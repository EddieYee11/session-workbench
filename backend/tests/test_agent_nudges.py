"""轨道 agent：事件提醒（日程前、提醒到期、订阅到期）的节制；Bark 只推主动消息；心跳不再拿已结束任务说事。"""
import asyncio
import json
from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from conversation import PersonalConversation
from heartbeat import Heartbeat
from proactive import Nudges, parse_subscriptions
from push_notifications import PushNotifications
from reminder_cards import ReminderCards

TZ = ZoneInfo('Asia/Shanghai')
LEDGER = '''# Subscriptions

## 订阅列表

| 订阅 | 费用 | 周期 | 下次到期 | 状态 |  |
| --- | --- | --- | --- | --- | --- |
| YouTube Premium | ¥85 | 每年 | 2026-10-12 | ✅ | |
| GPT Plus（旧） | ¥75 | 每月 | — | ❌ 已取消 | |
| Kimi | ¥67 | 每月 | 2026-06-22 | ✅ | |
| Claude Max 5倍 | ¥888 | 每月 | 2026-10-10 | ✅ | |
| 停掉的 | ¥1 | 每月 | 2026-10-11 | ❌ | |

## 注册码 / License Keys

| 名称 | Key | x | 2026-10-11 | ✅ |
'''


def at(h, m, day=10):
    return datetime(2026, 10, day, h, m, tzinfo=TZ).timestamp()


class Hub:
    def __init__(self, rows): self.rows = rows
    def matters(self): return self.rows


def calendar(title, start, **facts):
    return {'id': 'matter_' + title, 'source': 'phone_calendar', 'title': title, 'deadline': start,
            'facts': {'start': start, **facts}, 'feedback': {}}


def build(tmp_path, now, hub=None, reminders=None, settings=None):
    tmp_path.mkdir(exist_ok=True)
    conv = PersonalConversation(tmp_path, SimpleNamespace())
    ledger = tmp_path / 'subs.md'
    ledger.write_text(LEDGER)
    cfg = {'paused': False, 'intensity': 'balanced', 'quiet_start': 23, 'quiet_end': 8, **(settings or {})}
    n = Nudges(tmp_path, conv, lambda: cfg, hub=hub, reminders=reminders, ledger=ledger, clock=lambda: now[0])
    return n, conv


def receipts(conv):
    with conv.db() as db:
        return [r[0] for r in db.execute("SELECT text FROM messages WHERE request_id LIKE 'task-result:nudge:%' ORDER BY revision")]


def test_ledger_parser_reads_only_active_subscription_rows():
    rows = parse_subscriptions(LEDGER)
    assert [r['name'] for r in rows] == ['YouTube Premium', 'Kimi', 'Claude Max 5倍']


def test_calendar_reminder_and_subscription_each_said_once(tmp_path):
    now = [at(9, 50)]
    hub = Hub([calendar('周会', '2026-10-10T10:00+08:00', location='3楼'),
               calendar('周会', '2026-10-10T10:00+08:00'),  # mirrored calendar copy
               calendar('国庆节', '2026-10-10T09:55+08:00', calendar_displayName='中国节假日'),
               calendar('全天', '2026-10-10'),
               calendar('下午会', '2026-10-10T15:00+08:00')])
    path = tmp_path / 'reminders.json'
    path.write_text(json.dumps([{'id': 'r1', 'text': '给百度发信息', 'due': '2026-10-10 09:45', 'status': 'pending'},
                                {'id': 'r2', 'text': '已完成的', 'due': '2026-10-10 09:45', 'status': 'done'},
                                {'id': 'r3', 'text': '太久以前', 'due': '2026-10-10 08:00', 'status': 'pending'}]))
    n, conv = build(tmp_path, now, hub, ReminderCards(path))
    assert n.tick() == 4
    texts = receipts(conv)
    assert '10:00 「周会」，还有 10 分钟，地点：3楼。' in texts
    assert '提醒：给百度发信息' in texts
    assert any(t.startswith('Claude Max 5倍（¥888/每月）今天到期') for t in texts)
    assert any(t.startswith('YouTube Premium（¥85/每年）10月12日到期，还有 2 天') for t in texts)
    assert not any('国庆' in t or '全天' in t or 'Kimi' in t or '停掉' in t or '下午会' in t for t in texts)
    now[0] = at(9, 55)
    assert n.tick() == 0  # same things are never repeated


