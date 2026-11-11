"""主动定时与事件触发器（Triggers 第一版，对标 OpenMausBot Triggers 模式）。

与 `triggers.py`（被动事项评估事件账本）严格分离：
- 存储于 `Path(state) / "scheduled-triggers.sqlite"`（权限 0600，WAL 模式）
- 纯 Python 零外部依赖 5 段 Cron 解析与 `Asia/Shanghai` 下次触发时间计算
- 支持 `morning_briefing`（晨间简报）、`schedule_subscription_due`（日程/订阅到期巡检，无到期项静默跳过）、`custom`（自定义定时交办/提醒），并为后续 `event` 触发预留 `event_source` / `event_filter`
- 防并发重入（`running_run_id` -> `skipped_overlap` + 推进 `next_run_at` + 超时死锁自动回收）与异常隔离（记录 `last_error` / `trigger_runs` 失败原因，绝不拖垮主循环）
"""
from __future__ import annotations

import asyncio
import calendar
import inspect
import json
import secrets
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Asia/Shanghai")
VALID_KINDS = ("cron", "event")
VALID_TEMPLATES = ("morning_briefing", "schedule_subscription_due", "nightly_memory_dream", "custom")
VALID_STATUSES = ("active", "paused")
VALID_CHANNELS = ("personal", "work", "bookkeeping")
WEEKDAY_NAMES = ("周一", "周二", "周三", "周四", "周五", "周六", "周日")

_MONTH_ALIASES = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
}
_DOW_ALIASES = {
    "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
}

TEMPLATE_SPECS: dict[str, dict[str, Any]] = {
    "morning_briefing": {
        "id": "morning_briefing",
        "preset_trigger_id": "strg_preset_morning_briefing",
        "name": "晨间简报",
        "description": "汇总今日日程、待办与下一步重点、本月与今日记账概况，向主对话发送晨间简报并推送通知。",
        "default_cron_expr": "30 8 * * *",
        "default_channel": "personal",
        "default_prompt": "汇总今日日程、待办与下一步重点、近期记账概况，生成简明晨间简报。",
        "silent_when_empty": False,
    },
    "schedule_subscription_due": {
        "id": "schedule_subscription_due",
        "preset_trigger_id": "strg_preset_schedule_subscription_due",
        "name": "日程与订阅到期提醒",
        "description": "检查 1 小时内即将开始的日程、到点提醒与 3 天内到期订阅；有到期项时主动提醒，无到期项静默记成功不打扰。",
        "default_cron_expr": "0 9,13,18 * * *",
        "default_channel": "personal",
        "default_prompt": "检查今日即将开始的日程、到点提醒与即将到期订阅；有到期项时主动推入对话，无则静默跳过。",
        "silent_when_empty": True,
    },
    "custom": {
        "id": "custom",
        "preset_trigger_id": "",
        "name": "自定义定时提醒",
        "description": "按自定义 5 段 Cron 表达式与提示语定时投递主动提醒或巡检播报。",
        "default_cron_expr": "0 9 * * *",
        "default_channel": "personal",
        "default_prompt": "",
        "silent_when_empty": False,
    },
}

NIGHTLY_DREAM_SPEC: dict[str, Any] = {
    "id": "nightly_memory_dream",
    "preset_trigger_id": "strg_preset_nightly_memory_dream",
    "name": "夜间记忆整理 (/dream)",
    "description": "每晚 03:30 静默运行 memory_dream.run_dream：合并回合捕获偏好、近似去重、归档过期临时状态，静默写盘不推送打扰。",
    "default_cron_expr": "30 3 * * *",
    "default_channel": "personal",
    "default_prompt": "静默执行 /dream 夜间记忆整理与过期归档。",
    "silent_when_empty": True,
    "internal": True,
}

BUILTIN_ROUTINES: dict[str, dict[str, Any]] = {
    "nightly_memory_dream": NIGHTLY_DREAM_SPEC,
}

ALL_TEMPLATE_SPECS: dict[str, dict[str, Any]] = {
    **TEMPLATE_SPECS,
    **BUILTIN_ROUTINES,
}


def _parse_token(token: str, aliases: dict[str, int] | None, lo: int, hi: int, is_dow: bool = False) -> int:
    raw = token.strip().lower()
    if not raw:
        raise ValueError("空数值")
    if aliases and raw in aliases:
        val = aliases[raw]
    else:
        if not raw.isdigit():
            raise ValueError(f"非法数值 {token!r}")
        val = int(raw)
    if is_dow and val == 7:
        val = 0
    max_allowed = 7 if is_dow else hi
    if not (lo <= val <= max_allowed):
        raise ValueError(f"数值 {token!r} 超出范围 [{lo}, {max_allowed}]")
    return val


def _parse_cron_field(
    field: str,
    lo: int,
    hi: int,
    *,
    aliases: dict[str, int] | None = None,
    is_dow: bool = False,
) -> tuple[set[int], bool]:
    text = field.strip()
    if not text:
        raise ValueError("存在空字段")
    if text == "*":
        return set(range(lo, hi + 1)), True

    values: set[int] = set()
    for part in text.split(","):
        item = part.strip()
        if not item:
            raise ValueError(f"列表字段格式错误: {field!r}")
        step = 1
        if "/" in item:
            base, step_str = item.split("/", 1)
            if not step_str.strip().isdigit() or int(step_str.strip()) <= 0:
                raise ValueError(f"无效步长: {item!r}")
            step = int(step_str.strip())
        else:
            base = item

        if base == "*":
            start, end = lo, hi
            for v in range(start, end + 1, step):
                values.add(0 if (is_dow and v == 7) else v)
        elif "-" in base:
            left, right = base.split("-", 1)
            raw_l = left.strip().lower()
            raw_r = right.strip().lower()
            start = _parse_token(raw_l, aliases, lo, hi, is_dow=False)
            end = _parse_token(raw_r, aliases, lo, 7 if is_dow else hi, is_dow=False)
            if start > end:
                raise ValueError(f"区间起点大于终点: {item!r}")
            for v in range(start, end + 1, step):
                values.add(0 if (is_dow and v == 7) else v)
        else:
            if "/" in item:
                start = _parse_token(base, aliases, lo, hi, is_dow=is_dow)
                for v in range(start, hi + 1, step):
                    values.add(0 if (is_dow and v == 7) else v)
            else:
                values.add(_parse_token(base, aliases, lo, hi, is_dow=is_dow))

    if not values:
        raise ValueError(f"字段未匹配任何有效值: {field!r}")
    return values, False


