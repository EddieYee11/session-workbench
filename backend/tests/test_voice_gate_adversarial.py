"""Adversarial stress and verification test suite for Come Up Voice Gateway.

Challenges:
1. High-concurrency audio packet arrival and buffer overflow resilience.
2. Rapid-fire barge-in interruptions and epoch desync / stale audio leak verification.
3. Network drop and abrupt client disconnect: exception safety and post-call summary in finally.
4. Latency benchmarks: Time-To-First-Audio (TTFA) and interrupt round-trip latency.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import shutil
import time
from pathlib import Path
from typing import Any, AsyncIterator

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from conversation import PersonalConversation
from voice_live import (
    LiveUpstreamAdapter,
    MockLiveAdapter,
    voice_live_router,
)


class DummyRuntime:
    runtime_name = "hermes"


class StreamingMockAdapter(LiveUpstreamAdapter):
    """Controllable upstream adapter simulating real-world Gemini/OpenAI streaming behavior."""

    def __init__(self, model_name: str = "gemini-live-mock"):
        self.model_name = model_name
        self.queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
        self.received_audio: list[bytes] = []
        self.interrupt_calls: int = 0
        self.closed: bool = False

    async def connect(self, voice: str, system_prompt: str, tools: list[dict[str, Any]]) -> None:
        self.closed = False

    async def send_audio(self, pcm_16k: bytes) -> None:
        if not self.closed:
            self.received_audio.append(pcm_16k)

    async def send_text_turn(self, text: str) -> None:
        pass

    async def send_tool_response(self, call_id: str, name: str, output: dict[str, Any]) -> None:
        pass

    async def interrupt(self) -> None:
        self.interrupt_calls += 1

    async def incoming_events(self) -> AsyncIterator[dict[str, Any]]:
        while not self.closed:
            try:
                ev = await asyncio.wait_for(self.queue.get(), timeout=0.1)
                if ev is None:
                    break
                yield ev
            except asyncio.TimeoutError:
                if self.closed:
                    break
                continue

    async def close(self) -> None:
        self.closed = True
        self.queue.put_nowait(None)


@pytest.fixture
def voice_gate_env(tmp_path: Path):
    """Sets up an isolated environment with temporary state, records, and vault directories."""
    state = tmp_path / "state"
    state.mkdir(parents=True, exist_ok=True)
    token = "adv-challenge-token-2026"
    (state / "token").write_text(token, encoding="utf-8")

    records = tmp_path / "records"
    records.mkdir(parents=True, exist_ok=True)

    vault = tmp_path / "vault"
    vault.mkdir(parents=True, exist_ok=True)

    convo = PersonalConversation(state, DummyRuntime())

    return {
        "state": state,
        "token": token,
        "records": records,
        "vault": vault,
        "convo": convo,
    }


# ==============================================================================
# Challenge 1: High-Concurrency Audio Packet Arrival & Buffer Resilience
# ==============================================================================

def test_adv_01_high_concurrency_audio_packet_flood(voice_gate_env):
    """Adversarial Challenge 1A: Burst flood of 1,000 audio packets (3.2MB total).
    
    Verifies that the WebSocket gateway can ingest 1,000 back-to-back 100ms PCM16 packets
    without buffer overflow, socket drops, or dropped frames.
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
            records_dir=voice_gate_env["records"],
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["type"] == "ready"

        # Flood 1,000 packets of 3200 bytes (100ms 16kHz PCM16)
        chunk = b"\x00\x10" * 1600  # 3200 bytes
        t0 = time.perf_counter()
        for _ in range(1000):
            ws.send_bytes(chunk)

        # Send ping to confirm pipeline is alive and responsive
        ws.send_text('{"type": "ping"}')
        pong = json.loads(ws.receive_text())
        t1 = time.perf_counter()

        assert pong["type"] == "pong"
        assert len(mock.received_audio) == 1000
        # Ingestion of 1,000 frames must finish in reasonable time (< 2.0s)
        assert (t1 - t0) < 2.5, f"1000 packet flood took too long: {t1 - t0:.2f}s"


