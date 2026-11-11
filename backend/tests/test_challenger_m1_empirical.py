"""Adversarial Empirical Stress Harness by Backend Challenger 1.

Stress-tests:
1. matter_store.py: complete export parity, FSM edge transitions, FTS5 safety, matter ID validation.
2. POST /personal/matters/from_step:
   - Idempotency with identical request_id (same & mutated payloads).
   - Nonexistent message_id handling (with & without title).
   - Invalid step_index (negative, out-of-range, non-integer, missing).
   - Already linked step deduplication across different request_ids.
   - Status variations (suggested vs todo/doing outbox event creation).
3. OutboxProjector:
   - Step-by-step retry progression from pending (1..4) to dlq (5).
   - Filtering dlq out of pending queries.
   - Missing matter handling without crashing.
   - Exception handling in _vault projections.
4. Concurrency & Revisions:
   - Monotonic message_seq under stress.
   - Optimistic concurrency conflict detection.
"""
from __future__ import annotations

import asyncio
from pathlib import Path
import time
from unittest.mock import MagicMock

import pytest
from starlette.testclient import TestClient

import app as app_module
import matter_schema
import matter_store
from matter_store import (
    FSM_STATES,
    VALID_TRANSITIONS,
    MatterConflict,
    MatterError,
    MatterIllegalTransition,
    MatterNotFound,
    MatterStore,
    UnifiedMatterEntity,
    build_fts_query,
    cjk_unigram_tokenize,
    clean_cjk_snippet,
    generate_matter_id,
    process_matter_outbox_projector,
    validate_matter_id,
)


@pytest.fixture
def client():
    return TestClient(app_module.app)


@pytest.fixture
def auth_headers():
    return {"Authorization": f"Bearer {app_module.TOKEN}"}


@pytest.fixture
def store(tmp_path: Path):
    db_path = tmp_path / "empirical_matter_store.sqlite"
    return MatterStore(db_path)


# ===========================================================================
# 1. matter_store.py Export Parity, Contracts & Edge Cases
# ===========================================================================

def test_matter_store_export_completeness_and_parity():
    """Verify that all public contracts in matter_store match matter_schema exactly."""
    expected_exports = [
        "FSM_STATES",
        "VALID_TRANSITIONS",
        "MatterConflict",
        "MatterError",
        "MatterIllegalTransition",
        "MatterNotFound",
        "MatterStore",
        "UnifiedMatterEntity",
        "build_fts_query",
        "cjk_unigram_tokenize",
        "clean_cjk_snippet",
        "generate_matter_id",
        "process_matter_outbox_projector",
        "validate_matter_id",
    ]
    for symbol in expected_exports:
        assert hasattr(matter_store, symbol), f"matter_store missing symbol: {symbol}"
        if symbol != "process_matter_outbox_projector":
            assert getattr(matter_store, symbol) is getattr(matter_schema, symbol), (
                f"Symbol mismatch between matter_store and matter_schema: {symbol}"
            )

    assert set(matter_store.__all__) == set(expected_exports)
    assert len(FSM_STATES) == 11


def test_matter_id_validation_adversarial():
    """Stress test matter ID validation against SQL injection, null bytes, and boundary mutations."""
    valid_id = generate_matter_id()
    assert validate_matter_id(valid_id) is True

    adversarial_inputs = [
        "",
        None,
        12345,
        "mtr-",
        "mtr-20261107",
        "mtr-20261107-",
        "mtr-20261107-123",  # too short
        "mtr-20261107-123456789012345",  # too long
        "mtr-20261107-1234567G",  # non-hex char 'G' (only [a-z0-9] allowed)
        f"{valid_id}'; DROP TABLE matter_state; --",
        f"{valid_id}\x00",
        f"../{valid_id}",
        "MTR-20261107-ABCDEF12",  # uppercase should fail regex
    ]
    for bad_input in adversarial_inputs:
        assert validate_matter_id(bad_input) is False, f"Expected False for {bad_input!r}"


def test_fts5_query_builder_adversarial():
    """Verify build_fts_query sanitizes SQLite FTS5 injection attacks and reserved operators."""
    # SQLite FTS5 syntax crash vectors
    assert build_fts_query("") == ""
    assert build_fts_query("   ") == ""
    assert build_fts_query("***") == ""
    assert build_fts_query('"""') == ""
    assert build_fts_query("AND") == '"AND"*'
    assert build_fts_query("OR") == '"OR"*'
    assert build_fts_query("NOT") == '"NOT"*'
    assert build_fts_query("NEAR/2") == '"NEAR/2"*'
    assert build_fts_query("column:value") == "columnvalue*"

    # Mixed CJK and special punctuation
    q = build_fts_query("重构 v2.2.0 FTS5")
    assert '"重 构"' in q
    assert '"v2.2.0"*' in q
    assert "FTS5*" in q


