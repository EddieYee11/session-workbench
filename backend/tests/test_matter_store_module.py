"""Unit tests for backend/matter_store.py module and Outbox Projector.

Verifies:
1. Module imports and full export parity (MatterStore, UnifiedMatterEntity, FSM_STATES, etc.).
2. Compatibility between `from matter_store import MatterStore` and `from matter_schema import MatterStore`.
3. MatterStore state management, FSM transitions, and FTS5 search.
4. Outbox Projector background worker with success projection, retry backoff, and DLQ.
"""
from __future__ import annotations

import asyncio
from pathlib import Path
import time
from unittest.mock import MagicMock

import pytest

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


def test_matter_store_exports_and_compatibility():
    """Verify all symbols are cleanly exported and identical to schema definitions."""
    assert matter_store.MatterStore is matter_schema.MatterStore
    assert matter_store.UnifiedMatterEntity is matter_schema.UnifiedMatterEntity
    assert matter_store.MatterConflict is matter_schema.MatterConflict
    assert matter_store.MatterIllegalTransition is matter_schema.MatterIllegalTransition
    assert matter_store.MatterNotFound is matter_schema.MatterNotFound
    assert matter_store.FSM_STATES == matter_schema.FSM_STATES
    assert matter_store.VALID_TRANSITIONS == matter_schema.VALID_TRANSITIONS
    assert len(FSM_STATES) == 11
    assert "waiting_input" in FSM_STATES
    assert "executing" in FSM_STATES


def test_matter_id_generation_and_validation():
    """Verify matter ID format mtr-<YYYYMMDD>-<8 hex chars>."""
    mid = generate_matter_id()
    assert validate_matter_id(mid) is True
    assert mid.startswith("mtr-")
    parts = mid.split("-")
    assert len(parts) == 3
    assert len(parts[1]) == 8  # YYYYMMDD
    assert len(parts[2]) == 8  # 8 hex chars

    assert validate_matter_id("invalid-id") is False
    assert validate_matter_id("mtr-20261107") is False
    assert validate_matter_id("") is False


def test_matter_store_crud_and_fsm(tmp_path: Path):
    """Verify MatterStore CRUD and 11-state FSM state transitions."""
    db_path = tmp_path / "test_matter.sqlite"
    store = MatterStore(db_path)

    # 1. Create matter
    m1 = store.create_matter(
        title="重构后端架构",
        source_type="chat_extracted",
        status="suggested",
        why="用户在主聊天的要求",
    )
    assert m1.status == "suggested"
    assert m1.rev == 1
    assert validate_matter_id(m1.matter_id)

    # 2. Transition suggested -> todo
    m2 = store.transition_status(m1.matter_id, "todo", expected_rev=1)
    assert m2.status == "todo"
    assert m2.rev == 2

    # 3. Optimistic locking conflict (expected rev 1 while current is 2)
    with pytest.raises(MatterConflict) as exc_info:
        store.transition_status(m1.matter_id, "doing", expected_rev=1)
    assert exc_info.value.current_rev == 2

    # 4. Illegal FSM transition (todo -> waiting_input is not in VALID_TRANSITIONS)
    with pytest.raises(MatterIllegalTransition):
        store.transition_status(m1.matter_id, "waiting_input", expected_rev=2)

    # 5. Legal transition todo -> executing
    m3 = store.transition_status(m1.matter_id, "executing", expected_rev=2)
    assert m3.status == "executing"
    assert m3.rev == 3

    # 6. Legal transition executing -> waiting_input
    m4 = store.transition_status(m1.matter_id, "waiting_input", expected_rev=3, waiting_reason="等待审批")
    assert m4.status == "waiting_input"
    assert m4.waiting_reason == "等待审批"
    assert m4.rev == 4

    # 7. Get by ID
    fetched = store.get_by_id(m1.matter_id)
    assert fetched is not None
    assert fetched.matter_id == m1.matter_id
    assert fetched.status == "waiting_input"


def test_matter_store_fts_search(tmp_path: Path):
    """Verify FTS5 CJK unigram search and snippet highlighting."""
    db_path = tmp_path / "test_fts.sqlite"
    store = MatterStore(db_path)

    store.create_matter(title="实现 iOS 端折叠屏双屏协同规范", source_type="manual", status="todo")
    store.create_matter(title="整理财务记账周报", source_type="manual", status="done")

    res = store.search_matters_fts("折叠屏")
    assert res["total"] >= 1
    items = res["items"]
    assert any("折叠屏" in it["title"] for it in items)

    res_empty = store.search_matters_fts("!@#$%^")
    assert res_empty["total"] == 0


@pytest.mark.anyio
async def test_outbox_projector_success_and_retry(tmp_path: Path):
    """Verify process_matter_outbox_projector successfully projects items and handles retries to DLQ."""
    db_path = tmp_path / "test_outbox.sqlite"
    store = MatterStore(db_path)

    m = store.create_matter(title="测试同步事项", source_type="manual", status="todo")
    outbox_id = store.create_outbox_event(
        m.matter_id,
        "obsidian_projection",
        {"target_status": "todo", "day": "2026-11-07"},
    )
    assert outbox_id > 0

    # Mock board with _vault
    vault_calls = []

    def fake_vault(fn, *args, **kwargs):
        vault_calls.append((fn, args, kwargs))
        return {"todo": {"path": "任务/待处理/测试同步事项.md", "com_id": "com-123"}}

    board = MagicMock()
    board.matter_store = store
    board.today = MagicMock()
    board.today.vault = tmp_path / "vault"
    board._vault = fake_vault

    # Run projector once
    processed = await process_matter_outbox_projector(board, once=True)
    assert processed == 1
    assert len(vault_calls) == 1

    # Verify outbox event is marked done
    pending = store.list_pending_outbox()
    assert len(pending) == 0

    # Verify matter obsidian_binding was updated
    updated_matter = store.get_by_id(m.matter_id)
    assert updated_matter.obsidian_binding is not None
    assert updated_matter.obsidian_binding["path"] == "任务/待处理/测试同步事项.md"


@pytest.mark.anyio
async def test_outbox_projector_dlq_after_five_retries(tmp_path: Path):
    """Verify failing outbox projection enters DLQ after 5 retries."""
    db_path = tmp_path / "test_dlq.sqlite"
    store = MatterStore(db_path)

    m = store.create_matter(title="失败事项", source_type="manual", status="todo")
    outbox_id = store.create_outbox_event(
        m.matter_id,
        "obsidian_projection",
        {"target_status": "todo"},
    )

    def failing_vault(fn, *args, **kwargs):
        raise OSError("Obsidian iCloud sync timeout")

    board = MagicMock()
    board.matter_store = store
    board.today = MagicMock()
    board.today.vault = tmp_path / "vault"
    board._vault = failing_vault

    # Run projector 5 times
    for _ in range(5):
        await process_matter_outbox_projector(board, once=True)

    # After 5 retries, status is dlq and excluded from list_pending_outbox
    pending = store.list_pending_outbox()
    assert len(pending) == 0

    with store.db() as db:
        row = db.execute("SELECT status, retry_count FROM matter_outbox WHERE id=?", (outbox_id,)).fetchone()
        assert row["status"] == "dlq"
        assert row["retry_count"] == 5
