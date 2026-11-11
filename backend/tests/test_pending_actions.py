"""测试线 B：一句话确认执行（pending_actions.py）+ 数据新旧提示 + 语气文案。"""
import asyncio
import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from context_builder import build
from context_working_set import MARKER
from conversation import PersonalConversation
from hermes_prompt import SYSTEM_PROMPT
from message_router import MessageRouter
from pending_actions import PendingActions, data_freshness
from reply_style import REPLY_STYLE


def test_register_and_affirm_executes_via_fast_path(tmp_path, monkeypatch):
    """登记待确认动作后，用户回短肯定或命中确认词走 message_router L0 快路径直接执行，不再调大模型。"""
    import business_tools

    calls = []

    class FakeBusiness:
        def __init__(self, *_):
            pass

        async def call(self, tool, args, context):
            calls.append((tool, args, context))
            return {'verified': True, 'id': 'bk-1', **args}

    monkeypatch.setattr(business_tools, 'BusinessTools', FakeBusiness)

    pa = PendingActions(tmp_path)
    registered = pa.register(
        description='叫快车去搜狐媒体大厦（¥16）',
        confirm_word='叫',
        action={'tool': 'bookkeeping', 'args': {'action': 'add', 'amount': 16.0, 'category': '出行交通', 'comment': '快车'}},
    )
    assert registered['status'] == 'pending'
    assert registered['confirm_word'] == '叫'

    # 模型的 stream_chat 若被调用会报错，证明走了 L0 快路径
    class NoModelHermes:
        def key(self):
            return 'fixture'

        async def create_session(self):
            return 'com-personal-main'

        async def stream_chat(self, *_):
            raise AssertionError('Should not invoke LLM on pending action fast path')
            yield  # pragma: no cover

    chat = PersonalConversation(tmp_path, NoModelHermes())
    chat.submit('req-affirm-001', '好 叫吧')
    asyncio.run(chat.process_one())

    assert len(calls) == 1
    assert calls[0][0] == 'bookkeeping' and calls[0][1]['amount'] == 16.0
    reply = [m for m in chat.snapshot()['messages'] if m['role'] == 'assistant'][-1]
    assert '已记 -16 出行交通·快车' in reply['text']
    assert pa.active() is None
    assert pa.get(registered['id'])['status'] == 'executed'

    with sqlite3.connect(tmp_path / 'message-routing.sqlite') as db:
        row = db.execute('SELECT route, prompt_chars FROM decisions WHERE request_id=?', ('req-affirm-001',)).fetchone()
    assert json.loads(row[0])['level'] == 'L0' and row[1] == 0


@pytest.mark.parametrize('word', ['好', '可以', '行', '发吧', '就这个', '嗯', '订', '好，订吧'])
def test_various_short_affirmatives_match_pending_action(tmp_path, word):
    pa = PendingActions(tmp_path)
    pa.register('订明天去武汉的高铁票', '订', {'tool': 'remind', 'args': {'action': 'add', 'text': '订票'}})
    router = MessageRouter(tmp_path)
    route = router.decide(f'req-{word}', word)
    assert route.level == 'L0' and route.tool == 'pending_action'
    assert route.args['decision'] == 'affirm'


@pytest.mark.parametrize('word', ['算了', '不用', '先别', '不叫了', '再想想'])
def test_short_negation_cancels_pending_action(tmp_path, word):
    pa = PendingActions(tmp_path)
    item = pa.register('叫快车 ¥16', '叫', {'tool': 'remind', 'args': {'action': 'add', 'text': '叫车'}})

    chat = PersonalConversation(tmp_path)
    chat.submit('req-negate-001', word)
    asyncio.run(chat.process_one())

    reply = [m for m in chat.snapshot()['messages'] if m['role'] == 'assistant'][-1]
    assert '已取消' in reply['text'] and '叫快车 ¥16' in reply['text']
    assert pa.active() is None
    assert pa.get(item['id'])['status'] == 'cancelled'


def test_expired_action_does_not_trigger(tmp_path):
    now = [10000.0]
    pa = PendingActions(tmp_path, clock=lambda: now[0])
    item = pa.register('记一笔午饭 30 元', '记', {'tool': 'bookkeeping', 'args': {'action': 'add', 'amount': 30}}, ttl_seconds=1800)
    assert pa.active() is not None

    # 超过 30 分钟后过期
    now[0] += 1801.0
    assert pa.active() is None
    assert pa.match('好') is None
    assert pa.get(item['id'])['status'] == 'expired'


def test_unrelated_message_preserves_pending_action(tmp_path):
    pa = PendingActions(tmp_path)
    item = pa.register('叫快车去公司 ¥16', '叫', {'tool': 'remind', 'args': {'action': 'add', 'text': '叫车'}})

    router = MessageRouter(tmp_path)
    for text in ('今天北京天气怎么样？', '帮我查一下最近账单', '好久不见，最近忙什么呢？', '可以帮我看看这个报错吗？'):
        route = router.decide('req-' + text[:4], text)
        assert route.tool != 'pending_action'

    # 待确认动作依然保留未触发
    active = pa.active()
    assert active is not None and active['id'] == item['id'] and active['status'] == 'pending'