def test_quiet_hours_pause_and_daily_cap(tmp_path):
    now = [at(23, 30, day=9)]
    hub = Hub([calendar('深夜会', '2026-10-09T23:40+08:00')])
    n, conv = build(tmp_path, now, hub)
    assert n.tick() == 0 and receipts(conv) == []
    paused, conv2 = build(tmp_path / 'p', [at(9, 50)], settings={'paused': True})
    assert paused.tick() == 0
    from proactive import NUDGE_DAILY_MAX
    cap = NUDGE_DAILY_MAX['quiet']
    hub = Hub([calendar('会' + str(i), '2026-10-10T10:00+08:00') for i in range(cap + 3)])
    capped, conv3 = build(tmp_path / 'c', [at(9, 50)], hub, settings={'intensity': 'quiet'})
    assert capped.tick() == cap and len(receipts(conv3)) == cap


def test_subscription_reminder_already_sent_suppresses_ledger_duplicate(tmp_path):
    now = [at(9, 0)]
    path = tmp_path / 'reminders.json'
    path.write_text(json.dumps([{'id': 'r1', 'text': 'Claude Max 5倍 月度订阅到期，决定续费', 'due': '2026-10-10 09:00', 'status': 'pending'}]))
    n, conv = build(tmp_path, now, reminders=ReminderCards(path))
    n.tick()
    texts = receipts(conv)
    assert sum('Claude Max' in t for t in texts) == 1


def test_bark_only_pushes_proactive_messages(tmp_path):
    now = [at(12, 0)]
    conv = PersonalConversation(tmp_path, SimpleNamespace())
    (tmp_path / 'bark-config.json').write_text(json.dumps({'device_key': 'abcdefgh1234'}))
    p = PushNotifications(tmp_path, conv, lambda: {'quiet_start': 23, 'quiet_end': 8}, clock=lambda: now[0])
    with conv.db() as db:
        db.execute("INSERT INTO messages(id,request_id,role,text,status,phase,revision,created_at,updated_at) VALUES ('reply','req-reply','assistant','当面回复','completed','completed',1,?,?)",
                   (now[0] + 1, now[0] + 1))
    conv.task_receipt('nudge:x', '提醒：喝水')
    with conv.db() as db:
        db.execute("UPDATE messages SET created_at=? WHERE request_id='task-result:nudge:x'", (now[0] + 2,))
    p.enqueue()
    with p.db() as db:
        rows = [r[0] for r in db.execute("SELECT message_id FROM outbox WHERE device_id='bark'")]
    assert rows == ['task-result:nudge:x']


def test_heartbeat_digest_ignores_finished_tasks(tmp_path):
    hb = Heartbeat(tmp_path, tmp_path, SimpleNamespace(list=lambda: []), SimpleNamespace(list=lambda: []))
    digest = json.loads(hb.digest([{'title': '旧验收', 'status': 'execution_finished'}, {'title': '取消', 'status': 'cancelled'},
                                   {'title': '在跑', 'status': 'running'}]))
    assert [t['title'] for t in digest['tasks']] == ['在跑']


def test_repeating_reminder_fires_each_due_time_and_apple_all_day_is_skipped(tmp_path):
    # 验收补充：每天重复的提醒同名不同时间，每次到期都要说；Apple 全天日程带 T00:00 也不提醒。
    now = [at(9, 0)]
    path = tmp_path / 'reminders.json'
    path.write_text(json.dumps([{'id': 'r1', 'text': '吃药', 'due': '2026-10-10 09:00', 'repeat': 'daily', 'status': 'pending'}]))
    hub = Hub([calendar('全天活动', '2026-10-10T09:10+08:00', all_day=True)])
    n, conv = build(tmp_path, now, hub, ReminderCards(path))
    n.tick()  # also says the ledger's subscriptions; only the reminder/calendar rows matter here
    path.write_text(json.dumps([{'id': 'r1', 'text': '吃药', 'due': '2026-10-11 09:00', 'repeat': 'daily', 'status': 'pending'}]))
    now[0] = at(9, 1, day=11)
    n.tick()
    texts = receipts(conv)
    assert texts.count('提醒：吃药') == 2 and not any('全天活动' in t for t in texts)
