import sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from test_pi_safety import tool_service
from task_tools import approval_source


def test_approved_delete_preserves_origin_and_exact_action(tmp_path):
    tools,ctx=tool_service(tmp_path,'确认删除测试记账这笔')
    action={'tool':'bookkeeping','args':{'action':'delete','id':'fixture-1'}}
    proposal=tools.proposals.propose(agent='pi',relative_cwd='.',title='删除测试',prompt='删除fixture-1',
        sandbox='danger-full-access',reason='确认删除',idempotency_key='delete-proposal-001',actual_action=action,**ctx)
    tools.store.ensure(proposal)
    resolved=approval_source(tools.conversation,proposal)
    tools.store.change(proposal['id'],'approve-fixture-001','authorized',status='running',
        source_links=resolved['source_links'],source_message_ids=resolved['source_message_ids'],
        authorization={**resolved['authorization'],'actual_action':action,'request_id':'approve-fixture-001'})
    worker={**ctx,'task_id':proposal['id']}
    assert tools.authorize_tool({'tool':'bookkeeping','args':{'action':'recent'}},worker)['authorized']
    with pytest.raises(ValueError,match='不可逆'):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'delete','id':'other'}},worker)
    assert tools.authorize_tool(action,worker)['authorized']
    with pytest.raises(ValueError,match='禁止重复'):
        tools.authorize_tool(action,worker)
    with pytest.raises(ValueError,match='真实用户'):
        approval_source(tools.conversation,{**proposal,'origin_request_id':'forged'})


def test_approved_deletion_starts_despite_unrelated_old_workspace_task(tmp_path):
    import asyncio
    from test_business_read_queue import Worker
    tools,ctx=tool_service(tmp_path,'确认删除测试记账这笔')
    action={'tool':'bookkeeping','args':{'action':'delete','id':'fixture-1'}}
    proposal=tools.proposals.propose(agent='pi',relative_cwd='.',title='删除测试',prompt='删除fixture-1',
        sandbox='danger-full-access',reason='确认删除',idempotency_key='delete-proposal-001',actual_action=action,**ctx)
    tools.store.ensure(proposal)
    origin=approval_source(tools.conversation,proposal)
    tools.store.change(proposal['id'],'queue-fixture-001','authorized',status='queued',
        source_links=origin['source_links'],source_message_ids=origin['source_message_ids'],
        authorization={**origin['authorization'],'actual_action':action,'request_id':'approve-fixture-001'})
    old={**proposal,'id':'old-file-write'}
    tools.store.ensure(old)
    tools.store.change(old['id'],'old-uncertain-001','unknown',status='unknown',session_id='old-session')
    worker=Worker();tools.controller.runtime=worker
    asyncio.run(tools.controller.start_queued())
    tasks={t['id']:t for t in tools.store.list()}
    assert tasks[proposal['id']]['status']=='running'
    assert tasks[old['id']]['status']=='unknown'


def test_native_event_sequences_do_not_conflict_across_worker_sessions(tmp_path):
    tools,ctx=tool_service(tmp_path,'确认删除测试记账这笔')
    proposal=tools.proposals.propose(agent='pi',relative_cwd='.',title='删除测试',prompt='删除fixture-1',
        sandbox='danger-full-access',reason='确认删除',idempotency_key='delete-proposal-001',**ctx)
    task=tools.store.ensure(proposal)
    event={'seq':0,'type':'tool_execution_start','data':{'toolName':'bookkeeping','toolCallId':'first'}}
    tools.store.observe_events({**task,'session_id':'old'},[event])
    tools.store.observe_events({**task,'session_id':'new'},[{**event,'data':{'toolName':'bookkeeping','toolCallId':'second'}}])
    tools.store.observe_events({**task,'session_id':'new'},[{**event,'data':{'toolName':'bookkeeping','toolCallId':'second'}}])
    assert len([e for e in tools.store.list()[0]['events'] if e['kind']=='tool.started'])==2