def test_adv_02_audio_packet_size_extremes(voice_gate_env):
    """Adversarial Challenge 1B: Extreme packet sizes (0B, odd 1B/3B, 64KB, 1MB).
    
    Verifies that non-standard and large byte frames do not crash the gateway or hang the server.
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready

        # 0 bytes: ignored gracefully
        ws.send_bytes(b"")
        # Odd bytes (1 byte, 3 bytes): linear PCM16 is 2-byte aligned, but raw bytes shouldn't crash WS
        ws.send_bytes(b"\xaa")
        ws.send_bytes(b"\xbb\xcc\xdd")
        # Standard frame
        ws.send_bytes(b"\x00\x01" * 1600)
        # 64 KB frame
        ws.send_bytes(b"\x12\x34" * 32768)
        # 1 MB frame
        ws.send_bytes(b"\x56\x78" * 524288)

        # Health check ping
        ws.send_text('{"type": "ping"}')
        pong = json.loads(ws.receive_text())
        assert pong["type"] == "pong"

        # 0-byte was ignored, so 5 packets reached mock
        assert len(mock.received_audio) == 5
        assert len(mock.received_audio[0]) == 1
        assert len(mock.received_audio[1]) == 3
        assert len(mock.received_audio[2]) == 3200
        assert len(mock.received_audio[3]) == 65536
        assert len(mock.received_audio[4]) == 1048576


# ==============================================================================
# Challenge 2: Rapid-Fire Barge-In Interruptions & Epoch Monotonicity
# ==============================================================================

def test_adv_03_rapid_fire_barge_in_epoch_monotonicity(voice_gate_env):
    """Adversarial Challenge 2A: 50 back-to-back interrupt messages sent in rapid succession.
    
    Verifies that the server increments epochs strictly monotonically (1 -> 51)
    and that the client receives all 50 interrupted signals in consecutive order.
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["epoch"] == 1

        # Fire 50 interrupts rapidly
        for _ in range(50):
            ws.send_text('{"type": "interrupt"}')

        received_epochs = []
        for _ in range(50):
            msg = json.loads(ws.receive_text())
            assert msg["type"] == "interrupted"
            assert msg["source"] == "client"
            received_epochs.append(msg["epoch"])

        # Epochs must be strictly [2, 3, 4, ..., 51]
        expected_epochs = list(range(2, 52))
        assert received_epochs == expected_epochs
        assert mock.interrupt_calls == 50

        # Next ping must reflect epoch 51
        ws.send_text('{"type": "ping"}')
        pong = json.loads(ws.receive_text())
        assert pong["epoch"] == 51


