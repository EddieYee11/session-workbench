"""Apply only Com context settings, preserving model/auth/tool permissions; backups included."""
from pathlib import Path
from datetime import datetime
import json,shutil,socket,sys,sqlite3
import yaml


def main():
    if socket.gethostname()!='EddiedeMac-mini.local':raise RuntimeError('Apply on the verified mini host')
    profile=Path.home()/'.hermes/profiles/com-personal'
    state=Path.home()/'.session-workbench'
    with sqlite3.connect(state/'personal-conversation.sqlite') as db:
        if db.execute("SELECT 1 FROM messages WHERE role='user' AND status IN ('queued','sending','running')").fetchone():
            raise RuntimeError('Wait for the foreground turn to settle')
    with sqlite3.connect(state/'tasks.sqlite') as db:
        if any(json.loads(r[0]).get('status') in ('queued','dispatching','running','waiting','cancel_requested') for r in db.execute('SELECT data FROM tasks')):
            raise RuntimeError('Wait for managed tasks to settle')
    with sqlite3.connect(profile/'runs_idempotency.db') as db:
        if any(json.loads(r[0]).get('status') in ('queued','running') for r in db.execute('SELECT status_json FROM run_idempotency')):
            raise RuntimeError('Wait for Hermes runs to settle')
    with sqlite3.connect(profile/'state.db') as db:
        if db.execute('SELECT 1 FROM session_turn_leases WHERE expires_at > unixepoch()').fetchone():
            raise RuntimeError('Wait for the active Hermes turn lease')
    backup=Path.home()/'.session-workbench/backups'/('context-v2-'+datetime.now().strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True,mode=0o700)
    for name in ('config.yaml','SOUL.md'):
        shutil.copy2(profile/name,backup/name)
    cfg=yaml.safe_load((profile/'config.yaml').read_text())
    cfg.setdefault('agent',{})['system_prompt']=''  # authoritative Com instructions arrive once per run
    cfg.setdefault('auxiliary',{}).setdefault('background_review',{})['enabled']=False
    sys.path.insert(0,str(Path.home()/'.hermes/hermes-agent'))
    from toolsets import _HERMES_CORE_TOOLS
    from hermes_cli.config_defaults import DEFAULT_CONFIG
    direct={'terminal','read_file','search_files','clarify','skill_view'}
    deferred=sorted((set(_HERMES_CORE_TOOLS)|set(DEFAULT_CONFIG['tools']['tool_search']['defer']))-direct)
    cfg.setdefault('tools',{})['tool_search']={'enabled':'on','listing':'auto','listing_max_tokens':800,'search_default_limit':4,'max_search_limit':8,'defer':deferred}
    plugins=cfg.setdefault('plugins',{})
    plugins['enabled']=list(dict.fromkeys([*plugins.get('enabled',[]),'com-metrics']))
    plugins['disabled']=[x for x in plugins.get('disabled',[]) if x!='com-metrics']
    target=profile/'plugins/com-metrics'
    if target.exists():shutil.copytree(target,backup/'com-metrics')
    shutil.copytree(Path(__file__).with_name('hermes_metrics'),target,dirs_exist_ok=True)
    (profile/'SOUL.md').write_text('# Com\n你是 Eddie 的长期个人助理，有自己的判断，先想办法再问。自然、准确、简洁，保持连续协作。\n记忆权威为工作区 Markdown，由 Com memory_recall/memory_save 读取和维护；流程细则用 context_read 按需加载。不要维护第二套原生画像。用户授权、事实和不确定性以当前 Com 运行契约为准。\n')
    (profile/'config.yaml').write_text(yaml.safe_dump(cfg,allow_unicode=True,sort_keys=False))
    (profile/'config.yaml').chmod(0o600)
    print(json.dumps({'backup':str(backup),'model_unchanged':cfg.get('model'),'deferred_core_count':len(deferred)},ensure_ascii=False))

if __name__=='__main__':main()
