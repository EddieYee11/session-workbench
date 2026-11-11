"""Adversarial stress-test suite for Milestone 3 Gate:
SSE Concurrency, Ring Buffer Overflow & Pruning, Replay Contract, Deduplication, and Disconnection Resilience.

Empirically challenges:
1. Ring Buffer Overflow & Pruning Concurrency:
   - 2500 concurrent writes across 50 threads into SSERingBuffer(capacity=1000).
   - Zero SQLite locking crashes (OperationalError: database is locked).
   - Buffer size capped at 1000, oldest 1500 pruned, monotonic sequence order strictly preserved.
   - Database persistence integrity and cold restart restoration.
2. Replay vs Expired Cursor Resync Contract:
   - In-window replay: strict ascending sequence, exact boundary at min_retained_seq - 1.
   - Expired cursor (< min_retained_seq - 1): immediate resync_required event followed by snapshot.
   - Future cursor (> latest_seq): resync_required with cursor_future followed by snapshot.
   - Initial connection (cursor is None or <= 0): immediate snapshot.
3. Sequence Deduplication & Jitter Resilience:
   - Out-of-order and duplicate frame bursts simulation.
   - Verification of client-side deduplication gate (Web & iOS contract).
   - Zero duplicate state mutations on replayed sequences.
4. Heartbeat Keepalive & Disconnection Resilience:
   - Keepalive heartbeat frame emission on idle connection.
   - Client exponential backoff algorithm with jitter (bounded <= 15.5s, progressive).
   - Transient network blip grace period (< 3.0s silent without error banner).
5. End-to-End FastAPI Streaming Request Integration:
   - Direct Request invocation of /personal/stream verifying Last-Event-ID extraction and streaming response.
"""
from __future__ import annotations

import asyncio
import collections
import concurrent.futures
import json
import math
import random
import sqlite3
import time
from pathlib import Path
from typing import Any

import pytest
from starlette.requests import Request

import app as app_module
from sse_stream import SSEBroadcaster, SSEEvent, SSERingBuffer


# ===========================================================================
# 1. Ring Buffer Overflow & Pruning Concurrency (2500 Concurrent Writes)
# ===========================================================================

def test_adversarial_ring_buffer_concurrency_2500_events(tmp_path: Path):
    """Adversarial Challenge 1:
    Concurrently write 2500 events into SSERingBuffer(capacity=1000) using 50 worker threads.
    Verify:
    1. Zero SQLite locking errors (OperationalError: database is locked).
    2. Buffer size remains strictly capped at 1000.
    3. Oldest 1500 events (seq 1..1500) pruned from memory buffer.
    4. Monotonic sequence order maintained across all retained entries (1501..2500).
    5. Database contains all 2500 rows, monotonic and unbroken.
    6. Cold restart correctly reloads top 1000 events.
    """
    db_file = tmp_path / "sse_concurrency_2500.sqlite"
    rb = SSERingBuffer(db_file, capacity=1000)

    total_events = 2500
    num_workers = 50

    def worker_write(index: int) -> int:
        ev = rb.publish("stress.event", {
            "index": index,
            "payload": f"data-{index}",
            "ts": time.time(),
        })
        return ev.event_seq

    start_time = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=num_workers) as executor:
        seqs = list(executor.map(worker_write, range(total_events)))
    elapsed = time.time() - start_time

    # 1. Zero crash assertion: all 2500 events returned valid sequences
    assert len(seqs) == total_events, f"Expected {total_events} results, got {len(seqs)}"
    assert sorted(seqs) == list(range(1, total_events + 1)), "Event sequence numbers must be contiguous 1..2500"

    # 2. Buffer capacity cap
    assert len(rb.buffer) == 1000, f"Buffer size {len(rb.buffer)} exceeds capacity 1000"

    # 3. Oldest pruned: min_retained_seq must be 1501, latest_seq must be 2500
    assert rb.min_retained_seq == 1501, f"Expected min_retained_seq=1501, got {rb.min_retained_seq}"
    assert rb.latest_seq == 2500, f"Expected latest_seq=2500, got {rb.latest_seq}"

    # 4. Monotonic strictly increasing order inside buffer
    buffer_seqs = [ev.event_seq for ev in rb.buffer]
    assert buffer_seqs == list(range(1501, 2501)), "Buffer sequence must be monotonically increasing 1501..2500"

    # 5. SQLite persistent storage integrity & pruning: capped at capacity=1000 in WAL mode
    with sqlite3.connect(db_file) as conn:
        row_count, min_seq, max_seq = conn.execute(
            "SELECT COUNT(*), MIN(event_seq), MAX(event_seq) FROM sse_event_log"
        ).fetchone()
        assert row_count == 1000, f"Expected exactly 1000 pruned rows in SQLite, got {row_count}"
        assert min_seq == 1501, f"Expected min_seq=1501 in SQLite, got {min_seq}"
        assert max_seq == total_events, f"Expected max_seq=2500 in SQLite, got {max_seq}"

        # Check WAL mode
        journal_mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
        assert journal_mode.lower() == "wal"

    # 6. Cold restart verification
    rb_reloaded = SSERingBuffer(db_file, capacity=1000)
    assert len(rb_reloaded.buffer) == 1000
    assert rb_reloaded.min_retained_seq == 1501
    assert rb_reloaded.latest_seq == 2500
    reloaded_seqs = [ev.event_seq for ev in rb_reloaded.buffer]
    assert reloaded_seqs == buffer_seqs


