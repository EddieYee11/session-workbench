"""Real human source chains, scoped acceptance and durable plan scheduling."""
import asyncio
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))

from agent_tools import AgentTools
from capabilities import CapabilityRegistry
from conversation import PersonalConversation
from goals import GoalEvents
from policy import source, readonly_shell
from task_tools import authorized_assignment
from tasks import TaskController, TaskStore
from verification import verify
from work_dispatch import WorkProposalStore


class Worker:
    def __init__(self):
        self.calls=[]
        self.block=False
        self.action_lock=asyncio.Lock()
    async def preflight_task(self,task):
        if self.block:raise ValueError('model unavailable')
    async def create(self,agent,cwd,**kwargs):
        self.calls.append(('create',agent));return 'worker-'+str(len(self.calls))
    async def input(self,sid,prompt,key):
        self.calls.append(('input',prompt));return 'run-'+key
    async def status(self,sid):return 'running'
    def events(self,sid):return []
    def task_capabilities(self,task):return {'steer':True}
    async def deliver_task_input(self,task,command):
        self.calls.append(('steer',command['text']));return {'state':'delivered'}


def setup(tmp_path,text='帮我检查项目文件'):
    (tmp_path/'project').mkdir()
    chat=PersonalConversation(tmp_path)
    with chat.db() as db:db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-personal-main')")
    store=TaskStore(tmp_path);worker=Worker()
    controller=TaskController(store,worker,chat)
    service=AgentTools(tmp_path,chat,WorkProposalStore(tmp_path,tmp_path),store,controller,
                       CapabilityRegistry(tmp_path),GoalEvents(tmp_path))
    return service,submit(chat,'original-request-001',text),worker


def submit(chat,key,text,reference=None):
    mid=chat.submit(key,text,reference)['message_id']
    return {'origin_message_id':mid,'origin_request_id':key,'origin_session_id':'com-personal-main'}


def assignment_args(text,**values):
    return {'request_id':'assignment-request-001','title':'检查文件','prompt':'读取项目文件并报告',
            'agent':'codex','relative_cwd':'project','sandbox':'read-only','source_quote':text,
            'completion_condition':'观察到真实文件清单',**values}


@pytest.mark.parametrize('followup',['继续','接着做','按上面那个'])
def test_short_continuation_carries_actual_source_and_cannot_duplicate_task(tmp_path,followup):
    service,original,worker=setup(tmp_path)
    created=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件'),original))
    later=submit(service.conversation,'continued-request-001',followup)
    row=source(service.conversation,later)
    assert row['authorization_parent_message_id']==original['origin_message_id']
    assert row['source_links'][0]['text']=='帮我检查项目文件'
    sent=asyncio.run(service.call('task_send',{'task_id':created['task_id'],'text':followup,
                                            'request_id':'continued-input-001'},later))
    assert sent['delivery']=='pending_start'
    task=service.store.list()[0]
    assert task['context_revision']==2
    assert task['latest_user_message_id']==later['origin_message_id']
    assert task['source_message_ids']==[original['origin_message_id'],later['origin_message_id']]
    asyncio.run(service.controller.start_queued())
    prompt=worker.calls[-1][1]
    assert 'context_revision' in prompt and 'continued-request-001' in prompt
    with pytest.raises(ValueError,match='已有任务'):
        asyncio.run(service.call('task_submit',assignment_args(followup,request_id='duplicate-request-001'),later))
    assert len(service.store.list())==1


@pytest.mark.parametrize('original',['我希望把网站做好','引用：\n> 帮我修改项目','请停止旧任务'])
def test_continuation_does_not_invent_authorization(tmp_path,original):
    service,_,_=setup(tmp_path,original)
    later=submit(service.conversation,'no-authority-request-001','继续')
    with pytest.raises(ValueError):
        authorized_assignment(service.conversation,service.proposals,{**assignment_args('继续'),**later})


