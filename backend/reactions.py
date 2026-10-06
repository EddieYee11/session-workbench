"""A model-selected reaction to the one live Com! user turn.

The MCP process shares Com's private SQLite database. Its capability is minted
by Com for a specific active user message, never by a notification or a tool
result. No text classifier or automatic reaction is involved.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Literal


ReactionEmoji = Literal["👍", "❤️", "😂", "🎉", "🤔", "😮", "😢", "💪", "🙏", "🦀"]
REACTION_EMOJIS = ("👍", "❤️", "😂", "🎉", "🤔", "😮", "😢", "💪", "🙏", "🦀")
TURN_LIFETIME_SECONDS = 900


def install_schema(db: sqlite3.Connection) -> None:
    db.execute("""
        CREATE TABLE IF NOT EXISTS reaction_turns(
            message_id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
            request_id TEXT NOT NULL, capability_hash TEXT NOT NULL,
            expires_at REAL NOT NULL
        )
    """)


def project_message(row) -> dict:
    """The persisted JSON is projected identically for snapshots and updates."""
    message = dict(row)
    encoded = message.get("reaction")
    message["reaction"] = json.loads(encoded) if encoded else None
    return message


class ReactionStore:
    def __init__(self, state: Path):
        self.path = state / "personal-conversation.sqlite"

    @contextmanager
    def db(self):
        # A tool may only use an existing Com conversation, never create one.
        db = sqlite3.connect(self.path.as_uri() + "?mode=rw", uri=True, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                db.execute("BEGIN IMMEDIATE")
                yield db
        finally:
            db.close()

    def open_turn(self, message_id: str, session_id: str) -> str:
        token = secrets.token_urlsafe(32)
        now = time.time()
        with self.db() as db:
            message = db.execute(
                "SELECT role,status,request_id FROM messages WHERE id=?", (message_id,)
            ).fetchone()
            session = db.execute(
                "SELECT value FROM meta WHERE key IN ('hermes_session_id','pi_session_id','hermes_v2_session_id') AND value=?",
                (session_id,),
            ).fetchone()
            if (not message or message["role"] != "user"
                    or message["status"] not in ("sending", "running")
                    or not message["request_id"] or not session
                    or session["value"] != session_id):
                raise ValueError("reaction_turn_invalid")
            db.execute("DELETE FROM reaction_turns WHERE expires_at<?", (now,))
            db.execute(
                "INSERT OR REPLACE INTO reaction_turns VALUES(?,?,?,?,?)",
                (message_id, session_id, message["request_id"],
                 hashlib.sha256(token.encode()).hexdigest(), now + TURN_LIFETIME_SECONDS),
            )
        return token

    def close_turn(self, message_id: str) -> None:
        with self.db() as db:
            db.execute("DELETE FROM reaction_turns WHERE message_id=?", (message_id,))

    def react(self, message_id: str, reaction_token: str, emoji: ReactionEmoji) -> dict:
        if (not isinstance(message_id, str) or len(message_id) != 32
                or not isinstance(reaction_token, str) or not 32 <= len(reaction_token) <= 100
                or not isinstance(emoji, str) or emoji not in REACTION_EMOJIS):
            raise ValueError("reaction_arguments_invalid")
        now = time.time()
        with self.db() as db:
            target = db.execute(
                "SELECT m.role,m.status,m.request_id,m.reaction,t.session_id,"
                "t.request_id AS turn_request_id,t.capability_hash,t.expires_at "
                "FROM messages m JOIN reaction_turns t ON t.message_id=m.id WHERE m.id=?",
                (message_id,),
            ).fetchone()
            session = db.execute(
                "SELECT value FROM meta WHERE key IN ('hermes_session_id','pi_session_id','hermes_v2_session_id') AND value=?",
                (target["session_id"] if target else "",),
            ).fetchone()
            if (not target or target["role"] != "user"
                    or target["status"] not in ("sending", "running")
                    or not session or target["session_id"] != session["value"]
                    or target["request_id"] != target["turn_request_id"]
                    or target["expires_at"] <= now
                    or not hmac.compare_digest(target["capability_hash"],
                                               hashlib.sha256(reaction_token.encode()).hexdigest())):
                raise ValueError("reaction_target_invalid")
            # One expression per turn; repeated identical tool delivery is idempotent.
            if target["reaction"]:
                existing = json.loads(target["reaction"])
                if existing["emoji"] != emoji:
                    raise ValueError("reaction_already_selected")
                return {"message_id": message_id, "reaction": existing, "created": False}
            db.execute("UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")
            revision = int(db.execute(
                "SELECT value FROM meta WHERE key='revision'"
            ).fetchone()["value"])
            reaction = {
                "emoji": emoji, "event_id": "reaction_" + uuid.uuid4().hex,
                "created_at": now, "actor": "hermes",
            }
            db.execute(
                "UPDATE messages SET reaction=?,revision=?,updated_at=? WHERE id=?",
                (json.dumps(reaction, ensure_ascii=False), revision, now, message_id),
            )
        return {"message_id": message_id, "reaction": reaction, "created": True}
