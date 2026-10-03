"""Product state-machine tests: no credentials, model requests or worker processes."""
import asyncio
import sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tasks import TaskStore, TaskController
from conversation import PersonalConversation
from task_tools import record_constraint
from runtime import Runtime
from history import History
from work_dispatch import WorkProposalStore


class ControlledWorker:
    def __init__(self, support=True, response='delivered'):
        self.support=support;self.response=response;self.calls=[];self.observation=None
    def task_capabilities(self,task):return {'steer':self.support}
    async def status(self,sid):return 'running'
    def events(self,sid):return []
    def task_input_state(self,task,key):return self.observation
    async def deliver_task_input(self,task,command):
        self.calls.append((task['id'],task['run_id'],command['request_id'],command['text']))
        if isinstance(self.response,Exception):raise self.response
        return {'state':self.response}


def setup(tmp_path,worker=None):
    store=TaskStore(tmp_path);chat=PersonalConversation(tmp_path)
    store.ensure(dict(id='task-A',origin_message_id='source-A',title='A',agent='codex',cwd=str(tmp_path),prompt='inspect',sandbox='read-only'))
    store.change('task-A','start-task-A','started',status='running',session_id='session-A',run_id='native-turn-A',authorization={'sandbox':'read-only','cwd':str(tmp_path),'prompt':'inspect'})
    return store,TaskController(store,worker or ControlledWorker(),chat)


def test_mcp_old_readonly_restriction_is_audit_only_and_never_delivered(tmp_path):
    worker=ControlledWorker();store,controller=setup(tmp_path,worker)
    result=record_constraint(store,'task-A','', 'restrict-readonly-01','read_only')
    assert result['delivery']=='revoked' and not result['work_started']
    assert store.list()[0]['inputs'][0]['state']=='revoked'
    asyncio.run(controller.poll());asyncio.run(controller.poll())
    assert not worker.calls
    assert store.list()[0]['constraints']==['只读约束：不要修改、删除、发布或外发任何内容。']
    assert store.list()[0]['events'][-1]['kind']=='input_revoked'
    assert record_constraint(store,'task-A','', 'restrict-readonly-01','read_only')['delivery']=='revoked'


def test_mcp_note_cannot_authorize_new_actions(tmp_path):
    worker=ControlledWorker();store,controller=setup(tmp_path,worker)
    assert record_constraint(store,'task-A','发布并删除旧版本','unsafe-note-0001')['delivery']=='blocked_authorization'
    assert record_constraint(store,'task-A','read_only','typed-note-0001','note')['delivery']=='blocked_authorization'
    asyncio.run(controller.poll())
    assert not worker.calls
    assert store.list()[0]['inputs'][0]['state']=='blocked_authorization'
    with pytest.raises(ValueError):record_constraint(store,'task-A','../../outside','bad-path-0001','forbid_path')
    assert record_constraint(store,'task-A','proxy.conf','safe-path-0001','forbid_path')['delivery']=='queued'


@pytest.mark.parametrize('agent', ['pi','codex'])
def test_unsupported_is_terminal_visible_not_permanent_pending(tmp_path,agent):
    worker=ControlledWorker(support=False);store,controller=setup(tmp_path,worker)
    store.change('task-A','agent-change-001','agent_selected',agent=agent)
    record_constraint(store,'task-A','', 'unsupported-0001','preserve_style')
    asyncio.run(controller.poll());asyncio.run(controller.poll())
    assert not worker.calls
    assert store.list()[0]['inputs'][0]['state']=='unsupported'
    assert store.list()[0]['events'][-1]['kind']=='input_unsupported'
    assert not store.pending_inputs()


