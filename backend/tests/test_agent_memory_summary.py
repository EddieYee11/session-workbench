"""轨道 agent：滚动摘要水位线、注入位置、失败保留旧摘要；候选事实分流写入 MemoryCatalog。"""
import asyncio
import json
from types import SimpleNamespace

from context_builder import build
from context_working_set import MARKER
from conversation import PersonalConversation
from conversation_summary import ConversationSummary, MAX_CHARS, render, summary_block
from memory_catalog import MemoryCatalog
from memory_inbox import MemoryInbox


def seed(tmp_path, n, text='这是一条普通的对话内容', start=0):
    conv = PersonalConversation(tmp_path, SimpleNamespace())
    with conv.db() as db:
        for i in range(start, start + n):
            role = 'user' if i % 2 == 0 else 'assistant'
            db.execute("INSERT INTO messages(id,request_id,role,text,status,phase,revision,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)",
                       (f'm{i:04d}', f'r{i:04d}', role, f'{text} #{i}', 'completed', 'completed', i, 1000 + i, 1000 + i))
    return conv


def model_echo(calls, facts=None):
    async def model(data):
        calls.append(data)
        ids = [m['id'] for m in data['messages']]
        return {'summary': {'goals': ['把 Com 做成主动助理'], 'preferences': ['回复要短'], 'progress': ['已摘要到 ' + ids[-1]],
                            'decisions': [], 'commitments': ['周五前交付'], 'context': []},
                'facts': facts(data) if facts else []}
    return model


def test_only_messages_outside_window_are_summarized_and_watermark_advances(tmp_path):
    seed(tmp_path, 24)
    calls = []
    s = ConversationSummary(tmp_path, model=model_echo(calls))
    rows, busy = s.pending()
    assert [r['id'] for r in rows] == [f'm{i:04d}' for i in range(16)] and not busy
    assert s.due()  # 8 user turns slid out of the window
    row = asyncio.run(s.refresh())
    assert row['last_summarized_message_id'] == 'm0015' and row['first_message_id'] == 'm0000'
    assert [m['id'] for m in calls[0]['messages']][-1] == 'm0015'
    assert 'm0000 … m0015' in row['text'] and '目标：把 Com 做成主动助理' in row['text']
    assert s.pending()[0] == [] and not s.due()
    # Incremental: new messages only, previous summary handed back for updating.
    seed(tmp_path, 4, start=24)
    assert [r['id'] for r in s.pending()[0]] == ['m0016', 'm0017', 'm0018', 'm0019']
    asyncio.run(s.refresh(force=True))
    assert calls[1]['previous']['goals'] == ['把 Com 做成主动助理']
    assert [m['id'] for m in calls[1]['messages']] == ['m0016', 'm0017', 'm0018', 'm0019']
    assert s.current()['first_message_id'] == 'm0000' and s.current()['version'] == 2


def test_trigger_needs_enough_backlog_and_waits_for_running_turns(tmp_path):
    conv = seed(tmp_path, 12)  # 4 outside window, 2 user turns, few chars
    s = ConversationSummary(tmp_path, model=model_echo([]))
    assert not s.due()
    seed(tmp_path, 4, text='长' * 2000, start=12)
    assert not s.due()  # long turns are still inside the 8-message window
    seed(tmp_path, 8, start=16)
    assert s.due()
    with conv.db() as db:
        db.execute("UPDATE messages SET status='running' WHERE id='m0023'")
    assert not s.due()


def test_failure_keeps_old_summary_and_watermark(tmp_path):
    seed(tmp_path, 20)
    s = ConversationSummary(tmp_path, model=model_echo([]))
    first = asyncio.run(s.refresh(force=True))
    seed(tmp_path, 6, start=20)
    async def broken(data): return {'summary': 'not a dict'}
    s.model = broken
    assert asyncio.run(s.refresh(force=True)) is None
    assert s.current() == first
    assert s.status()['runs'][0]['status'] == 'failed'


def test_render_is_capped_and_injected_between_core_and_volatile_context(tmp_path):
    big = {k: ['很长的条目' * 12] * 5 for k in ('goals', 'preferences', 'progress', 'decisions', 'commitments', 'context')}
    assert len(render(big, 'm1', 'm9')) <= MAX_CHARS
    seed(tmp_path, 20)
    s = ConversationSummary(tmp_path, model=model_echo([]))
    asyncio.run(s.refresh(force=True))
    assert summary_block(tmp_path).startswith('对话滚动摘要')
    working = build(tmp_path, MARKER + json.dumps({'environment': {'current_date': '2026-10-10'}}) + '\n用户消息：\n你好', instructions='核心规则')
    core_at = working.instructions.index('核心规则')
    summary_at = working.instructions.index('对话滚动摘要')
    env_at = working.instructions.index('2026-10-10')
    assert core_at < summary_at < env_at
    assert working.sizes['summary_chars'] > 0