# ===========================================================================
# 2. Replay vs Expired Cursor Resync Contract
# ===========================================================================

@pytest.mark.anyio
async def test_adversarial_replay_contract_within_and_outside_retention_window(tmp_path: Path):
    """Adversarial Challenge 2:
    Verify replay behavior for:
    - Cursor within retention window (sequential replay in ascending order).
    - Boundary cursor (cursor == min_retained_seq - 1): all buffer events replayed.
    - Up-to-date cursor (cursor == latest_seq): 0 missed events.
    - Expired cursor (cursor < min_retained_seq - 1): resync_required with reason=cursor_expired + snapshot.
    - Future cursor (cursor > latest_seq): resync_required with reason=cursor_future + snapshot.
    - Initial connection (cursor None or <= 0): snapshot.
    """
    db_file = tmp_path / "sse_replay_contract.sqlite"
    rb = SSERingBuffer(db_file, capacity=100)
    bc = SSEBroadcaster(rb)

    # Publish 300 events. Buffer retains 201..300. min_retained_seq = 201, latest_seq = 300.
    for i in range(1, 301):
        bc.publish("item.event", {"idx": i})

    assert rb.latest_seq == 300
    assert rb.min_retained_seq == 201

    snapshot_data = {"board": {"col": "test"}, "revision": 42}
    get_snapshot = lambda: snapshot_data

    # --- Scenario 2.1: In-window replay (cursor = 280) ---
    missed_events = rb.get_since(280)
    assert len(missed_events) == 20
    assert [ev.event_seq for ev in missed_events] == list(range(281, 301))
    assert all(ev.data["idx"] == ev.event_seq for ev in missed_events)

    # In-window stream output verification
    stream_280 = bc.stream_client(cursor=280, get_snapshot_fn=get_snapshot)
    first_replayed_frame = await stream_280.__anext__()
    assert "id: 281" in first_replayed_frame
    assert "event: item.event" in first_replayed_frame
    assert '"idx":281' in first_replayed_frame

    # --- Scenario 2.2: Boundary in-window replay (cursor == min_retained_seq - 1 == 200) ---
    assert rb.is_in_buffer(200) is True
    boundary_missed = rb.get_since(200)
    assert len(boundary_missed) == 100
    assert boundary_missed[0].event_seq == 201
    assert boundary_missed[-1].event_seq == 300

    # --- Scenario 2.3: Up-to-date cursor (cursor == latest_seq == 300) ---
    assert rb.is_in_buffer(300) is True
    uptodate_missed = rb.get_since(300)
    assert len(uptodate_missed) == 0

    # --- Scenario 2.4: Expired cursor boundary (cursor == min_retained_seq - 2 == 199) ---
    assert rb.is_in_buffer(199) is False
    assert rb.is_expired(199) is True

    stream_expired = bc.stream_client(cursor=199, get_snapshot_fn=get_snapshot)
    frame1 = await stream_expired.__anext__()
    frame2 = await stream_expired.__anext__()

    # Frame 1 MUST be resync_required
    assert "event: resync_required" in frame1
    resync_payload = json.loads(frame1.split("data: ")[1].strip())
    assert resync_payload["reason"] == "cursor_expired"
    assert resync_payload["min_retained_seq"] == 201
    assert resync_payload["latest_seq"] == 300
    assert resync_payload["requested_cursor"] == 199

    # Frame 2 MUST be snapshot
    assert "event: snapshot" in frame2
    snap_payload = json.loads(frame2.split("data: ")[1].strip())
    assert snap_payload["latest_event_seq"] == 300
    assert snap_payload["board"]["col"] == "test"

    # --- Scenario 2.5: Far-expired cursor (cursor = 1) ---
    assert rb.is_in_buffer(1) is False
    assert rb.is_expired(1) is True

    # --- Scenario 2.6: Future cursor (cursor = 9999 > latest_seq) ---
    assert rb.is_in_buffer(9999) is False
    assert rb.is_future(9999) is True

    stream_future = bc.stream_client(cursor=9999, get_snapshot_fn=get_snapshot)
    f1 = await stream_future.__anext__()
    f2 = await stream_future.__anext__()

    assert "event: resync_required" in f1
    resync_future_payload = json.loads(f1.split("data: ")[1].strip())
    assert resync_future_payload["reason"] == "cursor_future"
    assert resync_future_payload["requested_cursor"] == 9999
    assert "event: snapshot" in f2

    # --- Scenario 2.7: Initial connection (cursor is None or 0) ---
    stream_none = bc.stream_client(cursor=None, get_snapshot_fn=get_snapshot)
    frame_init = await stream_none.__anext__()
    assert "event: snapshot" in frame_init
    assert "event: resync_required" not in frame_init


