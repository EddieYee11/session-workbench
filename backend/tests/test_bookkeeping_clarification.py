import sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from test_pi_safety import tool_service
from policy import source


def dialogue(tmp_path, original='帮我记一笔测试，一块还是一块五？',
             question='记账那句没听准，是记1块还是1块5？你回一个数我就记。',
             answer='一块五。'):
    tools, first = tool_service(tmp_path, original)
    chat = tools.conversation
    chat._assistant(first['origin_message_id'], question, status='completed')
    second = chat.submit('amount-confirmation-002', answer)
    return tools, first, {**first, 'origin_message_id':second['message_id'],
                         'origin_request_id':'amount-confirmation-002'}


@pytest.mark.parametrize('original',[
    '帮我记一笔测试，一块还是一块五？',
    '帮我记一笔午饭，金额待确认',
    '测试一下现在的速度如何，帮我再寄一个1块钱的测试机，张1块5的吧，还是？',
])
def test_amount_reply_inherits_real_pending_request(tmp_path, original):
    tools, first, ctx = dialogue(tmp_path, original)
    resolved = source(tools.conversation, ctx)
    assert resolved['authorization_parent_message_id'] == first['origin_message_id']
    assert len(resolved['source_links']) == 2
    args = {'tool':'bookkeeping','args':{'action':'add','amount':1.5,'comment':'测试'},'tool_call_id':'actual'}
    with pytest.raises(ValueError, match='本次确认'):
        tools.authorize_tool({**args,'args':{**args['args'],'amount':1}},ctx)
    assert tools.authorize_tool(args,ctx)['authorized']
    with pytest.raises(ValueError,match='禁止重复'):
        tools.authorize_tool(args,ctx)


@pytest.mark.parametrize('original,question,answer',[
    ('请查一下最近一块五的账目','这笔记账是多少？','一块五。'),
    ('不要记账，测试一块五','记账是记多少？','一块五。'),
    ('一块还是一块五','记账要记多少？','一块五。'),
    ('帮我记一笔测试，一块还是一块五？','电脑重启了吗？','一块五。'),
    ('帮我记一笔测试，一块还是一块五？','记账要记多少？','朋友说“一块五”。'),
    ('帮我记一笔测试，一块还是一块五？','记账要记多少？','明天一块五。'),
])
def test_unrelated_query_negation_or_quote_does_not_become_expense(tmp_path,original,question,answer):
    tools, _, ctx = dialogue(tmp_path,original,question,answer)
    with pytest.raises(ValueError):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':1.5}},ctx)


def test_stale_question_and_already_written_parent_are_not_replayed(tmp_path):
    tools, first, ctx = dialogue(tmp_path,'帮我记一笔测试，一块五。')
    args={'tool':'bookkeeping','args':{'action':'add','amount':1.5,'comment':'测试'}}
    assert tools.authorize_tool(args,first)['authorized']
    with pytest.raises(ValueError,match='原事项已有'):
        tools.authorize_tool(args,ctx)
    with tools.conversation.db() as db:
        db.execute("UPDATE messages SET created_at=created_at-1801 WHERE role='assistant'")
    assert 'bookkeeping_clarification' not in source(tools.conversation,ctx)


def test_discarding_shell_errors_does_not_trigger_overwrite_gate():
    from policy import deletion_risk
    assert not deletion_risk('bash',{'command':'ls /tmp 2>/dev/null'})
    assert deletion_risk('bash',{'command':'rm /tmp/a 2>/dev/null'})
    assert deletion_risk('bash',{'command':'echo replaced > /tmp/a'})


def test_plain_yes_on_confirm_card_books_the_card_amount(tmp_path):
    # 10-21：确认卡的「是」按钮不带金额，原来被拦，模型绕 60–80 秒
    card='记一笔 -980 · 人情社交·给女朋友买生日礼物（招商银行储蓄卡），记这笔账吗？确认金额后直接入账。'
    tools, first, ctx = dialogue(tmp_path, '给女朋友买生日礼物980', card, '是')
    args={'tool':'bookkeeping','args':{'action':'add','amount':980.0,'comment':'生日礼物'}}
    with pytest.raises(ValueError):
        tools.authorize_tool({**args,'args':{**args['args'],'amount':98.0}},ctx)
    assert tools.authorize_tool(args,ctx)['authorized']


@pytest.mark.parametrize('question,answer',[
    ('记账那句没听准，是记1块还是1块5？你回一个数我就记。','是'),   # 不是确认卡：纯「是」不知道记哪笔
    ('记一笔 -980 · 人情社交·礼物（招商银行储蓄卡），记这笔账吗？确认金额后直接入账。','是吗'),
])
def test_plain_yes_needs_a_confirm_card(tmp_path,question,answer):
    tools, _, ctx = dialogue(tmp_path,'给女朋友买生日礼物980',question,answer)
    with pytest.raises(ValueError):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':980.0}},ctx)