def test_two_tasks_from_one_source_require_concrete_reference(tmp_path):
    service,original,_=setup(tmp_path,'帮我检查项目文件和目录')
    first=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件和目录'),original))
    second=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件和目录',
                       request_id='second-assignment-001',title='检查目录'),original))
    later=submit(service.conversation,'ambiguous-request-001','继续')
    with pytest.raises(ValueError,match='多个事项'):
        asyncio.run(service.call('task_send',{'task_id':first['task_id'],'text':'继续','request_id':'ambiguous-input-001'},later))
    linked=submit(service.conversation,'named-request-001','继续检查目录')
    result=asyncio.run(service.call('task_send',{'task_id':second['task_id'],'text':'继续检查目录',
                                               'request_id':'named-input-001'},linked))
    assert result['delivery']=='pending_start'
    assert len(service.store.list()[0]['constraints'])==0


def test_new_human_can_verify_nearest_actual_task_but_not_unrelated_task(tmp_path):
    service,original,_=setup(tmp_path)
    task=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件'),original))
    (tmp_path/'project'/'result').write_text('actual')
    service.store.finish(task['task_id'],'execution_finished','观察到结果')
    later=submit(service.conversation,'verify-later-request-001','验收一下刚才那个任务')
    result=asyncio.run(service.call('task_verify',{'task_id':task['task_id'],
                         'checks':[{'type':'file_contains','path':'result','value':'actual'}]},later))
    assert result['verification_status']=='passed'
    submit(service.conversation,'unrelated-original-001','帮我分析另一个工程')
    unrelated=submit(service.conversation,'unrelated-verify-001','验收刚才那个任务')
    with pytest.raises(ValueError,match='未关联|其他任务'):
        asyncio.run(service.call('task_verify',{'task_id':task['task_id'],
                              'checks':[{'type':'file_exists','path':'result'}]},unrelated))


def test_later_merge_is_source_scoped_and_readonly_instruction_blocks_it(tmp_path):
    service,original,worker=setup(tmp_path,'帮我修改项目配置并修好')
    task=asyncio.run(service.call('task_submit',assignment_args('帮我修改项目配置并修好',sandbox='workspace-write'),original))
    service.store.change(task['task_id'],'copy-and-run-001','started',workspace_copy=str(tmp_path/'project'),run_id='run-001')
    service.store.finish(task['task_id'],'execution_finished','改动已完成')
    service.store.verify(task['task_id'],[{'reference':'fixture://check'}])
    merges=[]
    async def merge(value):merges.append(value['id']);return {'status':'merged'}
    worker.workers=SimpleNamespace(copies=SimpleNamespace(merge=merge))
    later=submit(service.conversation,'merge-later-request-001','合入刚才那个')
    assert asyncio.run(service.call('task_merge',{'task_id':task['task_id']},later))['status']=='merged'
    assert merges==[task['task_id']]
    denied=submit(service.conversation,'merge-denied-request-001','不要合入检查文件')
    with pytest.raises(ValueError,match='禁止合入'):
        asyncio.run(service.call('task_merge',{'task_id':task['task_id']},denied))


def test_paused_preflight_recovers_without_uncertain_replay_and_can_cancel(tmp_path):
    service,original,worker=setup(tmp_path)
    task=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件'),original))
    worker.block=True
    asyncio.run(service.controller.start_queued())
    service.store.recover()
    current=service.store.list()[0]
    assert current['status']=='paused' and not current['session_id'] and not worker.calls
    service.store.enqueue(task['task_id'],'保持结果格式','pause-constraint-001')
    assert service.store.list()[0]['inputs'][0]['state']=='pending_start'
    later=submit(service.conversation,'resume-human-request-001','继续')
    asyncio.run(service.call('task_resume',{'task_id':task['task_id'],'request_id':'resume-task-request-001'},later))
    worker.block=False
    asyncio.run(service.controller.start_queued())
    assert service.store.list()[0]['status']=='running'
    service.store.recover()
    with pytest.raises(ValueError,match='不能重放'):
        asyncio.run(service.controller.resume(task['task_id'],'unsafe-resume-request-001'))
    # A second task is cancelled while preflight-paused without contacting a worker.
    second=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件',
                         request_id='second-paused-task-001',title='目录'),original))
    service.store.change(second['task_id'],'pause-second-task-001','waiting',status='paused')
    before=list(worker.calls)
    asyncio.run(service.controller.command(second['task_id'],'','cancel-paused-task-001',cancel=True))
    assert next(t for t in service.store.list() if t['id']==second['task_id'])['status']=='cancelled'
    assert worker.calls==before


