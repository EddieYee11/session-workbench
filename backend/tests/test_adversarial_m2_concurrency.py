"""Adversarial stress-test suite for Milestone 2 Phase 2:
Concurrency Robustness, 11-State FSM, and Circuit Breakers.

Empirically challenges:
- Scenario A: High-concurrency identical action triggers (25+ threads hitting /personal/matters/{id}/action).
- Scenario B: Conflicting moves (Thread 1 -> doing, Thread 2 -> done with same rev; 15-thread race on rev).
- Scenario C: get_action_op scope breach test (cross-matter leakage prevention at store and API level).
- Scenario D: Outbox circuit-breaker and DLQ (5 consecutive delivery failures, filtering from pending, 503 headers).
- Scenario E: Concurrency deadlocks under Starlette TestClient & CrossEventLoopAsyncLock stress (multi-loop mutual exclusion & error recovery).
"""
from __future__ import annotations

import asyncio
import concurrent.futures
import json
from pathlib import Path
import threading
import time
from typing import Any

import pytest
from starlette.testclient import TestClient

import app as app_module
from board import CrossEventLoopAsyncLock
from matter_schema import (
    FSM_STATES,
    VALID_TRANSITIONS,
    MatterConflict,
    MatterIllegalTransition,
    MatterNotFound,
    MatterStore,
    generate_matter_id,
)


# ===========================================================================
# SCENARIO A: High-concurrency identical action triggers (25+ threads)
# ===========================================================================

def test_scenario_a1_high_concurrency_identical_action_same_request_id():
    """Scenario A1: 25 threads firing identical action with the SAME request_id simultaneously.
    Verify all threads receive 200 OK, matching receipt, exactly 1 entry in matter_action_ops,
    and matter status is 'done'.
    """
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="Scenario A1 25并发相同RequestID",
        source_type="test",
        status="suggested",
        matter_id=mid,
        action={"type": "bookkeep", "amount": 128.5, "note": "A1记账测试"},
    )

    req_id = f"req-scen-a1-{mid}"
    payload = {
        "action_type": "bookkeep",
        "amount": 128.5,
        "category": "商务餐饮",
        "comment": "高并发A1测试",
        "request_id": req_id,
    }

    worker_count = 25
    barrier = threading.Barrier(worker_count)

    def worker_action():
        barrier.wait()  # synchronize all threads to fire simultaneously
        return client.post(f"/personal/matters/{mid}/action", headers=headers, json=payload)

    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as pool:
        futures = [pool.submit(worker_action) for _ in range(worker_count)]
        responses = [f.result(timeout=10) for f in futures]

    # Verify all 25 returned 200 OK
    for idx, resp in enumerate(responses):
        assert resp.status_code == 200, f"Thread {idx} failed with {resp.status_code}: {resp.text}"
        data = resp.json()
        assert data["ok"] is True
        assert data["matter_status"] == "done"
        assert "receipt" in data

    # Verify receipt consistency
    first_receipt = responses[0].json()["receipt"]
    for idx, resp in enumerate(responses[1:], start=1):
        assert resp.json()["receipt"] == first_receipt, f"Receipt mismatch at index {idx}"

    # Verify single DB idempotency record
    with app_module.personal_board.matter_store.db() as db:
        rows = db.execute("SELECT * FROM matter_action_ops WHERE op_id=?", (req_id,)).fetchall()
        assert len(rows) == 1, f"Expected 1 op in matter_action_ops, found {len(rows)}"

    # Verify matter state is done with rev=2
    m = app_module.personal_board.matter_store.get_by_id(mid)
    assert m is not None
    assert m.status == "done"
    assert m.rev == 2


def test_scenario_a2_high_concurrency_action_distinct_request_ids():
    """Scenario A2: 25 threads firing action on the same matter with DISTINCT request_ids.
    First thread transitions matter to 'done'. Subsequent threads collide on FSM or optimistic lock,
    triggering double-checked re-fetch self-healing, and returning 200 OK with done state.
    Verify no 500 crashes, no deadlocks, and final state is done.
    """
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="Scenario A2 25并发不同RequestID自愈测试",
        source_type="test",
        status="suggested",
        matter_id=mid,
        action={"type": "calendar", "title": "A2并发日程"},
    )

    worker_count = 25
    barrier = threading.Barrier(worker_count)

    def worker_action(thread_idx: int):
        barrier.wait()
        req_id = f"req-scen-a2-{mid}-{thread_idx}"
        payload = {
            "action_type": "calendar",
            "title": f"A2日程-{thread_idx}",
            "request_id": req_id,
        }
        return client.post(f"/personal/matters/{mid}/action", headers=headers, json=payload)

    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as pool:
        futures = [pool.submit(worker_action, i) for i in range(worker_count)]
        responses = [f.result(timeout=10) for f in futures]

    # Verify every request returned 200 OK (no 500 or unhandled 400 race crashes)
    for idx, resp in enumerate(responses):
        assert resp.status_code == 200, f"Thread {idx} failed with {resp.status_code}: {resp.text}"
        data = resp.json()
        assert data["ok"] is True
        assert data["matter_status"] == "done"

    m = app_module.personal_board.matter_store.get_by_id(mid)
    assert m is not None
    assert m.status == "done"
    assert m.rev == 2


