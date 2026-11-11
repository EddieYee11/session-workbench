"""顺口提醒（nudges.py）单元测试：快递识别、日程 1 小时窗口、航班火车变动、提醒到期、订阅续费跨天去重、旧 key 不重发、安静时段、每日上限、paused、Bark 推送与 metadata。"""
import hashlib
import json
from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from conversation import PersonalConversation
from nudges import DAILY_MAX, Nudges, parse_subscriptions
from push_notifications import PushNotifications
from reminder_cards import ReminderCards

TZ = ZoneInfo("Asia/Shanghai")
SAMPLE_LEDGER = """# Subscriptions

## 订阅列表

| 订阅 | 费用 | 周期 | 下次到期 | 状态 |  |
| --- | --- | --- | --- | --- | --- |
| YouTube Premium | ¥85 | 每年 | 2026-11-12 | ✅ | |
| GPT Plus（旧） | ¥75 | 每月 | — | ❌ 已取消 | |
| Kimi | ¥67 | 每月 | 2026-06-22 | ✅ | |
| Claude Max 5倍 | ¥888 | 每月 | 2026-11-10 | ✅ | |
| 停掉的 | ¥1 | 每月 | 2026-11-11 | ❌ | |

## 注册码 / License Keys

| 名称 | Key | x | 2026-11-11 | ✅ |
"""


def at(hour: int, minute: int, day: int = 10) -> float:
    return datetime(2026, 11, day, hour, minute, tzinfo=TZ).timestamp()


class FakeHub:
    def __init__(self, rows=None):
        self.rows = list(rows or [])

    def matters(self):
        return self.rows


def make_engine(tmp_path, now_ref, rows=None, settings=None, reminders=None, ledger=None):
    tmp_path.mkdir(parents=True, exist_ok=True)
    conv = PersonalConversation(tmp_path, SimpleNamespace())
    (tmp_path / "bark-config.json").write_text('{"device_key": "abcdefgh1234", "preview": true}')
    cfg = {"paused": False, "intensity": "balanced", "quiet_start": 23, "quiet_end": 8, **(settings or {})}
    notif = PushNotifications(tmp_path, conv, lambda: cfg, clock=lambda: now_ref[0])
    hub = FakeHub(rows)
    engine = Nudges(
        tmp_path,
        conv,
        lambda: cfg,
        hub=hub,
        notifications=notif,
        reminders=reminders,
        ledger=ledger or (tmp_path / "empty-subs.md"),
        clock=lambda: now_ref[0],
    )
    return engine, conv, notif, hub


def delivered_messages(conv: PersonalConversation) -> list[dict]:
    with conv.db() as db:
        return [
            dict(r)
            for r in db.execute(
                "SELECT id, request_id, role, text, status FROM messages WHERE request_id LIKE 'task-result:nudge:%' ORDER BY revision"
            )
        ]


def test_express_delivery_and_pickup_recognition_and_bark_push(tmp_path):
    now = [at(9, 46)]
    sms_matter = {
        "id": "matter_sms_express_1",
        "source": "sms",
        "source_id": "latest",
        "title": "短信 · 最近 48 小时 2 条",
        "facts": {
            "messages": [
                {
                    "id": "msg_1",
                    "from": "10698000",
                    "text": "【顺丰速运】您购买的【德亚希腊酸奶】正在派送中，快递员：王师傅 13800138000，运单号 SF1234567890123",
                    "at": now[0] - 60,
                },
                {
                    "id": "msg_2",
                    "from": "10698001",
                    "text": "【菜鸟驿站】您的包裹【攀岩镁粉袋】已到驿站，请凭取件码 3-2-1088 取件。",
                    "at": now[0] - 30,
                },
            ]
        },
        "feedback": {},
    }
    engine, conv, notif, _ = make_engine(tmp_path, now, [sms_matter])
    assert engine.tick() == 2

    msgs = delivered_messages(conv)
    assert len(msgs) == 2
    for m in msgs:
        assert m["role"] == "assistant" and m["status"] == "completed"
        conclusion = m["text"].splitlines()[0]
        assert len(conclusion) <= 40
        meta = engine.message_metadata(m["id"])
        assert meta is not None
        assert meta["kind"] == "nudge"
        assert meta["source_matter_id"] == "matter_sms_express_1"

    assert "德亚希腊酸奶在派送了，今天注意收一下。" in msgs[0]["text"].splitlines()[0]
    assert "SF1234567890123" in msgs[0]["text"]
    assert "攀岩镁粉袋到了（取件码 3-2-1088），记得去取。" in msgs[1]["text"].splitlines()[0]

    with notif.db() as db:
        queued = [r[0] for r in db.execute("SELECT message_id FROM outbox WHERE device_id='bark'")]
    assert len(queued) == 2


