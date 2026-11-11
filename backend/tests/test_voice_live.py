import base64
import json
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

from conversation import PersonalConversation
from voice_live import (
    GeminiLiveAdapter,
    LiveUpstreamAdapter,
    MockLiveAdapter,
    OpenAIRealtimeAdapter,
    record_live_turn,
    voice_live_router,
)


class DummyRuntime:
    runtime_name = "hermes"


class FakeUpstream:
    def __init__(self):
        self.sent = []
        self._events = [
            json.dumps(
                {
                    "serverContent": {
                        "inputTranscription": {"text": "嗨，今天怎么样", "finished": True},
                        "outputTranscription": {"text": "挺好的，随时找我聊！", "finished": True},
                        "modelTurn": {
                            "parts": [
                                {
                                    "inlineData": {
                                        "mimeType": "audio/pcm;rate=24000",
                                        "data": base64.b64encode(b"\x01\x02\x03\x04").decode("ascii"),
                                    }
                                }
                            ]
                        },
                        "turnComplete": True,
                    }
                },
                ensure_ascii=False,
            )
        ]

    async def send(self, payload: str):
        self.sent.append(json.loads(payload))

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self._events:
            raise StopAsyncIteration
        return self._events.pop(0)

    async def close(self):
        pass


def test_voice_live_auth_and_duplex_turn(tmp_path: Path):
    state = tmp_path / "state"
    state.mkdir()
    (state / "token").write_text("secret-token-123")
    convo = PersonalConversation(state, DummyRuntime())
    fake_up = FakeUpstream()

    async def fake_factory(voice: str, prompt: str):
        return fake_up, "gemini-live-2.5-flash-native-audio"

    app = FastAPI()
    app.include_router(voice_live_router(state, convo, upstream_factory=fake_factory))
    client = TestClient(app)

    # Unauthorized should close with 1008
    try:
        with client.websocket_connect("/voice/live") as ws:
            ws.receive_text()
            assert False, "Expected unauthorized websocket to close"
    except Exception:
        pass

    # Authorized via Bearer header
    with client.websocket_connect("/voice/live", headers={"Authorization": "Bearer secret-token-123"}) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["voice"] == "Aoede"

        ws.send_bytes(b"\x00\x00\x01\x00")
        events = []
        got_audio = b""
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                got_audio += msg["bytes"]
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                events.append(ev)
                if ev.get("type") == "turn_complete":
                    break

        assert got_audio == b"\x01\x02\x03\x04"
        types = [e["type"] for e in events]
        assert "user_transcript" in types
        assert "assistant_transcript" in types
        assert "turn_complete" in types

    snap = convo.snapshot()
    texts = [m["text"] for m in snap["messages"]]
    assert "嗨，今天怎么样" in texts
    assert "挺好的，随时找我聊！" in texts


def test_record_live_turn_with_tools(tmp_path: Path):
    state = tmp_path / "state"
    state.mkdir()
    convo = PersonalConversation(state, DummyRuntime())
    res = record_live_turn(
        convo,
        "帮我记一笔午饭35",
        "记好啦，午饭 35 元。",
        [{"name": "bookkeeping_add", "title": "记账 ¥35 · 午饭", "ok": True}],
    )
    assert res and "user_message_id" in res
    msgs = convo.snapshot()["messages"]
    assert len(msgs) == 2
    assert msgs[0]["role"] == "user"
    assert msgs[0]["tasks"][0]["title"] == "记账 ¥35 · 午饭"
    assert msgs[1]["role"] == "assistant"


