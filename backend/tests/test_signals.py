import importlib
import sys
import time
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def test_notification_batch_is_authenticated_deduplicated_and_redacted(tmp_path, monkeypatch):
    monkeypatch.setenv("WORKBENCH_HOME", str(tmp_path))
    monkeypatch.setenv("WORKBENCH_STATE", str(tmp_path / "state"))
    import app
    app = importlib.reload(app)
    posted = int(time.time() * 1000)
    ordinary = {
        "id": "a" * 64, "package_name": "com.tencent.mm",
        "title": "小野", "text": "明天下午改到三点开会",
        "posted_at_ms": posted, "conversation_id": "shortcut-123",
        "reply_capable": True,
    }
    secret = {
        "id": "b" * 64, "package_name": "com.android.mms",
        "title": "验证码 123456", "text": "你的验证码是 123456",
        "posted_at_ms": posted,
    }
    with TestClient(app.app) as client:
        assert client.post("/personal/signals", json={"events": [ordinary]}).status_code == 401
        headers = {"Authorization": "Bearer " + app.TOKEN}
        first = client.post("/personal/signals", headers=headers, json={"events": [ordinary, secret]})
        assert first.status_code == 200
        assert len(first.json()["accepted_ids"]) == 2
        second = client.post("/personal/signals", headers=headers, json={"events": [ordinary]})
        assert second.json()["duplicate_ids"] == ["a" * 64]
        result = client.get("/personal/signals", headers=headers).json()
    assert result["count"] == 2
    assert result["items"][0]["text"] == "明天下午改到三点开会" or result["items"][1]["text"] == "明天下午改到三点开会"
    ordinary_saved = next(row for row in result["items"] if row["event_id"] == "a" * 64)
    assert ordinary_saved["conversation_id"] == "shortcut-123"
    assert ordinary_saved["reply_capable"] == 1
    redacted = next(row for row in result["items"] if row["event_id"] == "b" * 64)
    assert redacted["title"] == "敏感通知"
    assert redacted["text"] == ""
    assert "123456" not in str(result)


def test_inspection_records_summary_without_performing_an_action(tmp_path):
    from signals import PersonalSignals
    from signal_inspector import SignalInspector
    import asyncio

    state = tmp_path / "state"
    state.mkdir()
    signals = PersonalSignals(state)
    posted = int(time.time() * 1000)
    signals.ingest([{
        "id": "c" * 64, "package_name": "com.tencent.mm",
        "title": "同事", "text": "会议改到明天下午三点",
        "posted_at_ms": posted, "reply_capable": True,
    }])

    class Reviewer:
        async def review(self, item):
            assert item["package_name"] == "com.tencent.mm"
            return {"priority": "important", "category": "schedule",
                    "summary": "同事提议明天下午三点开会", "suggested_record": "待核对日历",
                    "draft_reply": "收到，我核对一下时间。"}

    assert asyncio.run(SignalInspector(signals, Reviewer()).inspect_once()) == 1
    row = signals.recent()["items"][0]
    assert row["status"] == "reviewed"
    assert row["priority"] == "important"
    assert row["summary"] == "同事提议明天下午三点开会"
    assert row["draft_reply"] == "收到，我核对一下时间。"
    assert signals.health()["important"] == 1
    assert asyncio.run(SignalInspector(signals, Reviewer()).inspect_once()) == 0
