"""Native work-page API: owner, copies, acceptance, resume and authoritative user echo."""
import asyncio,json,os,tempfile,sys,time
from pathlib import Path
import httpx
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'backend'))

async def main():
    state=Path(tempfile.mkdtemp(prefix='com-manual-chain-'));home=state/'home';project=home/'AI_Work_System/demo';project.mkdir(parents=True)
    (project/'existing.txt').write_text('dirty original')
    (state/'agent-config.json').write_text(json.dumps({'claude_model':'deepseek-v4.1-flash'}))
    os.environ.update(WORKBENCH_STATE=str(state),WORKBENCH_HOME=str(home),COM_MAIN_AGENT='pi',COM_PI_SAFE_PROBE='1')
    import app
    async def stable(_):return True
    app.runtime.workers.copies.sync_check=stable
    async def settled(tid):
        deadline=time.monotonic()+150
        while time.monotonic()<deadline:
            await app.task_controller.poll()
            task=next(t for t in app.task_store.list() if t['id']==tid)
            if task['status'] in ('execution_finished','failed','unknown'):return task
            await asyncio.sleep(.2)
        raise AssertionError('task timeout')
    results=[]
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app.app),base_url='http://fixture',headers={'Authorization':'Bearer '+app.TOKEN}) as client:
            for n in range(2):
                request='manual-ui-000'+str(n)
                reply=await client.post('/sessions',json={'agent':'claude','cwd':str(project),'request_id':request,
                    'prompt':'帮我在项目添加 output'+str(n)+'.txt，内容是 MANUAL_OK_'+str(n)+'。使用 Write，保持 existing.txt。',
                    'sandbox':'workspace-write','model':'deepseek-v4.1-flash'})
                assert reply.status_code==200,reply.text
                sid=reply.json()['sid'];metadata=app.history.managed()[sid]
                tid=metadata['task_id'];task=await settled(tid)
                assert task['status']=='execution_finished',task
                assert task['owner_conversation_id']=='personal-main' and task['verification_status']=='pending'
                assert not (project/('output'+str(n)+'.txt')).exists()
                context={k:task[k] for k in ('origin_session_id','origin_message_id','origin_request_id')}
                await app.agent_tools.call('task_verify',{'task_id':tid,'checks':[{'type':'file_contains','path':'output'+str(n)+'.txt','value':'MANUAL_OK_'+str(n)}]},context)
                await app.agent_tools.call('task_merge',{'task_id':tid},context)
                reply=await client.post('/sessions/'+sid+'/input',json={'request_id':'manual-follow-'+str(n),'text':'请用 Read 读取 output'+str(n)+'.txt，只回复其内容。'})
                assert reply.status_code==200,reply.text
                continued=await settled(tid);assert continued['status']=='execution_finished' and continued['result_round']==2,continued
                assert 'MANUAL_OK_'+str(n) in continued['result']
                await app.agent_tools.call('task_verify',{'task_id':tid,'checks':[{'type':'file_contains','path':'output'+str(n)+'.txt','value':'MANUAL_OK_'+str(n)}]},context)
                await app.agent_tools.call('task_merge',{'task_id':tid},context)
                live=(await client.get('/sessions/'+sid+'/live')).json()['items']
                assert any(m.get('request_id')=='manual-follow-'+str(n) and m['role']=='user' for m in live),live
                assert (project/'existing.txt').read_text()=='dirty original'
                results.append({'case':'work-page-api-owner-write-accept-merge-native-resume-echo','repeat':n+1,'status':'passed'})
        report={'root':str(state),'cases':results,'production_side_effects':0,'fixture_syncthing':True}
        (state/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
    finally:await app.runtime.workers.close();await app.conversation.stop();await app.inspector.stop()

if __name__=='__main__':asyncio.run(main())
