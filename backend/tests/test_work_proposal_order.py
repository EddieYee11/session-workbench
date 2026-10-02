"""A recent-history limit must not hide an older actionable authorization."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from work_dispatch import PROPOSAL_TTL_SECONDS, WorkProposalStore


def proposal(store, key, at):
    return store.propose(
        agent="codex", relative_cwd=".", title=key,
        prompt="检查现有项目并报告结果", sandbox="read-only", reason="用户待授权",
        idempotency_key=key, now=at,
    )


def test_old_pending_authorization_survives_twenty_newer_history_items(tmp_path, monkeypatch):
    monkeypatch.setattr("work_dispatch.time.time", lambda: 1100.0)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = WorkProposalStore(tmp_path / "state", workspace)
    pending = proposal(store, "pending-request-0001", 1000.0)
    history = []
    for index in range(20):
        record = proposal(store, f"historical-request-{index:04}", 1010.0 + index)
        history.append(store.reject(record["id"]))
    recent = store.list(20)
    assert len(recent) == 20
    assert recent[0]["id"] == pending["id"]
    assert recent[0]["status"] == "proposed"
    assert [record["id"] for record in recent[1:]] == [record["id"] for record in reversed(history[1:])]
    assert store.list(1) == [pending]


def test_pending_priority_excludes_expired_and_preserves_newest_order(tmp_path, monkeypatch):
    now = 100000.0
    monkeypatch.setattr("work_dispatch.time.time", lambda: now)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = WorkProposalStore(tmp_path / "state", workspace)
    expired = proposal(store, "expired-request-0001", now - PROPOSAL_TTL_SECONDS)
    older = proposal(store, "pending-request-0001", now - 100)
    newer = proposal(store, "pending-request-0002", now - 90)
    rejected = proposal(store, "rejected-request-001", now - 1)
    store.reject(rejected["id"])
    records = store.list(4)
    assert [record["id"] for record in records] == [newer["id"], older["id"], rejected["id"], expired["id"]]
    assert records[-1]["expires_at"] == now  # Equal to now is already expired.
    assert store.get(expired["id"])["status"] == "proposed"  # Listing remains read-only.
    with pytest.raises(ValueError, match="expired"):
        store.claim_approval(expired["id"], "approval-expired-001", now=now)
    assert store.get(expired["id"])["status"] == "expired"


@pytest.mark.parametrize("limit", [False, True, 0, -1, 101, 1.5, "20"])
def test_list_keeps_existing_limit_validation(tmp_path, limit):
    store = WorkProposalStore(tmp_path / "state", tmp_path)
    with pytest.raises(ValueError, match="Invalid limit"):
        store.list(limit)
