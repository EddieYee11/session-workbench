"""设备能力报告：从调用记录汇总每个能力的授权、最近成功/被拒/失败。"""
import json
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from device_nodes import DeviceNodes

NODE = "node_" + "a" * 32


def _nodes(tmp_path):
    n = DeviceNodes(tmp_path)
    n.register({"id": NODE, "capabilities": [
        {"tool": "calendar.list", "permission": True},
        {"tool": "reminders.create", "permission": False},
        {"tool": "contacts.search", "permission": True},
    ]})
    return n


def _add(n, ident, tool, status, age=10, **extra):
    t = time.time() - age
    row = {"id": ident, "node": NODE, "tool": tool, "status": status,
           "created_at": t, "finished_at": t, **extra}
    with n.db() as d:
        d.execute("INSERT INTO invocations VALUES(?,?,?,?)", (ident, NODE, ident, json.dumps(row)))


def _by(report):
    return {i["tool"]: i for i in report["items"]}


def test_success_counts_and_chat_source(tmp_path):
    n = _nodes(tmp_path)
    _add(n, "device_1", "calendar.list", "succeeded", age=100)
    _add(n, "device_2", "calendar.list", "succeeded", age=20)
    _add(n, "device_3", "calendar.list", "succeeded", age=9 * 86400)
    c = _by(n.capability_report(NODE))["calendar.list"]
    assert c["recent_7d"] == 2 and c["via_sync"] is False
    assert c["last_success_at"] == pytest.approx(time.time() - 20, abs=5)


def test_denied_and_failed_reason(tmp_path):
    n = _nodes(tmp_path)
    _add(n, "device_4", "reminders.create", "permission_denied")
    _add(n, "device_5", "reminders.create", "failed", age=5, reason="系统拒绝")
    r = _by(n.capability_report(NODE))["reminders.create"]
    assert r["permission"] is False and r["last_denied_at"] and r["last_success_at"] is None
    assert r["last_failed_reason"] == "系统拒绝" and r["recent_7d"] == 0


def test_sync_flag_follows_latest_success(tmp_path):
    n = _nodes(tmp_path)
    _add(n, "device_6", "calendar.list", "succeeded", age=500)
    _add(n, "sync-phone_calendar-1", "calendar.list", "succeeded", age=50)
    assert _by(n.capability_report(NODE))["calendar.list"]["via_sync"] is True
    _add(n, "device_7", "calendar.list", "succeeded", age=5)
    assert _by(n.capability_report(NODE))["calendar.list"]["via_sync"] is False


def test_untouched_capability_and_unknown_node(tmp_path):
    n = _nodes(tmp_path)
    c = _by(n.capability_report(NODE))["contacts.search"]
    assert c["last_success_at"] is None and c["recent_7d"] == 0 and c["via_sync"] is False
    with pytest.raises(KeyError):
        n.capability_report("node_" + "b" * 32)
