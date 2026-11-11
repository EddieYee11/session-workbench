from __future__ import annotations

import asyncio
import json
import sqlite3
import sys
import time
from pathlib import Path
from unittest.mock import AsyncMock

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_activity import AgentEventProjector, tool_activity
from context_working_set import MARKER
from direct_tools import (
    DIRECT_TOOL_NAMES,
    DIRECT_TOOL_SPECS,
    MCP_PREFIX,
    STRIPPED_ORIGIN_KEYS,
    attach_turn_reminders,
    build_direct_tools_reminder,
    select_direct_tools,
)
from hermes_prompt import SYSTEM_PROMPT
from hermes_runtime import HermesRuntime
from send_message import build_turn_reminder
from sse_stream import SSEBroadcaster, SSERingBuffer, TOOL_ACTIVITY_EVENTS


def test_direct_tool_specs_cover_all_seven_tools_and_strip_origin_ids() -> None:
    expected = (
        "business_operation",
        "memory_recall",
        "task_submit",
        "task_status",
        "context_read",
        "pending_action_register",
        "trigger_manage",
    )
    assert DIRECT_TOOL_NAMES == expected
    for name in expected:
        spec = DIRECT_TOOL_SPECS[name]
        assert spec.mcp_name == f"{MCP_PREFIX}{name}"
        for origin_key in STRIPPED_ORIGIN_KEYS:
            assert origin_key not in spec.required
            assert origin_key not in spec.optional
            assert origin_key not in spec.signature

    # 校验 trigger_manage 与 @triggers-mcp 锁定的字段对齐
    trig = DIRECT_TOOL_SPECS["trigger_manage"]
    assert trig.required == ("action",)
    for field_name in ("trigger_id", "name", "template", "cron_expr", "prompt", "channel", "status", "kind", "event_source", "event_filter"):
        assert field_name in trig.optional

    rendered = build_direct_tools_reminder(expected)
    assert rendered.startswith("<system_reminder>\n")
    assert rendered.endswith("\n</system_reminder>")
    for origin_key in STRIPPED_ORIGIN_KEYS:
        assert origin_key not in rendered


def test_direct_tools_skip_greeting_and_merge_single_system_reminder_without_touching_prompt_budget() -> None:
    # SYSTEM_PROMPT 预算严守 < 2200 字
    assert len(SYSTEM_PROMPT) < 2200

    # 纯寒暄 L1 不注入任何直调提示，保持既有单测 input=='你好' 不变
    assert select_direct_tools("L1", "chat", "你好") == []
    assert attach_turn_reminders("你好", send_mode=False, tool_names=[]) == "你好"

    # 复合提醒+后台任务查询同时预绑定 business_operation 与 task_status
    combo = select_direct_tools("L1", "reminder", "帮我列出当前未完成的提醒事项，再看一眼有没有正在跑的后台任务")
    assert "business_operation" in combo
    assert "task_status" in combo

    # 定时简报查询自动纳入 trigger_manage
    trig_tools = select_direct_tools("L2", "general", "每天早上8点自动发早安简报")
    assert "trigger_manage" in trig_tools

    # send_mode=True 时与 build_turn_reminder 合并为单一 <system_reminder> 块，不互相屏蔽
    merged = attach_turn_reminders(
        "帮我看看这个月一共花了多少钱",
        send_mode=True,
        base_turn_reminder=build_turn_reminder(),
        tool_names=["business_operation", "pending_action_register"],
    )
    assert merged.startswith("帮我看看这个月一共花了多少钱\n\n<system_reminder>\n")
    assert merged.count("<system_reminder>") == 1
    assert merged.count("</system_reminder>") == 1
    assert "mcp__com_workbench__send_message" in merged
    assert "mcp__com_workbench__business_operation" in merged
    assert "严禁先调 `tool_search` 或 `tool_describe`" in merged


