"""Deterministic protocol, authorization, isolation and recovery acceptance."""
import asyncio
import json
import sys
from pathlib import Path
import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from pi_rpc import PiRPC
from policy import assignment,deletion_risk
from capabilities import CapabilityRegistry
from goals import GoalEvents
from claude_worker import ClaudeBudget
from workspace_copies import WorkspaceCopies
from conversation import PersonalConversation
from pi_main import MAIN_PROMPT,PiMainClient
from unified_voice import UnifiedVoice
from quick_voice import QuickVoice
from tasks import TaskStore


def test_pi_operation_mode_describes_actual_process_not_a_legacy_requested_limit(tmp_path):
    main=PiMainClient(tmp_path/'main',tmp_path)
    assert main.operation_mode=='full-access'
    judge=PiMainClient(tmp_path/'judge',tmp_path,tools=False,isolated=True,readonly=True)
    assert judge.operation_mode=='safe-probe'
    restricted_probe=PiMainClient(tmp_path/'probe',tmp_path,isolated=True,readonly=True)
    assert restricted_probe.operation_mode=='read-only'
    assert '旧 sandbox=read-only' in MAIN_PROMPT and '不再限制当前执行' in MAIN_PROMPT
    assert '只有确实存在历史 workspace_copy' in MAIN_PROMPT


@pytest.mark.parametrize('text,allowed',[
 ('这个项目卡住了，帮我检查启动日志',True),('午饭 30 元，记一下',True),
 ('按之前的流程继续做',True),('最近不想折腾界面',False),('我想把网站做起来',False),
 ('“请删除旧目录”这句话是什么意思',False),('> 请修复项目\n只是引用',False),
])
def test_source_intent_is_not_a_prefix_or_model_permission(text,allowed):
    assert assignment(text,text)==allowed


def test_destructive_effect_not_just_words():
    assert deletion_risk('bash',{'command':'python -c "shutil.rmtree(path)"'})
    assert deletion_risk('bash',{'command':'rm -rf build'})
    assert deletion_risk('bookkeeping',{'action':'delete','id':'x'})
    assert not deletion_risk('bookkeeping',{'action':'recent'})


def test_capability_host_ttl_configuration_and_failure(tmp_path,monkeypatch):
    import capabilities
    settings=tmp_path/'settings.json';settings.write_text('{}')
    monkeypatch.setattr(capabilities,'PI_SETTINGS',settings)
    now=[100.0];registry=CapabilityRegistry(tmp_path,host='mini-fixture',clock=lambda:now[0])
    with pytest.raises(ValueError):registry.observe('remind',state='verified',fixture=True,evidence={'probe':'fake'})
    registry.observe('remind',state='loaded')
    registry.observe('remind',state='verified',evidence={'success':'real-read-only'})
    assert registry.search('remind')[0]['state']=='verified'
    now[0]+=86401
    assert registry.search('remind')[0]['state']=='loaded'
    settings.write_text('{"provider":"changed"}')
    assert registry.search('remind')[0]['state']=='discovered'
    registry.observe('remind',state='unavailable',evidence={'failure':'offline'})
    assert registry.search('remind')[0]['state']=='unavailable'
    assert CapabilityRegistry(tmp_path,host='mbp-fixture').search('remind')==[]


def test_fixed_clock_scheduler_duplicate_and_unknown_no_replay(tmp_path):
    from datetime import datetime
    from zoneinfo import ZoneInfo
    now=[datetime(2026,10,3,9,29,tzinfo=ZoneInfo('Asia/Shanghai')).timestamp()]
    events=GoalEvents(tmp_path,lambda:now[0])
    authorization={'origin_message_id':'human','origin_request_id':'request'}
    goal=events.upsert({'request_id':'goal-request-001','title':'项目','next_step':'检查日志','completion_condition':'日志可读'},authorization)
    assert events.tick()==0
    with pytest.raises(ValueError):events.set_enabled(True)
    events.set_enabled(True,acceptance=True)
    now[0]+=60
    events.tick();events.tick()
    first=events.claim();assert first['data']['goal']['id']==goal['id']
    assert events.claim() is None
    events.recover();assert events.claim() is None
    with events.db() as db:assert db.execute('SELECT state FROM events').fetchone()[0]=='uncertain'