# ===========================================================================
# SCENARIO B: Conflicting moves (Thread 1 -> doing, Thread 2 -> done with rev 1)
# ===========================================================================

def test_scenario_b1_binary_conflicting_moves():
    """Scenario B1: Exact binary race between two threads moving matter A from suggested:
    - Thread 1: moves to 'doing' with rev=1
    - Thread 2: moves to 'done' with rev=1
    Verify exactly one returns 200 OK, the other returns 409 Conflict with full rollback_metadata.
    """
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    m = app_module.personal_board.matter_store.create_matter(
        title="Scenario B1 二元冲突竞争测试",
        source_type="manual",
        status="suggested",
        matter_id=mid,
    )
    initial_rev = m.rev  # 1

    barrier = threading.Barrier(2)

    def move_thread(target_status: str, tag: str):
        barrier.wait()
        return client.post(
            "/personal/matter/move",
            headers=headers,
            json={
                "matter_id": mid,
                "to_status": target_status,
                "matter_rev": initial_rev,
                "request_id": f"req-b1-{tag}-{mid}",
            },
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        f1 = pool.submit(move_thread, "doing", "t1")
        f2 = pool.submit(move_thread, "done", "t2")
        r1 = f1.result(timeout=5)
        r2 = f2.result(timeout=5)

    statuses = [r1.status_code, r2.status_code]
    assert 200 in statuses, f"Expected at least one 200 OK, got {statuses}"
    assert 409 in statuses, f"Expected at least one 409 Conflict, got {statuses}"

    winner_resp = r1 if r1.status_code == 200 else r2
    loser_resp = r2 if r1.status_code == 200 else r1

    # Winner verification
    winner_data = winner_resp.json()
    assert winner_data["ok"] is True
    winner_status = winner_data["matter"]["status"]
    assert winner_status in ("doing", "done")
    assert winner_data["matter"]["rev"] == 2

    # Loser verification: rich 409 rollback_metadata contract
    loser_data = loser_resp.json()
    assert loser_data["ok"] is False
    assert loser_data["error"] == "conflict"
    assert loser_data["matter_id"] == mid
    assert loser_data["requested_rev"] == initial_rev
    assert loser_data["current_rev"] == 2

    # Verify 'latest' snapshot
    assert "latest" in loser_data
    assert loser_data["latest"]["rev"] == 2
    assert loser_data["latest"]["status"] == winner_status

    # Verify 'diff'
    assert "diff" in loser_data
    assert "rev" in loser_data["diff"]
    assert loser_data["diff"]["rev"]["requested"] == initial_rev
    assert loser_data["diff"]["rev"]["current"] == 2

    # Verify 'rollback_metadata'
    assert "rollback_metadata" in loser_data
    rb = loser_data["rollback_metadata"]
    assert rb["spring_target_column"] == winner_status
    assert isinstance(rb["auto_aligned"], bool)
    assert "toast_type" in rb
    assert "message" in rb

    # DB Integrity check
    persisted = app_module.personal_board.matter_store.get_by_id(mid)
    assert persisted is not None
    assert persisted.rev == 2
    assert persisted.status == winner_status


def test_scenario_b2_n_ary_conflicting_moves_race():
    """Scenario B2: 15 threads racing to move matter A from suggested to different target states,
    all supplying the initial rev=1.
    Verify: exactly 1 succeeds (200 OK), 14 receive 409 with complete rollback_metadata,
    and DB rev increment is exactly 1 (final rev = 2).
    """
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    m = app_module.personal_board.matter_store.create_matter(
        title="Scenario B2 15并发状态竞争",
        source_type="manual",
        status="suggested",
        matter_id=mid,
    )
    initial_rev = m.rev

    # Valid targets from suggested: todo, doing, executing, snoozed, dismissed, done
    candidate_targets = ["todo", "doing", "executing", "snoozed", "dismissed", "done"]
    worker_count = 15
    barrier = threading.Barrier(worker_count)

    def worker_move(idx: int):
        target = candidate_targets[idx % len(candidate_targets)]
        barrier.wait()
        return client.post(
            "/personal/matter/move",
            headers=headers,
            json={
                "matter_id": mid,
                "to_status": target,
                "matter_rev": initial_rev,
                "request_id": f"req-b2-race-{mid}-{idx}",
            },
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as pool:
        futures = [pool.submit(worker_move, i) for i in range(worker_count)]
        results = [f.result(timeout=10) for f in futures]

    count_200 = sum(1 for r in results if r.status_code == 200)
    count_409 = sum(1 for r in results if r.status_code == 409)

    assert count_200 == 1, f"Expected exactly 1 winner with 200 OK, got {count_200}"
    assert count_409 == worker_count - 1, f"Expected {worker_count - 1} 409s, got {count_409}"

    for r in results:
        if r.status_code == 409:
            data = r.json()
            assert data["error"] == "conflict"
            assert "rollback_metadata" in data
            assert data["rollback_metadata"]["spring_target_column"] in candidate_targets

    # SQLite integrity check
    final_m = app_module.personal_board.matter_store.get_by_id(mid)
    assert final_m.rev == initial_rev + 1


# ===========================================================================
# SCENARIO C: get_action_op scope breach test (cross-matter leakage prevention)
# ===========================================================================

def test_scenario_c1_store_level_matter_scope_enforcement():
    """Scenario C1: Directly test MatterStore.get_action_op.
    Ensure querying op_id created under matter_A using matter_B returns None,
    querying with matter_A returns result, and unscoped query returns result.
    """
    store = app_module.personal_board.matter_store
    mid_a = generate_matter_id()
    mid_b = generate_matter_id()
    op_id = f"op-scen-c1-{mid_a}"

    store.save_action_op(op_id, mid_a, {"secret_token": "a_confidential", "amount": 999.0})

    # Legitimate owner query
    res_a = store.get_action_op(op_id, matter_id=mid_a)
    assert res_a is not None
    assert res_a["secret_token"] == "a_confidential"

    # Attacker / cross-matter query with mid_b
    res_b = store.get_action_op(op_id, matter_id=mid_b)
    assert res_b is None, "CRITICAL SECURITY BREACH: Cross-matter op leakage in get_action_op!"

    # Empty or wrong matter_id
    res_wrong = store.get_action_op(op_id, matter_id="mtr-99999999-bad00000")
    assert res_wrong is None

    # Unscoped query (backward compat)
    res_unscoped = store.get_action_op(op_id)
    assert res_unscoped is not None
    assert res_unscoped["secret_token"] == "a_confidential"


def test_scenario_c2_api_level_request_id_cross_matter_hijack_prevention():
    """Scenario C2: API-level attack.
    Matter A performs an action with req_id_A.
    Matter B fires an action request deliberately hijacking req_id_A.
    Verify:
    - Matter B does NOT receive Matter A's cached action result.
    - Matter B performs its own action cleanly or raises appropriately.
    - Matter A and Matter B remain completely isolated in SQLite.
    """
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid_a = generate_matter_id()
    mid_b = generate_matter_id()

    app_module.personal_board.matter_store.create_matter(
        title="Matter A",
        source_type="test",
        status="suggested",
        matter_id=mid_a,
    )
    app_module.personal_board.matter_store.create_matter(
        title="Matter B",
        source_type="test",
        status="suggested",
        matter_id=mid_b,
    )

    hijack_req_id = f"shared-op-{int(time.time() * 1000)}"

    # 1. Matter A executes action with hijack_req_id
    resp_a = client.post(
        f"/personal/matters/{mid_a}/action",
        headers=headers,
        json={
            "action_type": "bookkeep",
            "amount": 500.0,
            "category": "商务餐饮",
            "comment": "Matter A 支出",
            "request_id": hijack_req_id,
        },
    )
    assert resp_a.status_code == 200
    data_a = resp_a.json()
    assert data_a["matter"]["matter_id"] == mid_a
    assert "¥500.0" in data_a["receipt"]["message"]

    # 2. Matter B attempts to execute action using the same request_id but with different payload
    resp_b = client.post(
        f"/personal/matters/{mid_b}/action",
        headers=headers,
        json={
            "action_type": "bookkeep",
            "amount": 20.0,
            "category": "交通出行",
            "comment": "Matter B 支出",
            "request_id": hijack_req_id,
        },
    )
    assert resp_b.status_code == 200
    data_b = resp_b.json()
    # Must NOT have returned Matter A's cached receipt
    assert data_b["matter"]["matter_id"] == mid_b
    assert "¥500.0" not in data_b["receipt"]["message"]
    assert "¥20.0" in data_b["receipt"]["message"]

    # Both matters should independently reach 'done'
    ma = app_module.personal_board.matter_store.get_by_id(mid_a)
    mb = app_module.personal_board.matter_store.get_by_id(mid_b)
    assert ma.status == "done"
    assert mb.status == "done"


# ===========================================================================
# SCENARIO D: Outbox circuit-breaker and DLQ (5 consecutive failures)
# ===========================================================================

def test_scenario_d1_outbox_dlq_lifecycle(tmp_path: Path):
    """Scenario D1: Full lifecycle of an outbox item under consecutive delivery failures.
    - Isolated on a dedicated tmp_path MatterStore instance to prevent shared-state pollution.
    - Retries 1..4 -> status remains 'pending', retry_count increments
    - Retry 5 -> transitions cleanly to 'dlq'
    - Verify list_pending_outbox() excludes this DLQ item
    - Subsequent retries remain in 'dlq'
    """
    db_file = tmp_path / "matters_d1_outbox.sqlite"
    store = MatterStore(db_file)
    mid = generate_matter_id()
    outbox_id = store.create_outbox_event(
        mid,
        "obsidian_projection",
        {"target_status": "done", "note_path": "Todos/test.md"},
    )
    assert isinstance(outbox_id, int)

    # Initially in pending list
    pending = store.list_pending_outbox(limit=100)
    matching = [item for item in pending if item["id"] == outbox_id]
    assert len(matching) == 1
    assert matching[0]["retry_count"] == 0
    assert matching[0]["status"] == "pending"

    # Trigger 4 consecutive delivery failures
    for attempt in range(1, 5):
        st = store.mark_outbox_retry(outbox_id, f"Connection timeout attempt {attempt}", max_retries=5)
        assert st == "pending"
        with store.db() as db:
            row = db.execute("SELECT retry_count, status FROM matter_outbox WHERE id=?", (outbox_id,)).fetchone()
            assert row["retry_count"] == attempt
            assert row["status"] == "pending"

    # 5th failure must trip the circuit breaker and transition to 'dlq'
    final_st = store.mark_outbox_retry(outbox_id, "Connection timeout attempt 5 (fatal)", max_retries=5)
    assert final_st == "dlq"

    with store.db() as db:
        row = db.execute("SELECT retry_count, status FROM matter_outbox WHERE id=?", (outbox_id,)).fetchone()
        assert row["retry_count"] == 5
        assert row["status"] == "dlq"

    # Verify DLQ item is NOT in list_pending_outbox
    pending_after = store.list_pending_outbox(limit=100)
    matching_after = [item for item in pending_after if item["id"] == outbox_id]
    assert len(matching_after) == 0, "DLQ item must not be included in pending outbox list"

    # Further retries stay in dlq
    st_overflow = store.mark_outbox_retry(outbox_id, "Attempt 6", max_retries=5)
    assert st_overflow == "dlq"


def test_scenario_d2_http_503_circuit_breaker_contract():
    """Scenario D2: Verify 503 response generated by build_503_timeout_response complies with PRD:
    - Status code 503
    - Retry-After: 3
    - body fields: outbox_queued, outbox_id, pending_sync, circuit_breaker block
    """
    mid = generate_matter_id()
    resp = app_module.build_503_timeout_response(
        matter_id=mid,
        outbox_id=777,
        error_detail="iCloud vault offline or timeout tripped",
    )
    assert resp.status_code == 503
    assert resp.headers.get("retry-after") == "3"

    body = json.loads(resp.body.decode("utf-8"))
    assert body["ok"] is False
    assert body["error"] == "service_unavailable"
    assert "iCloud" in body["detail"]
    assert body["retry_after"] == 3
    assert body["outbox_queued"] is True
    assert body["outbox_id"] == 777
    assert body["matter_id"] == mid
    assert body["pending_sync"] is True
    assert body["circuit_breaker"]["status"] == "tripped"
    assert body["circuit_breaker"]["timeout_seconds"] == 8
    assert body["circuit_breaker"]["target"] == "icloud_vault"


# ===========================================================================
# SCENARIO E: Concurrency deadlocks & CrossEventLoopAsyncLock stress testing
# ===========================================================================

def test_scenario_e1_cross_event_loop_async_lock_mutual_exclusion():
    """Scenario E1: 30 independent threads each with their own asyncio event loop,
    competing for a single CrossEventLoopAsyncLock.
    Each thread performs 20 iterations incrementing and decrementing a shared critical counter.
    Verify strict mutual exclusion (counter never exceeds 1 or dips below 0) and zero deadlocks.
    """
    lock = CrossEventLoopAsyncLock()
    active_in_critical = 0
    max_active_seen = 0
    total_executions = 0
    test_lock = threading.Lock()

    worker_count = 30
    iterations_per_worker = 20

    def thread_worker():
        nonlocal active_in_critical, max_active_seen, total_executions

        async def worker_loop():
            nonlocal active_in_critical, max_active_seen, total_executions
            for _ in range(iterations_per_worker):
                async with lock:
                    with test_lock:
                        active_in_critical += 1
                        if active_in_critical > max_active_seen:
                            max_active_seen = active_in_critical
                    # Small yield to let any competing coroutines/threads attempt access
                    await asyncio.sleep(0.0005)
                    with test_lock:
                        assert active_in_critical == 1, f"Lock invariant violated! active={active_in_critical}"
                        active_in_critical -= 1
                        total_executions += 1

        asyncio.run(worker_loop())

    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as pool:
        futures = [pool.submit(thread_worker) for _ in range(worker_count)]
        for f in futures:
            f.result(timeout=15)  # If it deadlocks, this raises TimeoutError

    assert max_active_seen == 1, f"Expected strictly max 1 thread in critical section, saw {max_active_seen}"
    assert active_in_critical == 0
    assert total_executions == worker_count * iterations_per_worker


def test_scenario_e2_lock_release_on_exception():
    """Scenario E2: Verify that CrossEventLoopAsyncLock releases correctly when an exception
    is raised inside the `async with` block, preventing deadlock on subsequent acquisitions.
    """
    lock = CrossEventLoopAsyncLock()

    async def fail_task():
        try:
            async with lock:
                raise ValueError("Deliberate failure inside lock")
        except ValueError:
            pass

    async def succeed_task():
        async with lock:
            return "recovered"

    async def run_scenario():
        await fail_task()
        res = await succeed_task()
        assert res == "recovered"

    asyncio.run(run_scenario())


def test_scenario_e3_get_matter_lock_concurrent_initialization():
    """Scenario E3: 40 threads simultaneously calling get_matter_lock for the same matter_id.
    Verify all threads receive the exact same lock instance and no race condition occurs.
    """
    test_mid = "mtr-test-lock-singleton-id"

    def get_lock_worker():
        async def fetch():
            return await app_module.get_matter_lock(test_mid)
        return asyncio.run(fetch())

    worker_count = 40
    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as pool:
        futures = [pool.submit(get_lock_worker) for _ in range(worker_count)]
        locks = [f.result(timeout=5) for f in futures]

    first_lock = locks[0]
    for idx, lk in enumerate(locks[1:], start=1):
        assert lk is first_lock, f"Thread {idx} got a different lock instance!"


# ===========================================================================
# SCENARIO F: Comprehensive 11-State FSM Topology & Illegal Transition Guard
# ===========================================================================

def test_scenario_f_11_state_exhaustive_illegal_transitions():
    """Scenario F: Exhaustively test illegal transitions from each of the 11 states.
    Attempt transitions NOT in VALID_TRANSITIONS and verify MatterIllegalTransition is raised.
    """
    store = app_module.personal_board.matter_store

    all_states = sorted(list(FSM_STATES))
    assert len(all_states) == 11, f"Expected exactly 11 states, got {len(all_states)}"

    for src_state in all_states:
        allowed = VALID_TRANSITIONS.get(src_state, set())
        disallowed = set(all_states) - allowed - {src_state}  # self-transition usually illegal or not defined in graph

        for target in disallowed:
            mid = generate_matter_id()
            m = store.create_matter(
                title=f"FSM guard {src_state} -> {target}",
                source_type="test",
                status=src_state,
                matter_id=mid,
            )
            with pytest.raises(MatterIllegalTransition) as exc_info:
                store.transition_status(mid, target, expected_rev=m.rev)
            assert f"Illegal transition from '{src_state}' to '{target}'" in str(exc_info.value)