def test_same_goal_independent_nodes_run_two_and_dependency_waits_for_merge(tmp_path):
    service,original,worker=setup(tmp_path,'帮我检查项目文件和目录，再检查结果')
    text='帮我检查项目文件和目录，再检查结果'
    goal=service.goals.upsert({'request_id':'plan-goal-request-001','title':'检查工程',
                             'next_step':'检查文件和目录','completion_condition':'三项均通过'},original)
    common=assignment_args(text,goal_id=goal['id'])
    first=asyncio.run(service.call('task_submit',{**common,'plan_node_id':'files'},original))
    second=asyncio.run(service.call('task_submit',{**common,'request_id':'plan-second-task-001',
                             'title':'检查目录','plan_node_id':'dirs'},original))
    dependent=asyncio.run(service.call('task_submit',{**common,'request_id':'plan-final-task-001',
                         'title':'结果检查','plan_node_id':'result','depends_on':[first['task_id']]},original))
    with pytest.raises(ValueError,match='节点已有任务'):
        asyncio.run(service.call('task_submit',{**common,'request_id':'duplicate-plan-task-001','plan_node_id':'files'},original))
    with pytest.raises(ValueError,match='相同计划节点内容'):
        asyncio.run(service.call('task_submit',{**common,'request_id':'alias-plan-task-001','plan_node_id':'files-alias'},original))
    asyncio.run(service.controller.start_queued());asyncio.run(service.controller.start_queued())
    assert len([c for c in worker.calls if c[0]=='create'])==2
    service.store.change(first['task_id'],'dependency-copy-001','workspace.isolated',workspace_copy=str(tmp_path/'copy'))
    service.store.finish(first['task_id'],'execution_finished','文件检查结束')
    service.store.verify(first['task_id'],[{'reference':'fixture://file-list'}])
    asyncio.run(service.controller.start_queued())
    current=next(t for t in service.store.list() if t['id']==dependent['task_id'])
    assert current['status']=='queued' and current['dependency_status']=='blocked'
    first_task=next(t for t in service.store.list() if t['id']==first['task_id'])
    service.store.change(first['task_id'],'dependency-merged-001','workspace.merged',merged_run_id=first_task['run_id'])
    asyncio.run(service.controller.start_queued())
    assert next(t for t in service.store.list() if t['id']==dependent['task_id'])['status']=='running'
    assert len(service.goals.list()[0]['plan_nodes'])==3


def test_criteria_require_all_actual_checks_and_judge_failure_stays_pending(tmp_path,monkeypatch):
    service,original,_=setup(tmp_path)
    criteria=[{'id':'first','description':'第一文件正确'},{'id':'second','description':'第二文件正确'}]
    task=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件',acceptance_criteria=criteria),original))
    (tmp_path/'project'/'first').write_text('one');(tmp_path/'project'/'second').write_text('two')
    service.store.finish(task['task_id'],'execution_finished','模型说完成')
    checks=[{'type':'file_contains','path':'first','value':'one','criterion_id':'first'},
            {'type':'file_contains','path':'second','value':'two','criterion_id':'second'}]
    current=service.store.list()[0]
    with pytest.raises(ValueError,match='未覆盖'):
        asyncio.run(verify(current,checks[:1],tmp_path))
    calls=[]
    async def judge(task,evidence,state):
        calls.append(evidence);return {'verdict':'revise','evidence_gaps':[{'criterion_id':'second','missing_evidence':'实际使用未检查'}],
                                      'next_steps':['补上使用证据'],'reason':'内容存在不等于使用已通过'}
    import quality_judge
    monkeypatch.setattr(quality_judge,'review',judge)
    for _ in range(3):
        result=asyncio.run(service.call('task_verify',{'task_id':task['task_id'],'checks':checks},original))
        assert result['verification_status']=='pending'
    assert len(calls)==2 and result['review_limit_reached']
    assert len(service.store.list()[0]['quality_reviews'])==2