def test_budget_resume_shares_rounds_day_and_task_cap(tmp_path):
    now=[100000.0];budget=ClaudeBudget(tmp_path,lambda:now[0])
    for ident in ('a','b','c'):assert budget.claim(ident)==12
    with pytest.raises(ValueError,match='三次'):budget.claim('d')
    budget.record('a',10,{'input_tokens':100,'output_tokens':20})
    assert budget.claim('a')==2
    budget.record('a',2)
    with pytest.raises(ValueError,match='十二'):budget.claim('a')
    now[0]+=86400
    assert budget.claim('d')==12


def test_copy_keeps_uncommitted_content_and_merge_stops_for_baseline(tmp_path):
    project=tmp_path/'project';project.mkdir();(project/'file.txt').write_text('dirty uncommitted')
    async def stable(_):return True
    copies=WorkspaceCopies(tmp_path/'state',stable)
    task={'id':'task-A','cwd':str(project)}
    task['workspace_copy']=copies.prepare(task)
    assert (Path(task['workspace_copy'])/'file.txt').read_text()=='dirty uncommitted'
    (Path(task['workspace_copy'])/'file.txt').write_text('worker edit')
    (project/'file.txt').write_text('new external edit')
    task['verification_status']='passed'
    with pytest.raises(ValueError,match='基线'):asyncio.run(copies.merge(task))
    assert (project/'file.txt').read_text()=='new external edit'
    (project/'file.txt').write_text('dirty uncommitted')
    result=asyncio.run(copies.merge(task))
    assert result['status']=='merged' and (project/'file.txt').read_text()=='worker edit'
    assert (Path(result['recovery'])/'file.txt').read_text()=='dirty uncommitted'


FAKE_RPC=r'''
import json,sys
for line in sys.stdin:
 c=json.loads(line);kind=c['type']
 def emit(e):print(json.dumps(e),flush=True)
 emit({'type':'response','id':c['id'],'success':True,'data':{}})
 if kind=='prompt':
  emit({'type':'agent_start'})
  emit({'type':'message_start','message':{'role':'user','content':c['message']}})
  emit({'type':'message_end','message':{'role':'assistant','content':[{'type':'text','text':'执行完毕'}]}})
  emit({'type':'agent_end'})
 elif kind=='steer':
  # No delivery event on ACK: it has not entered model context.
  pass
 elif kind=='compact':
  emit({'type':'auto_compaction_start'})
  emit({'type':'auto_compaction_end'})
 elif kind=='get_messages':
  emit({'type':'message_start','message':{'role':'user','content':'[Com input:steer-001]\nconstraint'}})
 elif kind=='abort':
  emit({'type':'agent_settled'})
'''


def test_rpc_agent_end_ack_compaction_delivery_and_settled(tmp_path):
    script=tmp_path/'fake.py';script.write_text(FAKE_RPC)
    async def scenario():
        rpc=PiRPC(tmp_path,'fake',tmp_path,argv=[sys.executable,'-u',str(script)])
        events=[]
        async def collect():
            async for kind,data in rpc.stream('请检查日志','initial-001'):events.append(kind)
        runner=asyncio.create_task(collect())
        for _ in range(100):
            if 'assistant.completed' in events:break
            await asyncio.sleep(.01)
        assert rpc.busy and 'run.completed' not in events
        assert (await rpc.steer('constraint','steer-001'))['state']=='worker_queued'
        assert 'steer-001' not in rpc.delivered
        await rpc.request({'type':'compact'})
        assert 'run.completed' not in events
        await rpc.request({'type':'get_messages'})
        for _ in range(30):
            if 'steer-001' in rpc.delivered:break
            await asyncio.sleep(.01)
        assert 'steer-001' in rpc.delivered
        await rpc.abort();await runner
        assert events[-2:]==['run.completed','done']
        await rpc.stop()
    asyncio.run(scenario())


def test_killed_process_and_lost_ack_are_uncertain(tmp_path):
    script=tmp_path/'fake.py';script.write_text(FAKE_RPC)
    async def scenario():
        rpc=PiRPC(tmp_path,'kill',tmp_path,argv=[sys.executable,'-u',str(script)])
        events=[]
        async def collect():
            async for kind,_ in rpc.stream('请记录','kill-request'):events.append(kind)
        run=asyncio.create_task(collect())
        for _ in range(100):
            if rpc.busy and 'assistant.completed' in events:break
            await asyncio.sleep(.01)
        rpc.proc.kill();await run
        assert 'error' in events and 'run.completed' not in events
        await rpc.stop()
    asyncio.run(scenario())