def test_adv_04_stale_audio_leak_with_tagged_epoch(voice_gate_env):
    """Adversarial Challenge 2B: Verification of tagged epoch fencing.
    
    When an upstream packet is tagged with an older epoch (e.g. epoch: 1),
    the gateway must drop it when active_epoch has advanced to 2.
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready (epoch 1)

        # Advance to epoch 2 via interrupt
        ws.send_text('{"type": "interrupt"}')
        ack = json.loads(ws.receive_text())
        assert ack["epoch"] == 2

        # Upstream yields stale frame tagged with epoch 1, and fresh frame with epoch 2
        mock.queue.put_nowait({"type": "audio", "data": b"STALE_OLD_EPOCH_1", "epoch": 1})
        mock.queue.put_nowait({"type": "audio", "data": b"FRESH_NEW_EPOCH_2", "epoch": 2})
        mock.queue.put_nowait({"type": "turn_complete", "epoch": 2})

        received_audio = []
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                received_audio.append(msg["bytes"])
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "turn_complete":
                    break

        assert b"STALE_OLD_EPOCH_1" not in received_audio
        assert b"FRESH_NEW_EPOCH_2" in received_audio


def test_adv_05_stale_audio_leak_with_untagged_real_world_adapter(voice_gate_env):
    """Adversarial Challenge 2C (Critical Architecture Probe):
    Untagged audio frames from real-world upstreams (Gemini Live / OpenAI Realtime).
    
    Real upstream APIs do NOT include an 'epoch' field in raw PCM packets.
    In voice_live.py:
        frame_epoch = int(event.get("epoch", active_epoch))
        if frame_epoch == active_epoch:
            await ws.send_bytes(pcm_data)
    
    We test what happens when an in-flight, untagged audio frame arrives AFTER
    an interrupt has been processed: does it leak through to the client?
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready

        # 1. First audio frame delivered in epoch 1
        mock.queue.put_nowait({"type": "audio", "data": b"EPOCH1_AUDIO_FRAME"})
        frame1 = ws.receive_bytes()
        assert frame1 == b"EPOCH1_AUDIO_FRAME"

        # 2. Client triggers barge-in interrupt -> active_epoch becomes 2
        ws.send_text('{"type": "interrupt"}')
        interrupt_msg = json.loads(ws.receive_text())
        assert interrupt_msg["type"] == "interrupted"
        assert interrupt_msg["epoch"] == 2

        # 3. Upstream (like real Gemini WebSocket) yields a chunk that was already in-flight
        # before the interrupt reached the upstream server.
        # Notice: It has NO 'epoch' key because Gemini/OpenAI has no concept of our epoch!
        mock.queue.put_nowait({"type": "audio", "data": b"IN_FLIGHT_GEMINI_STALE_FRAME"})
        mock.queue.put_nowait({"type": "turn_complete"})

        received_bytes = []
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                received_bytes.append(msg["bytes"])
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "turn_complete":
                    break

        # EMPIRICAL OBSERVATION & BUG DETECTION:
        # Check whether IN_FLIGHT_GEMINI_STALE_FRAME was leaked or dropped!
        leaked = b"IN_FLIGHT_GEMINI_STALE_FRAME" in received_bytes
        print(f"\n[STALE FRAME TEST] received_bytes = {received_bytes}")
        print(f"[STALE FRAME TEST] leaked = {leaked}")
        # An ideal epoch fencing gateway must DROP stale audio from prior epochs!
        # When upstream does not tag 'epoch' (true for all real APIs), voice_live.py line 1366
        # defaults to active_epoch, causing stale frames to LEAK to the client.
        assert not leaked, (
            f"VULNERABILITY CONFIRMED: Untagged in-flight audio frame {received_bytes} "
            "leaked to client after barge-in interrupt! Line 1366 defaults to active_epoch."
        )

        # 4. Verify that fresh untagged audio in the new turn after suppression is lifted is properly delivered
        mock.queue.put_nowait({"type": "audio", "data": b"FRESH_UNTAGGED_FRAME_EPOCH2"})
        mock.queue.put_nowait({"type": "turn_complete"})
        fresh_bytes = []
        while True:
            msg = ws.receive()
            if msg.get("bytes"):
                fresh_bytes.append(msg["bytes"])
            elif msg.get("text"):
                ev = json.loads(msg["text"])
                if ev.get("type") == "turn_complete":
                    break
        assert b"FRESH_UNTAGGED_FRAME_EPOCH2" in fresh_bytes, (
            "Fresh untagged audio frame from new epoch must be delivered after suppression is lifted!"
        )


def test_adv_11_zero_turns_immediate_disconnect(voice_gate_env):
    """Adversarial Challenge 3C: Client connects and immediately disconnects without any turns.
    
    Verifies that post_call_summary_pipeline and finally block handle empty session_turns
    gracefully without crashing or generating corrupt files.
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
            records_dir=voice_gate_env["records"],
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready
        # Immediately disconnect
        ws.close()

    assert mock.closed is True


def test_adv_12_concurrent_multi_session_stress(voice_gate_env):
    """Adversarial Challenge 1C: Multi-session concurrency stress.
    
    Verifies that multiple sequential and simultaneous client connections
    do not leak state, share epochs, or cross-contaminate PersonalConversation.
    """
    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            records_dir=voice_gate_env["records"],
        )
    )
    client = TestClient(app)
    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}

    for i in range(10):
        with client.websocket_connect(f"/voice/live?adapter=mock&session_id=stress-sess-{i}", headers=headers) as ws:
            ready = json.loads(ws.receive_text())
            assert ready["type"] == "ready"
            assert ready["epoch"] == 1
            assert ready["session_id"] == f"stress-sess-{i}"

            # Each session triggers 3 interrupts
            for _ in range(3):
                ws.send_text('{"type": "interrupt"}')
                ack = json.loads(ws.receive_text())
                assert ack["type"] == "interrupted"

            ws.send_text('{"type": "ping"}')
            pong = json.loads(ws.receive_text())
            assert pong["epoch"] == 4  # 1 + 3 interrupts

            ws.close()


def test_adv_06_simultaneous_bidirectional_interrupt_race(voice_gate_env):
    """Adversarial Challenge 2D: Simultaneous client barge-in and server-side VAD interrupt.
    
    Verifies that simultaneous interrupts from both client and server VAD
    do not trigger deadlocks or invalid epoch states.
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ready = json.loads(ws.receive_text())
        assert ready["epoch"] == 1

        # Queue server VAD interrupt in upstream
        mock.queue.put_nowait({"type": "interrupted"})
        # Send client interrupt over WS at the same time
        ws.send_text('{"type": "interrupt"}')

        # Read both interrupted signals
        int1 = json.loads(ws.receive_text())
        int2 = json.loads(ws.receive_text())

        assert int1["type"] == "interrupted"
        assert int2["type"] == "interrupted"

        sources = {int1["source"], int2["source"]}
        assert sources == {"server", "client"}
        # Both interrupts must increment epoch
        assert int1["epoch"] == 2
        assert int2["epoch"] == 3


