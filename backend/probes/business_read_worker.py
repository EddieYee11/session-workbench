"""Real WorkerRuntime create/input/tool/result, with disposable source-bound Com state."""
import argparse
import asyncio
import json
import os
import sys
import tempfile
import time
import uuid
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from agent_tools import AgentTools
from conversation import PersonalConversation
from goals import GoalEvents
from history import History
from runtime import Runtime
from task_tools import authorized_assignment
from tasks import TaskController,TaskStore
from work_dispatch import WorkProposalStore

SOURCE='帮我找一下，我的九月五号消费了一千三百二十五，这是什么消费？'


async def run():
    with tempfile.TemporaryDirectory(prefix='com-business-worker-') as directory:
        root=Path(directory);state=root/'state';workspace=root/'workspace'
        state.mkdir(mode=0o700);workspace.mkdir()
        token=uuid.uuid4().hex
        (state/'token').write_text(token);(state/'token').chmod(0o600)
        traces=[];denied=[];holder={}

        async def serve(reader,writer):
            status=200;result={};name=''
            try:
                header=(await reader.readuntil(b'\r\n\r\n')).decode()
                if ('Authorization: Bearer '+token).lower() not in header.lower():raise ValueError('Disposable token mismatch')
                length=next(int(line.split(':',1)[1]) for line in header.split('\r\n') if line.lower().startswith('content-length:'))
                payload=json.loads(await reader.readexactly(length));name=header.split(' ',2)[1].rsplit('/',1)[-1]
                if name not in ('loaded','bookkeeping_search','tool_result'):raise ValueError('Only the historical read tool is enabled in this probe')
                result=await holder['tools'].call(name,payload['args'],payload['context'])
                if name=='bookkeeping_search':traces.append({'tool':name,'args':payload['args'],'context':payload['context'],'result':result})
            except Exception as error:
                status=400;result={'detail':'Disposable worker read denied: '+type(error).__name__}
                denied.append({'tool':name,'error_type':type(error).__name__})
            try:
                body=json.dumps(result,ensure_ascii=False).encode()
                writer.write(f'HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {len(body)}\r\n\r\n'.encode()+body)
                await writer.drain()
            finally:
                writer.close();await writer.wait_closed()

        server=await asyncio.start_server(serve,'127.0.0.1',0)
        port=server.sockets[0].getsockname()[1]
        previous=os.environ.get('COM_INTERNAL_URL');os.environ['COM_INTERNAL_URL']=f'http://127.0.0.1:{port}'
        history=History(Path.home(),state);runtime=Runtime(history,token)
        chat=PersonalConversation(state)
        mid=chat.submit('native-worker-human-'+uuid.uuid4().hex,SOURCE)['message_id']
        with chat.db() as db:
            db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-worker-probe-main')")
            row=dict(db.execute('SELECT * FROM messages WHERE id=?',(mid,)).fetchone())
        context={'origin_session_id':'com-worker-probe-main','origin_message_id':mid,'origin_request_id':row['request_id']}
        store=TaskStore(state);runtime.task_store=store
        controller=TaskController(store,runtime,chat)
        registry=SimpleNamespace(observe=lambda *args,**kwargs:None,search=lambda *args,**kwargs:[])
        proposals=WorkProposalStore(state,workspace)
        holder['tools']=AgentTools(state,chat,proposals,store,controller,registry,GoalEvents(state))
        draft,authorization,key=authorized_assignment(chat,proposals,{
            **context,'request_id':'native-worker-query-'+uuid.uuid4().hex,'source_quote':SOURCE,
            'agent':'pi','relative_cwd':'.','sandbox':'danger-full-access',
            'title':'只读查账：9月5日1325元是什么消费',
            'prompt':'只读查2026-09-05金额1325元的支出，直接bookkeeping_search，返回真实交易ID、分类、备注、账户、日期金额，不派任务。',
            'completion_condition':'报告2026-09-05的1325元支出实际ID、类别、备注和账户'})
        created=store.create_authorized(draft,authorization,key)
        started=time.monotonic();output={}
        try:
            await controller.start_queued()
            deadline=time.monotonic()+150
            while time.monotonic()<deadline:
                current=next(task for task in store.list() if task['id']==created['id'])
                if current['status'] not in ('dispatching','running','waiting'):break
                await asyncio.sleep(.15);await controller.poll()
            current=next(task for task in store.list() if task['id']==created['id'])
            events=runtime.events(current.get('session_id','')) if current.get('session_id') else []
            output={'ok':False,'phase':'full_worker_create_input_tool_result','status':current['status'],
                    'startup_phase':current.get('startup_phase'),'failure':current.get('startup_failure'),
                    'block_reason':current.get('block_reason'),'temporary_com_state':True,
                    'production_ledger_written':False,'production_com_task_changed':False,
                    'elapsed_ms':round((time.monotonic()-started)*1000),'denied':denied,
                    'native_event_types':list(dict.fromkeys(event.get('type') or event.get('kind') for event in events))}
            if current['status']=='execution_finished':
                assert not denied and len(traces)==1
                trace=traces[0];items=trace['result']['items'];assert len(items)==1
                item=items[0];assert item['id']=='3843404382045470720' and item['amount']==1325
                assert trace['context']['task_id']==created['id'] and trace['context']['origin_message_id']==mid
                assert trace['context']['origin_request_id']==row['request_id']
                assert any(event.get('kind')=='input.delivered' for event in events)
                assert all(str(item[key]) in current['result'] for key in ('id','comment','account'))
                output.update(ok=True,source_bound=True,execution_scope=current['execution_scope'],
                              native_isolated=runtime.workers.workers[current['session_id']].isolated,
                              native_readonly=runtime.workers.workers[current['session_id']].readonly,
                              tool_calls=1,task_count=len(store.list()),actual_record=item,
                              coverage=trace['result']['coverage'],reply=current['result'])
            return output
        finally:
            await runtime.workers.close();server.close();await server.wait_closed()
            if previous is None:os.environ.pop('COM_INTERNAL_URL',None)
            else:os.environ['COM_INTERNAL_URL']=previous


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--output');args=parser.parse_args()
    result=asyncio.run(run())
    if args.output:
        target=Path(args.output);target.write_text(json.dumps(result,ensure_ascii=False,indent=2));target.chmod(0o600)
    print(json.dumps(result,ensure_ascii=False))
    sys.exit(0 if result['ok'] else 1)
