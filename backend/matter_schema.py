"""UnifiedMatterEntity data contract, FSM state machine, and SQLite persistence engine.

Implements PRD v2.2.0 Phase 1 single source of truth (SSOT) and immutable identity.
"""
from __future__ import annotations

import json
import re
import secrets
import sqlite3
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Optional
from urllib.parse import quote
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Asia/Shanghai")
MATTER_ID_REGEX = re.compile(r"^mtr-[0-9]{8}-[a-z0-9]{8,12}$")
FTS_RESERVED_OPERATORS = {"AND", "OR", "NOT", "NEAR"}


def cjk_unigram_tokenize(text: Optional[str]) -> str:
    """CJK 单字扩充空格分词：中文字符拆为单字，英数字与符号保持完整。"""
    if not text:
        return ""
    res = []
    for ch in str(text):
        if "\u4e00" <= ch <= "\u9fff":
            res.append(f" {ch} ")
        else:
            res.append(ch)
    return " ".join("".join(res).split())


def build_fts_query(raw_query: str) -> str:
    """解析检索词构造安全 FTS5 查询：中文生成精确短语，英文字词生成前缀匹配。

    - 中文字符串生成包含单字空格扩充的双引号短语（如 `"重 构"`）。
    - 纯字母数字且非 FTS5 保留字的英文词生成裸前缀查询（如 `FTS5*`, `iOS*`）。
    - 包含标点/点号/符号（如版本号 `v2.2.0`, `C++`, `(test)`）或 FTS5 保留字的 Token，
      使用双引号短语前缀安全转义（如 `"v2.2.0"*`, `"OR"*`），防止 SQLite FTS5 列定位语法错误及崩溃。
    - 过滤无实质字母/数字/汉字的纯符号/注入片段。
    """
    if not raw_query or not raw_query.strip():
        return ""
    tokens = []
    for part in raw_query.strip().split():
        clean_part = re.sub(r'["\'*^:\\]', '', part)
        if not clean_part or not re.search(r'[a-zA-Z0-9\u4e00-\u9fff]', clean_part):
            continue
        has_cjk = any("\u4e00" <= ch <= "\u9fff" for ch in clean_part)
        if has_cjk:
            cjk_clean = cjk_unigram_tokenize(clean_part)
            tokens.append(f'"{cjk_clean}"')
        else:
            if clean_part.isalnum() and clean_part.upper() not in FTS_RESERVED_OPERATORS:
                tokens.append(f"{clean_part}*")
            else:
                tokens.append(f'"{clean_part}"*')
    return " AND ".join(tokens) if tokens else ""


def clean_cjk_snippet(text: str) -> str:
    """消除 CJK 字符之间为了 FTS5 检索而人为插入的空格，保全 <b></b> 标签。"""
    if not text:
        return ""
    text = re.sub(r"([\u4e00-\u9fff])\s+([\u4e00-\u9fff])", r"\1\2", text)
    text = re.sub(r"([\u4e00-\u9fff])\s+([\u4e00-\u9fff])", r"\1\2", text)
    text = re.sub(r"<b>\s+", "<b>", text)
    text = re.sub(r"\s+</b>", "</b>", text)
    return text.strip()


# 11 合法 FSM 状态枚举 (PRD v2.2.0 第三章)
FSM_STATES = {
    "suggested",      # 建议推荐池（原 open / suggest）
    "todo",           # 待办认领池（原 待处理 / todo）
    "doing",          # 人工进行中（原 进行中 / doing）
    "executing",      # Agent 托管自动化执行中（后台航程）
    "waiting_input",  # 挂起等待用户决策与审批
    "error_retrying", # 出错自动退避重试中
    "error_blocked",  # 重试超限阻断停滞态
    "snoozed",        # 暂缓隔日
    "dismissed",      # 已忽略候选
    "cancelled",      # 已取消归档
    "done",           # 已完成交付
}

# 11 状态合法迁移拓扑与守卫矩阵
VALID_TRANSITIONS: dict[str, set[str]] = {
    "suggested": {"todo", "doing", "executing", "snoozed", "dismissed", "done"},
    "todo": {"suggested", "doing", "executing", "snoozed", "cancelled", "done"},
    "doing": {"todo", "suggested", "executing", "cancelled", "done"},
    "executing": {"todo", "doing", "waiting_input", "error_retrying", "error_blocked", "cancelled", "done"},
    "waiting_input": {"todo", "executing", "doing", "cancelled", "done"},
    "error_retrying": {"executing", "error_blocked", "cancelled"},
    "error_blocked": {"todo", "executing", "doing", "cancelled"},
    "snoozed": {"suggested", "todo", "dismissed"},
    "dismissed": {"suggested"},
    "cancelled": {"todo", "suggested"},
    "done": {"suggested", "todo", "doing"},  # 允许重新激活与撤销完成
}