def test_upstream_adapter_switching(tmp_path: Path):
    """Test switching between GeminiLiveAdapter, MockLiveAdapter, and custom adapters."""
    state = tmp_path / "state"
    state.mkdir()
    (state / "token").write_text("secret-token-switch")
    convo = PersonalConversation(state, DummyRuntime())

    # 1. Connect via ?adapter=mock
    app = FastAPI()
    app.include_router(voice_live_router(state, convo))
    client = TestClient(app)

    with client.websocket_connect("/voice/live?adapter=mock", headers={"Authorization": "Bearer secret-token-switch"}) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["model"] == "mock-live-2.5-flash"
        assert ready["epoch"] == 1

    # 2. Connect using custom adapter_factory
    async def custom_factory(voice: str, prompt: str, tools: list):
        return MockLiveAdapter(default_model="custom-voice-engine-v2")

    app2 = FastAPI()
    app2.include_router(voice_live_router(state, convo, adapter_factory=custom_factory))
    client2 = TestClient(app2)

    with client2.websocket_connect("/voice/live", headers={"Authorization": "Bearer secret-token-switch"}) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["model"] == "custom-voice-engine-v2"
        assert ready["epoch"] == 1

    # 3. Connect via ?adapter=openai without API key -> returns error
    with client.websocket_connect("/voice/live?adapter=openai", headers={"Authorization": "Bearer secret-token-switch"}) as ws:
        msg = json.loads(ws.receive_text())
        assert msg["type"] == "error"
        assert "OPENAI_API_KEY 未配置" in msg["message"]


def test_mock_adapter_full_duplex_session(tmp_path: Path):
    """Test MockLiveAdapter full-duplex session handshake, streaming audio packets, and transcript delivery."""
    state = tmp_path / "state"
    state.mkdir()
    (state / "token").write_text("token-duplex-test")
    convo = PersonalConversation(state, DummyRuntime())

    app = FastAPI()
    app.include_router(voice_live_router(state, convo, default_adapter="mock"))
    client = TestClient(app)

    with client.websocket_connect("/voice/live", headers={"Authorization": "Bearer token-duplex-test"}) as ws:
        # Handshake verification
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["voice"] == "Aoede"
        assert ready["sample_rate_in"] == 16000
        assert ready["sample_rate_out"] == 24000
        assert ready["epoch"] == 1

        # Ping-Pong keepalive verification
        ws.send_text(json.dumps({"type": "ping"}))
        pong = json.loads(ws.receive_text())
        assert pong["type"] == "pong"
        assert pong["epoch"] == 1

        # Send 16kHz PCM audio chunk (100ms / 3200 bytes)
        ws.send_bytes(b"\x00\x00" * 1600)

        # Receive full-duplex stream
        got_audio = b""
        events = []
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                got_audio += msg["bytes"]
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                events.append(ev)
                if ev.get("type") == "turn_complete":
                    break

        assert len(got_audio) > 0
        types = [e["type"] for e in events]
        assert "transcript" in types
        assert "user_transcript" in types
        assert "assistant_transcript" in types
        assert "emotion" in types
        assert "turn_complete" in types

        # Validate emotion envelope
        emotion_ev = next(e for e in events if e["type"] == "emotion")
        assert emotion_ev["state"] in ("calm", "happy", "concerned", "excited")
        assert 0.0 <= emotion_ev["energy"] <= 1.0
        assert emotion_ev["epoch"] == 1

        # Validate user & assistant transcript envelopes
        user_tr = next(e for e in events if e["type"] == "transcript" and e.get("role") == "user")
        assert user_tr["text"] == "嗨，今天怎么样"
        assert user_tr["epoch"] == 1

        asst_tr = next(e for e in events if e["type"] == "transcript" and e.get("role") == "assistant")
        assert asst_tr["text"] == "挺好的，随时找我聊！"
        assert asst_tr["epoch"] == 1

        # Validate turn completion
        tc = next(e for e in events if e["type"] == "turn_complete")
        assert tc["epoch"] == 1

    # Verify message persistence
    snap = convo.snapshot()
    texts = [m["text"] for m in snap["messages"]]
    assert "嗨，今天怎么样" in texts
    assert "挺好的，随时找我聊！" in texts


