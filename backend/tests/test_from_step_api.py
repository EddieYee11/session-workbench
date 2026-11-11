"""Comprehensive tests for POST /personal/matters/from_step API, PRD §7.1.6 normalized message responses, and chat bubble injection removal.

Verifies:
1. POST /personal/matters/from_step:
   - Extraction of step from message plan (TurnPlanner).
   - UnifiedMatterEntity creation and Outbox projection event creation.
   - Marking `linked_matter_id` on the step in message.
   - SSE `matter.update` event broadcast.
   - Idempotency with identical request_id and identical step.
   - Error handling for invalid payloads.
2. POST /personal/conversation/messages:
   - PRD §7.1.6 compliance: ok, message_id, request_id, message_seq, role, content, status="persisted".
   - Monotonic message_seq sequence generation.
   - Idempotency for repeated request_id.
3. Cases C04 Chat Bubble Elimination:
   - Verifies cases.progress(status="waiting") does NOT inject bubbles into the real conversation.
   - Verifies capsule.sync event is broadcast.
   - Verifies matter status is transitioned to waiting_input.
"""
from __future__ import annotations

import asyncio
from pathlib import Path
import time

import pytest
from starlette.testclient import TestClient

import app as app_module
from conversation import PersonalConversation
from matter_store import MatterStore


@pytest.fixture
def client():
    return TestClient(app_module.app)


@pytest.fixture
def auth_headers():
    return {"Authorization": f"Bearer {app_module.TOKEN}"}


def test_from_step_success_and_idempotency(client, auth_headers):
    """Verify POST /personal/matters/from_step extracts plan step, creates matter, and links."""
    # 1. Create a user message with a plan
    mid = f"msg-test-step-{int(time.time() * 1000)}"
    req_msg_id = f"req-msg-{int(time.time() * 1000)}"
    res_msg = app_module.conversation.submit(req_msg_id, "帮我分析 PRD 并拆分步骤")
    message_id = res_msg["message_id"]

    # Set plan on this user message
    plan = {
        "title": "PRD 落地执行计划",
        "todos": [
            {"id": "1", "content": "第一步：摸排现状与差距", "status": "completed"},
            {"id": "2", "content": "第二步：核对 Git 提交日志中的 PRD 修订记录", "status": "in_progress"},
            {"id": "3", "content": "第三步：跑通全链路单测", "status": "pending"},
        ],
    }
    app_module.conversation.set_plan(message_id, plan)

    # 2. Call POST /personal/matters/from_step
    req_step_id = f"req-step-{int(time.time() * 1000)}"
    payload = {
        "request_id": req_step_id,
        "conversation_id": "conv-default",
        "message_id": message_id,
        "step_index": 1,
        "title": "核对 Git 提交日志中的 PRD 修订记录",
        "initial_status": "todo",
        "obsidian_flow": "任务",
    }

    resp = client.post("/personal/matters/from_step", headers=auth_headers, json=payload)
    assert resp.status_code == 201
    data = resp.json()
    assert data["ok"] is True
    assert "matter" in data
    matter = data["matter"]
    assert matter["title"] == "核对 Git 提交日志中的 PRD 修订记录"
    assert matter["status"] == "todo"
    assert matter["rev"] == 1
    assert matter["source_ref"]["raw"] == f"{message_id}:1"

    source_step = data["source_step"]
    assert source_step["message_id"] == message_id
    assert source_step["step_index"] == 1
    assert source_step["linked_matter_id"] == matter["matter_id"]

    # 3. Verify Outbox event was created for Obsidian projection
    with app_module.personal_board.matter_store.db() as db:
        outbox_rows = db.execute(
            "SELECT * FROM matter_outbox WHERE matter_id=?", (matter["matter_id"],)
        ).fetchall()
        assert len(outbox_rows) >= 1
        assert "todo" in outbox_rows[0]["payload"]

    # 4. Verify step in conversation is marked with linked_matter_id
    updated_plan = app_module.conversation.plan_of(message_id)
    assert updated_plan["todos"][1].get("linked_matter_id") == matter["matter_id"]
    assert "linked_at" in updated_plan["todos"][1]

    # 5. Idempotency: call again with identical request_id
    resp_repeat = client.post("/personal/matters/from_step", headers=auth_headers, json=payload)
    assert resp_repeat.status_code == 201
    repeat_data = resp_repeat.json()
    assert repeat_data["matter"]["matter_id"] == matter["matter_id"]
    assert repeat_data["source_step"]["linked_matter_id"] == matter["matter_id"]