def parse_cron_expr(cron_expr: str) -> dict[str, Any]:
    """解析标准 5 段 Cron（分 时 日 月 周），返回匹配集合与通配标记。"""
    if not isinstance(cron_expr, str):
        raise ValueError("Cron 表达式必须为字符串")
    parts = cron_expr.strip().split()
    if len(parts) != 5:
        raise ValueError(f"无效的 5 段 cron 表达式 {cron_expr!r}：需要「分 时 日 月 周」共 5 段")
    try:
        minutes, min_star = _parse_cron_field(parts[0], 0, 59)
        hours, hour_star = _parse_cron_field(parts[1], 0, 23)
        doms, dom_star = _parse_cron_field(parts[2], 1, 31)
        months, mon_star = _parse_cron_field(parts[3], 1, 12, aliases=_MONTH_ALIASES)
        dows, dow_star = _parse_cron_field(parts[4], 0, 6, aliases=_DOW_ALIASES, is_dow=True)
    except ValueError as exc:
        raise ValueError(f"无效的 5 段 cron 表达式 {cron_expr!r}：{exc}") from exc
    return {
        "raw": " ".join(parts),
        "minutes": sorted(minutes),
        "hours": sorted(hours),
        "doms": set(doms),
        "months": set(months),
        "dows": set(dows),
        "min_star": min_star,
        "hour_star": hour_star,
        "dom_star": dom_star,
        "mon_star": mon_star,
        "dow_star": dow_star,
    }


def _cron_day_matches(spec: dict[str, Any], dt: datetime) -> bool:
    cron_dow = (dt.weekday() + 1) % 7  # Python Mon=0..Sun=6 -> Cron Sun=0, Mon=1..Sat=6
    dom_match = dt.day in spec["doms"]
    dow_match = cron_dow in spec["dows"]
    if spec["dom_star"] and spec["dow_star"]:
        return True
    if spec["dom_star"]:
        return dow_match
    if spec["dow_star"]:
        return dom_match
    return dom_match or dow_match


def compute_next_run_at(cron_expr: str, after_ts: float) -> float:
    """按 Asia/Shanghai 计算严格大于 `after_ts` 的下一个整分触发时间戳。"""
    spec = parse_cron_expr(cron_expr)
    base = datetime.fromtimestamp(float(after_ts), TZ).replace(second=0, microsecond=0) + timedelta(minutes=1)
    max_year = base.year + 8
    cur = base
    hours_set = set(spec["hours"])
    minutes_list = spec["minutes"]
    hours_list = spec["hours"]

    while cur.year <= max_year:
        if cur.month not in spec["months"]:
            next_month = [m for m in sorted(spec["months"]) if m > cur.month]
            if next_month:
                cur = cur.replace(month=next_month[0], day=1, hour=0, minute=0)
            else:
                cur = cur.replace(year=cur.year + 1, month=min(spec["months"]), day=1, hour=0, minute=0)
            continue

        days_in_month = calendar.monthrange(cur.year, cur.month)[1]
        if not _cron_day_matches(spec, cur):
            if cur.day < days_in_month:
                cur = cur.replace(day=cur.day + 1, hour=0, minute=0)
            elif cur.month < 12:
                cur = cur.replace(month=cur.month + 1, day=1, hour=0, minute=0)
            else:
                cur = cur.replace(year=cur.year + 1, month=1, day=1, hour=0, minute=0)
            continue

        if cur.hour not in hours_set:
            next_hours = [h for h in hours_list if h > cur.hour]
            if next_hours:
                cur = cur.replace(hour=next_hours[0], minute=minutes_list[0])
            else:
                cur = (cur.replace(hour=0, minute=0) + timedelta(days=1))
            continue

        next_minutes = [m for m in minutes_list if m >= cur.minute]
        if next_minutes:
            return cur.replace(minute=next_minutes[0]).timestamp()

        next_hours = [h for h in hours_list if h > cur.hour]
        if next_hours:
            cur = cur.replace(hour=next_hours[0], minute=minutes_list[0])
        else:
            cur = (cur.replace(hour=0, minute=0) + timedelta(days=1))

    raise ValueError(f"无法在 8 年内为 cron {cron_expr!r} 找到下次运行时间")


def describe_cron(cron_expr: str) -> str:
    """生成客户端可读的中文周期说明。"""
    try:
        spec = parse_cron_expr(cron_expr)
    except ValueError:
        return cron_expr or "未设置"
    parts = spec["raw"].split()
    if parts[0].startswith("*/") and spec["hour_star"] and spec["dom_star"] and spec["mon_star"] and spec["dow_star"]:
        return f"每 {parts[0][2:]} 分钟"
    if len(spec["minutes"]) == 1 and spec["dom_star"] and spec["mon_star"]:
        mm = f"{spec['minutes'][0]:02d}"
        hh_text = "、".join(f"{h:02d}:{mm}" for h in spec["hours"][:4])
        if len(spec["hours"]) > 4:
            hh_text += " 等"
        if spec["dow_star"]:
            if spec["hour_star"]:
                return f"每小时 :{mm}"
            return f"每天 {hh_text}"
        if spec["dows"] == {1, 2, 3, 4, 5}:
            return f"工作日 {hh_text}"
        if spec["dows"] == {0, 6}:
            return f"周末 {hh_text}"
    return f"Cron ({spec['raw']})"