def test_agent_event_projector_tool_started_completed_dedup_and_cold_start_suppression() -> None:
    projector = AgentEventProjector()
    now = time.time()

    # 1. 冷启动首帧（历史已完成消息及旧工具步骤）绝不重放为新事件
    cold_msg = {
        "id": "u-old",
        "role": "user",
        "status": "completed",
        "created_at": now - 3600,
        "updated_at": now - 3590,
        "tasks": [
            {
                "id": "tool-old-1",
                "call_id": "call_old_1",
                "kind": "tool",
                "tool": "mcp__com_workbench__business_operation",
                "title": "查账",
                "status": "done",
                "started_at": now - 3595,
                "finished_at": now - 3594,
                "duration_ms": 120,
            }
        ],
    }
    _, cold_events = projector.project({"event": "snapshot", "data": {"messages": [cold_msg], "runs": []}})
    assert [e["event"] for e in cold_events] == ["task.progress"]

    # 2. 新回合工具进入 running -> 发射一次 tool.started，且首帧仍保持 task.progress
    live_running = {
        "id": "u-live",
        "role": "user",
        "status": "running",
        "created_at": now,
        "updated_at": now + 0.1,
        "tasks": [
            {
                "id": "tool-1",
                "call_id": "call_abc",
                "kind": "tool",
                "tool": "mcp__com_workbench__memory_recall",
                "title": "检索记忆",
                "status": "running",
                "started_at": now + 0.1,
            }
        ],
    }
    activity, started_events = projector.project(
        {
            "data": {
                "messages": [live_running],
                "runs": [{"id": "r1", "message_id": "u-live", "status": "running", "active_tool": "mcp__com_workbench__memory_recall"}],
            }
        }
    )
    assert activity["kind"] == "remembering"
    assert started_events[0]["event"] == "task.progress"
    tool_started = [e for e in started_events if e["event"] == "tool.started"]
    assert len(tool_started) == 1
    assert tool_started[0]["data"] == {
        "message_id": "u-live",
        "tool_id": "tool-1",
        "call_id": "call_abc",
        "tool": "mcp__com_workbench__memory_recall",
        "title": "检索记忆",
        "kind": tool_activity("mcp__com_workbench__memory_recall"),
        "status": "running",
        "started_at": now + 0.1,
    }

    # 3. 同一 running 状态重复通知不重复推帧
    _, dup_running = projector.project({"data": {"messages": [live_running], "runs": []}})
    assert not any(e["event"] == "tool.started" for e in dup_running)

    # 4. 工具变为 done（以及第 2 个工具变为 failed） -> 发射 tool.completed，含 duration_ms
    live_finished = {
        "id": "u-live",
        "role": "user",
        "status": "running",
        "created_at": now,
        "updated_at": now + 0.5,
        "tasks": [
            {
                "id": "tool-1",
                "call_id": "call_abc",
                "kind": "tool",
                "tool": "mcp__com_workbench__memory_recall",
                "title": "检索记忆",
                "status": "done",
                "started_at": now + 0.1,
                "finished_at": now + 0.35,
                "duration_ms": 250,
            },
            {
                "id": "tool-2",
                "call_id": "call_fail",
                "kind": "tool",
                "tool": "mcp__com_workbench__context_read",
                "title": "读取上下文",
                "status": "failed",
                "started_at": now + 0.36,
                "finished_at": now + 0.46,
            },
        ],
    }
    assistant_done = {
        "id": "a-live",
        "role": "assistant",
        "status": "completed",
        "text": "已整理好三条记忆要点",
        "created_at": now + 0.5,
        "updated_at": now + 0.5,
    }
    _, done_events = projector.project({"data": {"messages": [live_finished, assistant_done], "runs": []}})
    assert done_events[0]["event"] == "task.progress"
    completed = [e for e in done_events if e["event"] == "tool.completed"]
    assert len(completed) == 2
    assert completed[0]["data"]["status"] == "done"
    assert completed[0]["data"]["duration_ms"] == 250
    assert completed[1]["data"]["status"] == "failed"
    assert completed[1]["data"]["duration_ms"] == 100
    assert any(e["event"] == "agent.push" and e["data"]["message_id"] == "a-live" for e in done_events)

    # 5. 再次投影已完成状态绝不重复推送 tool.completed 或 agent.push
    _, dup_done = projector.project({"data": {"messages": [live_finished, assistant_done], "runs": []}})
    assert not any(e["event"] in ("tool.started", "tool.completed", "agent.push") for e in dup_done)

    # 6. 远古历史消息后续因表情等改动再次进入增量流时，其旧工具不会误发 tool.completed
    ancient_msg = {
        "id": "u-ancient",
        "role": "user",
        "status": "completed",
        "created_at": now - 86400,
        "updated_at": now + 1.0,
        "work_tasks": [
            {
                "id": "tool-ancient",
                "call_id": "c-ancient",
                "kind": "tool",
                "tool": "read_file",
                "title": "旧读取",
                "status": "done",
                "started_at": now - 86400,
                "finished_at": now - 86399,
                "duration_ms": 1000,
            }
        ],
    }
    _, ancient_events = projector.project({"data": {"messages": [ancient_msg], "runs": []}})
    assert not any(e["event"] in ("tool.started", "tool.completed") for e in ancient_events)


