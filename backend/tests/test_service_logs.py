import os
from service_logs import DailyServiceLogs


def test_rotation_switches_the_live_writer_without_truncating_history(tmp_path):
    path = tmp_path/'stdout.log'
    path.write_text('before\n')
    fd = os.open(path, os.O_WRONLY | os.O_APPEND)
    try:
        logs=DailyServiceLogs(tmp_path, descriptors=((path.name,fd),), keep=2)
        logs.days[path.name]='2000-01-01'
        archives=logs.rotate(1700000000)
        os.write(fd,b'after\n')
        assert len(archives)==1
        assert (tmp_path/archives[0]).read_text()=='before\n'
        assert path.read_text()=='after\n'
        assert logs.rotate(1700000001)==[]
        assert path.stat().st_mode & 0o777 == 0o600
        for day in range(1,4): logs.rotate(1700000000+86400*day)
        assert len(list(tmp_path.glob('stdout.log.*')))==2
    finally: os.close(fd)