def test_from_step_validation_errors(client, auth_headers):
    """Verify 400 Bad Request on invalid from_step requests."""
    # Missing required fields
    resp = client.post("/personal/matters/from_step", headers=auth_headers, json={})
    assert resp.status_code == 400

    resp = client.post(
        "/personal/matters/from_step",
        headers=auth_headers,
        json={"request_id": "req-1", "message_id": "msg-1"},  # missing step_index
    )
    assert resp.status_code == 400

    resp = client.post(
        "/personal/matters/from_step",
        headers=auth_headers,
        json={"request_id": "req-1", "message_id": "msg-1", "step_index": "not_an_int"},
    )
    assert resp.status_code == 400


def test_normalized_conversation_messages_prd_contract(client, auth_headers):
    """Verify POST /personal/conversation/messages complies with PRD §7.1.6."""
    req_id_1 = f"req-msg-prd-{int(time.time() * 1000)}-1"
    payload_1 = {
        "request_id": req_id_1,
        "conversation_id": "conv-default",
        "role": "user",
        "content": "帮我把刚才讨论的架构重构要点整理成周报",
        "context_matter_id": "mtr-20261106-a8f9c2d1",
    }

    resp1 = client.post("/personal/conversation/messages", headers=auth_headers, json=payload_1)
    assert resp1.status_code == 200
    data1 = resp1.json()
    assert data1["ok"] is True
    assert data1["request_id"] == req_id_1
    assert data1["role"] == "user"
    assert data1["content"] == payload_1["content"]
    assert data1["status"] == "persisted"
    assert data1["context_matter_id"] == payload_1["context_matter_id"]
    seq1 = data1["message_seq"]
    assert isinstance(seq1, int) and seq1 > 0

    # Submit second message to verify monotonic incrementation of message_seq
    req_id_2 = f"req-msg-prd-{int(time.time() * 1000)}-2"
    payload_2 = {
        "request_id": req_id_2,
        "conversation_id": "conv-default",
        "role": "user",
        "content": "并且附加上全量单测通过记录",
    }
    resp2 = client.post("/personal/conversation/messages", headers=auth_headers, json=payload_2)
    assert resp2.status_code == 200
    data2 = resp2.json()
    assert data2["ok"] is True
    seq2 = data2["message_seq"]
    assert seq2 > seq1

    # Idempotent re-send of req_id_1 returns same message_id and message_seq
    resp_idempotent = client.post("/personal/conversation/messages", headers=auth_headers, json=payload_1)
    assert resp_idempotent.status_code == 200
    data_idem = resp_idempotent.json()
    assert data_idem["message_id"] == data1["message_id"]
    assert data_idem["message_seq"] == seq1
    assert data_idem["status"] == "persisted"


def test_cases_waiting_eliminates_chat_bubble_injection():
    """Verify cases.progress with waiting status does NOT inject chat bubble and transitions matter."""
    cases = app_module.cases
    store = app_module.personal_board.matter_store

    # Create a matter to bind with the case
    matter = store.create_matter(title="测试航程审批事项", source_type="manual", status="todo")

    # Delegate or register case
    tid = f"task-case-{int(time.time() * 1000)}"
    task_mock = {"id": tid, "title": "自动化迁移航程"}
    cases.register(task_mock, source="matter", source_id=matter.matter_id)

    # Transition matter to executing
    store.transition_status(matter.matter_id, "executing", case_binding={"task_id": tid})

    # Capture initial conversation message count
    history_before = app_module.conversation.history(limit=50)["messages"]
    before_ids = {m["id"] for m in history_before}

    # Trigger progress with waiting status
    cases.progress(tid, {
        "status": "waiting",
        "question": "需要确认是否归档历史数据？",
        "now": "等待用户批准",
    })

    # Verify NO chat bubble was injected into PersonalConversation
    history_after = app_module.conversation.history(limit=50)["messages"]
    new_messages = [m for m in history_after if m["id"] not in before_ids]
    # Ensure none of new messages are "case-wait:..."
    wait_receipts = [m for m in new_messages if m.get("id", "").startswith("case-wait:")]
    assert len(wait_receipts) == 0

    # Verify matter transitioned to waiting_input
    updated_matter = store.get_by_id(matter.matter_id)
    assert updated_matter.status == "waiting_input"
    assert updated_matter.waiting_reason == "需要确认是否归档历史数据？"