@pytest.mark.parametrize(
    'desc,action,expected_label',
    [
        ('给品牌方回复合作报价邮件', {'category': 'email_send', 'prompt': '发送报价邮件'}, '邮件发送'),
        ('给老马提交劳务报酬付款单 1500 元', {'category': 'payment_submit', 'prompt': '提交劳务费'}, '付款与报销提交'),
        ('把全国岩馆路书第三期发布到搜狐视频和视频号', {'category': 'content_publish', 'prompt': '发布视频'}, '内容发布'),
    ],
)
def test_gated_actions_only_prepare_and_stop_before_button(tmp_path, desc, action, expected_label):
    """属于邮件发送、付款提交、内容发布三类的动作，确认后只准备到按钮前并在回执里说明。"""
    from tasks import TaskStore

    task_store = TaskStore(tmp_path)
    pa = PendingActions(tmp_path)
    item = pa.register(desc, '发', action)
    assert item['gated_kind'] == expected_label

    res = asyncio.run(pa.execute(item['id'], request_id='req-gated-12345', task_store=task_store))
    assert res['status'] == 'prepared'
    assert expected_label in res['receipt']
    assert '停在最后一步' in res['receipt'] and '自己点' in res['receipt']
    tasks = task_store.list()
    assert len(tasks) == 1
    assert '严禁直接点击发送/提交/发布按钮' in tasks[0]['prompt']


def test_data_freshness_marks_stale_location_and_calendar(tmp_path):
    """定位 > 2h、日历 > 6h 标「较旧」；无数据时跳过不编造。"""
    now = 1762760000.0  # 固定时间戳
    assert data_freshness(tmp_path, now=now) == {}

    # 构造 devices.sqlite（定位 3 小时前 -> 较旧）
    with sqlite3.connect(tmp_path / 'devices.sqlite') as db:
        db.execute('CREATE TABLE devices(id TEXT PRIMARY KEY, data TEXT)')
        db.execute('CREATE TABLE invocations(id TEXT PRIMARY KEY, node TEXT, fingerprint TEXT, data TEXT)')
        db.execute(
            'INSERT INTO invocations VALUES (?,?,?,?)',
            ('inv1', 'node_1', 'fp', json.dumps({'tool': 'location.last', 'status': 'succeeded', 'finished_at': now - 3 * 3600})),
        )

    # 构造 personal-hub.sqlite（日历 7 小时前 -> 较旧；记账 30 分钟前 -> 正常；健康未同步 -> 跳过）
    with sqlite3.connect(tmp_path / 'personal-hub.sqlite') as db:
        db.execute('CREATE TABLE sources(name TEXT PRIMARY KEY, data TEXT)')
        db.execute('CREATE TABLE matters(id TEXT PRIMARY KEY, source TEXT, source_id TEXT, data TEXT)')
        db.execute('INSERT INTO sources VALUES (?,?)', ('apple_calendar', json.dumps({'updated_at': now - 7 * 3600})))
        db.execute('INSERT INTO sources VALUES (?,?)', ('accounting', json.dumps({'updated_at': now - 1800})))

    fresh = data_freshness(tmp_path, now=now)
    items = fresh['items']
    assert items['location']['stale'] is True and items['location']['status'] == '较旧'
    assert items['calendar']['stale'] is True and items['calendar']['status'] == '较旧'
    assert items['accounting']['stale'] is False and 'status' not in items['accounting']
    assert 'health' not in items
    assert '较旧' in fresh['summary']

    # 验证 build() 将 data_freshness 注入主对话上下文，且总长度仍在预算内
    working = build(tmp_path, MARKER + json.dumps({'origin_request_id': 'r1'}) + '\n用户消息：\n打车去公司')
    assert 'data_freshness' in working.instructions
    assert '较旧' in working.instructions
    assert len(working.instructions) < 2200


def test_tone_and_prompt_contract_and_budget():
    assert len(SYSTEM_PROMPT) < 2150
    for required in ('明确建议', '**标签**：值', '回我一句「X」就', '[[选项: X | 再想想]]', '人情话', 'pending_action_register'):
        assert required in SYSTEM_PROMPT
        assert required in REPLY_STYLE


