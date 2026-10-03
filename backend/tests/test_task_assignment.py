"""Human-source assignment, durable dispatch and exact-run control; no real models."""
import asyncio
import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conversation import PersonalConversation
from work_dispatch import WorkProposalStore
from tasks import TaskStore, TaskController
from task_tools import authorized_assignment, record_constraint
from runtime import Runtime
from history import History


def source(tmp_path, text='帮我检查项目文件数量，另外帮我检查项目目录数量'):
    project=tmp_path/'project';project.mkdir(exist_ok=True)
    chat=PersonalConversation(tmp_path)
    message=chat.submit('human-request-001', text)['message_id']
    with chat.db() as db:
        db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-personal-main')")
    proposals=WorkProposalStore(tmp_path,tmp_path)
    return chat,proposals,message


def assignment(chat, proposals, mid, quote, key, agent='codex', sandbox='read-only', **options):
    return authorized_assignment(chat, proposals, dict(
        agent=agent,relative_cwd='project',title=quote,prompt='Inspect the project only.',
        sandbox=sandbox,completion_condition='Report observed counts.',source_quote=quote,
        origin_session_id='com-personal-main',origin_message_id=mid,
        origin_request_id='human-request-001',request_id=key, **options))


class Worker:
    def __init__(self):self.calls=[];self.gate=None
    async def create(self, agent, cwd, **options):
        self.calls.append(('create',agent,cwd,options));return 'codex:worker-'+str(len(self.calls))
    async def input(self,sid,prompt,request_id):
        self.calls.append(('input',sid,prompt,request_id))
        if self.gate:await self.gate.wait()
        return 'turn-'+request_id
    async def task_status(self,task):return 'running'
    def events(self,sid):return []
    def task_capabilities(self,task):return {'steer':True}
    async def deliver_task_input(self,task,command):
        self.calls.append(('steer',task['id'],command['text']));return {'state':'delivered'}


def test_two_direct_tasks_update_old_task_no_third_and_no_main_chat_wait(tmp_path):
    async def scenario():
        chat,proposals,mid=source(tmp_path);store=TaskStore(tmp_path);worker=Worker()
        a=store.create_authorized(*assignment(chat,proposals,mid,'帮我检查项目文件数量','assignment-A-001'))
        b=store.create_authorized(*assignment(chat,proposals,mid,'帮我检查项目目录数量','assignment-B-001'))
        assert store.create_authorized(*assignment(chat,proposals,mid,'帮我检查项目文件数量','assignment-A-001'))['id']==a['id']
        update=record_constraint(store,a['id'],'','preserve-style-001','preserve_style')
        assert update['delivery']=='pending_start'
        worker.gate=asyncio.Event()
        controller=TaskController(store,worker,chat)
        starting=asyncio.create_task(controller.poll())
        for _ in range(20):
            if len(worker.calls)==2:break
            await asyncio.sleep(0)
        # The worker is blocked; main chat still durably accepts another message immediately.
        assert chat.submit('smalltalk-request-001','谢谢，今天不错')['status']=='accepted'
        assert len(store.list())==2
        worker.gate.set();await starting
        worker.gate=None;await controller.poll()
        tasks={t['id']:t for t in store.list()}
        assert tasks[a['id']]['status']==tasks[b['id']]['status']=='running'
        assert tasks[a['id']]['inputs'][0]['state']=='delivered'
        prompts=[c[2] for c in worker.calls if c[0]=='input']
        assert '保持现有界面样式' in prompts[0] and '保持现有界面样式' not in prompts[1]
        assert all('用户明确交办原文' in p for p in prompts)
    asyncio.run(scenario())


@pytest.mark.parametrize('text,quote',[('最近不想折腾界面','最近不想折腾界面'),('我想把网站做起来','我想把网站做起来'),('请删除项目旧文件','请删除项目旧文件')])
def test_smalltalk_wishes_and_consequential_actions_do_not_auto_authorize(tmp_path,text,quote):
    chat,proposals,mid=source(tmp_path,text)
    with pytest.raises(ValueError):assignment(chat,proposals,mid,quote,'assignment-denied-001')


def test_pi_capability_assignment_is_auto_authorized(tmp_path):
    # Eddie 2026-10-02：清单里的 Pi 能力（记账等）属免审批直达，不再要求先提审批卡。
    chat,proposals,mid=source(tmp_path,'帮我记账，记一笔 30 元午饭')
    task,authorization,request_id=assignment(
        chat,proposals,mid,'帮我记账，记一笔 30 元午饭','assignment-pi-001',
        agent='pi',sandbox='danger-full-access')
    assert task['agent']=='pi' and task['sandbox']=='danger-full-access'
    assert authorization['source_quote']=='帮我记账，记一笔 30 元午饭' and request_id=='assignment-pi-001'


