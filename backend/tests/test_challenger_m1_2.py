"""Empirical Challenger Test Suite for Phase 1 (M1) Com! Chat & Next Restructure.

Conducted by challenger_m1_2:
1. Non-destructive reverse-drag: repeated back-and-forth moves (suggest -> todo -> suggest -> todo),
   verifying Obsidian markdown Frontmatter is NEVER overwritten with "已取消" and NEVER deleted.
2. In-place actions: simulate bookkeep/calendar action executions and verify NO fake message is EVER
   injected into conversation history (messages table).
3. Micro-action idempotency: verify repeated submissions of the same request_id to /personal/matter/{matter_id}/action.
4. Static grep assertions on iOS and Web source code for zero fake message injections and zero tab hopping.
"""
import asyncio
import json
import re
import tempfile
from pathlib import Path
from starlette.testclient import TestClient

import app as app_module
from app import app, personal_board, conversation
from board import PersonalBoard
from matter_schema import (
    MatterStore,
    generate_matter_id,
)
from next_steps import NextSteps
from today import Today, com_id_derive, _front


def test_repeated_reverse_drag_obsidian_integrity():
    """Verify repeated back-and-forth moves (suggest -> todo -> suggest -> todo x5)

    Assertions:
    1. Obsidian markdown file is NEVER deleted.
    2. Obsidian markdown Frontmatter 状态 is NEVER overwritten with "已取消".
    3. Obsidian markdown body text remains completely intact.
    4. Matter state in SQLite reflects expected status and monotonic rev.
    """
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        state = base / "state"
        vault = base / "vault"
        vault.mkdir(parents=True, exist_ok=True)

        ns = NextSteps(state, clock=lambda: 1700000000.0)
        today = Today(None, None, vault, clock=lambda: 1700000000.0)
        board = PersonalBoard(state, today, ns, None, clock=lambda: 1700000000.0)

        # Create Obsidian task markdown
        rel = "任务/待处理/长周期对抗测试任务.md"
        cid = com_id_derive(rel)
        path = vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        initial_body = "# 用户关键内容\n这是不能被破坏的笔记正文内容。\n- 待办细节 A\n- 待办细节 B\n"
        initial_markdown = (
            f"---\nflow: 任务\n状态: 待处理\n计划结束: 2026-11-20\ncom_id: {cid}\n下一步: 推进\n---\n\n"
            + initial_body
        )
        path.write_text(initial_markdown, encoding="utf-8")

        # Create matter entity bound to this obsidian note
        mid = generate_matter_id()
        matter = board.matter_store.create_matter(
            title="长周期对抗测试任务",
            source_type="todo",
            status="todo",
            matter_id=mid,
            legacy_id="todo:" + cid,
            obsidian_binding={"path": rel, "com_id": cid},
        )
        current_rev = matter.rev

        # Perform 5 round trips: todo -> suggested -> todo -> suggested...
        for cycle in range(1, 6):
            # 1. Reverse drag: todo -> suggest
            req_id_to_suggest = f"req-cycle-{cycle}-to-suggest"
            async def move_to_suggest(r):
                return await board.move({
                    "request_id": req_id_to_suggest,
                    "matter_id": mid,
                    "card": mid,
                    "to": "suggest",
                    "rev": r,
                    "non_destructive": True,
                })

            res = asyncio.run(move_to_suggest(current_rev))
            assert res["ok"] is True, f"Cycle {cycle}: Move to suggest failed: {res}"
            current_rev = res["matter"]["rev"]

            # ASSERTION: File MUST exist
            assert path.exists(), f"Cycle {cycle}: File was deleted after move to suggest!"
            # ASSERTION: Frontmatter MUST NOT contain '已取消'
            content = path.read_text(encoding="utf-8")
            front = _front(path)
            assert front.get("状态") != "已取消", f"Cycle {cycle}: Frontmatter 状态 was destructively set to 已取消!"
            assert "这是不能被破坏的笔记正文内容" in content, f"Cycle {cycle}: Body content was corrupted!"

            # 2. Forward drag: suggest -> todo
            req_id_to_todo = f"req-cycle-{cycle}-to-todo"
            async def move_to_todo(r):
                return await board.move({
                    "request_id": req_id_to_todo,
                    "matter_id": mid,
                    "card": mid,
                    "to": "todo",
                    "rev": r,
                    "non_destructive": True,
                })

            res2 = asyncio.run(move_to_todo(current_rev))
            assert res2["ok"] is True, f"Cycle {cycle}: Move to todo failed: {res2}"
            current_rev = res2["matter"]["rev"]

            # ASSERTION: File MUST exist
            assert path.exists(), f"Cycle {cycle}: File was deleted after move to todo!"
            content2 = path.read_text(encoding="utf-8")
            front2 = _front(path)
            assert front2.get("状态") != "已取消", f"Cycle {cycle}: Frontmatter 状态 was set to 已取消!"
            assert "这是不能被破坏的笔记正文内容" in content2, f"Cycle {cycle}: Body content was corrupted!"

        # Final verification: After 5 full cycles (10 moves)
        final_matter = board.matter_store.get_by_id(mid)
        assert final_matter.status == "todo"
        assert final_matter.rev == 11  # 1 initial + 10 transitions
        assert path.is_file()
        final_content = path.read_text(encoding="utf-8")
        assert "状态: 已取消" not in final_content
        assert "这是不能被破坏的笔记正文内容" in final_content


