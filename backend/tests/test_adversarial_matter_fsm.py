"""Empirical Adversarial Stress Harness for UnifiedMatterEntity and PersonalBoard FSM.

Adversarial Challenger Test Suite:
1. Complete 11x11 pairwise FSM state transition matrix verification (illegal jumps strictly rejected).
2. Unknown and malformed target state rejection.
3. Multi-threaded race conditions and optimistic locking under high contention (SQLite WAL).
4. Stale revision detection (HTTP 409 MatterConflict / BoardConflict).
5. Rapid sequential transitions monotonic revision invariance.
6. SQL injection, path traversal, null-byte, and oversized input fuzzing against matter_id.
7. Truncation and boundary safety on title (100 char) and why (200 char).
8. PersonalBoard.move concurrent race attacks and idempotent op_id replay under pressure.
"""
from __future__ import annotations

import asyncio
import concurrent.futures
import json
import sqlite3
import tempfile
import time
from pathlib import Path

import pytest

from board import (
    BoardBadRequest,
    BoardConflict,
    BoardError,
    BoardTimeout,
    PersonalBoard,
)
from matter_schema import (
    FSM_STATES,
    VALID_TRANSITIONS,
    MatterConflict,
    MatterError,
    MatterIllegalTransition,
    MatterNotFound,
    MatterStore,
    UnifiedMatterEntity,
    generate_matter_id,
    validate_matter_id,
)
from next_steps import NextSteps
from today import Today


# ---------------------------------------------------------------------------
# Fixtures and Helpers
# ---------------------------------------------------------------------------

@pytest.fixture
def temp_store(tmp_path: Path):
    db_file = tmp_path / "adversarial_matter.sqlite"
    return MatterStore(db_file)


def _setup_board(tmp_path: Path, clock_func=time.time):
    root = tmp_path / "vault"
    pending = root / "任务" / "待处理"
    pending.mkdir(parents=True, exist_ok=True)
    (root / "任务" / "已完成").mkdir(parents=True, exist_ok=True)
    state = tmp_path / "state"
    state.mkdir(exist_ok=True)

    today = Today(None, None, root, clock=clock_func)
    ns = NextSteps(state, vault=root, clock=clock_func)
    board = PersonalBoard(state, today, ns, None, clock=clock_func)
    return board, today, ns, root


# ---------------------------------------------------------------------------
# 1. Complete Pairwise FSM Transition Matrix (121 Combinations)
# ---------------------------------------------------------------------------

def test_adversarial_complete_pairwise_fsm_transitions(temp_store: MatterStore):
    """Stress test all 11x11 = 121 state transition combinations.
    Every transition NOT in VALID_TRANSITIONS must raise MatterIllegalTransition.
    Every transition IN VALID_TRANSITIONS must succeed, update state, and increment rev.
    """
    assert len(FSM_STATES) == 11, f"Expected 11 FSM states, found {len(FSM_STATES)}"

    for from_state in sorted(FSM_STATES):
        allowed = VALID_TRANSITIONS.get(from_state, set())
        disallowed = FSM_STATES - allowed

        # 1. Test each disallowed transition
        for illegal_target in sorted(disallowed):
            m = temp_store.create_matter(
                title=f"Testing illegal {from_state}->{illegal_target}",
                source_type="manual",
                status=from_state,
            )
            initial_rev = m.rev
            initial_status = m.status

            with pytest.raises(MatterIllegalTransition, match=r"Illegal transition|Invalid target"):
                temp_store.transition_status(m.matter_id, illegal_target, expected_rev=initial_rev)

            # Empirical check: Verify entity in DB was untouched
            persisted = temp_store.get_by_id(m.matter_id)
            assert persisted is not None
            assert persisted.status == initial_status, f"State mutated on illegal jump {from_state}->{illegal_target}"
            assert persisted.rev == initial_rev, f"Rev mutated on illegal jump {from_state}->{illegal_target}"

        # 2. Test each allowed transition
        for legal_target in sorted(allowed):
            m = temp_store.create_matter(
                title=f"Testing legal {from_state}->{legal_target}",
                source_type="manual",
                status=from_state,
            )
            initial_rev = m.rev
            updated = temp_store.transition_status(m.matter_id, legal_target, expected_rev=initial_rev)
            assert updated.status == legal_target
            assert updated.rev == initial_rev + 1

            persisted = temp_store.get_by_id(m.matter_id)
            assert persisted is not None
            assert persisted.status == legal_target
            assert persisted.rev == initial_rev + 1