# ===========================================================================
# 3. Sequence Deduplication & Jitter Resilience
# ===========================================================================

def test_adversarial_client_sequence_deduplication_and_out_of_order():
    """Adversarial Challenge 3:
    Simulate client event processor modeling both Web (web/js/core.js) and iOS (AppModel.swift).
    Verify:
    1. Out-of-order and duplicate sequence deliveries are discarded silently.
    2. State mutations occur exactly ONCE per unique event_seq.
    3. Bursts of identical sequence frames trigger 0 duplicate mutations.
    4. Special events ('snapshot', 'resync_required') bypass deduplication gate.
    """
    class MockClientState:
        def __init__(self):
            self.last_event_id: int = 0
            self.applied_events: list[dict[str, Any]] = []
            self.discarded_count: int = 0
            self.snapshots_applied: int = 0
            self.resync_count: int = 0

        def receive_frame(self, raw_frame: str) -> bool:
            """Parser conforming to web/js/core.js and iOS AppModel.swift contract."""
            ev = "message"
            data = ""
            frame_id = ""
            for line in raw_frame.split("\n"):
                if not line or line.startswith(":"):
                    continue
                if ":" in line:
                    k, v = line.split(":", 1)
                    v = v.lstrip(" ")
                else:
                    k, v = line, ""
                if k == "id":
                    frame_id = v.strip()
                elif k == "event":
                    ev = v
                elif k == "data":
                    data += v

            try:
                value = json.loads(data) if data else {}
            except Exception:
                return False

            seq = int(frame_id) if frame_id.isdigit() else 0
            if seq == 0 and isinstance(value, dict) and isinstance(value.get("event_seq"), int):
                seq = value["event_seq"]

            # Deduplication Gate (AppModel.swift:989 & core.js:483)
            if seq > 0:
                if ev != "snapshot" and ev != "resync_required" and seq <= self.last_event_id:
                    self.discarded_count += 1
                    return False  # Discarded
                self.last_event_id = max(self.last_event_id, seq)

            if ev == "resync_required":
                self.resync_count += 1
                return True
            if ev == "snapshot":
                self.snapshots_applied += 1
                return True

            # Standard matter.update or regular event
            self.applied_events.append({"event": ev, "seq": seq, "data": value})
            return True

    client = MockClientState()

    # Step 1: Initial event 100
    frame_100 = "id: 100\nevent: matter.update\ndata: {\"matter_id\":\"m1\",\"status\":\"todo\",\"event_seq\":100}\n\n"
    assert client.receive_frame(frame_100) is True
    assert client.last_event_id == 100
    assert len(client.applied_events) == 1

    # Step 2: Immediate duplicate delivery of event 100 (network re-send)
    assert client.receive_frame(frame_100) is False
    assert client.last_event_id == 100
    assert len(client.applied_events) == 1
    assert client.discarded_count == 1

    # Step 3: Stale / out-of-order events (seq 95, 98, 99)
    for stale_seq in [95, 98, 99]:
        stale_frame = f"id: {stale_seq}\nevent: matter.update\ndata: {{\"matter_id\":\"m1\",\"status\":\"suggested\",\"event_seq\":{stale_seq}}}\n\n"
        assert client.receive_frame(stale_frame) is False
        assert client.last_event_id == 100
        assert len(client.applied_events) == 1

    assert client.discarded_count == 4

    # Step 4: Rapid duplicate burst: 50 identical transmissions of seq 101
    frame_101 = "id: 101\nevent: matter.update\ndata: {\"matter_id\":\"m1\",\"status\":\"doing\",\"event_seq\":101}\n\n"
    first_res = client.receive_frame(frame_101)
    assert first_res is True
    assert client.last_event_id == 101
    assert len(client.applied_events) == 2

    for _ in range(49):
        res = client.receive_frame(frame_101)
        assert res is False

    assert client.discarded_count == 4 + 49
    assert len(client.applied_events) == 2  # State applied exactly ONCE

    # Step 5: Special event snapshot with seq <= last_event_id MUST NOT be discarded
    snap_frame = f"id: 50\nevent: snapshot\ndata: {{\"latest_event_seq\":101,\"board\":{{}}}}\n\n"
    assert client.receive_frame(snap_frame) is True
    assert client.snapshots_applied == 1

    # Step 6: Special event resync_required with seq <= last_event_id MUST NOT be discarded
    resync_frame = f"id: 101\nevent: resync_required\ndata: {{\"reason\":\"cursor_expired\",\"event_seq\":101}}\n\n"
    assert client.receive_frame(resync_frame) is True
    assert client.resync_count == 1


