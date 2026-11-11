"""Empirical Challenger M1 Iteration 2 Stress Test Suite.

Adversarially tests:
1. Micro-action idempotency with rapid duplicate calls (5x rapid calls per action).
   - Assert all 5 return HTTP 200 with identical receipt payload.
   - Assert exactly 1 entry in matter_action_ops.
   - Assert zero duplicate executions and zero MatterIllegalTransition errors.
2. P08 reverse-drag non-destructive preservation with ZERO flags:
   - Call board.move({"card": "todo:<cid>", "to": "suggest", "rev": rev}) with NO flags.
   - Verify file is NEVER deleted, frontmatter 状态 is NEVER "已取消", body 100% preserved.
   - Perform 5 back-and-forth cycles with zero flags.
   - Verify explicit destructive_cancel behavior.
3. Verification of zero fake message injections in live DB across all micro-actions.
"""
import asyncio
import json
import tempfile
from pathlib import Path
from starlette.testclient import TestClient

import app as app_module
from app import app, personal_board, conversation
from board import PersonalBoard
from matter_schema import MatterStore, generate_matter_id
from next_steps import NextSteps
from today import Today, com_id_derive, _front


def test_stress_micro_action_rapid_duplicate_calls_idempotency():
    """Adversarial stress-test: 5 rapid calls to /personal/matter/{matter_id}/action with identical request_id."""
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="差旅打车报销",
        source_type="test",
        status="suggested",
        matter_id=mid,
        action={"type": "bookkeep", "amount": 42.5, "note": "滴滴快车"},
    )

    req_id = f"req-rapid-{mid}"
    payload = {
        "action_type": "bookkeep",
        "amount": 42.5,
        "category": "出行交通",
        "comment": "滴滴快车往返搜狐媒体大厦",
        "request_id": req_id,
    }

    responses = []
    # Rapid succession: 5 consecutive calls with identical request_id
    for i in range(5):
        resp = client.post(f"/personal/matter/{mid}/action", headers=headers, json=payload)
        responses.append(resp)

    # All 5 MUST return 200 OK
    for i, resp in enumerate(responses):
        assert resp.status_code == 200, f"Call {i+1} failed with status {resp.status_code}: {resp.text}"
        data = resp.json()
        assert data["ok"] is True
        assert data["matter_status"] == "done"

    # All 5 receipts MUST be 100% identical
    first_receipt = responses[0].json()["receipt"]
    for i, resp in enumerate(responses[1:], start=2):
        receipt_i = resp.json()["receipt"]
        assert receipt_i == first_receipt, f"Call {i} receipt differs from Call 1 receipt!\n1: {first_receipt}\n{i}: {receipt_i}"

    # Verify matter_action_ops table has EXACTLY ONE row for this request_id
    with app_module.personal_board.matter_store.db() as db:
        rows = db.execute("SELECT * FROM matter_action_ops WHERE op_id=?", (req_id,)).fetchall()
        assert len(rows) == 1, f"Expected 1 op in matter_action_ops, found {len(rows)}"
        cached_result = json.loads(rows[0]["result"])
        assert cached_result["receipt"] == first_receipt

    # Now verify calendar action with 5 rapid duplicate calls as well
    mid_cal = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="架构委员会闭门审查会",
        source_type="test",
        status="suggested",
        matter_id=mid_cal,
        action={"type": "calendar", "start": "2026-11-15 14:00", "end": "2026-11-15 16:00"},
    )
    cal_req_id = f"req-cal-rapid-{mid_cal}"
    cal_payload = {
        "action_type": "calendar",
        "title": "架构委员会闭门审查会",
        "start": "2026-11-15 14:00",
        "end": "2026-11-15 16:00",
        "location": "大会议室 1001",
        "request_id": cal_req_id,
    }

    cal_responses = [client.post(f"/personal/matter/{mid_cal}/action", headers=headers, json=cal_payload) for _ in range(5)]
    for idx, resp in enumerate(cal_responses):
        assert resp.status_code == 200, f"Calendar call {idx+1} failed: {resp.status_code}"
        assert resp.json()["receipt"] == cal_responses[0].json()["receipt"]

    with app_module.personal_board.matter_store.db() as db:
        cal_ops = db.execute("SELECT * FROM matter_action_ops WHERE op_id=?", (cal_req_id,)).fetchall()
        assert len(cal_ops) == 1


def test_micro_action_already_done_tolerance():
    """Verify that calling action on an already-done matter with a new request_id does not throw 400."""
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="已完成事项重新确认",
        source_type="test",
        status="done",
        matter_id=mid,
    )

    req_payload = {
        "action_type": "generic",
        "request_id": f"req-done-retry-{mid}",
    }
    resp = client.post(f"/personal/matter/{mid}/action", headers=headers, json=req_payload)
    assert resp.status_code == 200
    data = resp.json()
    assert data["ok"] is True
    assert data["matter_status"] == "done"