def test_sse_broadcaster_streams_tool_activity_events_from_conversation_updates(tmp_path: Path) -> None:
    from conversation import PersonalConversation

    ring = SSERingBuffer(tmp_path / "sse_events.sqlite", capacity=200)
    broadcaster = SSEBroadcaster(ring)
    projector = AgentEventProjector()

    class ToolClient:
        runtime_name = "hermes"
        session_key = "hermes_v2_session_id"
        has_native_history = True

        def key(self) -> str:
            return "fixture"

        async def create_session(self) -> str:
            return "com-hermes-main"

        def bind(self, _ctx: dict) -> None:
            pass

        async def stop(self) -> None:
            pass

        async def abort(self) -> None:
            pass

        async def stream_chat(self, session_id: str, text: str):
            yield "run.started", {"run_id": "run_sse_1"}
            yield "input.delivered", {"request_id": "req-sse-tool-1", "run_id": "run_sse_1"}
            yield "tool.started", {
                "tool_name": "mcp__com_workbench__business_operation",
                "tool_call_id": "tc_1",
                "args": {"tool": "bookkeeping", "args": {"action": "recent", "count": 3}},
            }
            await asyncio.sleep(0.02)
            yield "tool.completed", {
                "tool_name": "mcp__com_workbench__business_operation",
                "tool_call_id": "tc_1",
                "result": {"items": []},
            }
            yield "assistant.completed", {"content": "最近没有消费记录。"}
            yield "run.completed", {"run_id": "run_sse_1"}
            yield "done", {}

    convo = PersonalConversation(tmp_path, ToolClient())
    projector.project({"event": "snapshot", "data": convo.snapshot()})
    last_rev = convo.snapshot()["revision"]

    def on_notify() -> None:
        nonlocal last_rev
        change = convo.changes_since(last_rev)
        if change["revision"] > last_rev:
            last_rev = change["revision"]
            activity, semantic = projector.project({"data": change})
            broadcaster.publish("update", {**change, "activity": activity})
            broadcaster.publish_semantic_batch(semantic)

    convo._on_notify.append(on_notify)

    async def run_scenario() -> list[str]:
        frames: list[str] = []

        async def reader() -> None:
            async for raw_frame in broadcaster.stream_client(cursor=0, get_snapshot_fn=convo.snapshot, keepalive_seconds=5.0):
                frames.append(raw_frame)
                if "event: agent.push\n" in raw_frame:
                    break

        reader_task = asyncio.create_task(reader())
        await asyncio.sleep(0.02)
        convo.submit("req-sse-tool-1", "帮我看看这个月花了多少並查近3笔")
        await convo.process_one()
        await asyncio.wait_for(reader_task, timeout=3.0)
        return frames

    frames = asyncio.run(run_scenario())
    joined = "".join(frames)
    assert "event: snapshot\n" in joined
    assert "event: update\n" in joined
    assert "event: task.progress\n" in joined
    assert "event: tool.started\n" in joined
    assert "event: tool.completed\n" in joined
    assert "event: agent.push\n" in joined

    tool_events = ring.get_since(0, event_types=TOOL_ACTIVITY_EVENTS)
    assert [ev.event_type for ev in tool_events] == ["tool.started", "tool.completed"]
    assert tool_events[0].data["tool"] == "mcp__com_workbench__business_operation"
    assert tool_events[0].data["call_id"] == "tc_1"
    assert tool_events[1].data["status"] == "done"