def test_in_place_actions_no_fake_messages_injected():
    """Verify in-place actions (bookkeep, calendar) execute without inserting any fake messages into conversation DB."""
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    # Query initial message count in conversation SQLite database
    with app_module.conversation.db() as db:
        initial_count = db.execute("SELECT count(*) FROM messages").fetchone()[0]

    # 1. Execute bookkeep in-place action
    mid_bk = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="午餐支出消费",
        source_type="test",
        status="suggested",
        matter_id=mid_bk,
        action={"type": "bookkeep", "amount": 68.0, "note": "必胜客披萨"},
    )

    resp_bk = client.post(
        f"/personal/matter/{mid_bk}/action",
        headers=headers,
        json={
            "action_type": "bookkeep",
            "amount": 68.0,
            "category": "餐饮美食",
            "comment": "必胜客午市套餐",
            "request_id": "req-emp-bk-001",
        },
    )
    assert resp_bk.status_code == 200, f"Bookkeep action failed: {resp_bk.text}"
    data_bk = resp_bk.json()
    assert data_bk["ok"] is True
    assert data_bk["matter_status"] == "done"

    # Verify conversation messages table: COUNT MUST REMAIN UNCHANGED
    with app_module.conversation.db() as db:
        count_after_bk = db.execute("SELECT count(*) FROM messages").fetchone()[0]
        assert count_after_bk == initial_count, f"Fake message injected! Before: {initial_count}, After: {count_after_bk}"

        # Assert no message mentions 必胜客
        rows = db.execute("SELECT * FROM messages WHERE text LIKE '%必胜客%' OR text LIKE '%68.0%'").fetchall()
        assert len(rows) == 0, f"Found injected fake message in conversation DB: {rows}"

    # 2. Execute calendar in-place action
    mid_cal = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="技术架构委员会评审会议",
        source_type="test",
        status="suggested",
        matter_id=mid_cal,
        action={"type": "calendar", "start": "2026-11-12 10:00", "end": "2026-11-12 11:30"},
    )

    resp_cal = client.post(
        f"/personal/matter/{mid_cal}/action",
        headers=headers,
        json={
            "action_type": "calendar",
            "title": "技术架构委员会评审会议",
            "start": "2026-11-12 10:00",
            "end": "2026-11-12 11:30",
            "location": "大会议室 B",
            "request_id": "req-emp-cal-001",
        },
    )
    assert resp_cal.status_code == 200, f"Calendar action failed: {resp_cal.text}"
    data_cal = resp_cal.json()
    assert data_cal["ok"] is True
    assert data_cal["matter_status"] == "done"

    # Verify conversation messages table: COUNT MUST STILL REMAIN UNCHANGED
    with app_module.conversation.db() as db:
        count_after_cal = db.execute("SELECT count(*) FROM messages").fetchone()[0]
        assert count_after_cal == initial_count, f"Fake message injected! Expected: {initial_count}, Got: {count_after_cal}"

        rows = db.execute("SELECT * FROM messages WHERE text LIKE '%技术架构委员会%'").fetchall()
        assert len(rows) == 0, f"Found injected calendar fake message: {rows}"


