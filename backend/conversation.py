"""Durable Com main conversation with replaceable native transport and stable UI IDs."""

import asyncio
import json
import re
import sqlite3
import stat
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import AsyncIterator

import httpx
import capabilities
from reactions import ReactionStore, install_schema, project_message
from message_references import canonical_reference, reference_identity, referenced_input
from work_cards import accepted, linked_card, project_work


class HermesClient:
    def __init__(self, state: Path, base_url: str = "http://127.0.0.1:8649"):
        self.key_file = state / "hermes-api-key"
        self.base_url = base_url.rstrip("/")

    def key(self) -> str:
        try:
            info = self.key_file.stat()
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
                raise ValueError("hermes_key_permissions")
            key = self.key_file.read_text().strip()
            if not key:
                raise ValueError("hermes_key_missing")
            return key
        except FileNotFoundError:
            raise ValueError("hermes_key_missing") from None

    async def request(
        self, method: str, path: str, body: dict | None = None, timeout: float = 20
    ) -> dict:
        key = self.key()
        async with httpx.AsyncClient(timeout=timeout, trust_env=False, follow_redirects=False) as client:
            response = await client.request(
                method, self.base_url + path, json=body,
                headers={"Authorization": "Bearer " + key},
            )
        if response.status_code >= 400:
            raise RuntimeError("hermes_api_" + str(response.status_code))
        data = response.json()
        if not isinstance(data, dict):
            raise RuntimeError("hermes_invalid_response")
        return data

    async def create_session(self) -> str:
        sid = "com-personal-main"
        try:
            data = await self.request(
                "POST", "/api/sessions",
                {"id": sid, "source": "api_server", "title": "Com! 主对话"},
            )
        except RuntimeError as exc:
            if str(exc) != "hermes_api_409":
                raise
            data = await self.request("GET", "/api/sessions/" + sid)
        session = data.get("session", data)
        returned_id = session.get("id") if isinstance(session, dict) else None
        if returned_id != sid:
            raise RuntimeError("hermes_session_missing")
        return sid

    async def chat(self, session_id: str, text: str) -> str:
        data = await self.request(
            "POST", "/api/sessions/" + session_id + "/chat",
            {"message": text}, timeout=600,
        )
        message = data.get("message")
        output = message.get("content") if isinstance(message, dict) else None
        if not isinstance(output, str):
            raise RuntimeError("hermes_reply_missing")
        return output

    async def stream_chat(self, session_id: str, text: str) -> AsyncIterator[tuple[str, dict]]:
        """Parse Hermes' session-chat SSE without exposing its transport to Com clients."""
        timeout = httpx.Timeout(connect=10, read=120, write=20, pool=10)
        async with httpx.AsyncClient(timeout=timeout, trust_env=False, follow_redirects=False) as client:
            async with client.stream(
                "POST", self.base_url + "/api/sessions/" + session_id + "/chat/stream",
                json={"message": text},
                headers={"Authorization": "Bearer " + self.key(), "Accept": "text/event-stream"},
            ) as response:
                if response.status_code >= 400:
                    raise RuntimeError("hermes_api_" + str(response.status_code))
                if "text/event-stream" not in response.headers.get("content-type", ""):
                    raise RuntimeError("hermes_invalid_stream")
                event = "message"
                data_lines: list[str] = []
                async for line in response.aiter_lines():
                    if not line:
                        if data_lines:
                            try:
                                payload = json.loads("\n".join(data_lines))
                            except ValueError as exc:
                                raise RuntimeError("hermes_invalid_event") from exc
                            if not isinstance(payload, dict):
                                raise RuntimeError("hermes_invalid_event")
                            yield event, payload
                        event, data_lines = "message", []
                    elif line.startswith("event:"):
                        event = line[6:].strip()
                    elif line.startswith("data:"):
                        data_lines.append(line[5:].lstrip(" "))
                        if sum(len(part) for part in data_lines) > 4_000_000:
                            raise RuntimeError("hermes_event_too_large")
                if data_lines:
                    raise RuntimeError("hermes_truncated_event")


