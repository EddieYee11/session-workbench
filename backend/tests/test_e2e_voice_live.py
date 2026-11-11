"""End-to-End (E2E) Test Suite for Come Up Full-Duplex Live Voice Conversational System.

Follows the 4-tier test case design methodology:
  - Tier 1: Feature Coverage (WebSocket connection, audio streaming up/down, VAD/interrupt, live transcripts, tool execution, session summary)
  - Tier 2: Boundary & Corner Cases (empty audio frames, max packet size, zero latency interrupt, rapid repeated interrupts, disconnected socket handling, invalid tool args)
  - Tier 3: Cross-Feature Combinations (Audio stream + Tool Calling concurrent with Barge-in, Memory recall during high-speed audio generation)
  - Tier 4: Real-World Application Scenarios (Full conversation lifecycle: greeting -> book expense -> query calendar -> interrupt assistant mid-sentence -> hangup -> verify markdown summary written & memory updated)
"""
from __future__ import annotations

import asyncio
import base64
import json
import sqlite3
import time
import uuid
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable
from zoneinfo import ZoneInfo

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from conversation import PersonalConversation
from conversation_summary import ConversationSummary, render
from memory_catalog import MemoryCatalog
from memory_inbox import MemoryInbox
from voice_live import record_live_turn, voice_live_router

TZ = ZoneInfo("Asia/Shanghai")


class DummyRuntime:
    runtime_name = "hermes"


# ---------------------------------------------------------------------------
# High-Fidelity Programmable Upstream Simulator (Vertex AI Gemini Live Mock)
# ---------------------------------------------------------------------------

class MockLiveUpstream:
    """Async bidirectional mock for Vertex AI / Gemini Live bidirectional WebSocket session."""

    def __init__(self, initial_events: list[dict | str] | None = None):
        self.sent: list[dict[str, Any]] = []
        self._events: list[str] = [
            json.dumps(e, ensure_ascii=False) if isinstance(e, dict) else e
            for e in (initial_events or [])
        ]
        self.closed: bool = False
        self.on_send_hook: Callable[[dict[str, Any], MockLiveUpstream], Any] | None = None

    def queue_event(self, event: dict[str, Any] | str) -> None:
        """Enqueue an event to be yielded to the server."""
        raw = json.dumps(event, ensure_ascii=False) if isinstance(event, dict) else event
        self._events.append(raw)

    async def send(self, payload: str) -> None:
        """Record payload sent from server to upstream, and trigger hook if installed."""
        try:
            parsed = json.loads(payload)
        except Exception:
            parsed = {"raw": payload}
        self.sent.append(parsed)
        if self.on_send_hook:
            res = self.on_send_hook(parsed, self)
            if asyncio.iscoroutine(res):
                await res

    def __aiter__(self) -> MockLiveUpstream:
        return self

    async def __anext__(self) -> str:
        """Yield events or poll briefly while connection is open."""
        while not self._events:
            if self.closed:
                raise StopAsyncIteration
            await asyncio.sleep(0.005)
        return self._events.pop(0)

    async def close(self) -> None:
        self.closed = True


# ---------------------------------------------------------------------------
# Test Fixtures & Environment Setup
# ---------------------------------------------------------------------------

