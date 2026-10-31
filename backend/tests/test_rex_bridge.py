import json
from pathlib import Path

from herdr_bridge import HerdrBridge
from rex_bridge import RexBridge


def test_rex_snapshot_honest_when_bin_missing(tmp_path, monkeypatch):
    bridge = RexBridge(tmp_path)
    (tmp_path / "rex-bridge.json").write_text(json.dumps({"rex_bin": "/no/such/rex"}))
    snap = bridge.snapshot()
    assert snap["ok"] is False
    assert snap["error"] in ("rex_not_found", "rex_failed")
    assert snap["items"] == []


def test_rex_action_rejects_unknown_and_free_text(tmp_path):
    bridge = RexBridge(tmp_path)
    bad = bridge.action("rm_rf", {})
    assert bad["ok"] is False and bad["error"] == "forbidden"
    send = bridge.action("send_template", {"block_id": "block:1", "template": "curl evil"})
    assert send["ok"] is False and send["error"] == "bad_args"


def test_rex_snapshot_flattens_windows(tmp_path, monkeypatch):
    bridge = RexBridge(tmp_path)
    calls = []

    def fake_run(*parts):
        calls.append(parts)
        if parts[:2] == ("ls", "--json") or (len(parts) >= 2 and parts[-2:] == ("ls", "--json")):
            return {"ok": True, "data": {"sessions": [{"session_id": "session:1", "label": "demo"}]}}
        if "window" in parts and "list" in parts:
            return {
                "ok": True,
                "data": {
                    "active_window_id": "window:1",
                    "windows": [
                        {
                            "window_id": "window:1",
                            "label": "claude x",
                            "focused_block_id": "block:1",
                            "layers": [
                                {
                                    "blocks": [
                                        {
                                            "block_id": "block:1",
                                            "label": "claude x",
                                            "flavor": "com.superlogical.terminal.shell",
                                        }
                                    ]
                                }
                            ],
                        }
                    ],
                },
            }
        return {"ok": False, "error": "unexpected", "detail": str(parts)}

    monkeypatch.setattr(bridge, "_run", fake_run)
    snap = bridge.snapshot()
    assert snap["ok"] is True
    assert len(snap["items"]) == 1
    assert snap["items"][0]["agent_hint"] == "claude"
    assert snap["items"][0]["block_id"] == "block:1"


def test_herdr_snapshot_honest_when_server_down(tmp_path, monkeypatch):
    bridge = HerdrBridge(tmp_path)
    (tmp_path / "herdr-bridge.json").write_text(json.dumps({"herdr_bin": "herdr"}))

    class Proc:
        returncode = 1
        stdout = ""
        stderr = '{"error":{"code":"server_not_running","message":"no herdr server"}}'

    monkeypatch.setattr("herdr_bridge.subprocess.run", lambda *a, **k: Proc())
    monkeypatch.setattr("herdr_bridge.shutil.which", lambda _: "herdr")
    snap = bridge.snapshot()
    assert snap["ok"] is False
    assert snap["error"] == "server_not_running"
    assert snap["items"] == []