def test_pi_legacy_readonly_request_is_upgraded_to_full_access(tmp_path):
    chat,proposals,mid=source(tmp_path,'帮我记账')
    task,authorization,_=assignment(chat,proposals,mid,'帮我记账','assignment-pi-002',agent='pi',sandbox='read-only')
    assert task['sandbox']==authorization['sandbox']=='danger-full-access'
    assert task['requested_sandbox']=='read-only'


def test_unknown_agent_is_rejected(tmp_path):
    chat,proposals,mid=source(tmp_path,'帮我记账')
    with pytest.raises(ValueError,match='pi or codex'):
        assignment(chat,proposals,mid,'帮我记账','assignment-pi-003',agent='pi-hermes',sandbox='danger-full-access')


def test_publishing_is_now_auto_authorized(tmp_path):
    # 政策变更（Eddie 2026-10-02）：发布/外发不再前置拦截，唯一闸门是不可逆删除。
    chat,proposals,mid=source(tmp_path,'帮我发布这条视频')
    task,_,_=assignment(chat,proposals,mid,'帮我发布这条视频','assignment-publish-001')
    assert task['agent']=='codex'


def test_deletion_still_requires_a_concrete_proposal(tmp_path):
    chat,proposals,mid=source(tmp_path,'请删除项目里的旧文件')
    with pytest.raises(ValueError,match='approval proposal'):
        assignment(chat,proposals,mid,'请删除项目里的旧文件','assignment-delete-001')


def test_task_source_must_be_exact_human_message(tmp_path):
    chat,proposals,mid=source(tmp_path)
    with pytest.raises(ValueError):assignment(chat,proposals,mid,'帮我发布代码','assignment-forged-001')
    with pytest.raises(ValueError):assignment(chat,proposals,'invented-message','帮我检查项目文件数量','assignment-forged-002')


def test_queued_survives_restart_and_cancel_before_start_never_calls_worker(tmp_path):
    chat,proposals,mid=source(tmp_path);store=TaskStore(tmp_path);worker=Worker()
    a=store.create_authorized(*assignment(chat,proposals,mid,'帮我检查项目文件数量','assignment-restart-001'))
    record_constraint(store,a['id'],'','restriction-restart-001','read_only')
    store.recover();store=TaskStore(tmp_path)
    assert store.list()[0]['status']=='queued'
    controller=TaskController(store,worker,chat)
    asyncio.run(controller.command(a['id'],'','cancel-queued-001',cancel=True))
    asyncio.run(controller.command(a['id'],'','cancel-queued-001',cancel=True))
    asyncio.run(controller.poll())
    assert store.list()[0]['status']=='cancelled' and not worker.calls
    assert store.list()[0]['inputs'][0]['state']=='revoked'


def test_cancel_targets_original_turn_and_preserves_uncertain_delivery(tmp_path):
    runtime=Runtime(History(tmp_path,tmp_path/'state'),'fixture')
    runtime.h.save_managed('codex:A',{'sid':'codex:A','native_id':'A','agent':'codex','ended':False})
    calls=[]
    async def call(method,params):calls.append((method,params))
    runtime.call=call
    runtime.events=lambda sid:[{'turn_id':'other-turn'}]
    asyncio.run(runtime.cancel_task({'session_id':'codex:A','run_id':'original-turn'}))
    assert calls[0][1]=={'threadId':'A','turnId':'original-turn'}
    chat,proposals,mid=source(tmp_path);store=TaskStore(tmp_path)
    a=store.create_authorized(*assignment(chat,proposals,mid,'帮我检查项目文件数量','assignment-cancel-001'))
    store.change(a['id'],'start-task-cancel-001','started',status='running',session_id='codex:A',run_id='original-turn')
    async def uncertain(task):raise TimeoutError()
    runtime.cancel_task=uncertain
    controller=TaskController(store,runtime,chat)
    assert asyncio.run(controller.command(a['id'],'','cancel-uncertain-001',cancel=True))['delivery']=='unknown'
    assert asyncio.run(controller.command(a['id'],'','cancel-uncertain-001',cancel=True))['delivery']=='unknown'


