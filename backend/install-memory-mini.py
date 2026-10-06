"""Install after Syncthing delivery. Requires the isolated Hindsight venv."""
import os
import plistlib
import subprocess
from pathlib import Path

home = Path.home()
root = Path(__file__).resolve().parent
state = home / '.com-memory'
state.mkdir(mode=0o700, exist_ok=True)
state.chmod(0o700)
for label, executable, script, args in [
    ('work.eddie.com-memory', state/'venv/bin/python', 'memory_server.py', []),
    ('work.eddie.com-memory-sync', home/'.session-workbench/venv/bin/python', 'memory.py', ['watch']),
]:
    target = home / 'Library/LaunchAgents' / (label + '.plist')
    if target.exists():
        backup = state / (label + '.plist.before')
        if not backup.exists(): backup.write_bytes(target.read_bytes())
        subprocess.run(['launchctl', 'bootout', f'gui/{os.getuid()}', str(target)], capture_output=True)
    value = {'Label': label, 'ProgramArguments': [str(executable), str(root/script), *args],
        'WorkingDirectory': str(state), 'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'},
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 30,
        'StandardOutPath': str(state / (label + '.stdout.log')), 'StandardErrorPath': str(state / (label + '.stderr.log'))}
    target.write_bytes(plistlib.dumps(value)); target.chmod(0o600)
    subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(target)], check=True)
print('Installed loopback Hindsight and Markdown synchronizer.')