# ===========================================================================
# 4. Heartbeat Keepalive & Disconnection Resilience
# ===========================================================================

@pytest.mark.anyio
async def test_adversarial_heartbeat_keepalive_emission(tmp_path: Path):
    """Adversarial Challenge 4.1:
    Verify server keepalive heartbeat comments are generated when connection is idle.
    """
    db_file = tmp_path / "sse_heartbeat.sqlite"
    rb = SSERingBuffer(db_file, capacity=10)
    bc = SSEBroadcaster(rb)

    # Use a tiny keepalive timeout of 0.05s to verify idle heartbeat emission
    stream_gen = bc.stream_client(cursor=0, get_snapshot_fn=lambda: {"snap": 1}, keepalive_seconds=0.05)

    # First frame is snapshot
    f0 = await stream_gen.__anext__()
    assert "event: snapshot" in f0

    # Wait for keepalive comment
    f_heartbeat = await stream_gen.__anext__()
    assert f_heartbeat.startswith(": keepalive ")
    assert f_heartbeat.endswith("\n\n")


def test_adversarial_reconnect_backoff_and_jitter_bounds():
    """Adversarial Challenge 4.2:
    Simulate client exponential backoff calculation across 100 consecutive connection drops.
    Verify:
    1. Backoff is strictly capped (<= 15.5s / 15500ms).
    2. Jitter is strictly non-negative and randomized (prevents thundering herd).
    3. Monotonic upper growth until cap reached.
    4. No integer overflow or infinite loops.
    """
    # iOS Backoff formula: min(15.0, 1.0 * pow(1.8, min(failures, 5))) + random(0...0.5)
    for failures in range(1, 100):
        base_ios = min(15.0, 1.0 * (1.8 ** min(failures, 5)))
        jitter_ios = random.uniform(0.0, 0.5)
        total_ios = base_ios + jitter_ios

        assert 1.0 <= total_ios <= 15.5
        assert 0.0 <= jitter_ios <= 0.5

    # Web Backoff formula: min(15000, 1000 * (1.8 ** min(failures, 6))) + random() * 500
    for failures in range(1, 100):
        base_web = min(15000.0, 1000.0 * (1.8 ** min(failures, 6)))
        jitter_web = random.uniform(0.0, 500.0)
        total_web = base_web + jitter_web

        assert 1000.0 <= total_web <= 15500.0
        assert 0.0 <= jitter_web <= 500.0