def test_adversarial_unknown_target_states(temp_store: MatterStore):
    """Attempt transition to completely bogus states."""
    m = temp_store.create_matter("Bogus State Attack", "manual", status="suggested")
    bogus_states = [
        "hacked",
        "UNKNOWN",
        "deleted",
        "",
        "   ",
        "executing_now",
        "pending",
        "in_progress",  # Note: PRD uses 'doing', not 'in_progress'
        "done_forever",
        "None",
    ]
    for bs in bogus_states:
        with pytest.raises(MatterIllegalTransition):
            temp_store.transition_status(m.matter_id, bs)

        # Entity rev must not change
        assert temp_store.get_by_id(m.matter_id).rev == 1


# ---------------------------------------------------------------------------
# 2. High-Concurrency Multi-Threaded Contention & Stale Rev Conflicts (409)
# ---------------------------------------------------------------------------

def test_adversarial_concurrent_race_optimistic_lock(temp_store: MatterStore):
    """20 threads concurrently attempt to transition the SAME matter from suggested to todo.
    With expected_rev=1, exactly ONE thread must succeed (rev becomes 2).
    The remaining 19 threads MUST receive MatterConflict (HTTP 409 equivalent).
    """
    m = temp_store.create_matter("High Concurrency Race", "manual", status="suggested")
    matter_id = m.matter_id
    concurrency = 20

    success_count = 0
    conflict_count = 0
    other_errors = []

    def worker_transition():
        # Each thread uses a fresh connection via store.db() inside transition_status
        return temp_store.transition_status(matter_id, "todo", expected_rev=1)

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(worker_transition) for _ in range(concurrency)]
        for fut in concurrent.futures.as_completed(futures):
            try:
                res = fut.result()
                if res.status == "todo" and res.rev == 2:
                    success_count += 1
            except MatterConflict:
                conflict_count += 1
            except Exception as e:
                other_errors.append(e)

    assert len(other_errors) == 0, f"Unexpected exceptions during concurrency: {other_errors}"
    assert success_count == 1, f"Expected exactly 1 success, got {success_count}"
    assert conflict_count == concurrency - 1, f"Expected {concurrency - 1} conflicts, got {conflict_count}"

    # Verify final entity in database
    final_entity = temp_store.get_by_id(matter_id)
    assert final_entity.status == "todo"
    assert final_entity.rev == 2


def test_adversarial_concurrent_update_matter_race(temp_store: MatterStore):
    """20 threads concurrently attempt non-status field updates on the same matter with expected_rev=1.
    Exactly ONE update must succeed, 19 must raise MatterConflict.
    """
    m = temp_store.create_matter("Update Matter Race", "manual", status="suggested")
    matter_id = m.matter_id
    concurrency = 20

    success_count = 0
    conflict_count = 0
    other_errors = []

    def worker_update(idx: int):
        return temp_store.update_matter(
            matter_id,
            expected_rev=1,
            title=f"Updated by worker {idx}",
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(worker_update, i) for i in range(concurrency)]
        for fut in concurrent.futures.as_completed(futures):
            try:
                res = fut.result()
                if res.rev == 2:
                    success_count += 1
            except MatterConflict:
                conflict_count += 1
            except Exception as e:
                other_errors.append(e)

    assert len(other_errors) == 0, f"Unexpected exceptions: {other_errors}"
    assert success_count == 1
    assert conflict_count == concurrency - 1

    final_entity = temp_store.get_by_id(matter_id)
    assert final_entity.rev == 2


def test_adversarial_stale_revision_rejections(temp_store: MatterStore):
    """Test stale revision rejections on old and future rev values."""
    m = temp_store.create_matter("Stale Rev Test", "manual", status="suggested")
    # Advance to rev 5
    m = temp_store.transition_status(m.matter_id, "todo", expected_rev=1)
    m = temp_store.transition_status(m.matter_id, "doing", expected_rev=2)
    m = temp_store.transition_status(m.matter_id, "done", expected_rev=3)
    m = temp_store.transition_status(m.matter_id, "suggested", expected_rev=4)
    assert m.rev == 5

    # Test stale past revs: 1, 2, 3, 4
    for old_rev in [1, 2, 3, 4]:
        with pytest.raises(MatterConflict, match=r"VERSION_CONFLICT_409"):
            temp_store.transition_status(m.matter_id, "todo", expected_rev=old_rev)

    # Test future invalid revs: 6, 10, 999
    for future_rev in [6, 10, 999]:
        with pytest.raises(MatterConflict, match=r"VERSION_CONFLICT_409"):
            temp_store.transition_status(m.matter_id, "todo", expected_rev=future_rev)

    # Valid rev=5 succeeds
    m = temp_store.transition_status(m.matter_id, "todo", expected_rev=5)
    assert m.rev == 6


