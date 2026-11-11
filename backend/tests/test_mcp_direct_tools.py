from __future__ import annotations

import asyncio
import sqlite3
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import hermes_mcp as mcp_mod
from hermes_metrics.source_binding import KEYS, SOURCE_TOOLS, bind_source


def _seed_live_turn(root: Path, session_id: str, message_id: str, request_id: str) -> None:
    with sqlite3.connect(root / "personal-conversation.sqlite") as db:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS reaction_turns(session_id, message_id, request_id, expires_at);
            CREATE TABLE IF NOT EXISTS messages(id, role, status, request_id, supplement_to_message_id);
            """
        )
        db.execute("INSERT OR REPLACE INTO reaction_turns VALUES(?,?,?,?)", (session_id, message_id, request_id, time.time() + 120))
        db.execute("INSERT OR REPLACE INTO messages VALUES(?,?,?,?,NULL)", (message_id, "user", "running", request_id))


def test_direct_tools_strip_origin_fields_from_advertised_schema():
    expected_origin_bound = {
        "business_operation",
        "task_submit",
        "pending_action_register",
        "send_message",
        "trigger_manage",
        "memory_save",
        "decision_record",
    }
    assert expected_origin_bound <= SOURCE_TOOLS

    tools = {t.name: t for t in mcp_mod.mcp._tool_manager.list_tools()}
    for name in expected_origin_bound:
        assert name in tools, f"缺少 MCP 工具: {name}"
        props = tools[name].parameters.get("properties", {})
        reqs = tools[name].parameters.get("required", [])
        for key in KEYS:
            assert key not in props, f"{name} schema 仍残留隐藏字段 {key}"
            assert key not in reqs, f"{name} required 仍残留隐藏字段 {key}"


def test_high_frequency_direct_tools_have_concise_chinese_descriptions():
    tools = {t.name: t for t in mcp_mod.mcp._tool_manager.list_tools()}
    required_tools = (
        "business_operation",
        "memory_recall",
        "task_submit",
        "task_status",
        "context_read",
        "pending_action_register",
        "trigger_manage",
    )
    for name in required_tools:
        desc = tools[name].description or ""
        assert desc.strip(), f"{name} 缺少工具描述"
        assert any("\u4e00" <= ch <= "\u9fff" for ch in desc), f"{name} 描述应为精炼中文: {desc}"

    # business_operation 描述已内联常用子工具参数结构，不再强迫模型先调 context_read("business")
    biz_desc = tools["business_operation"].description
    assert "bookkeeping" in biz_desc and "remind" in biz_desc and "calendar_event" in biz_desc
    assert 'context_read(module, reference="business")' not in biz_desc


def test_source_binding_injects_origin_for_trigger_writes_and_skips_readonly_list(tmp_path: Path):
    _seed_live_turn(tmp_path, "sess-main", "msg-101", "req-101")

    # 1. trigger_manage(action='list') 与 memory_recall / task_status 均只读免注入
    assert bind_source(
        tool_name="mcp__com_workbench__trigger_manage",
        session_id="",
        args={"action": "list"},
        state=tmp_path,
    ) is None
    assert bind_source(tool_name="mcp__com_workbench__memory_recall", state=tmp_path) is None
    assert bind_source(tool_name="mcp__com_workbench__task_status", state=tmp_path) is None

    # 2. trigger_manage 写操作自动注入当前会话唯一活跃轮次的三元组
    bound = bind_source(
        tool_name="mcp__com_workbench__trigger_manage",
        session_id="sess-main",
        args={"action": "create", "template": "morning_briefing"},
        state=tmp_path,
    )
    assert bound == {
        "action": "modify",
        "args": {
            "origin_session_id": "sess-main",
            "origin_message_id": "msg-101",
            "origin_request_id": "req-101",
        },
    }

    # 3. 无有效会话来源时，写操作被阻断
    blocked = bind_source(
        tool_name="mcp__com_workbench__trigger_manage",
        session_id="sess-ghost",
        args={"action": "delete", "trigger_id": "strg_123"},
        state=tmp_path,
    )
    assert blocked is not None and blocked["action"] == "block"


def test_mcp_trigger_manage_forwards_readonly_and_source_bound_calls(monkeypatch: pytest.MonkeyPatch):
    calls: list[tuple[str, dict, dict]] = []
    monkeypatch.setattr(
        mcp_mod,
        "_shared",
        lambda name, args, context=None: calls.append((name, args, context or {})) or {"ok": True},
    )
    tool = mcp_mod.mcp._tool_manager.get_tool("trigger_manage")

    async def scenario():
        # list 无需注入三元组即可直接通过 FastMCP 参数校验并转发
        await tool.run({"action": "list"})
        assert calls[-1] == ("trigger_manage", {"action": "list", "kind": "cron"}, {})

        # create 写操作在缺少三元组且无活跃用户轮次时，_active_source 会安全阻断
        monkeypatch.setattr(mcp_mod, "_active_source", lambda mid="": (_ for _ in ()).throw(ValueError("无活跃来源")))
        with pytest.raises(Exception):
            await tool.run({"action": "create", "template": "morning_briefing"})

        # 注入三元组后一步直调成功
        await tool.run(
            {
                "action": "create",
                "template": "morning_briefing",
                "cron_expr": "30 8 * * *",
                "channel": "personal",
                "origin_session_id": "s1",
                "origin_message_id": "m1",
                "origin_request_id": "r1",
            }
        )
        assert calls[-1][0] == "trigger_manage"
        assert calls[-1][1]["template"] == "morning_briefing"
        assert calls[-1][2] == {
            "origin_session_id": "s1",
            "origin_message_id": "m1",
            "origin_request_id": "r1",
        }

    asyncio.run(scenario())