def test_no_summary_means_no_change(tmp_path):
    working = build(tmp_path, '你好', instructions='核心规则')
    assert '对话滚动摘要' not in working.instructions and working.sizes['summary_chars'] == 0


def facts_for(data):
    user = [m for m in data['messages'] if m['role'] == 'user']
    return [
        {'type': 'preference', 'category': '关于我', 'content': 'Eddie 偏好简短回复', 'quote': '我喜欢简短', 'message_id': user[0]['id'], 'confidence': 0.95},
        {'type': 'profile', 'category': '健康', 'content': 'Eddie 每周攀岩两次', 'quote': '每周攀岩两次', 'message_id': user[1]['id'], 'confidence': 0.9},
        {'type': 'temporary', 'category': '生活', 'content': '明天取快递', 'quote': '明天取快递', 'message_id': user[2]['id'], 'confidence': 0.9},
        {'type': 'preference', 'category': '关于我', 'content': 'Eddie 讨厌长消息', 'quote': '编造的原话', 'message_id': user[0]['id'], 'confidence': 0.9},
        {'type': 'relationship', 'category': '关于我', 'content': '密码是 123', 'quote': '我喜欢简短', 'message_id': user[0]['id'], 'confidence': 0.9},
        {'type': 'project', 'category': '项目', 'content': 'Eddie 在做 Com', 'quote': '好的', 'message_id': data['messages'][1]['id'], 'confidence': 0.9},
    ]


def setup_inbox(tmp_path):
    conv = PersonalConversation(tmp_path, SimpleNamespace())
    texts = ['我喜欢简短，别写长篇', '好的', '我每周攀岩两次', '收到', '明天取快递', '嗯'] + ['填充'] * 10
    with conv.db() as db:
        for i, text in enumerate(texts):
            db.execute("INSERT INTO messages(id,request_id,role,text,status,phase,revision,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)",
                       (f'm{i:04d}', f'r{i:04d}', 'user' if i % 2 == 0 else 'assistant', text, 'completed', 'completed', i, 1000 + i, 1000 + i))
    catalog = MemoryCatalog(tmp_path / 'ws')
    inbox = MemoryInbox(tmp_path, catalog)
    s = ConversationSummary(tmp_path, model=model_echo([], facts_for), inbox=inbox)
    asyncio.run(s.refresh(force=True))
    return inbox, catalog, s


def test_facts_are_verified_then_auto_saved_or_queued(tmp_path):
    inbox, catalog, s = setup_inbox(tmp_path)
    listing = inbox.list()
    assert [r['content'] for r in listing['learned']] == ['Eddie 偏好简短回复']
    assert [r['content'] for r in listing['pending']] == ['Eddie 每周攀岩两次']
    saved = catalog.list()
    assert len(saved) == 1 and saved[0]['source']['quote'] == '我喜欢简短' and saved[0]['source']['message_id'] == 'm0000'
    assert saved[0]['source']['type'] == 'auto_learned'
    assert s.status()['runs'][0]['facts'] == {'auto': 1, 'pending': 1, 'dropped': 3}  # model output capped at 5 facts
    # Same fact again is not duplicated.
    assert inbox.ingest(facts_for({'messages': [{'id': 'm0000', 'role': 'user'}, {'id': 'm0001', 'role': 'assistant'}, {'id': 'm0002', 'role': 'user'}, {'id': 'm0004', 'role': 'user'}]})[:1],
                        {'m0000': {'role': 'user', 'text': '我喜欢简短，别写长篇'}})['dropped'] == 1


def test_confirm_correct_delete_and_approve(tmp_path):
    inbox, catalog, _ = setup_inbox(tmp_path)
    learned = inbox.list()['learned'][0]
    pending = inbox.list()['pending'][0]
    corrected = inbox.act(learned['id'], 'correct', 'Eddie 偏好 1–3 句的回复')
    memory = catalog.get(learned['memory_id'])
    assert memory['content'] == 'Eddie 偏好 1–3 句的回复' and memory['version'] == 2 and corrected['state'] == 'corrected'
    inbox.act(learned['id'], 'delete')
    assert catalog.get(learned['memory_id'])['archived'] is True and len(catalog.get(learned['memory_id'])['history']) == 2
    approved = inbox.act(pending['id'], 'confirm')
    assert catalog.get(approved['memory_id'])['content'] == 'Eddie 每周攀岩两次'
    assert inbox.list() == {'learned': [], 'pending': []}
    try:
        inbox.act(pending['id'], 'confirm')
        raise AssertionError('should refuse')
    except ValueError:
        pass