def test_interruption_and_epoch_fencing(tmp_path: Path):
    """Test Generation Epoch Fencing: advancing epoch_id on interrupt and dropping older epoch frames."""
    state = tmp_path / "state"
    state.mkdir()
    (state / "token").write_text("token-epoch-fence")
    convo = PersonalConversation(state, DummyRuntime())

    mock = MockLiveAdapter(auto_respond=False)

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(voice_live_router(state, convo, adapter_factory=adapter_factory))
    client = TestClient(app)

    with client.websocket_connect("/voice/live", headers={"Authorization": "Bearer token-epoch-fence"}) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["epoch"] == 1

        # Upstream generates initial audio frame for Epoch 1
        mock.enqueue_event({"type": "audio", "data": b"AUDIO_FRAME_EPOCH_1", "epoch": 1})
        msg1 = ws.receive()
        assert msg1.get("bytes") == b"AUDIO_FRAME_EPOCH_1"

        # Client triggers barge-in interruption!
        ws.send_text(json.dumps({"type": "interrupt"}))
        interrupt_ack = json.loads(ws.receive_text())
        assert interrupt_ack["type"] == "interrupted"
        assert interrupt_ack["epoch"] == 2
        assert interrupt_ack["source"] == "client"
        assert mock.interrupted is True
        assert mock.interrupt_count == 1

        # Upstream now emits:
        # 1. A stale in-flight audio packet tagged with older Epoch 1
        # 2. A fresh audio packet tagged with new active Epoch 2
        # 3. A turn_complete tagged with Epoch 2
        mock.enqueue_event({"type": "audio", "data": b"STALE_LEFTOVER_FRAME_EPOCH_1", "epoch": 1})
        mock.enqueue_event({"type": "audio", "data": b"FRESH_FRAME_EPOCH_2", "epoch": 2})
        mock.enqueue_event({"type": "turn_complete", "epoch": 2})

        received_bytes = []
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                received_bytes.append(msg["bytes"])
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "turn_complete":
                    break

        # Verification: stale Epoch 1 audio was dropped by the epoch fence!
        assert b"STALE_LEFTOVER_FRAME_EPOCH_1" not in received_bytes
        # Verification: fresh Epoch 2 audio was successfully delivered!
        assert b"FRESH_FRAME_EPOCH_2" in received_bytes

        # Server-side VAD interrupt test:
        mock.enqueue_event({"type": "interrupted"})
        vad_interrupt = json.loads(ws.receive_text())
        assert vad_interrupt["type"] == "interrupted"
        assert vad_interrupt["epoch"] == 3
        assert vad_interrupt["source"] == "server"


def test_untagged_audio_suppression_on_interruption(tmp_path: Path):
    """Test that untagged audio packets from real-world adapters (no epoch key)
    are suppressed upon interruption and zero stale bytes leak to client."""
    state = tmp_path / "state"
    state.mkdir()
    (state / "token").write_text("token-untagged-fence")
    convo = PersonalConversation(state, DummyRuntime())

    mock = MockLiveAdapter(auto_respond=False)

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(voice_live_router(state, convo, adapter_factory=adapter_factory))
    client = TestClient(app)

    with client.websocket_connect("/voice/live", headers={"Authorization": "Bearer token-untagged-fence"}) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["epoch"] == 1

        # Deliver audio in epoch 1
        mock.enqueue_event({"type": "audio", "data": b"EPOCH1_AUDIO"})
        frame1 = ws.receive_bytes()
        assert frame1 == b"EPOCH1_AUDIO"

        # Client interrupts
        ws.send_text(json.dumps({"type": "interrupt"}))
        ack = json.loads(ws.receive_text())
        assert ack["type"] == "interrupted"
        assert ack["epoch"] == 2

        # In-flight untagged audio packet arrives from upstream before turn_complete
        mock.enqueue_event({"type": "audio", "data": b"UNTAGGED_STALE_FRAME"})
        mock.enqueue_event({"type": "turn_complete"})

        received_bytes = []
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                received_bytes.append(msg["bytes"])
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "turn_complete":
                    break

        assert b"UNTAGGED_STALE_FRAME" not in received_bytes
        assert len(received_bytes) == 0

        # After turn_complete, new untagged audio for epoch 2 is delivered
        mock.enqueue_event({"type": "audio", "data": b"EPOCH2_FRESH_AUDIO"})
        mock.enqueue_event({"type": "turn_complete"})

        fresh_bytes = []
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                fresh_bytes.append(msg["bytes"])
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "turn_complete":
                    break

        assert b"EPOCH2_FRESH_AUDIO" in fresh_bytes


