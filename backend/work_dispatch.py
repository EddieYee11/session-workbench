"""Approval-gated Pi/Codex work proposals from the Personal Agent.

Creating a proposal never starts a work session. Only the Com! authenticated
approval route may claim a proposal and call Runtime.create/input.
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator


PROPOSAL_TTL_SECONDS = 24 * 60 * 60
VALID_AGENTS = {"pi", "codex"}
VALID_CODEX_SANDBOXES = {"read-only", "workspace-write", "danger-full-access"}


class WorkProposalStore:
    def __init__(self, state: Path, workspace: Path | None = None):
        self.state = Path(state)
        self.workspace = (workspace or Path.home() / "AI_Work_System").resolve()
        self.path = self.state / "work-proposals.sqlite3"

    @contextmanager
    def _db(self) -> Iterator[sqlite3.Connection]:
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.state, 0o700)
        try:
            info = self.path.lstat()
        except FileNotFoundError:
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
            except FileExistsError:
                info = self.path.lstat()
                if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
                    raise RuntimeError("Proposal database permissions are invalid") from None
            else:
                os.close(fd)
        else:
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
                raise RuntimeError("Proposal database permissions are invalid")
        db = sqlite3.connect(self.path, timeout=5)
        try:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA busy_timeout=5000")
            db.execute(
                """CREATE TABLE IF NOT EXISTS proposals (
                id TEXT PRIMARY KEY,
                idempotency_key TEXT NOT NULL UNIQUE,
                fingerprint TEXT NOT NULL,
                agent TEXT NOT NULL,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                prompt TEXT NOT NULL,
                sandbox TEXT NOT NULL,
                reason TEXT NOT NULL,
                origin_session_id TEXT NOT NULL,
                origin_message_id TEXT NOT NULL,
                origin_request_id TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                approval_request_id TEXT,
                work_session_id TEXT,
                error_code TEXT
                )"""
            )
            db.commit()
            with db:
                yield db
        finally:
            db.close()

    def _cwd(self, relative_cwd: str) -> str:
        if not isinstance(relative_cwd, str) or not relative_cwd or len(relative_cwd) > 300:
            raise ValueError("Invalid work directory")
        raw = Path(relative_cwd)
        if raw.is_absolute():
            raise ValueError("Work directory must be relative to AI_Work_System")
        resolved = (self.workspace / raw).resolve()
        if not resolved.is_relative_to(self.workspace) or not resolved.is_dir():
            raise ValueError("Work directory is outside AI_Work_System")
        return str(resolved)

    @staticmethod
    def _text(value: str, field: str, maximum: int, required: bool = True) -> str:
        if not isinstance(value, str):
            raise ValueError(f"Invalid {field}")
        result = value.strip()
        if len(result) > maximum or (required and not result):
            raise ValueError(f"Invalid {field}")
        return result

    @staticmethod
    def _row(row: sqlite3.Row) -> dict[str, Any]:
        return {key: row[key] for key in row.keys() if key != "fingerprint"}

    def propose(
        self,
        *,
        agent: str,
        relative_cwd: str,
        title: str,
        prompt: str,
        sandbox: str,
        reason: str,
        origin_session_id: str = "",
        origin_message_id: str = "",
        origin_request_id: str = "",
        idempotency_key: str = "",
        now: float | None = None,
    ) -> dict[str, Any]:
        if agent not in VALID_AGENTS:
            raise ValueError("Agent must be pi or codex")
        if agent == "pi" and sandbox != "danger-full-access":
            raise ValueError("Pi currently requires explicit full-access approval")
        if agent == "codex" and sandbox not in VALID_CODEX_SANDBOXES:
            raise ValueError("Invalid Codex sandbox")
        payload = {
            "agent": agent,
            "cwd": self._cwd(relative_cwd),
            "title": self._text(title, "title", 120),
            "prompt": self._text(prompt, "prompt", 6000),
            "sandbox": sandbox,
            "reason": self._text(reason, "reason", 500),
            "origin_session_id": self._text(origin_session_id, "origin_session_id", 120, False),
            "origin_message_id": self._text(origin_message_id, "origin_message_id", 120, False),
            "origin_request_id": self._text(origin_request_id, "origin_request_id", 120, False),
        }
        fingerprint = hashlib.sha256(
            json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()
        ).hexdigest()
        key = self._text(idempotency_key, "idempotency_key", 120, False)
        if not key:
            key = "payload:" + fingerprint
        if len(key) < 10:
            raise ValueError("Invalid idempotency_key")
        proposal_id = "work_" + hashlib.sha256(key.encode()).hexdigest()[:24]
        at = time.time() if now is None else now
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            old = db.execute(
                "SELECT * FROM proposals WHERE idempotency_key=?", (key,)
            ).fetchone()
            if old:
                if old["fingerprint"] != fingerprint:
                    raise ValueError("Idempotency key conflicts with a different proposal")
                return self._row(old)
            db.execute(
                """INSERT INTO proposals (
                    id,idempotency_key,fingerprint,agent,cwd,title,prompt,sandbox,
                    reason,origin_session_id,origin_message_id,origin_request_id,
                    status,created_at,updated_at,expires_at
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    proposal_id,key,fingerprint,payload["agent"],payload["cwd"],
                    payload["title"],payload["prompt"],payload["sandbox"],
                    payload["reason"],payload["origin_session_id"],
                    payload["origin_message_id"],payload["origin_request_id"],
                    "proposed",at,at,at+PROPOSAL_TTL_SECONDS,
                ),
            )
            row = db.execute("SELECT * FROM proposals WHERE id=?", (proposal_id,)).fetchone()
            return self._row(row)

    def get(self, proposal_id: str) -> dict[str, Any] | None:
        with self._db() as db:
            row = db.execute("SELECT * FROM proposals WHERE id=?", (proposal_id,)).fetchone()
            return self._row(row) if row else None

    def list(self, limit: int = 20) -> list[dict[str, Any]]:
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
            raise ValueError("Invalid limit")
        with self._db() as db:
            rows = db.execute(
                "SELECT * FROM proposals "
                "ORDER BY CASE WHEN status='proposed' AND expires_at>? THEN 0 ELSE 1 END,"
                "created_at DESC LIMIT ?", (time.time(), limit),
            ).fetchall()
            return [self._row(row) for row in rows]

    def claim_approval(
        self, proposal_id: str, approval_request_id: str, *, now: float | None = None
    ) -> dict[str, Any]:
        """Atomic user-approval claim; the caller then creates the work session."""
        request_id = self._text(approval_request_id, "approval_request_id", 120)
        if len(request_id) < 10:
            raise ValueError("Invalid approval_request_id")
        at = time.time() if now is None else now
        expired = False
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM proposals WHERE id=?", (proposal_id,)).fetchone()
            if not row:
                raise ValueError("Proposal not found")
            if row["approval_request_id"]:
                if row["approval_request_id"] != request_id:
                    raise ValueError("Proposal already has a different approval request")
                return {**self._row(row), "claimed_now": False}
            if row["status"] != "proposed":
                raise ValueError("Proposal cannot be approved")
            if at >= row["expires_at"]:
                db.execute(
                    "UPDATE proposals SET status='expired',updated_at=? WHERE id=?",
                    (at, proposal_id),
                )
                expired = True
            else:
                db.execute(
                    """UPDATE proposals SET status='dispatching',
                       approval_request_id=?,updated_at=? WHERE id=?""",
                    (request_id, at, proposal_id),
                )
            row = db.execute("SELECT * FROM proposals WHERE id=?", (proposal_id,)).fetchone()
            result = self._row(row)
        if expired:
            raise ValueError("Proposal expired")
        return {**result, "claimed_now": True}

    def mark_accepted(
        self, proposal_id: str, approval_request_id: str, work_session_id: str
    ) -> dict[str, Any]:
        sid = self._text(work_session_id, "work_session_id", 160)
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM proposals WHERE id=?", (proposal_id,)).fetchone()
            if not row or row["approval_request_id"] != approval_request_id:
                raise ValueError("Approval request mismatch")
            if row["status"] == "accepted" and row["work_session_id"] == sid:
                return self._row(row)
            if row["status"] != "dispatching":
                raise ValueError("Proposal is not dispatching")
            db.execute(
                """UPDATE proposals SET status='accepted',work_session_id=?,
                   updated_at=? WHERE id=?""",
                (sid, time.time(), proposal_id),
            )
            return self._row(db.execute(
                "SELECT * FROM proposals WHERE id=?", (proposal_id,)
            ).fetchone())

    def mark_unknown(
        self,
        proposal_id: str,
        approval_request_id: str,
        error_code: str,
        work_session_id: str | None = None,
    ) -> dict[str, Any]:
        code = self._text(error_code, "error_code", 80)
        sid = self._text(work_session_id, "work_session_id", 160) if work_session_id else None
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM proposals WHERE id=?", (proposal_id,)).fetchone()
            if not row or row["approval_request_id"] != approval_request_id:
                raise ValueError("Approval request mismatch")
            if row["status"] == "dispatching":
                db.execute(
                    """UPDATE proposals SET status='unknown',error_code=?,
                       work_session_id=COALESCE(?, work_session_id),
                       updated_at=? WHERE id=?""",
                    (code, sid, time.time(), proposal_id),
                )
            return self._row(db.execute(
                "SELECT * FROM proposals WHERE id=?", (proposal_id,)
            ).fetchone())

    def recover_inflight(self, *, now: float | None = None) -> int:
        """On Com! startup, make interrupted approvals inspectable without retrying."""
        at = time.time() if now is None else now
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            changed = db.execute(
                """UPDATE proposals SET status='unknown',
                   error_code=COALESCE(error_code, 'service_restarted'),
                   updated_at=? WHERE status='dispatching'""",
                (at,),
            )
            return changed.rowcount

    def reject(self, proposal_id: str) -> dict[str, Any]:
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM proposals WHERE id=?", (proposal_id,)).fetchone()
            if not row:
                raise ValueError("Proposal not found")
            if row["status"] == "rejected":
                return self._row(row)
            if row["status"] != "proposed":
                raise ValueError("Proposal cannot be rejected")
            db.execute(
                "UPDATE proposals SET status='rejected',updated_at=? WHERE id=?",
                (time.time(), proposal_id),
            )
            return self._row(db.execute(
                "SELECT * FROM proposals WHERE id=?", (proposal_id,)
            ).fetchone())
