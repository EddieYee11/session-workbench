"""Mini-only native transport smoke acceptance, isolated from production stores/tools."""
import asyncio
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
import httpx

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'backend'))

async def wait(client,predicate,seconds=150):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        value=await predicate(client)
        if value:
            return value
        await asyncio.sleep(.3)
    raise AssertionError('acceptance timeout')

async def main():
    root=Path(tempfile.mkdtemp(prefix='com-native-acceptance-'))
    home=root/'home';project=home/'AI_Work_System/demo';project.mkdir(parents=True)
    (project/'hello.txt').write_text('fixture-read-only\n')
    state=root/'state';state.mkdir()
    env={**os.environ,'WORKBENCH_HOME':str(home),'WORKBENCH_STATE':str(state),
         'COM_MAIN_AGENT':'pi','COM_PI_SAFE_PROBE':'1','COM_INTERNAL_URL':'http://127.0.0.1:8765'}
    log=(root/'server.log').open('w')
    def start():
        return subprocess.Popen([sys.executable,'-m','uvicorn','app:app','--host','127.0.0.1','--port','8765'],cwd=ROOT/'backend',env=env,stdout=log,stderr=log)
    server=start()
    results=[]
    try:
        async with httpx.AsyncClient(base_url='http://127.0.0.1:8765',trust_env=False,timeout=30) as client:
            async def ready(c):
                try:return (await c.get('/health')).json().get('features',{}).get('pi_main')
                except httpx.HTTPError:return False
            await wait(client,ready,30)
            client.headers['Authorization']='Bearer '+(state/'token').read_text().strip()
            for n in range(2):
                key='real-native-pi-probe-'+str(n)
                text='请用 task_status 只读查询现有任务，然后简短告诉我查询结果。不要创建或修改任何任务。'
                a=(await client.post('/personal/conversation/messages',json={'request_id':key,'text':text})).json()
                b=(await client.post('/personal/quick-voice/messages',json={'request_id':key,'text':text,'purpose':'conversation'})).json()
                assert a['message_id']==b['message_id'],(a,b)
                async def done(c):
                    snapshot=(await c.get('/personal/conversation')).json()
                    message=next((m for m in snapshot.get('messages',[]) if m.get('id')==a['message_id']),None)
                    if message and message['status'] in ('completed','unknown','failed'):
                        return message
                message=await wait(client,done)
                assert message['status']=='completed',message
                receipt=(await client.get('/personal/quick-voice/receipts/'+key)).json()
                assert receipt['status']=='completed'
                assert (await client.get('/personal/tasks')).json()['items']==[]
                events=[json.loads(line) for line in (state/'pi-rpc/main/events.jsonl').read_text().splitlines()]
                calls=[e for e in events if e.get('turn_id')==key and e.get('type')=='tool_execution_start']
                loaded=(await client.get('/personal/capabilities',params={'query':'task_status'})).json()['items']
                assert any(c['id']=='task_status' and c['state']=='loaded' for c in loaded),loaded
                results.append({'case':'pi-main-text-voice-task-status','repeat':n+1,'status':'passed','message_id':a['message_id'],'tool_calls':len(calls)})
            # SSE retains public snapshot/update event names; closing app does not stop native work.
            async with client.stream('GET','/personal/conversation/stream') as response:
                async for line in response.aiter_lines():
                    if line.startswith('event:'):
                        assert line=='event: snapshot',line
                        results.append({'case':'public-sse-shape','status':'passed'})
                        break
            server.terminate();server.wait(10)
            server=start();await wait(client,ready,30)
            snapshot=(await client.get('/personal/conversation')).json()
            assert len([m for m in snapshot['messages'] if m['role']=='user'])==2
            results.append({'case':'restart-retains-message-request-identity','status':'passed'})
    finally:
        server.terminate()
        try:server.wait(10)
        except subprocess.TimeoutExpired:server.kill()
        log.close()
    report={'root':str(root),'cases':results,'production_side_effects':0,'routing_benchmark':False}
    print(json.dumps(report,ensure_ascii=False,indent=2))
    (root/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=='__main__':asyncio.run(main())