def test_adversarial_rapid_sequential_cycle_rev_monotonicity(temp_store: MatterStore):
    """Execute 50 rapid state transitions through legal cycle loops.
    Verify rev increments monotonically from 1 to 51 with 0 errors or gaps.
    """
    m = temp_store.create_matter("Monotonic Rev Cycle", "manual", status="suggested")
    assert m.rev == 1

    cycle = ["todo", "doing", "done", "suggested"]
    steps = 48  # 12 full cycles of 4 steps each
    for i in range(steps):
        target = cycle[i % len(cycle)]
        m = temp_store.transition_status(m.matter_id, target, expected_rev=m.rev)
        assert m.rev == i + 2
        assert m.status == target

    assert m.rev == 49
    persisted = temp_store.get_by_id(m.matter_id)
    assert persisted.rev == 49


# ---------------------------------------------------------------------------
# 3. Input Fuzzing, Injection & Boundary Attacks
# ---------------------------------------------------------------------------

def test_adversarial_matter_id_validation_fuzzing():
    """Attack validate_matter_id with malicious payloads, null bytes, long buffers, SQLi."""
    valid_ids = [
        "mtr-20261106-a8f9c2d1",
        "mtr-20260101-12345678",
        "mtr-19991231-abcdef012345",
    ]
    for vid in valid_ids:
        assert validate_matter_id(vid) is True, f"Valid ID rejected: {vid}"

    malicious_payloads = [
        # SQL Injections
        "mtr-20261106-a'; DROP TABLE matter_state; --",
        "' OR '1'='1",
        "mtr-20261106-a' UNION SELECT * FROM matter_state--",
        # Path Traversals
        "../../../../../../etc/passwd",
        "mtr-20261106-../../etc/passwd",
        # Null bytes & shell escapes
        "mtr-20261106-ab\x00cd",
        "mtr-20261106-$(rm -rf /)",
        "`touch /tmp/pwned`",
        # Malformed format / prefixes
        "todo:12345678",
        "next:abcdef1234567890",
        "mtr-2026110-12345678",  # only 7 digits date
        "mtr-202611067-12345678",  # 9 digits date
        "mtr-20261106-short",  # < 8 chars hash
        "mtr-20261106-waytoolonghexstring1234567890",  # > 12 chars hash
        "MTR-20261106-A8F9C2D1",  # uppercase
        # Buffer overflow / huge string
        "mtr-20261106-" + ("a" * 100000),
        # Non-string primitives
        None,
        12345678,
        3.14159,
        ["mtr-20261106-a8f9c2d1"],
        {"matter_id": "mtr-20261106-a8f9c2d1"},
    ]
    for payload in malicious_payloads:
        assert validate_matter_id(payload) is False, f"Malicious payload accepted: {payload!r}"


def test_adversarial_sqli_resilience_in_store(temp_store: MatterStore):
    """Test SQL injection attacks on MatterStore queries (get_by_id, transition_status)."""
    sqli_targets = [
        "mtr-20261106-a'; DROP TABLE matter_state; --",
        "' OR 1=1 --",
        "nonexistent' UNION SELECT * FROM matter_state --",
    ]
    for sqli in sqli_targets:
        # get_by_id should return None, not crash or execute injection
        assert temp_store.get_by_id(sqli) is None

        # transition_status should raise MatterNotFound
        with pytest.raises(MatterNotFound):
            temp_store.transition_status(sqli, "todo")

    # Verify table is still intact and functional
    m = temp_store.create_matter("Post SQLi Survival", "manual", status="suggested")
    assert m.matter_id.startswith("mtr-")
    assert temp_store.get_by_id(m.matter_id) is not None