def test_item1_enqueue_task_reuses_authorized_assignment_and_deletion_goes_to_approval(tmp_path):
    """项 1：_enqueue_task 复用 authorized_assignment（真实确认消息+原登记消息），删除/清空转 propose_work 审批卡，业务工具走 authorize_tool。"""
    from agent_tools import AgentTools
    from tasks import TaskStore
    from work_dispatch import WorkProposalStore

    chat = PersonalConversation(tmp_path)
    task_store = TaskStore(tmp_path)
    proposals = WorkProposalStore(tmp_path, tmp_path)
    tools = AgentTools(tmp_path, chat, proposals, task_store, None, None, None)

    # 1a. 正常任务：登记时记录真实用户消息，确认时复用 authorized_assignment 校验并入队
    u1 = chat.submit('req-task-orig-001', '帮我准备本周报销票据汇总表')
    sid = 'com-personal-main'
    with chat.db() as db:
        db.execute("INSERT OR REPLACE INTO meta(key,value) VALUES('hermes_session_id',?)", (sid,))
        db.execute("UPDATE messages SET status='completed' WHERE id=?", (u1['message_id'],))
    reg = asyncio.run(
        tools.call(
            'pending_action_register',
            {
                'description': '准备本周报销票据汇总表',
                'confirm_word': '准备',
                'action': {'tool': 'task', 'title': '准备本周报销票据汇总表', 'prompt': '帮我准备本周报销票据汇总表'},
            },
            {
                'origin_session_id': sid,
                'origin_message_id': u1['message_id'],
                'origin_request_id': 'req-task-orig-001',
            },
        )
    )
    assert reg['status'] == 'pending'
    chat.submit('req-task-confirm-001', '好')
    asyncio.run(chat.process_one())
    tasks = task_store.list()
    assert any(t['title'] == '准备本周报销票据汇总表' and t['status'] in ('queued', 'running', 'succeeded') for t in tasks)

    # 1b. 伪造不存在的 origin_message_id 时，确认阶段被 source() / authorized_assignment 拒绝
    pa = PendingActions(tmp_path)
    fake_task = pa.register(
        '后台静默任务',
        '跑',
        {'tool': 'task', 'title': '未授权任务', 'prompt': '后台静默任务'},
        context={'origin_session_id': sid, 'origin_message_id': 'msg_nonexistent_fake', 'origin_request_id': 'req-fake-0001'},
    )
    with pytest.raises(ValueError, match='需要真实用户消息'):
        asyncio.run(pa.execute(fake_task['id'], request_id='req-fake-confirm-01', task_store=task_store))
    assert pa.get(fake_task['id'])['status'] == 'failed'

    # 1c. 不可逆删除/清空动作（无论 task 还是 tool）一律转 propose_work 审批卡，绝不因「好」直接执行
    u_del = chat.submit('req-del-orig-001', '帮我清空旧的测试缓存数据')
    del_item = pa.register(
        '清空旧的测试缓存数据',
        '清',
        {'tool': 'remind', 'args': {'action': 'delete', 'id': 'rem-1'}},
        context={
            'origin_session_id': sid,
            'origin_message_id': u_del['message_id'],
            'origin_request_id': 'req-del-orig-001',
            'origin_user_text': '帮我清空旧的测试缓存数据',
        },
    )
    u_del_confirm = chat.submit('req-del-confirm-001', '好')
    res_del = asyncio.run(
        pa.execute(
            del_item['id'],
            request_id='req-del-confirm-001',
            message_id=u_del_confirm['message_id'],
            session_id=sid,
            task_store=task_store,
        )
    )
    assert res_del['status'] == 'approval_required'
    assert res_del.get('proposal_id')
    assert any(t['id'] == res_del['proposal_id'] and t['status'] == 'approval_required' for t in task_store.list())

    # 1d. 业务工具调用经过 authorize_tool：若记账金额未出现在用户原话中则拒绝执行
    u_bk = chat.submit('req-bk-orig-001', '记一笔午饭 25 元')
    tampered = pa.register(
        '记一笔午饭 999 元',
        '记',
        {'tool': 'bookkeeping', 'args': {'action': 'add', 'amount': 999, 'category': '餐饮', 'comment': '午饭'}},
        context={
            'origin_session_id': sid,
            'origin_message_id': u_bk['message_id'],
            'origin_request_id': 'req-bk-orig-001',
            'origin_user_text': '记一笔午饭 25 元',
        },
    )
    u_bk_confirm = chat.submit('req-bk-confirm-001', '好')
    with pytest.raises(ValueError, match='金额不在真实用户消息中'):
        asyncio.run(
            pa.execute(
                tampered['id'],
                request_id='req-bk-confirm-001',
                message_id=u_bk_confirm['message_id'],
                session_id=sid,
                task_store=task_store,
            )
        )
    assert pa.get(tampered['id'])['status'] == 'failed'


def test_item2_gated_actions_without_passed_task_store_create_prepare_task_and_accurate_receipt(tmp_path):
    """项 2：对外三类动作在未显式传 task_store（如走 MessageRouter / PersonalConversation）时按需实例化 TaskStore 入队准备任务。"""
    from tasks import TaskStore

    pa = PendingActions(tmp_path)
    item = pa.register(
        '给张总发送合同确认邮件',
        '发',
        {'category': 'email_send', 'prompt': '拟好给张总的合同确认邮件并填好收件人'},
    )
    assert item['gated_kind'] == '邮件发送'

    chat = PersonalConversation(tmp_path)
    chat.submit('req-gated-route-001', '好，发吧')
    asyncio.run(chat.process_one())

    reply = [m for m in chat.snapshot()['messages'] if m['role'] == 'assistant'][-1]
    assert '邮件发送' in reply['text']
    assert '停在最后一步' in reply['text'] and '自己点' in reply['text']

    tasks = TaskStore(tmp_path).list()
    assert len(tasks) == 1
    assert '严禁直接点击发送/提交/发布按钮' in tasks[0]['prompt']
    assert tasks[0]['id'] in reply['text']


@pytest.mark.parametrize(
    'desc,action,expected_label',
    [
        ('把这期图文发小红书', {'prompt': '上传图文笔记'}, '内容发布'),
        ('今晚八点发抖音和视频号', {'prompt': '上传竖屏成片'}, '内容发布'),
        ('同步发微博和发B站动态', {'prompt': '发布动态'}, '内容发布'),
        ('给摄影师提劳务 800 元', {'prompt': '填写 PR 劳务单'}, '付款与报销提交'),
        ('帮我付劳务费给嘉宾並提报销', {'prompt': '报销单与付款申请'}, '付款与报销提交'),
        ('用 gmail send 给客户发报价单', {'prompt': 'gmail send'}, '邮件发送'),
        ('调用工具执行动作', {'tool': 'shell', 'args': {'cmd': 'gws gmail 发送 周报邮件'}}, '邮件发送'),
        ('调用工具执行动作', {'tool': 'browser', 'args': {'step': '发小红书草稿并提交'}}, '内容发布'),
        ('调用工具执行动作', {'tool': 'pr', 'args': {'step': '提劳务报酬申请'}}, '付款与报销提交'),
    ],
)
def test_item3_gated_kind_regex_covers_social_publish_labor_expense_and_gmail_send(tmp_path, desc, action, expected_label):
    """项 3：对外三类判定不信任模型自填 category，覆盖发小红书/抖音/视频号/微博/B站、提/付劳务/报销/付款、gmail send / gws gmail 发送，且匹配描述与参数。"""
    pa = PendingActions(tmp_path)
    item = pa.register(desc, '发', action)
    assert item['gated_kind'] == expected_label


