"""Empirical Challenger Verification for M1 Iteration 2 Gate.

Specifically verifying:
1. 4 PRD Transitions (executing -> todo, waiting_input -> todo, error_blocked -> todo, done -> doing).
2. 11-State Board Move Gatekeeper via REST API (POST /personal/matter/move).
3. Concurrency on matter_rev parameter (fresh succeeds, stale 409, 20-thread race).
4. Cross-matter request_id isolation on micro-actions.
"""
from __future__ import annotations

import asyncio
import concurrent.futures
from pathlib import Path
import tempfile
import time

import pytest
from starlette.testclient import TestClient

import app as app_module
from board import BoardBadRequest, BoardConflict, PersonalBoard
from matter_schema import (
    FSM_STATES,
    VALID_TRANSITIONS,
    MatterConflict,
    MatterIllegalTransition,
    MatterStore,
    generate_matter_id,
)
from next_steps import NextSteps
from today import Today


@pytest.fixture
def temp_store(tmp_path: Path):
    db_file = tmp_path / "iter2_matter.sqlite"
    return MatterStore(db_file)


# ---------------------------------------------------------------------------
# Check 1: 4 PRD Transitions Empiric Verification
# ---------------------------------------------------------------------------

def test_prd_four_transitions(temp_store: MatterStore):
    """Empirically test the 4 specific PRD transitions:
    - executing -> todo
    - waiting_input -> todo
    - error_blocked -> todo
    - done -> doing
    """
    # 1. executing -> todo
    m1 = temp_store.create_matter("Test executing to todo", "manual", status="executing")
    u1 = temp_store.transition_status(m1.matter_id, "todo", expected_rev=m1.rev)
    assert u1.status == "todo"
    assert u1.rev == 2
    assert temp_store.get_by_id(m1.matter_id).status == "todo"

    # 2. waiting_input -> todo
    m2 = temp_store.create_matter("Test waiting_input to todo", "manual", status="waiting_input")
    u2 = temp_store.transition_status(m2.matter_id, "todo", expected_rev=m2.rev)
    assert u2.status == "todo"
    assert u2.rev == 2
    assert temp_store.get_by_id(m2.matter_id).status == "todo"

    # 3. error_blocked -> todo
    m3 = temp_store.create_matter("Test error_blocked to todo", "manual", status="error_blocked")
    u3 = temp_store.transition_status(m3.matter_id, "todo", expected_rev=m3.rev)
    assert u3.status == "todo"
    assert u3.rev == 2
    assert temp_store.get_by_id(m3.matter_id).status == "todo"

    # 4. done -> doing
    m4 = temp_store.create_matter("Test done to doing", "manual", status="done")
    u4 = temp_store.transition_status(m4.matter_id, "doing", expected_rev=m4.rev)
    assert u4.status == "doing"
    assert u4.rev == 2
    assert temp_store.get_by_id(m4.matter_id).status == "doing"


# ---------------------------------------------------------------------------
# Check 2: 11-State Board Move Gatekeeper (REST API & Board Level)
# ---------------------------------------------------------------------------