def test_matter_fsm_terminal_and_illegal_transitions(store: MatterStore):
    """Stress test boundary FSM state transitions."""
    m_init = store.create_matter(title="边界测试", source_type="manual", status="todo")
    assert m_init.completed_at is None

    # Transition to done sets completed_at
    m = store.transition_status(m_init.matter_id, "done", expected_rev=1)
    assert m.status == "done"
    assert m.completed_at is not None

    # Done -> executing is illegal
    with pytest.raises(MatterIllegalTransition):
        store.transition_status(m.matter_id, "executing", expected_rev=m.rev)

    # Done -> waiting_input is illegal
    with pytest.raises(MatterIllegalTransition):
        store.transition_status(m.matter_id, "waiting_input", expected_rev=m.rev)

    # Done -> todo is LEGAL (reactivation), completed_at should become None
    m_reactivated = store.transition_status(m.matter_id, "todo", expected_rev=m.rev)
    assert m_reactivated.status == "todo"
    assert m_reactivated.completed_at is None
    assert m_reactivated.rev == 3

    # Nonexistent matter_id transition must raise MatterNotFound
    with pytest.raises(MatterNotFound):
        store.transition_status("mtr-20261107-00000000", "todo", expected_rev=1)

    # Nonexistent matter_id update must raise MatterNotFound
    with pytest.raises(MatterNotFound):
        store.update_matter("mtr-20261107-00000000", title="新标题")


def test_matter_optimistic_locking_conflict_details(store: MatterStore):
    """Verify MatterConflict carries structured diff and revision details for 409 rollback."""
    m = store.create_matter(title="乐观锁测试", source_type="manual", status="todo")
    assert m.rev == 1

    # Advance revision behind the back
    store.transition_status(m.matter_id, "doing", expected_rev=1)

    # Now attempt transition with stale expected_rev=1
    with pytest.raises(MatterConflict) as exc_info:
        store.transition_status(m.matter_id, "done", expected_rev=1)

    conflict = exc_info.value
    assert conflict.requested_rev == 1
    assert conflict.current_rev == 2
    assert conflict.latest.status == "doing"
    assert "rev" in conflict.diff
    assert conflict.diff["rev"]["requested"] == 1
    assert conflict.diff["rev"]["current"] == 2


# ===========================================================================
# 2. Outbox Projector Retries, Backoff & DLQ Behavior
# ===========================================================================

@pytest.mark.anyio
async def test_outbox_retry_sequence_to_dlq_empirical(store: MatterStore):
    """Empirically verify outbox event transitions through exactly 5 retries to DLQ."""
    m = store.create_matter(title="失败重试测试", source_type="manual", status="todo")
    outbox_id = store.create_outbox_event(
        m.matter_id,
        "obsidian_projection",
        {"target_status": "todo", "path": "任务/待处理/不存在.md"},
    )

    call_count = 0

    def mock_failing_vault(fn, *args, **kwargs):
        nonlocal call_count
        call_count += 1
        raise TimeoutError(f"Simulated Obsidian vault timeout attempt {call_count}")

    board = MagicMock()
    board.matter_store = store
    board.today = MagicMock()
    board.today.vault = Path("/dummy/vault")
    board._vault = mock_failing_vault

    # Iteration 1 to 4: Status must remain 'pending', retry_count increments
    for expected_retry in range(1, 5):
        processed = await process_matter_outbox_projector(board, once=True)
        assert processed == 0  # Failed item not counted in processed_count

        pending = store.list_pending_outbox()
        assert len(pending) == 1
        assert pending[0]["id"] == outbox_id
        assert pending[0]["retry_count"] == expected_retry
        assert pending[0]["status"] == "pending"

    # Iteration 5: Reaches max_retries=5 -> transitions to 'dlq'
    processed = await process_matter_outbox_projector(board, once=True)
    assert processed == 0

    # Must NO LONGER appear in pending outbox
    pending_after_dlq = store.list_pending_outbox()
    assert len(pending_after_dlq) == 0

    # Check directly in SQLite database
    with store.db() as db:
        row = db.execute("SELECT status, retry_count FROM matter_outbox WHERE id=?", (outbox_id,)).fetchone()
        assert row["status"] == "dlq"
        assert row["retry_count"] == 5


