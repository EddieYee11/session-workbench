"""Reproduce the real 09-05/1325 query blocked behind an uncertain prior write."""
import asyncio
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from agent_tools import AgentTools
from capabilities import CapabilityRegistry
from conversation import PersonalConversation
from goals import GoalEvents
from policy import bookkeeping_intent,bookkeeping_query
from task_tools import authorized_assignment
from tasks import TaskStore,TaskController,business_read_task,WorkerStartupFailure,WorkerInputRejected
from work_dispatch import WorkProposalStore

SOURCE='帮我找一下，我的九月五号消费了一千三百二十五，这是什么消费？'


class Worker:
    def __init__(self):self.calls=[]
    async def preflight_task(self,task):self.calls.append(('preflight',task['id']))
    async def create_task_worker(self,task):
        self.calls.append(('create',task['id'],task.get('execution_scope')));return 'pi:fixture-reader'
    async def input(self,sid,prompt,request):self.calls.append(('input',request));return 'reader-run'
    def events(self,sid):return [{'role':'assistant','kind':'item','turn_id':'reader-run','text':'实际只读查询完成：指定账目匹配'}]
    async def task_status(self,task):return 'completed'


def setup(tmp_path,source=SOURCE):
    chat=PersonalConversation(tmp_path)
    mid=chat.submit('query-1325-human-request',source)['message_id']
    with chat.db() as db:db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-personal-main')")
    context={'origin_session_id':'com-personal-main','origin_message_id':mid,'origin_request_id':'query-1325-human-request'}
    proposals=WorkProposalStore(tmp_path,tmp_path);store=TaskStore(tmp_path);worker=Worker()
    controller=TaskController(store,worker,chat)
    tools=AgentTools(tmp_path,chat,proposals,store,controller,CapabilityRegistry(tmp_path),GoalEvents(tmp_path))
    draft,authorization,key=authorized_assignment(chat,proposals,{**context,'request_id':'query-1325-task-request',
        'source_quote':source,'agent':'pi','relative_cwd':'.','sandbox':'danger-full-access',
        'title':'只读查账：9 月 5 日 1325 元是什么消费','prompt':'查询指定日期金额，返回真实结果',
        'completion_condition':'报告指定消费的分类与备注'})
    task=store.create_authorized(draft,authorization,key)
    store.ensure({'id':'old-topup-task','origin_message_id':'old-topup-source','title':'手机话费充值1元',
                  'agent':'pi','cwd':str(tmp_path),'sandbox':'danger-full-access','prompt':'记账'})
    store.change('old-topup-task','old-write-uncertain-request','execution_unknown',status='unknown',
                 authorization={'source_quote':'手机话费充值1元，记账'},session_id='pi:old-write',run_id='old-write-run')
    return tools,task,context,worker


@pytest.mark.parametrize('text',[SOURCE,'帮我找一下我9月5号消费了1325是什么消费'])
def test_lookup_question_is_query_and_never_new_expense(text):
    assert bookkeeping_query(text)
    assert not bookkeeping_intent(text)


def test_actual_query_shape_starts_despite_old_unknown_write_and_original_write_never_replays(tmp_path):
    tools,created,_,worker=setup(tmp_path)
    asyncio.run(tools.controller.start_queued())
    tasks={task['id']:task for task in tools.store.list()}
    reader=tasks[created['id']]
    assert reader['status']=='running' and reader['execution_scope']=='business-query'
    assert not reader.get('workspace_copy')
    assert tasks['old-topup-task']['status']=='unknown'
    assert [call for call in worker.calls if call[0]=='create']==[('create',created['id'],'business-query')]
    asyncio.run(tools.controller.poll())
    tasks={task['id']:task for task in tools.store.list()}
    assert tasks[created['id']]['status']=='execution_finished'
    assert tasks['old-topup-task']['status']=='unknown'


def test_real_writer_stays_blocked_with_visible_reason(tmp_path):
    tools,created,_,worker=setup(tmp_path,'帮我修改项目配置')
    assert not business_read_task(created)
    asyncio.run(tools.controller.start_queued())
    current=next(task for task in tools.store.list() if task['id']==created['id'])
    assert current['status']=='queued'
    assert '状态待核实' in current['block_reason'] and current['blocked_by']==['old-topup-task']
    assert not worker.calls


def test_read_label_from_model_cannot_turn_writing_source_into_read_scope(tmp_path):
    tools,task,_,_=setup(tmp_path,'帮我记账，手机话费充值1元')
    assert '只读查账' in task['title']
    assert not business_read_task(task)