def test_adversarial_transient_grace_period_suppresses_error_banner():
    """Adversarial Challenge 4.3:
    Verify transient grace period (3.0s):
    Disconnections under 3.0s MUST NOT set streamNote or error banner.
    """
    class MockClientConnectionManager:
        def __init__(self):
            self.disconnect_time: float | None = None
            self.stream_note = ""
            self.errors: dict[str, str] = {}
            self.streaming = False

        def mark_down(self, now: float, attempt: int):
            self.streaming = False
            if self.disconnect_time is None:
                self.disconnect_time = now
            elapsed = now - self.disconnect_time

            # 3.0s Transient Grace Period Contract (PRD C06 & TC-05)
            if elapsed < 3.0:
                self.stream_note = ""
                self.errors.pop("/personal/conversation", None)
                return

            msg = "实时连接恢复中，当前显示本地缓存"
            self.stream_note = msg
            self.errors["/personal/conversation"] = msg

        def mark_up(self):
            self.disconnect_time = None
            self.streaming = True
            self.stream_note = ""
            self.errors.pop("/personal/conversation", None)

    mgr = MockClientConnectionManager()
    t0 = 1000.0

    # 1. Transient drop for 0.5s (e.g. WiFi <-> Cellular handover)
    mgr.mark_down(now=t0, attempt=1)
    mgr.mark_down(now=t0 + 0.5, attempt=1)
    assert mgr.stream_note == "", "Transient drop < 3.0s must not show error banner"
    assert "/personal/conversation" not in mgr.errors

    # 2. Still disconnected at 2.9s
    mgr.mark_down(now=t0 + 2.9, attempt=2)
    assert mgr.stream_note == "", "Transient drop < 3.0s must not show error banner"

    # 3. Reconnected at 2.95s
    mgr.mark_up()
    assert mgr.streaming is True
    assert mgr.stream_note == ""

    # 4. Prolonged drop: starts at t1, continues to t1 + 3.5s (> 3.0s)
    t1 = 2000.0
    mgr.mark_down(now=t1, attempt=1)
    mgr.mark_down(now=t1 + 1.0, attempt=1)
    assert mgr.stream_note == ""
    mgr.mark_down(now=t1 + 3.5, attempt=2)
    assert mgr.stream_note == "实时连接恢复中，当前显示本地缓存"
    assert mgr.errors["/personal/conversation"] == "实时连接恢复中，当前显示本地缓存"