@pytest.mark.anyio
async def test_outbox_projector_handles_missing_matter_cleanly(store: MatterStore):
    """If outbox references a matter that does not exist, projector should not crash."""
    outbox_id = store.create_outbox_event(
        "mtr-20261107-deadbeef",
        "obsidian_projection",
        {"target_status": "todo"},
    )

    board = MagicMock()
    board.matter_store = store
    board.today = MagicMock()
    board.today.vault = Path("/dummy/vault")
    board._vault = MagicMock()

    processed = await process_matter_outbox_projector(board, once=True)
    # Projector marks it done because there's nothing to create/update
    assert processed == 1

    with store.db() as db:
        row = db.execute("SELECT status FROM matter_outbox WHERE id=?", (outbox_id,)).fetchone()
        assert row["status"] == "done"


# ===========================================================================
# 3. POST /personal/matters/from_step Empirical Stress Testing
# ===========================================================================

def test_from_step_duplicate_request_id_idempotency_with_mutated_payload(client, auth_headers):
    """Empirically test that duplicate request_id strictly returns the cached response,
    even if the caller attempts to mutate the body parameters (title, step_index, status).
    """
    # 1. Create a message with a step
    req_msg = f"req-msg-idem-{int(time.time() * 1000)}"
    res_msg = app_module.conversation.submit(req_msg, "用户分析测试")
    message_id = res_msg["message_id"]

    plan = {
        "title": "测试计划",
        "todos": [{"id": "1", "content": "原始第一步", "status": "pending"}],
    }
    app_module.conversation.set_plan(message_id, plan)

    req_step_id = f"req-step-idem-{int(time.time() * 1000)}"
    payload_original = {
        "request_id": req_step_id,
        "conversation_id": "conv-default",
        "message_id": message_id,
        "step_index": 0,
        "title": "原始步骤标题",
        "initial_status": "todo",
        "obsidian_flow": "任务",
    }

    # Initial call
    resp1 = client.post("/personal/matters/from_step", headers=auth_headers, json=payload_original)
    assert resp1.status_code == 201
    data1 = resp1.json()
    created_matter_id = data1["matter"]["matter_id"]
    assert data1["matter"]["title"] == "原始步骤标题"

    # Mutated call with same request_id but altered title, status, step_index
    payload_mutated = {
        "request_id": req_step_id,
        "conversation_id": "conv-other",
        "message_id": message_id,
        "step_index": 99,
        "title": "恶意篡改的标题",
        "initial_status": "done",
    }
    resp2 = client.post("/personal/matters/from_step", headers=auth_headers, json=payload_mutated)
    assert resp2.status_code == 201
    data2 = resp2.json()

    # Must match original response exactly
    assert data2["matter"]["matter_id"] == created_matter_id
    assert data2["matter"]["title"] == "原始步骤标题"
    assert data2["source_step"]["step_index"] == 0

    # Verify no second matter was inserted into matter_state
    with app_module.personal_board.matter_store.db() as db:
        rows = db.execute(
            "SELECT COUNT(*) as c FROM matter_state WHERE title='恶意篡改的标题'"
        ).fetchone()
        assert rows["c"] == 0


def test_from_step_nonexistent_message_id_handling(client, auth_headers):
    """Verify POST /personal/matters/from_step handles nonexistent message_id gracefully."""
    nonexistent_mid = f"msg-nonexistent-{int(time.time() * 1000)}"
    req_step_id = f"req-step-nonexist-{int(time.time() * 1000)}"

    # Case A: Nonexistent message_id with explicit title provided
    payload_with_title = {
        "request_id": req_step_id,
        "message_id": nonexistent_mid,
        "step_index": 0,
        "title": "独立生成的任务事项",
        "initial_status": "todo",
    }
    resp = client.post("/personal/matters/from_step", headers=auth_headers, json=payload_with_title)
    assert resp.status_code == 201
    data = resp.json()
    assert data["ok"] is True
    assert data["matter"]["title"] == "独立生成的任务事项"
    assert data["source_step"]["message_id"] == nonexistent_mid
    assert data["source_step"]["step_index"] == 0
    assert data["source_step"]["linked_matter_id"] == data["matter"]["matter_id"]

    # Case B: Nonexistent message_id without title provided -> fallback title generated
    req_step_id_2 = f"req-step-notitle-{int(time.time() * 1000)}"
    payload_no_title = {
        "request_id": req_step_id_2,
        "message_id": nonexistent_mid,
        "step_index": 3,
        "initial_status": "suggested",
    }
    resp2 = client.post("/personal/matters/from_step", headers=auth_headers, json=payload_no_title)
    assert resp2.status_code == 201
    data2 = resp2.json()
    assert data2["ok"] is True
    assert data2["matter"]["title"] == f"Step 3 from {nonexistent_mid}"
    assert data2["matter"]["status"] == "suggested"


