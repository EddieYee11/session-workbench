"""Actual Work routes and two-turn temporary-file writes by CC and Codex.

This never connects to production Com, reuses a production session, or writes
outside its disposable project. Native authentication remains inside the SDK.
"""
import argparse
import asyncio
import contextlib
import importlib
import hashlib
import json
import os
import socket
import sys
import tempfile
import time
import types
import uuid
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))


async def run():
    import httpx
    import websockets
    with tempfile.TemporaryDirectory(prefix='com-manual-chat-') as directory:
        root=Path(directory).resolve();home=root/'home';state=root/'state';codex_home=root/'codex'
        project_root=home/'AI_Work_System'/'chat-project'
        project_root.mkdir(parents=True);state.mkdir(mode=0o700);codex_home.mkdir(mode=0o700)
        native_home=Path(os.environ.get('CODEX_HOME',str(Path.home()/'.codex'))).expanduser()
        linked=[]
        shared_hashes={}
        for name in ('auth.json','config.toml'):
            source=native_home/name
            if source.is_file():
                shared_hashes[name]=hashlib.sha256(source.read_bytes()).hexdigest()
                (codex_home/name).symlink_to(source.resolve());linked.append(name)
        original_config=Path.home()/'.session-workbench/agent-config.json'
        config=json.loads(original_config.read_text()) if original_config.exists() else {}
        (state/'agent-config.json').write_text(json.dumps({'main_agent':'pi',
            **({'claude_model':config['claude_model']} if config.get('claude_model') else {})}))
        previous={name:os.environ.get(name) for name in ('WORKBENCH_HOME','WORKBENCH_STATE','COM_MAIN_AGENT','CODEX_HOME')}
        os.environ.update(WORKBENCH_HOME=str(home),WORKBENCH_STATE=str(state),COM_MAIN_AGENT='pi',CODEX_HOME=str(codex_home))
        module=importlib.import_module('app')
        runtime=module.runtime
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        assert port!=18942
        native=await asyncio.create_subprocess_exec(runtime.codex,'app-server','--listen',f'ws://127.0.0.1:{port}',
            '--ws-auth','capability-token','--ws-token-file',str(state/'token'),
            stdin=asyncio.subprocess.DEVNULL,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL,
            env=dict(os.environ))

        async def ensure_rpc(self):
            async with self.connect_lock:
                if self.rpc is not None:return
                for _ in range(100):
                    if native.returncode is not None:raise RuntimeError('Disposable Codex app-server exited')
                    try:
                        self.rpc=await websockets.connect(f'ws://127.0.0.1:{port}',
                            additional_headers={'Authorization':'Bearer '+self.token},max_size=32*1024*1024)
                        break
                    except OSError:await asyncio.sleep(.1)
                if self.rpc is None:raise RuntimeError('Disposable Codex app-server did not start')
                self.reader_task=asyncio.create_task(self.reader())
                await self.call('initialize',{'clientInfo':{'name':'com-work-acceptance','title':'Work chat native acceptance','version':'1.0'},
                                               'capabilities':{'experimentalApi':True}},connect=False)
                await self.rpc.send(json.dumps({'method':'initialized'}))
        runtime.ensure_rpc=types.MethodType(ensure_rpc,runtime)
        cases=[];phase='http_create';output={}

        async def settled(task_id,timeout=180):
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                async with runtime.action_lock:await module.task_controller.poll()
                current=next(task for task in module.task_store.list() if task['id']==task_id)
                if current['status'] not in ('running','waiting','dispatching'):return current
                await asyncio.sleep(.15)
            raise TimeoutError('Work native turn did not settle')

        try:
            transport=httpx.ASGITransport(app=module.app)
            async with httpx.AsyncClient(transport=transport,base_url='http://com-probe',
                                          headers={'Authorization':'Bearer '+module.TOKEN},timeout=180) as client:
                for agent in ('claude','codex'):
                    project=project_root/agent;project.mkdir()
                    artifact=project/'com-permission.txt'
                    first_marker='first-'+uuid.uuid4().hex
                    second_marker='second-'+uuid.uuid4().hex
                    first_prompt=('请在当前目录新建 com-permission.txt，只写一行 '+first_marker+
                                  '，末尾保留换行。然后读取这个文件，把读到的完整内容回复给我。')
                    started=time.monotonic();rid='manual-chat-'+agent+'-'+uuid.uuid4().hex
                    # A legacy UI value cannot reinstate the revoked permission.
                    body={'request_id':rid,'agent':agent,'cwd':str(project),'sandbox':'read-only','prompt':first_prompt}
                    phase=agent+'_first_create'
                    response=await client.post('/sessions',json=body)
                    assert response.status_code==200, 'Work create HTTP status '+str(response.status_code)
                    first=response.json();assert first['status']=='accepted' and first['submission_state']=='submitted',first
                    sid=first['sid'];meta=module.history.managed()[sid]
                    assert meta['cwd']==str(project), 'Selected cwd differs: '+meta['cwd']+' vs '+str(project)
                    assert meta['sandbox']=='danger-full-access' and not meta.get('workspace_copy'), 'Interactive full access incorrectly copied or changed sandbox'
                    task=next(task for task in module.task_store.list() if task.get('session_id')==sid)
                    assert task['interactive'] and task['authorization']['entry']=='work_page_human_chat', 'Work source entry mismatch'
                    assert not task.get('workspace_copy'), 'Work task unexpectedly has an isolated copy'
                    assert task['requested_sandbox']=='read-only', 'Requested permission audit was lost'
                    assert task['authorization']['source_quote']==first_prompt, 'Work quote differs from current human text'
                    with module.conversation.db() as db:
                        source=dict(db.execute('SELECT * FROM messages WHERE id=?',(task['origin_message_id'],)).fetchone())
                    assert source['role']=='user' and source['text']==body['prompt'] and source['request_id']=='work:'+rid, 'Human source row differs'
                    assert (await client.post('/sessions',json=body)).json()==first, 'Duplicate create receipt differs'
                    assert (await client.get('/receipts/'+rid)).json()==first, 'GET create receipt differs'
                    assert len(module.task_store.list())==len(cases)+1, 'Duplicate request created an extra task'
                    phase=agent+'_first_reply';first_task=await settled(task['id'])
                    assert first_task['status']=='execution_finished' and first_task['result'].strip(),first_task['status']
                    assert first_task['verification_status']=='pending'
                    assert artifact.is_file() and artifact.read_text()==first_marker+'\n','First native file write differs'
                    assert first_marker in first_task['result'],'First native reply lacks actual file content'
                    worker=runtime.workers.workers.get(sid)
                    native_id=worker.native_session if worker else meta['native_id']
                    assert native_id
                    # A historical restriction fixture is retained for audit; it
                    # is never represented as a new human message or replayed.
                    legacy='只读，不改文件'
                    task,_=module.task_store.change(task['id'],'proof-audit-'+uuid.uuid4().hex,
                        'proof.legacy_constraint',constraints=[*first_task.get('constraints',[]),legacy])
                    assert legacy in task['constraints'] and legacy in task['work_brief']['constraints_audit']
                    assert legacy not in task['work_brief']['constraints'],'Legacy restriction became effective again'
                    phase=agent+'_same_session_followup'
                    more={'request_id':'manual-follow-'+agent+'-'+uuid.uuid4().hex,
                          'text':('请在刚才的 com-permission.txt 末尾追加一行 '+second_marker+
                                  '，末尾保留换行，然后读取文件，把两行完整内容回复给我。')}
                    response=await client.post('/sessions/'+sid+'/input',json=more)
                    assert response.status_code==200, 'Work follow-up HTTP status '+str(response.status_code)
                    follow=response.json();assert follow['status']=='accepted' and follow['sid']==sid
                    assert follow.get('turn_id') and follow['turn_id']!=first['turn_id']
                    assert (await client.post('/sessions/'+sid+'/input',json=more)).json()==follow
                    assert (await client.get('/receipts/'+more['request_id'])).json()==follow
                    phase=agent+'_followup_reply';second_task=await settled(task['id'])
                    assert second_task['status']=='execution_finished'
                    expected=first_marker+'\n'+second_marker+'\n'
                    assert artifact.read_text()==expected,'Second native append/readback differs'
                    assert first_marker in second_task['result'] and second_marker in second_task['result'],'Follow-up lacks both readback lines'
                    assert legacy in second_task['constraints'],'Historical restriction audit was discarded'
                    new_native_id=worker.native_session if worker else module.history.managed()[sid]['native_id']
                    assert new_native_id==native_id
                    events=runtime.events(sid)
                    tool_events=[event for event in events if event.get('kind')=='tool.started' or
                                 (event.get('kind')=='item' and event.get('role')=='tool' and event.get('state')=='running')]
                    assert tool_events,'Actual native write/read tools were not observed'
                    assert sorted(path.name for path in project.iterdir())==['com-permission.txt'],'Unexpected fixture project files'
                    cases.append({'agent':agent,'http_create':response.status_code,'accepted':True,
                                  'first_reply':first_task['result'],'followup_reply':second_task['result'],
                                  'same_native_session':True,'duplicate_receipts_equal':True,'real_source_bound':True,
                                  'followup_without_task_acceptance':True,'workspace_copy':None,
                                  'requested_sandbox':'read-only','sandbox':meta['sandbox'],
                                  'legacy_readonly_retained_for_audit':True,'legacy_readonly_execution_effect':False,
                                  'first_file_write_verified':True,'second_append_and_readback_verified':True,
                                  'artifact':'com-permission.txt','artifact_sha256':hashlib.sha256(expected.encode()).hexdigest(),
                                  'native_tool_events':len(tool_events),'elapsed_ms':round((time.monotonic()-started)*1000)})
            shared_unchanged=all(hashlib.sha256((native_home/name).read_bytes()).hexdigest()==digest for name,digest in shared_hashes.items())
            assert shared_unchanged,'Shared native auth/config changed'
            output={'ok':True,'cases':cases,'native_codex_independent_port':port,'production_server_used':False,
                    'temporary_com_state':True,'temporary_workbench_home':True,'temporary_native_codex_sessions':True,
                    'shared_native_auth_linked':linked,'credentials_copied':False,
                    'shared_native_auth_config_unchanged':shared_unchanged,
                    'production_com_sessions_reused':False,'production_project_files_written':False,
                    'temporary_project_files_written':True,'real_two_turn_write_readback':True}
        except Exception as error:
            output={'ok':False,'phase':phase,'error_type':type(error).__name__,'cases':cases,
                    'temporary_com_state':True,'production_server_used':False,
                    'production_project_files_written':False,
                    'temporary_project_files_written':any(project_root.rglob('com-permission.txt'))}
            if isinstance(error,AssertionError):output['assertion']=str(error)[:500]
            with module.history.db() as db:
                output['receipt_states']=[json.loads(row[0]).get('status') for row in db.execute('SELECT data FROM receipts')]
        finally:
            await runtime.workers.close()
            if runtime.rpc:await runtime.rpc.close()
            if runtime.reader_task:
                runtime.reader_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):await runtime.reader_task
            if native.returncode is None:
                native.terminate()
                try:await asyncio.wait_for(native.wait(),10)
                except asyncio.TimeoutError:native.kill();await native.wait()
            for name,value in previous.items():
                if value is None:os.environ.pop(name,None)
                else:os.environ[name]=value
        return output


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--output');args=parser.parse_args()
    result=asyncio.run(run())
    if args.output:
        target=Path(args.output);target.write_text(json.dumps(result,ensure_ascii=False,indent=2));target.chmod(0o600)
    print(json.dumps(result,ensure_ascii=False))
    sys.exit(0 if result['ok'] else 1)
