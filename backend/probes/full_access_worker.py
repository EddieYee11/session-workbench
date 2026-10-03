"""Actual Pi worker writes and reads a disposable file through the genuine guard."""
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

CONTENT='Com Pi full-access verified '+uuid.uuid4().hex
SOURCE='请在当前目录创建 permission-proof.txt，内容完整写入「'+CONTENT+'」，然后用 read 工具读取全文，最终准确返回文件内容。'


async def run():
    with tempfile.TemporaryDirectory(prefix='com-pi-full-access-') as directory:
        root=Path(directory).resolve();state=root/'state';workspace=root/'workspace'
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
                if name not in ('loaded','authorize_tool','tool_result'):raise ValueError('Only native local-file tools are enabled in this probe')
                if name=='authorize_tool' and payload['args']['tool'] not in ('write','read'):
                    raise ValueError('Only write/read are allowed by this disposable fixture')
                result=await holder['tools'].call(name,payload['args'],payload['context'])
                if name=='authorize_tool':traces.append({'tool':payload['args']['tool'],'args':payload['args']['args'],'context':payload['context']})
            except Exception as error:
                status=400;result={'detail':'Disposable worker fixture denied: '+type(error).__name__}
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
        mid=chat.submit('native-pi-file-human-'+uuid.uuid4().hex,SOURCE)['message_id']
        with chat.db() as db:
            db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-file-probe-main')")
            row=dict(db.execute('SELECT * FROM messages WHERE id=?',(mid,)).fetchone())
        context={'origin_session_id':'com-file-probe-main','origin_message_id':mid,'origin_request_id':row['request_id']}
        store=TaskStore(state);runtime.task_store=store
        controller=TaskController(store,runtime,chat)
        registry=SimpleNamespace(observe=lambda *args,**kwargs:None,search=lambda *args,**kwargs:[])
        proposals=WorkProposalStore(state,workspace)
        holder['tools']=AgentTools(state,chat,proposals,store,controller,registry,GoalEvents(state))
        draft,authorization,key=authorized_assignment(chat,proposals,{
            **context,'request_id':'native-pi-file-'+uuid.uuid4().hex,'source_quote':SOURCE,
            'agent':'pi','relative_cwd':'.','sandbox':'read-only','title':'临时目录最高权限真实写入验收',
            'prompt':'直接 write 创建 permission-proof.txt，content 为 '+CONTENT+'。随后直接 read 全文，准确报告，不派任务，不调用 Bash。',
            'completion_condition':'实际文件存在且全文与 '+CONTENT+' 一致，真实 read 返回全文。'})
        created=store.create_authorized(draft,authorization,key)
        store.enqueue(created['id'],'先只读，不改代码','legacy-readonly-file-'+uuid.uuid4().hex)
        started=time.monotonic()
        try:
            await controller.start_queued()
            deadline=time.monotonic()+150
            while time.monotonic()<deadline:
                current=next(task for task in store.list() if task['id']==created['id'])
                if current['status'] not in ('dispatching','running','waiting'):break
                await asyncio.sleep(.15);await controller.poll()
            current=next(task for task in store.list() if task['id']==created['id'])
            output={'ok':False,'phase':'actual_worker_write_read','status':current['status'],
                    'failure':current.get('startup_failure'),'temporary_com_state':True,'production_state_changed':False,
                    'elapsed_ms':round((time.monotonic()-started)*1000),'denied':denied}
            if current['status']=='execution_finished':
                events=runtime.events(current['session_id']);worker=runtime.workers.workers[current['session_id']]
                target=workspace/'permission-proof.txt'
                output.update(traces=traces,reply=current['result'],actual_file_content=target.read_text() if target.exists() else None)
                if denied or not target.exists() or target.read_text().rstrip('\n')!=CONTENT:
                    return output
                writes=[index for index,call in enumerate(traces) if call['tool']=='write']
                output.update(write_tool_count=len(writes),read_after_write=bool(writes and any(call['tool']=='read' for call in traces[writes[-1]+1:])))
                if not writes or not output['read_after_write']:return output
                assert all(call['context']['task_id']==created['id'] and call['context']['origin_message_id']==mid and
                           call['context']['origin_request_id']==row['request_id'] for call in traces)
                assert any(event.get('kind')=='input.delivered' for event in events)
                assert CONTENT in current['result'] and not worker.isolated and not worker.readonly
                assert current['sandbox']=='danger-full-access' and not current.get('workspace_copy')
                assert current['inputs'][0]['state']=='revoked'
                recovery=list((state/'main-write-recovery').glob('*.json'));assert len(recovery)==1
                duplicate_blocked=False
                try:
                    # Replay the already authorized write while the original source remains valid.
                    store.change(current['id'],'fixture-duplicate-recheck','fixture',status='running')
                    written=traces[writes[0]]
                    holder['tools'].authorize_tool({'tool':'write','args':written['args'],'tool_call_id':'duplicate-fixture'},written['context'])
                except ValueError:duplicate_blocked=True
                assert duplicate_blocked
                output.update(ok=True,source_bound=True,sandbox=current['sandbox'],cwd_original=True,
                              native_isolated=worker.isolated,native_readonly=worker.readonly,workspace_copy=None,
                              readonly_audit=current['constraints'],readonly_input_state='revoked',tool_calls=len(traces),
                              duplicate_write_blocked=True,actual_file_content=target.read_text(),reply=current['result'])
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
