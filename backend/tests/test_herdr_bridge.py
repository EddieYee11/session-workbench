import json

from herdr_bridge import HerdrBridge, unwrap_snapshot
from fleet import from_herdr
from superagent_flags import SuperagentFlags


def test_unwrap_result_snapshot():
    raw = {"id": 1, "result": {"snapshot": {"tabs": [{"tab_id": "t1", "label": "A", "agent_status": "working"}]}}}
    assert unwrap_snapshot(raw)["tabs"][0]["tab_id"] == "t1"


def test_snapshot_parses_wrapped_cli(tmp_path, monkeypatch):
    bridge = HerdrBridge(tmp_path)
    (tmp_path / "herdr-bridge.json").write_text(json.dumps({"herdr_bin": "herdr", "local_machine": "mini"}))

    class Proc:
        returncode = 0
        stdout = json.dumps({"result": {"snapshot": {"tabs": [{"tab_id": "abc", "label": "Pi", "agent_status": "idle"}]}}})
        stderr = ""

    monkeypatch.setattr("herdr_bridge.subprocess.run", lambda *a, **k: Proc())
    monkeypatch.setattr("herdr_bridge.shutil.which", lambda _: "herdr")
    snap = bridge.snapshot()
    assert snap["ok"] and snap["items"][0]["id"] == "abc" and snap["machine"] == "mini"


def test_fleet_ids_include_machine():
    items = from_herdr({"at": 1, "items": [{"id": "t1", "raw_id": "t1", "title": "X", "status": "working", "machine": "mbp"}]})
    assert items[0]["id"] == "herdr:mbp:t1" and items[0]["host"] == "mbp"


def test_ingest_and_action_queue(tmp_path):
    (tmp_path / "superagent-flags.json").write_text(json.dumps({"herdr_write": "on"}))
    bridge = HerdrBridge(tmp_path, flags=SuperagentFlags(tmp_path))
    bridge.ingest("mbp", {"tabs": [{"tab_id": "t9", "label": "Codex", "agent_status": "working"}]})
    all_snap = bridge.snapshot_all()
    assert any(i.get("machine") == "mbp" for i in all_snap["items"])
    q = bridge.enqueue_action("mbp", "focus_tab", {"tab_id": "t9"}, "req-herdr-001")
    assert q["ok"] and bridge.pending_actions("mbp")[0]["action"] == "focus_tab"
    # interrupt without is_agent rejected
    bad = bridge.enqueue_action("mbp", "send_template", {"template": "interrupt", "tab_id": "t9", "is_agent": False}, "req-herdr-002")
    assert bad["error"] == "not_agent_pane"


def test_write_flag_off(tmp_path):
    (tmp_path / "superagent-flags.json").write_text(json.dumps({"herdr_write": "off"}))
    bridge = HerdrBridge(tmp_path, flags=SuperagentFlags(tmp_path))
    bridge.ingest("mbp", {"tabs": [{"tab_id": "t9", "label": "X", "agent_status": "working"}]})
    assert bridge.enqueue_action("mbp", "focus_tab", {"tab_id": "t9"}, "req-x")["error"] == "herdr_write_off"