def test_hermes_runtime_records_first_bubble_ms_in_send_message_mode(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("COM_SENDMESSAGE_MODE", "on")
    monkeypatch.setenv("COM_FAST_CLASSIFIER_MODE", "off")

    posted_bodies: list[dict] = []

    def handler(_request: httpx.Request) -> httpx.Response:
        posted_bodies.append(json.loads(_request.content.decode("utf-8")))
        return httpx.Response(200, json={"run_id": "run_bubble_1"})

    real_async_client = httpx.AsyncClient
    monkeypatch.setattr(
        httpx,
        "AsyncClient",
        lambda **kwargs: real_async_client(**{**kwargs, "transport": httpx.MockTransport(handler)}),
    )

    async def scenario() -> None:
        client = HermesRuntime(tmp_path)
        client.create_session = AsyncMock()
        client.key = lambda: "fixture"
        client.request = AsyncMock(return_value={"status": "completed", "output": "内部收尾思考"})

        async def events(_run_id: str):
            # 早期内部思考不应冒充可见气泡延迟
            yield "assistant.delta", {"delta": "内部思考中..."}
            await asyncio.sleep(0.03)
            yield "tool.started", {
                "tool": "mcp__com_workbench__send_message",
                "tool_call_id": "call_sm_1",
                "args": {"type": "text", "content": "好，马上帮你查"},
            }
            yield "tool.completed", {
                "tool": "mcp__com_workbench__send_message",
                "tool_call_id": "call_sm_1",
                "result": {"ok": True},
            }
            await asyncio.sleep(0.04)
            yield "run.completed", {"status": "completed", "output": "内部收尾思考"}

        client._events = events
        wrapped = (
            MARKER
            + json.dumps({"origin_request_id": "req-bubble-1", "origin_message_id": "m-bubble-1"})
            + "\n用户消息：\n帮我看看这个月一共花了多少钱"
        )
        out = [ev async for ev in client.stream_chat("main", wrapped)]
        assert out

    asyncio.run(scenario())

    # 确认 <system_reminder> 同时包含 send_message 与直调工具契约，且不污染原始用户前文
    sent_input = posted_bodies[0]["input"]
    assert sent_input.startswith("帮我看看这个月一共花了多少钱\n\n<system_reminder>\n")
    assert sent_input.count("<system_reminder>") == 1
    assert "mcp__com_workbench__business_operation" in sent_input

    with sqlite3.connect(tmp_path / "hermes-runs.sqlite") as db:
        metrics = json.loads(
            db.execute("SELECT data FROM context_metrics WHERE request_id=?", ("req-bubble-1",)).fetchone()[0]
        )
    assert "first_bubble_ms" in metrics
    assert metrics["first_bubble_ms"] >= 25.0
    assert metrics["first_text_ms"] == metrics["first_bubble_ms"]
    assert metrics["first_bubble_ms"] < metrics["elapsed_ms"]

    with sqlite3.connect(tmp_path / "message-routing.sqlite") as db:
        router_first_ms, router_elapsed_ms = db.execute(
            "SELECT first_text_ms, elapsed_ms FROM decisions WHERE request_id=?",
            ("req-bubble-1",),
        ).fetchone()
    assert router_first_ms == pytest.approx(metrics["first_bubble_ms"])
    assert router_first_ms < router_elapsed_ms