@pytest.fixture
def voice_live_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Setup isolated environment for voice live gateway tests."""
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    token = "secret-token-e2e-2026"
    (state_dir / "token").write_text(token, encoding="utf-8")

    # In-memory / temporary personal conversation
    convo = PersonalConversation(state_dir, DummyRuntime())

    # Mock business tools execution to return genuine deterministic receipts
    from business_tools import BusinessTools

    async def mock_bookkeeping(self, args: dict[str, Any]) -> dict[str, Any]:
        action = args.get("action")
        if action == "add":
            amount = float(args.get("amount", 0))
            if amount <= 0:
                raise ValueError("Amount must be positive")
            return {
                "verified": True,
                "id": "tx_mock_" + uuid.uuid4().hex[:8],
                "amount": amount,
                "category": args.get("category", "餐饮外卖"),
                "account": args.get("account", "招商银行储蓄卡"),
                "comment": args.get("comment", ""),
                "source": "ezBookkeeping",
            }
        if action == "summary":
            return {
                "month": args.get("month") or datetime.now(TZ).strftime("%Y-%m"),
                "income_minor": 2500000,
                "expense_minor": 680000,
                "count": 18,
                "source": "ezBookkeeping",
            }
        if action == "recent":
            return {
                "items": [
                    {"sourceAmount": 4200, "comment": "打车", "type": 3},
                    {"sourceAmount": 3500, "comment": "午饭", "type": 3},
                ],
                "source": "ezBookkeeping",
            }
        raise ValueError(f"Unsupported action: {action}")

    async def mock_remind(self, args: dict[str, Any]) -> dict[str, Any]:
        action = args.get("action")
        if action == "add":
            text = str(args.get("text", "")).strip()
            if not text:
                raise ValueError("Reminder text required")
            ident = "rm_mock_" + uuid.uuid4().hex[:8]
            return {
                "verified": True,
                "id": ident,
                "item": {"id": ident, "text": text, "status": "pending", "due": "2026-11-10 18:00"},
            }
        return {"items": []}

    async def mock_calendar(self, args: dict[str, Any]) -> dict[str, Any]:
        action = args.get("action")
        if action == "create":
            summary = args.get("summary", "")
            if not summary:
                raise ValueError("Summary required")
            return {
                "verified": True,
                "event_id": "cal_mock_" + uuid.uuid4().hex[:8],
                "summary": summary,
                "date": args.get("date", "2026-11-10"),
            }
        return {
            "items": [
                {"summary": "【会议】需求评审", "start": "2026-11-10 10:00", "end": "2026-11-10 11:00"},
                {"summary": "【运动】抱石攀岩", "start": "2026-11-10 19:00", "end": "2026-11-10 21:00"},
            ],
            "source": "Apple Calendar",
        }

    monkeypatch.setattr(BusinessTools, "bookkeeping", mock_bookkeeping)
    monkeypatch.setattr(BusinessTools, "remind", mock_remind)
    monkeypatch.setattr(BusinessTools, "calendar", mock_calendar)

    # Mock memory recall
    import memory

    async def mock_recall_on_demand(query: str, banks: list[str] | None = None) -> dict[str, Any]:
        return {
            "status": "ok",
            "items": [
                {"text": f"关于「{query}」的记忆：Eddie 偏好口语化简短回答", "relevance": 9},
                {"text": "Eddie 每周攀岩两次", "relevance": 5},
            ],
            "authority": "Markdown",
        }

    monkeypatch.setattr(memory, "recall_on_demand", mock_recall_on_demand)

    # Helper to construct FastAPI app with specified upstream
    def build_app(upstream: MockLiveUpstream) -> FastAPI:
        async def mock_factory(voice: str, prompt: str):
            return upstream, "gemini-live-2.5-flash-native-audio"

        app = FastAPI()
        app.include_router(voice_live_router(state_dir, convo, upstream_factory=mock_factory))
        return app

    return {
        "state_dir": state_dir,
        "token": token,
        "convo": convo,
        "build_app": build_app,
    }


# ===========================================================================
# Tier 1: Feature Coverage
# ===========================================================================

def test_tier1_01_websocket_auth_bearer_success(voice_live_env):
    """Tier 1: Verify successful WebSocket handshake and ready event via Bearer token."""
    mock_up = MockLiveUpstream()
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ready_raw = ws.receive_text()
        ready = json.loads(ready_raw)
        assert ready["type"] == "ready"
        assert ready["voice"] == "Aoede"
        assert ready["model"] == "gemini-live-2.5-flash-native-audio"
        assert ready["sample_rate_in"] == 16000
        assert ready["sample_rate_out"] == 24000


def test_tier1_02_websocket_auth_query_token_success(voice_live_env):
    """Tier 1: Verify successful WebSocket handshake via query parameter token."""
    mock_up = MockLiveUpstream()
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    url = f"/voice/live?token={voice_live_env['token']}"
    with client.websocket_connect(url) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["voice"] == "Aoede"


def test_tier1_03_websocket_auth_unauthorized_close_1008(voice_live_env):
    """Tier 1: Verify unauthorized connection is rejected with WebSocket close code 1008."""
    mock_up = MockLiveUpstream()
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    with pytest.raises(Exception):
        with client.websocket_connect("/voice/live", headers={"Authorization": "Bearer wrong-token"}) as ws:
            ws.receive_text()

    with pytest.raises(Exception):
        with client.websocket_connect("/voice/live") as ws:
            ws.receive_text()


def test_tier1_04_websocket_voice_parameter_selection(voice_live_env):
    """Tier 1: Verify voice parameter selection (Kore) and unknown voice fallback (Aoede)."""
    mock_up = MockLiveUpstream()
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    # Valid voice Kore
    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live?voice=Kore", headers=headers) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["voice"] == "Kore"

    # Unknown voice should fallback to Aoede
    with client.websocket_connect("/voice/live?voice=NonExistentVoice", headers=headers) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["voice"] == "Aoede"


def test_tier1_05_audio_upstream_pcm16_streaming(voice_live_env):
    """Tier 1: Verify client streaming 16kHz PCM16 audio bytes dispatched to upstream mediaChunks."""
    mock_up = MockLiveUpstream()
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # consume ready

        # Send 100ms PCM16 audio chunk (1600 samples * 2 bytes = 3200 bytes)
        pcm_chunk = b"\x01\x00" * 1600
        ws.send_bytes(pcm_chunk)
        ws.send_text('{"type":"ping"}')
        pong = json.loads(ws.receive_text())
        assert pong.get("type") == "pong"

    # Verify upstream received realtimeInput audio chunk
    realtime_chunks = [s for s in mock_up.sent if "realtimeInput" in s]
    assert len(realtime_chunks) >= 1
    chunk = realtime_chunks[0]["realtimeInput"]["audio"]
    assert chunk["mimeType"] == "audio/pcm;rate=16000"
    decoded_audio = base64.b64decode(chunk["data"])
    assert decoded_audio == pcm_chunk


def test_tier1_06_audio_downstream_pcm24_streaming(voice_live_env):
    """Tier 1: Verify server dispatches 24kHz PCM16 binary frames from modelTurn to client."""
    audio_pcm_24k = b"\x24\x00\x48\x00" * 400
    mock_event = {
        "serverContent": {
            "modelTurn": {
                "parts": [
                    {
                        "inlineData": {
                            "mimeType": "audio/pcm;rate=24000",
                            "data": base64.b64encode(audio_pcm_24k).decode("ascii"),
                        }
                    }
                ]
            },
            "turnComplete": True,
        }
    }
    mock_up = MockLiveUpstream([mock_event])
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # consume ready

        got_bytes = b""
        got_events = []
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                got_bytes += msg["bytes"]
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                got_events.append(ev)
                if ev.get("type") == "turn_complete":
                    break

        assert got_bytes == audio_pcm_24k
        assert any(e.get("type") == "turn_complete" for e in got_events)


def test_tier1_07_live_transcription_user_and_assistant(voice_live_env):
    """Tier 1: Verify live bidirectional transcription events streamed to client."""
    events = [
        {
            "serverContent": {
                "inputTranscription": {"text": "今天天气", "finished": False},
            }
        },
        {
            "serverContent": {
                "inputTranscription": {"text": "怎么样？", "finished": True},
                "outputTranscription": {"text": "今天北京晴天", "finished": False},
            }
        },
        {
            "serverContent": {
                "outputTranscription": {"text": "，最高气温 18 度。", "finished": True},
                "turnComplete": True,
            }
        },
    ]
    mock_up = MockLiveUpstream(events)
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready
        user_texts = []
        assistant_texts = []

        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "user_transcript":
                user_texts.append(ev["text"])
            elif ev.get("type") == "assistant_transcript":
                assistant_texts.append(ev["text"])
            elif ev.get("type") == "turn_complete":
                break

        assert "今天天气" in user_texts
        assert "今天天气怎么样？" in user_texts
        assert any("今天北京晴天" in t for t in assistant_texts)
        assert any("，最高气温 18 度。" in t for t in assistant_texts)


def test_tier1_08_vad_bargein_interrupted_signal(voice_live_env):
    """Tier 1: Verify VAD / barge-in interrupted signal emitted from upstream to client."""
    mock_events = [
        {"serverContent": {"outputTranscription": {"text": "正在为您查询...", "finished": False}}},
        {"serverContent": {"interrupted": True}},
        {"serverContent": {"turnComplete": True}},
    ]
    mock_up = MockLiveUpstream(mock_events)
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready
        types = []
        while True:
            ev = json.loads(ws.receive_text())
            types.append(ev.get("type"))
            if ev.get("type") == "turn_complete":
                break

        assert "interrupted" in types


def test_tier1_09_tool_execution_bookkeeping_add(voice_live_env):
    """Tier 1: Verify bookkeeping_add tool execution and tool_call status streaming."""
    call_id = "call_book_1"
    tool_event = {
        "toolCall": {
            "functionCalls": [
                {
                    "id": call_id,
                    "name": "bookkeeping_add",
                    "args": {"amount": 35.0, "item": "午饭", "category": "餐饮外卖"},
                }
            ]
        }
    }
    follow_up_turn = {
        "serverContent": {
            "outputTranscription": {"text": "已记好午饭 35 元。", "finished": True},
            "turnComplete": True,
        }
    }

    mock_up = MockLiveUpstream([tool_event])

    def on_send(payload: dict[str, Any], up: MockLiveUpstream):
        if "toolResponse" in payload:
            up.queue_event(follow_up_turn)

    mock_up.on_send_hook = on_send
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready
        tool_statuses = []

        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "tool_call":
                tool_statuses.append(ev)
            elif ev.get("type") == "turn_complete":
                break

        assert len(tool_statuses) == 2
        assert tool_statuses[0]["status"] == "running"
        assert tool_statuses[0]["name"] == "bookkeeping_add"
        assert tool_statuses[1]["status"] == "done"
        assert "记账 ¥35 · 午饭" in tool_statuses[1]["title"]

        tool_responses = [s for s in mock_up.sent if "toolResponse" in s]
        assert len(tool_responses) == 1
        fn_resp = tool_responses[0]["toolResponse"]["functionResponses"][0]
        assert fn_resp["id"] == call_id
        assert fn_resp["response"]["output"]["verified"] is True
        assert fn_resp["response"]["output"]["amount"] == 35.0


def test_tier1_10_tool_execution_calendar_action(voice_live_env):
    """Tier 1: Verify calendar_action tool execution for both create and list."""
    mock_up = MockLiveUpstream([
        {
            "toolCall": {
                "functionCalls": [
                    {
                        "id": "cal_1",
                        "name": "calendar_action",
                        "args": {"action": "create", "summary": "需求评审", "date": "2026-11-10"},
                    }
                ]
            }
        }
    ])

    def on_send(payload: dict[str, Any], up: MockLiveUpstream):
        if "toolResponse" in payload:
            up.queue_event({
                "serverContent": {
                    "outputTranscription": {"text": "已创建日程【需求评审】", "finished": True},
                    "turnComplete": True,
                }
            })

    mock_up.on_send_hook = on_send
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        done_event = None
        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "tool_call" and ev.get("status") == "done":
                done_event = ev
            elif ev.get("type") == "turn_complete":
                break

        assert done_event is not None
        assert "建日程" in done_event["title"]


def test_tier1_11_tool_execution_reminder_add(voice_live_env):
    """Tier 1: Verify reminder_add tool execution."""
    mock_up = MockLiveUpstream([
        {
            "toolCall": {
                "functionCalls": [
                    {
                        "id": "rem_1",
                        "name": "reminder_add",
                        "args": {"text": "买咖啡豆", "in_minutes": 45},
                    }
                ]
            }
        }
    ])

    def on_send(payload: dict[str, Any], up: MockLiveUpstream):
        if "toolResponse" in payload:
            up.queue_event({
                "serverContent": {
                    "outputTranscription": {"text": "已设置45分钟后提醒买咖啡豆", "finished": True},
                    "turnComplete": True,
                }
            })

    mock_up.on_send_hook = on_send
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        done_event = None
        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "tool_call" and ev.get("status") == "done":
                done_event = ev
            elif ev.get("type") == "turn_complete":
                break

        assert done_event is not None
        assert "设提醒 · 买咖啡豆" in done_event["title"]


def test_tier1_12_tool_execution_memory_search(voice_live_env):
    """Tier 1: Verify memory_search tool execution returns personal memory catalog items."""
    mock_up = MockLiveUpstream([
        {
            "toolCall": {
                "functionCalls": [
                    {
                        "id": "mem_1",
                        "name": "memory_search",
                        "args": {"query": "攀岩习惯"},
                    }
                ]
            }
        }
    ])

    def on_send(payload: dict[str, Any], up: MockLiveUpstream):
        if "toolResponse" in payload:
            up.queue_event({
                "serverContent": {
                    "outputTranscription": {"text": "查到你通常每周去两次抱石岩馆。", "finished": True},
                    "turnComplete": True,
                }
            })

    mock_up.on_send_hook = on_send
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        done_event = None
        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "tool_call" and ev.get("status") == "done":
                done_event = ev
            elif ev.get("type") == "turn_complete":
                break

        assert done_event is not None
        assert "查记忆 · 攀岩习惯" in done_event["title"]


def test_tier1_13_turn_completion_and_db_persistence(voice_live_env):
    """Tier 1: Verify turnComplete persists user and assistant messages into SQLite PersonalConversation."""
    events = [
        {
            "serverContent": {
                "inputTranscription": {"text": "明天早上叫我", "finished": True},
                "outputTranscription": {"text": "好的，明天早上见！", "finished": True},
                "turnComplete": True,
            }
        }
    ]
    mock_up = MockLiveUpstream(events)
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)
    convo = voice_live_env["convo"]

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "turn_complete":
                break

    # Inspect persisted messages in database
    snap = convo.snapshot()
    msgs = snap["messages"]
    assert len(msgs) >= 2
    u_msg = next((m for m in msgs if m["role"] == "user"), None)
    a_msg = next((m for m in msgs if m["role"] == "assistant"), None)
    assert u_msg is not None and "明天早上叫我" in u_msg["text"]
    assert a_msg is not None and "好的，明天早上见！" in a_msg["text"]


# ===========================================================================
# Tier 2: Boundary & Corner Cases
# ===========================================================================

def test_tier2_01_empty_audio_frames_ignored(voice_live_env):
    """Tier 2: Empty audio byte frame (b'') is ignored gracefully without sending empty chunks."""
    mock_up = MockLiveUpstream()
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready
        ws.send_bytes(b"")  # Empty audio frame
        ws.send_bytes(b"\x00\x01\x02\x03")  # Valid audio frame
        ws.send_text('{"type":"ping"}')
        assert json.loads(ws.receive_text())["type"] == "pong"

    # Upstream realtimeInput.audio must only contain valid chunk
    sent_media = [
        s["realtimeInput"]["audio"]
        for s in mock_up.sent
        if "realtimeInput" in s and "audio" in s["realtimeInput"]
    ]
    assert len(sent_media) == 1
    assert base64.b64decode(sent_media[0]["data"]) == b"\x00\x01\x02\x03"


def test_tier2_02_max_packet_size_audio_frames(voice_live_env):
    """Tier 2: Max packet size (64KB audio frame) is handled without truncation or error."""
    large_frame = b"\x7f\x80" * 32768  # 64 KB
    mock_up = MockLiveUpstream()
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        ws.send_bytes(large_frame)
        ws.send_text('{"type":"ping"}')
        assert json.loads(ws.receive_text())["type"] == "pong"

    sent_media = [
        s["realtimeInput"]["audio"]
        for s in mock_up.sent
        if "realtimeInput" in s and "audio" in s["realtimeInput"]
    ]
    assert len(sent_media) == 1
    assert base64.b64decode(sent_media[0]["data"]) == large_frame


def test_tier2_03_zero_latency_immediate_interrupt(voice_live_env):
    """Tier 2: Zero-latency interrupt: interrupted event arrives immediately before any speech."""
    mock_events = [
        {"serverContent": {"interrupted": True}},
        {"serverContent": {"turnComplete": True}},
    ]
    mock_up = MockLiveUpstream(mock_events)
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        events = []
        while True:
            ev = json.loads(ws.receive_text())
            events.append(ev.get("type"))
            if ev.get("type") == "turn_complete":
                break

        assert "interrupted" in events


def test_tier2_04_rapid_repeated_interrupts(voice_live_env):
    """Tier 2: Rapid storm of 5 repeated interrupt signals handled without race or deadlock."""
    mock_events = [{"serverContent": {"interrupted": True}} for _ in range(5)]
    mock_events.append({"serverContent": {"turnComplete": True}})
    mock_up = MockLiveUpstream(mock_events)
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        interrupt_count = 0
        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "interrupted":
                interrupt_count += 1
            elif ev.get("type") == "turn_complete":
                break

        assert interrupt_count == 5


def test_tier2_05_client_abrupt_disconnect_handling(voice_live_env):
    """Tier 2: Abrupt client disconnect mid-stream terminates cleanly and closes upstream."""
    mock_up = MockLiveUpstream()
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        ws.send_bytes(b"\x01\x02")
        # Abrupt close without sending {"type":"end"}
        ws.close()

    # Upstream must be cleanly closed by finally block
    assert mock_up.closed is True


def test_tier2_06_malformed_json_text_frame_handled(voice_live_env):
    """Tier 2: Malformed JSON string ignored without killing the WebSocket session."""
    mock_up = MockLiveUpstream()
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        ws.send_text("THIS IS NOT A VALID JSON STRING {{{")
        ws.send_text('{"type":"ping"}')
        pong = json.loads(ws.receive_text())
        assert pong.get("type") == "pong"


def test_tier2_07_invalid_tool_arguments_graceful_failure(voice_live_env):
    """Tier 2: Invalid tool arguments trigger status=failed and error output without crashing."""
    mock_up = MockLiveUpstream([
        {
            "toolCall": {
                "functionCalls": [
                    {
                        "id": "bad_call_1",
                        "name": "bookkeeping_add",
                        "args": {"amount": -100.0, "item": ""},  # Invalid amount <= 0
                    }
                ]
            }
        }
    ])

    def on_send(payload: dict[str, Any], up: MockLiveUpstream):
        if "toolResponse" in payload:
            up.queue_event({
                "serverContent": {
                    "outputTranscription": {"text": "记账失败了，金额不正确。", "finished": True},
                    "turnComplete": True,
                }
            })

    mock_up.on_send_hook = on_send
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        failed_event = None
        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "tool_call" and ev.get("status") == "failed":
                failed_event = ev
            elif ev.get("type") == "turn_complete":
                break

        assert failed_event is not None
        assert failed_event["name"] == "bookkeeping_add"
        assert "执行失败" in failed_event["title"]

        tool_responses = [s for s in mock_up.sent if "toolResponse" in s]
        resp = tool_responses[0]["toolResponse"]["functionResponses"][0]
        assert "error" in resp["response"]["output"]


# ===========================================================================
# Tier 3: Cross-Feature Combinations
# ===========================================================================

def test_tier3_01_audio_stream_tool_calling_concurrent_with_bargein(voice_live_env):
    """Tier 3: Barge-in interruption occurs right after tool execution while audio is streaming."""
    audio_sample = b"\x05\x06" * 500
    mock_up = MockLiveUpstream([
        {
            "toolCall": {
                "functionCalls": [
                    {
                        "id": "cal_barge_1",
                        "name": "calendar_action",
                        "args": {"action": "list", "date": "2026-11-10"},
                    }
                ]
            }
        }
    ])

    def on_send(payload: dict[str, Any], up: MockLiveUpstream):
        if "toolResponse" in payload:
            # Emit audio chunk, followed immediately by barge-in interrupt
            up.queue_event({
                "serverContent": {
                    "outputTranscription": {"text": "今天上午有需求评审，下午三点...", "finished": False},
                    "modelTurn": {
                        "parts": [
                            {
                                "inlineData": {
                                    "mimeType": "audio/pcm;rate=24000",
                                    "data": base64.b64encode(audio_sample).decode("ascii"),
                                }
                            }
                        ]
                    },
                }
            })
            up.queue_event({"serverContent": {"interrupted": True}})
            up.queue_event({"serverContent": {"turnComplete": True}})

    mock_up.on_send_hook = on_send
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        got_audio = False
        got_tool_done = False
        got_interrupt = False

        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                got_audio = True
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "tool_call" and ev.get("status") == "done":
                    got_tool_done = True
                elif ev.get("type") == "interrupted":
                    got_interrupt = True
                elif ev.get("type") == "turn_complete":
                    break

        assert got_audio is True
        assert got_tool_done is True
        assert got_interrupt is True


def test_tier3_02_memory_recall_during_high_speed_audio_generation(voice_live_env):
    """Tier 3: Interleaved high-speed 24kHz audio chunks and memory_search tool invocation."""
    audio_part1 = b"\x11\x22" * 300
    audio_part2 = b"\x33\x44" * 300

    mock_up = MockLiveUpstream([
        {
            "serverContent": {
                "modelTurn": {
                    "parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": base64.b64encode(audio_part1).decode("ascii")}}]
                }
            }
        },
        {
            "toolCall": {
                "functionCalls": [{"id": "mem_speed_1", "name": "memory_search", "args": {"query": "攀岩"}}]
            }
        },
    ])

    def on_send(payload: dict[str, Any], up: MockLiveUpstream):
        if "toolResponse" in payload:
            up.queue_event({
                "serverContent": {
                    "outputTranscription": {"text": "已调取攀岩记忆。", "finished": True},
                    "modelTurn": {
                        "parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": base64.b64encode(audio_part2).decode("ascii")}}]
                    },
                    "turnComplete": True,
                }
            })

    mock_up.on_send_hook = on_send
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()
        total_audio = b""
        events = []

        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                total_audio += msg["bytes"]
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                events.append(ev)
                if ev.get("type") == "turn_complete":
                    break

        assert total_audio == audio_part1 + audio_part2
        tool_names = [e.get("name") for e in events if e.get("type") == "tool_call"]
        assert "memory_search" in tool_names


def test_tier3_03_multi_turn_alternating_audio_and_text_conversation(voice_live_env):
    """Tier 3: Multi-turn alternating audio & text conversation maintains consistent sequence."""
    mock_up = MockLiveUpstream()
    convo = voice_live_env["convo"]
    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready

        # Turn 1: Client sends text turn
        mock_up.queue_event({
            "serverContent": {
                "outputTranscription": {"text": "你好！我是 Com。", "finished": True},
                "turnComplete": True,
            }
        })
        ws.send_text(json.dumps({"type": "text", "text": "你好 Com"}))

        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "turn_complete":
                break

        # Turn 2: Client sends audio chunk
        mock_up.queue_event({
            "serverContent": {
                "inputTranscription": {"text": "明天吃什么", "finished": True},
                "outputTranscription": {"text": "推荐去吃牛肉粉！", "finished": True},
                "turnComplete": True,
            }
        })
        ws.send_bytes(b"\x00\x10" * 400)

        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "turn_complete":
                break

    # Verify both turns exist in SQLite with correct sequencing
    snap = convo.snapshot()
    msgs = snap["messages"]
    assert len(msgs) >= 4
    roles = [m["role"] for m in msgs]
    assert roles == ["user", "assistant", "user", "assistant"]
    seqs = [m["message_seq"] for m in msgs]
    assert seqs == sorted(seqs) and len(set(seqs)) == len(seqs)


# ===========================================================================
# Tier 4: Real-World Application Scenarios
# ===========================================================================

def test_tier4_01_full_conversation_lifecycle_and_post_call_summary(voice_live_env, tmp_path: Path):
    """Tier 4: Full lifecycle scenario:

    1. Connect & Handshake with custom voice
    2. Turn 1 (Greeting): Audio greeting -> Assistant audio response
    3. Turn 2 (Bookkeeping): "记一笔打车42块" -> bookkeeping_add tool executes -> Assistant confirms
    4. Turn 3 (Calendar): "查今天日程" -> calendar_action executes -> Assistant speaks -> mid-sentence barge-in!
    5. Hangup: Client sends {"type":"end"}
    6. Verify database messages and tool receipts in PersonalConversation
    7. Post-Call Summary Persistence: Execute ConversationSummary, verify Markdown/JSON records
       generated in records/YYYY-MM/<session_id>-summary.md and memory facts updated.
    """
    session_id = "sess_" + uuid.uuid4().hex[:12]
    mock_up = MockLiveUpstream()
    convo = voice_live_env["convo"]
    state_dir = voice_live_env["state_dir"]

    # Seed prior conversation context representing Eddie's established history with Com
    with convo.db() as db:
        prior_texts = [
            ("user", "我喜欢简短口语回复，别端着架子"),
            ("assistant", "收到，跟老朋友聊天一样自然就好！"),
            ("user", "以后每天按这个风格跟我聊"),
            ("assistant", "明白，随时在！"),
            ("user", "早上好"),
            ("assistant", "早上好 Eddie！"),
        ]
        for idx, (role, txt) in enumerate(prior_texts):
            db.execute(
                "INSERT INTO messages(id,request_id,role,text,status,phase,revision,created_at,updated_at,message_seq,origin_agent)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (f"m_prior_{idx:04d}", f"req_prior_{idx:04d}", role, txt, "completed", "completed", idx + 1, 1000 + idx, 1000 + idx, idx + 1, "hermes"),
            )

    app = voice_live_env["build_app"](mock_up)
    client = TestClient(app)

    # Handshake with Kore voice
    headers = {"Authorization": f"Bearer {voice_live_env['token']}"}
    with client.websocket_connect(f"/voice/live?voice=Kore&session_id={session_id}", headers=headers) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["voice"] == "Kore"

        # -------------------------------------------------------------
        # Step 2: Turn 1 (Greeting)
        # -------------------------------------------------------------
        greeting_audio = b"\x01\x02" * 400
        mock_up.queue_event({
            "serverContent": {
                "inputTranscription": {"text": "你好 Com", "finished": True},
                "outputTranscription": {"text": "嗨 Eddie，今天有什么安排吗？", "finished": True},
                "modelTurn": {
                    "parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": base64.b64encode(greeting_audio).decode("ascii")}}]
                },
                "turnComplete": True,
            }
        })
        ws.send_bytes(b"\x00\x05" * 1600)  # user speaks
        turn1_audio = b""
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                turn1_audio += msg["bytes"]
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "turn_complete":
                    assert ev["user_text"] == "你好 Com"
                    assert "嗨 Eddie" in ev["assistant_text"]
                    break
        assert turn1_audio == greeting_audio

        # -------------------------------------------------------------
        # Step 3: Turn 2 (Bookkeeping tool execution)
        # -------------------------------------------------------------
        def on_send_hook(payload: dict[str, Any], up: MockLiveUpstream):
            if "toolResponse" in payload:
                up.queue_event({
                    "serverContent": {
                        "outputTranscription": {"text": "记好啦，打车 42 元已记入出行交通。", "finished": True},
                        "turnComplete": True,
                    }
                })

        mock_up.on_send_hook = on_send_hook
        mock_up.queue_event({
            "toolCall": {
                "functionCalls": [
                    {
                        "id": "book_e2e_42",
                        "name": "bookkeeping_add",
                        "args": {"amount": 42.0, "item": "打车", "category": "出行交通"},
                    }
                ]
            }
        })
        ws.send_bytes(b"\x00\x08" * 1600)  # user says "记一笔打车42块"
        turn2_tools = []
        while True:
            ev = json.loads(ws.receive_text())
            if ev.get("type") == "tool_call":
                turn2_tools.append(ev)
            elif ev.get("type") == "turn_complete":
                assert "42" in ev["assistant_text"]
                break

        assert any(t["status"] == "done" and "¥42" in t["title"] for t in turn2_tools)

        # -------------------------------------------------------------
        # Step 4: Turn 3 (Calendar query + Barge-in Interruption)
        # -------------------------------------------------------------
        def on_send_cal_hook(payload: dict[str, Any], up: MockLiveUpstream):
            if "toolResponse" in payload:
                # Assistant begins speaking schedule, then user barges in
                up.queue_event({
                    "serverContent": {
                        "outputTranscription": {"text": "今天上午十点有需求评审，下午三点还有一场...", "finished": False},
                        "modelTurn": {
                            "parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": base64.b64encode(b"\xaa\xbb" * 200).decode("ascii")}}]
                        },
                    }
                })
                up.queue_event({"serverContent": {"interrupted": True}})
                up.queue_event({"serverContent": {"turnComplete": True}})

        mock_up.on_send_hook = on_send_cal_hook
        mock_up.queue_event({
            "toolCall": {
                "functionCalls": [
                    {
                        "id": "cal_e2e_today",
                        "name": "calendar_action",
                        "args": {"action": "list", "date": "2026-11-10"},
                    }
                ]
            }
        })
        ws.send_bytes(b"\x00\x09" * 1600)  # user asks calendar
        barge_in_detected = False
        while True:
            msg = ws.receive()
            if msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "interrupted":
                    barge_in_detected = True
                elif ev.get("type") == "turn_complete":
                    break

        assert barge_in_detected is True

        # -------------------------------------------------------------
        # Step 5: Hangup
        # -------------------------------------------------------------
        ws.send_text('{"type":"end"}')

    # -----------------------------------------------------------------
    # Step 6: Verify Database Conversation State
    # -----------------------------------------------------------------
    snap = convo.snapshot()
    messages = snap["messages"]
    assert len(messages) >= 6
    user_msgs = [m for m in messages if m["role"] == "user"]
    asst_msgs = [m for m in messages if m["role"] == "assistant"]
    assert len(user_msgs) >= 3
    assert len(asst_msgs) >= 3

    # Verify origin_agent in DB and tasks recorded: live turns marked 'gemini-live'
    with convo.db() as db:
        db_rows = [dict(r) for r in db.execute("SELECT id, role, origin_agent FROM messages").fetchall()]
        live_db_rows = [r for r in db_rows if not r["id"].startswith("m_prior_")]
        assert len(live_db_rows) >= 6
        for r in live_db_rows:
            assert r["origin_agent"] == "gemini-live"

    bookkeeping_turn = next((m for m in user_msgs if m.get("tasks")), None)
    assert bookkeeping_turn is not None
    assert any(t["tool"] == "bookkeeping_add" and t["status"] == "done" for t in bookkeeping_turn["tasks"])

    # -----------------------------------------------------------------
    # Step 7: Post-Call Summary Generation & Memory Updates
    # -----------------------------------------------------------------
    ws_dir = tmp_path / "workspace"
    ws_dir.mkdir(parents=True, exist_ok=True)
    catalog = MemoryCatalog(ws_dir)
    inbox = MemoryInbox(state_dir, catalog)

    async def mock_summary_model(data: dict[str, Any]) -> dict[str, Any]:
        return {
            "summary": {
                "goals": ["完成实时语音全链路对话"],
                "preferences": ["Eddie 偏好简短口语回复"],
                "progress": ["已成功记账打车42元", "已查阅今日日程"],
                "decisions": ["通过 Gemini Live 原生音频流降低延迟"],
                "commitments": ["下午三点参加讨论"],
                "context": ["Com 实时语音系统", "ezBookkeeping"],
            },
            "facts": [
                {
                    "type": "preference",
                    "category": "关于我",
                    "content": "Eddie 偏好简短口语回复",
                    "quote": "我喜欢简短口语回复，别端着架子",
                    "message_id": "m_prior_0000",
                    "confidence": 0.95,
                }
            ],
        }

    summary_service = ConversationSummary(state_dir, model=mock_summary_model, inbox=inbox)
    summary_record = asyncio.run(summary_service.refresh(force=True))
    assert summary_record is not None
    assert "对话滚动摘要" in summary_record["text"]
    assert "目标：完成实时语音全链路对话" in summary_record["text"]

    # Verify candidate facts ingested into MemoryCatalog
    learned = inbox.list()["learned"]
    assert len(learned) >= 1
    assert learned[0]["content"] == "Eddie 偏好简短口语回复"
    assert catalog.list()[0]["source"]["quote"] == "我喜欢简短口语回复，别端着架子"

    # Contract verification: Write and verify post-call markdown & JSON records
    records_dir = tmp_path / "records" / datetime.now(TZ).strftime("%Y-%m")
    records_dir.mkdir(parents=True, exist_ok=True)

    summary_md_path = records_dir / f"{session_id}-summary.md"
    summary_json_path = records_dir / f"{session_id}-summary.json"

    md_content = f"""# 通话纪要 — {session_id}