def test_item4_execute_atomically_claims_running_and_prevents_concurrent_duplicate_execution(tmp_path, monkeypatch):
    """项 4：PendingActions.execute 在 await 前用 UPDATE ... status='running' WHERE status='pending' 原子抢占，并发调用不重复执行。"""
    import business_tools

    calls = []

    class SlowBusiness:
        def __init__(self, *_):
            pass

        async def call(self, tool, args, context):
            calls.append((tool, args))
            await asyncio.sleep(0.05)
            return {'verified': True, 'id': 'rem-atomic-1', **args}

    monkeypatch.setattr(business_tools, 'BusinessTools', SlowBusiness)

    pa = PendingActions(tmp_path)
    item = pa.register(
        '明早九点提醒我开会',
        '提',
        {'tool': 'remind', 'args': {'action': 'add', 'text': '开会'}},
    )

    async def run_both():
        return await asyncio.gather(
            pa.execute(item['id'], request_id='req-concurrent-1'),
            pa.execute(item['id'], request_id='req-concurrent-2'),
        )

    r1, r2 = asyncio.run(run_both())
    assert len(calls) == 1
    already = [r for r in (r1, r2) if r.get('already_processed')]
    fresh = [r for r in (r1, r2) if not r.get('already_processed')]
    assert len(already) == 1 and len(fresh) == 1
    assert fresh[0]['status'] == 'executed'
    assert pa.get(item['id'])['status'] == 'executed'


def test_item5_pending_action_register_requires_source_and_fast_bookkeeping_checks_verified_and_real_error(tmp_path, monkeypatch):
    """项 5：agent_tools.pending_action_register 校验真实用户消息 source()；conversation 快路径记账检查 verified 并报真实错误。"""
    import business_tools
    from agent_tools import AgentTools
    from tasks import TaskStore
    from work_dispatch import WorkProposalStore

    chat = PersonalConversation(tmp_path)
    tools = AgentTools(tmp_path, chat, WorkProposalStore(tmp_path, tmp_path), TaskStore(tmp_path), None, None, None)

    # 5a. 无真实用户消息 source 时拒绝 pending_action_register
    with pytest.raises(ValueError, match='真实用户消息|source'):
        asyncio.run(
            tools.call(
                'pending_action_register',
                {
                    'description': '偷偷登记动作',
                    'confirm_word': '好',
                    'action': {'tool': 'remind', 'args': {'action': 'add', 'text': 'x'}},
                },
                {},
            )
        )

    # 5b. pending_action 记账返回 verified=False 时，不伪报「已记」，标为 unknown 并提示未拿到落盘确认
    class UnverifiedBusiness:
        def __init__(self, *_):
            pass

        async def call(self, tool, args, context):
            return {'verified': False, 'amount': 16.0, 'category': '餐饮', 'comment': '午饭'}

    monkeypatch.setattr(business_tools, 'BusinessTools', UnverifiedBusiness)
    pa = PendingActions(tmp_path)
    pa.register(
        '记一笔午饭 16 元',
        '记',
        {'tool': 'bookkeeping', 'args': {'action': 'add', 'amount': 16.0, 'category': '餐饮', 'comment': '午饭'}},
    )
    chat.submit('req-unverified-bk', '好')
    asyncio.run(chat.process_one())
    snap = chat.snapshot()
    last_msg = [m for m in snap['messages'] if m['role'] == 'assistant'][-1]
    assert '未取得账本写入及回读凭据' in last_msg['text']
    assert last_msg['status'] == 'unknown'

    # 5c. pending_action 快路径执行失败时，绝不把内部错误原文直接回给用户，降级让模型正常跑这一轮并记错误日志
    async def boom_execute(*_a, **_kw):
        raise RuntimeError('数据库连接超时：disk I/O error')

    fallback_client = _ScriptedHermes(['已由模型兜底处理设置提醒。'])
    chat.client = fallback_client
    pa.register(
        '设置提醒测试异常',
        '设',
        {'tool': 'remind', 'args': {'action': 'add', 'text': '测试'}},
    )
    monkeypatch.setattr(PendingActions, 'execute', boom_execute)
    chat.submit('req-boom-pa', '好')
    asyncio.run(chat.process_one())
    last_reply = [m for m in chat.snapshot()['messages'] if m['role'] == 'assistant'][-1]
    assert '数据库连接超时：disk I/O error' not in last_reply['text']
    assert '业务查询暂不可用' not in last_reply['text']
    assert '已由模型兜底处理设置提醒' in last_reply['text']
    assert len(fallback_client.received_prompts) == 1


