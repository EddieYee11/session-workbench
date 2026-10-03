import asyncio
import json
import sqlite3
from pathlib import Path
import pytest
from archives import Archives
from claude_worker import ClaudeBudget
from execution_boundary import require_host,sandbox
from verification import verify

def tool_service(tmp_path,text):
    from conversation import PersonalConversation
    from work_dispatch import WorkProposalStore
    from tasks import TaskStore,TaskController
    from capabilities import CapabilityRegistry
    from goals import GoalEvents
    from agent_tools import AgentTools
    from types import SimpleNamespace
    chat=PersonalConversation(tmp_path)
    message=chat.submit('human-authorized-001',text)
    with chat.db() as db:db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-personal-main')")
    store=TaskStore(tmp_path);controller=TaskController(store,SimpleNamespace(action_lock=asyncio.Lock()),chat)
    service=AgentTools(tmp_path,chat,WorkProposalStore(tmp_path,tmp_path),store,controller,CapabilityRegistry(tmp_path),GoalEvents(tmp_path))
    context={'origin_message_id':message['message_id'],'origin_request_id':'human-authorized-001','origin_session_id':'com-personal-main'}
    return service,context


def test_write_ack_loss_blocks_repeated_side_effect(tmp_path):
    service,context=tool_service(tmp_path,'午饭 30 元，记一下')
    args={'tool':'bookkeeping','args':{'action':'add','amount':30,'note':'午饭'},'tool_call_id':'first'}
    assert service.authorize_tool(args,context)['authorized']
    # Process disappears after actual write but before the result event. Never retry.
    with pytest.raises(ValueError,match='禁止重复'):service.authorize_tool(dict(args,tool_call_id='second'),context)
    with sqlite3.connect(service.path) as db:assert db.execute('SELECT state FROM effects').fetchone()[0]=='uncertain'


@pytest.mark.parametrize('write_copy',[False,True])
def test_goal_can_advance_after_acceptance_but_never_repeats_pending_work(tmp_path,write_copy):
    text='帮我检查项目文件，再检查项目目录'
    service,context=tool_service(tmp_path,text)
    (tmp_path/'project').mkdir()
    goal=service.goals.upsert({'request_id':'goal-steps-001','title':'项目检查',
        'next_step':'检查文件','completion_condition':'两项检查通过'},context)
    args={'request_id':'goal-files-001','title':'检查文件','prompt':'只读检查项目文件',
        'agent':'codex','relative_cwd':'project','sandbox':'read-only','source_quote':text,
        'completion_condition':'看到文件清单','goal_id':goal['id']}
    first=asyncio.run(service.call('task_submit',args,context))
    assert asyncio.run(service.call('task_submit',args,context))['task_id']==first['task_id']
    next_args={**args,'request_id':'goal-dirs-001','title':'检查目录'}
    with pytest.raises(ValueError,match='已有'):asyncio.run(service.call('task_submit',next_args,context))
    if write_copy:
        service.store.change(first['task_id'],'goal-copy-fixture','workspace.isolated',workspace_copy=str(tmp_path/'copy'),run_id='goal-run-001')
    service.store.finish(first['task_id'],'execution_finished','实际清单')
    with pytest.raises(ValueError,match='已有'):asyncio.run(service.call('task_submit',next_args,context))
    service.store.verify(first['task_id'],[{'reference':'fixture://actual-list'}])
    if write_copy:
        with pytest.raises(ValueError,match='已有'):asyncio.run(service.call('task_submit',next_args,context))
        service.store.change(first['task_id'],'goal-merge-fixture','workspace.merged',merged_run_id='goal-run-001')
    second=asyncio.run(service.call('task_submit',next_args,context))
    assert second['task_id']!=first['task_id']


@pytest.mark.parametrize('text',['请查一下最近午饭 30 元的记账','帮我记一下午饭，没有金额'])
def test_query_and_missing_amount_cannot_add_bookkeeping(tmp_path,text):
    service,context=tool_service(tmp_path,text)
    with pytest.raises(ValueError):service.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':30}},context)