@pytest.mark.parametrize('failure,state',[(ValueError('rejected'),'failed'),(TimeoutError(),'unknown')])
def test_worker_failure_is_recorded_and_never_replayed(tmp_path,failure,state):
    worker=ControlledWorker(response=failure);store,controller=setup(tmp_path,worker)
    first=asyncio.run(controller.command('task-A','constraint','request-failure-01'))
    assert first['delivery']==state
    assert asyncio.run(controller.command('task-A','constraint','request-failure-01'))['delivery']==state
    asyncio.run(controller.poll())
    assert len(worker.calls)==1
    assert store.list()[0]['inputs'][0]['state']==state
    with pytest.raises(ValueError):asyncio.run(controller.command('task-A','different','request-failure-01'))


def test_rpc_queue_ack_is_not_delivery(tmp_path):
    worker=ControlledWorker(response='worker_queued');store,controller=setup(tmp_path,worker)
    assert asyncio.run(controller.command('task-A','constraint','rpc-queued-0001'))['delivery']=='worker_queued'
    asyncio.run(controller.poll())
    assert store.list()[0]['inputs'][0]['state']=='worker_queued'
    worker.observation='delivered';asyncio.run(controller.poll())
    assert store.list()[0]['inputs'][0]['state']=='delivered'
    assert len(worker.calls)==1


def test_restart_after_claim_preserves_unknown_no_replay(tmp_path):
    worker=ControlledWorker();store,controller=setup(tmp_path,worker)
    store.enqueue('task-A','constraint','crash-input-0001')
    assert store.transition_input('crash-input-0001',('queued',),'sending')
    store.recover()
    reopened=TaskStore(tmp_path)
    asyncio.run(TaskController(reopened,worker,controller.conversation).poll())
    assert reopened.list()[0]['inputs'][0]['state']=='unknown'
    assert reopened.list()[0]['status']=='unknown'
    assert not worker.calls


def test_restart_before_delivery_blocks_unknown_execution(tmp_path):
    worker=ControlledWorker();store,controller=setup(tmp_path,worker)
    store.enqueue('task-A','constraint','before-crash-0001');store.recover()
    asyncio.run(controller.poll())
    assert store.list()[0]['inputs'][0]['state']=='blocked_state'
    assert not worker.calls


def test_codex_adapter_checks_native_ack_and_original_scope(tmp_path):
    runtime=Runtime(History(tmp_path,tmp_path/'state'),'fixture')
    runtime.h.save_managed('codex:thread-A',{'sid':'codex:thread-A','native_id':'thread-A','agent':'codex','ended':False})
    calls=[]
    async def call(method,params):calls.append((method,params));return {'turnId':'native-A'}
    runtime.call=call
    task={'agent':'codex','session_id':'codex:thread-A','run_id':'native-A'}
    command={'text':'do not edit proxy.conf'}
    assert asyncio.run(runtime.deliver_task_input(task,command))['state']=='delivered'
    assert calls[0][0]=='turn/steer'
    assert calls[0][1]['threadId']=='thread-A' and calls[0][1]['expectedTurnId']=='native-A'
    assert 'full access' in calls[0][1]['input'][0]['text']
    assert 'Do not invent actions or repeat uncertain operations' in calls[0][1]['input'][0]['text']
    async def wrong(method,params):return {'turnId':'another-turn'}
    runtime.call=wrong
    assert asyncio.run(runtime.deliver_task_input(task,command))['state']=='unknown'


def test_pi_task_waits_for_settled_and_manual_status_unchanged(tmp_path):
    runtime=Runtime(History(tmp_path,tmp_path/'state'),'fixture')
    task={'agent':'pi','session_id':'pi:A'}
    events=[{'type':'agent_start'},{'type':'agent_end'}]
    async def status(sid):return 'completed'
    runtime.status=status;runtime.events=lambda sid:events
    assert not runtime.task_capabilities(task)['steer']
    assert asyncio.run(runtime.task_status(task))=='running'
    events.extend([{'type':'message_end','data':{'message':{'role':'assistant','stopReason':'aborted'}}},{'type':'agent_settled'}])
    assert asyncio.run(runtime.task_status(task))=='interrupted'