@pytest.mark.parametrize('past_word', ['发了', '叫了', '记了', '订了', '我已经发了'])
def test_item6_confirm_word_rejects_past_tense_le_and_affirm_plus_negate_cancels(tmp_path, past_word):
    """项 6：「发了/叫了/记了」完成态不误触 affirm；「好，算了」「行吧不用了」等先肯定后否定判为 negate。"""
    pa = PendingActions(tmp_path)
    for cw in ('发', '叫', '记', '订'):
        pa.register(f'测试动作-{cw}', cw, {'tool': 'remind', 'args': {'action': 'add', 'text': cw}})
        assert pa.match(past_word) is None

    for cancel_phrase in ('好，算了', '行吧不用了', '好，不叫了', '可以，还是算了', '嗯不用了'):
        item = pa.register('叫快车 ¥16', '叫', {'tool': 'remind', 'args': {'action': 'add', 'text': '叫车'}})
        matched = pa.match(cancel_phrase)
        assert matched is not None and matched['decision'] == 'negate', f'{cancel_phrase} should negate'
        res = pa.cancel(item['id'])
        assert res['status'] == 'cancelled'


def test_item7_data_freshness_no_device_last_seen_fallback_handles_ms_timestamps_and_builds_once(tmp_path, monkeypatch):
    """项 7：data_freshness 去掉设备 last_seen 冒充定位时间、毫秒时间戳除 1000、context_builder.build 每轮只算一次。"""
    import pending_actions

    now = 1762760000.0

    # 7a. 只有 devices 表 last_seen、没有 location 工具调用时，不生成伪造的 location 新鲜度
    with sqlite3.connect(tmp_path / 'devices.sqlite') as db:
        db.execute('CREATE TABLE devices(id TEXT PRIMARY KEY, data TEXT)')
        db.execute('CREATE TABLE invocations(id TEXT PRIMARY KEY, node TEXT, fingerprint TEXT, data TEXT)')
        db.execute('INSERT INTO devices VALUES (?,?)', ('dev1', json.dumps({'last_seen': now - 10 * 3600})))

    assert data_freshness(tmp_path, now=now) == {}

    # 7b. 毫秒级时间戳（> 1e12）自动除以 1000：10 分钟前的毫秒时间戳为新鲜，3 小时前的毫秒时间戳为较旧且分钟数准确
    with sqlite3.connect(tmp_path / 'devices.sqlite') as db:
        db.execute(
            'INSERT INTO invocations VALUES (?,?,?,?)',
            ('inv-ms', 'node_1', 'fp', json.dumps({'tool': 'location.last', 'status': 'succeeded', 'finished_at': int((now - 3 * 3600) * 1000)})),
        )
    with sqlite3.connect(tmp_path / 'personal-hub.sqlite') as db:
        db.execute('CREATE TABLE sources(name TEXT PRIMARY KEY, data TEXT)')
        db.execute('INSERT INTO sources VALUES (?,?)', ('apple_calendar', json.dumps({'updated_at': int((now - 600) * 1000)})))

    fresh = data_freshness(tmp_path, now=now)
    assert fresh['items']['location']['stale'] is True
    assert fresh['items']['location']['age_minutes'] == 180
    assert fresh['items']['calendar']['stale'] is False
    assert fresh['items']['calendar']['age_minutes'] == 10

    # 7c. context_builder.build 已有 data_freshness 时不重复计算
    call_count = [0]
    orig_fn = pending_actions.data_freshness

    def counting_df(state, *a, **kw):
        call_count[0] += 1
        return orig_fn(state, *a, **kw)

    monkeypatch.setattr(pending_actions, 'data_freshness', counting_df)
    build(tmp_path, MARKER + json.dumps({'origin_request_id': 'r1', 'data_freshness': {'summary': '预设'}}) + '\n用户消息：\n你好')
    assert call_count[0] == 0
    build(tmp_path, MARKER + json.dumps({'origin_request_id': 'r2'}) + '\n用户消息：\n你好')
    assert call_count[0] == 1


def test_minor_unknown_tool_fails_honestly_and_pi_native_history_includes_fast_path_turns(tmp_path):
    """顺手修：未知 tool 诚实报错并置 status='failed' 不伪报已执行；pi_main 原生历史开启时仍包含 L0 快路径回合（run_id IS NULL）。"""
    pa = PendingActions(tmp_path)
    item = pa.register('执行未知工具动作', '执', {'tool': 'nonexistent_magic_tool', 'args': {'x': 1}})
    with pytest.raises(ValueError, match='未知或不支持的工具'):
        asyncio.run(pa.execute(item['id'], request_id='req-unknown-tool'))
    assert pa.get(item['id'])['status'] == 'failed'

    # 验证 pi_main (has_native_history=True, runtime_name='pi') 的 _pi_input 包含快路径生成的无 run_id 消息
    class FakePiNativeClient:
        has_native_history = True
        runtime_name = 'pi'

        def key(self):
            return 'pi:native-test'

        async def create_session(self):
            return 'pi-session-1'

    chat = PersonalConversation(tmp_path, FakePiNativeClient())
    pa2 = PendingActions(tmp_path)
    pa2.register('取消测试快路径动作', '叫', {'tool': 'remind', 'args': {'action': 'add', 'text': '叫车'}})
    chat.submit('req-fast-turn', '算了')
    asyncio.run(chat.process_one())

    u2 = chat.submit('req-next-llm-turn', '刚才取消了什么？')
    with chat.db() as db:
        user_row = db.execute('SELECT * FROM messages WHERE id=?', (u2['message_id'],)).fetchone()
    pi_text, _ = chat._pi_input(user_row, 'pi-session-1', 'tok-1')
    assert '已取消：取消测试快路径动作' in pi_text


