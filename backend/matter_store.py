"""Authoritative MatterStore module and Transactional Outbox Projector.

Provides single-source-of-truth persistence engine, 11-state FSM state machine,
optimistic locking, and async projection of outbox events to Obsidian.
"""
from __future__ import annotations

import asyncio
from datetime import datetime
import json
import logging
from typing import Any, Optional
from zoneinfo import ZoneInfo

from matter_schema import (
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
    validate_matter_id,
)

logger = logging.getLogger(__name__)
TZ = ZoneInfo("Asia/Shanghai")


async def process_matter_outbox_projector(
    board: Any,
    interval: float = 3.0,
    once: bool = False,
) -> int:
    """Async background worker that projects pending matter_outbox events to Obsidian notes.

    Polls list_pending_outbox(), projects frontmatter updates via board._vault,
    and calls mark_outbox_done on success or mark_outbox_retry on failure (DLQ after 5 retries).
    """
    processed_count = 0
    while True:
        try:
            if board and getattr(board, "matter_store", None):
                pending = board.matter_store.list_pending_outbox(limit=20)
                for item in pending:
                    outbox_id = item["id"]
                    matter_id = item["matter_id"]
                    event_type = item.get("event_type", "")
                    payload = item.get("payload") or {}

                    try:
                        matter = board.matter_store.get_by_id(matter_id)
                        target_status = payload.get("target_status")
                        path = payload.get("path") or (
                            matter.obsidian_binding.get("path")
                            if matter and matter.obsidian_binding
                            else None
                        )

                        if event_type in ("obsidian_projection", "obsidian_create"):
                            # Case 1: Status changed to done -> call todo_done
                            if target_status == "done" and path and board.today and board.today.vault:
                                board._vault(board.today.todo_done, path, from_board=True)
                            # Case 2: Status is todo or doing
                            elif target_status in ("todo", "doing"):
                                state_label = "进行中" if target_status == "doing" else "待处理"
                                if path and board.today and board.today.vault:
                                    # Existing note: update status frontmatter
                                    board._vault(board.today.todo_set_state, path, state_label)
                                elif board.today and board.today.vault and matter:
                                    # New note creation in Obsidian
                                    day = payload.get("day") or datetime.now(TZ).date().isoformat()
                                    res = board._vault(
                                        board.today.todo_create,
                                        title=matter.title,
                                        day=day,
                                        note=matter.why,
                                        state=state_label,
                                    )
                                    if res and isinstance(res, dict) and "todo" in res:
                                        board.matter_store.update_matter(
                                            matter.matter_id,
                                            obsidian_binding={
                                                "path": res["todo"].get("path"),
                                                "com_id": res["todo"].get("com_id"),
                                            },
                                        )

                        board.matter_store.mark_outbox_done(outbox_id)
                        processed_count += 1
                    except Exception as err:
                        logger.warning("Outbox item %s failed: %s", outbox_id, err)
                        board.matter_store.mark_outbox_retry(outbox_id, str(err), max_retries=5)
        except asyncio.CancelledError:
            break
        except Exception as exc:
            logger.error("Outbox projector error: %s", exc)

        if once:
            break
        await asyncio.sleep(interval)

    return processed_count


__all__ = [
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