class MatterError(Exception):
    """Base exception for matter operations."""


class MatterNotFound(MatterError):
    """Raised when matter entity does not exist."""


class MatterConflict(MatterError):
    """Raised when version conflict occurs (HTTP 409 equivalent)."""

    def __init__(
        self,
        message: str,
        latest: Optional[UnifiedMatterEntity] = None,
        requested_rev: Optional[int] = None,
        current_rev: Optional[int] = None,
        diff: Optional[dict[str, Any]] = None,
    ):
        super().__init__(message)
        self.latest = latest
        self.requested_rev = requested_rev
        self.current_rev = current_rev
        self.diff = diff


class MatterIllegalTransition(MatterError):
    """Raised when an illegal FSM transition is attempted."""


def generate_matter_id(ts: Optional[float] = None) -> str:
    """生成全局不可变 MatterID：mtr-<YYYYMMDD>-<8位十六进制随机串>"""
    now = datetime.fromtimestamp(ts if ts is not None else time.time(), TZ)
    date_str = now.strftime("%Y%m%d")
    random_part = secrets.token_hex(4)  # 8 hex chars
    return f"mtr-{date_str}-{random_part}"


def validate_matter_id(matter_id: str) -> bool:
    """校验是否符合不可变 MatterID 格式规范"""
    return bool(isinstance(matter_id, str) and MATTER_ID_REGEX.match(matter_id))


@dataclass
class UnifiedMatterEntity:
    """单一事实源 (SSOT) 统一事项实体"""
    matter_id: str
    title: str
    status: str = "suggested"
    rev: int = 1
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    source_type: str = "manual"
    urgency: str = "none"
    due_date: Optional[str] = None
    source_ref: dict = field(default_factory=dict)
    why: str = ""
    action: Optional[dict] = None
    obsidian_binding: Optional[dict] = None
    case_binding: Optional[dict] = None
    waiting_reason: Optional[str] = None
    last_error: Optional[str] = None
    completed_at: Optional[float] = None
    legacy_id: Optional[str] = None  # 兼容桥接: next:xxx 或 todo:xxx

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        # 为兼容旧版前端与已有单测断言，默认挂载 id 字段别名
        data["id"] = self.matter_id
        return data


