"""Comprehensive test suite for Milestone M4:
Agent Memory & Post-Call Summary, Tool Calling Strictness, and Emotion/Backchanneling.

Verifies:
1. Automated post-call summary generation on session disconnection in records/YYYY-MM/<session_id>-summary.md & .json.
2. Obsidian task card dispatch (任务/待处理/<名称>.md) when explicit due dates exist.
3. Candidate facts ingestion into MemoryCatalog (_global/记忆库/Com/mem_*.md) with confidence >= 0.8.
4. Decision persistence into _global/记忆库/事件/YYYY-MM/.
5. ezBookkeeping timestamp second validation (rejection of millisecond timestamps, enforcement of seconds).
6. reminder_add dual-write behavior (WeChat queue + macOS Apple Calendar with 【分类】标题 format).
7. Context-based dynamic emotion emission.
8. 600-900ms pause backchanneling signal.
"""
from __future__ import annotations

import asyncio
import json
import re
import time
import uuid
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from conversation import PersonalConversation
from conversation_summary import extract_rule_based_summary, post_call_summary_pipeline
from memory_catalog import MemoryCatalog
from voice_live import (
    MockLiveAdapter,
    detect_emotion_state,
    execute_live_tool,
    voice_live_router,
)

TZ = timezone(timedelta(hours=8))


class DummyRuntime:
    runtime_name = "hermes"


@pytest.fixture
def test_env(tmp_path: Path, monkeypatch):
    """Sets up an isolated environment with temporary state, records, vault, and memory root."""
    state = tmp_path / "state"
    state.mkdir(parents=True, exist_ok=True)
    token_file = state / "token"
    token_file.write_text("test-m4-token-999")

    records_dir = tmp_path / "records"
    records_dir.mkdir(parents=True, exist_ok=True)

    vault_dir = tmp_path / "vault"
    (vault_dir / "任务/待处理").mkdir(parents=True, exist_ok=True)

    memory_root = tmp_path / "workspace"
    (memory_root / "_global/记忆库/Com").mkdir(parents=True, exist_ok=True)
    (memory_root / "_global/记忆库/事件").mkdir(parents=True, exist_ok=True)

    convo = PersonalConversation(state, DummyRuntime())

    return {
        "state": state,
        "token": "test-m4-token-999",
        "records_dir": records_dir,
        "vault_dir": vault_dir,
        "memory_root": memory_root,
        "convo": convo,
    }


# ==============================================================================
# 1. Post-Call Summary on WebSocket Disconnect
# ==============================================================================