def test_adversarial_field_boundary_truncation_and_unicode(temp_store: MatterStore):
    """Test oversized titles, why strings, and complex unicode/emojis.
    matter_schema defines title[:100] and why[:200].
    """
    huge_title = "🔥【超长任务】" + ("测" * 500)
    huge_why = "由于" + ("原" * 1000)
    special_source_ref = {
        "ident": "mail:999",
        "summary": "包含特殊字符: <script>alert('xss')</script> & 'quotes' \"double\"",
        "complex_tree": {"a": [1, 2, {"b": True, "c": None}]},
    }

    m = temp_store.create_matter(
        title=huge_title,
        source_type="mail",
        why=huge_why,
        source_ref=special_source_ref,
        status="suggested",
    )

    # Verify title is cleanly truncated to 100 chars
    assert len(m.title) == 100
    assert m.title.startswith("🔥【超长任务】")

    # Verify why is cleanly truncated to 200 chars
    assert len(m.why) == 200
    assert m.why.startswith("由于")

    # Verify roundtrip through SQLite
    persisted = temp_store.get_by_id(m.matter_id)
    assert len(persisted.title) == 100
    assert len(persisted.why) == 200
    assert persisted.source_ref["summary"] == special_source_ref["summary"]
    assert persisted.source_ref["complex_tree"]["a"][2]["b"] is True


# ---------------------------------------------------------------------------
# 4. PersonalBoard Adversarial Attacks
# ---------------------------------------------------------------------------

def test_adversarial_board_move_malformed_inputs(tmp_path: Path):
    """Adversarial attacks on PersonalBoard.move() inputs:
    Missing request_id, missing matter_id/card, invalid target columns, non-integer rev.
    """
    board, today, ns, vault = _setup_board(tmp_path)

    async def run_attacks():
        # 1. Missing request_id
        with pytest.raises(BoardBadRequest, match=r"缺少 request_id"):
            await board.move({"card": "mtr-20261106-a8f9c2d1", "to": "todo"})

        with pytest.raises(BoardBadRequest, match=r"缺少 request_id"):
            await board.move({"request_id": "", "card": "mtr-20261106-a8f9c2d1", "to": "todo"})

        # 2. Invalid target 'to' column
        # Unified matters reject bogus/empty target states as 非法移动
        for bad_to in ["bogus", "invalid_state", ""]:
            with pytest.raises(BoardBadRequest, match=r"非法移动"):
                await board.move({"request_id": "req-1", "card": "mtr-20261106-a8f9c2d1", "to": bad_to})

        # Legacy cards reject non-5-column states as 非法移动
        for bad_legacy_to in ["executing", "waiting_input", "error_blocked", "bogus", ""]:
            with pytest.raises(BoardBadRequest, match=r"非法移动"):
                await board.move({"request_id": "req-leg-1", "card": "todo:legacy-001", "to": bad_legacy_to})

        # 3. Non-existent matter_id
        with pytest.raises(BoardBadRequest, match=r"事项不存在"):
            await board.move({
                "request_id": "req-nonexistent",
                "card": "mtr-20261106-nonexistent",
                "to": "todo",
                "rev": 1,
            })

    asyncio.run(run_attacks())


def test_adversarial_board_move_concurrent_race_and_idempotency(tmp_path: Path):
    """Concurrently hit PersonalBoard.move with:
    1. Multiple distinct request_ids competing for the same matter: exactly 1 succeeds, others 409 BoardConflict.
    2. Multiple identical request_ids replaying the same operation: all return identical cached output.
    """
    board, today, ns, vault = _setup_board(tmp_path)

    # Seed a matter into board's matter_store
    m = board.matter_store.create_matter("Concurrent Board Move", "manual", status="suggested")
    matter_id = m.matter_id

    async def run_concurrent_distinct_moves():
        concurrency = 8
        results = []
        conflicts = 0

        async def worker(idx: int):
            return await board.move({
                "request_id": f"op-concurrent-{idx}",
                "card": matter_id,
                "matter_id": matter_id,
                "to": "todo",
                "rev": 1,
            })

        tasks = [worker(i) for i in range(concurrency)]
        outcomes = await asyncio.gather(*tasks, return_exceptions=True)
        for out in outcomes:
            if isinstance(out, dict) and out.get("ok"):
                results.append(out)
            elif isinstance(out, BoardConflict):
                conflicts += 1
            else:
                raise AssertionError(f"Unexpected outcome: {out}")

        assert len(results) == 1, f"Expected exactly 1 successful move, got {len(results)}"
        assert conflicts == concurrency - 1, f"Expected {concurrency - 1} BoardConflicts, got {conflicts}"

    asyncio.run(run_concurrent_distinct_moves())

    # Verify idempotent request_id replay
    async def run_idempotency_replay():
        # The winning op (op-concurrent-X) was saved in board_ops.
        # Now replay with the SAME op_id repeatedly:
        replay_res1 = await board.move({
            "request_id": "op-idempotent-test",
            "card": matter_id,
            "matter_id": matter_id,
            "to": "doing",
            "rev": 2,
        })
        assert replay_res1["ok"] is True
        assert replay_res1["matter"]["status"] == "doing"
        assert replay_res1["matter"]["rev"] == 3

        # Replay 5 times with identical request_id:
        for _ in range(5):
            cached = await board.move({
                "request_id": "op-idempotent-test",
                "card": matter_id,
                "matter_id": matter_id,
                "to": "done",  # Even with different parameters, op_id cache takes precedence!
                "rev": 999,
            })
            assert cached["ok"] is True
            assert cached["matter"]["status"] == "doing"
            assert cached["matter"]["rev"] == 3

        # Verify matter in DB stayed at rev=3, status=doing (not changed to done)
        persisted = board.matter_store.get_by_id(matter_id)
        assert persisted.status == "doing"
        assert persisted.rev == 3

    asyncio.run(run_idempotency_replay())


