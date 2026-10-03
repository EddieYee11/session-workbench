"""Voice facts and explicit records share source-checked intent; no real ledger calls."""
import asyncio
import sqlite3
import sys
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from agent_tools import AgentTools
from capabilities import CapabilityRegistry
from conversation import PersonalConversation
from goals import GoalEvents
from policy import assignment,bookkeeping_intent,bookkeeping_details,money_amounts
from task_tools import authorized_assignment
from tasks import TaskStore,TaskController
from work_dispatch import WorkProposalStore


def service(tmp_path,text,purpose='conversation'):
    chat=PersonalConversation(tmp_path)
    with chat.db() as db:
        db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-personal-main')")
        db.execute('CREATE TABLE IF NOT EXISTS voice_requests(request_id TEXT PRIMARY KEY,purpose TEXT NOT NULL)')
    mid=chat.submit('voice-intent-request-001',text)['message_id']
    with chat.db() as db:db.execute('INSERT INTO voice_requests VALUES (?,?)',('voice-intent-request-001',purpose))
    store=TaskStore(tmp_path)
    runtime=SimpleNamespace(action_lock=asyncio.Lock())
    tools=AgentTools(tmp_path,chat,WorkProposalStore(tmp_path,tmp_path),store,TaskController(store,runtime,chat),
                     CapabilityRegistry(tmp_path),GoalEvents(tmp_path))
    return tools,{'origin_session_id':'com-personal-main','origin_message_id':mid,'origin_request_id':'voice-intent-request-001'}


@pytest.mark.parametrize('text,amount',[
    ('买零食花费五十九块二毛二。',59.22),
    ('记个账，午饭吃面花费三十二块五毛。',32.5),
    ('午饭30元，记账',30),
    ('我要记账，午饭30元',30),
    ('我想记一笔午饭三十五元',35),
    ('帮我记一笔，午饭三十二块五',32.5),
    ('早饭十二元五角二分，记一下',12.52),
    ('午饭三十五点二二元，记账',35.22),
    ('买口香糖花了五毛二分',.52),
    ('买纸袋花了五分',.05),
    ('打车花费59块2毛2',59.22),
    ('午饭¥35.22，记一下',35.22),
    ('茶五元，记账',5),
    ('饭30元，记一下',30),
    ('能不能帮我记账这笔午饭30元？',30),
])
def test_current_expense_in_normal_voice_is_authorized_once(tmp_path,text,amount):
    assert bookkeeping_intent(text)
    assert assignment(text,text)
    assert Decimal(str(amount)) in money_amounts(text)
    tools,context=service(tmp_path,text)
    call={'tool':'bookkeeping','args':{'action':'add','amount':amount,'note':'当前真实事项'},'tool_call_id':'first-call'}
    assert tools.authorize_tool(call,context)['authorized']
    with pytest.raises(ValueError,match='禁止重复'):
        tools.authorize_tool({**call,'tool_call_id':'retry-call'},context)
    with sqlite3.connect(tools.path) as db:assert db.execute('SELECT count(*) FROM effects').fetchone()[0]==1


@pytest.mark.parametrize('text',[
    '你能记账吗？',
    '你会记账吗，午饭59.22元',
    '为什么你记账这么慢，59.22元？',
    '不要记账，午饭59.22元',
    '请先别记这笔午饭59.22元',
    '我以后想记账，午饭59.22元',
    '我希望有空记录午饭59.22元',
    '我想买零食花费59.22元',
    '明天提醒我记账，午饭59.22元',
    '请查一下最近午饭59.22元的记账',
    '只是举例，买零食花费59.22元',
    '假设买零食花费59.22元',
    '我朋友买零食花费59.22元',
    '她买零食花费59.22元',
    '引用：\n> 买零食花费59.22元，记账',
    '我说的是“买零食花费59.22元，记账”',
])
@pytest.mark.parametrize('purpose',['conversation','expense'])
def test_candidates_questions_negations_and_quotes_cannot_add(tmp_path,text,purpose):
    assert not bookkeeping_intent(text)
    tools,context=service(tmp_path,text,purpose)
    with pytest.raises(ValueError):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':59.22},'tool_call_id':'rejected'},context)
    with sqlite3.connect(tools.path) as db:assert db.execute('SELECT count(*) FROM effects').fetchone()[0]==0


