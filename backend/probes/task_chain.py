"""Real Claude worker through source guards, durable ledger, verification and isolated merge."""
import asyncio,json,tempfile,sys,time,socket
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'backend'))
from history import History
from runtime import Runtime
from tasks import TaskStore,TaskController
from conversation import PersonalConversation
from pi_main import PiMainClient
from work_dispatch import WorkProposalStore
from agent_tools import AgentTools
from capabilities import CapabilityRegistry
from goals import GoalEvents

async def main():
    state=Path(tempfile.mkdtemp(prefix='com-task-chain-'))
    (state/'agent-config.json').write_text(json.dumps({'claude_model':'deepseek-v4.1-flash','execution_host':socket.gethostname()}))
    home=state/'home';workspace=home/'AI_Work_System';project=workspace/'demo';project.mkdir(parents=True)
    (project/'source.txt').write_text('dirty-current-change')
    runtime=Runtime(History(home,state),'isolated-fixture-token')
    store=TaskStore(state);runtime.task_store=store
    chat=PersonalConversation(state,PiMainClient(state,workspace,tools=False))
    sid=await chat._ensure_session()
    controller=TaskController(store,runtime,chat)
    service=AgentTools(state,chat,WorkProposalStore(state,workspace),store,controller,CapabilityRegistry(state),GoalEvents(state))
    async def fixture_synced(_):return True
    runtime.workers.copies.sync_check=fixture_synced
    cases=[]
    try:
        for n in range(2):
            # Seed a real fixture user row, without starting a main model/routing experiment.
            rid='chain-user-000'+str(n)
            text='帮我在 demo 项目添加 result'+str(n)+'.txt，内容为 CHAIN_OK_'+str(n)+'，保持现有 source.txt。'
            human=chat.submit(rid,text);chat._finish(human['message_id'],'completed')
            context={'origin_session_id':sid,'origin_message_id':human['message_id'],'origin_request_id':rid,'fixture':True}
            args={'agent':'claude','relative_cwd':'demo','title':'隔离项目修复'+str(n),'sandbox':'workspace-write',
                  'request_id':'chain-task-000'+str(n),'prompt':text+' 使用 Write 工具，避免命令。',
                  'source_quote':text,'completion_condition':'文件包含 CHAIN_OK_'+str(n)}
            receipt=await service.call('task_submit',args,context)
            same=await service.call('task_submit',args,context);assert same['task_id']==receipt['task_id']
            deadline=time.monotonic()+150
            while time.monotonic()<deadline:
                await controller.poll()
                task=next(t for t in store.list() if t['id']==receipt['task_id'])
                if task['status'] in ('execution_finished','failed','unknown'):break
                await asyncio.sleep(.2)
            assert task['status']=='execution_finished',task
            assert task['verification_status']=='pending' and not task['structured_result']['uncertain']
            assert any(e['kind']=='tool.started' for e in task['events']),task['events']
            assert (Path(task['workspace_copy'])/'source.txt').read_text()=='dirty-current-change'
            assert not (project/('result'+str(n)+'.txt')).exists()
            accepted=await service.call('task_verify',{'task_id':task['id'],'checks':[{'type':'file_contains','path':'result'+str(n)+'.txt','value':'CHAIN_OK_'+str(n)}]},context)
            assert accepted['verification_status']=='passed'
            merged=await service.call('task_merge',{'task_id':task['id']},context)
            assert merged['status']=='merged' and (project/('result'+str(n)+'.txt')).read_text().strip()=='CHAIN_OK_'+str(n)
            assert len(store.list())==n+1
            cases.append({'case':'source-submit-native-write-timeline-verify-merge','repeat':n+1,'status':'passed','fixture_syncthing':True})
        report={'root':str(state),'cases':cases,'production_side_effects':0,'production_capability_verification':False,'routing_benchmark':False}
        (state/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
    finally:await runtime.workers.close();await chat.stop()

if __name__=='__main__':asyncio.run(main())