def test_live_tool_roundtrip(tmp_path: Path, monkeypatch):
    """Test Personal Agent tool calling round-trip through the gateway."""
    state = tmp_path / "state"
    state.mkdir()
    (state / "token").write_text("token-tool-roundtrip")
    convo = PersonalConversation(state, DummyRuntime())

    # Intercept execute_live_tool to test gateway handling without external dependencies
    async def fake_execute_live_tool(name: str, args: dict, **kwargs):
        assert name == "bookkeeping_add"
        assert args.get("amount") == 35.0
        return f"记账 ¥35 · {args.get('item')}", {"ok": True, "id": "test-tx-999"}

    monkeypatch.setattr("voice_live.execute_live_tool", fake_execute_live_tool)

    app = FastAPI()
    app.include_router(voice_live_router(state, convo, default_adapter="mock"))
    client = TestClient(app)

    with client.websocket_connect("/voice/live", headers={"Authorization": "Bearer token-tool-roundtrip"}) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"

        # Client sends request triggering tool call
        ws.send_text(json.dumps({"type": "text", "text": "帮我记一笔午饭35"}))

        events = []
        got_audio = b""
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                got_audio += msg["bytes"]
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                events.append(ev)
                if ev.get("type") == "turn_complete":
                    break

        tool_events = [e for e in events if e.get("type") == "tool_call"]
        assert len(tool_events) >= 2
        running_ev = tool_events[0]
        assert running_ev["name"] == "bookkeeping_add"
        assert running_ev["status"] == "running"
        assert running_ev["state"] == "executing"

        done_ev = tool_events[1]
        assert done_ev["name"] == "bookkeeping_add"
        assert done_ev["status"] == "done"
        assert done_ev["state"] == "completed"
        assert "记账 ¥35 · 午饭" in done_ev["title"]

        assert len(got_audio) > 0
        asst_tr = next(e for e in events if e["type"] == "transcript" and e.get("role") == "assistant")
        assert "已为你完成bookkeeping_add操作" in asst_tr["text"]

    # Verify turn is persisted in conversation with task receipts
    snap = convo.snapshot()
    user_msg = snap["messages"][0]
    assert user_msg["role"] == "user"
    assert user_msg["tasks"][0]["tool"] == "bookkeeping_add"
    assert "记账 ¥35 · 午饭" in user_msg["tasks"][0]["title"]
    assert user_msg["tasks"][0]["status"] == "done"


def test_go_away_silent_reconnect_with_mock_adapter(tmp_path: Path):
    """Test silent upstream reconnection on goAway using saved sessionResumption handle."""
    state = tmp_path / "state"
    state.mkdir()
    (state / "token").write_text("token-goaway-test")
    convo = PersonalConversation(state, DummyRuntime())

    mock = MockLiveAdapter(auto_respond=False)

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(voice_live_router(state, convo, adapter_factory=adapter_factory))
    client = TestClient(app)

    with client.websocket_connect(
        "/voice/live?session=sess-goaway-1",
        headers={"Authorization": "Bearer token-goaway-test"},
    ) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["session_id"] == "sess-goaway-1"
        assert len(mock.connect_calls) == 1
        assert mock.connect_calls[0]["resumption_handle"] is None

        # Upstream sends sessionResumptionUpdate, then goAway, then post-reconnect events
        mock.enqueue_events([
            {"sessionResumptionUpdate": {"resumable": True, "newHandle": "handle-goaway-999"}},
            {"goAway": {"timeLeft": "5s"}},
            {"type": "transcript", "role": "user", "text": "继续刚才的话题", "finished": True},
            {"type": "transcript", "role": "assistant", "text": "嗯，我还在听。", "finished": True},
            {"type": "audio", "data": b"\x10\x20\x30\x40"},
            {"type": "turn_complete"},
        ])

        events = []
        got_audio = b""
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                got_audio += msg["bytes"]
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                events.append(ev)
                if ev.get("type") == "turn_complete":
                    break

        assert not any(e.get("type") == "error" for e in events)
        assert got_audio == b"\x10\x20\x30\x40"
        assert len(mock.connect_calls) == 2
        assert mock.connect_calls[1]["resumption_handle"] == "handle-goaway-999"
        assert mock.connect_calls[1]["setup"]["setup"]["sessionResumption"] == {"handle": "handle-goaway-999"}