@pytest.mark.parametrize('text,amount',[
    ('帮我记账，午饭没有金额',30),
    ('帮我记账三十元',30),
    ('记账30元',30),
    ('午饭35元，记一下',59.22),
    ('午饭35元，记一下',True),
    ('午饭35元，记一下',float('nan')),
    ('午饭35元，记一下',float('inf')),
    ('午饭35元，记一下',1e100),
    ('帮我記账午饭“59.22元”',59.22),
    ('记账，2026年10月3日午饭，没说金额',2026),
    ('午饭花了5分钟，记账',5),
    ('请记录会议3',3),
])
def test_amount_and_purpose_must_come_from_unquoted_current_human(tmp_path,text,amount):
    tools,context=service(tmp_path,text)
    with pytest.raises(ValueError):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':amount},'tool_call_id':'incomplete'},context)
    with sqlite3.connect(tools.path) as db:assert db.execute('SELECT count(*) FROM effects').fetchone()[0]==0


def test_expense_entry_supplies_only_intent_for_complete_current_expense(tmp_path):
    tools,context=service(tmp_path,'午饭三十五元','expense')
    assert not assignment('午饭三十五元','午饭三十五元')
    assert tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':35},'tool_call_id':'expense-entry'},context)['authorized']


def test_later_capability_question_cannot_reuse_old_source_amount(tmp_path):
    tools,original=service(tmp_path,'买零食花费五十九块二毛二。')
    mid=tools.conversation.submit('latest-capability-request-001','你能记账吗？')['message_id']
    current={**original,'origin_message_id':mid,'origin_request_id':'latest-capability-request-001'}
    with pytest.raises(ValueError):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':59.22},'tool_call_id':'wrong-history'},current)
    # Even a server-stage supplement cannot turn a capability question into a write.
    with tools.conversation.db() as db:
        db.execute('UPDATE messages SET supplement_to_message_id=? WHERE id=?',(original['origin_message_id'],mid))
    with pytest.raises(ValueError):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':59.22},'tool_call_id':'wrong-bound-history'},current)


def test_real_staged_reply_to_chat_is_valid_source_without_fabricating_task_intent(tmp_path):
    tools,original=service(tmp_path,'你好')
    mid=tools.conversation.submit('chat-supplement-source-001','我还是只想聊聊')['message_id']
    with tools.conversation.db() as db:
        db.execute('UPDATE messages SET supplement_to_message_id=? WHERE id=?',(original['origin_message_id'],mid))
    current={**original,'origin_message_id':mid,'origin_request_id':'chat-supplement-source-001'}
    assert tools.authorize_tool({'tool':'read','args':{'path':str(tmp_path/'example')},
                                'tool_call_id':'chat-source-read'},current)['authorized']
    with pytest.raises(ValueError,match='assignment'):
        authorized_assignment(tools.conversation,tools.proposals,{**current,'source_quote':'我还是只想聊聊',
            'agent':'pi','relative_cwd':'.','title':'伪造交办','prompt':'不能凭普通聊天派任务',
            'completion_condition':'真实任务','request_id':'chat-no-assignment-001'})


def test_continuation_does_not_manufacture_missing_purpose_from_server_labels(tmp_path):
    tools,original=service(tmp_path,'记账30元')
    mid=tools.conversation.submit('continue-missing-purpose-001','继续')['message_id']
    current={**original,'origin_message_id':mid,'origin_request_id':'continue-missing-purpose-001'}
    with pytest.raises(ValueError,match='缺少记账用途'):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':30},'tool_call_id':'missing-purpose'},current)


def test_normal_voice_fact_can_keep_real_quote_when_delegated(tmp_path):
    text='买零食花费五十九块二毛二。'
    tools,context=service(tmp_path,text)
    draft,authorization,key=authorized_assignment(tools.conversation,tools.proposals,{
        **context,'agent':'pi','relative_cwd':'.','title':'记录零食费用','prompt':'按用户原话处理',
        'sandbox':'danger-full-access','completion_condition':'新增回读匹配','source_quote':text,
        'request_id':'bookkeeping-task-request-001'})
    assert authorization['source_quote']==text and text in draft['prompt']
    task=tools.store.create_authorized(draft,authorization,key)
    tools.store.change(task['id'],'bookkeeping-task-running','started',status='running')
    with pytest.raises(ValueError,match='金额不在'):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':59},'tool_call_id':'wrong-task-amount'},
                             {**context,'task_id':task['id']})
    assert tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':59.22},'tool_call_id':'correct-task-amount'},
                                {**context,'task_id':task['id']})['authorized']
