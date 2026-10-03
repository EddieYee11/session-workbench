"""One native read-only tool turn against an isolated Com guard; no routing benchmark."""
import asyncio,json,os,subprocess,sys,tempfile,time
from pathlib import Path
import httpx
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'backend'))
from conversation import PersonalConversation
from pi_rpc import PiRPC
from pi_main import MAIN_PROMPT

async def main():
    root=Path(tempfile.mkdtemp(prefix='com-main-tools-'))
    home=root/'home';workspace=home/'AI_Work_System';workspace.mkdir(parents=True)
    state=root/'state';state.mkdir()
    chat=PersonalConversation(state)
    mid=chat.submit('native-main-read-001','帮我直接用 bash 运行 command -v adb 和 adb version，只读确认当前主机工具，不创建任务。')['message_id']
    with chat.db() as db:
        db.execute("INSERT OR REPLACE INTO meta VALUES ('pi_session_id','com-pi-main')")
        db.execute("UPDATE messages SET status='completed' WHERE id=?",(mid,))
    env={**os.environ,'WORKBENCH_HOME':str(home),'WORKBENCH_STATE':str(state),'COM_MAIN_AGENT':'pi',
         'COM_PI_SAFE_PROBE':'1','COM_INTERNAL_URL':'http://127.0.0.1:8766'}
    log=(root/'server.log').open('w')
    server=subprocess.Popen([sys.executable,'-m','uvicorn','app:app','--host','127.0.0.1','--port','8766'],cwd=ROOT/'backend',env=env,stdout=log,stderr=log)
    rpc=None
    try:
        async with httpx.AsyncClient(base_url=env['COM_INTERNAL_URL'],trust_env=False) as client:
            for _ in range(100):
                try:
                    if (await client.get('/health')).status_code==200:break
                except httpx.HTTPError:pass
                await asyncio.sleep(.1)
            else:raise AssertionError('fixture server not ready')
            argv=['/usr/local/bin/pi','--mode','rpc','--provider','opencode-go','--model','deepseek-v4.1-flash',
                  '--no-context-files','--no-extensions','--no-skills','--extension',str(ROOT/'backend/com-pi.ts'),
                  '--session-dir',str(root/'sessions'),'--system-prompt',MAIN_PROMPT]
            rpc=PiRPC(state,'native-main-tools',workspace,argv=argv,env=env)
            rpc.bind({'origin_session_id':'com-pi-main','origin_message_id':mid,'origin_request_id':'native-main-read-001','fixture':True})
            events=[]
            async for kind,data in rpc.stream('帮我直接用 bash 运行 command -v adb 和 adb version，只读确认当前主机工具，不创建任务。','native-main-read-001'):
                events.append({'kind':kind,'data':data})
            tools=[e for e in events if e['kind']=='tool.completed' and e['data'].get('tool_name')=='bash']
            assert tools and any('Android Debug Bridge' in json.dumps(e) for e in tools),events
            assert any(e['kind']=='run.completed' for e in events),events
            client.headers['Authorization']='Bearer '+(state/'token').read_text().strip()
            assert (await client.get('/personal/tasks')).json()['items']==[]
            report={'status':'passed','native_bash_completed':True,'task_created':False,'production_side_effects':0,'routing_benchmark':False,'events':events}
            (root/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
            print(json.dumps({'status':'passed','report':str(root/'result.json'),'native_bash_completed':True,'task_created':False}))
    finally:
        if rpc:await rpc.stop()
        server.terminate()
        try:server.wait(10)
        except subprocess.TimeoutExpired:server.kill();server.wait()
        log.close()

if __name__=='__main__':asyncio.run(main())