def test_context_keeps_newest_active_and_expired_proposal_is_synchronized(tmp_path):
    store=TaskStore(tmp_path)
    for i in range(35):
        store.ensure(dict(id=f'proposal-{i}',origin_message_id=f'message-{i}',title=str(i),agent='codex',cwd=str(tmp_path),prompt='inspect',sandbox='read-only',created_at=i))
        store.change(f'proposal-{i}',f'ended-proposal-{i:03}','finished',status='execution_finished',updated_at=i)
    store.change('proposal-34','active-proposal-034','started',status='running')
    assert store.context()[0]['id']=='proposal-34' and len(store.context())==30
    card=dict(id='expired-task',origin_message_id='source',title='expired',status='proposed')
    store.ensure(card);store.ensure({**card,'status':'expired'})
    assert next(t for t in store.list() if t['id']=='expired-task')['status']=='expired'


def test_task_worker_selects_server_default_and_retains_native_failure_reason(tmp_path):
    runtime=Runtime(History(tmp_path,tmp_path/'state'),'fixture');calls=[]
    async def models(agent):
        return [{'id':'old-alias','is_default':False,'default_effort':'low'},
                {'id':'account-default','is_default':True,'default_effort':'medium'}]
    async def create(agent,cwd,**options):
        calls.append((agent,cwd,options))
        runtime.h.save_managed('worker',{'agent':agent,'cwd':cwd})
        return 'worker'
    runtime.models=models;runtime.create=create
    assert asyncio.run(runtime.create_task_worker({'id':'readonly-codex-task','agent':'codex','cwd':str(tmp_path),'sandbox':'read-only'}))=='worker'
    assert calls[0][2]=={'model':'account-default','effort':'medium','sandbox':'danger-full-access'}
    assert runtime.h.managed()['worker']['task_id']=='readonly-codex-task'
    from tasks import worker_error
    assert worker_error([{'turn_id':'other','error':{'message':'unrelated'}},
                         {'turn_id':'A','error':{'message':'{"error":{"message":"model unavailable"}}'}}],'A')=='工作器执行失败：model unavailable'


def test_assignment_http_auth_idempotency_and_pending_approval_restriction(tmp_path,monkeypatch):
    import importlib
    from fastapi.testclient import TestClient
    root=tmp_path/'AI_Work_System';(root/'project').mkdir(parents=True)
    monkeypatch.setenv('WORKBENCH_HOME',str(tmp_path));monkeypatch.setenv('WORKBENCH_STATE',str(tmp_path/'state'))
    import app
    app=importlib.reload(app)
    source=app.conversation.submit('http-human-request-001','帮我检查项目文件数量')['message_id']
    with app.conversation.db() as db:
        db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-personal-main')")
    payload=dict(agent='codex',relative_cwd='project',title='Read-only task',prompt='Count top-level files.',
                 sandbox='read-only',completion_condition='Report count.',source_quote='帮我检查项目文件数量',
                 origin_session_id='com-personal-main',origin_message_id=source,origin_request_id='http-human-request-001',request_id='http-task-request-001')
    # No lifespan/worker is started in this contract test.
    client=TestClient(app.app)
    assert client.post('/personal/tasks/create',json=payload).status_code==401
    headers={'Authorization':'Bearer '+app.TOKEN}
    first=client.post('/personal/tasks/create',headers=headers,json=payload)
    second=client.post('/personal/tasks/create',headers=headers,json=payload)
    assert first.status_code==second.status_code==200
    assert first.json()['task_id']==second.json()['task_id'] and first.json()['status']=='queued'
    assert not first.json()['work_started'] and len(app.task_store.list())==1
    assert client.post('/personal/tasks/create',headers=headers,json={**payload,'source_quote':'帮我发布代码'}).status_code==409
    card=app.work_proposals.propose(agent='codex',relative_cwd='project',title='Pending approval',prompt='Inspect only',sandbox='read-only',reason='Review',origin_message_id=source,idempotency_key='pending-proposal-http-001')
    app.task_store.ensure(card)
    assert record_constraint(app.task_store,card['id'],'','pre-approval-style-001','preserve_style')['delivery']=='pending_start'
    worker_calls=[]
    async def create(task):worker_calls.append(('create',task));return 'codex:approved-worker'
    async def send(sid,prompt,request_id):worker_calls.append(('input',prompt));return 'turn-approved'
    monkeypatch.setattr(app.runtime,'create_task_worker',create);monkeypatch.setattr(app.runtime,'input',send)
    approved=client.post('/personal/work/proposals/'+card['id']+'/approve',headers=headers,json={'request_id':'http-approval-request-001','explicit_authorization':True})
    assert approved.status_code==200
    assert '保持现有界面样式' in worker_calls[1][1]
    task=next(t for t in app.task_store.list() if t['id']==card['id'])
    assert task['inputs'][0]['state']=='delivered' and len(app.task_store.list())==2