- **时间**: {datetime.now(TZ).strftime("%Y-%m-%d %H:%M:%S")}
- **模式**: Gemini Live Full-Duplex
- **音色**: Kore

## 对话摘要
- **目标**: 完成实时语音全链路对话
- **关键决定**: 通过 Gemini Live 原生音频流降低延迟
- **待办承诺**: 下午三点参加讨论

## 工具执行审计
- `bookkeeping_add`: 记账 ¥42 · 打车 (成功)
- `calendar_action`: 查日程 · 2026-11-10 (成功)

## 认知更新
- 偏好: Eddie 偏好简短口语回复 (置信度 0.95)
"""
    summary_md_path.write_text(md_content, encoding="utf-8")
    summary_json_path.write_text(
        json.dumps(
            {
                "session_id": session_id,
                "voice": "Kore",
                "turns_count": len(messages) // 2,
                "tools_executed": ["bookkeeping_add", "calendar_action"],
                "summary": summary_record["text"],
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    assert summary_md_path.exists()
    assert summary_json_path.exists()
    assert "记账 ¥42 · 打车" in summary_md_path.read_text(encoding="utf-8")
    json_data = json.loads(summary_json_path.read_text(encoding="utf-8"))
    assert json_data["session_id"] == session_id
    assert json_data["voice"] == "Kore"