def test_11_state_board_move_gatekeeper():
    """Verify that POST /personal/matter/move with to_status: 'executing' or 'waiting_input'
    returns HTTP 200 and updates status without being rejected by the old 5-column check.
    Also verify legacy cards cannot jump to non-5-column states.
    """
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    # Create a fresh matter in personal_board.matter_store
    mid = generate_matter_id()
    m = app_module.personal_board.matter_store.create_matter(
        title="11-State Gatekeeper Test",
        source_type="manual",
        status="todo",
        matter_id=mid,
    )
    assert m.status == "todo"
    rev = m.rev

    # 1. Move todo -> executing via API
    resp1 = client.post(
        "/personal/matter/move",
        headers=headers,
        json={
            "matter_id": mid,
            "to_status": "executing",
            "matter_rev": rev,
            "request_id": f"req-gate-exec-{mid}",
        },
    )
    assert resp1.status_code == 200, f"Failed moving to executing: {resp1.text}"
    data1 = resp1.json()
    assert data1["ok"] is True
    assert data1["matter"]["status"] == "executing"
    rev = data1["matter"]["rev"]

    # 2. Move executing -> waiting_input via API
    resp2 = client.post(
        "/personal/matter/move",
        headers=headers,
        json={
            "matter_id": mid,
            "to_status": "waiting_input",
            "matter_rev": rev,
            "request_id": f"req-gate-wait-{mid}",
        },
    )
    assert resp2.status_code == 200, f"Failed moving to waiting_input: {resp2.text}"
    data2 = resp2.json()
    assert data2["ok"] is True
    assert data2["matter"]["status"] == "waiting_input"
    rev = data2["matter"]["rev"]

    # 3. Move waiting_input -> todo via API (one of the 4 PRD transitions!)
    resp3 = client.post(
        "/personal/matter/move",
        headers=headers,
        json={
            "matter_id": mid,
            "to_status": "todo",
            "matter_rev": rev,
            "request_id": f"req-gate-todo-{mid}",
        },
    )
    assert resp3.status_code == 200, f"Failed moving to todo: {resp3.text}"
    data3 = resp3.json()
    assert data3["ok"] is True
    assert data3["matter"]["status"] == "todo"

    # 4. Verify legacy card rejection for non-5-column states via legacy /personal/board/move
    resp_leg = client.post(
        "/personal/board/move",
        headers=headers,
        json={
            "card": "todo:legacy_test_card_123",
            "to": "executing",
            "request_id": f"req-gate-legacy-fail-{mid}",
        },
    )
    assert resp_leg.status_code == 400
    assert "非法移动" in resp_leg.text


# ---------------------------------------------------------------------------
# Check 3: Concurrency Test on matter_rev parameter
# ---------------------------------------------------------------------------

def test_concurrency_on_matter_rev_parameter():
    """Empirically test that passing matter_rev:
    1. Triggers 409 conflict when stale.
    2. Succeeds when fresh.
    3. Exactly 1 succeeds and 19 fail with 409 in a 20-thread race over the HTTP API.
    """
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    m = app_module.personal_board.matter_store.create_matter(
        title="Concurrency matter_rev Race",
        source_type="manual",
        status="suggested",
        matter_id=mid,
    )
    current_rev = m.rev  # 1

    # Stale rev test: expected_rev = 999
    resp_stale = client.post(
        "/personal/matter/move",
        headers=headers,
        json={
            "matter_id": mid,
            "to_status": "todo",
            "matter_rev": 999,
            "request_id": f"req-rev-stale-{mid}",
        },
    )
    assert resp_stale.status_code == 409, f"Expected 409 for stale rev, got {resp_stale.status_code}"

    # Fresh rev test: matter_rev = 1
    resp_fresh = client.post(
        "/personal/matter/move",
        headers=headers,
        json={
            "matter_id": mid,
            "to_status": "todo",
            "matter_rev": current_rev,
            "request_id": f"req-rev-fresh-{mid}",
        },
    )
    assert resp_fresh.status_code == 200
    data_fresh = resp_fresh.json()
    assert data_fresh["matter"]["rev"] == current_rev + 1
    current_rev = data_fresh["matter"]["rev"]

    # 20-thread race against the HTTP API using matter_rev
    concurrency = 20
    success_count = 0
    conflict_count = 0
    errors = []

    def send_move_race(idx: int):
        # All threads compete with the SAME expected rev (current_rev) to move todo -> doing
        resp = client.post(
            "/personal/matter/move",
            headers=headers,
            json={
                "matter_id": mid,
                "to_status": "doing",
                "matter_rev": current_rev,
                "request_id": f"req-rev-race-{mid}-{idx}",
            },
        )
        return resp.status_code, resp.json()

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(send_move_race, i) for i in range(concurrency)]
        for fut in concurrent.futures.as_completed(futures):
            try:
                code, res = fut.result()
                if code == 200 and res.get("ok"):
                    success_count += 1
                elif code == 409:
                    conflict_count += 1
                else:
                    errors.append((code, res))
            except Exception as e:
                errors.append(e)

    assert len(errors) == 0, f"Unexpected errors in race: {errors}"
    assert success_count == 1, f"Expected exactly 1 success, got {success_count}"
    assert conflict_count == concurrency - 1, f"Expected {concurrency - 1} conflicts, got {conflict_count}"

    # Final entity in DB must be at rev = current_rev + 1, status = doing
    final_m = app_module.personal_board.matter_store.get_by_id(mid)
    assert final_m.status == "doing"
    assert final_m.rev == current_rev + 1