class _ScriptedHermes:
    def __init__(self, replies, on_turn=None):
        self.replies = list(replies)
        self.on_turn = on_turn
        self.received_prompts = []

    def key(self):
        return 'fixture'

    async def create_session(self):
        return 'com-personal-main'

    async def stream_chat(self, session_id, text):
        self.received_prompts.append(text)
        if self.on_turn:
            self.on_turn(len(self.received_prompts), session_id, text)
        reply = self.replies.pop(0) if self.replies else '已执行完毕。'
        yield 'run.started', {'run_id': f'run-{len(self.received_prompts)}'}
        yield 'assistant.completed', {'content': reply}
        yield 'run.completed', {}
        yield 'done', {}


def test_auto_register_when_reply_has_confirm_phrase_without_registration(tmp_path):
    """有确认句无登记 → 自动登记：confirm_word=X，description=回复首句（去 ** 加粗，≤60 字），action={'tool':'confirm_to_model'}，context 完整，ttl=1800。"""
    reply_text = (
        '**帮你设好明天早上 9:00 交周报的提醒。**\n'
        '**时间**：明天 09:00\n'
        '回我一句「加」就写进系统提醒。\n'
        '[[选项: 加 | 再想想]]'
    )
    client = _ScriptedHermes([reply_text])
    chat = PersonalConversation(tmp_path, client)
    u = chat.submit('req-auto-reg-001', '明天早上九点提醒我交周报')
    asyncio.run(chat.process_one())

    pa = PendingActions(tmp_path)
    active = pa.active()
    assert active is not None
    assert active['confirm_word'] == '加'
    assert active['description'] == '帮你设好明天早上 9:00 交周报的提醒'
    assert '**' not in active['description'] and len(active['description']) <= 60
    assert active['action'] == {'tool': 'confirm_to_model'}
    ctx = active['context']
    assert ctx['origin_session_id'] == 'com-personal-main'
    assert ctx['origin_message_id'] == u['message_id']
    assert ctx['origin_request_id'] == 'req-auto-reg-001'
    assert ctx['origin_user_text'] == '明天早上九点提醒我交周报'
    assert round(active['expires_at'] - active['created_at']) == 1800


def test_auto_register_skips_when_same_turn_already_registered(tmp_path):
    """已有登记不重复：同一轮已调用 pending_action_register 时，回复落库不再重复自动登记。"""
    pa = PendingActions(tmp_path)
    chat_ref = []
    user_ref = []
    registered_ref = []

    def on_turn(turn_idx, sid, _text):
        item = pa.register(
            description='写进系统提醒：明天 9:00 交周报',
            confirm_word='加',
            action={'tool': 'remind', 'args': {'action': 'add', 'at': '2026-11-11 09:00', 'text': '交周报'}},
            context={
                'origin_session_id': sid,
                'origin_message_id': user_ref[0]['message_id'],
                'origin_request_id': 'req-no-dup-001',
                'origin_user_text': '明天早上九点提醒我交周报',
            },
        )
        registered_ref.append(item)

    client = _ScriptedHermes(
        ['**写进系统提醒：明天 9:00 交周报。**回我一句「加」就写进系统提醒。'],
        on_turn=on_turn,
    )
    chat = PersonalConversation(tmp_path, client)
    chat_ref.append(chat)
    u = chat.submit('req-no-dup-001', '明天早上九点提醒我交周报')
    user_ref.append(u)
    asyncio.run(chat.process_one())

    active = pa.active()
    assert active is not None
    assert active['id'] == registered_ref[0]['id']
    assert active['action']['tool'] == 'remind'
    with pa.db() as db:
        count = db.execute('SELECT COUNT(*) FROM pending_actions').fetchone()[0]
    assert count == 1