def test_true_staged_readonly_supplement_keeps_source_link_but_no_longer_restricts_execution(tmp_path):
    service,original,_=setup(tmp_path,'帮我修改项目配置')
    later=submit(service.conversation,'readonly-human-request-001','先只读，不改代码')
    with service.conversation.db() as db:
        columns={row['name'] for row in db.execute('PRAGMA table_info(messages)')}
        if 'supplement_to_message_id' not in columns:db.execute('ALTER TABLE messages ADD COLUMN supplement_to_message_id TEXT')
        db.execute('UPDATE messages SET supplement_to_message_id=? WHERE id=?',
                   (original['origin_message_id'],later['origin_message_id']))
    row=source(service.conversation,{**later,'supplement_to_message_id':original['origin_message_id']})
    assert row['authorization_parent_message_id']==original['origin_message_id']
    for context in (original,later):
        assert service.authorize_tool({'tool':'bash','args':{'command':'git status --short'},'tool_call_id':'read-status'},context)['authorized']
        assert service.authorize_tool({'tool':'edit','args':{'path':'config','oldText':'a','newText':context['origin_message_id']},'tool_call_id':'native-edit'},context)['authorized']
    with pytest.raises(ValueError,match='关联不匹配'):
        source(service.conversation,{**later,'supplement_to_message_id':'forged-parent'})


def test_latest_task_guard_ignores_revoked_readonly_but_refreshes_cancelled_state(tmp_path):
    from worker_runtime import WorkerRuntime
    service,original,_=setup(tmp_path,'帮我修改项目配置')
    created=asyncio.run(service.call('task_submit',assignment_args('帮我修改项目配置',sandbox='workspace-write'),original))
    service.store.change(created['task_id'],'worker-copy-context-001','started',status='running',workspace_copy=str(tmp_path/'project'))
    captured=service.store.list()[0]
    service.store.enqueue(created['task_id'],'先只读，不改代码','latest-readonly-task-001')
    runtime=WorkerRuntime(SimpleNamespace(state=tmp_path,task_store=service.store))
    runtime.guard(captured,'Edit',{'file_path':'config','old_string':'old','new_string':'new'})
    assert service.store.list()[0]['inputs'][0]['state']=='revoked'
    runtime.guard(captured,'Read',{'file_path':'config'})
    service.store.change(created['task_id'],'cancelled-native-task-001','cancelled',status='cancelled')
    with pytest.raises(ValueError,match='不能继续'):
        runtime.guard(captured,'Read',{'file_path':'config'})


def test_shell_inspection_does_not_enter_write_deduplication_ledger(tmp_path):
    service,original,_=setup(tmp_path)
    args={'tool':'bash','args':{'command':'git status --short'},'tool_call_id':'inspect-001'}
    assert service.authorize_tool(args,original)['authorized']
    assert service.authorize_tool({**args,'tool_call_id':'inspect-002'},original)['authorized']
    for unsafe in ('git diff --output=/tmp/result','ls > /tmp/result','pwd; rm old','git -c core.pager=bad log'):
        assert not readonly_shell('bash',{'command':unsafe})


def test_passed_review_is_idempotent_and_new_result_run_gets_own_review(tmp_path,monkeypatch):
    service,original,_=setup(tmp_path)
    created=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件'),original))
    (tmp_path/'project'/'result').write_text('actual')
    service.store.finish(created['task_id'],'execution_finished','实际文件已经生成')
    calls=[]
    async def judge(task,evidence,state):
        calls.append(task.get('run_id'));return {'verdict':'pass','evidence_gaps':[],
                                               'next_steps':[],'reason':'用户要求有实际文件证据'}
    import quality_judge
    monkeypatch.setattr(quality_judge,'review',judge)
    args={'task_id':created['task_id'],'checks':[{'type':'file_contains','path':'result','value':'actual'}],'quality_review':True}
    for _ in range(3):
        checked=asyncio.run(service.call('task_verify',args,original))
        assert checked['verification_status']=='passed'
    assert len(calls)==1 and checked['structured_result']['coverage']['semantic_assessment']=='pass'
    service.store.change(created['task_id'],'next-result-run-001','started',status='running',run_id='second-real-run')
    service.store.finish(created['task_id'],'execution_finished','第二轮结果')
    checked=asyncio.run(service.call('task_verify',args,original))
    assert checked['verification_status']=='passed' and len(calls)==2
    assert checked['quality_reviews'][-1]['run_id']=='second-real-run'