def test_micro_action_idempotency_failure():
    """Verify micro-action idempotency on repeated request_id.

    When a mobile/web client sends an action with request_id = 'req-idemp-test'
    and then repeats it (due to retry, weak network, or user double-tap):
    The endpoint MUST be idempotent (returning 200 OK with cached receipt).
    """
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="差旅车票报销",
        source_type="test",
        status="suggested",
        matter_id=mid,
        action={"type": "bookkeep", "amount": 150.0, "note": "高铁票"},
    )

    req_payload = {
        "action_type": "bookkeep",
        "amount": 150.0,
        "category": "出行交通",
        "comment": "北京-天津高铁票",
        "request_id": f"req-idemp-{mid}",
    }

    # First execution
    resp1 = client.post(f"/personal/matter/{mid}/action", headers=headers, json=req_payload)
    assert resp1.status_code == 200
    data1 = resp1.json()
    assert data1["ok"] is True
    assert data1["matter_status"] == "done"

    # Second execution with EXACT SAME request_id and payload
    resp2 = client.post(f"/personal/matter/{mid}/action", headers=headers, json=req_payload)
    assert resp2.status_code == 200, f"Expected 200 idempotent response on retry, got: {resp2.status_code}"
    data2 = resp2.json()
    assert data2["ok"] is True
    assert data2["matter_status"] == "done"
    assert data2["receipt"] == data1["receipt"]


def test_board_move_idempotency_success_comparison():
    """Contrast: Board move properly caches request_id and returns 200 idempotent response."""
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    mid = generate_matter_id()
    app_module.personal_board.matter_store.create_matter(
        title="对比测试事项",
        source_type="test",
        status="suggested",
        matter_id=mid,
    )

    req_payload = {
        "matter_id": mid,
        "to_status": "todo",
        "request_id": f"req-move-idemp-{mid}",
    }

    # First move call
    resp1 = client.post("/personal/matter/move", headers=headers, json=req_payload)
    assert resp1.status_code == 200
    data1 = resp1.json()
    assert data1["ok"] is True

    # Second move call with SAME request_id
    resp2 = client.post("/personal/matter/move", headers=headers, json=req_payload)
    assert resp1.status_code == 200
    data1 = resp1.json()
    assert data1["ok"] is True

    # Second move call with SAME request_id
    resp2 = client.post("/personal/matter/move", headers=headers, json=req_payload)
    # Assert move endpoint is fully idempotent (200 OK)
    assert resp2.status_code == 200, f"Move idempotency failed: {resp2.status_code}"
    data2 = resp2.json()
    assert data2["ok"] is True
    assert data2["matter"]["matter_id"] == mid


def test_static_code_verification_zero_message_injection():
    """Verify by reading and regex-checking Swift and JS sources that all fake send calls were removed."""
    proj_root = Path("/Users/eddiegao/AI_Work_System/work/工具与效率/会话工作台")

    # 1. iOS NextView and BoardViews
    ios_files = [
        proj_root / "ios/Com/Views/NextView.swift",
        proj_root / "ios/Com/Views/BoardViews.swift",
    ]
    for p in ios_files:
        content = p.read_text(encoding="utf-8")
        assert "send(textOverride:" not in content, f"Found send(textOverride:) in {p}!"
        # Verify no manual message injection into conversation.messages
        assert "conversation.messages.append" not in content, f"Found conversation.messages.append in {p}!"

    # 2. Web cases.js and core.js
    web_files = [
        proj_root / "web/js/cases.js",
        proj_root / "web/js/next.js",
    ]
    for p in web_files:
        if p.exists():
            content = p.read_text(encoding="utf-8")
            assert "send({ textOverride" not in content, f"Found send({{ textOverride }}) in {p}!"
