"""Explicit Com configuration cutover/rollback; preserve all messages and uncertain work."""
import argparse,hashlib,json,os,shutil,socket,sqlite3,subprocess,time
from datetime import datetime
from pathlib import Path

STATE=Path.home()/'.session-workbench'
EXPECTED='EddiedeMac-mini.local'

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--apply',action='store_true');parser.add_argument('--rollback',type=Path)
    args=parser.parse_args()
    if socket.gethostname()!=EXPECTED:raise RuntimeError('只能在已核验的 mini 执行切换')
    path=STATE/'personal-conversation.sqlite'
    with sqlite3.connect(path.as_uri()+'?mode=ro',uri=True) as db:
        active=db.execute("SELECT COUNT(*) FROM messages WHERE role='user' AND status IN ('sending','running','queued')").fetchone()[0]
        counts=dict(db.execute('SELECT role,COUNT(*) FROM messages GROUP BY role'))
    if active:raise RuntimeError('主线还有未结束输入，请等原输入结束后再切换')
    active_tasks=0
    if (STATE/'tasks.sqlite').exists():
        with sqlite3.connect((STATE/'tasks.sqlite').as_uri()+'?mode=ro',uri=True) as db:
            active_tasks=sum(json.loads(row[0]).get('status') in ('queued','dispatching','running','waiting','cancel_requested')
                             for row in db.execute('SELECT data FROM tasks'))
    if active_tasks:raise RuntimeError('还有受管工作任务未结束，请等任务结束后再切换')
    config=STATE/'agent-config.json'
    if args.rollback:
        prior=args.rollback/'agent-config.json'
        old=json.loads(prior.read_text()) if prior.exists() else {'main_agent':'hermes'}
        old['main_agent']='hermes'
        config.write_text(json.dumps(old,ensure_ascii=False,indent=2));config.chmod(0o600)
        with sqlite3.connect(path) as db:
            old_session=db.execute("SELECT value FROM meta WHERE key='hermes_session_id'").fetchone()
            if old_session:db.execute('INSERT OR REPLACE INTO meta VALUES (?,?)',('origin-map:com-pi-main',json.dumps({'to':old_session[0],'boundary':time.time()})))
        print(json.dumps({'main_agent':'hermes','history_preserved':True,'replay':False}));return
    if not args.apply:
        print(json.dumps({'active_main_inputs':active,'active_worker_tasks':active_tasks,'counts':counts,'configured_main':json.loads(config.read_text()).get('main_agent') if config.exists() else 'hermes'}));return
    backup=STATE/'backups'/('com-pi-'+datetime.now().strftime('%Y%m%d-%H%M%S'));backup.mkdir(parents=True,mode=0o700)
    for database in [*STATE.glob('*.sqlite'),*STATE.glob('*.sqlite3')]:
        source=sqlite3.connect(database.as_uri()+'?mode=ro',uri=True)
        dest=sqlite3.connect(backup/database.name)
        try:source.backup(dest)
        finally:source.close();dest.close()
        (backup/database.name).chmod(0o600)
    for name in ('agent-config.json','token','hermes-personal-api-key','hermes-triage-api-key'):
        original=STATE/name
        if original.exists():shutil.copy2(original,backup/name);(backup/name).chmod(0o600)
    boundary=time.time()
    global_settings=Path.home()/'.claude/settings.json'
    record={'backup':str(backup),'boundary':boundary,'previous_counts':counts,'main_agent':'pi','claude_model':'deepseek-v4.1-flash',
            'execution_host':EXPECTED,'scheduler_enabled':False,'replay':False,
            'claude_global_settings_sha256':hashlib.sha256(global_settings.read_bytes()).hexdigest()}
    (backup/'cutover.json').write_text(json.dumps(record,indent=2));(backup/'cutover.json').chmod(0o600)
    with sqlite3.connect(path) as db:
        old_session=db.execute("SELECT value FROM meta WHERE key='hermes_session_id'").fetchone()
        db.execute("INSERT OR IGNORE INTO meta VALUES ('pi_session_id','com-pi-main')")
        db.execute("INSERT OR IGNORE INTO meta VALUES ('pi_cutover_boundary',?)",(str(boundary),))
        if old_session:db.execute('INSERT OR IGNORE INTO meta VALUES (?,?)',('origin-map:'+old_session[0],json.dumps({'to':'com-pi-main','boundary':boundary})))
    updated=json.loads(config.read_text()) if config.exists() else {}
    updated.update(main_agent='pi',claude_model='deepseek-v4.1-flash',execution_host=EXPECTED)
    config.write_text(json.dumps(updated,ensure_ascii=False,indent=2));config.chmod(0o600)
    if (STATE/'goals.sqlite').exists():
        with sqlite3.connect(STATE/'goals.sqlite') as db:db.execute("INSERT OR REPLACE INTO settings VALUES ('scheduler_enabled','false')")
    print(json.dumps(record,indent=2))

if __name__=='__main__':main()