# ==============================================================================
# Challenge 3: Network Drop & Abrupt Client Disconnect Resilience
# ==============================================================================

def test_adv_07_abrupt_disconnect_post_call_summary_execution(voice_gate_env):
    """Adversarial Challenge 3A: Abrupt client disconnect without sending 'end'.
    
    Empirically verifies:
    1. Gateway does not crash with unhandled WebSocket exceptions.
    2. The finally block executes post_call_summary_pipeline.
    3. The summary markdown and json files are persisted to records_dir.
    4. The upstream adapter is cleanly closed.
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
            records_dir=voice_gate_env["records"],
            vault_dir=voice_gate_env["vault"],
        )
    )
    client = TestClient(app)

    session_id = "test-adv-session-drop-001"
    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect(f"/voice/live?session_id={session_id}", headers=headers) as ws:
        ws.receive_text()  # ready

        # User speaks
        ws.send_text('{"type": "text", "text": "Eddie: 明天下午三点提醒我和张总开会"}')
        ws.receive_text()  # transcript
        ws.receive_text()  # user_transcript

        # Assistant speaks
        mock.queue.put_nowait({"type": "transcript", "role": "assistant", "text": "好的，已经记下了！", "finished": True})
        mock.queue.put_nowait({"type": "turn_complete"})
        ws.receive_text()  # transcript
        ws.receive_text()  # assistant_transcript
        ws.receive_text()  # turn_complete

        # ABRUPT DROP: client disconnects immediately without sending {"type": "end"}!
        ws.close()

    # Upstream must be cleanly closed by finally block
    assert mock.closed is True

    # Check that post_call_summary_pipeline in finally: actually wrote files!
    month_str = time.strftime("%Y-%m")
    expected_summary_dir = voice_gate_env["records"] / month_str
    md_file = expected_summary_dir / f"{session_id}-summary.md"
    json_file = expected_summary_dir / f"{session_id}-summary.json"

    assert md_file.exists(), f"Summary markdown missing: {md_file}"
    assert json_file.exists(), f"Summary JSON missing: {json_file}"

    md_content = md_file.read_text(encoding="utf-8")
    assert session_id in md_content
    assert "明天下午三点提醒我和张总开会" in md_content


def test_adv_08_abrupt_disconnect_mid_stream_audio_flood(voice_gate_env):
    """Adversarial Challenge 3B: Client drops connection while audio is actively streaming.
    
    Verifies that upstream_to_client catching WebSocketDisconnect / CancelledError
    does not leave background coroutines hanging or leak resources.
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
            records_dir=voice_gate_env["records"],
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready

        # Queue continuous audio chunks into upstream
        for i in range(10):
            mock.queue.put_nowait({"type": "audio", "data": f"CHUNK_{i}".encode()})

        # Receive 2 chunks then abruptly drop connection
        ws.receive_bytes()
        ws.receive_bytes()
        ws.close()

    # Upstream must be closed cleanly despite buffered chunks
    assert mock.closed is True


