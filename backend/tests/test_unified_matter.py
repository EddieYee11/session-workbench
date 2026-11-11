"""Comprehensive tests for UnifiedMatterEntity, 11-state FSM, and In-Place Micro Actions.

Verifies:
1. Immutable matter_id format and validation.
2. 11-state FSM transitions, guard conditions, and monotonic rev versioning.
3. 409 conflict detection on stale revisions.
4. Non-destructive reverse-drag (P08 bug fix: markdown frontmatter preserved).
5. In-place micro-actions (bookkeeping, calendar) without chat redirection or fake messages.
6. REST API endpoints (/personal/matters, /personal/matter/board, /personal/matter/move, /personal/matter/{id}/action, /personal/matter/{id}/delegate).
"""
import asyncio
import json
import re
import tempfile
from pathlib import Path
from starlette.testclient import TestClient

from app import app, personal_board
from board import PersonalBoard
from matter_schema import (
    FSM_STATES,
    VALID_TRANSITIONS,
    MatterConflict,
    MatterIllegalTransition,
    MatterNotFound,
    MatterStore,
    UnifiedMatterEntity,
    generate_matter_id,
    validate_matter_id,
)
from next_steps import NextSteps
from today import Today, com_id_derive


def test_matter_id_format_and_validation():
    """Verify matter_id format mtr-YYYYMMDD-hash and regex validation."""
    mid = generate_matter_id()
    assert validate_matter_id(mid), f"Generated ID failed validation: {mid}"
    assert re.match(r"^mtr-[0-9]{8}-[a-z0-9]{8,12}$", mid)

    # Invalid IDs must be rejected
    assert not validate_matter_id("todo:12345678")
    assert not validate_matter_id("next:abcdef1234567890")
    assert not validate_matter_id("mtr-invalid")
    assert not validate_matter_id("")


def test_fsm_11_states_transitions_and_rev():
    """Verify FSM state machine transitions, illegal transition guards, and rev monotonicity."""
    with tempfile.TemporaryDirectory() as td:
        db_path = Path(td) / "matter_test.sqlite"
        store = MatterStore(db_path)

        # 1. Create matter (initial state: suggested, rev: 1)
        m = store.create_matter("确认方案", "manual", status="suggested")
        assert m.status == "suggested"
        assert m.rev == 1
        assert m.matter_id.startswith("mtr-")

        # 2. Valid transition: suggested -> todo (rev 1 -> 2)
        m = store.transition_status(m.matter_id, "todo", expected_rev=1)
        assert m.status == "todo"
        assert m.rev == 2

        # 3. Valid transition: todo -> doing (rev 2 -> 3)
        m = store.transition_status(m.matter_id, "doing", expected_rev=2)
        assert m.status == "doing"
        assert m.rev == 3

        # 4. Valid transition: doing -> done (rev 3 -> 4)
        m = store.transition_status(m.matter_id, "done", expected_rev=3)
        assert m.status == "done"
        assert m.rev == 4
        assert m.completed_at is not None

        # 5. Illegal transition guard: done -> error_blocked is NOT in VALID_TRANSITIONS
        try:
            store.transition_status(m.matter_id, "error_blocked")
            assert False, "Should have raised MatterIllegalTransition"
        except MatterIllegalTransition:
            pass

        # 6. Optimistic lock / 409 conflict detection: stale expected_rev must raise MatterConflict
        try:
            store.transition_status(m.matter_id, "suggested", expected_rev=2)
            assert False, "Should have raised MatterConflict"
        except MatterConflict:
            pass

        # Current rev is 4; transition with expected_rev=4 succeeds
        m = store.transition_status(m.matter_id, "suggested", expected_rev=4)
        assert m.status == "suggested"
        assert m.rev == 5


def test_transactional_outbox():
    """Verify transactional outbox persistence and status lifecycle."""
    with tempfile.TemporaryDirectory() as td:
        store = MatterStore(Path(td) / "test.sqlite")
        mid = generate_matter_id()
        oid = store.create_outbox_event(mid, "matter_created", {"title": "Outbox Task"})
        assert oid > 0

        pending = store.list_pending_outbox()
        assert len(pending) == 1
        assert pending[0]["matter_id"] == mid
        assert pending[0]["event_type"] == "matter_created"

        store.mark_outbox_done(oid)
        assert len(store.list_pending_outbox()) == 0


