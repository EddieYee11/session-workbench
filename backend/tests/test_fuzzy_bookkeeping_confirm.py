"""模糊记账走二次确认卡片，不能落成旧账或直接绕过授权."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fast_bookkeeping import parse, parse_candidate
from conversation import PersonalConversation
from message_router import classify


def test_fuzzy_text_only_becomes_candidate():
    for text in ('午饭花的21。', 'Apple 礼品卡 145.65', '卖了旧书得三十八'):
        plan = parse_candidate(text)
        assert plan and plan['amount'] > 0, text
        assert plan['category'] and plan['account'], text
        assert parse(text) is None


def test_blocked_query_multi_amount_and_number_only_do_not_confirm():
    for text in (
        '假设买零食花费59.22元', '不要记账，午饭59.22元', '我朋友买零食花费59.22元',
        '查一下最近午饭59.22元的记账', '午饭59.22元 25', '145.65',
    ):
        assert parse_candidate(text) is None, text


def test_candidate_routes_to_confirmation_card():
    route = classify('Apple 礼品卡 145.65')
    assert route.tool == 'bookkeeping' and route.args['action'] == 'confirm'
    assert route.label == '待确认记账'


def test_confirm_route_outputs_card_without_ledger_call(tmp_path, monkeypatch):
    calls = []

    class FakeTools:
        async def call(self, *args, **kwargs):
            calls.append(args)
            raise AssertionError('候选确认不得写入')

    import asyncio
    import business_tools
    monkeypatch.setattr(business_tools, 'BusinessTools', FakeTools)
    chat = PersonalConversation(tmp_path)
    mid = chat.submit('candidate-confirm-001', '午饭花的21。')['message_id']
    asyncio.run(chat.process_one())
    assistant = [m for m in chat.snapshot()['messages'] if m['role'] == 'assistant'][-1]
    assert not calls
    assert '21' in assistant['text'] and assistant['status'] == 'completed'
    assert assistant['suggestions'] == ['是', '改一下', '不记']


# 2026-10-18 真实误判：正常提问/交办被当成记一笔（见 personal-conversation.sqlite 里的回复「记一笔 -0.3 · 购物消费」）
def test_real_misfires_are_never_bookkeeping():
    for text in (
        '帮我整理一下三角洲部队在所有的客户端，它的数据都是通的吗？包括安卓跟 iOS 上，它们能够一起连接玩',  # 三角 ≠ 3 毛
        '在 ~/AI_Work_System/work/工具与效率/会话工作台/docs 里找出修改时间最新的 3 份文档，列出文件名和一句话内容概括。',  # 3 份
        '我今天去了北鼎奥森，但是今天下雨，外边没有去拍摄那些照片，把这个事项的话帮我挪到周一，我周一的话需要',  # 周一 ≠ ¥1
        '对比一下国际上其他赛事，这次的成绩水平如何呢？',
        '帮我整理一下：现在的 com APP 是什么时候自己处理？什么时候调用派去处理复杂任务呢？',
    ):
        assert parse_candidate(text) is None, text
        assert parse(text) is None, text
        route = classify(text)
        assert not (route.tool == 'bookkeeping'), (text, route)


def test_numbers_that_are_not_money_are_not_amounts():
    from policy import _money_matches
    for text in ('三角洲部队', '三角形面积', '周一开会', '星期一提醒我', '第三名', '找出最新的 3 份文档', '第 5 页', '一共 4 台设备'):
        assert not _money_matches(text), (text, _money_matches(text))
    # 真金额不受影响
    assert [float(m[2]) for m in _money_matches('花了三毛')] == [0.3]
    assert [float(m[2]) for m in _money_matches('发快递花了15块')] == [15.0]


def test_real_expense_statements_still_work():
    for text in ('午饭花的21。', 'Apple 礼品卡 145.65', '卖了旧书得三十八', '发快递花费 12.5', '充网费花费70块。', '我今天发快递花了15块钱。'):
        assert parse(text) or parse_candidate(text), text
