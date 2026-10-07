"""主动消息排期：时间窗口、来源身份、幂等、暂停与后台事件提示词。"""
import asyncio
from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from background_events import BackgroundEvents
from goals import GoalEvents
from proactive import Proactive
from tasks import TaskStore

TZ = ZoneInfo('Asia/Shanghai')


def at(hour, minute, day=7):
    return datetime(2026, 10, day, hour, minute, tzinfo=TZ).timestamp()


def test_due_window_pause_and_disabled_item(tmp_path):
    assert [row['id'] for row in Proactive(tmp_path, clock=lambda: at(21, 0)).due()] == ['evening-review']
    assert Proactive(tmp_path, clock=lambda: at(20, 59)).due() == []
    assert [row['id'] for row in Proactive(tmp_path, clock=lambda: at(21, 29)).due()] == ['evening-review']
    assert Proactive(tmp_path, clock=lambda: at(21, 31)).due() == []
    paused = Proactive(tmp_path, clock=lambda: at(21, 0))
    paused.configure({'paused': True})
    assert Proactive(tmp_path, clock=lambda: at(21, 0)).due() == []


def test_source_identity_is_version_and_planned_time(tmp_path):
    row = Proactive(tmp_path, clock=lambda: at(21, 0)).due()[0]
    assert row['source_id'] == 'cron:evening-review:1:2026-10-07T21:00'
    assert row['planned_at'].startswith('2026-10-07T21:00')


def test_tick_is_idempotent_per_planned_time(tmp_path):
    events = GoalEvents(tmp_path)
    scheduler = Proactive(tmp_path, clock=lambda: at(21, 0))
    assert scheduler.tick(events) == 1
    assert scheduler.tick(events) == 0
    with events.db() as db:
        rows = [tuple(row) for row in db.execute('SELECT id,kind,state FROM events')]
    assert rows == [('proactive:cron:evening-review:1:2026-10-07T21:00', 'proactive', 'queued')]
    assert Proactive(tmp_path, clock=lambda: at(21, 0, day=8)).tick(events) == 1
    with events.db() as db:
        assert len(list(db.execute('SELECT id FROM events'))) == 2


def test_disabled_item_and_broken_time_are_skipped(tmp_path):
    scheduler = Proactive(tmp_path, clock=lambda: at(21, 0), items=[
        {'id': 'off', 'at': '21:00', 'enabled': False},
        {'id': 'bad', 'at': '9点半'},
        {'id': 'range', 'at': '25:00'},
    ])
    assert scheduler.due() == []
    assert scheduler.tick(GoalEvents(tmp_path)) == 0


def test_saved_config_wins_over_defaults(tmp_path):
    scheduler = Proactive(tmp_path, clock=lambda: at(21, 0))
    scheduler.configure({'items': [{'id': 'memo', 'at': '21:00', 'enabled': True, 'title': '备忘'}]})
    assert [row['id'] for row in scheduler.due()] == ['memo']
    try:
        scheduler.configure({'paused': 'yes'})
    except ValueError:
        pass
    else:
        raise AssertionError('暂停状态必须是布尔值')


async def _session(self=None):
    return 'com-personal-main'


def conversation_with(output, prompts, receipts):
    class Client:
        runtime_name = 'hermes'

        async def stream_chat(self, session, text):
            prompts.append((session, text))
            yield 'assistant.completed', {'content': output}
            yield 'run.completed', {}

    return SimpleNamespace(client=Client(), _ensure_session=_session,
                           task_receipt=lambda ident, text: receipts.append((ident, text)))


def test_proactive_event_asks_for_a_message_and_writes_receipt(tmp_path):
    events = GoalEvents(tmp_path)
    Proactive(tmp_path, clock=lambda: at(21, 0)).tick(events)
    prompts, receipts = [], []
    consumer = BackgroundEvents(events, conversation_with('今天完成的事；明天先做 X。', prompts, receipts), TaskStore(tmp_path))
    assert asyncio.run(consumer.process()) is True
    assert len(prompts) == 1
    session, text = prompts[0]
    assert session == 'com-personal-main'
    assert '主动消息' in text and 'NO_UPDATE' in text
    assert 'cron:evening-review:1:2026-10-07T21:00' in text
    assert '"origin_source": "cron"' in text
    assert '晚间复盘' in text and '明天的第一件事' in text
    assert receipts == [('event:proactive:cron:evening-review:1:2026-10-07T21:00', '今天完成的事；明天先做 X。')]
    with events.db() as db:
        assert db.execute('SELECT state FROM events').fetchone()[0] == 'completed'


def test_proactive_event_stays_quiet_on_no_update(tmp_path):
    events = GoalEvents(tmp_path)
    Proactive(tmp_path, clock=lambda: at(21, 0)).tick(events)
    prompts, receipts = [], []
    consumer = BackgroundEvents(events, conversation_with('NO_UPDATE', prompts, receipts), TaskStore(tmp_path))
    assert asyncio.run(consumer.process()) is True
    assert receipts == []
    with events.db() as db:
        assert db.execute('SELECT state FROM events').fetchone()[0] == 'completed'


def test_goal_event_keeps_its_own_instruction(tmp_path):
    events = GoalEvents(tmp_path)
    goal = events.upsert({'request_id': 'goal-proactive-001', 'title': '项目', 'next_step': '修复项目',
                          'completion_condition': '检查通过'}, {'origin_message_id': 'human'})
    events.enqueue('due-proactive-001', 'goal_due', {'goal': goal, 'authorization': goal['authorization']})
    prompts, receipts = [], []
    consumer = BackgroundEvents(events, conversation_with('无变化', prompts, receipts), TaskStore(tmp_path))
    assert asyncio.run(consumer.process()) is True
    assert '主动消息' not in prompts[0][1] and '无变化或无下一步时不通知' in prompts[0][1]
    assert receipts == []


def test_fire_queues_immediately_with_planned_minute_identity(tmp_path):
    events = GoalEvents(tmp_path)
    scheduler = Proactive(tmp_path, clock=lambda: at(13, 7))
    assert scheduler.fire(events, 'evening-review') == 1
    assert scheduler.fire(events, 'evening-review') == 0
    with events.db() as db:
        assert tuple(db.execute('SELECT id FROM events').fetchone()) == (
            'proactive:cron:evening-review:1:2026-10-07T13:07',)
