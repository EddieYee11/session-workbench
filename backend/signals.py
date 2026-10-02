"""Idempotent inbox for explicitly enabled Android notification signals."""

import re
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path


_PACKAGE = re.compile(r"^[A-Za-z0-9_.]{1,160}$")
_EVENT_ID = re.compile(r"^[a-fA-F0-9]{64}$")
_SECRET = re.compile(r"验证码|校验码|动态码|一次性密码|verification code|one.time code|\botp\b", re.I)


class PersonalSignals:
    def __init__(self, state: Path):
        self.path = state / "personal-signals.sqlite"
        with self.db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS signals(
                    event_id TEXT PRIMARY KEY, package_name TEXT NOT NULL,
                    title TEXT NOT NULL, text TEXT NOT NULL,
                    posted_at_ms INTEGER NOT NULL, received_at REAL NOT NULL,
                    status TEXT NOT NULL, sensitive INTEGER NOT NULL DEFAULT 0,
                    conversation_id TEXT NOT NULL DEFAULT '',
                    reply_capable INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS signal_order
                    ON signals(posted_at_ms DESC, received_at DESC);
                CREATE TABLE IF NOT EXISTS reviews(
                    event_id TEXT PRIMARY KEY, inspected_at REAL NOT NULL,
                    priority TEXT NOT NULL, category TEXT NOT NULL,
                    summary TEXT NOT NULL, suggested_record TEXT NOT NULL,
                    draft_reply TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS inspection_state(
                    key TEXT PRIMARY KEY, value TEXT NOT NULL
                );
            """)
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def ingest(self, events: list) -> dict:
        if not isinstance(events, list) or not 1 <= len(events) <= 50:
            raise ValueError("通知批次无效")
        now = time.time()
        normalized = []
        for item in events:
            if not isinstance(item, dict):
                raise ValueError("通知字段无效")
            event_id = item.get("id")
            package_name = item.get("package_name")
            title = item.get("title", "")
            body = item.get("text", "")
            posted = item.get("posted_at_ms")
            conversation_id = item.get("conversation_id", "")
            reply_capable = item.get("reply_capable", False)
            if (
                not isinstance(event_id, str) or not _EVENT_ID.fullmatch(event_id)
                or not isinstance(package_name, str) or not _PACKAGE.fullmatch(package_name)
                or not isinstance(title, str) or len(title) > 180
                or not isinstance(body, str) or len(body) > 1000
                or not isinstance(posted, int)
                or posted < int((now - 30 * 86400) * 1000)
                or posted > int((now + 300) * 1000)
                or not isinstance(conversation_id, str) or len(conversation_id) > 256
                or not isinstance(reply_capable, bool)
            ):
                raise ValueError("通知字段无效")
            sensitive = bool(item.get("sensitive")) or bool(_SECRET.search(title + " " + body))
            if sensitive:
                title, body = "敏感通知", ""
            normalized.append((
                event_id.lower(), package_name, title, body, posted, now, "new",
                int(sensitive), conversation_id, int(reply_capable),
            ))
        accepted, duplicates = [], []
        with self.db() as db:
            db.execute("DELETE FROM signals WHERE received_at<?", (now - 30 * 86400,))
            db.execute("DELETE FROM reviews WHERE event_id NOT IN (SELECT event_id FROM signals)")
            for row in normalized:
                result = db.execute(
                    "INSERT OR IGNORE INTO signals VALUES(?,?,?,?,?,?,?,?,?,?)", row
                )
                (accepted if result.rowcount else duplicates).append(row[0])
        return {"accepted_ids": accepted, "duplicate_ids": duplicates, "received_at": now}

    def recent(self, limit: int = 50) -> dict:
        limit = max(1, min(limit, 100))
        with self.db() as db:
            rows = db.execute(
                "SELECT s.event_id,s.package_name,s.title,s.text,s.posted_at_ms,"
                "s.received_at,s.status,s.sensitive,s.conversation_id,s.reply_capable,"
                "r.inspected_at,r.priority,r.category,r.summary,r.suggested_record,"
                "r.draft_reply"
                " FROM signals s LEFT JOIN reviews r ON r.event_id=s.event_id"
                " ORDER BY s.posted_at_ms DESC,s.received_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
            count = db.execute("SELECT COUNT(*) FROM signals").fetchone()[0]
        return {"items": [dict(row) for row in rows], "count": count}

    def pending(self, limit: int = 10) -> list[dict]:
        with self.db() as db:
            rows = db.execute(
                "SELECT event_id,package_name,title,text,posted_at_ms,sensitive"
                " FROM signals WHERE status='new' AND sensitive=0"
                " ORDER BY received_at,event_id LIMIT ?", (limit,),
            ).fetchall()
        return [dict(row) for row in rows]

    def prune(self) -> None:
        with self.db() as db:
            db.execute("DELETE FROM signals WHERE received_at<?", (time.time() - 30 * 86400,))
            db.execute("DELETE FROM reviews WHERE event_id NOT IN (SELECT event_id FROM signals)")

    def mark_reviewed(self, event_id: str, review: dict) -> None:
        priority = review.get("priority")
        category = review.get("category")
        summary = review.get("summary")
        suggestion = review.get("suggested_record", "")
        draft = review.get("draft_reply", "")
        if (
            priority not in ("normal", "important")
            or category not in ("general", "schedule", "finance", "work", "contact")
            or not isinstance(summary, str) or not 1 <= len(summary) <= 140
            or not isinstance(suggestion, str) or len(suggestion) > 200
            or not isinstance(draft, str) or len(draft) > 300
        ):
            raise ValueError("通知巡检结果无效")
        now = time.time()
        with self.db() as db:
            row = db.execute("SELECT status FROM signals WHERE event_id=?", (event_id,)).fetchone()
            if not row or row["status"] != "new":
                return
            db.execute("UPDATE signals SET status='reviewed' WHERE event_id=?", (event_id,))
            db.execute(
                "INSERT OR REPLACE INTO reviews VALUES(?,?,?,?,?,?,?)",
                (event_id, now, priority, category, summary, suggestion, draft),
            )
            db.execute(
                "INSERT OR REPLACE INTO inspection_state VALUES('last_success',?)", (str(now),)
            )

    def mark_sensitive_skipped(self) -> None:
        with self.db() as db:
            db.execute("UPDATE signals SET status='sensitive_skipped' WHERE status='new' AND sensitive=1")

    def health(self) -> dict:
        with self.db() as db:
            counts = {r["status"]: r["n"] for r in db.execute(
                "SELECT status,COUNT(*) AS n FROM signals GROUP BY status"
            )}
            attention = db.execute(
                "SELECT COUNT(*) FROM reviews WHERE priority='important'"
            ).fetchone()[0]
            state = {r["key"]: r["value"] for r in db.execute(
                "SELECT key,value FROM inspection_state"
            )}
        return {
            "pending": counts.get("new", 0),
            "reviewed": counts.get("reviewed", 0),
            "sensitive_skipped": counts.get("sensitive_skipped", 0),
            "important": attention,
            "last_success": float(state.get("last_success", 0)),
            "last_attempt": float(state.get("last_attempt", 0)),
            "last_error": state.get("last_error", ""),
            "interval_minutes": 30,
        }

    def inspection_attempt(self, error: str = "") -> None:
        now = time.time()
        with self.db() as db:
            db.execute("INSERT OR REPLACE INTO inspection_state VALUES('last_attempt',?)", (str(now),))
            db.execute("INSERT OR REPLACE INTO inspection_state VALUES('last_error',?)", (error,))