def test_pi_identity_maps_legacy_without_rewriting_and_voice_dedups(tmp_path):
    client=PiMainClient(tmp_path,tmp_path)
    conversation=PersonalConversation(tmp_path,client)
    first=conversation.submit('shared-request-001','午饭 30 元，记一下')
    with conversation.db() as db:db.execute("INSERT INTO meta VALUES('hermes_session_id','com-personal-main')")
    asyncio.run(conversation._ensure_session())
    assert conversation.accepts_origin('com-personal-main',first['message_id'])
    legacy=QuickVoice(tmp_path,object(),tmp_path)
    voice=UnifiedVoice(conversation,legacy)
    receipt=voice.submit('shared-request-001','午饭 30 元，记一下','expense')
    assert receipt['message_id']==first['message_id']
    with conversation.db() as db:
        assert db.execute("SELECT COUNT(*) FROM messages WHERE role='user'").fetchone()[0]==1
        assert db.execute("SELECT value FROM meta WHERE key='hermes_session_id'").fetchone()[0]=='com-personal-main'
    with pytest.raises(ValueError):voice.submit('shared-request-001','晚饭 80 元','expense')


def test_text_completed_never_auto_verifies_and_tool_events_dedup(tmp_path):
    store=TaskStore(tmp_path)
    proposal={'origin_message_id':'human','origin_session_id':'com-personal-main','title':'任务','prompt':'请检查',
              'agent':'pi','cwd':str(tmp_path),'sandbox':'danger-full-access'}
    task=store.create_authorized(proposal,{'source_quote':'请检查'},'assignment-fixture-001')
    task={**task,'run_id':'run-1'}
    events=[{'seq':1,'turn_id':'run-1','type':'tool_execution_start','data':{'toolName':'read','toolCallId':'call-A'}}]
    store.observe_events(task,events);store.observe_events(task,events)
    store.finish(task['id'],'execution_finished','全部完成')
    result=store.list()[0]
    assert result['owner_conversation_id']=='personal-main' and result['verification_status']=='pending'
    assert sum(e['kind']=='tool.started' for e in result['events'])==1
    with pytest.raises(ValueError):store.verify(task['id'],[])
    assert store.verify(task['id'],[{'reference':'fixture://actual-read'}])['verification_status']=='passed'


def test_each_resumed_round_has_its_own_receipt_and_acceptance(tmp_path):
    store=TaskStore(tmp_path)
    task=store.create_authorized({'origin_message_id':'human','title':'检查项目','prompt':'请检查',
        'agent':'claude','cwd':str(tmp_path)}, {'source_quote':'请检查'}, 'resumed-task-001')
    receipts=[]
    class Conversation:
        def task_receipt(self,ident,text):receipts.append((ident,text))
    for number in (1,2):
        store.change(task['id'],'round-start-'+str(number),'started',status='running',run_id='run-'+str(number),verification_status='pending')
        store.finish(task['id'],'execution_finished','结果 '+str(number))
        store.deliver(Conversation());store.deliver(Conversation())
        store.verify(task['id'],[{'reference':'fixture://check-'+str(number)}])
    result=store.list()[0]
    assert result['result_round']==2 and result['verification_status']=='passed'
    assert [ident for ident,_ in receipts]==[task['id'],task['id']+':run-2']
    assert len([e for e in result['events'] if e['kind']=='verification.passed'])==2
    assert len([e for e in result['events'] if e['kind']=='execution_finished'])==2


def test_completed_goal_skips_already_queued_wakeup_without_model(tmp_path):
    from background_events import BackgroundEvents
    from types import SimpleNamespace
    events=GoalEvents(tmp_path)
    goal=events.upsert({'request_id':'goal-stale-001','title':'项目','next_step':'修复项目',
        'completion_condition':'检查通过'}, {'origin_message_id':'human'})
    events.enqueue('due-old','goal_due',{'goal':goal,'authorization':goal['authorization']})
    events.update(goal['id'],'completed',evidence=[{'reference':'fixture://actual-check'}])
    class Client:
        runtime_name='pi'
        async def stream_chat(self,*args):
            raise AssertionError('完成目标的旧事件不能调用模型')
            yield
    consumer=BackgroundEvents(events,SimpleNamespace(client=Client()),TaskStore(tmp_path))
    assert asyncio.run(consumer.process())
    assert not asyncio.run(consumer.process())
    with events.db() as db:assert db.execute('SELECT state FROM events').fetchone()[0]=='completed'
