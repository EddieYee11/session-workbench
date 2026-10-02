import importlib
import sys
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from personal import PersonalBridge, calendar_overview, finance_overview


def test_overview_is_authenticated_and_sources_are_independent(tmp_path, monkeypatch):
    monkeypatch.setenv("WORKBENCH_HOME", str(tmp_path))
    monkeypatch.setenv("WORKBENCH_STATE", str(tmp_path / "state"))
    import app
    app = importlib.reload(app)

    async def fetch(path):
        if path.endswith("calendar"):
            return {"available": True, "updated": 123, "items": [{
                "id": "event-1", "summary": "开会", "start": {"dateTime": "2026-10-01T10:00:00+08:00"},
                "end": {"dateTime": "2026-10-01T11:00:00+08:00"},
                "description": "不要透传", "attendees": ["private@example.com"],
            }]}
        raise ValueError("upstream_auth_failed")

    monkeypatch.setattr(app.personal, "fetch", fetch)
    with TestClient(app.app) as client:
        assert client.get("/personal/overview").status_code == 401
        response = client.get("/personal/overview", headers={"Authorization": "Bearer " + app.TOKEN})
    assert response.status_code == 200
    body = response.json()
    assert body["calendar"]["items"][0]["title"] == "开会"
    assert "description" not in body["calendar"]["items"][0]
    assert body["finance"] == {"available": False, "error_code": "upstream_auth_failed"}


def test_credential_file_must_be_private(tmp_path):
    bridge = PersonalBridge(tmp_path)
    assert (tmp_path / "dashboard-service-token").exists() is False
    try:
        bridge.token()
    except ValueError as exc:
        assert str(exc) == "credential_missing"
    else:
        raise AssertionError("missing token accepted")
    bridge.credential.write_text("test-only")
    bridge.credential.chmod(0o644)
    try:
        bridge.token()
    except ValueError as exc:
        assert str(exc) == "credential_permissions"
    else:
        raise AssertionError("world-readable token accepted")


def test_projection_preserves_scope_and_minor_units():
    calendar = calendar_overview({"available": True, "updated": 1, "items": []})
    assert calendar["coverage"] == {"scope": "configured_calendar_only", "days": 14}
    finance = finance_overview({"available": True, "updated": 2, "month": "2026-10",
        "month_start": "2026-10-01T00:00:00+08:00", "month_end": "2026-10-01T14:00:00+08:00",
        "month_transaction_count": 1,
        "coverage": {"items": "recent_49", "totals": "all_fetched_transactions_month_to_date"},
        "totals": {"CNY": {"income": 1000, "expense": 123,
        "today_expense": 23, "categories": {"餐饮": 123}}}})
    assert finance["totals"]["CNY"]["expense_minor"] == 123
    assert finance["month_transaction_count"] == 1
    assert finance["month_start"] == "2026-10-01T00:00:00+08:00"
    assert "items" not in finance
