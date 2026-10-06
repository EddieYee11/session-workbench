"""Prepare an isolated full-access Com Hermes profile and explicitly cut over."""
import argparse
import hashlib
import json
import os
import shutil
import socket
import sqlite3
import time
from datetime import datetime
from pathlib import Path
import yaml


def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','cutover']);args=parser.parse_args()
    if socket.gethostname() != 'EddiedeMac-mini.local':raise RuntimeError('Run on the verified mini host')
    home=Path.home();state=home/'.session-workbench';profile=home/'.hermes/profiles/com-personal'
    root=home/'AI_Work_System/work/工具与效率/会话工作台'
    if args.action=='prepare':
        backup=state/'backups'/('hermes-profile-'+datetime.now().strftime('%Y%m%d-%H%M%S'));backup.mkdir(parents=True,mode=0o700)
        for name in ('config.yaml','.env','auth.json'):
            if (profile/name).exists():shutil.copy2(profile/name,backup/name);(backup/name).chmod(0o600)
        base=yaml.safe_load((home/'.hermes/config.yaml').read_text());cfg=yaml.safe_load((profile/'config.yaml').read_text())
        cfg['model']={'default':'deepseek-v4-flash','provider':'deepseek'}
        cfg['platform_toolsets']={'api_server':['hermes-cli','com_workbench'],'cron':['hermes-cli','com_workbench']}
        cfg['terminal']={**base.get('terminal',{}),'backend':'local','cwd':str(home/'AI_Work_System')}
        cfg['skills']={**base.get('skills',{}),'external_dirs':[str(home/'.pi-gateway/skills'),str(home/'AI_Work_System/.agents/skills')], 'write_approval':False}
        cfg['memory']={'memory_enabled':False,'user_profile_enabled':False}
        cfg['approvals']={'mode':'off'}
        cfg['delegation']={**base.get('delegation',{}),'max_concurrent_children':2,'inherit_mcp_toolsets':True,'subagent_auto_approve':True}
        cfg['agent']={**cfg.get('agent',{}),'max_turns':100,'gateway_timeout':1800}
        cfg['mcp_servers']['com_workbench']['tools']={'prompts':False,'resources':False}
        cfg['mcp_servers']['com_workbench']['trust']='full'
        cfg['mcp_servers']['com_workbench']['command']=str(state/'venv/bin/python')
        cfg['timezone']='Asia/Shanghai'
        from hermes_prompt import SYSTEM_PROMPT
        prompt=SYSTEM_PROMPT
        cfg.setdefault('agent',{})['system_prompt']=prompt
        (profile/'config.yaml').write_text(yaml.safe_dump(cfg,allow_unicode=True,sort_keys=False));(profile/'config.yaml').chmod(0o600)
        env={}
        for line in (profile/'.env').read_text().splitlines():
            if '=' in line and not line.startswith('#'):k,v=line.split('=',1);env[k]=v
        for line in (home/'.hermes/.env').read_text().splitlines():
            if '=' in line and not line.startswith('#'):
                k,v=line.split('=',1)
                if k.startswith('DEEPSEEK_'):env[k]=v
        env['HERMES_YOLO_MODE']='1'
        (profile/'.env').write_text('\n'.join(k+'='+v for k,v in env.items())+'\n');(profile/'.env').chmod(0o600)
        print(json.dumps({'profile':str(profile),'backup':str(backup),'mode':'full-access','model':'deepseek-v4-flash','prepared':True}));return
    dbpath=state/'personal-conversation.sqlite'
    with sqlite3.connect(dbpath) as db:
        if db.execute("SELECT COUNT(*) FROM messages WHERE role='user' AND status IN ('queued','sending','running')").fetchone()[0]:raise RuntimeError('Wait for current main inputs to settle')
    if (state/'tasks.sqlite').exists():
        with sqlite3.connect(state/'tasks.sqlite') as db:
            if any(json.loads(r[0]).get('status') in ('queued','dispatching','running','waiting','cancel_requested') for r in db.execute('SELECT data FROM tasks')):raise RuntimeError('Wait for managed tasks to settle')
    import asyncio
    from hermes_runtime import HermesRuntime
    from hermes_prompt import SYSTEM_PROMPT
    client=HermesRuntime(state)
    with sqlite3.connect(dbpath) as db:
        history=[{'role':r[0],'text':r[1][-1000:]} for r in db.execute("SELECT role,text FROM messages WHERE status='completed' ORDER BY created_at DESC LIMIT 16")]
    async def seed():
        try:
            await client.request('POST','/api/sessions',{'id':'com-hermes-main','source':'api_server','title':'Com! 主对话','system_prompt':SYSTEM_PROMPT+'\n只读旧对话摘要，不重放操作：'+json.dumps(list(reversed(history)),ensure_ascii=False)})
        except RuntimeError as error:
            if str(error)!='hermes_api_409':raise
    asyncio.run(seed())
    path=state/'agent-config.json';cfg=json.loads(path.read_text());cfg.update(main_agent='hermes',hermes_model='deepseek-v4-flash',hermes_provider='deepseek',execution_host=socket.gethostname(),personal_autonomy={'mandate_id':'com-hermes-personal-20261005','calendar':True,'reminders':True,'source':'User-approved Com Hermes implementation plan 2026-10-05'})
    path.write_text(json.dumps(cfg,ensure_ascii=False,indent=2));path.chmod(0o600)
    with sqlite3.connect(dbpath) as db:
        boundary=time.time();sid='com-hermes-main'
        old=[r[0] for r in db.execute("SELECT value FROM meta WHERE key IN ('pi_session_id','hermes_session_id')")]
        db.execute("INSERT OR REPLACE INTO meta VALUES('hermes_v2_session_id',?)",(sid,))
        for previous in old:db.execute('INSERT OR REPLACE INTO meta VALUES(?,?)',('origin-map:'+previous,json.dumps({'to':sid,'boundary':boundary})))
        count=db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]
    print(json.dumps({'cutover':True,'main_agent':'hermes','messages_preserved':count,'replayed':False}))

if __name__=='__main__':main()