def test_p08_reverse_drag_without_any_flags():
    """Adversarial stress-test: Reverse-drag 'todo:<cid>' -> 'suggest' with ZERO flags.

    Production web/iOS callers invoke:
      board.move({"card": f"todo:{cid}", "to": "suggest", "rev": rev, "request_id": op_id})
    WITHOUT passing 'non_destructive': True or 'preserve_markdown': True.

    Assertions:
    1. The markdown file is NOT deleted.
    2. Frontmatter '状态' is NOT changed to '已取消'.
    3. Markdown body is completely preserved.
    4. 5 back-and-forth cycles without ANY flags must succeed.
    """
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        state = base / "state"
        vault = base / "vault"
        vault.mkdir(parents=True, exist_ok=True)

        ns = NextSteps(state, clock=lambda: 1700000000.0)
        today = Today(None, None, vault, clock=lambda: 1700000000.0)
        board = PersonalBoard(state, today, ns, None, clock=lambda: 1700000000.0)

        rel = "任务/待处理/零标记生产调用逆向拖拽测试.md"
        cid = com_id_derive(rel)
        path = vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        body_text = "# 核心机密内容\n千万不能被静默取消或删除！\n- 第一条生产业务线\n- 第二条核心交付项\n"
        initial_markdown = (
            f"---\nflow: 任务\n状态: 待处理\n计划结束: 2026-12-01\ncom_id: {cid}\n下一步: 待办\n---\n\n"
            + body_text
        )
        path.write_text(initial_markdown, encoding="utf-8")

        # Snapshot initially to register card in board
        snap = board.snapshot()
        card_id = f"todo:{cid}"
        found = board._find_card(snap, card_id)
        assert found is not None, f"Card {card_id} not found in snapshot: {snap}"
        current_rev = found.get("rev") or str(path.stat().st_mtime_ns)

        async def fake_next_to_todo(ident, day=None, remind_at=None, state='待处理'):
            return {'todo': {'path': rel, 'com_id': cid}}

        # Run 5 round trips: todo -> suggest -> todo -> suggest (ZERO flags passed!)
        for cycle in range(1, 6):
            # Step A: todo -> suggest WITHOUT non_destructive or preserve_markdown
            res_suggest = asyncio.run(board.move({
                "request_id": f"req-cycle-{cycle}-rev-drag",
                "card": card_id,
                "to": "suggest",
                "rev": current_rev,
                # Deliberately omit non_destructive, preserve_markdown, destructive_cancel!
            }))
            assert res_suggest["ok"] is True, f"Cycle {cycle} reverse drag failed: {res_suggest}"

            # CRITICAL ASSERTIONS:
            assert path.exists(), f"Cycle {cycle}: File was deleted after reverse-drag without flags!"
            content = path.read_text(encoding="utf-8")
            front = _front(path)
            assert front.get("状态") != "已取消", f"Cycle {cycle}: Frontmatter 状态 became '已取消' without flags! Got: {front.get('状态')}"
            assert "千万不能被静默取消或删除" in content, f"Cycle {cycle}: Body content corrupted!"

            # Step B: suggest -> todo
            next_card_id = res_suggest["card"]["id"]
            current_rev = res_suggest["card"]["rev"]
            res_todo = asyncio.run(board.move({
                "request_id": f"req-cycle-{cycle}-forward-drag",
                "card": next_card_id,
                "to": "todo",
                "rev": current_rev,
            }, next_to_todo=fake_next_to_todo))
            assert res_todo["ok"] is True, f"Cycle {cycle} forward drag failed: {res_todo}"

            assert path.exists()
            content2 = path.read_text(encoding="utf-8")
            assert "已取消" not in content2
            assert "千万不能被静默取消或删除" in content2

            # Refresh card_id and current_rev for next cycle
            card_id = res_todo["card"]["id"]
            current_rev = res_todo["card"]["rev"]




def test_p08_explicit_destructive_cancel_behavior():
    """Verify that when destructive_cancel=True IS explicitly passed, it cancels the note."""
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        state = base / "state"
        vault = base / "vault"
        vault.mkdir(parents=True, exist_ok=True)

        ns = NextSteps(state, clock=lambda: 1700000000.0)
        today = Today(None, None, vault, clock=lambda: 1700000000.0)
        board = PersonalBoard(state, today, ns, None, clock=lambda: 1700000000.0)

        rel = "任务/待处理/显式删除测试.md"
        cid = com_id_derive(rel)
        path = vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"---\nflow: 任务\n状态: 待处理\ncom_id: {cid}\n---\n\n内容", encoding="utf-8")

        snap = board.snapshot()
        card = board._find_card(snap, f"todo:{cid}")
        rev = card.get("rev") or str(path.stat().st_mtime_ns)

        # Explicitly pass destructive_cancel: True
        res = asyncio.run(board.move({
            "request_id": "req-explicit-destroy-1",
            "card": f"todo:{cid}",
            "to": "suggest",
            "rev": rev,
            "destructive_cancel": True,
        }))
        assert res["ok"] is True
        # Now frontmatter state SHOULD be '已取消'
        front = _front(path)
        assert front.get("状态") == "已取消", "Expected '已取消' when destructive_cancel=True is explicitly set!"