def test_business_query_full_access_keeps_source_financial_intent_and_deletion_guards(tmp_path):
    from worker_runtime import WorkerRuntime
    tools,created,context,_=setup(tmp_path)
    asyncio.run(tools.controller.start_queued())
    task=next(item for item in tools.store.list() if item['id']==created['id'])
    worker=WorkerRuntime(SimpleNamespace(state=tmp_path,task_store=tools.store))
    native_context={**context,'task_id':task['id']}
    for tool,args in (('bookkeeping',{'action':'recent'}),('bookkeeping_search',{'date':'2026-09-05','amount':1325})):
        assert tools.authorize_tool({'tool':tool,'args':args},native_context)['authorized']
        worker.guard(task,tool,args)
    for tool,args in (('bash',{'command':'python arbitrary.py'}),('edit',{'path':'config','newText':'changed'})):
        assert tools.authorize_tool({'tool':tool,'args':args},native_context)['authorized']
        worker.guard(task,tool,args)
    with pytest.raises(ValueError):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':1325}},native_context)
    with pytest.raises(ValueError,match='不可逆'):
        worker.guard(task,'bash',{'command':'rm -rf project'})
    with pytest.raises(ValueError,match='真实用户消息'):
        tools.authorize_tool({'tool':'edit','args':{'path':'config','newText':'changed'}},
                             {**native_context,'origin_message_id':'invented'})


def test_pi_business_query_has_original_cwd_full_access_and_no_workspace_copy(tmp_path,monkeypatch):
    from history import History
    import worker_runtime
    state=tmp_path/'state';state.mkdir()
    history=History(tmp_path,state)
    runtime=SimpleNamespace(state=state,h=history,emit=lambda *args:None)
    workers=worker_runtime.WorkerRuntime(runtime)
    def copy(task):raise AssertionError('business query must not copy the whole workspace')
    monkeypatch.setattr(workers.copies,'prepare',copy)
    instances=[]
    prompts=[]
    class Pi:
        def __init__(self,*args,**kwargs):instances.append({'cwd':args[2],**kwargs})
        def bind(self,context):pass
        async def start(self):pass
        async def stream(self,text,request_id):
            prompts.append(text)
            yield 'input.accepted',{}
            yield 'run.completed',{}
    monkeypatch.setattr(worker_runtime,'PiRPC',Pi)
    task={'id':'readonly-business-task','agent':'pi','sandbox':'danger-full-access','cwd':str(tmp_path),
          'execution_scope':'business-read','title':'指定日期查账','workspace_copy':None}
    sid=asyncio.run(workers.create(task))
    assert sid.startswith('pi:com-') and not instances[0]['isolated'] and not instances[0]['readonly']
    assert history.managed()[sid]['workspace_copy'] is None
    assert instances[0]['cwd']==str(tmp_path)
    assert history.managed()[sid]['cwd']==str(tmp_path)
    asyncio.run(workers.input(sid,'查指定日期账目','read-query-request'))
    assert 'bookkeeping_search' in prompts[0] and 'Asia/Shanghai' in prompts[0] and '全量真实账本' in prompts[0]
    assert '[Com 业务查询]' in prompts[0] and '全程只读' not in prompts[0]


def test_prestart_failure_pauses_and_fresh_retry_keeps_original_claim_and_constraints(tmp_path):
    tools,created,_,worker=setup(tmp_path)
    tools.store.enqueue(created['id'],'只返回匹配的账目','reader-extra-constraint')
    original=worker.create_task_worker
    failures=2
    async def create(task):
        nonlocal failures
        if failures:
            failures-=1
            raise WorkerStartupFailure('RuntimeError','native_startup_failed','native_startup','pi:failed-reader')
        return await original(task)
    worker.create_task_worker=create
    for attempt in range(2):
        asyncio.run(tools.controller.start_queued())
        task=next(t for t in tools.store.list() if t['id']==created['id'])
        assert task['status']=='paused' and task['pause_phase']=='pre_start'
        assert not task['session_id'] and not task['run_id']
        assert task['startup_failure']['input_sent'] is False
        assert task['inputs'][0]['state']=='pending_start'
        assert not any(call[0]=='input' for call in worker.calls)
        asyncio.run(tools.controller.resume(created['id'],'resume-reader-attempt-'+str(attempt)))
    asyncio.run(tools.controller.start_queued())
    task=next(t for t in tools.store.list() if t['id']==created['id'])
    assert task['status']=='running' and task['dispatch_attempt']==2
    claims=[event['request_id'] for event in task['events'] if event['kind']=='dispatching']
    assert claims==['dispatch:'+created['id'],'dispatch:'+created['id']+':1','dispatch:'+created['id']+':2']
    assert task['inputs'][0]['state']=='delivered'
    assert next(t for t in tools.store.list() if t['id']=='old-topup-task')['status']=='unknown'


def test_input_failure_remains_unknown_and_never_uses_prestart_recovery(tmp_path):
    tools,created,_,worker=setup(tmp_path)
    async def input(sid,prompt,request):
        raise WorkerStartupFailure('RuntimeError','native_startup_failed')
    worker.input=input
    asyncio.run(tools.controller.start_queued())
    task=next(t for t in tools.store.list() if t['id']==created['id'])
    assert task['status']=='unknown' and task['session_id']=='pi:fixture-reader'
    assert task['startup_phase']=='delivery_unknown'
    with pytest.raises(ValueError,match='不能重放'):
        asyncio.run(tools.controller.resume(created['id'],'unsafe-reader-resume'))