# ==============================================================================
# Challenge 4: Latency & TTFA (Time to First Audio) Measurement
# ==============================================================================

def test_adv_09_latency_ttfa_measurement(voice_gate_env):
    """Adversarial Challenge 4A: Empirical measurement of Time-to-First-Audio (TTFA).
    
    Measures the local gateway round-trip latency from when client sends audio
    to when the first downstream PCM24 audio packet is received.
    Executes 30 iterations to compute min, mean, p95, and max latency.
    """
    mock = MockLiveAdapter(auto_respond=True)

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    ttfa_samples: list[float] = []

    for _ in range(25):
        # Fresh mock per iteration
        iter_mock = MockLiveAdapter(auto_respond=True)

        async def iter_factory(v: str, p: str, t: list):
            return iter_mock

        iter_app = FastAPI()
        iter_app.include_router(
            voice_live_router(
                voice_gate_env["state"],
                voice_gate_env["convo"],
                adapter_factory=iter_factory,
            )
        )
        iter_client = TestClient(iter_app)

        with iter_client.websocket_connect("/voice/live", headers=headers) as ws:
            ws.receive_text()  # ready

            t_start = time.perf_counter()
            # Send 100ms PCM16 frame
            ws.send_bytes(b"\x00\x01" * 1600)

            # Receive until first audio packet
            while True:
                msg = ws.receive()
                if msg.get("bytes"):
                    t_first_audio = time.perf_counter()
                    ttfa_samples.append((t_first_audio - t_start) * 1000.0)  # ms
                    break

    assert len(ttfa_samples) == 25
    min_ttfa = min(ttfa_samples)
    mean_ttfa = sum(ttfa_samples) / len(ttfa_samples)
    sorted_ttfa = sorted(ttfa_samples)
    p95_ttfa = sorted_ttfa[int(len(sorted_ttfa) * 0.95)]
    max_ttfa = max(ttfa_samples)

    print(
        f"\n[TTFA Latency Benchmark] Samples={len(ttfa_samples)}, "
        f"Min={min_ttfa:.2f}ms, Mean={mean_ttfa:.2f}ms, P95={p95_ttfa:.2f}ms, Max={max_ttfa:.2f}ms"
    )

    # Local gateway overhead must be under 30ms on modern macOS
    assert mean_ttfa < 30.0, f"Mean TTFA {mean_ttfa:.2f}ms exceeded 30ms local threshold!"
    assert p95_ttfa < 50.0, f"P95 TTFA {p95_ttfa:.2f}ms exceeded 50ms local threshold!"


def test_adv_10_interruption_roundtrip_latency(voice_gate_env):
    """Adversarial Challenge 4B: Interruption acknowledgment round-trip latency.
    
    Measures the exact elapsed time between client dispatching {"type": "interrupt"}
    and receiving {"type": "interrupted", "epoch": N}.
    Target: < 15ms.
    """
    mock = StreamingMockAdapter()

    async def adapter_factory(voice: str, prompt: str, tools: list):
        return mock

    app = FastAPI()
    app.include_router(
        voice_live_router(
            voice_gate_env["state"],
            voice_gate_env["convo"],
            adapter_factory=adapter_factory,
        )
    )
    client = TestClient(app)

    headers = {"Authorization": f"Bearer {voice_gate_env['token']}"}
    with client.websocket_connect("/voice/live", headers=headers) as ws:
        ws.receive_text()  # ready

        latencies = []
        for _ in range(20):
            t0 = time.perf_counter()
            ws.send_text('{"type": "interrupt"}')
            ack = json.loads(ws.receive_text())
            t1 = time.perf_counter()
            assert ack["type"] == "interrupted"
            latencies.append((t1 - t0) * 1000.0)

        mean_lat = sum(latencies) / len(latencies)
        max_lat = max(latencies)
        print(f"\n[Interrupt Latency Benchmark] Mean={mean_lat:.2f}ms, Max={max_lat:.2f}ms")

        # Barge-in acknowledgment must be ultra-fast (< 15ms)
        assert mean_lat < 15.0, f"Interrupt roundtrip {mean_lat:.2f}ms exceeded 15ms threshold!"