def test_schedule_one_hour_window_and_travel_change(tmp_path):
    now = [at(14, 0)]
    rows = [
        {
            "id": "matter_cal_soon",
            "source": "apple_calendar",
            "title": "选题评审会",
            "deadline": "2026-11-10T14:45:00+08:00",
            "facts": {"start": "2026-11-10T14:45:00+08:00", "location": "搜狐媒体大厦 12F"},
            "feedback": {},
        },
        {
            "id": "matter_cal_far",
            "source": "apple_calendar",
            "title": "晚间训练",
            "deadline": "2026-11-10T16:30:00+08:00",
            "facts": {"start": "2026-11-10T16:30:00+08:00"},
            "feedback": {},
        },
        {
            "id": "matter_travel_1",
            "source": "gmail",
            "title": "【航旅纵横】CA1501 登机口变更",
            "facts": {"from": "service@umetrip.com", "snippet": "您乘坐的 CA1501 航班登机口变更为 B22，原起飞时间 17:00。"},
            "feedback": {},
        },
    ]
    engine, conv, _, _ = make_engine(tmp_path, now, rows)
    assert engine.tick() == 2
    texts = [m["text"] for m in delivered_messages(conv)]
    assert any("14:45「选题评审会」还有 45 分钟开始。" in t and "搜狐媒体大厦 12F" in t for t in texts)
    assert not any("晚间训练" in t for t in texts)
    assert any("CA1501" in t and "变更" in t for t in texts)


def test_deduplication_and_retrigger_only_on_state_change(tmp_path):
    now = [at(10, 0)]
    hub_rows = [
        {
            "id": "matter_jd_1",
            "source": "wechat",
            "title": "微信 · 10:00",
            "facts": {
                "chats": [
                    {
                        "name": "京东快递",
                        "username": "gh_jd",
                        "summary": "【京东快递】您的【蛋白粉】正在派送中，运单号 JD001122334455",
                        "messages": [{"text": "【京东快递】您的【蛋白粉】正在派送中，运单号 JD001122334455"}],
                    }
                ]
            },
            "feedback": {},
        }
    ]
    engine, conv, _, hub = make_engine(tmp_path, now, hub_rows)
    assert engine.tick() == 1
    # 同一状态再次 tick（即使文案微小变化但运单与派送状态未变）不重复提醒
    now[0] = at(10, 5)
    assert engine.tick() == 0
    assert len(delivered_messages(conv)) == 1

    # 状态从「派送中」变为「待取件」时重新提醒一次
    hub.rows = [
        {
            "id": "matter_jd_1",
            "source": "wechat",
            "title": "微信 · 10:30",
            "facts": {
                "chats": [
                    {
                        "name": "京东快递",
                        "username": "gh_jd",
                        "summary": "【京东快递】您的【蛋白粉】已放入丰巢快递柜，运单号 JD001122334455，取件码 889911",
                        "messages": [{"text": "【京东快递】您的【蛋白粉】已放入丰巢快递柜，运单号 JD001122334455，取件码 889911"}],
                    }
                ]
            },
            "feedback": {},
        }
    ]
    now[0] = at(10, 30)
    assert engine.tick() == 1
    msgs = delivered_messages(conv)
    assert len(msgs) == 2
    assert "在派送了" in msgs[0]["text"]
    assert "到了（取件码 889911）" in msgs[1]["text"]


def test_quiet_hours_paused_and_daily_intensity_limits(tmp_path):
    cal_rows = [
        {
            "id": f"matter_cal_{i}",
            "source": "phone_calendar",
            "title": f"会议{i}",
            "deadline": "2026-11-10T10:30:00+08:00",
            "facts": {"start": "2026-11-10T10:30:00+08:00"},
            "feedback": {},
        }
        for i in range(15)
    ]

    # 1. paused = True 时不发送
    now = [at(10, 0)]
    paused_engine, paused_conv, _, _ = make_engine(tmp_path / "paused", now, cal_rows, settings={"paused": True})
    assert paused_engine.tick() == 0
    assert delivered_messages(paused_conv) == []

    # 2. 安静时段（23:00 - 08:00）不发送
    night_now = [at(23, 15)]
    night_rows = [
        {
            "id": "matter_night",
            "source": "phone_calendar",
            "title": "夜间日程",
            "deadline": "2026-11-10T23:45:00+08:00",
            "facts": {"start": "2026-11-10T23:45:00+08:00"},
            "feedback": {},
        }
    ]
    quiet_engine, quiet_conv, _, _ = make_engine(tmp_path / "night", night_now, night_rows)
    assert quiet_engine.tick() == 0
    assert delivered_messages(quiet_conv) == []

    # 3. 每日上限：quiet=2, balanced=6, active=12
    assert DAILY_MAX == {"quiet": 2, "balanced": 6, "active": 12}
    for level, expected_cap in (("quiet", 2), ("balanced", 6), ("active", 12)):
        eng, c, _, _ = make_engine(tmp_path / f"cap_{level}", [at(10, 0)], cal_rows, settings={"intensity": level})
        assert eng.tick() == expected_cap
        assert len(delivered_messages(c)) == expected_cap
        # 当天再次 tick 不会突破上限
        assert eng.tick() == 0