def test_affirm_triggers_confirm_to_model_submits_new_turn_with_description(tmp_path):
    """affirm 触发 confirm_to_model：快路径立刻回「好，马上办。」，并向主对话提交带 description 的新一轮指令；删除类仍走审批。"""
    client = _ScriptedHermes(
        [
            '**帮你设好明天早上 9:00 交周报的提醒。**\n回我一句「加」就写进系统提醒。',
            '已为你写进系统提醒：明天 09:00 交周报。',
        ]
    )
    chat = PersonalConversation(tmp_path, client)
    u1 = chat.submit('req-c2m-turn1', '明天早上九点交周报')
    asyncio.run(chat.process_one())

    pa = PendingActions(tmp_path)
    auto_item = pa.active()
    assert auto_item is not None and auto_item['action']['tool'] == 'confirm_to_model'
    desc = auto_item['description']

    # 用户回「加」命中 L0 快路径
    u2 = chat.submit('req-c2m-affirm', '加')
    asyncio.run(chat.process_one())

    # 1) 快路径本身未调用第二轮 stream_chat，且对 u2 立刻返回「好，马上办。」
    assert len(client.received_prompts) == 1
    msgs = chat.snapshot()['messages']
    u2_reply = next(m for m in msgs if m['role'] == 'assistant' and m.get('parent_id') == u2['message_id'])
    assert u2_reply['text'] == '好，马上办。'

    # 2) 已向主对话提交新一轮 user 消息，指令包含 description，且 source_quote 含原话+确认消息
    resolved = pa.get(auto_item['id'])
    assert resolved['status'] == 'executed'
    detail = json.loads( sqlite3.connect(pa.path).execute('SELECT resolution FROM pending_actions WHERE id=?', (auto_item['id'],)).fetchone()[0] )['detail']
    assert '明天早上九点交周报' in detail['source_quote'] and '加' in detail['source_quote']
    queued_turns = [m for m in msgs if m['role'] == 'user' and m['status'] == 'queued']
    assert len(queued_turns) == 1
    assert f'Eddie 已确认：{desc}。直接执行，不要再问确认；执行后用一句话回执' == queued_turns[0]['text']

    # 3) 跑新一轮时主对话模型收到该确认指令并完成回执
    asyncio.run(chat.process_one())
    assert len(client.received_prompts) == 2
    assert f'Eddie 已确认：{desc}。直接执行，不要再问确认；执行后用一句话回执' in client.received_prompts[1]
    final_reply = [m for m in chat.snapshot()['messages'] if m['role'] == 'assistant'][-1]
    assert '已为你写进系统提醒' in final_reply['text']

    # 4) 删除类 confirm_to_model 仍走审批卡，不直接提交执行
    from tasks import TaskStore

    task_store = TaskStore(tmp_path)
    u_del = chat.submit('req-c2m-del-orig', '帮我清空旧的测试提醒记录')
    with chat.db() as db:
        db.execute("UPDATE messages SET status='completed' WHERE id=?", (u_del['message_id'],))
    chat._finish(u_del['message_id'], 'completed', '**清空旧的测试提醒记录。**回我一句「清」就执行。')
    del_item = pa.active()
    assert del_item is not None and del_item['confirm_word'] == '清'
    u_del_confirm = chat.submit('req-c2m-del-confirm', '清')
    res_del = asyncio.run(
        pa.execute(
            del_item['id'],
            request_id='req-c2m-del-confirm',
            message_id=u_del_confirm['message_id'],
            task_store=task_store,
        )
    )
    assert res_del['status'] == 'approval_required' and res_del.get('proposal_id')


def test_negate_cancels_auto_registered_confirm_to_model(tmp_path):
    """否定照常取消：自动登记的 confirm_to_model 在收到否定回复时正常取消，不提交新一轮。"""
    client = _ScriptedHermes(['**帮你设好明天早上 9:00 交周报的提醒。**\n回我一句「加」就写进系统提醒。'])
    chat = PersonalConversation(tmp_path, client)
    chat.submit('req-c2m-neg-1', '明天早上九点提醒我交周报')
    asyncio.run(chat.process_one())

    pa = PendingActions(tmp_path)
    item = pa.active()
    assert item is not None and item['confirm_word'] == '加'

    chat.submit('req-c2m-neg-2', '不加了')
    asyncio.run(chat.process_one())

    assert pa.active() is None
    assert pa.get(item['id'])['status'] == 'cancelled'
    msgs = chat.snapshot()['messages']
    last_reply = [m for m in msgs if m['role'] == 'assistant'][-1]
    assert '已取消' in last_reply['text']
    assert not any(m['role'] == 'user' and m['status'] == 'queued' for m in msgs)


@pytest.mark.parametrize(
    'reply_text,confirm_word,expected_category,expected_label',
    [
        (
            '**给品牌方发送合作报价邮件已经拟好。**\n回我一句「发」就发送邮件。',
            '发',
            'email_send',
            '邮件发送',
        ),
        (
            '**给老马提交劳务报酬付款单 1500 元已核对。**\n回我一句「提」就提交付款单。',
            '提',
            'payment_submit',
            '付款与报销提交',
        ),
        (
            '**把全国岩馆路书第三期发布到小红书和视频号已就绪。**\n回我一句「发」就发布视频。',
            '发',
            'content_publish',
            '内容发布',
        ),
    ],
)
def test_auto_register_gated_descriptions_set_correct_category(
    tmp_path, reply_text, confirm_word, expected_category, expected_label
):
    """外发三类描述命中时 category 正确，且确认后只准备到按钮前。"""
    client = _ScriptedHermes([reply_text])
    chat = PersonalConversation(tmp_path, client)
    chat.submit(f'req-gated-auto-{confirm_word}', '帮我处理这项外发工作')
    asyncio.run(chat.process_one())

    pa = PendingActions(tmp_path)
    active = pa.active()
    assert active is not None
    assert active['confirm_word'] == confirm_word
    assert active['action']['tool'] == 'confirm_to_model'
    assert active['action']['category'] == expected_category
    assert active['category'] == expected_category
    assert active['gated_kind'] == expected_label

    # 确认后走外发三类准备通道（status='prepared'），不在后台直接点击发送/提交/发布
    chat.submit(f'req-gated-confirm-{confirm_word}', confirm_word)
    asyncio.run(chat.process_one())
    resolved = pa.get(active['id'])
    assert resolved['status'] == 'prepared'
    last_reply = [m for m in chat.snapshot()['messages'] if m['role'] == 'assistant'][-1]
    assert expected_label in last_reply['text'] and '停在最后一步' in last_reply['text']