def test_fixed_tool_intents_A_B_update_A_smalltalk(tmp_path):
    # Fixed tool-call decisions isolate product behavior from unapproved model inference.
    project=tmp_path/'project';project.mkdir()
    proposals=WorkProposalStore(tmp_path,tmp_path)
    store=TaskStore(tmp_path);chat=PersonalConversation(tmp_path);worker=ControlledWorker()
    source_A=chat.submit('request-intent-A','请检查项目 A')['message_id']
    source_B=chat.submit('request-intent-B','请检查项目 B')['message_id']
    def propose(mid,key,title):
        card=proposals.propose(agent='codex',relative_cwd='project',title=title,prompt='inspect only',sandbox='read-only',reason='explicit assignment',origin_message_id=mid,idempotency_key=key)
        store.ensure(card)
        return card
    A=propose(source_A,'intent-proposal-A','A');B=propose(source_B,'intent-proposal-B','B')
    assert propose(source_A,'intent-proposal-A','A')['id']==A['id']
    store.change(A['id'],'authorized-intent-A','started',status='running',session_id='A',run_id='turn-A',authorization={'sandbox':'read-only'})
    record_constraint(store,A['id'],'proxy.conf','intent-update-A-01','forbid_path')
    chat.submit('request-smalltalk','谢谢，今天真不错') # no tool decision
    asyncio.run(TaskController(store,worker,chat).poll())
    assert len(store.list())==2
    assert len(worker.calls)==1 and worker.calls[0][0]==A['id']
    tasks={t['id']:t for t in store.list()}
    assert tasks[A['id']]['message_id']==source_A and tasks[B['id']]['message_id']==source_B
    assert len(tasks[A['id']]['constraints'])==1 and not tasks[B['id']]['constraints']
    with pytest.raises(ValueError):record_constraint(store,'ambiguous-reference','', 'ambiguous-0001','read_only')


def test_queue_confirmation_timeout_does_not_silently_wait(tmp_path):
    worker=ControlledWorker(response='worker_queued');store,controller=setup(tmp_path,worker)
    asyncio.run(controller.command('task-A','constraint','queue-timeout-0001'))
    with store.db() as db:db.execute('UPDATE inputs SET updated_at=0')
    asyncio.run(controller.poll());asyncio.run(controller.poll())
    assert store.list()[0]['inputs'][0]['state']=='unknown'
    assert len(worker.calls)==1


def test_codex_terminal_is_scoped_to_original_turn(tmp_path):
    runtime=Runtime(History(tmp_path,tmp_path/'state'),'fixture')
    async def status(sid):return 'completed'
    runtime.status=status
    runtime.events=lambda sid:[{'kind':'status','status':'running','turn_id':'A'},
        {'kind':'status','status':'completed','turn_id':'B'}]
    assert asyncio.run(runtime.task_status({'agent':'codex','session_id':'s','run_id':'A'}))=='running'
    runtime.events=lambda sid:[{'kind':'status','status':'completed','turn_id':'A'},
        {'kind':'status','status':'running','turn_id':'B'}]
    assert asyncio.run(runtime.task_status({'agent':'codex','session_id':'s','run_id':'A'}))=='completed'


def test_final_results_exclude_deltas_tools_and_other_turns():
    from tasks import worker_result
    assert worker_result([{'kind':'delta','role':'assistant','text':'partial'},
        {'kind':'item','role':'tool','text':'shell output'},
        {'kind':'item','role':'assistant','id':'answer','text':'final','turn_id':'A'},
        {'kind':'item','role':'assistant','text':'other','turn_id':'B'}],'A')=='final'
    assert worker_result([{'type':'message_end','data':{'message':{'role':'assistant',
        'content':[{'type':'thinking','thinking':'private'},{'type':'text','text':'Pi final'}]}}}])=='Pi final'
    assert worker_result([{'kind':'item','role':'assistant','id':'progress','text':'I will inspect'},
                          {'kind':'item','role':'assistant','id':'answer','text':'Observed two files'}])=='Observed two files'