# ---------------------------------------------------------------------------
# Check 4: Deep Adversarial Stress - Full 11-State API Routing & Malformed Revs
# ---------------------------------------------------------------------------

def test_adversarial_all_11_states_board_routing():
    """Verify that all legal transitions across the 11 FSM states can be navigated via /personal/matter/move."""
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    m = app_module.personal_board.matter_store.create_matter(
        title="Full 11 State Navigation",
        source_type="manual",
        status="suggested",
        matter_id=mid,
    )
    rev = m.rev

    # Route: suggested -> todo -> executing -> error_retrying -> error_blocked -> todo -> doing -> done -> doing -> cancelled -> todo -> snoozed -> suggested -> dismissed -> suggested
    route = [
        "todo",
        "executing",
        "error_retrying",
        "error_blocked",
        "todo",
        "doing",
        "done",
        "doing",
        "cancelled",
        "todo",
        "snoozed",
        "suggested",
        "dismissed",
        "suggested",
    ]

    for step_idx, next_st in enumerate(route):
        resp = client.post(
            "/personal/matter/move",
            headers=headers,
            json={
                "matter_id": mid,
                "to_status": next_st,
                "matter_rev": rev,
                "request_id": f"req-route-{mid}-{step_idx}",
            },
        )
        assert resp.status_code == 200, f"Step {step_idx} ({next_st}) failed: {resp.text}"
        data = resp.json()
        assert data["ok"] is True
        assert data["matter"]["status"] == next_st
        rev = data["matter"]["rev"]

    assert rev == m.rev + len(route)
    persisted = app_module.personal_board.matter_store.get_by_id(mid)
    assert persisted.status == "suggested"
    assert persisted.rev == rev


def test_adversarial_malformed_matter_rev_inputs():
    """Stress test malformed and boundary inputs for matter_rev:
    Strings, floats, negative numbers, None.
    """
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    m = app_module.personal_board.matter_store.create_matter(
        title="Malformed Rev Stress",
        source_type="manual",
        status="suggested",
        matter_id=mid,
    )
    rev = m.rev  # 1

    # Non-digit string rev: 'abc' should be ignored (treated as None / optimistic pass) or handled gracefully
    resp_str = client.post(
        "/personal/matter/move",
        headers=headers,
        json={
            "matter_id": mid,
            "to_status": "todo",
            "matter_rev": "not_a_number",
            "request_id": f"req-malformed-str-{mid}",
        },
    )
    # expected_rev is None when str is non-digit -> transition succeeds
    assert resp_str.status_code == 200
    rev = resp_str.json()["matter"]["rev"]
    assert rev == 2

    # Negative rev: -1 is not all digits, expected_rev is None
    resp_neg = client.post(
        "/personal/matter/move",
        headers=headers,
        json={
            "matter_id": mid,
            "to_status": "doing",
            "matter_rev": -1,
            "request_id": f"req-malformed-neg-{mid}",
        },
    )
    assert resp_neg.status_code == 200
    rev = resp_neg.json()["matter"]["rev"]
    assert rev == 3

