"""Daily launchd log rotation in the writer process; no copy/truncate race."""
import os
import time
from pathlib import Path


class DailyServiceLogs:
    def __init__(self, state, descriptors=(("stdout.log", 1), ("stderr.log", 2)), keep=7):
        self.state = Path(state)
        self.descriptors = descriptors
        self.keep = keep
        self.days = {}
        for name, _ in descriptors:
            path = self.state / name
            self.days[name] = self.day(path.stat().st_mtime if path.exists() else time.time())

    @staticmethod
    def day(timestamp):
        return time.strftime('%Y-%m-%d', time.localtime(timestamp))

    def rotate(self, now=None):
        now = time.time() if now is None else now
        today = self.day(now)
        rotated = []
        for name, target_fd in self.descriptors:
            path = self.state / name
            if self.days[name] == today or not path.exists():
                continue
            archive = self.state / f'{name}.{self.days[name]}.{int(now * 1000)}'
            # Existing writes keep reaching the archive until dup2 atomically switches
            # the writer FD. Nothing is truncated, and stderr's logging objects survive.
            path.rename(archive)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                os.dup2(fd, target_fd)
            finally:
                os.close(fd)
            self.days[name] = today
            archive.chmod(0o600)
            rotated.append(archive.name)
            archives = sorted(self.state.glob(name + '.*'), key=lambda p: p.stat().st_mtime, reverse=True)
            # Only our numeric timestamp archives are eligible for retention cleanup.
            archives = [p for p in archives if p.name.rsplit('.', 1)[-1].isdigit() and p.is_file()]
            for old in archives[self.keep:]:
                old.unlink()
        return rotated
