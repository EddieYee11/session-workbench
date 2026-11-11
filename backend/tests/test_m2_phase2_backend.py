"""Tests for Milestone 2 Phase 2 Backend Implementation:
1. 409 spring rollback metadata payload contract
2. 503 circuit breaker outbox queuing & Retry-After header
3. get_action_op matter_id scoping enforcement
4. mark_outbox_retry DLQ transition
5. Interrupt Fork metadata in message submission
"""
import concurrent.futures
import json
import time
from starlette.testclient import TestClient

import app as app_module
from matter_schema import MatterStore, generate_matter_id


def test_409_spring_rollback_metadata_contract():
    """Verify 409 response has rich spring rollback metadata, latest entity, and diff."""
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    m = app_module.personal_board.matter_store.create_matter(
        title="409 回滚元数据测试",
        source_type="test",
        status="suggested",
        matter_id=mid,
    )
    initial_rev = m.rev

    # Advance rev to 2
    app_module.personal_board.matter_store.transition_status(mid, "todo", expected_rev=initial_rev)

    # Now make move request using stale rev=1
    resp = client.post(
        "/personal/matter/move",
        headers=headers,
        json={
            "matter_id": mid,
            "to_status": "doing",
            "matter_rev": initial_rev,
            "request_id": f"req-409-test-{mid}",
        },
    )
    assert resp.status_code == 409
    data = resp.json()
    assert data["ok"] is False
    assert data["error"] == "conflict"
    assert data["matter_id"] == mid
    assert data["requested_rev"] == initial_rev
    assert data["current_rev"] == 2
    assert "latest" in data
    assert data["latest"]["status"] == "todo"
    assert data["latest"]["rev"] == 2
    assert "diff" in data
    assert data["diff"]["status"]["requested"] == "doing"
    assert data["diff"]["status"]["current"] == "todo"
    assert "rollback_metadata" in data
    rollback = data["rollback_metadata"]
    assert rollback["spring_target_column"] == "todo"
    assert rollback["auto_aligned"] is False
    assert "toast_type" in rollback


def test_503_circuit_breaker_outbox_contract():
    """Verify build_503_timeout_response returns Retry-After: 3, outbox_queued, pending_sync."""
    client = TestClient(app_module.app)
    mid = generate_matter_id()
    resp = app_module.build_503_timeout_response(matter_id=mid, outbox_id=42)
    assert resp.status_code == 503
    assert resp.headers.get("retry-after") == "3"
    body = json.loads(resp.body.decode("utf-8"))
    assert body["ok"] is False
    assert body["retry_after"] == 3
    assert body["outbox_queued"] is True
    assert body["outbox_id"] == 42
    assert body["pending_sync"] is True
    assert body["circuit_breaker"]["timeout_seconds"] == 8


def test_get_action_op_matter_id_scoping():
    """Verify that get_action_op enforces matter_id scoping and rejects cross-matter hijacking."""
    store = app_module.personal_board.matter_store
    mid_a = generate_matter_id()
    mid_b = generate_matter_id()
    op_id = f"op-scoping-{mid_a}"

    store.save_action_op(op_id, mid_a, {"result": "success_for_a"})

    # 1. Matching matter_id succeeds
    res_a = store.get_action_op(op_id, matter_id=mid_a)
    assert res_a == {"result": "success_for_a"}

    # 2. None matter_id succeeds (unscoped)
    res_unscoped = store.get_action_op(op_id)
    assert res_unscoped == {"result": "success_for_a"}

    # 3. Mismatched matter_id returns None (prevent hijack)
    res_b = store.get_action_op(op_id, matter_id=mid_b)
    assert res_b is None


def test_mark_outbox_retry_dlq_transition():
    """Verify outbox retries increment and transition to dlq after max_retries."""
    store = app_module.personal_board.matter_store
    mid = generate_matter_id()
    outbox_id = store.create_outbox_event(mid, "obsidian_projection", {"test": True})

    # Retry 1 through 4 remain pending
    for i in range(1, 5):
        status = store.mark_outbox_retry(outbox_id, f"error {i}", max_retries=5)
        assert status == "pending"

    # 5th retry transitions to dlq
    status_dlq = store.mark_outbox_retry(outbox_id, "error 5", max_retries=5)
    assert status_dlq == "dlq"


def test_interrupt_fork_chat_messages():
    """Verify Interrupt Fork metadata is included when requested or background cases exist."""
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    req_id = f"req-fork-test-{int(time.time() * 1000)}"
    resp = client.post(
        "/personal/conversation/messages",
        headers=headers,
        json={
            "request_id": req_id,
            "text": "测试即时应答消息",
            "is_interrupt_fork": True,
        },
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "accepted"
    assert data["is_interrupt_fork"] is True
    assert "fork_thread_id" in data
    assert data["fork_thread_id"].startswith("fork-main-")
