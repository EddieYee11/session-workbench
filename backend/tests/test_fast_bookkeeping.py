"""确定性记账快通道：明确意图直写账本，模糊回退 Hermes。不碰真实账本。"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import business_tools
from conversation import PersonalConversation
from fast_bookkeeping import parse, receipt


def test_unauthorized_and_fuzzy_text_never_takes_the_fast_path():
    for text in (
        # 项目契约里明确不许写的句式
        '你能记账吗？', '不要记账，午饭59.22元', '我以后想记账，午饭59.22元',
        '请查一下最近午饭59.22元的记账', '假设买零食花费59.22元', '我朋友买零食花费59.22元',
        '引用：\n> 买零食花费59.22元，记账', '帮我记账，午饭没有金额', '记账30元',
        '午饭花了5分钟，记账', '帮我記账午饭“59.22元”',
        # 没有明确记账意图，或用途认不出
        '天气不错啊', '打车 30', '午饭 35', '茶五元，记账',
    ):
        assert parse(text) is None, text


def test_explicit_expense_parses_to_one_ledger_entry():
    plan = parse('记一笔 午饭 35')
    assert plan == {'amount': 35.0, 'category': '餐饮外卖',
                    'account': '招商银行储蓄卡', 'comment': '午饭'}
    assert receipt(plan) == '已记 -35 餐饮外卖·午饭'


def test_income_and_non_default_account_are_kept():
    assert receipt(parse('工资到账15000')).startswith('已记 +15000')
    assert parse('记账 打车 30 用花呗')['account'] == '花呗'


def _run(tmp_path, text, monkeypatch, *, verified=True):
    calls = []

    class FakeTools:
        def __init__(self, *args, **kwargs):
            pass

        async def call(self, tool, args, context):
            calls.append((tool, args, context))
            return {'verified': verified, 'id': '999', 'amount': args['amount'],
                    'category': args['category'], 'account': args.get('account', ''),
                    'comment': args.get('comment', '')}

    monkeypatch.setattr(business_tools, 'BusinessTools', FakeTools)
    chat = PersonalConversation(tmp_path)
    mid = chat.submit('fast-bookkeeping-request-001', text)['message_id']
    asyncio.run(chat.process_one())
    with chat.db() as db:
        row = db.execute('SELECT status,error FROM messages WHERE id=?', (mid,)).fetchone()
        reply = db.execute(
            "SELECT text FROM messages WHERE parent_id=? AND role='assistant'", (mid,)).fetchone()
    return row, (reply['text'] if reply else ''), calls


def test_explicit_entry_settles_without_hermes(tmp_path, monkeypatch):
    row, reply, calls = _run(tmp_path, '记账 打车 30', monkeypatch)
    assert row['status'] == 'completed' and reply == '已记 -30 出行交通·打车'
    assert calls[0][0] == 'bookkeeping' and calls[0][1]['action'] == 'add'
    assert calls[0][2]['origin_request_id'] == 'fast-bookkeeping-request-001'


def test_fuzzy_entry_falls_through_to_hermes_without_touching_the_ledger(tmp_path, monkeypatch):
    row, reply, calls = _run(tmp_path, '天气不错啊', monkeypatch)
    assert not calls
    # 落到 Hermes 客户端的表现：本机没有 hermes key。
    assert row['status'] == 'failed' and row['error'] == 'hermes_key_missing'


def test_unverified_write_is_reported_and_never_replayed(tmp_path, monkeypatch):
    row, reply, calls = _run(tmp_path, '记账 打车 30', monkeypatch, verified=False)
    assert len(calls) == 1 and row['status'] == 'unknown'
    assert '待核实' in reply and '请勿重复' in reply