class PersonalConversation:
    def __init__(self, state: Path, client: HermesClient | None = None):
        self.path = state / "personal-conversation.sqlite"
        self.client = client or HermesClient(state)
        self.reactions = ReactionStore(state)
        self.wake = asyncio.Event()
        self.changed = asyncio.Condition()
        self.task: asyncio.Task | None = None
        with self.db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS messages(
                    id TEXT PRIMARY KEY, request_id TEXT UNIQUE, parent_id TEXT,
                    role TEXT NOT NULL, text TEXT NOT NULL, status TEXT NOT NULL,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    run_id TEXT, error TEXT
                );
                CREATE INDEX IF NOT EXISTS personal_message_order
                    ON messages(created_at, id);
            """)
            columns = {row["name"] for row in db.execute("PRAGMA table_info(messages)")}
            for name, definition in (
                ("phase", "TEXT NOT NULL DEFAULT ''"),
                ("active_tool", "TEXT"),
                ("received_at", "REAL"),
                ("revision", "INTEGER NOT NULL DEFAULT 0"),
                ("reaction", "TEXT"),
                ("reference", "TEXT"),
                ("tasks", "TEXT"),
                ("supplement_to_message_id", "TEXT"),
                ("work_card", "TEXT"),
                ("new_item", "TEXT"),
                ("artifacts", "TEXT NOT NULL DEFAULT '[]'"),
            ):
                if name not in columns:
                    db.execute(f"ALTER TABLE messages ADD COLUMN {name} {definition}")
            db.execute("INSERT OR IGNORE INTO meta(key,value) VALUES('revision','0')")
            db.execute("CREATE TABLE IF NOT EXISTS user_events(request_id TEXT PRIMARY KEY,message_id TEXT NOT NULL,state TEXT NOT NULL)")
            db.execute("CREATE INDEX IF NOT EXISTS user_events_message ON user_events(message_id)")
            db.execute("CREATE TABLE IF NOT EXISTS ledger_cards(id TEXT PRIMARY KEY,data TEXT NOT NULL,revision INTEGER NOT NULL)")
            install_schema(db)
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

    @staticmethod
    def _bump(db: sqlite3.Connection) -> int:
        db.execute("UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")
        return int(db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()["value"])

    def _notify(self) -> None:
        try:
            asyncio.get_running_loop().create_task(self._notify_waiters())
        except RuntimeError:
            pass

    async def _notify_waiters(self) -> None:
        async with self.changed:
            self.changed.notify_all()

    def task_receipt(self, task_id: str, text: str, parent_id: str | None = None):
        """Idempotent outbox sink, including a crash before outbox acknowledgement."""
        with self.db() as db:
            key = 'task-result:' + task_id
            if db.execute('SELECT id FROM messages WHERE request_id=?', (key,)).fetchone():
                return
            revision = self._bump(db)
            at = time.time()
            if parent_id and not db.execute("SELECT 1 FROM messages WHERE id=? AND role='user'", (parent_id,)).fetchone():
                parent_id = None
            db.execute("INSERT INTO messages(id,request_id,parent_id,role,text,status,phase,revision,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                       (key, key, parent_id, 'assistant', text, 'completed', 'completed', revision, at, at))
        self._notify()

    def task_receipt_for_message(self, task_id: str, text: str, parent_id: str):
        return self.task_receipt(task_id, text, parent_id)

    def submit(self, request_id: str, text: str, reference: dict | None = None, *, new_item: dict | None = None) -> dict:
        text = text.strip()
        if not 10 <= len(request_id) <= 100 or not 1 <= len(text) <= 8000:
            raise ValueError("消息或请求标识无效")
        identity = reference_identity(reference, "personal-main")
        with self.db() as db:
            old = db.execute(
                "SELECT id,text,status,reference,new_item FROM messages WHERE request_id=?", (request_id,)
            ).fetchone()
            if old:
                saved_reference = json.loads(old["reference"]) if old["reference"] else None
                if ((json.loads(old["new_item"]) if old["new_item"] else None) != new_item or old["text"] != text
                        or reference_identity(saved_reference, "personal-main") != identity):
                    raise ValueError("请求标识冲突")
                return {"status": old["status"], "request_id": request_id, "message_id": old["id"]}
            def lookup(session: str, ident: str) -> dict | None:
                if session == "personal-main":
                    source = db.execute("SELECT id,role,text FROM messages WHERE id=?", (ident,)).fetchone()
                    return dict(source) if source else None
                return getattr(self, "reference_lookup", lambda _session, _id: None)(session, ident)
            saved_reference = canonical_reference(reference, lookup, "personal-main")
            mid = uuid.uuid4().hex
            now = time.time()
            revision = self._bump(db)
            db.execute(
                "INSERT INTO messages(id,request_id,role,text,status,phase,revision,created_at,updated_at,reference,new_item)"
                " VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (mid, request_id, "user", text, "queued", "queued", revision, now, now,
                 json.dumps(saved_reference, ensure_ascii=False) if saved_reference else None,
                 json.dumps(new_item) if new_item else None),
            )
            db.execute("INSERT OR IGNORE INTO user_events VALUES (?,?,'queued')",(request_id,mid))
        self.wake.set()
        self._notify()
        return {"status": "accepted", "request_id": request_id, "message_id": mid}

    @staticmethod
    def _runs(messages: list[dict]) -> list[dict]:
        return [
            {
                "message_id": message["id"], "run_id": message["run_id"],
                "status": message["status"], "phase": message["phase"],
                "active_tool": message["active_tool"],
                "received_at": message["received_at"],
            }
            for message in messages
            if message["role"] == "user" and message["status"] in
            ("queued", "sending", "running", "unknown", "approval_required")
        ]

    @staticmethod
    def _message_query(where: str = "") -> str:
        return (
            "SELECT id,request_id,parent_id,supplement_to_message_id,role,text,status,phase,active_tool,tasks,work_card,artifacts,"
            "(SELECT state FROM user_events WHERE user_events.message_id=messages.id) AS delivery_state,"
            "received_at,revision,created_at,updated_at,run_id,error,reaction,reference FROM messages " + where
        )

    @staticmethod
    def _project_message(row) -> dict:
        message = project_message(row)
        message["reference"] = json.loads(message["reference"]) if message["reference"] else None
        message["tasks"] = json.loads(message["tasks"]) if message["tasks"] else []
        message["artifacts"]=json.loads(message.get("artifacts") or "[]")
        return project_work(message)

    def attach_artifact(self, message_id, artifact):
        with self.db() as db:
            row=db.execute('SELECT artifacts FROM messages WHERE id=?',(message_id,)).fetchone()
            if not row:raise ValueError('成果来源消息不存在')
            items=json.loads(row[0] or '[]')
            if any(item.get('id')==artifact['id'] for item in items):return
            items.append(artifact)
            revision=self._bump(db)
            db.execute('UPDATE messages SET artifacts=?,revision=?,updated_at=? WHERE id=?',(json.dumps(items,ensure_ascii=False),revision,time.time(),message_id))
        self._notify()

    def sync_task_cards(self, tasks: list[dict]) -> None:
        """Project the ledger onto its real source messages and the same durable SSE."""
        by_message = {}
        changed = False
        for task in tasks:
            sources = set(task.get('source_message_ids', [])) | {task.get('origin_message_id')}
            for mid in sources - {None, ''}:
                by_message.setdefault(mid, []).append(task)
        with self.db() as db:
            for mid, linked in by_message.items():
                row = db.execute('SELECT work_card FROM messages WHERE id=? AND role=?', (mid, 'user')).fetchone()
                if not row:
                    continue
                data = json.dumps(linked_card(linked), ensure_ascii=False, sort_keys=True)
                if row[0] == data:
                    continue
                revision = self._bump(db)
                db.execute('UPDATE messages SET work_card=?,revision=? WHERE id=?', (data, revision, mid))
                changed = True
            for task in tasks:
                # Keep the live detail useful without broadcasting unbounded native logs.
                detail = {**task, 'acceptance_passed': accepted(task), 'events': task.get('events', [])[-80:], 'inputs': task.get('inputs', [])[-20:]}
                data = json.dumps(detail, ensure_ascii=False, sort_keys=True)
                old = db.execute('SELECT data FROM ledger_cards WHERE id=?', (task['id'],)).fetchone()
                if old and old[0] == data:
                    continue
                revision = self._bump(db)
                db.execute('INSERT OR REPLACE INTO ledger_cards VALUES (?,?,?)', (task['id'], data, revision))
                changed = True
        if changed:
            self._notify()

    def _active_runs(self, db: sqlite3.Connection) -> list[dict]:
        rows = db.execute(self._message_query(
            "WHERE role='user' AND status IN "
            "('queued','sending','running','unknown','approval_required') "
            "ORDER BY created_at,id"
        )).fetchall()
        return self._runs([dict(row) for row in rows])

    def snapshot(self) -> dict:
        with self.db() as db:
            db.execute("BEGIN")
            revision = int(db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()["value"])
            rows = db.execute(
                self._message_query("ORDER BY created_at DESC,id DESC LIMIT 500")
            ).fetchall()
            runs = self._active_runs(db)
            tasks = [json.loads(r[0]) for r in db.execute('SELECT data FROM ledger_cards ORDER BY revision')]
        messages = [self._project_message(row) for row in reversed(rows)]
        return {
            "conversation_id": "personal-main", "revision": revision,
            "messages": messages, "runs": runs, "tasks": tasks,
        }

    def changes_since(self, revision: int) -> dict:
        if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
            raise ValueError("无效的会话版本")
        with self.db() as db:
            db.execute("BEGIN")
            current = int(db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()["value"])
            rows = db.execute(
                self._message_query("WHERE revision>? AND revision<=? ORDER BY revision,created_at,id"),
                (revision, current),
            ).fetchall()
            runs = self._active_runs(db)
            tasks = [json.loads(r[0]) for r in db.execute('SELECT data FROM ledger_cards WHERE revision>? AND revision<=? ORDER BY revision', (revision, current))]
        messages = [self._project_message(row) for row in rows]
        return {
            "conversation_id": "personal-main", "revision": current,
            "messages": messages, "runs": runs, "changed_tasks": tasks,
        }

    def history(self, before: str = "", around: str = "", limit: int = 60) -> dict:
        """Read-only keyset pages; never restore the native agent."""
        limit = max(1, min(limit, 100))
        with self.db() as db:
            if around:
                anchor = db.execute("SELECT created_at,id FROM messages WHERE id=?", (around,)).fetchone()
                if not anchor:
                    raise ValueError("原消息不存在")
                earlier = db.execute(self._message_query("WHERE (created_at,id)<(?,?) ORDER BY created_at DESC,id DESC LIMIT ?"), (*anchor, limit // 2)).fetchall()
                later = db.execute(self._message_query("WHERE (created_at,id)>=(?,?) ORDER BY created_at,id LIMIT ?"), (*anchor, limit - len(earlier))).fetchall()
                rows = list(reversed(earlier)) + list(later)
            else:
                if before:
                    anchor = db.execute("SELECT created_at,id FROM messages WHERE id=?", (before,)).fetchone()
                    if not anchor:
                        raise ValueError("分页位置不存在")
                    rows = db.execute(self._message_query("WHERE (created_at,id)<(?,?) ORDER BY created_at DESC,id DESC LIMIT ?"), (*anchor, limit)).fetchall()
                else:
                    rows = db.execute(self._message_query("ORDER BY created_at DESC,id DESC LIMIT ?"), (limit,)).fetchall()
                rows = list(reversed(rows))
            more = bool(rows and db.execute("SELECT 1 FROM messages WHERE (created_at,id)<(?,?) LIMIT 1", (rows[0]["created_at"], rows[0]["id"])).fetchone())
        return {"messages": [self._project_message(r) for r in rows], "has_more": more,
                "next_before": rows[0]["id"] if more else ""}

    def search(self, query: str = "", date: str = "", limit: int = 40) -> dict:
        clauses, params = [], []
        if query.strip():
            # instr is literal: percent and underscore are never wildcards.
            clauses.append("instr(lower(text), lower(?))>0")
            params.append(query.strip()[:200])
        if date:
            from datetime import datetime
            from zoneinfo import ZoneInfo
            try:
                start = datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=ZoneInfo("Asia/Shanghai")).timestamp()
            except ValueError:
                raise ValueError("日期格式应为 YYYY-MM-DD") from None
            clauses.append("created_at>=? AND created_at<?")
            params.extend([start, start + 86400])
        if not clauses:
            return {"items": []}
        with self.db() as db:
            rows = db.execute("SELECT id,role,text,created_at FROM messages WHERE " + " AND ".join(clauses) + " ORDER BY created_at DESC,id DESC LIMIT ?", (*params, max(1, min(limit, 100)))).fetchall()
        return {"items": [{**dict(r), "text": r["text"][:400], "source": "Pi 主对话"} for r in rows]}

    async def stream(self, after_revision: int | None = None) -> AsyncIterator[dict]:
        """Resume from durable revisions, fall back when the cursor is invalid."""
        if after_revision is not None and (
            isinstance(after_revision, bool) or not isinstance(after_revision, int) or after_revision < 0
        ):
            raise ValueError("无效的会话版本")
        state = self.changes_since(after_revision) if after_revision is not None else self.snapshot()
        if after_revision is not None and after_revision <= state["revision"]:
            seen = state["revision"]
            yield {"event": "update", "id": seen, "data": state}
        else:
            state = self.snapshot()
            seen = state["revision"]
            yield {"event": "snapshot", "id": seen, "data": state}
        while True:
            change = self.changes_since(seen)
            if change["revision"] > seen:
                seen = change["revision"]
                yield {"event": "update", "id": seen, "data": change}
                continue
            timed_out = False
            async with self.changed:
                if self.changes_since(seen)["revision"] <= seen:
                    try:
                        await asyncio.wait_for(self.changed.wait(), timeout=15)
                    except asyncio.TimeoutError:
                        timed_out = True
            if timed_out:
                yield {"event": "keepalive", "id": seen, "data": {}}

    def _next(self):
        with self.db() as db:
            return db.execute(
                "SELECT * FROM messages WHERE role='user' AND status IN"
                " ('queued','sending','running') ORDER BY created_at,id LIMIT 1"
            ).fetchone()

    def _set(
        self, mid: str, status: str, run_id: str | None = None,
        error: str | None = None, *, phase: str | None = None,
        active_tool: str | None = None, received: bool = False,
    ):
        with self.db() as db:
            revision = self._bump(db)
            db.execute(
                "UPDATE messages SET status=?,phase=?,active_tool=?,"
                "received_at=CASE WHEN ? THEN COALESCE(received_at,?) ELSE received_at END,"
                "revision=?,run_id=COALESCE(?,run_id),error=?,updated_at=?"
                " WHERE id=?",
                (
                    status, phase or status, active_tool, int(received), time.time(),
                    revision, run_id, error, time.time(), mid,
                ),
            )
        self._notify()

    @staticmethod
    def _tool_task_title(name: str | None) -> str:
        """工具调用转任务标题；与客户端 AgentWorkCard 的文案保持一致。"""
        if not name:
            return "调用工具"
        if name.endswith("personal_overview"):
            return "正在读取日历与账本概览"
        if name.endswith("recent_work_sessions"):
            return "正在核对工作会话"
        if name.endswith("propose_work"):
            return "正在准备工作建议"
        if name.endswith("work_proposal_status"):
            return "正在核对工作建议"
        return f"正在使用 {name[:46]}"

    def _record_tasks(self, mid: str, tasks: list) -> None:
        """持久化某条用户消息的工作任务清单并通知订阅者。"""
        with self.db() as db:
            revision = self._bump(db)
            db.execute(
                "UPDATE messages SET tasks=?,revision=?,updated_at=? WHERE id=?",
                (json.dumps(tasks, ensure_ascii=False), revision, time.time(), mid),
            )
        self._notify()

    @staticmethod
    def _finish_running_tasks(tasks: list, status: str) -> None:
        for task in tasks:
            if task.get("status") == "running":
                task["status"] = status

    def _finalize_tasks(self, db: sqlite3.Connection, mid: str) -> None:
        """A settled reply does not prove an unclosed tool actually completed."""
        row = db.execute("SELECT tasks FROM messages WHERE id=?", (mid,)).fetchone()
        if not row or not row["tasks"]:
            return
        try:
            tasks = json.loads(row["tasks"])
        except (json.JSONDecodeError, TypeError):
            return
        if not isinstance(tasks, list):
            return
        changed = False
        for task in tasks:
            if isinstance(task, dict) and task.get("status") == "running":
                task["status"] = "unknown"
                changed = True
        if changed:
            db.execute("UPDATE messages SET tasks=? WHERE id=?",
                       (json.dumps(tasks, ensure_ascii=False), mid))

    def _assistant(
        self, mid: str, text: str, *, append: bool = False,
        status: str = "streaming", phase: str = "responding",
    ) -> None:
        with self.db() as db:
            existing = db.execute(
                "SELECT id,text FROM messages WHERE parent_id=? AND role='assistant'", (mid,)
            ).fetchone()
            revision = self._bump(db)
            now = time.time()
            if existing:
                content = existing["text"] + text if append else text
                db.execute(
                    "UPDATE messages SET text=?,status=?,phase=?,revision=?,updated_at=? WHERE id=?",
                    (content, status, phase, revision, now, existing["id"]),
                )
            else:
                db.execute(
                    "INSERT INTO messages(id,parent_id,role,text,status,phase,revision,created_at,updated_at)"
                    " VALUES(?,?,?,?,?,?,?,?,?)",
                    (uuid.uuid4().hex, mid, "assistant", text, status, phase, revision, now, now),
                )
            db.execute(
                "UPDATE messages SET status='running',phase=?,active_tool=NULL,"
                "received_at=CASE WHEN ? THEN COALESCE(received_at,?) ELSE received_at END,revision=?,updated_at=?"
                " WHERE id=?",
                (phase, getattr(self.client, 'runtime_name', None) != 'pi', now, revision, now, mid),
            )
        self._notify()

    def _session_id(self) -> str | None:
        key = getattr(self.client, 'session_key', 'hermes_session_id')
        with self.db() as db:
            row = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row['value'] if row else None

    def accepts_origin(self, sid, mid):
        if sid == self._session_id():
            return True
        with self.db() as db:
            row = db.execute('SELECT value FROM meta WHERE key=?', ('origin-map:'+str(sid),)).fetchone()
        if not row:
            return False
        mapping = json.loads(row[0])
        with self.db() as db:
            message = db.execute('SELECT created_at FROM messages WHERE id=?', (mid,)).fetchone()
        return bool(message and mapping.get('to')==self._session_id() and message[0] <= mapping['boundary'])

    async def _ensure_session(self) -> str:
        sid = self._session_id()
        if sid:
            return sid
        sid = await self.client.create_session()
        key = getattr(self.client, 'session_key', 'hermes_session_id')
        with self.db() as db:
            db.execute('INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)', (key,sid))
            if key != 'hermes_session_id':
                old=db.execute("SELECT value FROM meta WHERE key='hermes_session_id'").fetchone()
                boundary=time.time()
                if old:
                    db.execute('INSERT OR IGNORE INTO meta VALUES (?,?)',
                        ('origin-map:'+old[0],json.dumps({'to':sid,'boundary':boundary})))
                db.execute("INSERT OR IGNORE INTO meta VALUES ('pi_cutover_boundary',?)",(str(boundary),))
        return self._session_id() or sid

    def _finish(self, mid: str, status: str, output: str = "", error: str | None = None):
        with self.db() as db:
            existing = db.execute(
                "SELECT id FROM messages WHERE parent_id=? AND role='assistant'", (mid,)
            ).fetchone()
            revision = self._bump(db)
            now = time.time()
            db.execute(
                "UPDATE messages SET status=?,phase=?,active_tool=NULL,error=?,revision=?,updated_at=?"
                " WHERE id=?",
                (status, status, error, revision, now, mid),
            )
            if status == "completed":
                self._finalize_tasks(db, mid)
            db.execute("UPDATE user_events SET state=CASE WHEN state='delivered' THEN state ELSE ? END WHERE message_id=?",(status,mid))
            if existing:
                db.execute(
                    "UPDATE messages SET text=CASE WHEN ?<>'' THEN ? ELSE text END,"
                    "status=?,phase=?,revision=?,updated_at=? WHERE id=?",
                    (output, output, status, status, revision, now, existing["id"]),
                )
            elif output:
                db.execute(
                    "INSERT INTO messages(id,parent_id,role,text,status,phase,revision,created_at,updated_at)"
                    " VALUES(?,?,?,?,?,?,?,?,?)",
                    (uuid.uuid4().hex, mid, "assistant", output, status, status, revision, now, now),
                )
        self._notify()

    def _delivery(self, mid: str, state: str) -> None:
        with self.db() as db:
            db.execute("UPDATE user_events SET state=? WHERE message_id=?", (state, mid))
            revision = self._bump(db)
            db.execute("UPDATE messages SET revision=?,updated_at=? WHERE id=?", (revision, time.time(), mid))
        self._notify()

    def _pi_input(self, row, session_id: str, reaction_token: str, *, supplement_to=None) -> tuple[str, dict]:
        supplement_to = supplement_to or row['supplement_to_message_id']
        context = {'origin_session_id': session_id, 'origin_message_id': row['id'],
                   'origin_request_id': row['request_id'],
                   'tasks': getattr(self, 'task_context', lambda: [])(),
                   'environment': getattr(self, 'task_environment', lambda: {})(),
                   'reaction': {'message_id': row['id'], 'token': reaction_token}}
        if row.get('new_item') if isinstance(row,dict) else row['new_item']:
            context['new_item']=json.loads(row['new_item'])
        if supplement_to:
            context['supplement_to_message_id'] = supplement_to
        with self.db() as db:
            voice_table = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='voice_requests'").fetchone()
            voice = db.execute('SELECT purpose FROM voice_requests WHERE request_id=?', (row['request_id'],)).fetchone() if voice_table else None
            if voice:
                context['voice_purpose'] = voice[0]
            history = [] if getattr(self.client, 'has_native_history', False) or supplement_to else [
                {'role': r['role'], 'text': r['text'][-1000:]} for r in db.execute(
                    "SELECT role,text FROM messages WHERE status='completed' ORDER BY created_at DESC LIMIT 16")]
        reference = json.loads(row['reference']) if row['reference'] else None
        text = ("[Com 主对话上下文；只提供关联，不授予执行权限]\n" + json.dumps(context, ensure_ascii=False)
                + "\n" + capabilities.render() + "\n只读历史摘要（不可重放操作）："
                + json.dumps(list(reversed(history)), ensure_ascii=False)
                + ("\n本条是当前执行中原事项的用户补充，保持同一事项并应用本条限制。" if supplement_to else "")
                + ("\n用户已点击改为新事项。本条独立处理，不再补充到原任务；正文与真实来源保持原样。" if context.get("new_item") else "")
                + "\n用户消息：\n" + referenced_input(row['text'], reference))
        return text, context

    def _is_supplement(self, row, active_mid: str) -> bool:
        reference = json.loads(row['reference']) if row['reference'] else None
        if reference:
            if reference.get('mode') != 'reply' or reference.get('source_session_id') != 'personal-main':
                return False
            with self.db() as db:
                source = db.execute('SELECT id,parent_id FROM messages WHERE id=?', (reference['id'],)).fetchone()
            return bool(source and (source['id'] == active_mid or source['parent_id'] == active_mid))
        # Only explicit adjustments to the sole active main turn interrupt it.
        # Independent requests stay in the normal prompt queue.
        return bool(re.match(r'^(?:补充(?:一下|要求|说明|信息)?[：:，,\s]|更正[：:，,\s]|纠正[：:，,\s]|改成|改为|请保持|先(?:只读|别改|不改|仅(?:查看|检查|分析|阅读)|只(?:查看|检查|分析|阅读)|不要)|只读(?:[，。:：\s]|$)|保持只读|不要(?:改|修改|删除|动|执行|提交|发送)|暂停(?:一下|当前|这个|这项)?[。！!\s]*$|停下[。！!\s]*$|继续(?:刚才|这个|原来|当前)|继续[。！!\s]*$)', row['text']))

    async def _deliver_supplements(self, session_id: str, active_mid: str, supplements: dict) -> None:
        while True:
            with self.db() as db:
                queued = db.execute("SELECT * FROM messages WHERE role='user' AND status='queued' ORDER BY created_at,id").fetchall()
            for row in queued:
                if row['id'] == active_mid or not self._is_supplement(row, active_mid):
                    continue
                mid = row['id']
                with self.db() as db:
                    db.execute('UPDATE messages SET supplement_to_message_id=? WHERE id=?', (active_mid, mid))
                self._set(mid, 'sending', phase='awaiting_delivery')
                self._delivery(mid, 'sending')
                supplements[row['request_id']] = mid
                try:
                    token = self.reactions.open_turn(mid, session_id)
                    text, context = self._pi_input(row, session_id, token, supplement_to=active_mid)
                    receipt = await self.client.steer_chat(session_id, text, row['request_id'], context)
                    if receipt.get('state') == 'not_sent':
                        # Native idle was observed before writing any command.
                        supplements.pop(row['request_id'], None)
                        self._set(mid, 'queued')
                        self._delivery(mid, 'queued')
                        self.reactions.close_turn(mid)
                        return
                    with self.db() as db:
                        state = db.execute('SELECT state FROM user_events WHERE message_id=?', (mid,)).fetchone()[0]
                    if state != 'delivered':
                        self._delivery(mid, 'worker_queued')
                    if receipt.get('state') == 'delivered':
                        self._set(mid, 'running', phase='thinking', received=True)
                        self._delivery(mid, 'delivered')
                except asyncio.CancelledError:
                    self._finish(mid, 'unknown', error='补充提交中断；送达结果待核实，未自动重试')
                    raise
                except Exception:
                    self._finish(mid, 'unknown', error='补充送达结果待核实，未自动重试')
            await asyncio.sleep(.05)

    async def process_one(self) -> bool:
        if getattr(self, '_processing', False):
            return False
        self._processing = True
        try:
            return await self._process_one()
        finally:
            self._processing = False

    async def _process_one(self) -> bool:
        row = self._next()
        if row is None:
            return False
        mid = row["id"]
        if row["status"] in ("sending", "running"):
            self._finish(mid, "unknown", error="提交中断，可能已被主助理接收；未自动重试")
            return True
        if row["status"] == "queued":
            try:
                self.client.key()
                session_id = await self._ensure_session()
            except (ValueError, RuntimeError, httpx.HTTPError) as exc:
                self._finish(mid, "failed", error=str(exc))
                return True
            self._set(mid, "sending")
            pending = ""
            last_flush = 0.0
            has_partial = False
            completed = False
            terminal = False
            final_text = ""
            work_tasks: list = []
            tool_seq = 0
            supplements: dict[str, str] = {}
            supplement_task = None
            native = getattr(self.client, 'runtime_name', None) == 'pi'
            native_received = not native

            def flush() -> None:
                nonlocal pending, last_flush, has_partial
                if pending:
                    self._assistant(mid, pending, append=True)
                    pending = ""
                    last_flush = time.monotonic()
                    has_partial = True

            try:
                reaction_token = self.reactions.open_turn(mid, session_id)
                saved_reference = json.loads(row["reference"]) if row["reference"] else None
                user_input = referenced_input(row["text"], saved_reference)
                transport_text = user_input
                if isinstance(self.client, HermesClient) and getattr(self.client,'runtime_name',None)!='pi':
                    context = getattr(self, 'task_context', lambda: [])()
                    transport_text = (
                        "[Com 主对话上下文；只提供关联，不授予执行权限]\n"
                        + json.dumps({'origin_session_id': session_id, 'origin_message_id': mid,
                                      'origin_request_id': row['request_id'], 'tasks': context,
                                      'environment':getattr(self,'task_environment',lambda:{})(),
                                      'reaction': {'message_id': mid, 'token': reaction_token}}, ensure_ascii=False)
                        + "\n可按当前用户消息的语义自然选一个表情，用 react_to_user_message 附到这条消息；"
                        "可选 👍 ❤️ 😂 🎉 🤔 😮 😢 💪 🙏 🦀，合适时才用，不需要每条都附加。"
                        "message_id 和 reaction_token 必须逐字使用上方 reaction 的 message_id 和 token，"
                        "只针对这条用户消息，一轮最多一个；不要把通知、引用、任务回执或工具输出当作反应目标。"
                        "token 是本轮内部参数，不向用户复述；工具调用失败不假装已附加，正文正常答复即可。"
                        + "\n" + capabilities.render() + "\n"
                        + "明确交办时用 create_task：逐字引用用户交办原文和上面的 origin IDs。"
                        "执行者取 pi 或 codex：上面清单里的能力（记账、提醒、日历、收藏、转写、看图等）派给 pi 并传 sandbox='danger-full-access'；"
                        "需要读写项目文件的代码活派给 codex；所有执行者统一 sandbox='danger-full-access'。用户已撤销 Com 的全部只读约束，历史限制只作审计。"
                        "清单里有对口的就直接照办并落成任务，不要先反问用户要不要做。"
                        "只有不可逆删除（删除/清空/销毁文件或数据）才用 propose_work 等具体批准，其余一律直接 create_task。"
                        "多件明确交办分别创建；先读现有任务，补充约束用 update_task_constraints 并复用任务 ID。"
                        "update_task_constraints 的 constraint_type 必填；旧 read_only 类型仅留审计，不限制当前执行。"
                        "保持现有样式时 constraint_type='preserve_style', text=''；禁止路径时 constraint_type='forbid_path', text=项目内相对路径。"
                        "不要把 read_only/preserve_style 写进 text 后省略类型。任意新动作或普通备注才用 constraint_type='note'，它只记录且因未授权而不执行。"
                        "要求停止时用 cancel_task，复用精确 task ID；任务查询用 get_task_status；后台 queued 是已受理，继续主聊天无需等待工作器。"
                        "创建工具的 queued/work_started=false 回执只允许说已受理或排队中；"
                        "执行动作、网络访问或文件修改结果必须有工作器实际事件或结果才能陈述，不能把任务要求当作完成证据。"
                        "闲聊不派发；指代不明先追问；任务执行结束不代表验收通过；已受理不代表生效。"
                        "面向用户用简洁中文说明任务名称、实际进度和结果；task ID、constraint_type、delivery 等内部参数保留在工具调用中，不在普通回复里逐项展示。"
                        "补充要求先说已给原任务补充、仍待送达，真实回执已确认时才说已送达；无需重复解释规则或询问是否继续跟进。"
                        "删除、权限扩张不能由工作建议获得授权。\n用户消息：\n" + user_input)
                if native:
                    transport_text, context = self._pi_input(row, session_id, reaction_token)
                async for event, payload in self.client.stream_chat(session_id, transport_text):
                    if terminal and event != "done":
                        continue
                    if event == "run.started":
                        run_id = payload.get("run_id")
                        self._set(
                            mid, "sending" if native else "running", run_id if isinstance(run_id, str) else None,
                            phase="awaiting_delivery" if native else "thinking", received=not native,
                        )
                        self._delivery(mid, 'sending' if native else 'delivered')
                        if native and callable(getattr(self.client, 'steer_chat', None)):
                            supplement_task = asyncio.create_task(self._deliver_supplements(session_id, mid, supplements))
                        work_tasks = [] if native else [{"id": "think", "title": "分析用户请求", "status": "running"}]
                        self._record_tasks(mid, work_tasks)
                    elif event == 'input.accepted':
                        with self.db() as db:
                            delivered = db.execute('SELECT state FROM user_events WHERE message_id=?', (mid,)).fetchone()[0] == 'delivered'
                        if not delivered:
                            self._delivery(mid, 'worker_queued')
                    elif event == 'input.delivered':
                        request_id = payload.get('request_id')
                        target = mid if request_id == row['request_id'] else supplements.get(request_id)
                        if target:
                            self._set(target, 'running', payload.get('run_id'), phase='thinking', received=True)
                            self._delivery(target, 'delivered')
                            if target == mid:
                                native_received = True
                                work_tasks = [{"id": "think", "title": "分析用户请求", "status": "running"}]
                                self._record_tasks(mid, work_tasks)
                    elif event == "tool.started":
                        flush()
                        name = payload.get("tool_name")
                        self._set(
                            mid, "running", phase="executing",
                            active_tool=name[:120] if isinstance(name, str) else None,
                            received=not native,
                        )
                        for task in work_tasks:
                            if task.get('id') == 'think' and task.get('status') == 'running':
                                task['status'] = 'done'
                        tool_seq += 1
                        work_tasks.append({
                            "id": f"tool-{tool_seq}",
                            "call_id": payload.get('tool_call_id'), "kind": "tool",
                            "tool": name[:120] if isinstance(name, str) else '',
                            "title": self._tool_task_title(name if isinstance(name, str) else None),
                            "status": "running", "started_at": time.time(),
                        })
                        self._record_tasks(mid, work_tasks)
                    elif event in ("tool.completed", "tool.failed"):
                        self._set(mid, "running", phase="thinking")
                        call_id = payload.get('tool_call_id')
                        candidates = [task for task in work_tasks if task.get('kind') == 'tool' and task.get('status') == 'running'
                                      and (task.get('call_id') == call_id if call_id else task.get('call_id') is None)]
                        # Legacy Hermes has no call ID; pair only a unique open call.
                        if len(candidates) == 1:
                            task = candidates[0]
                            finished = time.time()
                            task.update(status='done' if event == 'tool.completed' else 'failed', finished_at=finished,
                                        duration_ms=max(0, round((finished - task['started_at']) * 1000)))
                        result=payload.get('result') or {}
                        reminder=(result.get('details') or {}).get('id') if isinstance(result,dict) else None
                        if len(candidates)==1 and candidates[0].get('tool')=='remind' and event=='tool.completed' and isinstance(reminder,str) and re.fullmatch(r'rm[A-Za-z0-9]+',reminder):
                            candidates[0]['reminder_id']=reminder
                        self._record_tasks(mid, work_tasks)
                    elif event == "assistant.delta":
                        delta = payload.get("delta")
                        if isinstance(delta, str) and delta:
                            pending += delta
                            if not has_partial or len(pending) >= 64 or time.monotonic() - last_flush >= .08:
                                flush()
                    elif event == "assistant.completed":
                        flush()
                        content = payload.get("content")
                        if isinstance(content, str):
                            final_text = content
                            self._assistant(mid, content, status="streaming")
                        for task in work_tasks:
                            if task.get('kind') != 'tool' and task.get('status') == 'running':
                                task['status'] = 'done'
                        if not any(t.get("id") == "reply" for t in work_tasks):
                            work_tasks.append({"id": "reply", "title": "撰写回复", "status": "running"})
                        self._record_tasks(mid, work_tasks)
                    elif event == "run.completed":
                        flush()
                        completed = bool(final_text) and native_received
                        for task in work_tasks:
                            if task.get('status') == 'running':
                                task['status'] = 'unknown' if task.get('kind') == 'tool' else 'done'
                        self._record_tasks(mid, work_tasks)
                        self._finish(
                            mid, "completed" if completed else "unknown", final_text,
                            None if completed else "主助理未返回完整答复；结果待核实，未自动重试",
                        )
                        terminal = True
                    elif event == "error":
                        flush()
                        if not terminal:
                            self._finish(mid, "unknown", error="主助理执行中断；结果待核实，未自动重试")
                            terminal = True
                    elif event == "input.handled":
                        self._finish(mid,"unknown",error="输入已由 Pi 扩展处理，没有原生执行回合；请核对扩展结果，不会自动重发")
                        terminal=True
                    elif event == "done":
                        break
                flush()
                if not terminal:
                    self._finish(mid, "unknown", error="主助理流已中断；结果待核实，未自动重试")
            except asyncio.CancelledError:
                flush()
                if not terminal:
                    self._finish(mid, "unknown", error="提交中断，可能已被主助理接收；未自动重试")
                raise
            except (ValueError, RuntimeError, httpx.HTTPError):
                flush()
                if not terminal:
                    self._finish(mid, "unknown", error="提交结果待核实；未自动重试")
            finally:
                if supplement_task:
                    supplement_task.cancel()
                    try:
                        await supplement_task
                    except asyncio.CancelledError:
                        pass
                for supplementary_mid in supplements.values():
                    with self.db() as db:
                        supplementary = db.execute('SELECT status,received_at FROM messages WHERE id=?', (supplementary_mid,)).fetchone()
                    if supplementary and supplementary['status'] != 'unknown':
                        delivered = supplementary['received_at'] is not None
                        self._finish(supplementary_mid, 'completed' if completed and delivered else 'unknown',
                                     error=None if completed and delivered else '补充执行或送达结果待核实，未自动重试')
                    self.reactions.close_turn(supplementary_mid)
                self.reactions.close_turn(mid)
        return True

    async def loop(self):
        while True:
            try:
                processed = await self.process_one()
                if not processed:
                    background = getattr(self, 'process_background', None)
                    if background:
                        processed = await background()
            except asyncio.CancelledError:
                raise
            except Exception:
                # A transient adapter failure must not permanently stop delivery.
                await asyncio.sleep(2)
                continue
            if not processed:
                self.wake.clear()
                try:
                    await asyncio.wait_for(self.wake.wait(), 3)
                except asyncio.TimeoutError:
                    pass

    def start(self):
        if self.task is None or self.task.done():
            self.task = asyncio.create_task(self.loop())

    async def stop(self):
        if self.task:
            self.task.cancel()
            try:
                await self.task
            except asyncio.CancelledError:
                pass
            self.task = None
        stop=getattr(self.client,'stop',None)
        if stop:
            await stop()