def test_setup_field_fallback_retry_with_mock_adapter(tmp_path: Path):
    """Test target setup fallback retry when enableAffectiveDialog/proactivity are rejected."""
    state = tmp_path / "state"
    state.mkdir()
    (state / "token").write_text("token-setup-fallback")
    convo = PersonalConversation(state, DummyRuntime())

    native_target = (
        {
            "account": "test@example.com",
            "project": "test-proj",
            "location": "us-central1",
            "model": "gemini-live-2.5-flash-native-audio",
            "affective": True,
            "proactive": True,
        },
    )
    mock = MockLiveAdapter(
        auto_respond=False,
        reject_advanced_setup=True,
        targets=native_target,
    )

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(voice_live_router(state, convo, adapter_factory=adapter_factory))
    client = TestClient(app)

    with client.websocket_connect(
        "/voice/live",
        headers={"Authorization": "Bearer token-setup-fallback"},
    ) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert len(mock.setup_attempts) == 2

        first_setup = mock.setup_attempts[0]["setup"]
        assert first_setup["generationConfig"].get("enableAffectiveDialog") is True
        assert first_setup.get("proactivity") == {"proactiveAudio": True}

        second_setup = mock.setup_attempts[1]["setup"]
        assert "enableAffectiveDialog" not in second_setup["generationConfig"]
        assert "proactivity" not in second_setup
        assert second_setup["realtimeInputConfig"]["automaticActivityDetection"]["silenceDurationMs"] == 650
        assert second_setup["contextWindowCompression"] == {"slidingWindow": {}}


def test_resume_skips_opening_greeting_with_mock_adapter(tmp_path: Path):
    """Test new session sends hidden opening turn while resume=1 uses saved handle and skips opening."""
    state = tmp_path / "state"
    state.mkdir()
    (state / "token").write_text("token-resume-opening")
    convo = PersonalConversation(state, DummyRuntime())

    mock1 = MockLiveAdapter(auto_respond=False, auto_respond_opening=True)

    async def factory1(voice: str, prompt: str, tools: list):
        return mock1

    app1 = FastAPI()
    app1.include_router(voice_live_router(state, convo, adapter_factory=factory1))
    client1 = TestClient(app1)

    with client1.websocket_connect(
        "/voice/live?session=sess-resume-01",
        headers={"Authorization": "Bearer token-resume-opening"},
    ) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"
        assert ready["session_id"] == "sess-resume-01"

        mock1.enqueue_event({"sessionResumptionUpdate": {"resumable": True, "newHandle": "hdl-resume-01"}})

        events = []
        while True:
            msg = ws.receive()
            if msg.get("text"):
                ev = json.loads(msg["text"])
                events.append(ev)
                if ev.get("type") == "turn_complete":
                    break

        assert len(mock1.opening_prompts) == 1
        assert not any(e.get("type") == "user_transcript" for e in events)
        assert convo.snapshot()["messages"] == []

    # Reconnect with resume=1
    mock2 = MockLiveAdapter(auto_respond=False, auto_respond_opening=True)

    async def factory2(voice: str, prompt: str, tools: list):
        return mock2

    app2 = FastAPI()
    app2.include_router(voice_live_router(state, convo, adapter_factory=factory2))
    client2 = TestClient(app2)

    with client2.websocket_connect(
        "/voice/live?session=sess-resume-01&resume=1",
        headers={"Authorization": "Bearer token-resume-opening"},
    ) as ws:
        ready2 = json.loads(ws.receive_text())
        assert ready2["type"] == "ready"
        assert ready2["session_id"] == "sess-resume-01"
        assert len(mock2.opening_prompts) == 0
        assert mock2.connect_calls[-1]["resumption_handle"] == "hdl-resume-01"


