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
        # 没有明确记账意图，或用途认不出（茶/花的 已进快通道，见下）
        '天气不错啊', '打车 30', '午饭 35',
        'Apple 礼品卡 145.65',
        # 无单位中文数字是数量、不是金额
        '我买了十本书', '跑了五公里', '今天下午十点开会', '这本书一百页', '花了三十个积分',
    ):
        assert parse(text) is None, text


def test_explicit_expense_parses_to_one_ledger_entry():
    plan = parse('记一笔 午饭 35')
    assert plan == {'amount': 35.0, 'category': '餐饮外卖',
                    'account': '招商银行储蓄卡', 'comment': '午饭'}
    assert receipt(plan) == '已记 -35 餐饮外卖·午饭'


def test_spoken_category_aliases_take_the_fast_path():
    """口语漏词要进快通道，不能静默回落到 Hermes。"""
    assert parse('茶五元，记账')['category'] == '餐饮外卖'
    assert parse('午饭花的21') == {
        'amount': 21.0, 'category': '餐饮外卖',
        'account': '招商银行储蓄卡', 'comment': '午饭'}
    assert parse('记账 美团外卖 42')['category'] == '餐饮外卖'
    # 「记一下」+ 裸数字（省略元/块）也应直写，不回落 Hermes。
    assert parse('记一下咖啡18') == {
        'amount': 18.0, 'category': '餐饮外卖',
        'account': '招商银行储蓄卡', 'comment': '咖啡'}
    assert parse('帮我记一下咖啡18') == {
        'amount': 18.0, 'category': '餐饮外卖',
        'account': '招商银行储蓄卡', 'comment': '咖啡'}
    assert parse('记下星巴克25') == {
        'amount': 25.0, 'category': '餐饮外卖',
        'account': '招商银行储蓄卡', 'comment': '星巴克'}
    assert parse('帮我记一下打车36') == {
        'amount': 36.0, 'category': '出行交通',
        'account': '招商银行储蓄卡', 'comment': '打车'}
    assert parse('记一下奶茶22')['amount'] == 22.0
    # 无记账动词的裸数字仍不直写
    assert parse('美团外卖32') is None
    assert parse('星巴克25') is None


def test_bare_number_bookkeeping_edges_overnight():
    """过夜补强：空格、句末动词、中文数字、否定/查询不得进快通道。"""
    assert parse('记下外卖40') == {
        'amount': 40.0, 'category': '餐饮外卖',
        'account': '招商银行储蓄卡', 'comment': '外卖'}
    assert parse('请记一下地铁15') == {
        'amount': 15.0, 'category': '出行交通',
        'account': '招商银行储蓄卡', 'comment': '地铁'}
    assert parse('记一下 咖啡 18')['amount'] == 18.0
    assert parse('咖啡18记一下')['amount'] == 18.0
    assert parse('记一下咖啡十八')['amount'] == 18.0
    for text in ('不要记一下咖啡18', '查一下咖啡18的记账', '星巴克25', '美团外卖32'):
        assert parse(text) is None, text


def test_income_and_non_default_account_are_kept():
    assert receipt(parse('工资到账15000')).startswith('已记 +15000')
    assert parse('记账 打车 30 用花呗')['account'] == '花呗'


def test_unitless_chinese_amount_from_voice_is_recorded():
    """语音常说“剪头发花费一百一十四”，无单位中文数字也必须落账。"""
    assert parse('剪头发花费一百一十四。') == {
        'amount': 114.0, 'category': '个护美容',
        'account': '招商银行储蓄卡', 'comment': '剪头发'}
    assert receipt(parse('午饭花了三十五')) == '已记 -35 餐饮外卖·午饭'


def _run(tmp_path, text, monkeypatch, *, verified=True):
    calls = []

    class FakeTools:
        def __init__(self, *args, **kwargs):
            pass

        async def call(self, tool, args, context):
            amount = args.get('amount', 0) if isinstance(args, dict) else 0
            calls.append((tool, args, context))
            return {'verified': verified, 'id': '999', 'amount': amount,
                    'category': args.get('category') if isinstance(args, dict) else '',
                    'account': args.get('account', ''), 'comment': args.get('comment', '')}

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