def test_due_reminders_and_repeating_reminder(tmp_path):
    now = [at(9, 50)]
    rem_path = tmp_path / "reminders.json"
    rem_path.write_text(
        json.dumps(
            [
                {"id": "r1", "text": "给百度发信息", "due": "2026-11-10 09:45", "status": "pending"},
                {"id": "r2", "text": "已完成的", "due": "2026-11-10 09:45", "status": "done"},
                {"id": "r3", "text": "太久以前", "due": "2026-11-10 08:00", "status": "pending"},
            ]
        )
    )
    engine, conv, _, _ = make_engine(tmp_path, now, reminders=ReminderCards(rem_path))
    assert engine.tick() == 1
    msgs = delivered_messages(conv)
    assert [m["text"] for m in msgs] == ["提醒：给百度发信息"]
    assert msgs[0]["request_id"] == "task-result:nudge:reminder:r1:2026-11-10 09:45"

    # 同一 due 时间再次 tick 不重复
    now[0] = at(9, 52)
    assert engine.tick() == 0

    # 每天重复的提醒在次日新 due 时间正常触发
    rem_path.write_text(json.dumps([{"id": "r1", "text": "给百度发信息", "due": "2026-11-11 09:45", "status": "pending"}]))
    now[0] = at(9, 46, day=11)
    assert engine.tick() == 1
    assert len(delivered_messages(conv)) == 2


def test_subscriptions_cross_day_and_reminder_deduplication(tmp_path):
    rows = parse_subscriptions(SAMPLE_LEDGER)
    assert [r["name"] for r in rows] == ["YouTube Premium", "Kimi", "Claude Max 5倍"]

    now = [at(9, 0)]
    ledger = tmp_path / "subs.md"
    ledger.write_text(SAMPLE_LEDGER)
    rem_path = tmp_path / "reminders.json"
    # 同名订阅已作为提醒发出时，不再重复发订阅续费提醒
    rem_path.write_text(
        json.dumps([{"id": "r_sub", "text": "Claude Max 5倍 月度订阅到期，决定续费", "due": "2026-11-10 09:00", "status": "pending"}])
    )
    engine, conv, notif, _ = make_engine(tmp_path, now, reminders=ReminderCards(rem_path), ledger=ledger)
    assert engine.tick() == 2
    texts = [m["text"] for m in delivered_messages(conv)]
    assert sum("Claude Max" in t for t in texts) == 1
    assert any(t.startswith("YouTube Premium（¥85/每年）11月12日到期，还有 2 天，续不续定一下？") for t in texts)
    assert notif._bark_headline("task-result:nudge:subscription:YouTube Premium:2026-11-12", texts[-1], True)[0] == "Com · 订阅到期"

    # 跨天（次日 days=1，即使账本 due 微调但同 subject 在 7 天内）也不重复提醒
    ledger.write_text(SAMPLE_LEDGER.replace("2026-11-12", "2026-11-13"))
    now[0] = at(9, 0, day=11)
    assert engine.tick() == 0


def test_legacy_sent_keys_not_resent(tmp_path):
    now = [at(10, 0)]
    cal_start = "2026-11-10T10:10:00+08:00"
    start_ts = int(datetime.fromisoformat(cal_start).timestamp())
    legacy_cal_subject = f"周会@{start_ts}"
    legacy_cal_key = "calendar:" + hashlib.sha256(legacy_cal_subject.encode("utf-8")).hexdigest()[:24]

    hub_rows = [
        {
            "id": "matter_cal_legacy",
            "source": "apple_calendar",
            "title": "周会",
            "deadline": cal_start,
            "facts": {"start": cal_start, "location": "3楼"},
            "feedback": {},
        }
    ]
    rem_path = tmp_path / "reminders.json"
    rem_path.write_text(json.dumps([{"id": "r1", "text": "交周报", "due": "2026-11-10 09:55", "status": "pending"}]))
    ledger = tmp_path / "subs.md"
    ledger.write_text(SAMPLE_LEDGER)

    engine, conv, _, _ = make_engine(tmp_path, now, rows=hub_rows, reminders=ReminderCards(rem_path), ledger=ledger)
    # 模拟旧 proactive.Nudges 已写入 sent 表的记录（无 matter_id/state_token/fingerprint）
    with engine.db() as db:
        db.execute(
            "INSERT INTO sent(key, day, kind, subject, at) VALUES (?,?,?,?,?)",
            (legacy_cal_key, "2026-11-10", "calendar", legacy_cal_subject, now[0] - 60),
        )
        db.execute(
            "INSERT INTO sent(key, day, kind, subject, at) VALUES (?,?,?,?,?)",
            ("reminder:r1:2026-11-10 09:55", "2026-11-10", "reminder", "交周报", now[0] - 60),
        )
        db.execute(
            "INSERT INTO sent(key, day, kind, subject, at) VALUES (?,?,?,?,?)",
            ("subscription:YouTube Premium:2026-11-12", "2026-11-09", "subscription", "YouTube Premium", now[0] - 86400),
        )
        db.execute(
            "INSERT INTO sent(key, day, kind, subject, at) VALUES (?,?,?,?,?)",
            ("subscription:Claude Max 5倍:2026-11-10", "2026-11-10", "subscription", "Claude Max 5倍", now[0] - 60),
        )

    assert engine.tick() == 0
    assert delivered_messages(conv) == []
