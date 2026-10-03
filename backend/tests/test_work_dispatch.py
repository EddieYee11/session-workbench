import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from work_dispatch import WorkProposalStore


def proposal(store: WorkProposalStore, **changes):
    data = {
        "agent": "codex",
        "relative_cwd": ".",
        "title": "检查工作台",
        "prompt": "检查现有测试并报告结果",
        "sandbox": "read-only",
        "reason": "需要检查代码",
        "origin_session_id": "com-main",
        "origin_message_id": "msg-1",
        "origin_request_id": "request-00001",
        "idempotency_key": "proposal-request-00001",
        "now": 1000.0,
    }
    data.update(changes)
    return store.propose(**data)


def test_proposal_requires_user_claim_and_is_idempotent(tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = WorkProposalStore(tmp_path / "state", workspace)
    first = proposal(store)
    assert first["status"] == "proposed"
    assert first["origin_request_id"] == "request-00001"
    assert proposal(store)["id"] == first["id"]
    with pytest.raises(ValueError, match="Idempotency key"):
        proposal(store, prompt="其他任务")
    claimed = store.claim_approval(first["id"], "approval-00001", now=1001.0)
    assert claimed["status"] == "dispatching"
    assert claimed["claimed_now"] is True
    repeat = store.claim_approval(first["id"], "approval-00001", now=1002.0)
    assert repeat["status"] == "dispatching"
    assert repeat["claimed_now"] is False
    with pytest.raises(ValueError, match="different approval"):
        store.claim_approval(first["id"], "approval-00002", now=1002.0)
    accepted = store.mark_accepted(first["id"], "approval-00001", "codex:thread-1")
    assert accepted["status"] == "accepted"
    assert accepted["work_session_id"] == "codex:thread-1"
    assert store.mark_accepted(first["id"], "approval-00001", "codex:thread-1") == accepted


def test_proposal_rejects_fake_pi_sandbox_and_directory_escape(tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = WorkProposalStore(tmp_path / "state", workspace)
    assert proposal(store, agent="pi", sandbox="read-only")['sandbox'] == 'danger-full-access'
    with pytest.raises(ValueError, match="outside"):
        proposal(store, relative_cwd="..")
    with pytest.raises(ValueError, match="relative"):
        proposal(store, relative_cwd=str(workspace))


def test_expired_proposal_cannot_dispatch(tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = WorkProposalStore(tmp_path / "state", workspace)
    first = proposal(store)
    with pytest.raises(ValueError, match="expired"):
        store.claim_approval(first["id"], "approval-00001", now=first["expires_at"])
    assert store.get(first["id"])["status"] == "expired"


def test_unknown_and_rejected_are_terminal_for_approval(tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = WorkProposalStore(tmp_path / "state", workspace)
    first = proposal(store)
    store.claim_approval(first["id"], "approval-00001", now=1001.0)
    unknown = store.mark_unknown(
        first["id"], "approval-00001", "transport_unknown", "codex:thread-1"
    )
    assert unknown["status"] == "unknown"
    assert unknown["work_session_id"] == "codex:thread-1"
    with pytest.raises(ValueError, match="not dispatching"):
        store.mark_accepted(first["id"], "approval-00001", "pi:session")
    other = proposal(store, idempotency_key="proposal-request-00002")
    assert store.reject(other["id"])["status"] == "rejected"
    with pytest.raises(ValueError, match="cannot be approved"):
        store.claim_approval(other["id"], "approval-00002", now=1002.0)


def test_recover_inflight_marks_unknown_without_resending(tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = WorkProposalStore(tmp_path / "state", workspace)
    first = proposal(store)
    store.claim_approval(first["id"], "approval-00001", now=1001.0)
    assert store.recover_inflight(now=1002.0) == 1
    recovered = store.get(first["id"])
    assert recovered["status"] == "unknown"
    assert recovered["error_code"] == "service_restarted"
    assert store.recover_inflight(now=1003.0) == 0
    repeat = store.claim_approval(first["id"], "approval-00001", now=1004.0)
    assert repeat["claimed_now"] is False
    assert repeat["status"] == "unknown"