def test_two_tasks_same_source_do_not_collide_but_write_ack_loss_still_blocks(tmp_path):
    service,original,_=setup(tmp_path,'帮我记账，记两笔各 30 元午饭')
    args=assignment_args('帮我记账，记两笔各 30 元午饭',agent='pi',sandbox='danger-full-access')
    first=asyncio.run(service.call('task_submit',args,original))
    second=asyncio.run(service.call('task_submit',{**args,'request_id':'second-write-task-001','title':'第二笔'},original))
    for created in (first,second):
        service.store.change(created['task_id'],'running:'+created['task_id'],'started',status='running')
    tool={'tool':'bookkeeping','args':{'action':'add','amount':30,'note':'午饭'},'tool_call_id':'first-write'}
    assert service.authorize_tool(tool,{**original,'task_id':first['task_id']})['authorized']
    assert service.authorize_tool({**tool,'tool_call_id':'second-write'},{**original,'task_id':second['task_id']})['authorized']
    with pytest.raises(ValueError,match='禁止重复'):
        service.authorize_tool({**tool,'tool_call_id':'uncertain-retry'},{**original,'task_id':first['task_id']})


def test_bare_continuation_cannot_recreate_cancelled_task(tmp_path):
    service,original,_=setup(tmp_path)
    created=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件'),original))
    asyncio.run(service.controller.command(created['task_id'],'','cancel-original-task-001',cancel=True))
    later=submit(service.conversation,'continue-cancelled-001','继续',
                 {'mode':'reply','id':original['origin_message_id']})
    with pytest.raises(ValueError,match='已有任务'):
        asyncio.run(service.call('task_submit',assignment_args('继续',request_id='duplicate-cancelled-001'),later))
    with pytest.raises(ValueError):
        asyncio.run(service.call('task_resume',{'task_id':created['task_id'],'request_id':'resume-cancelled-001'},later))
    assert service.store.list()[0]['status']=='cancelled'


def test_compact_background_context_preserves_full_sqlite_sources_and_old_limits(tmp_path):
    service,original,_=setup(tmp_path,'帮我检查项目文件'+('，原始材料'*400))
    created=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件'),original))
    service.store.enqueue(created['task_id'],'不要修改任何代理配置','old-critical-limit-001')
    for number in range(20):
        follow=submit(service.conversation,'extra-source-request-'+str(number),'继续检查项目文件'+('，补充材料'*200))
        row=source(service.conversation,follow)
        service.store.enqueue(created['task_id'],row['raw_text'],'extra-source-input-'+str(number),source_context=row)
    full=service.store.list()[0]
    compact=service.store.context()[0]
    assert len(full['source_links'])==21 and len(compact['source_links'])==5
    assert len(compact['source_links'][0]['text'])==800
    assert len(full['source_links'][0]['text'])>800
    assert '不要修改任何代理配置' not in compact['effective_constraints']
    assert '不要修改任何代理配置' in compact['constraints_audit']
    assert '不要修改任何代理配置' not in compact['work_brief']['constraints']
    assert '不要修改任何代理配置' in compact['work_brief']['constraints_audit']


def test_judge_pass_for_old_context_does_not_verify_new_constraints(tmp_path,monkeypatch):
    service,original,_=setup(tmp_path)
    created=asyncio.run(service.call('task_submit',assignment_args('帮我检查项目文件'),original))
    (tmp_path/'project'/'result').write_text('actual')
    service.store.finish(created['task_id'],'execution_finished','已产生文件')
    async def judge(task,evidence,state):
        service.store.change(task['id'],'new-context-during-review-001','requirements.updated',
                             '追加了使用验收条件',context_revision=task['context_revision']+1,
                             constraints=['需额外验证实际使用'])
        return {'verdict':'pass','reason':'旧要求已达到','evidence_gaps':[],'next_steps':[]}
    import quality_judge
    monkeypatch.setattr(quality_judge,'review',judge)
    checked=asyncio.run(service.call('task_verify',{'task_id':created['task_id'],
                    'checks':[{'type':'file_exists','path':'result'}],'quality_review':True},original))
    assert checked['verification_status']=='pending'
    assert checked['quality_reviews'][-1]['stale']
    assert checked.get('quality_review') is None
