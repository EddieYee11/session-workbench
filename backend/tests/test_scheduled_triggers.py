from __future__ import annotations

import asyncio
import importlib
import json
import sqlite3
import stat
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from activity import Activity
from agent_tools import AgentTools
from scheduled_triggers import (
    ScheduledTriggerStore,
    compute_next_run_at,
    describe_cron,
    parse_cron_expr,
)

TZ = ZoneInfo("Asia/Shanghai")


class DummyConversation:
    def __init__(self, root: Path) -> None:
        self.path = root / "personal-conversation.sqlite"
        self.receipts: list[tuple[str, str, str]] = []
        with sqlite3.connect(self.path) as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY,
                    role TEXT,
                    text TEXT,
                    raw_text TEXT,
                    status TEXT,
                    request_id TEXT,
                    created_at REAL,
                    parent_id TEXT,
                    reference TEXT,
                    supplement_to_message_id TEXT
                );
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY,
                    value TEXT
                );
                """
            )

    def _session_id(self) -> str:
        return "s1"

    def db(self):
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    def task_receipt(self, task_id: str, text: str, parent_id: str | None = None, *, channel: str | None = None) -> str:
        ch = channel or "personal"
        self.receipts.append((task_id, text, ch))
        msg_id = f"task-result:{task_id}"
        with sqlite3.connect(self.path) as db:
            db.execute(
                "INSERT OR REPLACE INTO messages(id, role, text, raw_text, status, request_id, created_at) VALUES(?,?,?,?,?,?,?)",
                (msg_id, "assistant", text, text, "completed", task_id, 1760000000.0),
            )
        return msg_id


class DummyNotifications:
    def __init__(self) -> None:
        self.enqueued = 0

    def enqueue(self) -> None:
        self.enqueued += 1


class DummyToday:
    def __init__(self, events=None, reminders=None, todos=None) -> None:
        self._events = events or []
        self._reminders = reminders or []
        self._todos = todos or []

    def snapshot(self) -> dict:
        return {
            "date": "2026-11-11",
            "events": list(self._events),
            "reminders": list(self._reminders),
            "todos": list(self._todos),
        }


class DummyNextSteps:
    def __init__(self, items=None) -> None:
        self._items = items or []

    def snapshot(self) -> dict:
        return {"items": list(self._items)}


class DummyFinance:
    async def snapshot(self, month=None) -> dict:
        return {
            "available": True,
            "month": month or "2026-11",
            "currencies": [{"currency": "CNY", "month_minor": 358650, "today_minor": 4800, "count": 19}],
        }


class DummyNudges:
    def __init__(self, schedule=None, reminders=None, subs=None) -> None:
        self._schedule = schedule or []
        self._reminders = reminders or []
        self._subs = subs or []

    def schedule_candidates(self, now: float) -> list[dict]:
        return list(self._schedule)

    def due_reminders(self, now: float) -> list[dict]:
        return list(self._reminders)

    def subscriptions(self, now: float) -> list[dict]:
        return list(self._subs)


def test_cron_parser_and_shanghai_next_run():
    base = datetime(2026, 11, 11, 8, 15, 30, tzinfo=TZ).timestamp()  # 周三 08:15:30
    same_day = compute_next_run_at("30 8 * * *", base)
    assert datetime.fromtimestamp(same_day, TZ) == datetime(2026, 11, 11, 8, 30, tzinfo=TZ)

    # 恰好在 08:30:00 触发后，下一次应推进到次日 08:30
    next_day = compute_next_run_at("30 8 * * *", same_day)
    assert datetime.fromtimestamp(next_day, TZ) == datetime(2026, 11, 12, 8, 30, tzinfo=TZ)

    # 周五 18:00 后计算工作日 09:00 -> 下周一 09:00
    fri_evening = datetime(2026, 11, 13, 18, 5, tzinfo=TZ).timestamp()
    mon_morning = compute_next_run_at("0 9 * * 1-5", fri_evening)
    assert datetime.fromtimestamp(mon_morning, TZ) == datetime(2026, 11, 16, 9, 0, tzinfo=TZ)

    # 步长与列表与周日别名（0 和 7 都表示周日）
    step_ts = compute_next_run_at("*/15 * * * *", base)
    assert datetime.fromtimestamp(step_ts, TZ) == datetime(2026, 11, 11, 8, 30, tzinfo=TZ)
    sun_ts = compute_next_run_at("0 10 * * 7", fri_evening)
    assert datetime.fromtimestamp(sun_ts, TZ) == datetime(2026, 11, 15, 10, 0, tzinfo=TZ)

    # 闰年 2 月 29 日跨年跳转
    leap_ts = compute_next_run_at("0 0 29 2 *", base)
    assert datetime.fromtimestamp(leap_ts, TZ) == datetime(2028, 2, 29, 0, 0, tzinfo=TZ)

    assert "每天 08:30" in describe_cron("30 8 * * *")
    assert "工作日 09:00" in describe_cron("0 9 * * 1-5")

    for bad in ("* * * *", "60 8 * * *", "0 24 * * *", "0 8 0 * *", "0 8 * 13 *", "0 8 * * 8", "*/0 * * * *", "20-10 * * * *"):
        with pytest.raises(ValueError):
            parse_cron_expr(bad)


def test_store_schema_permissions_and_presets_idempotent(tmp_path: Path):
    now = datetime(2026, 11, 11, 9, 0, tzinfo=TZ).timestamp()
    store = ScheduledTriggerStore(tmp_path, clock=lambda: now)
    mode = stat.S_IMODE(store.path.stat().st_mode)
    assert mode == 0o600

    items = store.ensure_presets()
    assert len(items) == 2
    assert {x["template"] for x in items} == {"morning_briefing", "schedule_subscription_due"}
    assert all(x["status"] == "paused" for x in items)

    # 删除其中一个预设后再次调用 ensure_presets 不会死灰复燃覆盖用户选择
    store.delete(items[0]["id"])
    after = store.ensure_presets()
    assert len(after) == 1


def test_morning_briefing_and_silent_vs_active_subscription_due(tmp_path: Path):
    now = datetime(2026, 11, 11, 8, 30, tzinfo=TZ).timestamp()
    conv = DummyConversation(tmp_path)
    notif = DummyNotifications()
    today = DummyToday(
        events=[{"title": "搜狐户外选题会", "start": now + 3600, "all_day": False, "location": "线上", "informational": False}],
        todos=[{"title": "审阅攀岩进度条成片", "overdue": False}],
    )
    next_steps = DummyNextSteps(items=[{"title": "确认 11 月预算表", "state": "open"}])
    nudges = DummyNudges()

    store = ScheduledTriggerStore(
        tmp_path,
        conversation=conv,
        today_view=today,
        next_steps=next_steps,
        finance_dashboard=DummyFinance(),
        nudges=nudges,
        notifications=notif,
        clock=lambda: now,
    )

    # 1. 晨间简报：推送气泡 + 通知入队 + channel 透传
    briefing = store.create(template="morning_briefing", channel="work", status="active")
    res_b = asyncio.run(store.run_now(briefing["id"]))
    assert res_b["status"] == "succeeded"
    assert res_b["message_id"].startswith("task-result:")
    assert len(conv.receipts) == 1
    assert conv.receipts[0][2] == "work"
    assert "搜狐户外选题会" in conv.receipts[0][1]
    assert "¥3,586.50" in conv.receipts[0][1]
    assert notif.enqueued == 1

    # 2. 日程/订阅到期提醒：无到期项时静默记 succeeded，绝不发气泡打扰
    due_trg = store.create(template="schedule_subscription_due", cron_expr="0 * * * *", status="active")
    res_silent = asyncio.run(store.run_now(due_trg["id"]))
    assert res_silent["status"] == "succeeded"
    assert res_silent["message_id"] == ""
    assert "静默跳过" in res_silent["summary"]
    assert len(conv.receipts) == 1
    assert notif.enqueued == 1

    # 3. 注入到期订阅与即将开始日程：主动发气泡，且同一天后续定时 tick 不重复刷屏
    nudges._subs = [{"key": "subscription:iCloud+:2026-11-12", "conclusion": "iCloud+（¥68/月）明天到期，续不续定一下？"}]
    nudges._schedule = [{"key": "schedule:abc", "conclusion": "09:00「产品评审」还有 30 分钟开始。"}]
    tick_time = store.get(due_trg["id"])["next_run_at"]
    store.clock = lambda: tick_time
    tick_res = asyncio.run(store.tick(tick_time))
    due_outcomes = [r for r in tick_res if r["trigger_id"] == due_trg["id"]]
    assert len(due_outcomes) == 1
    assert due_outcomes[0]["status"] == "succeeded"
    assert due_outcomes[0]["message_id"].startswith("task-result:")
    assert len(conv.receipts) == 2
    assert "iCloud+" in conv.receipts[-1][1]

    # 下一个整点再跑同一天定时 tick：同一订阅与日程已提醒过，自动静默跳过
    next_tick = store.get(due_trg["id"])["next_run_at"]
    store.clock = lambda: next_tick
    tick_res_2 = asyncio.run(store.tick(next_tick))
    due_outcomes_2 = [r for r in tick_res_2 if r["trigger_id"] == due_trg["id"]]
    assert due_outcomes_2[0]["status"] == "succeeded"
    assert due_outcomes_2[0]["message_id"] == ""
    assert len(conv.receipts) == 2


def test_overlap_protection_stale_recovery_and_exception_isolation(tmp_path: Path):
    t = [datetime(2026, 11, 11, 10, 0, tzinfo=TZ).timestamp()]
    conv = DummyConversation(tmp_path)
    gate = asyncio.Event()
    entered = asyncio.Event()

    async def slow_or_boom(trigger: dict):
        if "BOOM" in trigger["prompt"]:
            raise RuntimeError("boom_in_custom_runner")
        entered.set()
        await gate.wait()
        return {"text": "慢任务完成", "summary": "慢任务完成"}

    store = ScheduledTriggerStore(
        tmp_path,
        conversation=conv,
        custom_runner=slow_or_boom,
        clock=lambda: t[0],
        run_timeout_seconds=600.0,
    )
    trg = store.create(name="并发测试", template="custom", cron_expr="*/5 * * * *", prompt="检查队列")
    due_at = trg["next_run_at"]
    t[0] = due_at

    async def scenario():
        first_task = asyncio.create_task(store.tick(due_at))
        await entered.wait()
        # 此时 running_run_id 非空；下一轮到点 tick 必须记 skipped_overlap 并推进 next_run_at，不并发重入
        second_due = store.get(trg["id"])["next_run_at"]
        t[0] = second_due
        overlap_res = await store.tick(second_due)
        assert len(overlap_res) == 1
        assert overlap_res[0]["status"] == "skipped_overlap"
        assert store.get(trg["id"])["next_run_at"] > second_due

        gate.set()
        first_res = await first_task
        assert first_res[0]["status"] == "succeeded"
        assert store.get(trg["id"])["running_run_id"] == ""

    asyncio.run(scenario())

    runs = store.recent_runs(trg["id"], limit=10)
    assert {r["status"] for r in runs} >= {"succeeded", "skipped_overlap"}

    # 异常隔离：执行抛错时写入 failed 与 last_error，绝不抛异常中断主循环
    boom_trg = store.create(name="失败测试", template="custom", cron_expr="0 12 * * *", prompt="BOOM")
    fail_res = asyncio.run(store.run_now(boom_trg["id"]))
    assert fail_res["status"] == "failed"
    assert "boom_in_custom_runner" in fail_res["error"]
    persisted = store.get(boom_trg["id"])
    assert persisted["last_outcome"] == "failed"
    assert "boom_in_custom_runner" in persisted["last_error"]
    assert persisted["running_run_id"] == ""

    # 超时死锁回收：手工模拟一条超时遗留的 running 记录，下一次 run_now 能自动回收并正常执行
    stale_trg = store.create(name="超时回收", template="custom", cron_expr="0 13 * * *", prompt="正常执行")
    with store.db() as db:
        db.execute(
            "INSERT INTO trigger_runs(id, trigger_id, started_at, status) VALUES('trun_stale', ?, ?, 'running')",
            (stale_trg["id"], t[0] - 1200),
        )
        db.execute("UPDATE scheduled_triggers SET running_run_id='trun_stale' WHERE id=?", (stale_trg["id"],))
    recovered = asyncio.run(store.run_now(stale_trg["id"]))
    assert recovered["status"] == "succeeded"
    stale_runs = {r["id"]: r for r in store.recent_runs(stale_trg["id"])}
    assert stale_runs["trun_stale"]["status"] == "failed"
    assert "超时" in stale_runs["trun_stale"]["error"]


def test_agent_tools_trigger_manage_source_and_activity(tmp_path: Path):
    conv = DummyConversation(tmp_path)

    class StubProposals:
        workspace = tmp_path

    class StubStore:
        def list(self):
            return []

    class StubCapabilities:
        def search(self, *a, **k):
            return []

    class StubGoals:
        def list(self):
            return []

        def enabled(self):
            return False

    tools = AgentTools(tmp_path, conv, StubProposals(), StubStore(), None, StubCapabilities(), StubGoals())
    store = ScheduledTriggerStore(tmp_path, conversation=conv)
    tools.scheduled_triggers = store

    # list 只读，无需用户消息来源
    listed = asyncio.run(tools.call("trigger_manage", {"action": "list"}, {}))
    assert listed["count"] == 0

    # 写操作无真实用户消息来源必须被拒绝
    with pytest.raises(ValueError, match="来源"):
        asyncio.run(tools.call("trigger_manage", {"action": "create", "template": "morning_briefing"}, {}))

    # 写入真实 running 用户消息后，create / pause / resume / update / run_now / delete 全链路打通且留痕到 Activity
    with conv.db() as db:
        db.execute(
            "INSERT INTO messages(id, role, text, raw_text, status, request_id, created_at) VALUES(?,?,?,?,?,?,?)",
            ("msg-user-1", "user", "帮我加个每天早八点半的晨间简报", "帮我加个每天早八点半的晨间简报", "running", "req-user-1", 1760000001.0),
        )
        db.commit()

    ctx = {"origin_session_id": "s1", "origin_message_id": "msg-user-1", "origin_request_id": "req-user-1"}
    created = asyncio.run(tools.call("trigger_manage", {"action": "create", "template": "morning_briefing", "cron_expr": "30 8 * * *"}, ctx))
    tid = created["trigger"]["id"]
    assert created["trigger"]["status"] == "active"

    paused = asyncio.run(tools.call("trigger_manage", {"action": "pause", "trigger_id": tid}, ctx))
    assert paused["trigger"]["status"] == "paused"

    resumed = asyncio.run(tools.call("trigger_manage", {"action": "resume", "trigger_id": tid}, ctx))
    assert resumed["trigger"]["status"] == "active"

    updated = asyncio.run(tools.call("trigger_manage", {"action": "update", "trigger_id": tid, "name": "早报 Pro", "cron_expr": "0 8 * * 1-5"}, ctx))
    assert updated["trigger"]["name"] == "早报 Pro"

    ran = asyncio.run(tools.call("trigger_manage", {"action": "run_now", "trigger_id": tid}, ctx))
    assert ran["status"] == "succeeded"

    deleted = asyncio.run(tools.call("trigger_manage", {"action": "delete", "trigger_id": tid}, ctx))
    assert deleted["deleted"] is True

    act_feed = Activity(tmp_path / "tool-effects.sqlite", conv, StubStore()).items(limit=20)
    summaries = [item["summary"] for item in act_feed if item["tool"] == "trigger_manage"]
    assert len(summaries) == 6
    assert any("新建触发器" in s for s in summaries)
    assert any("立即触发" in s for s in summaries)
    assert any("删除触发器" in s for s in summaries)


@pytest.fixture
def app_service(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("WORKBENCH_HOME", str(tmp_path))
    monkeypatch.setenv("WORKBENCH_STATE", str(tmp_path / "state"))
    import app

    app = importlib.reload(app)
    with TestClient(app.app) as client:
        yield app, client


def test_app_triggers_channels_and_health_endpoints(app_service, monkeypatch: pytest.MonkeyPatch):
    app, client = app_service
    headers = {"Authorization": f"Bearer {app.TOKEN}"}

    # 1. /health 原样保留 personal_send_message_v1，且包含新开关只读快照（默认 False）
    health = client.get("/health")
    assert health.status_code == 200
    h_json = health.json()
    assert "personal_send_message_v1" in h_json["features"]
    assert h_json["features"]["triggers"] is False
    assert h_json["features"]["channels"] is False
    assert h_json["superagent_flags"]["triggers"] is False

    # 2. GET /personal/triggers 返回预设模板、两条默认 paused 种子与开关状态
    r_list = client.get("/personal/triggers", headers=headers)
    assert r_list.status_code == 200
    body = r_list.json()
    assert body["triggers_enabled"] is False
    assert len(body["triggers"]) == 2
    assert len(body["templates"]) == 3

    # 3. POST / PATCH / POST action / DELETE /personal/triggers
    r_create = client.post(
        "/personal/triggers",
        headers=headers,
        json={"name": "喝水提醒", "template": "custom", "cron_expr": "0 10,15 * * 1-5", "prompt": "起来接杯温水活动一下", "channel": "personal"},
    )
    assert r_create.status_code == 200
    tid = r_create.json()["trigger"]["id"]

    r_patch = client.patch(f"/personal/triggers/{tid}", headers=headers, json={"name": "下午茶与喝水提醒"})
    assert r_patch.status_code == 200
    assert r_patch.json()["trigger"]["name"] == "下午茶与喝水提醒"

    r_pause = client.post(f"/personal/triggers/{tid}/action", headers=headers, json={"action": "pause"})
    assert r_pause.status_code == 200
    assert r_pause.json()["trigger"]["status"] == "paused"

    # 即使 triggers_on 默认为 False，手动 run_now 依然可以跑通全链路验证
    r_run = client.post(f"/personal/triggers/{tid}/action", headers=headers, json={"action": "run_now"})
    assert r_run.status_code == 200
    assert r_run.json()["status"] == "succeeded"
    assert r_run.json()["message_id"].startswith("task-result:")

    r_del = client.delete(f"/personal/triggers/{tid}", headers=headers)
    assert r_del.status_code == 200
    assert r_del.json()["deleted"] is True
    assert client.delete(f"/personal/triggers/{tid}", headers=headers).status_code == 404

    # 4. Channels REST 接口与 GET /personal/conversation?channel=... 兼容
    r_ch = client.get("/personal/channels", headers=headers)
    assert r_ch.status_code == 200
    assert r_ch.json()["active"] == "personal"

    r_sel = client.post("/personal/channels/select", headers=headers, json={"channel": "work"})
    assert r_sel.status_code == 200
    assert r_sel.json()["active"] == "work"

    assert client.post("/personal/channels/select", headers=headers, json={"channel": "invalid_ch"}).status_code == 400
    assert client.get("/personal/conversation", headers=headers).status_code == 200
    assert client.get("/personal/conversation?channel=work", headers=headers).status_code == 200