class ScheduledTriggerStore:
    """主动定时/事件触发器存储与执行引擎。"""

    def __init__(
        self,
        state: Path | str,
        *,
        conversation: Any = None,
        today_view: Any = None,
        next_steps: Any = None,
        finance_dashboard: Any = None,
        nudges: Any = None,
        notifications: Any = None,
        custom_runner: Callable[[dict[str, Any]], Any] | None = None,
        clock: Callable[[], float] = time.time,
        run_timeout_seconds: float = 600.0,
    ) -> None:
        self.state = Path(state)
        self.state.mkdir(parents=True, exist_ok=True)
        self.path = self.state / "scheduled-triggers.sqlite"
        self.conversation = conversation
        self.today_view = today_view
        self.next_steps = next_steps
        self.finance_dashboard = finance_dashboard
        self.nudges = nudges
        self.notifications = notifications
        self.custom_runner = custom_runner
        self.clock = clock
        self.run_timeout_seconds = float(run_timeout_seconds)
        self._init_db()

    def _init_db(self) -> None:
        with sqlite3.connect(self.path, timeout=20) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA foreign_keys=ON")
            db.execute(
                """
                CREATE TABLE IF NOT EXISTS scheduled_triggers (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT 'cron',
                    cron_expr TEXT NOT NULL DEFAULT '',
                    event_source TEXT NOT NULL DEFAULT '',
                    event_filter TEXT NOT NULL DEFAULT '{}',
                    template TEXT NOT NULL DEFAULT 'custom',
                    prompt TEXT NOT NULL DEFAULT '',
                    channel TEXT NOT NULL DEFAULT 'personal',
                    status TEXT NOT NULL DEFAULT 'active',
                    running_run_id TEXT NOT NULL DEFAULT '',
                    last_run_at REAL,
                    next_run_at REAL,
                    last_outcome TEXT NOT NULL DEFAULT '',
                    last_error TEXT NOT NULL DEFAULT '',
                    last_summary TEXT NOT NULL DEFAULT '',
                    run_count INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )
            db.execute(
                """
                CREATE TABLE IF NOT EXISTS trigger_runs (
                    id TEXT PRIMARY KEY,
                    trigger_id TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    finished_at REAL,
                    status TEXT NOT NULL,
                    summary TEXT NOT NULL DEFAULT '',
                    error TEXT NOT NULL DEFAULT '',
                    message_id TEXT NOT NULL DEFAULT ''
                )
                """
            )
            db.execute("CREATE INDEX IF NOT EXISTS idx_trigger_runs_tid_started ON trigger_runs(trigger_id, started_at DESC)")
            db.execute("CREATE INDEX IF NOT EXISTS idx_scheduled_triggers_due ON scheduled_triggers(status, next_run_at)")
            db.execute("CREATE TABLE IF NOT EXISTS trigger_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        conn = sqlite3.connect(self.path, timeout=20)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def _row_to_dict(self, row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
        d = dict(row)
        raw_filter = d.get("event_filter") or "{}"
        try:
            parsed_filter = json.loads(raw_filter) if isinstance(raw_filter, str) else raw_filter
            if not isinstance(parsed_filter, dict):
                parsed_filter = {}
        except ValueError:
            parsed_filter = {}
        d["event_filter"] = parsed_filter
        d["schedule_label"] = describe_cron(d["cron_expr"]) if d.get("kind") == "cron" else f"事件: {d.get('event_source') or '未指定'}"
        d["is_running"] = bool(d.get("running_run_id"))
        return d

    def _run_row_to_dict(self, row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
        return dict(row)

    def templates(self, *, include_internal: bool = False) -> list[dict[str, Any]]:
        source = ALL_TEMPLATE_SPECS if include_internal else TEMPLATE_SPECS
        return [dict(spec) for spec in source.values()]

    def builtin_routines(self) -> list[dict[str, Any]]:
        """返回内置后台静默例程（含 `nightly_memory_dream` 03:30 夜间记忆整理）及其下次运行时间。"""
        now = float(self.clock())
        out: list[dict[str, Any]] = []
        with self.db() as db:
            for key, spec in BUILTIN_ROUTINES.items():
                meta_key = f"builtin_routine:{key}"
                row = db.execute("SELECT value FROM trigger_meta WHERE key=?", (meta_key,)).fetchone()
                state_obj: dict[str, Any] = {}
                if row:
                    try:
                        state_obj = json.loads(row[0])
                    except ValueError:
                        state_obj = {}
                next_at = state_obj.get("next_run_at")
                if next_at is None:
                    next_at = compute_next_run_at(spec["default_cron_expr"], now)
                out.append(
                    {
                        **spec,
                        "status": state_obj.get("status", "active"),
                        "cron_expr": state_obj.get("cron_expr", spec["default_cron_expr"]),
                        "last_run_at": state_obj.get("last_run_at"),
                        "next_run_at": next_at,
                        "last_summary": state_obj.get("last_summary", ""),
                        "run_count": int(state_obj.get("run_count", 0)),
                    }
                )
        return out

    def ensure_nightly_dream(self, *, status: str = "active") -> dict[str, Any]:
        """幂等创建或读取显式 `nightly_memory_dream` 触发器行（Cron `30 3 * * *`）。"""
        preset_id = NIGHTLY_DREAM_SPEC["preset_trigger_id"]
        try:
            return self.get(preset_id)
        except KeyError:
            return self.create(
                name=NIGHTLY_DREAM_SPEC["name"],
                template="nightly_memory_dream",
                kind="cron",
                cron_expr=NIGHTLY_DREAM_SPEC["default_cron_expr"],
                prompt=NIGHTLY_DREAM_SPEC["default_prompt"],
                channel=NIGHTLY_DREAM_SPEC["default_channel"],
                status=status,
                trigger_id=preset_id,
            )

    def ensure_presets(self, *, include_internal: bool = False) -> list[dict[str, Any]]:
        """首次启动幂等写入两条实用预设触发器（默认 paused 待启用，不擅自打扰），并初始化内置 `nightly_memory_dream` 03:30 例程。"""
        now = float(self.clock())
        created: list[str] = []
        with self.db() as db:
            dream_meta = db.execute(
                "SELECT value FROM trigger_meta WHERE key='builtin_routine:nightly_memory_dream'"
            ).fetchone()
            if not dream_meta:
                dream_next = compute_next_run_at(NIGHTLY_DREAM_SPEC["default_cron_expr"], now)
                db.execute(
                    "INSERT OR REPLACE INTO trigger_meta(key, value) VALUES('builtin_routine:nightly_memory_dream', ?)",
                    (
                        json.dumps(
                            {
                                "id": NIGHTLY_DREAM_SPEC["preset_trigger_id"],
                                "template": "nightly_memory_dream",
                                "cron_expr": NIGHTLY_DREAM_SPEC["default_cron_expr"],
                                "status": "active",
                                "next_run_at": dream_next,
                                "last_run_at": None,
                                "run_count": 0,
                            },
                            ensure_ascii=False,
                        ),
                    ),
                )
            seeded = db.execute("SELECT value FROM trigger_meta WHERE key='presets_seeded_v1'").fetchone()
            if not seeded:
                for tpl_key in ("morning_briefing", "schedule_subscription_due"):
                    spec = TEMPLATE_SPECS[tpl_key]
                    preset_id = spec["preset_trigger_id"]
                    exists = db.execute("SELECT 1 FROM scheduled_triggers WHERE id=?", (preset_id,)).fetchone()
                    if exists:
                        continue
                    next_at = compute_next_run_at(spec["default_cron_expr"], now)
                    db.execute(
                        """
                        INSERT INTO scheduled_triggers (
                            id, name, kind, cron_expr, event_source, event_filter,
                            template, prompt, channel, status, running_run_id,
                            last_run_at, next_run_at, last_outcome, last_error, last_summary,
                            run_count, created_at, updated_at
                        ) VALUES (?, ?, 'cron', ?, '', '{}', ?, ?, ?, 'paused', '', NULL, ?, '', '', '', 0, ?, ?)
                        """,
                        (
                            preset_id,
                            spec["name"],
                            spec["default_cron_expr"],
                            tpl_key,
                            spec["default_prompt"],
                            spec["default_channel"],
                            next_at,
                            now,
                            now,
                        ),
                    )
                    created.append(preset_id)
                db.execute(
                    "INSERT OR REPLACE INTO trigger_meta(key, value) VALUES('presets_seeded_v1', ?)",
                    (json.dumps({"at": now, "ids": created}),),
                )
        if include_internal:
            self.ensure_nightly_dream(status="active")
        return self.list()

    def list(self, *, status: str = "", channel: str = "") -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if status:
            clauses.append("status = ?")
            params.append(status)
        if channel:
            clauses.append("channel = ?")
            params.append(channel)
        where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
        with self.db() as db:
            rows = db.execute(
                f"SELECT * FROM scheduled_triggers {where} ORDER BY created_at ASC, id ASC",
                tuple(params),
            ).fetchall()
        return [self._row_to_dict(r) for r in rows]

    def get(self, trigger_id: str) -> dict[str, Any]:
        if not trigger_id:
            raise ValueError("缺少 trigger_id")
        with self.db() as db:
            row = db.execute("SELECT * FROM scheduled_triggers WHERE id=?", (trigger_id,)).fetchone()
        if not row:
            raise KeyError(f"触发器不存在: {trigger_id}")
        return self._row_to_dict(row)

    def recent_runs(self, trigger_id: str = "", limit: int = 20) -> list[dict[str, Any]]:
        lim = max(1, min(int(limit or 20), 100))
        with self.db() as db:
            if trigger_id:
                rows = db.execute(
                    "SELECT * FROM trigger_runs WHERE trigger_id=? ORDER BY started_at DESC, rowid DESC LIMIT ?",
                    (trigger_id, lim),
                ).fetchall()
            else:
                rows = db.execute(
                    "SELECT * FROM trigger_runs ORDER BY started_at DESC, rowid DESC LIMIT ?",
                    (lim,),
                ).fetchall()
        return [self._run_row_to_dict(r) for r in rows]

    def _validate_channel(self, channel: str) -> str:
        ch = (channel or "personal").strip() or "personal"
        if ch not in VALID_CHANNELS:
            raise ValueError(f"不支持的 channel {ch!r}，可选: {', '.join(VALID_CHANNELS)}")
        return ch

    def create(
        self,
        *,
        name: str = "",
        template: str = "custom",
        kind: str = "cron",
        cron_expr: str = "",
        prompt: str = "",
        channel: str = "personal",
        status: str = "active",
        event_source: str = "",
        event_filter: dict[str, Any] | None = None,
        trigger_id: str = "",
    ) -> dict[str, Any]:
        tpl = (template or "custom").strip() or "custom"
        if tpl not in ALL_TEMPLATE_SPECS:
            raise ValueError(f"不支持的触发器模板 {tpl!r}，可选: {', '.join(VALID_TEMPLATES)}")
        spec = ALL_TEMPLATE_SPECS[tpl]

        knd = (kind or "cron").strip() or "cron"
        if knd not in VALID_KINDS:
            raise ValueError(f"不支持的触发器类型 {knd!r}，可选: cron, event")

        st = (status or "active").strip() or "active"
        if st not in VALID_STATUSES:
            raise ValueError(f"不支持的触发器状态 {st!r}，可选: active, paused")

        ch = self._validate_channel(channel or spec["default_channel"])
        final_name = (name or spec["name"]).strip()
        if not final_name:
            raise ValueError("触发器名称不能为空")

        final_prompt = (prompt if prompt is not None and prompt.strip() else spec["default_prompt"]).strip()
        if tpl == "custom" and not final_prompt:
            raise ValueError("自定义触发器 (template='custom') 必须提供非空 prompt")

        now = float(self.clock())
        if knd == "cron":
            expr = (cron_expr or spec["default_cron_expr"]).strip()
            parsed = parse_cron_expr(expr)
            expr = parsed["raw"]
            next_at: float | None = compute_next_run_at(expr, now)
            ev_source = ""
            ev_filter_json = "{}"
        else:
            expr = (cron_expr or "").strip()
            if expr:
                expr = parse_cron_expr(expr)["raw"]
            ev_source = (event_source or "").strip()
            if not ev_source:
                raise ValueError("事件触发器 (kind='event') 必须指定 event_source（如 mail / calendar）")
            if event_filter is not None and not isinstance(event_filter, dict):
                raise ValueError("event_filter 必须为 JSON 对象")
            ev_filter_json = json.dumps(event_filter or {}, ensure_ascii=False, sort_keys=True)
            next_at = None

        tid = trigger_id.strip() if trigger_id else f"strg_{secrets.token_hex(8)}"
        if not tid.startswith("strg_"):
            tid = f"strg_{tid}"

        with self.db() as db:
            if db.execute("SELECT 1 FROM scheduled_triggers WHERE id=?", (tid,)).fetchone():
                raise ValueError(f"触发器 ID 已存在: {tid}")
            db.execute(
                """
                INSERT INTO scheduled_triggers (
                    id, name, kind, cron_expr, event_source, event_filter,
                    template, prompt, channel, status, running_run_id,
                    last_run_at, next_run_at, last_outcome, last_error, last_summary,
                    run_count, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', NULL, ?, '', '', '', 0, ?, ?)
                """,
                (
                    tid,
                    final_name[:80],
                    knd,
                    expr,
                    ev_source,
                    ev_filter_json,
                    tpl,
                    final_prompt[:2000],
                    ch,
                    st,
                    next_at,
                    now,
                    now,
                ),
            )
        return self.get(tid)

    def update(
        self,
        trigger_id: str,
        *,
        name: str | None = None,
        cron_expr: str | None = None,
        prompt: str | None = None,
        channel: str | None = None,
        status: str | None = None,
        template: str | None = None,
        kind: str | None = None,
        event_source: str | None = None,
        event_filter: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        current = self.get(trigger_id)
        now = float(self.clock())

        new_tpl = current["template"] if not template else template.strip()
        if new_tpl not in ALL_TEMPLATE_SPECS:
            raise ValueError(f"不支持的触发器模板 {new_tpl!r}")

        new_kind = current["kind"] if not kind else kind.strip()
        if new_kind not in VALID_KINDS:
            raise ValueError(f"不支持的触发器类型 {new_kind!r}")

        new_status = current["status"] if not status else status.strip()
        if new_status not in VALID_STATUSES:
            raise ValueError(f"不支持的触发器状态 {new_status!r}")

        new_channel = current["channel"] if not channel else self._validate_channel(channel)
        new_name = current["name"] if (name is None or not name.strip()) else name.strip()[:80]
        new_prompt = current["prompt"] if prompt is None else prompt.strip()[:2000]
        if new_tpl == "custom" and not new_prompt:
            raise ValueError("自定义触发器 (template='custom') 的 prompt 不能为空")

        if new_kind == "cron":
            raw_expr = current["cron_expr"] if (cron_expr is None or not cron_expr.strip()) else cron_expr.strip()
            if not raw_expr:
                raw_expr = ALL_TEMPLATE_SPECS[new_tpl]["default_cron_expr"]
            new_expr = parse_cron_expr(raw_expr)["raw"]
            if new_expr != current["cron_expr"] or (new_status == "active" and current["status"] != "active") or current["next_run_at"] is None:
                next_at: float | None = compute_next_run_at(new_expr, now)
            else:
                next_at = current["next_run_at"]
            new_ev_source = current["event_source"] if event_source is None else event_source.strip()
            new_ev_filter = current["event_filter"] if event_filter is None else event_filter
        else:
            new_expr = current["cron_expr"] if cron_expr is None else cron_expr.strip()
            if new_expr:
                new_expr = parse_cron_expr(new_expr)["raw"]
            new_ev_source = (current["event_source"] if event_source is None else event_source).strip()
            if not new_ev_source:
                raise ValueError("事件触发器必须提供 event_source")
            new_ev_filter = current["event_filter"] if event_filter is None else event_filter
            if not isinstance(new_ev_filter, dict):
                raise ValueError("event_filter 必须为 JSON 对象")
            next_at = None

        with self.db() as db:
            db.execute(
                """
                UPDATE scheduled_triggers
                SET name=?, kind=?, cron_expr=?, event_source=?, event_filter=?,
                    template=?, prompt=?, channel=?, status=?, next_run_at=?, updated_at=?
                WHERE id=?
                """,
                (
                    new_name,
                    new_kind,
                    new_expr,
                    new_ev_source,
                    json.dumps(new_ev_filter, ensure_ascii=False, sort_keys=True),
                    new_tpl,
                    new_prompt,
                    new_channel,
                    new_status,
                    next_at,
                    now,
                    trigger_id,
                ),
            )
        return self.get(trigger_id)

    def pause(self, trigger_id: str) -> dict[str, Any]:
        return self.update(trigger_id, status="paused")

    def resume(self, trigger_id: str) -> dict[str, Any]:
        current = self.get(trigger_id)
        now = float(self.clock())
        next_at = compute_next_run_at(current["cron_expr"], now) if current["kind"] == "cron" else None
        with self.db() as db:
            db.execute(
                "UPDATE scheduled_triggers SET status='active', next_run_at=?, updated_at=? WHERE id=?",
                (next_at, now, trigger_id),
            )
        return self.get(trigger_id)

    def delete(self, trigger_id: str) -> dict[str, Any]:
        existing = self.get(trigger_id)
        with self.db() as db:
            db.execute("DELETE FROM trigger_runs WHERE trigger_id=?", (trigger_id,))
            db.execute("DELETE FROM scheduled_triggers WHERE id=?", (trigger_id,))
        return {"deleted": True, "trigger_id": trigger_id, "name": existing["name"]}

    def _deliver_to_conversation(
        self,
        receipt_key: str,
        text: str,
        *,
        channel: str = "personal",
        meta: dict[str, Any] | None = None,
    ) -> str:
        if self.conversation is None or not hasattr(self.conversation, "task_receipt"):
            return ""
        fn = self.conversation.task_receipt
        msg_id: str | None = None
        try:
            sig = inspect.signature(fn)
            accepts_channel = "channel" in sig.parameters or any(
                p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()
            )
        except (TypeError, ValueError):
            accepts_channel = False

        if accepts_channel:
            res = fn(receipt_key, text, channel=channel)
        else:
            res = fn(receipt_key, text)
        msg_id = str(res) if isinstance(res, str) and res else f"task-result:{receipt_key}"

        if meta and hasattr(self.conversation, "db"):
            try:
                with self.conversation.db() as db:
                    db.execute(
                        "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)",
                        (f"message-metadata:{msg_id}", json.dumps(meta, ensure_ascii=False)),
                    )
            except Exception:
                pass

        if self.notifications is not None and hasattr(self.notifications, "enqueue"):
            try:
                self.notifications.enqueue()
            except Exception:
                pass
        return msg_id

    async def _execute_morning_briefing(self, trigger: dict[str, Any], now: float) -> tuple[str, str]:
        local_dt = datetime.fromtimestamp(now, TZ)
        day_label = f"{local_dt.month:02d}-{local_dt.day:02d} {WEEKDAY_NAMES[local_dt.weekday()]}"
        sections: list[str] = [f"早安 Eddie，今日简报（{day_label}）："]

        # 1. 今日日程与待办提醒
        events_lines: list[str] = []
        todo_lines: list[str] = []
        if self.today_view is not None and hasattr(self.today_view, "snapshot"):
            snap = await asyncio.to_thread(self.today_view.snapshot)
            for ev in (snap.get("events") or []):
                if ev.get("informational"):
                    continue
                if ev.get("all_day"):
                    when = "全天"
                else:
                    when = datetime.fromtimestamp(float(ev.get("start") or now), TZ).strftime("%H:%M")
                loc = f"（{ev['location']}）" if ev.get("location") else ""
                events_lines.append(f"• {when} {ev.get('title') or '日程'}{loc}")
            for rm in (snap.get("reminders") or [])[:4]:
                if rm.get("status") == "pending":
                    due_part = str(rm.get("due") or "")[-5:]
                    todo_lines.append(f"• [提醒 {due_part}] {rm.get('title') or ''}".strip())
            for td in (snap.get("todos") or [])[:5]:
                prefix = "⚠️过期 " if td.get("overdue") else ""
                todo_lines.append(f"• {prefix}{td.get('title') or ''}")

        if events_lines:
            sections.append("【今日日程】\n" + "\n".join(events_lines[:6]))
        else:
            sections.append("【今日日程】今日暂无固定排期。")

        # 2. 下一步重点
        next_lines: list[str] = []
        if self.next_steps is not None and hasattr(self.next_steps, "snapshot"):
            try:
                ns = await asyncio.to_thread(self.next_steps.snapshot)
                for item in (ns.get("items") or [])[:3]:
                    if item.get("state", "open") == "open":
                        next_lines.append(f"• {item.get('title') or ''}")
            except Exception:
                pass

        combined_focus = todo_lines[:4] + [x for x in next_lines if x not in todo_lines][:3]
        if combined_focus:
            sections.append("【待办与重点】\n" + "\n".join(combined_focus[:6]))

        # 3. 近期记账概况
        if self.finance_dashboard is not None and hasattr(self.finance_dashboard, "snapshot"):
            try:
                fin = await self.finance_dashboard.snapshot(local_dt.strftime("%Y-%m"))
                if isinstance(fin, dict) and fin.get("available"):
                    currencies = fin.get("currencies") or []
                    if currencies:
                        cny = next((c for c in currencies if c.get("currency") in ("CNY", "RMB")), currencies[0])
                        month_yuan = float(cny.get("month_minor", 0)) / 100.0
                        today_yuan = float(cny.get("today_minor", 0)) / 100.0
                        sections.append(f"【账本概况】本月累计支出 ¥{month_yuan:,.2f}（今日 ¥{today_yuan:,.2f}，共 {cny.get('count', 0)} 笔）。")
                    else:
                        sections.append("【账本概况】本月暂无支出记录。")
            except Exception:
                pass

        text = "\n\n".join(sections)
        receipt_key = f"trigger:{trigger['id']}:{local_dt.strftime('%Y%m%d%H%M')}:{secrets.token_hex(3)}"
        msg_id = self._deliver_to_conversation(
            receipt_key,
            text,
            channel=trigger.get("channel") or "personal",
            meta={
                "kind": "scheduled_trigger",
                "trigger_id": trigger["id"],
                "template": "morning_briefing",
                "channel": trigger.get("channel") or "personal",
            },
        )
        summary = f"已推送晨间简报（日程 {len(events_lines)} 项，待办/重点 {len(combined_focus)} 项）"
        return summary, msg_id

    async def _execute_schedule_subscription_due(
        self,
        trigger: dict[str, Any],
        now: float,
        *,
        manual: bool = False,
    ) -> tuple[str, str]:
        due_items: list[tuple[str, str]] = []  # (dedup_key, display_line)

        if self.nudges is not None:
            for fn_name in ("schedule_candidates", "due_reminders", "subscriptions"):
                fn = getattr(self.nudges, fn_name, None)
                if callable(fn):
                    try:
                        cands = await asyncio.to_thread(fn, now)
                        for c in cands or []:
                            key = str(c.get("key") or c.get("fingerprint") or c.get("subject") or "")
                            line = str(c.get("conclusion") or c.get("text") or "").splitlines()[0].strip()
                            if line:
                                due_items.append((key or line, line))
                    except Exception:
                        pass
        elif self.today_view is not None and hasattr(self.today_view, "snapshot"):
            snap = await asyncio.to_thread(self.today_view.snapshot)
            for ev in (snap.get("events") or []):
                if ev.get("informational") or ev.get("all_day"):
                    continue
                start = float(ev.get("start") or 0)
                if now < start <= now + 3600:
                    mins = max(1, round((start - now) / 60))
                    hhmm = datetime.fromtimestamp(start, TZ).strftime("%H:%M")
                    title = str(ev.get("title") or "日程")
                    due_items.append((f"ev:{title}:{int(start // 60)}", f"{hhmm}「{title}」还有 {mins} 分钟开始"))

        if not due_items:
            return "无即将开始日程或到期订阅，静默跳过", ""

        local_dt = datetime.fromtimestamp(now, TZ)
        day_str = local_dt.date().isoformat()
        if not manual:
            with self.db() as db:
                notified_row = db.execute(
                    "SELECT value FROM trigger_meta WHERE key=?",
                    (f"due_notified:{trigger['id']}:{day_str}",),
                ).fetchone()
                already = set(json.loads(notified_row[0])) if notified_row else set()
            fresh = [(k, line) for k, line in due_items if k not in already]
            if not fresh:
                return "今日到期项已提醒过，静默跳过", ""
            selected = fresh
        else:
            selected = due_items

        lines = [line for _, line in selected[:8]]
        if len(lines) == 1:
            text = lines[0]
        else:
            text = "近期日程与订阅到期提醒：\n" + "\n".join(f"• {line}" for line in lines)

        receipt_key = f"trigger:{trigger['id']}:{int(now)}:{secrets.token_hex(3)}"
        msg_id = self._deliver_to_conversation(
            receipt_key,
            text,
            channel=trigger.get("channel") or "personal",
            meta={
                "kind": "scheduled_trigger",
                "trigger_id": trigger["id"],
                "template": "schedule_subscription_due",
                "channel": trigger.get("channel") or "personal",
            },
        )
        if not manual:
            with self.db() as db:
                notified_row = db.execute(
                    "SELECT value FROM trigger_meta WHERE key=?",
                    (f"due_notified:{trigger['id']}:{day_str}",),
                ).fetchone()
                merged = list(dict.fromkeys((json.loads(notified_row[0]) if notified_row else []) + [k for k, _ in selected]))
                db.execute(
                    "INSERT OR REPLACE INTO trigger_meta(key, value) VALUES(?, ?)",
                    (f"due_notified:{trigger['id']}:{day_str}", json.dumps(merged, ensure_ascii=False)),
                )
        return f"发现 {len(selected)} 项到期提醒并已主动推送", msg_id

    async def _execute_nightly_memory_dream(
        self,
        trigger: dict[str, Any],
        now: float,
        *,
        manual: bool = False,
    ) -> tuple[str, str, dict[str, Any]]:
        import memory_dream

        reason = "manual_trigger" if manual else "nightly_cron"
        result = await memory_dream.run_dream(self.state, reason=reason, now=now)
        summary = str(result.get("summary") or "夜间记忆整理完成")
        # 夜间 03:30 静默整理，不向主对话灌水、不发 Bark 通知打扰
        return summary, "", result

    async def _execute_custom(self, trigger: dict[str, Any], now: float) -> tuple[str, str]:
        prompt_text = (trigger.get("prompt") or "").strip()
        if self.custom_runner is not None:
            result = self.custom_runner(trigger)
            if inspect.isawaitable(result):
                result = await result
            if isinstance(result, dict):
                if result.get("silent"):
                    return str(result.get("summary") or "按规则静默跳过"), ""
                body = str(result.get("text") or prompt_text)
                summary = str(result.get("summary") or f"已执行自定义触发器「{trigger['name']}」")
            else:
                body = str(result or prompt_text)
                summary = f"已执行自定义触发器「{trigger['name']}」"
        else:
            body = f"【定时提醒 · {trigger['name']}】\n{prompt_text}"
            summary = f"已触发定时提醒「{trigger['name']}」"

        receipt_key = f"trigger:{trigger['id']}:{int(now)}:{secrets.token_hex(3)}"
        msg_id = self._deliver_to_conversation(
            receipt_key,
            body,
            channel=trigger.get("channel") or "personal",
            meta={
                "kind": "scheduled_trigger",
                "trigger_id": trigger["id"],
                "template": "custom",
                "channel": trigger.get("channel") or "personal",
            },
        )
        return summary, msg_id

    def _recover_stale_running_if_needed(self, db: sqlite3.Connection, row: sqlite3.Row, now: float) -> str:
        """若上一轮运行已超过 run_timeout_seconds，自动回收死锁状态，避免永久跳过。"""
        running_id = str(row["running_run_id"] or "")
        if not running_id:
            return ""
        run_row = db.execute("SELECT started_at, status FROM trigger_runs WHERE id=?", (running_id,)).fetchone()
        if not run_row:
            db.execute("UPDATE scheduled_triggers SET running_run_id='' WHERE id=?", (row["id"],))
            return ""
        started_at = float(run_row["started_at"] or 0)
        if now - started_at >= self.run_timeout_seconds:
            db.execute(
                "UPDATE trigger_runs SET finished_at=?, status='failed', error='运行超时自动回收', summary='运行超时' WHERE id=?",
                (now, running_id),
            )
            db.execute(
                "UPDATE scheduled_triggers SET running_run_id='', last_outcome='failed', last_error='运行超时自动回收', updated_at=? WHERE id=?",
                (now, row["id"]),
            )
            return ""
        return running_id

    def _record_skipped_overlap(self, db: sqlite3.Connection, row: sqlite3.Row, now: float, *, advance_next: bool) -> dict[str, Any]:
        run_id = f"trun_{secrets.token_hex(8)}"
        summary = "上一轮仍在运行，跳过本次并发重入"
        next_at = row["next_run_at"]
        if advance_next and row["kind"] == "cron" and row["cron_expr"]:
            try:
                next_at = compute_next_run_at(row["cron_expr"], now)
            except ValueError:
                next_at = row["next_run_at"]
        db.execute(
            """
            INSERT INTO trigger_runs (id, trigger_id, started_at, finished_at, status, summary, error, message_id)
            VALUES (?, ?, ?, ?, 'skipped_overlap', ?, '', '')
            """,
            (run_id, row["id"], now, now, summary),
        )
        db.execute(
            """
            UPDATE scheduled_triggers
            SET next_run_at=?, last_outcome='skipped_overlap', last_summary=?, updated_at=?
            WHERE id=?
            """,
            (next_at, summary, now, row["id"]),
        )
        return {
            "run_id": run_id,
            "trigger_id": row["id"],
            "status": "skipped_overlap",
            "summary": summary,
            "error": "",
            "message_id": "",
            "next_run_at": next_at,
        }

    async def _execute_one(self, trigger_id: str, now: float, *, manual: bool) -> dict[str, Any]:
        run_id = f"trun_{secrets.token_hex(8)}"
        with sqlite3.connect(self.path, timeout=20) as db:
            db.row_factory = sqlite3.Row
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM scheduled_triggers WHERE id=?", (trigger_id,)).fetchone()
            if not row:
                db.execute("ROLLBACK")
                raise KeyError(f"触发器不存在: {trigger_id}")
            still_running = self._recover_stale_running_if_needed(db, row, now)
            if still_running:
                overlap = self._record_skipped_overlap(db, row, now, advance_next=not manual)
                db.commit()
                return {**overlap, "trigger": self.get(trigger_id)}

            next_at = row["next_run_at"]
            if not manual and row["kind"] == "cron" and row["cron_expr"]:
                next_at = compute_next_run_at(row["cron_expr"], now)
            elif manual and row["kind"] == "cron" and row["cron_expr"] and (next_at is None or float(next_at) <= now):
                next_at = compute_next_run_at(row["cron_expr"], now)

            db.execute(
                """
                INSERT INTO trigger_runs (id, trigger_id, started_at, finished_at, status, summary, error, message_id)
                VALUES (?, ?, ?, NULL, 'running', '', '', '')
                """,
                (run_id, trigger_id, now),
            )
            db.execute(
                "UPDATE scheduled_triggers SET running_run_id=?, next_run_at=?, updated_at=? WHERE id=?",
                (run_id, next_at, now, trigger_id),
            )
            db.commit()
            trigger_snapshot = self._row_to_dict(row)

        try:
            tpl = trigger_snapshot.get("template") or "custom"
            dream_res: dict[str, Any] | None = None
            if tpl == "morning_briefing":
                summary, msg_id = await self._execute_morning_briefing(trigger_snapshot, now)
            elif tpl == "schedule_subscription_due":
                summary, msg_id = await self._execute_schedule_subscription_due(trigger_snapshot, now, manual=manual)
            elif tpl == "nightly_memory_dream":
                summary, msg_id, dream_res = await self._execute_nightly_memory_dream(trigger_snapshot, now, manual=manual)
            else:
                summary, msg_id = await self._execute_custom(trigger_snapshot, now)
            finished_at = float(self.clock())
            with self.db() as db:
                db.execute(
                    "UPDATE trigger_runs SET finished_at=?, status='succeeded', summary=?, error='', message_id=? WHERE id=?",
                    (finished_at, summary[:500], msg_id, run_id),
                )
                db.execute(
                    """
                    UPDATE scheduled_triggers
                    SET running_run_id='', last_run_at=?, last_outcome='succeeded',
                        last_error='', last_summary=?, run_count=run_count+1, updated_at=?
                    WHERE id=?
                    """,
                    (now, summary[:500], finished_at, trigger_id),
                )
            out = {
                "run_id": run_id,
                "trigger_id": trigger_id,
                "status": "succeeded",
                "summary": summary,
                "error": "",
                "message_id": msg_id,
                "trigger": self.get(trigger_id),
            }
            if dream_res is not None:
                out["dream"] = dream_res
            return out
        except Exception as exc:
            finished_at = float(self.clock())
            err = f"{type(exc).__name__}: {exc}"[:500]
            fail_summary = f"执行失败：{err[:120]}"
            with self.db() as db:
                db.execute(
                    "UPDATE trigger_runs SET finished_at=?, status='failed', summary=?, error=? WHERE id=?",
                    (finished_at, fail_summary, err, run_id),
                )
                db.execute(
                    """
                    UPDATE scheduled_triggers
                    SET running_run_id='', last_run_at=?, last_outcome='failed',
                        last_error=?, last_summary=?, run_count=run_count+1, updated_at=?
                    WHERE id=?
                    """,
                    (now, err, fail_summary, finished_at, trigger_id),
                )
            return {
                "run_id": run_id,
                "trigger_id": trigger_id,
                "status": "failed",
                "summary": fail_summary,
                "error": err,
                "message_id": "",
                "trigger": self.get(trigger_id),
            }

    async def _run_builtin_nightly_dream(self, now: float, *, manual: bool) -> dict[str, Any]:
        preset_id = NIGHTLY_DREAM_SPEC["preset_trigger_id"]
        run_id = f"trun_{secrets.token_hex(8)}"
        meta_key = "builtin_routine:nightly_memory_dream"
        with self.db() as db:
            meta_row = db.execute("SELECT value FROM trigger_meta WHERE key=?", (meta_key,)).fetchone()
            state_obj: dict[str, Any] = json.loads(meta_row[0]) if meta_row else {}
            expr = str(state_obj.get("cron_expr") or NIGHTLY_DREAM_SPEC["default_cron_expr"])
            next_at = compute_next_run_at(expr, now)
            db.execute(
                "INSERT INTO trigger_runs (id, trigger_id, started_at, finished_at, status, summary, error, message_id) VALUES (?, ?, ?, NULL, 'running', '', '', '')",
                (run_id, preset_id, now),
            )
        try:
            summary, msg_id, dream_res = await self._execute_nightly_memory_dream(NIGHTLY_DREAM_SPEC, now, manual=manual)
            finished_at = float(self.clock())
            state_obj.update(
                {
                    "id": preset_id,
                    "template": "nightly_memory_dream",
                    "cron_expr": expr,
                    "status": state_obj.get("status", "active"),
                    "last_run_at": now,
                    "next_run_at": next_at,
                    "last_summary": summary[:500],
                    "run_count": int(state_obj.get("run_count", 0)) + 1,
                }
            )
            with self.db() as db:
                db.execute(
                    "UPDATE trigger_runs SET finished_at=?, status='succeeded', summary=?, error='', message_id=? WHERE id=?",
                    (finished_at, summary[:500], msg_id, run_id),
                )
                db.execute(
                    "INSERT OR REPLACE INTO trigger_meta(key, value) VALUES(?, ?)",
                    (meta_key, json.dumps(state_obj, ensure_ascii=False)),
                )
            return {
                "run_id": run_id,
                "trigger_id": preset_id,
                "template": "nightly_memory_dream",
                "status": "succeeded",
                "summary": summary,
                "error": "",
                "message_id": msg_id,
                "dream": dream_res,
                "trigger": {**NIGHTLY_DREAM_SPEC, **state_obj},
            }
        except Exception as exc:
            finished_at = float(self.clock())
            err = f"{type(exc).__name__}: {exc}"[:500]
            fail_summary = f"执行失败：{err[:120]}"
            state_obj.update({"last_run_at": now, "next_run_at": next_at, "last_error": err, "last_summary": fail_summary})
            with self.db() as db:
                db.execute(
                    "UPDATE trigger_runs SET finished_at=?, status='failed', summary=?, error=? WHERE id=?",
                    (finished_at, fail_summary, err, run_id),
                )
                db.execute(
                    "INSERT OR REPLACE INTO trigger_meta(key, value) VALUES(?, ?)",
                    (meta_key, json.dumps(state_obj, ensure_ascii=False)),
                )
            return {
                "run_id": run_id,
                "trigger_id": preset_id,
                "template": "nightly_memory_dream",
                "status": "failed",
                "summary": fail_summary,
                "error": err,
                "message_id": "",
                "trigger": {**NIGHTLY_DREAM_SPEC, **state_obj},
            }

    async def run_now(self, trigger_id: str) -> dict[str, Any]:
        """手动立即触发一次（无论 triggers 总开关是否打开、或该项是否处于 paused，均可用于验证全链路）。"""
        now = float(self.clock())
        if trigger_id in ("nightly_memory_dream", NIGHTLY_DREAM_SPEC["preset_trigger_id"]):
            with self.db() as db:
                has_row = db.execute(
                    "SELECT id FROM scheduled_triggers WHERE id=? OR template='nightly_memory_dream' LIMIT 1",
                    (NIGHTLY_DREAM_SPEC["preset_trigger_id"],),
                ).fetchone()
            if has_row:
                return await self._execute_one(str(has_row["id"]), now, manual=True)
            return await self._run_builtin_nightly_dream(now, manual=True)
        return await self._execute_one(trigger_id, now, manual=True)

    async def tick(self, now: float | None = None) -> list[dict[str, Any]]:
        """扫描所有到期 active cron 触发器（及内置 `nightly_memory_dream` 03:30 例程）并逐个安全执行，绝不抛出未捕获异常。"""
        moment = float(self.clock() if now is None else now)
        has_explicit_dream = False
        builtin_dream_due = False
        try:
            with self.db() as db:
                due_rows = db.execute(
                    """
                    SELECT id FROM scheduled_triggers
                    WHERE status='active' AND kind='cron' AND next_run_at IS NOT NULL AND next_run_at <= ?
                    ORDER BY next_run_at ASC, id ASC
                    """,
                    (moment,),
                ).fetchall()
                has_explicit_dream = bool(
                    db.execute(
                        "SELECT 1 FROM scheduled_triggers WHERE template='nightly_memory_dream' LIMIT 1"
                    ).fetchone()
                )
                if not has_explicit_dream:
                    meta_row = db.execute(
                        "SELECT value FROM trigger_meta WHERE key='builtin_routine:nightly_memory_dream'"
                    ).fetchone()
                    if meta_row:
                        try:
                            st_obj = json.loads(meta_row[0])
                            if st_obj.get("status", "active") == "active" and st_obj.get("next_run_at") is not None:
                                builtin_dream_due = float(st_obj["next_run_at"]) <= moment
                        except (ValueError, TypeError):
                            builtin_dream_due = False
        except Exception:
            return []

        results: list[dict[str, Any]] = []
        for r in due_rows:
            try:
                res = await self._execute_one(str(r["id"]), moment, manual=False)
                results.append(res)
            except Exception:
                continue
        if builtin_dream_due and not has_explicit_dream:
            try:
                results.append(await self._run_builtin_nightly_dream(moment, manual=False))
            except Exception:
                pass
        return results

    async def dispatch_action(self, action: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        """统一工具与 REST 动作分发入口。"""
        data = dict(payload or {})
        act = (action or data.get("action") or "").strip()
        if act == "list":
            items = self.list(
                status=str(data.get("status") or ""),
                channel=str(data.get("channel") or ""),
            )
            return {
                "items": items,
                "count": len(items),
                "templates": self.templates(),
                "recent_runs": self.recent_runs(str(data.get("trigger_id") or ""), limit=int(data.get("limit") or 20)),
            }
        if act == "create":
            created = self.create(
                name=str(data.get("name") or ""),
                template=str(data.get("template") or "custom"),
                kind=str(data.get("kind") or "cron"),
                cron_expr=str(data.get("cron_expr") or ""),
                prompt=str(data.get("prompt") or ""),
                channel=str(data.get("channel") or "personal"),
                status=str(data.get("status") or "active"),
                event_source=str(data.get("event_source") or ""),
                event_filter=data.get("event_filter") if isinstance(data.get("event_filter"), dict) else None,
            )
            return {"status": "created", "trigger": created}
        tid = str(data.get("trigger_id") or data.get("id") or "").strip()
        if not tid:
            raise ValueError(f"动作 {act!r} 需要提供 trigger_id")
        if act == "update":
            updated = self.update(
                tid,
                name=data.get("name") if "name" in data and data.get("name") != "" else None,
                cron_expr=data.get("cron_expr") if "cron_expr" in data and data.get("cron_expr") != "" else None,
                prompt=data.get("prompt") if "prompt" in data and data.get("prompt") != "" else None,
                channel=data.get("channel") if "channel" in data and data.get("channel") != "" else None,
                status=data.get("status") if "status" in data and data.get("status") != "" else None,
                template=data.get("template") if "template" in data and data.get("template") != "" else None,
                kind=data.get("kind") if "kind" in data and data.get("kind") != "" else None,
                event_source=data.get("event_source") if "event_source" in data else None,
                event_filter=data.get("event_filter") if isinstance(data.get("event_filter"), dict) else None,
            )
            return {"status": "updated", "trigger": updated}
        if act == "pause":
            return {"status": "paused", "trigger": self.pause(tid)}
        if act == "resume":
            return {"status": "active", "trigger": self.resume(tid)}
        if act == "delete":
            return self.delete(tid)
        if act == "run_now":
            return await self.run_now(tid)
        raise ValueError(f"不支持的触发器动作 {act!r}，可选: create, list, update, pause, resume, delete, run_now")