# ---------------------------------------------------------------------------
# 5. Outbox Engine Durability
# ---------------------------------------------------------------------------

def test_adversarial_outbox_ordering_and_durability(temp_store: MatterStore):
    """Stress test outbox queue with 50 sequential events, verify FIFO order and completion."""
    mid = generate_matter_id()
    event_ids = []
    for i in range(50):
        eid = temp_store.create_outbox_event(mid, "state_change", {"step": i, "payload": "data" * 10})
        event_ids.append(eid)

    # IDs must be strictly increasing
    assert event_ids == sorted(event_ids)
    assert len(event_ids) == 50

    # Read pending outbox with limit
    batch1 = temp_store.list_pending_outbox(limit=20)
    assert len(batch1) == 20
    assert batch1[0]["id"] == event_ids[0]
    assert batch1[0]["payload"]["step"] == 0

    # Mark first 20 done
    for item in batch1:
        temp_store.mark_outbox_done(item["id"])

    # Next batch should start at step 20
    batch2 = temp_store.list_pending_outbox(limit=20)
    assert len(batch2) == 20
    assert batch2[0]["payload"]["step"] == 20

    # Mark remaining done
    for item in temp_store.list_pending_outbox(limit=100):
        temp_store.mark_outbox_done(item["id"])

    assert len(temp_store.list_pending_outbox()) == 0


def test_adversarial_board_move_rev_desync_on_obsidian_binding(tmp_path: Path):
    """Bug reproduction test:
    When board.move transitions a card to 'todo' with next_to_todo, transition_status increments
    rev to 2, then update_matter increments rev to 3 for obsidian_binding.
    However, board._move_unified_matter returns the stale 'updated' object (rev 2) in response['matter']!
    As a result, any subsequent client move using the returned rev immediately fails with 409 BoardConflict!
    """
    board, today, ns, vault = _setup_board(tmp_path)

    m = board.matter_store.create_matter("测试两步连续移动", "manual", status="suggested")
    assert m.rev == 1

    async def next_to_todo(ident, day=None, remind_at=None, state="待处理"):
        made = today.todo_create("测试两步连续移动", "2026-11-06", "", "", "", ident)
        return {"status": "completed", "todo": made}

    async def run():
        # Move 1: suggest -> todo
        r1 = await board.move({
            "request_id": "op-step1",
            "matter_id": m.matter_id,
            "to": "todo",
            "rev": 1,
        }, next_to_todo=next_to_todo)

        returned_rev = r1["matter"]["rev"]
        db_entity = board.matter_store.get_by_id(m.matter_id)

        # Invariance: returned rev in API response must match authoritative rev in SQLite
        assert returned_rev == db_entity.rev, (
            f"Desync detected: returned rev {returned_rev} != db rev {db_entity.rev}"
        )

        # Move 2: client moves todo -> doing using the returned_rev
        r2 = await board.move({
            "request_id": "op-step2",
            "matter_id": m.matter_id,
            "to": "doing",
            "rev": returned_rev,
        })
        assert r2["ok"] is True
        assert r2["matter"]["status"] == "doing"

    asyncio.run(run())