def test_non_destructive_reverse_drag_p08_fix():
    """Verify P08 bug fix: dragging from todo/doing back to suggested must NOT overwrite Markdown with '已取消'."""
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        state = base / "state"
        vault = base / "vault"
        vault.mkdir(parents=True, exist_ok=True)

        ns = NextSteps(state, clock=lambda: 1700000000.0)
        today = Today(None, None, vault, clock=lambda: 1700000000.0)
        board = PersonalBoard(state, today, ns, None, clock=lambda: 1700000000.0)

        # Create an Obsidian markdown todo
        rel = "任务/待处理/不可破坏的笔记.md"
        cid = com_id_derive(rel)
        path = vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        initial_markdown = f"---\nflow: 任务\n状态: 待处理\n计划结束: 2026-11-10\ncom_id: {cid}\n下一步: 推进\n---\n\n# 核心用户内容不可丢失\n"
        path.write_text(initial_markdown, encoding="utf-8")
        rev = str(path.stat().st_mtime_ns)

        # Execute move to suggest without any flags (production default must be non-destructive)
        async def run_move():
            res = await board.move({
                "request_id": "op-p08-test",
                "card": "todo:" + cid,
                "to": "suggest",
                "rev": rev,
            })
            assert res["ok"]

        asyncio.run(run_move())

        # CRITICAL ASSERTION: Frontmatter must NOT be overwritten with "状态: 已取消"
        content_after = path.read_text(encoding="utf-8")
        assert "状态: 已取消" not in content_after, "P08 Regression: Markdown file was destructively marked as 已取消!"
        assert "核心用户内容不可丢失" in content_after


def test_in_place_actions_and_api_endpoints():
    """Verify in-place action execution, matter board, and delegate endpoints without chat redirection."""
    import app as app_module
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}
    board = app_module.personal_board

    # 1. Test GET /personal/matter/board
    board_resp = client.get("/personal/matter/board", headers=headers)
    assert board_resp.status_code == 200
    board_data = board_resp.json()
    assert "columns" in board_data
    assert "suggested" in board_data["columns"]
    assert "todo" in board_data["columns"]
    assert "doing" in board_data["columns"]
    assert "done" in board_data["columns"]

    # 2. Seed a test matter in matter_store
    matter = board.matter_store.create_matter(
        title="午餐消费记账",
        source_type="test",
        status="suggested",
        action={"type": "bookkeep", "amount": 38.5, "note": "麦当劳"},
    )
    mid = matter.matter_id

    # 3. Test POST /personal/matter/{matter_id}/action with bookkeep (in-place)
    act_resp = client.post(
        f"/personal/matter/{mid}/action",
        headers=headers,
        json={
            "action_type": "bookkeep",
            "amount": 42.0,
            "category": "餐饮美食",
            "comment": "原位微卡调整金额",
            "request_id": "req-micro-test-01",
        },
    )
    assert act_resp.status_code == 200
    act_data = act_resp.json()
    assert act_data["ok"] is True
    assert act_data["matter_status"] == "done"
    assert act_data["receipt"] is not None
    assert "42" in act_data["receipt"]["message"]

    # Verify state in SQLite store is atomically updated to done
    stored = board.matter_store.get_by_id(mid)
    assert stored.status == "done"
    assert stored.rev >= 2

    # 4. Test calendar in-place action
    matter_cal = board.matter_store.create_matter(
        title="参加行业技术峰会",
        source_type="test",
        status="suggested",
        action={"type": "calendar", "start": "2026-11-15 14:00", "end": "2026-11-15 17:00"},
    )
    cal_resp = client.post(
        f"/personal/matter/{matter_cal.matter_id}/action",
        headers=headers,
        json={
            "action_type": "calendar",
            "title": "参加行业技术峰会",
            "start": "2026-11-15 14:00",
            "end": "2026-11-15 17:00",
            "location": "北京国际会议中心",
        },
    )
    assert cal_resp.status_code == 200
    assert cal_resp.json()["ok"] is True
    assert cal_resp.json()["matter_status"] == "done"

    # 5. Test POST /personal/matter/move
    matter_move = board.matter_store.create_matter(
        title="测试移动事项",
        source_type="test",
        status="suggested",
    )
    move_resp = client.post(
        "/personal/matter/move",
        headers=headers,
        json={
            "matter_id": matter_move.matter_id,
            "to_status": "todo",
            "rev": matter_move.rev,
            "request_id": "op-move-test-01",
        },
    )
    assert move_resp.status_code == 200
    move_data = move_resp.json()
    assert move_data["ok"] is True
    assert move_data["matter"]["status"] == "todo"

    # 6. Test POST /personal/matter/{matter_id}/delegate
    del_resp = client.post(
        f"/personal/matter/{matter_move.matter_id}/delegate",
        headers=headers,
        json={"instruction": "全自动后台调研", "request_id": "req-del-01"},
    )
    assert del_resp.status_code == 200
    del_data = del_resp.json()
    assert del_data["ok"] is True
    assert del_data["mode"] == "case"
    assert "capsule" in del_data
    assert del_data["capsule"]["state_text"] == "后台航程已启动"