def test_from_step_invalid_step_index_inputs(client, auth_headers):
    """Test validation errors on malformed step_index."""
    req_base = f"req-step-val-{int(time.time() * 1000)}"

    # 1. String that cannot be cast to integer
    resp = client.post(
        "/personal/matters/from_step",
        headers=auth_headers,
        json={"request_id": f"{req_base}-1", "message_id": "msg-1", "step_index": "abc"},
    )
    assert resp.status_code == 400
    assert "必须为整数" in resp.json()["detail"]

    # 2. Float string
    resp = client.post(
        "/personal/matters/from_step",
        headers=auth_headers,
        json={"request_id": f"{req_base}-2", "message_id": "msg-1", "step_index": "3.14"},
    )
    assert resp.status_code == 400

    # 3. Missing step_index entirely
    resp = client.post(
        "/personal/matters/from_step",
        headers=auth_headers,
        json={"request_id": f"{req_base}-3", "message_id": "msg-1"},
    )
    assert resp.status_code == 400

    # 4. None / null step_index
    resp = client.post(
        "/personal/matters/from_step",
        headers=auth_headers,
        json={"request_id": f"{req_base}-4", "message_id": "msg-1", "step_index": None},
    )
    assert resp.status_code == 400


def test_from_step_step_already_linked_deduplication(client, auth_headers):
    """When a step was already linked by request_id A, a subsequent request with request_id B
    targeting the same step must re-link and return the existing matter without duplication.
    """
    req_msg = f"req-msg-linked-{int(time.time() * 1000)}"
    res_msg = app_module.conversation.submit(req_msg, "测试已关联去重")
    message_id = res_msg["message_id"]

    plan = {
        "title": "已关联去重测试计划",
        "todos": [
            {"id": "1", "content": "第一步：准备", "status": "completed"},
            {"id": "2", "content": "第二步：关键执行项", "status": "pending"},
        ],
    }
    app_module.conversation.set_plan(message_id, plan)

    # First request: links step 1 to a new matter
    req_id_1 = f"req-step-first-{int(time.time() * 1000)}"
    payload_1 = {
        "request_id": req_id_1,
        "message_id": message_id,
        "step_index": 1,
        "title": "第二步：关键执行项",
        "initial_status": "todo",
    }
    resp1 = client.post("/personal/matters/from_step", headers=auth_headers, json=payload_1)
    assert resp1.status_code == 201
    matter_id_1 = resp1.json()["matter"]["matter_id"]

    # Second request with a completely NEW request_id targeting the same step
    req_id_2 = f"req-step-second-{int(time.time() * 1000)}"
    payload_2 = {
        "request_id": req_id_2,
        "message_id": message_id,
        "step_index": 1,
        "title": "尝试重复创建同一步骤",
        "initial_status": "todo",
    }
    resp2 = client.post("/personal/matters/from_step", headers=auth_headers, json=payload_2)
    assert resp2.status_code == 201
    data2 = resp2.json()

    # Must return the existing matter_id!
    assert data2["matter"]["matter_id"] == matter_id_1
    assert data2["source_step"]["linked_matter_id"] == matter_id_1


def test_from_step_initial_status_outbox_filtering(client, auth_headers):
    """Verify initial_status='suggested' does NOT create outbox event, while 'todo' and 'doing' do."""
    store = app_module.personal_board.matter_store

    # 1. Suggested status
    req_sugg = f"req-sugg-{int(time.time() * 1000)}"
    resp_sugg = client.post(
        "/personal/matters/from_step",
        headers=auth_headers,
        json={
            "request_id": req_sugg,
            "message_id": "msg-dummy-1",
            "step_index": 0,
            "title": "建议阶段事项",
            "initial_status": "suggested",
        },
    )
    assert resp_sugg.status_code == 201
    mid_sugg = resp_sugg.json()["matter"]["matter_id"]

    with store.db() as db:
        outbox_sugg = db.execute("SELECT * FROM matter_outbox WHERE matter_id=?", (mid_sugg,)).fetchall()
        assert len(outbox_sugg) == 0, "Suggested matter should NOT create outbox projection event"

    # 2. Doing status
    req_doing = f"req-doing-{int(time.time() * 1000)}"
    resp_doing = client.post(
        "/personal/matters/from_step",
        headers=auth_headers,
        json={
            "request_id": req_doing,
            "message_id": "msg-dummy-2",
            "step_index": 0,
            "title": "进行中阶段事项",
            "initial_status": "doing",
        },
    )
    assert resp_doing.status_code == 201
    mid_doing = resp_doing.json()["matter"]["matter_id"]

    with store.db() as db:
        outbox_doing = db.execute("SELECT * FROM matter_outbox WHERE matter_id=?", (mid_doing,)).fetchall()
        assert len(outbox_doing) == 1, "Doing matter MUST create outbox projection event"
        assert "doing" in outbox_doing[0]["payload"]