def test_zero_fake_messages_in_live_db():
    """Verify SQLite messages table does not increment when running actions."""
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    with app_module.conversation.db() as db:
        initial_msg_count = db.execute("SELECT count(*) FROM messages").fetchone()[0]

    actions_to_test = [
        {"action_type": "bookkeep", "amount": 99.9, "category": "电子数码", "comment": "购买充电线"},
        {"action_type": "calendar", "title": "客户方案对接会", "start": "2026-11-20 15:00"},
        {"action_type": "reply_mail", "mail_id": "mail-12345", "draft": "确认同意方案"},
        {"action_type": "generic"},
    ]

    for idx, act in enumerate(actions_to_test):
        mid = generate_matter_id()
        app_module.personal_board.matter_store.create_matter(
            title=f"零消息注入验证-{idx}",
            source_type="test",
            status="suggested",
            matter_id=mid,
        )
        act_payload = {**act, "request_id": f"req-zero-msg-{idx}"}
        resp = client.post(f"/personal/matter/{mid}/action", headers=headers, json=act_payload)
        assert resp.status_code == 200

        with app_module.conversation.db() as db:
            current_msg_count = db.execute("SELECT count(*) FROM messages").fetchone()[0]
            assert current_msg_count == initial_msg_count, (
                f"Fake message injected during action {act['action_type']}! Initial: {initial_msg_count}, Current: {current_msg_count}"
            )


def test_unified_matter_reverse_drag_zero_flags():
    """Verify unified matter entity (mtr-...) reverse drag to 'suggest' with ZERO flags.

    Assert:
    - Matter status transitions to 'suggested'.
    - Monotonic rev increases.
    - Obsidian binding note is NEVER overwritten or deleted.
    """
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        state = base / "state"
        vault = base / "vault"
        vault.mkdir(parents=True, exist_ok=True)

        ns = NextSteps(state, clock=lambda: 1700000000.0)
        today = Today(None, None, vault, clock=lambda: 1700000000.0)
        board = PersonalBoard(state, today, ns, None, clock=lambda: 1700000000.0)

        rel = "任务/待处理/统一事项零标志逆向拖拽.md"
        cid = com_id_derive(rel)
        path = vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        body = "# 统一实体正文\n不可篡改的核心数据\n"
        path.write_text(f"---\nflow: 任务\n状态: 待处理\ncom_id: {cid}\n---\n\n{body}", encoding="utf-8")

        mid = generate_matter_id()
        matter = board.matter_store.create_matter(
            title="统一事项零标志测试",
            source_type="todo",
            status="todo",
            matter_id=mid,
            legacy_id="todo:" + cid,
            obsidian_binding={"path": rel, "com_id": cid},
        )

        # Move to suggest WITHOUT ANY FLAGS
        res = asyncio.run(board.move({
            "request_id": f"req-mtr-rev-{mid}",
            "matter_id": mid,
            "to": "suggest",
            "rev": matter.rev,
        }))
        assert res["ok"] is True
        assert res["matter"]["status"] == "suggested"
        assert res["matter"]["rev"] == matter.rev + 1

        # Assert physical note is untouched
        assert path.exists()
        front = _front(path)
        assert front.get("状态") != "已取消"
        assert "不可篡改的核心数据" in path.read_text(encoding="utf-8")


import pytest


def test_concurrent_identical_action_requests():
    """Adversarial stress-test: 5 concurrent threads/tasks firing identical request_id simultaneously."""
    import concurrent.futures


    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="并发记账压力测试",
        source_type="test",
        status="suggested",
        matter_id=mid,
        action={"type": "bookkeep", "amount": 88.0, "note": "并发请求测试"},
    )

    req_id = f"req-concurrent-{mid}"
    payload = {
        "action_type": "bookkeep",
        "amount": 88.0,
        "category": "餐饮美食",
        "comment": "并发记账测试",
        "request_id": req_id,
    }

    def fire_request():
        return client.post(f"/personal/matter/{mid}/action", headers=headers, json=payload)

    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
        futures = [executor.submit(fire_request) for _ in range(5)]
        results = [f.result() for f in futures]

    # Every concurrent request must return 200 OK (no 400 or 500 race condition crash)
    for idx, r in enumerate(results):
        assert r.status_code == 200, f"Concurrent request {idx} failed with {r.status_code}: {r.text}"
        data = r.json()
        assert data["ok"] is True
        assert data["matter_status"] == "done"

    # All returned receipts must match
    base_receipt = results[0].json()["receipt"]
    for idx, r in enumerate(results[1:], start=2):
        assert r.json()["receipt"] == base_receipt, f"Receipt mismatch in concurrent call {idx}"

    # Exactly 1 entry in matter_action_ops
    with app_module.personal_board.matter_store.db() as db:
        rows = db.execute("SELECT * FROM matter_action_ops WHERE op_id=?", (req_id,)).fetchall()
        assert len(rows) == 1, f"Expected 1 op in matter_action_ops, found {len(rows)}"
