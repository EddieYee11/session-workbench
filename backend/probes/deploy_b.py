"""Run only on mini, after source hash verification; do not interrupt work."""
from pathlib import Path
import json,sqlite3,subprocess,time
h=Path.home();s=h/'.session-workbench'
with sqlite3.connect(s/'tasks.sqlite') as db:
 assert not any(json.loads(r[0])['status'] in ('running','waiting','queued','dispatching','cancel_requested') for r in db.execute('SELECT data FROM tasks'))
with sqlite3.connect(s/'personal-conversation.sqlite') as db:
 assert not db.execute("SELECT 1 FROM messages WHERE status IN ('running','sending','queued') LIMIT 1").fetchone()
backup=s/'backups'/time.strftime('com-b-1.8.1-%Y%m%d-%H%M%S');backup.mkdir(parents=True)
for source in s.glob('*.sqlite*'):
 if source.name.endswith(('-wal','-shm')):continue
 with sqlite3.connect(source) as db, sqlite3.connect(backup/source.name) as target:db.backup(target)
subprocess.run(['launchctl','kickstart','-k',f'gui/{__import__("os").getuid()}/work.eddie.sessions'],check=True)
print('SQLite backup:',backup,'; restart requested with no executing Com work')