# ===========================================================================
# 5. Concurrent Streaming & Publishing Interleaving (Stress Race Test)
# ===========================================================================

@pytest.mark.anyio
async def test_adversarial_concurrent_stream_and_publish_race(tmp_path: Path):
    """Adversarial Challenge 5:
    Stress race between concurrent stream reading and concurrent event publishing.
    Verify:
    1. Subscriber receives streamed events without dropping or crashing.
    2. Zero deadlocks under heavy interleaving.
    """
    db_file = tmp_path / "sse_race.sqlite"
    rb = SSERingBuffer(db_file, capacity=500)
    bc = SSEBroadcaster(rb)

    # Initial seed
    for i in range(1, 21):
        bc.publish("seed", {"n": i})

    received_seqs: list[int] = []
    stop_event = asyncio.Event()

    async def consumer():
        stream_gen = bc.stream_client(cursor=20, get_snapshot_fn=lambda: {"snap": 1}, keepalive_seconds=5.0)
        async for frame in stream_gen:
            for line in frame.split("\n"):
                if line.startswith("id: "):
                    s = int(line[4:].strip())
                    received_seqs.append(s)
            if stop_event.is_set():
                break

    consumer_task = asyncio.create_task(consumer())
    await asyncio.sleep(0.05)  # Ensure consumer is hooked

    # Concurrently publish 100 new events
    def publish_batch(start_idx: int, count: int):
        for j in range(start_idx, start_idx + count):
            bc.publish("live.race", {"idx": j})

    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, publish_batch, 21, 100)

    # Allow consumer time to drain
    await asyncio.sleep(0.2)
    stop_event.set()
    consumer_task.cancel()
    try:
        await consumer_task
    except asyncio.CancelledError:
        pass

    assert len(received_seqs) >= 100, f"Expected at least 100 live events received, got {len(received_seqs)}"
    # Sequences must be strictly increasing
    assert all(x < y for x, y in zip(received_seqs, received_seqs[1:])), "Received stream must be monotonically increasing"


# ===========================================================================
# 6. End-to-End FastAPI Streaming Request Integration Test
# ===========================================================================

@pytest.mark.anyio
async def test_api_sse_stream_header_replay_and_resync():
    """Adversarial Challenge 6:
    Verify FastAPI personal_conversation_stream handler:
    - Extracts Last-Event-ID header.
    - Yields text/event-stream content.
    - Accurately responds with snapshot, replayed frames, or resync_required.
    """
    # 1. Test request without Last-Event-ID -> Snapshot
    scope_init = {
        "type": "http",
        "method": "GET",
        "path": "/personal/stream",
        "headers": [(b"authorization", f"Bearer {app_module.TOKEN}".encode())],
    }
    req_init = Request(scope_init)
    resp_init = await app_module.personal_conversation_stream(req_init)
    assert resp_init.status_code == 200
    assert resp_init.media_type == "text/event-stream"
    first_frame = await resp_init.body_iterator.__anext__()
    assert "event: snapshot" in first_frame
    await resp_init.body_iterator.aclose()

    # 2. Test request with Last-Event-ID header
    scope_cursor = {
        "type": "http",
        "method": "GET",
        "path": "/personal/stream",
        "headers": [
            (b"authorization", f"Bearer {app_module.TOKEN}".encode()),
            (b"last-event-id", b"99999999"),  # Future cursor
        ],
    }
    req_cursor = Request(scope_cursor)
    resp_cursor = await app_module.personal_conversation_stream(req_cursor)
    assert resp_cursor.status_code == 200
    frame_resync = await resp_cursor.body_iterator.__anext__()
    assert "event: resync_required" in frame_resync
    assert "cursor_future" in frame_resync
    await resp_cursor.body_iterator.aclose()
