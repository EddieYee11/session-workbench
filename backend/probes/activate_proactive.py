"""Activate the proactive scheduler on mini: wait for idle, back up, reload the service, then
verify one real proactive message inside the live Com conversation.

usage: python probes/activate_proactive.py [--fire] [--idle-limit 600] [--log PATH]
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from goals import GoalEvents
from proactive import Proactive

STATE = Path(os.environ.get('WORKBENCH_STATE', str(Path.home() / '.session-workbench')))
LABEL = 'work.eddie.sessions'
HEALTH = 'http://127.0.0.1:8650/health'
INFLIGHT = ('running', 'sending', 'queued')


def busy():
    marks = ','.join('?' * len(INFLIGHT))
    with sqlite3.connect(STATE / 'personal-conversation.sqlite', timeout=20) as db:
        if db.execute('SELECT 1 FROM messages WHERE status IN (' + marks + ') LIMIT 1', INFLIGHT).fetchone():
            return True
    with sqlite3.connect(STATE / 'tasks.sqlite', timeout=20) as db:
        return any(json.loads(row[0])['status'] in INFLIGHT + ('waiting', 'dispatching', 'cancel_requested')
                   for row in db.execute('SELECT data FROM tasks'))


def wait_idle(limit, log):
    deadline = time.time() + limit
    while time.time() < deadline:
        if not busy():
            return True
        log('waiting: Com still has an in-flight message or task')
        time.sleep(5)
    return False


def backup():
    target = STATE / 'backups' / time.strftime('com-proactive-%Y%m%d-%H%M%S')
    target.mkdir(parents=True, exist_ok=True)
    for source in STATE.glob('*.sqlite'):
        with sqlite3.connect(source) as db, sqlite3.connect(target / source.name) as copy:
            db.backup(copy)
    return target


def restart():
    subprocess.run(['launchctl', 'kickstart', '-k', f'gui/{os.getuid()}/{LABEL}'], check=True)


def wait_health(limit, log):
    deadline = time.time() + limit
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(HEALTH, timeout=5) as response:
                if response.status == 200:
                    return True
        except Exception:
            time.sleep(2)
    log('health check did not pass')
    return False


def watch(limit, log):
    """Return the live proactive receipt written after this call started."""
    started = time.time()
    deadline = started + limit
    while time.time() < deadline:
        with sqlite3.connect(STATE / 'personal-conversation.sqlite', timeout=20) as db:
            row = db.execute("SELECT text,status,created_at FROM messages WHERE request_id LIKE "
                             "'task-result:event:proactive:%' AND created_at>=? ORDER BY created_at DESC LIMIT 1",
                             (started,)).fetchone()
        if row and row[1] == 'completed':
            return row[0]
        log('waiting for the live receipt')
        time.sleep(5)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fire', action='store_true', help='重启后立刻排一条，验证线上链路')
    parser.add_argument('--idle-limit', type=int, default=900)
    parser.add_argument('--receipt-limit', type=int, default=300)
    parser.add_argument('--log', default=str(STATE / 'logs' / 'proactive-activate.log'))
    args = parser.parse_args()
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    handle = log_path.open('a')

    def log(message):
        line = time.strftime('[%Y-%m-%d %H:%M:%S] ') + message
        handle.write(line + '\n')
        handle.flush()
        print(line, flush=True)

    log('activate start: idle-limit=%ss fire=%s' % (args.idle_limit, args.fire))
    if not wait_idle(args.idle_limit, log):
        log('aborted: Com never became idle, service untouched')
        return 1
    log('backup: ' + str(backup()))
    restart()
    log('service reloaded')
    if not wait_health(90, log):
        return 1
    log('health ok')
    if args.fire:
        queued = Proactive(STATE).fire(GoalEvents(STATE), 'evening-review')
        log('queued live event: %s' % queued)
        text = watch(args.receipt_limit, log)
        log('live receipt: ' + json.dumps(text, ensure_ascii=False))
        if not text:
            return 1
    log('activate done')
    return 0


if __name__ == '__main__':
    sys.exit(main())