def test_confirm_to_model_realistic_integration_with_hermes_v2_session(tmp_path):
    """复现线上验收测试六：HermesRuntime (hermes_v2_session_id='com-hermes-main') + 历史遗留 hermes_session_id='com-personal-main' 下，
    用户说「查」触发 confirm_to_model，不报「主对话来源不匹配」，以当前确认消息为 origin、source_quote=原话+确认消息提交新一轮。
    """
    from policy import source as policy_source

    class _HermesV2RuntimeStub(_ScriptedHermes):
        session_key = 'hermes_v2_session_id'

        async def create_session(self) -> str:
            return 'com-hermes-main'

    client = _HermesV2RuntimeStub(
        [
            '你说「查」，我再去看后天有什么日程。',
            '后天上午 10:00 有产品周会。',
        ]
    )
    chat = PersonalConversation(tmp_path, client)
    # 模拟线上库同时存在历史 hermes_session_id='com-personal-main' 与当前 hermes_v2_session_id='com-hermes-main'
    with chat.db() as db:
        db.execute("INSERT OR REPLACE INTO meta(key,value) VALUES('hermes_session_id','com-personal-main')")
        db.execute("INSERT OR REPLACE INTO meta(key,value) VALUES('hermes_v2_session_id','com-hermes-main')")

    orig_text = '验收测试六：等会儿帮我看看后天有什么日程，现在先别查，我说「查」你再查。'
    u1 = chat.submit('req-online-test6-orig', orig_text)
    asyncio.run(chat.process_one())

    pa = PendingActions(tmp_path)
    active = pa.active()
    assert active is not None
    assert active['action']['tool'] == 'confirm_to_model'
    assert active['confirm_word'] == '查'
    assert active['context']['origin_session_id'] == 'com-hermes-main'
    assert active['context']['origin_message_id'] == u1['message_id']

    # 用户发「查」→ L0 快路径执行 confirm_to_model
    u2 = chat.submit('req-online-test6-confirm', '查')
    asyncio.run(chat.process_one())

    resolved = pa.get(active['id'])
    assert resolved['status'] == 'executed'
    detail = json.loads(
        sqlite3.connect(pa.path).execute('SELECT resolution FROM pending_actions WHERE id=?', (active['id'],)).fetchone()[0]
    )['detail']

    # 校验新一轮使用当前确认消息作为 origin，source_quote = 原话 + 确认消息
    auth = detail['authorization']
    assert auth['origin_session_id'] == 'com-hermes-main'
    assert auth['origin_message_id'] == u2['message_id']
    assert auth['origin_request_id'] == 'req-online-test6-confirm'
    assert orig_text in detail['source_quote'] and '\n查' in detail['source_quote']

    msgs = chat.snapshot()['messages']
    u2_reply = next(m for m in msgs if m['role'] == 'assistant' and m.get('parent_id') == u2['message_id'])
    assert u2_reply['text'] == '好，马上办。'
    assert '主对话来源不匹配' not in u2_reply['text']

    queued = [m for m in msgs if m['role'] == 'user' and m['status'] == 'queued']
    assert len(queued) == 1
    expected_instruction = f"Eddie 已确认：{active['description']}。直接执行，不要再问确认；执行后用一句话回执"
    assert queued[0]['text'] == expected_instruction

    # 校验新一轮消息在后续工具调用做 policy.source 校验时同样通过，且关联到本次确认消息与原话+确认消息
    followup_src = policy_source(
        chat,
        {
            'origin_session_id': 'com-hermes-main',
            'origin_message_id': queued[0]['id'],
            'origin_request_id': f"confirm-model-{active['id']}",
        },
    )
    assert followup_src['authorization_parent_message_id'] == u2['message_id']
    assert orig_text in followup_src['text'] and '查' in followup_src['text']

    # 跑完新一轮模型回复
    asyncio.run(chat.process_one())
    final_reply = [m for m in chat.snapshot()['messages'] if m['role'] == 'assistant'][-1]
    assert '后天上午 10:00 有产品周会' in final_reply['text']


def test_pending_action_fast_path_failure_degrades_to_normal_model_turn(tmp_path, monkeypatch, caplog):
    """快路径兜底：pending_action 执行抛错或返回 status='failed' 时，不把内部错误直接回给用户，记日志并降级交由模型正常执行。"""
    import logging

    client = _ScriptedHermes(
        [
            '你说「查」，我再去看后天有什么日程。',
            '我已直接帮你查好：后天没有冲突日程。',
        ]
    )
    chat = PersonalConversation(tmp_path, client)
    chat.submit('req-degrade-orig', '等会儿帮我看看后天有什么日程，我说「查」你再查。')
    asyncio.run(chat.process_one())

    pa = PendingActions(tmp_path)
    active = pa.active()
    assert active is not None and active['confirm_word'] == '查'

    async def fail_execute(*_a, **_kw):
        raise ValueError('主对话来源不匹配')

    monkeypatch.setattr(PendingActions, 'execute', fail_execute)

    with caplog.at_level(logging.ERROR):
        u_confirm = chat.submit('req-degrade-confirm', '查')
        asyncio.run(chat.process_one())

    # 1) 错误已记入日志，且待确认项不再卡在 pending
    assert any('主对话来源不匹配' in rec.message for rec in caplog.records)
    assert pa.get(active['id'])['status'] == 'failed'

    # 2) 用户收到的回复来自模型正常跑完该轮，绝不包含内部报错文案
    msgs = chat.snapshot()['messages']
    reply = next(m for m in msgs if m['role'] == 'assistant' and m.get('parent_id') == u_confirm['message_id'])
    assert '主对话来源不匹配' not in reply['text']
    assert '我已直接帮你查好：后天没有冲突日程。' in reply['text']
    assert len(client.received_prompts) == 2
    assert '查' in client.received_prompts[1]



