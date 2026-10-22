# ruff: noqa: I001
# isort: skip_file
"""身体数据：Garmin 按天入库（Garmin 同步夹具） → /personal/health 7 天；今天页待办改期；下一步的今日简报。"""

import asyncio
import json
import time
from datetime import datetime, timedelta

from next_steps import NextSteps, health_line
from personal_hub import TZ, PersonalHub
from today import Today


def day(i):
    return (datetime.now(TZ).date() - timedelta(days=i)).isoformat()


def test_health_returns_days_in_order_and_skips_old_garmin_in_briefing(tmp_path):
    hub = PersonalHub(tmp_path, home=tmp_path)
    for i, battery in ((0, 47), (1, 62), (3, 30)):
        hub.matter(
            "garmin", day(i), "佳明健康记录", {"date": day(i), "measurements": {"body_battery": battery, "sleep_seconds": 26000}, "body_battery_curve": [[1, battery]], "missing": []}, deadline=None
        )
    data = hub.health(7)
    assert [d["date"] for d in data["days"]] == [day(3), day(1), day(0)]
    assert data["today"]["measurements"]["body_battery"] == 47 and data["phone"] is None
    garmin = [c for c in hub.briefing()["cards"] if c["source"] == "garmin"]
    assert [c["source_id"] for c in garmin] == [day(0)], "历史天数不进简报卡"


def test_health_falls_back_to_phone_when_no_garmin_today(tmp_path):
    hub = PersonalHub(tmp_path, home=tmp_path)
    hub.matter("garmin", day(1), "佳明健康记录", {"measurements": {"steps": 100}, "body_battery_curve": []}, deadline=None)
    hub.matter("phone_health", "node:x", "手机健康记录", {"steps": 5000, "source": "Apple HealthKit"}, deadline=None)
    data = hub.health(7)
    assert data["today"] is None and data["phone"]["steps"] == 5000


def test_garmin_sync_refetches_recent_and_backfills_missing(tmp_path, monkeypatch):
    hub = PersonalHub(tmp_path, home=tmp_path)
    hub.matter("garmin", day(4), "佳明健康记录", {"version": 2, "measurements": {"steps": 1}, "body_battery_curve": []}, deadline=None)
    hub.matter("garmin", day(5), "佳明健康记录", {"date": day(5), "measurements": {"steps": 1}, "missing": []}, deadline=None)  # 旧格式要重取
    seen = []

    async def command(args, timeout=25):
        dates = [str(a) for a in args[4:]]
        seen.extend(dates)
        return {"source": "Garmin Connect", "days": [{"date": d, "measurements": {"steps": 9}, "body_battery_curve": [], "missing": []} for d in dates]}

    monkeypatch.setattr(hub, "command", command)
    asyncio.run(hub.sync_source("garmin"))
    assert day(0) in seen and day(1) in seen and day(5) in seen and day(4) not in seen


def test_todo_postpone_changes_only_due_line(tmp_path):
    folder = tmp_path / "任务" / "待处理"
    folder.mkdir(parents=True)
    f = folder / "交报销.md"
    f.write_text("---\nflow: 任务\n状态: 待处理\n计划结束: 2026-10-10\n---\n正文不动\n", encoding="utf-8")
    now = datetime(2026, 10, 15, 9, 0, tzinfo=TZ).timestamp()
    t = Today(vault=tmp_path, clock=lambda: now)
    r = t.todo_postpone("任务/待处理/交报销.md")
    assert r["due"] == "2026-10-16" and r["undo"] == "计划结束: 2026-10-10"
    assert f.read_text(encoding="utf-8") == "---\nflow: 任务\n状态: 待处理\n计划结束: 2026-10-16\n---\n正文不动\n"


class Hub:
    def __init__(self, h):
        self.h = h

    def matters(self):
        return []

    def health(self, days):
        return self.h


def test_headline_from_model_and_rule_fallback_mentions_body(tmp_path):
    h = {
        "today": {"measurements": {"body_battery": 31, "sleep_seconds": 5.2 * 3600, "sleep_score": 60, "hrv_last_night": 38}},
        "days": [{"measurements": {"body_battery": 31, "sleep_seconds": 5.2 * 3600}}],
    }
    seen = {}

    async def model(digest):
        seen.update(digest["health"])
        return {"headline": "睡了 5.2 小时、电量 31，今天少排点事。", "items": []}

    engine = NextSteps(tmp_path, Hub(h), model=model)
    asyncio.run(engine.refresh(force=True))
    assert seen["body_battery"] == 31 and seen["sleep_hours"] == 5.2
    assert engine.snapshot()["headline"] == "睡了 5.2 小时、电量 31，今天少排点事。"

    async def broken(digest):
        raise TimeoutError("down")

    engine = NextSteps(tmp_path / "b", Hub(h), model=broken)
    asyncio.run(engine.refresh(force=True))
    assert "身体电量 31" in engine.snapshot()["headline"] and "睡了 5.2 小时" in engine.snapshot()["headline"]
    assert health_line({}) == ""


def test_phone_connect_syncs_stale_phone_sources_only(tmp_path, monkeypatch):
    hub = PersonalHub(tmp_path, home=tmp_path)
    calls = []

    async def sync(name, force=False):
        calls.append((name, force))

    monkeypatch.setattr(hub, "sync", sync)
    with hub.db() as d:
        d.execute("INSERT INTO sources VALUES(?,?)", ("phone_calendar", json.dumps({"name": "phone_calendar", "updated_at": time.time()})))
    asyncio.run(hub.sync_phone())
    assert calls == [("phone_health", True), ("phone_reminders", True)], "刚成功过的日历不重拉"


def test_phone_connect_backs_off_after_recent_attempt(tmp_path, monkeypatch):
    hub = PersonalHub(tmp_path, home=tmp_path)
    calls = []

    async def sync(name, force=False):
        calls.append(name)

    monkeypatch.setattr(hub, "sync", sync)
    with hub.db() as d:
        for n in ("phone_health", "phone_calendar", "phone_reminders"):
            d.execute("INSERT INTO sources VALUES(?,?)", (n, json.dumps({"name": n, "attempted_at": time.time()})))
    asyncio.run(hub.sync_phone())
    assert calls == [], "刚试过（哪怕失败）就不再每次连上都拉"