class MatterStore:
    """SQLite 持久化引擎与事务状态机"""

    def __init__(self, db_path: Path, clock=time.time):
        self.db_path = Path(db_path)
        self.clock = clock
        self._init_db()

    def _init_db(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(self.db_path, timeout=20) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("""
                CREATE TABLE IF NOT EXISTS matter_state (
                    matter_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL,
                    urgency TEXT DEFAULT 'none',
                    due_date TEXT,
                    source_type TEXT NOT NULL,
                    source_ref TEXT,
                    why TEXT,
                    action TEXT,
                    obsidian_binding TEXT,
                    case_binding TEXT,
                    waiting_reason TEXT,
                    last_error TEXT,
                    rev INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    legacy_id TEXT,
                    raw_data TEXT
                )
            """)
            db.execute("CREATE INDEX IF NOT EXISTS idx_matter_status ON matter_state(status)")
            db.execute("CREATE INDEX IF NOT EXISTS idx_matter_legacy ON matter_state(legacy_id)")
            db.execute("CREATE INDEX IF NOT EXISTS idx_matter_updated ON matter_state(updated_at DESC)")

            # 事务外发箱 (Transactional Outbox) 用于异步向 Obsidian Markdown 投递
            db.execute("""
                CREATE TABLE IF NOT EXISTS matter_outbox (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    matter_id TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    retry_count INTEGER DEFAULT 0,
                    status TEXT DEFAULT 'pending',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

            # 事项动作幂等操作表 (Idempotency Op Log)
            db.execute("""
                CREATE TABLE IF NOT EXISTS matter_action_ops (
                    op_id TEXT PRIMARY KEY,
                    matter_id TEXT NOT NULL,
                    result TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
            """)
            db.execute("CREATE INDEX IF NOT EXISTS idx_action_ops_matter ON matter_action_ops(matter_id)")

            # 1. 冷归档分区表 (matter_archive)
            db.execute("""
                CREATE TABLE IF NOT EXISTS matter_archive (
                    matter_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL,
                    urgency TEXT DEFAULT 'none',
                    due_date TEXT,
                    source_type TEXT NOT NULL,
                    source_ref TEXT,
                    why TEXT,
                    action TEXT,
                    obsidian_binding TEXT,
                    case_binding TEXT,
                    waiting_reason TEXT,
                    last_error TEXT,
                    rev INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    archived_at REAL NOT NULL,
                    archive_reason TEXT DEFAULT 'auto_gc',
                    legacy_id TEXT,
                    raw_data TEXT
                )
            """)
            db.execute("CREATE INDEX IF NOT EXISTS idx_archive_status ON matter_archive(status)")
            db.execute("CREATE INDEX IF NOT EXISTS idx_archive_completed ON matter_archive(completed_at DESC)")
            db.execute("CREATE INDEX IF NOT EXISTS idx_archive_archived ON matter_archive(archived_at DESC)")
            db.execute("CREATE INDEX IF NOT EXISTS idx_archive_legacy ON matter_archive(legacy_id)")

            # 2. 全局全文检索虚拟表 (matter_fts)
            db.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS matter_fts USING fts5(
                    matter_id UNINDEXED,
                    title,
                    why,
                    note,
                    tags,
                    tokenize = 'unicode61'
                )
            """)

            # 若 matter_fts 为空但已有数据，补录历史记录进索引
            fts_count = db.execute("SELECT COUNT(*) FROM matter_fts").fetchone()[0]
            if fts_count == 0:
                rows = db.execute("SELECT matter_id, title, why, action, source_type, urgency FROM matter_state").fetchall()
                for r in rows:
                    mid, title, why, act_raw, stype, urg = r
                    action_dict = json.loads(act_raw) if act_raw else {}
                    note = action_dict.get("draft", "") if isinstance(action_dict, dict) else ""
                    tags = f"{stype} {urg}"
                    db.execute(
                        "INSERT INTO matter_fts(matter_id, title, why, note, tags) VALUES (?, ?, ?, ?, ?)",
                        (mid, cjk_unigram_tokenize(title), cjk_unigram_tokenize(why), cjk_unigram_tokenize(note), cjk_unigram_tokenize(tags)),
                    )
            db.commit()

    def db(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=20)
        conn.row_factory = sqlite3.Row
        return conn

    def get_by_id(self, matter_id: str) -> Optional[UnifiedMatterEntity]:
        with self.db() as db:
            row = db.execute("SELECT * FROM matter_state WHERE matter_id=?", (matter_id,)).fetchone()
            if not row and not matter_id.startswith("mtr-"):
                # 兼容按 legacy_id 查询（如 next:xxx 或 todo:xxx 或 bare id）
                row = db.execute("SELECT * FROM matter_state WHERE legacy_id=?", (matter_id,)).fetchone()
                if not row:
                    # 尝试带前缀查询
                    for prefix in ("next:", "todo:"):
                        row = db.execute("SELECT * FROM matter_state WHERE legacy_id=?", (prefix + matter_id,)).fetchone()
                        if row:
                            break
            return self._row_to_entity(row) if row else None

    def list_matters(
        self,
        status: Optional[str] = None,
        source_type: Optional[str] = None,
        limit: int = 100,
    ) -> list[UnifiedMatterEntity]:
        query = "SELECT * FROM matter_state WHERE 1=1"
        params: list[Any] = []
        if status:
            query += " AND status=?"
            params.append(status)
        if source_type:
            query += " AND source_type=?"
            params.append(source_type)
        query += " ORDER BY updated_at DESC LIMIT ?"
        params.append(limit)

        with self.db() as db:
            rows = db.execute(query, params).fetchall()
            return [self._row_to_entity(r) for r in rows]

    def create_matter(
        self,
        title: str,
        source_type: str,
        status: str = "suggested",
        **kwargs: Any,
    ) -> UnifiedMatterEntity:
        if status not in FSM_STATES:
            raise MatterIllegalTransition(f"Invalid FSM status: {status}")

        clock_override = kwargs.get("clock")
        now = clock_override() if callable(clock_override) else self.clock()
        matter_id = kwargs.get("matter_id") or generate_matter_id(now)
        rev = kwargs.get("rev", 1)
        legacy_id = kwargs.get("legacy_id")

        entity = UnifiedMatterEntity(
            matter_id=matter_id,
            title=title[:100],
            status=status,
            rev=rev,
            created_at=kwargs.get("created_at", now),
            updated_at=kwargs.get("updated_at", now),
            source_type=source_type,
            urgency=kwargs.get("urgency", "none"),
            due_date=kwargs.get("due_date"),
            source_ref=kwargs.get("source_ref") or {},
            why=kwargs.get("why", "")[:200],
            action=kwargs.get("action"),
            obsidian_binding=kwargs.get("obsidian_binding"),
            case_binding=kwargs.get("case_binding"),
            waiting_reason=kwargs.get("waiting_reason"),
            last_error=kwargs.get("last_error"),
            completed_at=kwargs.get("completed_at"),
            legacy_id=legacy_id,
        )

        with self.db() as db:
            db.execute(
                """
                INSERT OR REPLACE INTO matter_state (
                    matter_id, title, status, urgency, due_date, source_type,
                    source_ref, why, action, obsidian_binding, case_binding,
                    waiting_reason, last_error, rev, created_at, updated_at,
                    completed_at, legacy_id, raw_data
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    entity.matter_id,
                    entity.title,
                    entity.status,
                    entity.urgency,
                    entity.due_date,
                    entity.source_type,
                    json.dumps(entity.source_ref, ensure_ascii=False),
                    entity.why,
                    json.dumps(entity.action, ensure_ascii=False) if entity.action else None,
                    json.dumps(entity.obsidian_binding, ensure_ascii=False) if entity.obsidian_binding else None,
                    json.dumps(entity.case_binding, ensure_ascii=False) if entity.case_binding else None,
                    entity.waiting_reason,
                    entity.last_error,
                    entity.rev,
                    entity.created_at,
                    entity.updated_at,
                    entity.completed_at,
                    entity.legacy_id,
                    json.dumps(kwargs.get("raw_data") or {}, ensure_ascii=False),
                ),
            )
            self._sync_fts(db, entity)
            db.commit()
        return entity

    def transition_status(
        self,
        matter_id: str,
        to_status: str,
        expected_rev: Optional[int] = None,
        **kwargs: Any,
    ) -> UnifiedMatterEntity:
        if to_status not in FSM_STATES:
            raise MatterIllegalTransition(f"Invalid target FSM status: {to_status}")

        with self.db() as db:
            row = db.execute("SELECT * FROM matter_state WHERE matter_id=?", (matter_id,)).fetchone()
            if not row:
                # 尝试通过 legacy_id 查找
                row = db.execute("SELECT * FROM matter_state WHERE legacy_id=?", (matter_id,)).fetchone()
            if not row:
                raise MatterNotFound(f"Matter not found: {matter_id}")

            entity = self._row_to_entity(row)
            if expected_rev is not None and entity.rev != expected_rev:
                diff = {
                    "rev": {"requested": expected_rev, "current": entity.rev},
                    "status": {"requested": to_status, "current": entity.status},
                }
                raise MatterConflict(
                    f"VERSION_CONFLICT_409: expected rev {expected_rev}, current {entity.rev}",
                    latest=entity,
                    requested_rev=expected_rev,
                    current_rev=entity.rev,
                    diff=diff,
                )

            allowed = VALID_TRANSITIONS.get(entity.status, set())
            if to_status not in allowed:
                raise MatterIllegalTransition(
                    f"Illegal transition from '{entity.status}' to '{to_status}' (allowed: {allowed})"
                )

            clock_override = kwargs.get("clock")
            now = clock_override() if callable(clock_override) else self.clock()
            new_rev = entity.rev + 1
            completed_at = now if to_status == "done" else (None if entity.status == "done" else entity.completed_at)

            obsidian_binding = kwargs.get("obsidian_binding", entity.obsidian_binding)
            case_binding = kwargs.get("case_binding", entity.case_binding)
            waiting_reason = kwargs.get("waiting_reason", entity.waiting_reason)
            last_error = kwargs.get("last_error", entity.last_error)

            cursor = db.execute(
                """
                UPDATE matter_state
                SET status=?, rev=?, updated_at=?, completed_at=?,
                    obsidian_binding=?, case_binding=?, waiting_reason=?, last_error=?
                WHERE matter_id=? AND rev=?
                """,
                (
                    to_status,
                    new_rev,
                    now,
                    completed_at,
                    json.dumps(obsidian_binding, ensure_ascii=False) if obsidian_binding else None,
                    json.dumps(case_binding, ensure_ascii=False) if case_binding else None,
                    waiting_reason,
                    last_error,
                    entity.matter_id,
                    entity.rev,
                ),
            )
            if cursor.rowcount == 0:
                fresh_row = db.execute("SELECT * FROM matter_state WHERE matter_id=?", (entity.matter_id,)).fetchone()
                fresh_entity = self._row_to_entity(fresh_row) if fresh_row else entity
                diff = {
                    "rev": {"requested": entity.rev, "current": fresh_entity.rev},
                    "status": {"requested": to_status, "current": fresh_entity.status},
                }
                raise MatterConflict(
                    f"Concurrent update conflict on matter {entity.matter_id}",
                    latest=fresh_entity,
                    requested_rev=expected_rev,
                    current_rev=fresh_entity.rev,
                    diff=diff,
                )
            db.commit()

            entity.status = to_status
            entity.rev = new_rev
            entity.updated_at = now
            entity.completed_at = completed_at
            entity.obsidian_binding = obsidian_binding
            entity.case_binding = case_binding
            entity.waiting_reason = waiting_reason
            entity.last_error = last_error
            self._sync_fts(db, entity)
            db.commit()
            return entity

    def update_matter(
        self,
        matter_id: str,
        expected_rev: Optional[int] = None,
        **kwargs: Any,
    ) -> UnifiedMatterEntity:
        """更新非状态字段并增加版本号"""
        with self.db() as db:
            row = db.execute("SELECT * FROM matter_state WHERE matter_id=?", (matter_id,)).fetchone()
            if not row:
                row = db.execute("SELECT * FROM matter_state WHERE legacy_id=?", (matter_id,)).fetchone()
            if not row:
                raise MatterNotFound(f"Matter not found: {matter_id}")

            entity = self._row_to_entity(row)
            if expected_rev is not None and entity.rev != expected_rev:
                diff = {
                    "rev": {"requested": expected_rev, "current": entity.rev},
                }
                raise MatterConflict(
                    f"VERSION_CONFLICT_409: expected rev {expected_rev}, current {entity.rev}",
                    latest=entity,
                    requested_rev=expected_rev,
                    current_rev=entity.rev,
                    diff=diff,
                )

            now = self.clock()
            new_rev = entity.rev + 1

            title = kwargs.get("title", entity.title)
            why = kwargs.get("why", entity.why)
            urgency = kwargs.get("urgency", entity.urgency)
            due_date = kwargs.get("due_date", entity.due_date)
            action = kwargs.get("action", entity.action)
            obsidian_binding = kwargs.get("obsidian_binding", entity.obsidian_binding)
            case_binding = kwargs.get("case_binding", entity.case_binding)

            cursor = db.execute(
                """
                UPDATE matter_state
                SET title=?, why=?, urgency=?, due_date=?, action=?,
                    obsidian_binding=?, case_binding=?, rev=?, updated_at=?
                WHERE matter_id=? AND rev=?
                """,
                (
                    title,
                    why,
                    urgency,
                    due_date,
                    json.dumps(action, ensure_ascii=False) if action else None,
                    json.dumps(obsidian_binding, ensure_ascii=False) if obsidian_binding else None,
                    json.dumps(case_binding, ensure_ascii=False) if case_binding else None,
                    new_rev,
                    now,
                    entity.matter_id,
                    entity.rev,
                ),
            )
            if cursor.rowcount == 0:
                fresh_row = db.execute("SELECT * FROM matter_state WHERE matter_id=?", (entity.matter_id,)).fetchone()
                fresh_entity = self._row_to_entity(fresh_row) if fresh_row else entity
                diff = {
                    "rev": {"requested": entity.rev, "current": fresh_entity.rev},
                }
                raise MatterConflict(
                    f"VERSION_CONFLICT_409: Concurrent update conflict on matter {entity.matter_id}",
                    latest=fresh_entity,
                    requested_rev=expected_rev,
                    current_rev=fresh_entity.rev,
                    diff=diff,
                )
            db.commit()

            entity.title = title
            entity.why = why
            entity.urgency = urgency
            entity.due_date = due_date
            entity.action = action
            entity.obsidian_binding = obsidian_binding
            entity.case_binding = case_binding
            entity.rev = new_rev
            entity.updated_at = now
            self._sync_fts(db, entity)
            db.commit()
            return entity

    def create_outbox_event(self, matter_id: str, event_type: str, payload: dict) -> int:
        now = self.clock()
        with self.db() as db:
            cursor = db.execute(
                """
                INSERT INTO matter_outbox (matter_id, event_type, payload, retry_count, status, created_at, updated_at)
                VALUES (?, ?, ?, 0, 'pending', ?, ?)
                """,
                (matter_id, event_type, json.dumps(payload, ensure_ascii=False), now, now),
            )
            db.commit()
            return cursor.lastrowid

    def list_pending_outbox(self, limit: int = 50) -> list[dict[str, Any]]:
        with self.db() as db:
            rows = db.execute(
                "SELECT * FROM matter_outbox WHERE status='pending' ORDER BY id ASC LIMIT ?",
                (limit,),
            ).fetchall()
            return [
                {
                    "id": r["id"],
                    "matter_id": r["matter_id"],
                    "event_type": r["event_type"],
                    "payload": json.loads(r["payload"]),
                    "retry_count": r["retry_count"],
                    "status": r["status"],
                    "created_at": r["created_at"],
                }
                for r in rows
            ]

    def mark_outbox_done(self, outbox_id: int) -> None:
        now = self.clock()
        with self.db() as db:
            db.execute("UPDATE matter_outbox SET status='done', updated_at=? WHERE id=?", (now, outbox_id))
            db.commit()

    def mark_outbox_retry(self, outbox_id: int, error_msg: str, max_retries: int = 5) -> str:
        now = self.clock()
        with self.db() as db:
            row = db.execute("SELECT retry_count FROM matter_outbox WHERE id=?", (outbox_id,)).fetchone()
            if not row:
                return "not_found"
            new_count = row["retry_count"] + 1
            new_status = "dlq" if new_count >= max_retries else "pending"
            db.execute(
                "UPDATE matter_outbox SET retry_count=?, status=?, updated_at=? WHERE id=?",
                (new_count, new_status, now, outbox_id),
            )
            db.commit()
            return new_status

    def get_action_op(self, op_id: str, matter_id: Optional[str] = None) -> Optional[dict]:
        if not op_id:
            return None
        with self.db() as db:
            row = db.execute("SELECT matter_id, result FROM matter_action_ops WHERE op_id=?", (op_id,)).fetchone()
            if not row:
                return None
            if matter_id and row["matter_id"] != matter_id:
                return None
            return json.loads(row["result"])

    def save_action_op(self, op_id: str, matter_id: str, result: dict) -> None:
        if not op_id:
            return
        now = self.clock()
        with self.db() as db:
            db.execute(
                "INSERT OR REPLACE INTO matter_action_ops (op_id, matter_id, result, created_at) VALUES (?, ?, ?, ?)",
                (op_id, matter_id, json.dumps(result, ensure_ascii=False), now),
            )
            db.commit()

    def _row_to_entity(self, row: sqlite3.Row) -> UnifiedMatterEntity:
        return UnifiedMatterEntity(
            matter_id=row["matter_id"],
            title=row["title"],
            status=row["status"],
            rev=row["rev"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            source_type=row["source_type"],
            urgency=row["urgency"] or "none",
            due_date=row["due_date"],
            source_ref=json.loads(row["source_ref"]) if row["source_ref"] else {},
            why=row["why"] or "",
            action=json.loads(row["action"]) if row["action"] else None,
            obsidian_binding=json.loads(row["obsidian_binding"]) if row["obsidian_binding"] else None,
            case_binding=json.loads(row["case_binding"]) if row["case_binding"] else None,
            waiting_reason=row["waiting_reason"],
            last_error=row["last_error"],
            completed_at=row["completed_at"],
            legacy_id=row["legacy_id"],
        )

    def _sync_fts(self, db: sqlite3.Connection, entity: UnifiedMatterEntity, note: str = "", tags: str = "") -> None:
        db.execute("DELETE FROM matter_fts WHERE matter_id=?", (entity.matter_id,))
        title_tok = cjk_unigram_tokenize(entity.title)
        why_tok = cjk_unigram_tokenize(entity.why)
        draft = entity.action.get("draft", "") if isinstance(entity.action, dict) else ""
        note_tok = cjk_unigram_tokenize(note or draft)
        tags_tok = cjk_unigram_tokenize(tags or f"{entity.source_type} {entity.urgency}")
        db.execute(
            "INSERT INTO matter_fts(matter_id, title, why, note, tags) VALUES (?, ?, ?, ?, ?)",
            (entity.matter_id, title_tok, why_tok, note_tok, tags_tok),
        )

    def archive_matters_gc(self, ttl_days: int = 7, dry_run: bool = False, clock: Optional[Callable[[], float]] = None) -> dict[str, Any]:
        """原子迁移满足 TTL 的已办结/已取消事项至 matter_archive。

        保全契约：严禁物理删除或 unlink 本地 Markdown 文件！obsidian_binding 保持原样迁移。
        """
        now = (clock or self.clock)()
        cutoff_ts = now - (ttl_days * 86400)
        with self.db() as db:
            rows = db.execute("""
                SELECT matter_id FROM matter_state
                WHERE status IN ('done', 'cancelled')
                  AND (
                    (completed_at IS NOT NULL AND completed_at <= ?)
                    OR
                    (completed_at IS NULL AND updated_at <= ?)
                  )
            """, (cutoff_ts, cutoff_ts)).fetchall()
            eligible_ids = [r["matter_id"] for r in rows]

            if dry_run or not eligible_ids:
                return {
                    "ok": True,
                    "archived_count": len(eligible_ids),
                    "dry_run": dry_run,
                    "cutoff_ts": cutoff_ts,
                    "ttl_days": ttl_days,
                    "matter_ids": eligible_ids,
                }

            for mid in eligible_ids:
                db.execute("""
                    INSERT OR REPLACE INTO matter_archive (
                        matter_id, title, status, urgency, due_date, source_type,
                        source_ref, why, action, obsidian_binding, case_binding,
                        waiting_reason, last_error, rev, created_at, updated_at,
                        completed_at, archived_at, archive_reason, legacy_id, raw_data
                    )
                    SELECT
                        matter_id, title, status, urgency, due_date, source_type,
                        source_ref, why, action, obsidian_binding, case_binding,
                        waiting_reason, last_error, rev, created_at, updated_at,
                        completed_at, ?, 'auto_gc', legacy_id, raw_data
                    FROM matter_state WHERE matter_id=?
                """, (now, mid))
                db.execute("DELETE FROM matter_state WHERE matter_id=?", (mid,))

            db.commit()
            return {
                "ok": True,
                "archived_count": len(eligible_ids),
                "dry_run": False,
                "cutoff_ts": cutoff_ts,
                "ttl_days": ttl_days,
                "matter_ids": eligible_ids,
            }

    def search_matters_fts(
        self,
        query: Optional[str] = None,
        status: Optional[str] = None,
        page: int = 1,
        page_size: int = 20,
        source_type: Optional[str] = None,
    ) -> dict[str, Any]:
        """在归档库（冷分区）中分页检索历史事项，支持 CJK 单字/双字/多字及英数字 FTS5 全文搜索与高亮"""
        page = max(1, page)
        page_size = max(1, min(100, page_size))
        offset = (page - 1) * page_size

        status_list = [s.strip() for s in status.split(",") if s.strip()] if status else []

        with self.db() as db:
            clean_q = build_fts_query(query) if query and query.strip() else ""
            if query and query.strip() and not clean_q:
                # 显式提供了检索关键词，但被清洗过滤后无有效 Token（如全为纯标点或注入符号），
                # 返回空结果集，避免回退至全量冷库泄漏
                return {
                    "total": 0,
                    "page": page,
                    "page_size": page_size,
                    "has_more": False,
                    "items": [],
                }

            if clean_q:
                where_clauses = ["matter_fts MATCH ?", "(a.matter_id IS NOT NULL OR s.matter_id IS NOT NULL)"]
                params: list[Any] = [clean_q]

                if status_list:
                    placeholders = ",".join("?" for _ in status_list)
                    where_clauses.append(f"COALESCE(a.status, s.status) IN ({placeholders})")
                    params.extend(status_list)
                if source_type:
                    where_clauses.append("COALESCE(a.source_type, s.source_type)=?")
                    params.append(source_type)

                where_sql = " AND ".join(where_clauses)
                count_sql = f"""
                    SELECT COUNT(*) FROM matter_fts
                    LEFT JOIN matter_archive a ON matter_fts.matter_id = a.matter_id
                    LEFT JOIN matter_state s ON matter_fts.matter_id = s.matter_id
                    WHERE {where_sql}
                """
                try:
                    total = db.execute(count_sql, params).fetchone()[0]

                    data_sql = f"""
                        SELECT
                            COALESCE(a.matter_id, s.matter_id) as matter_id,
                            COALESCE(a.title, s.title) as title,
                            COALESCE(a.status, s.status) as status,
                            COALESCE(a.urgency, s.urgency) as urgency,
                            COALESCE(a.due_date, s.due_date) as due_date,
                            COALESCE(a.source_type, s.source_type) as source_type,
                            COALESCE(a.source_ref, s.source_ref) as source_ref,
                            COALESCE(a.why, s.why) as why,
                            COALESCE(a.action, s.action) as action,
                            COALESCE(a.obsidian_binding, s.obsidian_binding) as obsidian_binding,
                            COALESCE(a.case_binding, s.case_binding) as case_binding,
                            COALESCE(a.waiting_reason, s.waiting_reason) as waiting_reason,
                            COALESCE(a.last_error, s.last_error) as last_error,
                            COALESCE(a.rev, s.rev) as rev,
                            COALESCE(a.created_at, s.created_at) as created_at,
                            COALESCE(a.updated_at, s.updated_at) as updated_at,
                            COALESCE(a.completed_at, s.completed_at) as completed_at,
                            a.archived_at,
                            (a.matter_id IS NOT NULL) as is_archived,
                            COALESCE(a.legacy_id, s.legacy_id) as legacy_id,
                            COALESCE(a.raw_data, s.raw_data) as raw_data,
                            bm25(matter_fts) as search_score,
                            snippet(matter_fts, 1, '<b>', '</b>', '...', 10) as hl_title,
                            snippet(matter_fts, 2, '<b>', '</b>', '...', 10) as hl_why
                        FROM matter_fts
                        LEFT JOIN matter_archive a ON matter_fts.matter_id = a.matter_id
                        LEFT JOIN matter_state s ON matter_fts.matter_id = s.matter_id
                        WHERE {where_sql}
                        ORDER BY search_score ASC, COALESCE(a.completed_at, s.completed_at) DESC
                        LIMIT ? OFFSET ?
                    """
                    rows = db.execute(data_sql, (*params, page_size, offset)).fetchall()
                except sqlite3.OperationalError:
                    return {
                        "total": 0,
                        "page": page,
                        "page_size": page_size,
                        "has_more": False,
                        "items": [],
                    }
            else:
                where_clauses = ["1=1"]
                params = []
                if status_list:
                    placeholders = ",".join("?" for _ in status_list)
                    where_clauses.append(f"status IN ({placeholders})")
                    params.extend(status_list)
                if source_type:
                    where_clauses.append("source_type=?")
                    params.append(source_type)

                where_sql = " AND ".join(where_clauses)
                count_sql = f"SELECT COUNT(*) FROM matter_archive WHERE {where_sql}"
                total = db.execute(count_sql, params).fetchone()[0]

                data_sql = f"""
                    SELECT *, 1 as is_archived FROM matter_archive
                    WHERE {where_sql}
                    ORDER BY completed_at DESC, archived_at DESC
                    LIMIT ? OFFSET ?
                """
                rows = db.execute(data_sql, (*params, page_size, offset)).fetchall()

            items = []
            for r in rows:
                entity = self._row_to_entity(r)
                item_dict = entity.to_dict()
                is_archived = bool(r["is_archived"]) if "is_archived" in r.keys() else True
                item_dict["is_archived"] = is_archived
                item_dict["archived_at"] = r["archived_at"] if "archived_at" in r.keys() and r["archived_at"] is not None else r["updated_at"]
                if "search_score" in r.keys():
                    item_dict["search_score"] = r["search_score"]
                hl_title = clean_cjk_snippet(r["hl_title"]) if "hl_title" in r.keys() and r["hl_title"] else entity.title
                hl_why = clean_cjk_snippet(r["hl_why"]) if "hl_why" in r.keys() and r["hl_why"] else entity.why
                item_dict["highlights"] = {"title": hl_title, "why": hl_why}
                item_dict["title_snippet"] = hl_title
                item_dict["why_snippet"] = hl_why

                obs_url = ""
                if item_dict.get("obsidian_binding") and isinstance(item_dict["obsidian_binding"], dict):
                    obs_path = item_dict["obsidian_binding"].get("path", "")
                    if obs_path:
                        clean_path = obs_path.removesuffix(".md")
                        obs_url = f"obsidian://open?vault=obsidian&file={quote(clean_path)}"
                        item_dict["obsidian_binding"]["url"] = obs_url
                item_dict["obsidian_url"] = obs_url

                items.append(item_dict)

            return {
                "total": total,
                "page": page,
                "page_size": page_size,
                "has_more": (offset + len(items)) < total,
                "items": items,
            }

    def restore_matter(self, matter_id: str, target_status: str = "todo", clock: Optional[Callable[[], float]] = None) -> UnifiedMatterEntity:
        """从归档冷表中原子恢复事项至活跃热表 (matter_state)"""
        if target_status not in FSM_STATES:
            raise MatterIllegalTransition(f"Invalid target status: {target_status}")

        now = (clock or self.clock)()
        with self.db() as db:
            row = db.execute("SELECT * FROM matter_archive WHERE matter_id=?", (matter_id,)).fetchone()
            if not row and not matter_id.startswith("mtr-"):
                row = db.execute("SELECT * FROM matter_archive WHERE legacy_id=?", (matter_id,)).fetchone()
            if not row:
                raise MatterNotFound(f"Archived matter not found: {matter_id}")

            entity = self._row_to_entity(row)
            new_rev = entity.rev + 1

            db.execute("""
                INSERT OR REPLACE INTO matter_state (
                    matter_id, title, status, urgency, due_date, source_type,
                    source_ref, why, action, obsidian_binding, case_binding,
                    waiting_reason, last_error, rev, created_at, updated_at,
                    completed_at, legacy_id, raw_data
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                entity.matter_id,
                entity.title,
                target_status,
                entity.urgency,
                entity.due_date,
                entity.source_type,
                json.dumps(entity.source_ref, ensure_ascii=False),
                entity.why,
                json.dumps(entity.action, ensure_ascii=False) if entity.action else None,
                json.dumps(entity.obsidian_binding, ensure_ascii=False) if entity.obsidian_binding else None,
                json.dumps(entity.case_binding, ensure_ascii=False) if entity.case_binding else None,
                entity.waiting_reason,
                entity.last_error,
                new_rev,
                entity.created_at,
                now,
                None,
                entity.legacy_id,
                row["raw_data"] if "raw_data" in row.keys() else "{}",
            ))

            db.execute("DELETE FROM matter_archive WHERE matter_id=?", (entity.matter_id,))

            restored_entity = UnifiedMatterEntity(
                matter_id=entity.matter_id,
                title=entity.title,
                status=target_status,
                rev=new_rev,
                created_at=entity.created_at,
                updated_at=now,
                source_type=entity.source_type,
                urgency=entity.urgency,
                due_date=entity.due_date,
                source_ref=entity.source_ref,
                why=entity.why,
                action=entity.action,
                obsidian_binding=entity.obsidian_binding,
                case_binding=entity.case_binding,
                waiting_reason=entity.waiting_reason,
                last_error=entity.last_error,
                completed_at=None,
                legacy_id=entity.legacy_id,
            )

            self._sync_fts(db, restored_entity)
            db.commit()
            return restored_entity
