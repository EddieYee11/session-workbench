"""Durable Com! main conversation backed by an isolated Hermes API server."""

import asyncio
import json
import sqlite3
import stat
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import AsyncIterator

import httpx
from reactions import ReactionStore, install_schema, project_message
from message_references import canonical_reference, reference_identity, referenced_input


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
            ):
                if name not in columns:
                    db.execute(f"ALTER TABLE messages ADD COLUMN {name} {definition}")
            db.execute("INSERT OR IGNORE INTO meta(key,value) VALUES('revision','0')")
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

    def task_receipt(self, task_id: str, text: str):
        """Idempotent outbox sink, including a crash before outbox acknowledgement."""
        with self.db() as db:
            key = 'task-result:' + task_id
            if db.execute('SELECT id FROM messages WHERE request_id=?', (key,)).fetchone():
                return
            revision = self._bump(db)
            at = time.time()
            db.execute("INSERT INTO messages(id,request_id,role,text,status,phase,revision,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)",
                       (key, key, 'assistant', text, 'completed', 'completed', revision, at, at))
        self._notify()

    def submit(self, request_id: str, text: str, reference: dict | None = None) -> dict:
        text = text.strip()
        if not 10 <= len(request_id) <= 100 or not 1 <= len(text) <= 8000:
            raise ValueError("消息或请求标识无效")
        identity = reference_identity(reference, "personal-main")
        with self.db() as db:
            old = db.execute(
                "SELECT id,text,status,reference FROM messages WHERE request_id=?", (request_id,)
            ).fetchone()
            if old:
                saved_reference = json.loads(old["reference"]) if old["reference"] else None
                if (old["text"] != text
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
                "INSERT INTO messages(id,request_id,role,text,status,phase,revision,created_at,updated_at,reference)"
                " VALUES(?,?,?,?,?,?,?,?,?,?)",
                (mid, request_id, "user", text, "queued", "queued", revision, now, now,
                 json.dumps(saved_reference, ensure_ascii=False) if saved_reference else None),
            )
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
            "SELECT id,request_id,parent_id,role,text,status,phase,active_tool,"
            "received_at,revision,created_at,updated_at,run_id,error,reaction,reference FROM messages " + where
        )

    @staticmethod
    def _project_message(row) -> dict:
        message = project_message(row)
        message["reference"] = json.loads(message["reference"]) if message["reference"] else None
        return message

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
        messages = [self._project_message(row) for row in reversed(rows)]
        return {
            "conversation_id": "personal-main", "revision": revision,
            "messages": messages, "runs": runs,
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
        messages = [self._project_message(row) for row in rows]
        return {
            "conversation_id": "personal-main", "revision": current,
            "messages": messages, "runs": runs,
        }

    async def stream(self, after_revision: int | None = None) -> AsyncIterator[dict]:
        """Broadcast durable Com state; reconnects always begin with a full snapshot."""
        if after_revision is not None and (
            isinstance(after_revision, bool) or not isinstance(after_revision, int) or after_revision < 0
        ):
            raise ValueError("无效的会话版本")
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
                "received_at=COALESCE(received_at,?),revision=?,updated_at=?"
                " WHERE id=?",
                (phase, now, revision, now, mid),
            )
        self._notify()

    def _session_id(self) -> str | None:
        with self.db() as db:
            row = db.execute("SELECT value FROM meta WHERE key='hermes_session_id'").fetchone()
        return row["value"] if row else None

    async def _ensure_session(self) -> str:
        sid = self._session_id()
        if sid:
            return sid
        sid = await self.client.create_session()
        with self.db() as db:
            db.execute(
                "INSERT OR IGNORE INTO meta(key,value) VALUES('hermes_session_id',?)", (sid,)
            )
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

    async def process_one(self) -> bool:
        row = self._next()
        if row is None:
            return False
        mid = row["id"]
        if row["status"] in ("sending", "running"):
            self._finish(mid, "unknown", error="提交中断，可能已被 Hermes 接收；未自动重试")
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
                if isinstance(self.client, HermesClient):
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
                        + "\n明确交办普通诊断或项目代码修改用 create_task：逐字引用用户交办原文和上面的 origin IDs，默认 Codex read-only；明确代码修改才用 workspace-write。"
                        "涉及发布、删除、外发、部署、认证配置或 Pi full-access 才用 propose_work 等待具体批准。"
                        "多件明确交办分别创建；先读现有任务，补充约束用 update_task_constraints 并复用任务 ID。"
                        "update_task_constraints 的 constraint_type 必填：用户说保持只读/不要改文件时 constraint_type='read_only', text=''；"
                        "保持现有样式时 constraint_type='preserve_style', text=''；禁止路径时 constraint_type='forbid_path', text=项目内相对路径。"
                        "不要把 read_only/preserve_style 写进 text 后省略类型。任意新动作或普通备注才用 constraint_type='note'，它只记录且因未授权而不执行。"
                        "要求停止时用 cancel_task，复用精确 task ID；任务查询用 get_task_status；后台 queued 是已受理，继续主聊天无需等待工作器。"
                        "创建工具的 queued/work_started=false 回执只允许说已受理或排队中；"
                        "执行动作、只读约束遵守、网络访问或文件修改结果必须有工作器实际事件或结果才能陈述，不能把任务要求当作完成证据。"
                        "闲聊不派发；指代不明先追问；任务执行结束不代表验收通过；已受理不代表生效。"
                        "面向用户用简洁中文说明任务名称、实际进度和结果；task ID、constraint_type、delivery 等内部参数保留在工具调用中，不在普通回复里逐项展示。"
                        "补充要求先说已给原任务补充、仍待送达，真实回执已确认时才说已送达；无需重复解释规则或询问是否继续跟进。"
                        "发布、删除、外发、权限扩张不能由工作建议获得授权。\n用户消息：\n" + user_input)
                async for event, payload in self.client.stream_chat(session_id, transport_text):
                    if terminal and event != "done":
                        continue
                    if event == "run.started":
                        run_id = payload.get("run_id")
                        self._set(
                            mid, "running", run_id if isinstance(run_id, str) else None,
                            phase="thinking", received=True,
                        )
                    elif event == "tool.started":
                        flush()
                        name = payload.get("tool_name")
                        self._set(
                            mid, "running", phase="executing",
                            active_tool=name[:120] if isinstance(name, str) else None,
                            received=True,
                        )
                    elif event in ("tool.completed", "tool.failed"):
                        self._set(mid, "running", phase="thinking")
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
                    elif event == "run.completed":
                        flush()
                        completed = bool(final_text)
                        self._finish(
                            mid, "completed" if completed else "unknown", final_text,
                            None if completed else "Hermes 未返回完整答复；结果待核实，未自动重试",
                        )
                        terminal = True
                    elif event == "error":
                        flush()
                        if not terminal:
                            self._finish(mid, "unknown", error="Hermes 执行中断；结果待核实，未自动重试")
                            terminal = True
                    elif event == "done":
                        break
                flush()
                if not terminal:
                    self._finish(mid, "unknown", error="Hermes 流已中断；结果待核实，未自动重试")
            except asyncio.CancelledError:
                flush()
                if not terminal:
                    self._finish(mid, "unknown", error="提交中断，可能已被 Hermes 接收；未自动重试")
                raise
            except (ValueError, RuntimeError, httpx.HTTPError):
                flush()
                if not terminal:
                    self._finish(mid, "unknown", error="提交结果待核实；未自动重试")
            finally:
                self.reactions.close_turn(mid)
        return True

    async def loop(self):
        while True:
            try:
                processed = await self.process_one()
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
        if self.task is None:
            self.task = asyncio.create_task(self.loop())

    async def stop(self):
        if self.task:
            self.task.cancel()
            try:
                await self.task
            except asyncio.CancelledError:
                pass
            self.task = None