def test_removals_are_recoverable_only_inside_independent_copy(tmp_path):
    from policy import recoverable_remove
    copy=tmp_path/'copy';copy.mkdir()
    assert recoverable_remove('bash',{'command':'rm -rf build'},copy)
    for command in ('rm -rf ..','rm -rf .','rm x; curl example.com','rm /Users/eddiegao/live','rm *.txt','dd if=/dev/zero of=disk'):
        assert not recoverable_remove('bash',{'command':command},copy)


def test_unknown_task_has_structured_uncertain_result(tmp_path):
    from tasks import TaskStore
    store=TaskStore(tmp_path)
    with store.db() as db:store._save(db,{'id':'unknown','status':'unknown','verification_status':'uncertain'})
    result=store.list()[0]['structured_result']
    assert result['uncertain'] and result['execution_status']=='unknown'


def test_sdk_shutdown_and_result_cleanup_close_client_once(tmp_path):
    from claude_worker import ClaudeWorker
    async def run():
        worker=ClaudeWorker(tmp_path,{'id':'close'},lambda _:None,None)
        class Client:
            count=0
            async def disconnect(self):
                self.count+=1
                await asyncio.sleep(.01)
        client=Client();worker.client=client
        await asyncio.gather(worker.disconnect(),worker.disconnect(),worker.stop())
        assert client.count==1 and worker.client is None
    asyncio.run(run())


def test_destructive_commands_require_exact_approved_action(tmp_path):
    from policy import deletion_risk
    from worker_runtime import WorkerRuntime
    command={'command':'curl -X DELETE https://example.invalid/item/1'}
    task={'sandbox':'workspace-write','cwd':str(tmp_path),'workspace_copy':str(tmp_path),
          'authorization':{'actual_action':{'tool':'Bash','args':command}}}
    assert deletion_risk('bash',command)
    WorkerRuntime.guard(None,task,'Bash',command)
    with pytest.raises(ValueError):WorkerRuntime.guard(None,task,'Bash',{'command':'curl -X DELETE https://example.invalid/item/2'})
    assert deletion_risk('bash',{'command':'mv new old'})


def test_archive_ack_loss_reconciles_and_restore_does_not_overwrite(tmp_path):
    state=tmp_path/'state';state.mkdir();project=tmp_path/'project';project.mkdir()
    target=project/'old';target.mkdir();(target/'data').write_text('original')
    archive=Archives(state,project)
    result=archive.archive('old','req-archive','user-1')
    with sqlite3.connect(archive.path) as db:
        result['status']='uncertain'
        db.execute('UPDATE archives SET data=? WHERE id=?',(json.dumps(result),result['id']))
    reconciled=archive.archive('old','req-archive','user-1')
    assert reconciled['status']=='archived' and not target.exists()
    assert Path(reconciled['destination'],'data').read_text()=='original'
    target.mkdir()
    with pytest.raises(ValueError,match='不覆盖'):archive.restore(result['id'])
    target.rmdir()
    assert archive.restore(result['id'])['status']=='restored'
    assert archive.restore(result['id'])['status']=='restored'
    assert (target/'data').read_text()=='original'


def test_manual_claude_tasks_do_not_consume_automatic_daily_budget(tmp_path):
    budget=ClaudeBudget(tmp_path)
    for n in range(5):budget.claim('manual-'+str(n),False)
    for n in range(3):budget.claim('auto-'+str(n))
    with pytest.raises(ValueError,match='三次'):budget.claim('fourth-auto')


def test_known_token_budget_stops_resume(tmp_path,monkeypatch):
    monkeypatch.setenv('COM_CLAUDE_TOKEN_LIMIT','10')
    budget=ClaudeBudget(tmp_path);budget.claim('one')
    budget.record('one',1,{'input_tokens':10,'output_tokens':2})
    with pytest.raises(ValueError,match='Token'):budget.claim('one')


def test_host_boundary_rejects_other_machine(tmp_path):
    (tmp_path/'agent-config.json').write_text(json.dumps({'execution_host':'other-machine.invalid'}))
    with pytest.raises(ValueError,match='主机'):require_host(tmp_path)


def test_acceptance_requires_real_evidence_and_cannot_use_prose(tmp_path):
    task={'status':'execution_finished','cwd':str(tmp_path),'id':'check'}
    with pytest.raises(ValueError):asyncio.run(verify(task,[{'type':'completed','text':'完成'}],tmp_path))
    (tmp_path/'output').write_text('wrong')
    with pytest.raises(ValueError):asyncio.run(verify(task,[{'type':'file_contains','path':'output','value':'expected'}],tmp_path))
    with pytest.raises(ValueError):asyncio.run(verify(task,[{'type':'file_exists','path':'../escape'}],tmp_path))