def test_session_disconnection_generates_summary_files(test_env):
    """Verify that disconnecting WebSocket automatically triggers post-call summary in records/YYYY-MM/."""
    state = test_env["state"]
    records_dir = test_env["records_dir"]
    vault_dir = test_env["vault_dir"]
    memory_root = test_env["memory_root"]
    convo = test_env["convo"]
    session_id = f"test-sess-{uuid.uuid4().hex[:8]}"

    mock_adapter = MockLiveAdapter()
    app = FastAPI()
    app.include_router(
        voice_live_router(
            state,
            convo,
            adapter_factory=lambda v, p, t: mock_adapter,
            records_dir=records_dir,
            vault_dir=vault_dir,
            memory_root=memory_root,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {test_env['token']}"}
    with client.websocket_connect(f"/voice/live?session_id={session_id}", headers=headers) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["session_id"] == session_id

        # Send user text turn
        ws.send_text(json.dumps({"type": "text", "text": "你好 Com，今天讨论一下视频号新片调色"}))

        # Simulate upstream response with decision and commitment
        mock_adapter.enqueue_events([
            {
                "type": "transcript",
                "role": "assistant",
                "text": "好的 Eddie，我们决定统一改用青绿小清新风格，今晚20:30记得提醒我查日志。",
                "finished": True,
            },
            {"type": "turn_complete"},
        ])

        while True:
            msg = ws.receive()
            if msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "turn_complete":
                    break

    # Session disconnected! Verify summary files generated automatically
    month_str = datetime.now(TZ).strftime("%Y-%m")
    expected_md = records_dir / month_str / f"{session_id}-summary.md"
    expected_json = records_dir / month_str / f"{session_id}-summary.json"

    assert expected_md.exists(), f"Summary markdown file not created at {expected_md}"
    assert expected_json.exists(), f"Summary JSON file not created at {expected_json}"

    md_content = expected_md.read_text(encoding="utf-8")
    assert f"实时语音通话纪要 — {session_id}" in md_content
    assert "## 1. 对话要点与摘要" in md_content
    assert "## 2. 拍板与关键决定" in md_content
    assert "## 3. 行动待办 (Action Items)" in md_content
    assert "## 5. 逐字转写记录 (Transcript)" in md_content

    json_data = json.loads(expected_json.read_text(encoding="utf-8"))
    assert json_data["session_id"] == session_id
    assert json_data["turns_count"] >= 1
    assert "files" in json_data
    assert json_data["files"]["markdown"] == str(expected_md)
    assert json_data["files"]["json"] == str(expected_json)


# ==============================================================================
# 2. Tasks and Memory Updates Persistence
# ==============================================================================

def test_tasks_and_memory_updates_produced_correctly(test_env):
    """Verify tasks are written to vault/任务/待处理/<名称>.md and facts to MemoryCatalog."""
    state = test_env["state"]
    records_dir = test_env["records_dir"]
    vault_dir = test_env["vault_dir"]
    memory_root = test_env["memory_root"]
    session_id = f"test-task-mem-{uuid.uuid4().hex[:8]}"

    turns = [
        {
            "user": "Com，我喜欢简短利落的口语回复。另外计划明天 18:00 前完成岩馆路书第二章分镜，关联搜狐户外项目。",
            "assistant": "明白，已经为你记录好个人偏好，并建立了明天 18:00 截止的岩馆路书待办！另外决定本周成片不再使用暖色调。",
            "timestamp": time.time(),
        }
    ]
    tools_run = [
        {
            "name": "bookkeeping_add",
            "title": "记账 ¥88 · 岩馆门票",
            "ok": True,
            "arguments": {"amount": 88.0, "item": "岩馆门票"},
        }
    ]
    emotions = [{"state": "calm", "energy": 0.6}]

    res = asyncio.run(
        post_call_summary_pipeline(
            session_id=session_id,
            turns=turns,
            tools_run=tools_run,
            emotions=emotions,
            state=state,
            records_dir=records_dir,
            vault_dir=vault_dir,
            memory_root=memory_root,
        )
    )

    # 1. Verify Task Card Created in Obsidian Vault
    assert len(res["tasks_created"]) >= 1
    task_file = Path(res["tasks_created"][0])
    assert task_file.exists()
    assert task_file.parent == vault_dir / "任务/待处理"
    task_content = task_file.read_text(encoding="utf-8")
    assert "flow: 任务" in task_content
    assert "状态: 待处理" in task_content
    assert "计划结束:" in task_content
    assert "关联项目:" in task_content
    assert "下一步:" in task_content
    assert session_id in task_content

    # 2. Verify Fact Saved into MemoryCatalog
    catalog = MemoryCatalog(memory_root)
    memories = catalog.list()
    assert len(memories) >= 1
    fact = next((m for m in memories if "简短" in m["content"] or "Eddie" in m["content"]), None)
    assert fact is not None
    assert fact["version"] >= 1
    assert "quote" in fact["source"]
    assert "简短" in fact["source"]["quote"]

    # 3. Verify Decision Persisted to Events
    month_str = datetime.now(TZ).strftime("%Y-%m")
    events_folder = memory_root / "_global/记忆库/事件" / month_str
    assert events_folder.exists()
    event_files = list(events_folder.glob("*.md"))
    assert len(event_files) >= 1
    event_text = event_files[0].read_text(encoding="utf-8")
    assert session_id in event_text
    assert "Eddie 决议" in event_text


# ==============================================================================
# 3. ezBookkeeping Timestamp Second Validation
# ==============================================================================

def test_ezbookkeeping_timestamp_seconds_validation(test_env, monkeypatch):
    """Verify bookkeeping_add validates time in SECONDS and rejects milliseconds."""
    state = test_env["state"]

    calls: list[dict[str, Any]] = []

    async def mock_bookkeeping(self, args: dict[str, Any]):
        calls.append(args)
        return {"id": "tx-12345", "verified": True}

    from business_tools import BusinessTools
    monkeypatch.setattr(BusinessTools, "bookkeeping", mock_bookkeeping)

    # Case A: Milliseconds timestamp (> 1e11) must be REJECTED!
    ms_timestamp = 1731174000000  # 13 digits: Nov 2024 in milliseconds
    with pytest.raises(ValueError) as exc_info:
        asyncio.run(
            execute_live_tool(
                "bookkeeping_add",
                {"amount": 35.0, "item": "午餐", "time": ms_timestamp},
                state=state,
            )
        )
    assert "秒级" in str(exc_info.value)
    assert "毫秒" in str(exc_info.value)

    # Case B: Second-level timestamp (10 digits ~ 1.7e9) must be ACCEPTED!
    sec_timestamp = 1731174000  # 10 digits: seconds
    title, res = asyncio.run(
        execute_live_tool(
            "bookkeeping_add",
            {"amount": 35.0, "item": "午餐", "time": sec_timestamp},
            state=state,
        )
    )
    assert "记账 ¥35 · 午餐" in title
    assert res["time_seconds"] == sec_timestamp
    assert len(calls) == 1
    # Verify the ISO string formatted from second timestamp was passed to business tools
    expected_iso_prefix = datetime.fromtimestamp(sec_timestamp, tz=TZ).strftime("%Y-%m-%d")
    assert calls[0]["time"].startswith(expected_iso_prefix)

    # Case C: Default time when omitted must be current timestamp in seconds
    calls.clear()
    before_s = int(time.time())
    title, res = asyncio.run(
        execute_live_tool(
            "bookkeeping_add",
            {"amount": 20.0, "item": "拿铁咖啡"},
            state=state,
        )
    )
    after_s = int(time.time())
    assert before_s <= res["time_seconds"] <= after_s


# ==============================================================================
# 4. Reminder Dual-Write Behavior
# ==============================================================================

def test_reminder_dual_write_behavior(test_env, monkeypatch):
    """Verify reminder_add schedules dual-write to WeChat queue and Apple Calendar with 【分类】标题 format."""
    state = test_env["state"]

    remind_calls: list[dict[str, Any]] = []
    calendar_calls: list[dict[str, Any]] = []

    from business_tools import BusinessTools

    async def mock_remind(self, args: dict[str, Any]):
        remind_calls.append(args)
        return {
            "id": "rm_test_123",
            "verified": True,
            "item": {"id": "rm_test_123", "text": args.get("text"), "due": "2026-11-10 20:30"},
        }

    async def mock_calendar(self, args: dict[str, Any]):
        calendar_calls.append(args)
        return {"ok": True, "event_id": "cal_evt_456"}

    monkeypatch.setattr(BusinessTools, "remind", mock_remind)
    monkeypatch.setattr(BusinessTools, "calendar", mock_calendar)

    # Execute reminder tool call
    title, res = asyncio.run(
        execute_live_tool(
            "reminder_add",
            {
                "text": "检查Syncthing双机同步日志",
                "at": "2026-11-10 20:30",
                "category": "工作",
            },
            state=state,
        )
    )

    # 1. Primary write to WeChat reminder queue verified
    assert len(remind_calls) == 1
    assert remind_calls[0]["text"] == "检查Syncthing双机同步日志"
    assert remind_calls[0]["at"] == "2026-11-10 20:30"

    # 2. Dual-write to macOS Apple Calendar verified
    assert len(calendar_calls) == 1
    cal_call = calendar_calls[0]
    assert cal_call["action"] == "create"
    assert cal_call["date"] == "2026-11-10"
    assert cal_call["hour"] == 20
    assert cal_call["minute"] == 30
    # Summary title must follow 【分类】标题 format per Eddie's workflow
    assert cal_call["summary"] == "【工作】检查Syncthing双机同步日志"

    # 3. Execution receipt contains dual_write confirmation
    assert res["dual_write"] is True
    assert res["calendar_summary"] == "【工作】检查Syncthing双机同步日志"
    assert "设提醒 · 检查Syncthing双机同步日志" in title


# ==============================================================================
# 5. Interactive Emotion Perception & Backchanneling
# ==============================================================================

def test_context_based_emotion_detection():
    """Verify 5-dimensional tone perception based on conversation text context."""
    assert detect_emotion_state("今天加班到两点，好累啊终于弄完了")[0] == "exhausted"
    assert detect_emotion_state("快点！线上服务出问题了，紧急修复！")[0] == "urgent"
    assert detect_emotion_state("太棒了！这个方案完美搞定啦，哈哈！")[0] == "excited"
    assert detect_emotion_state("我们来深入分析一下这个架构方案的利弊对比")[0] == "thoughtful"
    assert detect_emotion_state("查一下明天的日程安排")[0] == "calm"


def test_backchanneling_pause_signal_handling(test_env):
    """Verify 600-900ms pause triggers backchanneling response ('嗯')."""
    state = test_env["state"]
    convo = test_env["convo"]
    records_dir = test_env["records_dir"]

    mock_adapter = MockLiveAdapter()
    app = FastAPI()
    app.include_router(
        voice_live_router(
            state,
            convo,
            adapter_factory=lambda v, p, t: mock_adapter,
            records_dir=records_dir,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {test_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready

        # 1. Send pause of 750ms (within 600-900ms backchanneling window)
        ws.send_text(json.dumps({"type": "pause", "duration_ms": 750}))
        bc_msg = json.loads(ws.receive_text())
        assert bc_msg["type"] == "backchannel"
        assert bc_msg["text"] == "嗯"
        assert bc_msg["pause_duration_ms"] == 750

        # 2. Send pause of 300ms (too short < 600ms, should NOT emit backchannel)
        ws.send_text(json.dumps({"type": "pause", "duration_ms": 300}))
        # Ping to check no backchannel is queued
        ws.send_text(json.dumps({"type": "ping"}))
        pong = json.loads(ws.receive_text())
        assert pong["type"] == "pong"


def test_graceful_end_signal_emits_summary_ready(test_env):
    """Verify client sending {"type": "end"} receives {"type": "summary_ready"}."""
    state = test_env["state"]
    convo = test_env["convo"]
    records_dir = test_env["records_dir"]
    session_id = f"test-end-{uuid.uuid4().hex[:8]}"

    mock_adapter = MockLiveAdapter()
    app = FastAPI()
    app.include_router(
        voice_live_router(
            state,
            convo,
            adapter_factory=lambda v, p, t: mock_adapter,
            records_dir=records_dir,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {test_env['token']}"}
    with client.websocket_connect(f"/voice/live?session_id={session_id}", headers=headers) as ws:
        ws.receive_text()  # ready

        ws.send_text(json.dumps({"type": "text", "text": "今天通话结束了，再见"}))

        # Client requests clean hangup
        ws.send_text(json.dumps({"type": "end"}))

        summary_ready = None
        while True:
            msg = ws.receive()
            if msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "summary_ready":
                    summary_ready = ev
                    break

        assert summary_ready is not None
        assert summary_ready["type"] == "summary_ready"
        assert summary_ready["session_id"] == session_id
        assert summary_ready["path"].endswith(".md")