def test_affirmative_native_preflight_rejection_pauses_original_task_without_unknown_replay(tmp_path):
    tools,created,_,worker=setup(tmp_path)
    async def input(sid,prompt,request):raise WorkerInputRejected('auth_lock_permission_denied',sid)
    worker.input=input
    asyncio.run(tools.controller.start_queued())
    task=next(t for t in tools.store.list() if t['id']==created['id'])
    assert task['status']=='paused' and task['startup_phase']=='native_prompt_rejected'
    assert not task['session_id'] and not task['run_id']
    assert task['startup_failure']['input_sent'] is True
    assert task['startup_failure']['input_delivered'] is False
    assert task['startup_failure']['worker_session_id']=='pi:fixture-reader'
    assert any(event['kind']=='worker.input_rejected' for event in task['events'])
    asyncio.run(tools.controller.resume(created['id'],'resume-rejected-reader'))
    assert next(t for t in tools.store.list() if t['id']==created['id'])['dispatch_attempt']==1
    assert next(t for t in tools.store.list() if t['id']=='old-topup-task')['status']=='unknown'


@pytest.mark.parametrize('uncertain,started,expected',[(False,False,WorkerInputRejected),(True,False,RuntimeError),(False,True,RuntimeError)])
def test_worker_accepts_only_no_start_affirmative_native_rejection(tmp_path,uncertain,started,expected):
    import worker_runtime
    from history import History
    history=History(tmp_path,tmp_path)
    runtime=SimpleNamespace(state=tmp_path,h=history,emit=lambda *args:None,events=lambda sid:[])
    workers=worker_runtime.WorkerRuntime(runtime)
    history.save_managed('pi:rejected-fixture',{'agent':'pi'})
    stopped=[]
    class Pi:
        async def stream(self,text,request_id):
            yield 'error',{'uncertain':uncertain,'native_rejection':True,'delivery':'not_sent',
                          'reason_code':'auth_lock_permission_denied','native_started':started}
        async def stop(self):stopped.append(True)
    workers.workers['pi:rejected-fixture']=Pi();workers.statuses['pi:rejected-fixture']='ready'
    with pytest.raises(expected) as error:
        asyncio.run(workers.input('pi:rejected-fixture','查询指定账目','rejection-worker-request'))
    if expected is WorkerInputRejected:
        assert error.value.details['input_delivered'] is False and stopped==[True]
        assert history.managed()['pi:rejected-fixture']['ended']
    else:
        assert not isinstance(error.value,WorkerInputRejected) and not stopped


def test_worker_startup_error_is_typed_and_does_not_persist_raw_secret(tmp_path,monkeypatch):
    from history import History
    import worker_runtime
    state=tmp_path/'state';state.mkdir()
    history=History(tmp_path,state)
    workers=worker_runtime.WorkerRuntime(SimpleNamespace(state=state,h=history,emit=lambda *args:None))
    class Pi:
        def __init__(self,*args,**kwargs):pass
        def bind(self,context):pass
        async def start(self):raise RuntimeError('private-token-in-stderr')
    monkeypatch.setattr(worker_runtime,'PiRPC',Pi)
    task={'id':'failed-read-task','agent':'pi','cwd':str(tmp_path),'sandbox':'danger-full-access',
          'execution_scope':'business-read','workspace_copy':None}
    with pytest.raises(WorkerStartupFailure) as error:asyncio.run(workers.create(task))
    assert error.value.details['input_sent'] is False and error.value.details['phase']=='native_startup'
    meta=next(iter(history.managed().values()))
    assert meta['ended'] and meta['startup_failure']['error_type']=='RuntimeError'
    assert 'private-token' not in str(error.value) and 'private-token' not in str(meta)


def test_main_read_tool_uses_true_source_without_keyword_permission_gate(tmp_path):
    tools,_,_,_=setup(tmp_path)
    mid=tools.conversation.submit('main-read-capability-question','这是什么消费？')['message_id']
    context={'origin_session_id':'com-personal-main','origin_message_id':mid,'origin_request_id':'main-read-capability-question'}
    assert tools.authorize_tool({'tool':'bookkeeping','args':{'action':'recent'}},context)['authorized']
    assert tools.authorize_tool({'tool':'read','args':{'path':'project/file'}},context)['authorized']
    with pytest.raises(ValueError):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':1325}},context)


def test_search_entry_checks_real_source_and_business_scope(tmp_path,monkeypatch):
    import bookkeeping_search
    tools,created,context,_=setup(tmp_path)
    asyncio.run(tools.controller.start_queued())
    calls=[]
    async def search(args,state):calls.append(args);return {'read_only':True,'items':[{'amount':1325,'comment':'fixture'}]}
    monkeypatch.setattr(bookkeeping_search,'search',search)
    result=asyncio.run(tools.call('bookkeeping_search',{'date':'2026-09-05','amount':1325},{**context,'task_id':created['id']}))
    assert result['read_only'] and len(calls)==1
    with pytest.raises(ValueError,match='真实用户消息'):
        asyncio.run(tools.call('bookkeeping_search',{'date':'2026-09-05','amount':1325},
                               {**context,'origin_message_id':'invented-source'}))