def test_os_sandbox_blocks_writes_outside_copy(tmp_path):
    # Paths outside temporary root prove the filesystem boundary, not a command regex.
    import subprocess,sys,tempfile
    if sys.platform!='darwin':pytest.skip('macOS sandbox')
    state=tmp_path/'state';state.mkdir();copy=tmp_path/'copy';copy.mkdir()
    outside=Path.home()/('.com-sandbox-probe-'+next(tempfile._get_candidate_names()))
    script='from pathlib import Path; Path('+repr(str(outside))+').write_text("blocked")'
    result=subprocess.run(sandbox([sys.executable,'-c',script],state,copy),capture_output=True)
    try:
        assert result.returncode!=0 and not outside.exists()
    finally:
        outside.unlink(missing_ok=True)


def test_main_can_run_adb_without_creating_worker(tmp_path):
    service,context=tool_service(tmp_path,'无线调试连接我的手机 192.0.2.10:40247，把 Shizuku 服务启动起来\n```')
    assert service.authorize_tool({'tool':'bash','args':{'command':'adb connect 192.0.2.10:40247'},'tool_call_id':'adb-connect'},context)['authorized']
    assert service.store.list()==[]


def test_main_edit_preserves_original_for_recovery(tmp_path):
    service,context=tool_service(tmp_path,'帮我修好项目里的配置')
    target=tmp_path/'config.txt';target.write_text('original')
    assert service.authorize_tool({'tool':'edit','args':{'path':str(target),'oldText':'original','newText':'fixed'},'tool_call_id':'edit'},context)['authorized']
    records=list((tmp_path/'main-write-recovery').glob('*.json'))
    assert len(records)==1
    data=json.loads(records[0].read_text())
    assert Path(data['backup']).read_text()=='original'
    assert data['origin_message_id']==context['origin_message_id']


def test_main_shell_removal_still_requires_concrete_approval(tmp_path):
    service,context=tool_service(tmp_path,'帮我删除旧文件')
    with pytest.raises(ValueError,match='具体批准'):
        service.authorize_tool({'tool':'bash','args':{'command':'rm -rf old'},'tool_call_id':'delete'},context)


@pytest.mark.parametrize('prior,allowed',[
    ('无线调试我的手机，把 Shizuku 跑起来',True),
    ('最近不想折腾手机',False),
    ('引用：\n> 无线调试我的手机',False),
])
def test_option_reply_has_real_context_and_never_grants_from_wishes(tmp_path,prior,allowed):
    from policy import source
    service,context=tool_service(tmp_path,prior)
    with service.conversation.db() as db:
        t=db.execute('SELECT created_at FROM messages WHERE id=?',(context['origin_message_id'],)).fetchone()[0]
        db.execute("INSERT INTO messages(id,parent_id,role,text,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",('assistant-choice',context['origin_message_id'],'assistant','A 连无线调试把 Shizuku 激活\nB 检查命令报错原因','completed',t+1,t+1))
        db.execute("INSERT INTO messages(id,request_id,role,text,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",('reply','reply-request-001','user','a 192.0.2.10:40247','pending',t+2,t+2))
    follow={**context,'origin_message_id':'reply','origin_request_id':'reply-request-001'}
    row=source(service.conversation,follow)
    args={'tool':'bash','args':{'command':'adb connect 192.0.2.10:40247'},'tool_call_id':'context-adb'}
    if allowed:
        assert row['authorization_parent_message_id']==context['origin_message_id']
        assert service.authorize_tool(args,follow)['authorized']
        task=asyncio.run(service.call('task_submit',{'agent':'pi','relative_cwd':'.','title':'连接手机','prompt':'连接并验证 Shizuku','sandbox':'danger-full-access','completion_condition':'回读服务状态','source_quote':row['raw_text'],'request_id':'optional-pi-worker-001'},follow))
        assert task['task_id']
    else:
        with pytest.raises(ValueError):service.authorize_tool(args,follow)
