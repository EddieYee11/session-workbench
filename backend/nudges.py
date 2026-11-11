"""事件触发的「顺口提醒」（Her 式主动提醒 + 四闸门主动打分分流）。

从已归并的事项（PersonalHub matters / Triggers）里挑选今天与 Eddie 有关、需要他注意的事：
- 快递派送 / 待取件（顺丰 / 京东 / 菜鸟等）
- 1 小时内的日程
- 航班 / 火车出行变动
- 到期提醒与 3 天内订阅续费

四闸门收口流水线（`evaluate_four_gates` / `tick`）：
1. 闸门一 · 幂等去重：同 `key` / `fingerprint` / 未变 `state_token` / 7 天内已提订阅一律拦截；
2. 闸门二 · 同类合并：同批次多件同状态快递、多条出行变动、3 项以上订阅到期合并成单条精炼提醒，不连珠炮刷屏；
3. 闸门三 · 静默顺延：安静时段（默认 23:00–08:00）不打扰，将有效候选暂存 `proactive-nudges.sqlite` 的 `deferred` 表，出静默期后复核补发；
4. 闸门四 · 每日主动上限：按优先级分值排序，生产环境与四闸门模式下严格限制每日主动提醒 `<= 5` 条（兼容旧单测显式 `intensity` 档位校验）。

数据源新鲜度自检：
- 当短信源距今 `> 48h` 未更新，或出行提醒缺少实时 `place`/定位时，绝不在提醒里瞎编位置或路程耗时，而是顺口附一句新鲜度说明。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import time
from contextlib import closing, contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Callable
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Asia/Shanghai")
RULES_PATH = Path(__file__).with_name("nudge_rules.json")
DAILY_MAX = {"quiet": 2, "balanced": 6, "active": 12}
NUDGE_DAILY_MAX = DAILY_MAX
PROACTIVE_HARD_CAP = 5
SMS_STALE_SECONDS = 48 * 3600
LOCATION_STALE_SECONDS = 2 * 3600
DEFER_TTL_SECONDS = 14 * 3600
CALENDAR_SOURCES = ("apple_calendar", "google_calendar", "phone_calendar")
HOLIDAY_KEYWORDS = ("节假日", "中国大陆", "中国节日")
SUBSCRIPTION_DAYS = 3
REMINDER_GRACE_SECONDS = 600
SUBSCRIPTION_LEDGER = "Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian/LifeOS/07_Identity/📅 Subscriptions.md"

KIND_SCORES: dict[str, int] = {
    "travel": 95,
    "schedule": 88,
    "reminder": 85,
    "express:pickup": 78,
    "express:delivering": 72,
    "express": 75,
    "subscription": 65,
}


def parse_subscriptions(text: str) -> list[dict]:
    """Only the 订阅列表 table: name, fee, cycle, next due, status. Other sections are never read."""
    rows = []
    for line in text.split("## 订阅列表", 1)[-1].split("\n## ", 1)[0].splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5 or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", cells[3]):
            continue
        if "✅" not in cells[4]:
            continue
        rows.append({"name": cells[0], "fee": cells[1], "cycle": cells[2], "due": cells[3]})
    return rows


CARRIER_NAMES = ("顺丰", "京东", "菜鸟", "丰巢", "中通", "圆通", "韵达", "申通", "极兔", "EMS", "邮政", "德邦")
TRACKING_RE = re.compile(
    r"(?:单号|运单号|运单|快件)[：:\s]*([A-Za-z0-9]{8,24})\b|\b(SF\d{10,15}|JD[A-Za-z0-9]{10,18}|YT\d{10,15}|ZT\d{10,15})\b",
    re.I,
)
PICKUP_CODE_RE = re.compile(r"(?:取件码|凭(?:取件码|提货码|码)?)[：:\s]*([0-9A-Za-z\-]{4,14})")
COURIER_RE = re.compile(r"(?:快递员|派件员|配送员|骑士)[：:\s]*([\u4e00-\u9fa5]{2,4}(?:师傅|哥|姐)?)")
PHONE_RE = re.compile(r"(?<!\d)(1[3-9]\d{9})(?!\d)")
GOODS_BRACKET_RE = re.compile(r"(?:你购买的|您购买的|商品)?【([^】]{2,18})】")
FLIGHT_TRAIN_RE = re.compile(r"\b([A-Z0-9]{2}\d{3,4}|[GDCTKZ]\d{1,4})\b")


def validate_nudge_rules(data: dict) -> dict:
    if not isinstance(data, dict) or not isinstance(data.get("rules"), list) or not data["rules"]:
        raise ValueError("nudge_rules.json 必须包含非空 rules 列表")
    daily = data.get("daily_max") or {}
    for k in ("quiet", "balanced", "active"):
        if int(daily.get(k, DAILY_MAX[k])) < 1:
            raise ValueError(f"daily_max.{k} 必须 >= 1")
    for rule in data["rules"]:
        if not isinstance(rule, dict) or rule.get("kind") not in ("express", "schedule", "travel"):
            raise ValueError(f"未知提醒规则类型: {rule}")
        for pat_key in ("carrier_pattern", "delivering_pattern", "pickup_pattern", "status_pattern", "change_pattern"):
            if pat_key in rule:
                re.compile(rule[pat_key])
    return data


class NudgeRules:
    def __init__(self, path: Path = RULES_PATH):
        self.path = Path(path)
        self.stamp: int | None = None
        self.data: dict | None = None
        self.error: str = ""
        self.refresh()
        if self.data is None:
            raise ValueError(f"顺口提醒规则表不可用：{self.error}")

    def refresh(self) -> dict:
        try:
            stamp = self.path.stat().st_mtime_ns
            if stamp != self.stamp:
                self.stamp = stamp
                self.data = validate_nudge_rules(json.loads(self.path.read_text("utf-8")))
                self.error = ""
        except (OSError, ValueError, TypeError, re.error) as exc:
            self.error = f"{type(exc).__name__}: {exc}"[:300]
        return self.data or {"daily_max": DAILY_MAX, "rules": []}

    def daily_max(self) -> dict[str, int]:
        raw = self.refresh().get("daily_max") or {}
        return {k: int(raw.get(k, v)) for k, v in DAILY_MAX.items()}

    def rule_of(self, kind: str) -> dict:
        for r in self.refresh().get("rules", []):
            if r.get("kind") == kind:
                return r
        return {}


def _instant(value: Any) -> float | None:
    if isinstance(value, dict):
        value = value.get("dateTime", value.get("date"))
    if not isinstance(value, str) or "T" not in value:
        return None
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (moment.replace(tzinfo=TZ) if moment.tzinfo is None else moment).timestamp()


def _clip_conclusion(text: str, limit: int = 40) -> str:
    text = re.sub(r"\s+", " ", (text or "").strip())
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip("，。；、 ") + "。"


def _clean_item_name(title: str, text: str) -> str:
    """尽量提炼快递物品名或快递品牌，避免把【顺丰速运】签名当商品名。"""
    for m in GOODS_BRACKET_RE.finditer(f"{title} {text}"):
        cand = m.group(1).strip()
        if not any(c in cand for c in CARRIER_NAMES) and not any(
            x in cand for x in ("速运", "快递", "物流", "驿站", "通知", "提醒")
        ):
            return cand[:14]
    cleaned_title = re.sub(r"^(\s*【[^】]+】\s*)+", "", (title or "").strip())
    if cleaned_title and cleaned_title not in ("短信", "邮件") and not cleaned_title.startswith(("短信 ·", "微信 ·")):
        for kw in ("正在派送", "派送中", "在派送", "待取件", "已到件", "已放入", "快件", "包裹", "物流"):
            cleaned_title = cleaned_title.replace(kw, "")
        cleaned_title = cleaned_title.strip(" ：:-—，。")
        if 2 <= len(cleaned_title) <= 14 and not any(c == cleaned_title for c in CARRIER_NAMES):
            return cleaned_title
    carrier = next((c for c in CARRIER_NAMES if c in f"{title} {text}"), "")
    return f"{carrier}快递" if carrier else "你的快递"


def _extract_express_raw(text: str) -> str:
    parts = []
    carrier = next((c for c in CARRIER_NAMES if c in text), "")
    if carrier:
        parts.append(carrier)
    code_m = PICKUP_CODE_RE.search(text)
    if code_m:
        parts.append(f"取件码 {code_m.group(1)}")
    track_m = TRACKING_RE.search(text)
    if track_m:
        tn = track_m.group(1) or track_m.group(2)
        parts.append(f"单号 {tn}")
    courier_m = COURIER_RE.search(text)
    if courier_m:
        parts.append(f"快递员 {courier_m.group(1)}")
    phone_m = PHONE_RE.search(text)
    if phone_m:
        parts.append(phone_m.group(1))
    snippet = re.sub(r"\s+", " ", text.strip())
    if parts:
        raw_head = " · ".join(parts)
        if len(snippet) <= 90:
            return snippet
        return f"{raw_head}\n{snippet[:90]}"
    return snippet[:90]


def _iter_matter_units(matter: dict) -> list[dict]:
    """把聚合型事项（sms.messages / wechat.chats）或单条事项拆成可匹配的单元，保留原 matter id。"""
    mid = str(matter.get("id") or matter.get("matter_id") or "")
    source = str(matter.get("source") or "")
    title = str(matter.get("title") or "")
    facts = matter.get("facts") if isinstance(matter.get("facts"), dict) else {}
    if not mid and source and matter.get("source_id"):
        mid = "matter_" + hashlib.sha256(f"{source}:{matter['source_id']}".encode()).hexdigest()[:24]

    if source == "sms" and isinstance(facts.get("messages"), list):
        units = []
        for idx, msg in enumerate(facts["messages"]):
            if not isinstance(msg, dict):
                continue
            txt = str(msg.get("text") or "").strip()
            if not txt:
                continue
            units.append(
                {
                    "matter_id": mid or f"sms:{msg.get('id', idx)}",
                    "unit_id": str(msg.get("id") or f"{mid}:{idx}"),
                    "source": source,
                    "title": "",
                    "text": txt,
                    "actor": str(msg.get("from") or ""),
                    "facts": msg,
                    "matter": matter,
                }
            )
        if units:
            return units

    if source in ("wechat", "wechat_digest") and isinstance(facts.get("chats"), list):
        units = []
        for idx, chat in enumerate(facts["chats"]):
            if not isinstance(chat, dict):
                continue
            name = str(chat.get("name") or "")
            summary = str(chat.get("summary") or "")
            msgs = chat.get("messages") if isinstance(chat.get("messages"), list) else []
            combined = " ".join(str(m.get("text") or "") for m in msgs if isinstance(m, dict)).strip() or summary
            if not combined:
                continue
            units.append(
                {
                    "matter_id": mid or f"wechat:{chat.get('username', idx)}",
                    "unit_id": f"{mid}:{chat.get('username') or name or idx}",
                    "source": source,
                    "title": name,
                    "text": combined,
                    "actor": str(chat.get("sender") or name),
                    "facts": chat,
                    "matter": matter,
                }
            )
        if units:
            return units

    snippet = str(facts.get("snippet") or facts.get("body") or facts.get("notes") or facts.get("description") or "")
    if not snippet and isinstance(matter.get("summary"), str):
        snippet = matter["summary"]
    text = f"{title} {snippet}".strip()
    return [
        {
            "matter_id": mid or f"{source}:{matter.get('source_id', title)}",
            "unit_id": mid or f"{source}:{matter.get('source_id', title)}",
            "source": source,
            "title": title,
            "text": text,
            "actor": str(facts.get("from") or matter.get("actor") or ""),
            "facts": facts,
            "matter": matter,
        }
    ]


def score_candidate(cand: dict[str, Any]) -> int:
    """为候选提醒计算确定性优先级分值，供四闸门在配额受限时择优放行。"""
    if "score" in cand and isinstance(cand["score"], (int, float)):
        return int(cand["score"])
    kind = str(cand.get("kind") or "")
    state_token = str(cand.get("state_token") or "")
    compound = f"{kind}:{state_token}"
    if compound in KIND_SCORES:
        return KIND_SCORES[compound]
    return KIND_SCORES.get(kind, 60)


class Nudges:
    """事件触发的顺口提醒：快递派送/待取件、1小时内日程、航班火车变动，内置四闸门与新鲜度自检。"""

    def __init__(
        self,
        state: Path | str,
        conversation: Any,
        settings: Callable[[], dict],
        hub: Any = None,
        triggers: Any = None,
        notifications: Any = None,
        reminders: Any = None,
        ledger: Path | str | None = None,
        rules: NudgeRules | None = None,
        clock: Callable[[], float] = time.time,
        *,
        hard_daily_cap: int | None = None,
    ):
        self.state = Path(state)
        self.state.mkdir(parents=True, exist_ok=True)
        self.path = self.state / "proactive-nudges.sqlite"
        self.conversation = conversation
        self.settings = settings
        self.hub = hub
        self.triggers = triggers
        self.notifications = notifications
        self.reminders = reminders
        self.ledger = Path(ledger) if ledger else Path.home() / SUBSCRIPTION_LEDGER
        self.rules = rules or NudgeRules()
        self.clock = clock
        self.hard_daily_cap = hard_daily_cap
        with self.db() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute(
                "CREATE TABLE IF NOT EXISTS sent("
                "key TEXT PRIMARY KEY, day TEXT, kind TEXT, subject TEXT, at REAL, "
                "matter_id TEXT DEFAULT '', state_token TEXT DEFAULT '', fingerprint TEXT DEFAULT '')"
            )
            cols = {r[1] for r in db.execute("PRAGMA table_info(sent)")}
            for col in ("matter_id", "state_token", "fingerprint"):
                if col not in cols:
                    db.execute(f"ALTER TABLE sent ADD COLUMN {col} TEXT DEFAULT ''")
            db.execute(
                "CREATE TABLE IF NOT EXISTS deferred("
                "key TEXT PRIMARY KEY, day TEXT, kind TEXT, subject TEXT, "
                "deferred_at REAL, expires_at REAL, payload TEXT NOT NULL)"
            )
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=20)
        try:
            with db:
                yield db
        finally:
            db.close()

    def _raw_matters(self) -> list[dict]:
        rows: list[dict] = []
        seen_ids: set[str] = set()
        if self.hub is not None and hasattr(self.hub, "matters"):
            for m in self.hub.matters() or []:
                if not isinstance(m, dict):
                    continue
                if (m.get("feedback") or {}).get("action") in ("handled", "mute"):
                    continue
                mid = str(m.get("id") or "")
                if mid:
                    seen_ids.add(mid)
                rows.append(m)
        if self.triggers is not None and hasattr(self.triggers, "items"):
            for t in self.triggers.items(limit=60) or []:
                if not isinstance(t, dict) or t.get("disposition") == "filtered":
                    continue
                mid = str(t.get("matter_id") or t.get("id") or "")
                if mid and mid in seen_ids:
                    continue
                try:
                    facts = json.loads(t.get("summary") or "{}")
                    if not isinstance(facts, dict):
                        facts = {"snippet": str(t.get("summary") or "")}
                except ValueError:
                    facts = {"snippet": str(t.get("summary") or "")}
                rows.append(
                    {
                        "id": mid or str(t.get("id") or ""),
                        "source": t.get("source", ""),
                        "source_id": t.get("thread_key", ""),
                        "title": t.get("title", ""),
                        "facts": facts,
                        "feedback": {},
                    }
                )
        return rows

    def source_freshness(self, now: float | None = None, *, unit: dict | None = None) -> dict[str, Any]:
        """检查短信源是否超 48 小时未更新，以及当前是否具备可用实时 `place`/定位。"""
        moment = float(self.clock() if now is None else now)
        sms_timestamps: list[float] = []
        has_live_location = False
        explicit_place = ""

        # 1. 检查单元/事项自身携带的明确地点或短信时间戳
        if isinstance(unit, dict):
            u_facts = unit.get("facts") if isinstance(unit.get("facts"), dict) else {}
            matter = unit.get("matter") if isinstance(unit.get("matter"), dict) else {}
            m_facts = matter.get("facts") if isinstance(matter.get("facts"), dict) else {}
            for candidate_place in (
                u_facts.get("place"),
                u_facts.get("location"),
                m_facts.get("place"),
                m_facts.get("location"),
                matter.get("place"),
                matter.get("location"),
            ):
                if isinstance(candidate_place, str) and candidate_place.strip():
                    explicit_place = candidate_place.strip()[:40]
                    break
            if unit.get("source") == "sms" or matter.get("source") == "sms":
                for ts_cand in (
                    u_facts.get("at"),
                    u_facts.get("updated_at"),
                    matter.get("source_updated_at"),
                    matter.get("updated_at"),
                ):
                    if isinstance(ts_cand, (int, float)) and float(ts_cand) > 0:
                        sms_timestamps.append(float(ts_cand))

        # 2. 检查 personal-hub.sqlite 的 sources 表与 location 事项新鲜度
        hub_db = self.state / "personal-hub.sqlite"
        if hub_db.is_file():
            try:
                with closing(sqlite3.connect(f"file:{hub_db}?mode=ro", uri=True, timeout=2)) as db:
                    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                    if "sources" in tables:
                        cols = {r[1] for r in db.execute("PRAGMA table_info(sources)")}
                        key_col = "source" if "source" in cols else ("name" if "name" in cols else "")
                        ts_col = "updated_at" if "updated_at" in cols else ("last_sync_at" if "last_sync_at" in cols else "")
                        if key_col and ts_col:
                            s_row = db.execute(f"SELECT {ts_col} FROM sources WHERE {key_col}='sms'").fetchone()
                            if s_row and s_row[0] is not None:
                                sms_timestamps.append(float(s_row[0]))
                            loc_row = db.execute(
                                f"SELECT {ts_col} FROM sources WHERE {key_col} IN ('location', 'phone_location') ORDER BY {ts_col} DESC LIMIT 1"
                            ).fetchone()
                            if loc_row and loc_row[0] is not None and (moment - float(loc_row[0])) <= LOCATION_STALE_SECONDS:
                                has_live_location = True
            except (sqlite3.Error, ValueError, TypeError):
                pass

        # 3. 兜底参考 pending_actions.data_freshness（包含 phone_location.json 等）
        try:
            from pending_actions import data_freshness

            df = data_freshness(self.state, now=moment)
            for item in (df.get("items") or []) if isinstance(df, dict) else []:
                if not isinstance(item, dict):
                    continue
                src_name = str(item.get("source") or "")
                age = item.get("age_seconds")
                if src_name == "sms" and isinstance(age, (int, float)):
                    sms_timestamps.append(moment - float(age))
                if src_name in ("location", "phone_location") and item.get("stale") is False:
                    has_live_location = True
        except Exception:
            pass

        # 4. 检查内存 hub matters 里的 location 源
        if not has_live_location and not explicit_place:
            for m in self._raw_matters():
                if str(m.get("source") or "") in ("location", "phone_location"):
                    m_facts = m.get("facts") if isinstance(m.get("facts"), dict) else {}
                    pl = str(m_facts.get("place") or m_facts.get("address") or m.get("title") or "").strip()
                    ts_val = m.get("source_updated_at") or m.get("updated_at") or m_facts.get("at")
                    if pl and (ts_val is None or (moment - float(ts_val)) <= LOCATION_STALE_SECONDS):
                        has_live_location = True
                        explicit_place = pl[:40]
                        break

        sms_age_seconds: float | None = None
        sms_stale = False
        if sms_timestamps:
            latest_sms = max(sms_timestamps)
            sms_age_seconds = max(0.0, moment - latest_sms)
            sms_stale = sms_age_seconds > SMS_STALE_SECONDS

        place_missing = not bool(explicit_place or has_live_location)
        sms_age_hours = int(round((sms_age_seconds or 0.0) / 3600.0)) if sms_age_seconds is not None else None
        return {
            "sms_stale": sms_stale,
            "sms_age_seconds": sms_age_seconds,
            "sms_age_hours": sms_age_hours,
            "place": explicit_place,
            "place_missing": place_missing,
        }

    @staticmethod
    def _format_freshness_note(
        fresh: dict[str, Any],
        *,
        is_sms_source: bool,
        need_place: bool,
    ) -> str:
        sms_stale = bool(is_sms_source and fresh.get("sms_stale"))
        place_missing = bool(need_place and fresh.get("place_missing"))
        hours = max(48, int(fresh.get("sms_age_hours") or 49))
        if sms_stale and place_missing:
            return f"（顺带说明：短信源距今已超 {hours} 小时未更新，且当前缺少实时定位，未估算路程）"
        if sms_stale:
            return f"（顺带说明：短信源距今已超 {hours} 小时未更新，请留意最新状态）"
        if place_missing:
            return "（顺带说明：当前缺少实时定位，暂不估算出发路程）"
        return ""

    def express_candidates(self, now: float) -> list[dict]:
        rule = self.rules.rule_of("express")
        if not rule:
            return []
        carrier_re = re.compile(rule.get("carrier_pattern", "顺丰|京东|菜鸟|快递|驿站|丰巢"), re.I)
        delivering_re = re.compile(rule.get("delivering_pattern", "派送中|正在派送|在派送|派件中|配送中"), re.I)
        pickup_re = re.compile(rule.get("pickup_pattern", "待取|取件码|已放入|已投递|已到.*?驿站|已到.*?柜|到件"), re.I)
        allowed_sources = set(rule.get("sources") or ("sms", "wechat", "gmail", "work_mail"))

        out: list[dict] = []
        for matter in self._raw_matters():
            if matter.get("source") and matter.get("source") not in allowed_sources:
                continue
            for unit in _iter_matter_units(matter):
                blob = f"{unit['title']} {unit['text']} {unit['actor']}"
                is_delivering = bool(delivering_re.search(blob))
                is_pickup = bool(pickup_re.search(blob))
                if not (is_delivering or is_pickup):
                    continue
                if not (carrier_re.search(blob) or PICKUP_CODE_RE.search(blob) or TRACKING_RE.search(blob)):
                    continue
                state_token = "pickup" if is_pickup else "delivering"
                item_name = _clean_item_name(unit["title"], unit["text"])
                if state_token == "delivering":
                    conclusion = _clip_conclusion(f"{item_name}在派送了，今天注意收一下。", 40)
                else:
                    code_m = PICKUP_CODE_RE.search(blob)
                    code_part = f"（取件码 {code_m.group(1)}）" if code_m else ""
                    conclusion = _clip_conclusion(f"{item_name}到了{code_part}，记得去取。", 40)
                raw_info = _extract_express_raw(unit["text"] or unit["title"])
                fresh = self.source_freshness(now, unit=unit)
                fresh_note = self._format_freshness_note(
                    fresh,
                    is_sms_source=(unit.get("source") == "sms"),
                    need_place=False,
                )
                detail_lines = [p for p in (raw_info if raw_info != conclusion else "", fresh_note) if p]
                text = f"{conclusion}\n" + "\n".join(detail_lines) if detail_lines else conclusion

                track_m = TRACKING_RE.search(blob)
                code_m = PICKUP_CODE_RE.search(blob)
                entity_key = (
                    (track_m.group(1) or track_m.group(2))
                    if track_m
                    else code_m.group(1)
                    if code_m
                    else item_name
                )
                fp = hashlib.sha256(f"express|{entity_key}|{state_token}".encode("utf-8")).hexdigest()[:24]
                cand = {
                    "key": f"express:{fp}",
                    "kind": "express",
                    "subject": f"express:{entity_key}",
                    "state_token": state_token,
                    "fingerprint": fp,
                    "matter_id": unit["matter_id"],
                    "conclusion": conclusion,
                    "text": text,
                }
                cand["score"] = score_candidate(cand)
                out.append(cand)
        return out

    def schedule_candidates(self, now: float) -> list[dict]:
        rule = self.rules.rule_of("schedule")
        window_minutes = int(rule.get("window_minutes") or self.rules.refresh().get("schedule_window_minutes") or 60)
        allowed_sources = set(rule.get("sources") or CALENDAR_SOURCES)
        out: list[dict] = []
        seen_subjects: set[str] = set()

        for matter in self._raw_matters():
            if matter.get("source") not in allowed_sources:
                continue
            facts = matter.get("facts") if isinstance(matter.get("facts"), dict) else {}
            if facts.get("all_day") or facts.get("availability") == 1:
                continue
            cal_name = str(facts.get("calendar", "")) + str(facts.get("calendar_displayName", ""))
            if any(k in cal_name for k in HOLIDAY_KEYWORDS):
                continue
            start = _instant(facts.get("start") or matter.get("deadline"))
            if start is None or not (now < start <= now + window_minutes * 60):
                continue
            raw_title = str(matter.get("title") or facts.get("title") or facts.get("summary") or "日程").strip()[:60]
            title = raw_title[:24]
            start_min = int(start // 60)
            legacy_subject = f"{raw_title}@{int(start)}"
            legacy_key = "calendar:" + hashlib.sha256(legacy_subject.encode("utf-8")).hexdigest()[:24]
            subject = f"schedule:{title}"
            dedup_token = f"{title}@{start_min}"
            if dedup_token in seen_subjects or legacy_subject in seen_subjects:
                continue
            seen_subjects.add(dedup_token)
            seen_subjects.add(legacy_subject)

            minutes = max(1, round((start - now) / 60))
            hhmm = datetime.fromtimestamp(start, TZ).strftime("%H:%M")
            place = str(facts.get("location") or "").strip()[:30]
            conclusion = _clip_conclusion(f"{hhmm}「{title}」还有 {minutes} 分钟开始。", 40)
            raw_parts = [f"时间：{hhmm}"]
            if place:
                raw_parts.append(f"地点：{place}")
            text = f"{conclusion}\n{' · '.join(raw_parts)}"
            mid = str(matter.get("id") or f"calendar:{title}:{start_min}")
            fp = hashlib.sha256(f"schedule|{title}|{start_min}".encode("utf-8")).hexdigest()[:24]
            cand = {
                "key": legacy_key,
                "legacy_key": f"schedule:{fp}",
                "kind": "schedule",
                "subject": subject,
                "state_token": str(start_min),
                "fingerprint": fp,
                "matter_id": mid,
                "conclusion": conclusion,
                "text": text,
            }
            cand["score"] = score_candidate(cand)
            out.append(cand)
        return out

    def travel_candidates(self, now: float) -> list[dict]:
        rule = self.rules.rule_of("travel")
        if not rule:
            return []
        carrier_re = re.compile(
            rule.get("carrier_pattern", "航班|飞机|机票|高铁|动车|火车|列车|12306|登机口|检票口"),
            re.I,
        )
        change_re = re.compile(
            rule.get("change_pattern", "延误|取消|改签|变更|调整|提前|推迟|晚点|停运|改到|改为"),
            re.I,
        )
        allowed_sources = set(rule.get("sources") or ("sms", "wechat", "gmail", "work_mail", *CALENDAR_SOURCES))

        out: list[dict] = []
        for matter in self._raw_matters():
            if matter.get("source") and matter.get("source") not in allowed_sources:
                continue
            for unit in _iter_matter_units(matter):
                blob = f"{unit['title']} {unit['text']} {unit['actor']}"
                if not (carrier_re.search(blob) and change_re.search(blob)):
                    continue
                change_m = change_re.search(blob)
                change_word = change_m.group(0) if change_m else "变动"
                no_m = FLIGHT_TRAIN_RE.search(blob)
                trip_no = no_m.group(1) if no_m else ""
                label = f"{trip_no} " if trip_no else "你的出行"
                conclusion = _clip_conclusion(f"{label}有{change_word}，留意最新时间。", 40)
                raw_info = re.sub(r"\s+", " ", (unit["text"] or unit["title"]).strip())[:90]

                # 新鲜度与定位自检：绝不瞎编出发地或路程时间
                fresh = self.source_freshness(now, unit=unit)
                fresh_note = self._format_freshness_note(
                    fresh,
                    is_sms_source=(unit.get("source") == "sms"),
                    need_place=True,
                )
                detail_parts: list[str] = []
                if raw_info and raw_info != conclusion:
                    detail_parts.append(raw_info)
                if fresh.get("place") and not fresh.get("place_missing"):
                    detail_parts.append(f"当前位置参考：{fresh['place']}")
                if fresh_note:
                    detail_parts.append(fresh_note)
                text = f"{conclusion}\n" + "\n".join(detail_parts) if detail_parts else conclusion

                state_token = hashlib.sha256(f"{change_word}|{raw_info[:48]}".encode("utf-8")).hexdigest()[:16]
                subject = f"travel:{trip_no or unit['matter_id']}"
                fp = hashlib.sha256(f"travel|{subject}|{state_token}".encode("utf-8")).hexdigest()[:24]
                cand = {
                    "key": f"travel:{fp}",
                    "kind": "travel",
                    "subject": subject,
                    "state_token": state_token,
                    "fingerprint": fp,
                    "matter_id": unit["matter_id"],
                    "conclusion": conclusion,
                    "text": text,
                    "freshness": fresh,
                }
                cand["score"] = score_candidate(cand)
                out.append(cand)
        return out

    def due_reminders(self, now: float) -> list[dict]:
        if self.reminders is None:
            return []
        try:
            items = self.reminders.list()
        except ValueError:
            return []
        rows: list[dict] = []
        for item in items:
            if item.get("status") != "pending" or not item.get("due"):
                continue
            try:
                due = datetime.strptime(item["due"], "%Y-%m-%d %H:%M").replace(tzinfo=TZ).timestamp()
            except (TypeError, ValueError):
                continue
            if not (due <= now < due + REMINDER_GRACE_SECONDS):
                continue
            text = str(item.get("text") or "").strip()
            if not text:
                continue
            key = f"reminder:{item['id']}:{item['due']}"
            full_text = f"提醒：{text[:300]}"
            fp = hashlib.sha256(f"{key}|{full_text}".encode("utf-8")).hexdigest()[:24]
            cand = {
                "key": key,
                "kind": "reminder",
                "subject": text[:40],
                "state_token": key,
                "fingerprint": fp,
                "matter_id": f"reminder:{item['id']}",
                "conclusion": _clip_conclusion(full_text, 40),
                "text": full_text,
            }
            cand["score"] = score_candidate(cand)
            rows.append(cand)
        return rows

    def subscriptions(self, now: float) -> list[dict]:
        try:
            text = self.ledger.read_text("utf-8")
        except (OSError, UnicodeError):
            return []
        today = datetime.fromtimestamp(now, TZ).date()
        rows: list[dict] = []
        for sub in parse_subscriptions(text):
            try:
                due = datetime.strptime(sub["due"], "%Y-%m-%d").date()
            except ValueError:
                continue
            days = (due - today).days
            if not (0 <= days <= SUBSCRIPTION_DAYS):
                continue
            when = (
                "今天到期"
                if days == 0
                else "明天到期"
                if days == 1
                else f"{due.month}月{due.day}日到期，还有 {days} 天"
            )
            text_ = f"{sub['name']}（{sub['fee']}/{sub['cycle']}）{when}，续不续定一下？"
            key = f"subscription:{sub['name']}:{sub['due']}"
            fp = hashlib.sha256(f"{key}|{text_}".encode("utf-8")).hexdigest()[:24]
            cand = {
                "key": key,
                "kind": "subscription",
                "subject": sub["name"],
                "state_token": sub["due"],
                "fingerprint": fp,
                "matter_id": key,
                "conclusion": _clip_conclusion(text_, 40),
                "text": text_,
            }
            cand["score"] = score_candidate(cand)
            rows.append(cand)
        return rows

    def candidates(self, now: float | None = None) -> list[dict]:
        moment = self.clock() if now is None else now
        rows: list[dict] = []
        for fn in (
            self.express_candidates,
            self.schedule_candidates,
            self.travel_candidates,
            self.due_reminders,
            self.subscriptions,
        ):
            try:
                rows.extend(fn(moment))
            except Exception:
                continue
        return rows

    def _normalize_candidate(self, item: dict | tuple) -> dict:
        if isinstance(item, dict):
            norm = dict(item)
            norm.setdefault("state_token", str(norm.get("key") or ""))
            norm.setdefault(
                "fingerprint",
                hashlib.sha256(f"{norm.get('key')}|{norm.get('text')}".encode("utf-8")).hexdigest()[:24],
            )
            norm.setdefault("matter_id", str(norm.get("key") or ""))
            norm.setdefault("conclusion", _clip_conclusion((norm.get("text") or "").splitlines()[0], 40))
            norm["score"] = score_candidate(norm)
            return norm
        key, kind, subject, text = item[:4]
        conclusion = text.splitlines()[0] if text else ""
        norm = {
            "key": str(key),
            "kind": str(kind),
            "subject": str(subject),
            "state_token": str(key),
            "fingerprint": hashlib.sha256(f"{key}|{text}".encode("utf-8")).hexdigest()[:24],
            "matter_id": str(item[4]) if len(item) > 4 else str(key),
            "conclusion": _clip_conclusion(conclusion, 40),
            "text": str(text),
        }
        norm["score"] = score_candidate(norm)
        return norm

    def _record_message_metadata(self, receipt_key: str, candidate: dict) -> None:
        if not hasattr(self.conversation, "db"):
            return
        msg_key = f"task-result:{receipt_key}"
        meta_payload = {
            "kind": "nudge",
            "nudge_kind": candidate.get("kind", "nudge"),
            "source_matter_id": candidate.get("matter_id", ""),
            "matter_id": candidate.get("matter_id", ""),
            "fingerprint": candidate.get("fingerprint", ""),
            "state_token": candidate.get("state_token", ""),
            "score": score_candidate(candidate),
            "coalesced_count": int(candidate.get("coalesced_count", 1)),
        }
        try:
            with self.conversation.db() as db:
                db.execute(
                    "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)",
                    (f"message-metadata:{msg_key}", json.dumps(meta_payload, ensure_ascii=False)),
                )
        except Exception:
            pass

    def message_metadata(self, message_id_or_key: str) -> dict | None:
        if not hasattr(self.conversation, "db"):
            return None
        key = message_id_or_key if message_id_or_key.startswith("task-result:") else f"task-result:{message_id_or_key}"
        with self.conversation.db() as db:
            row = db.execute("SELECT value FROM meta WHERE key=?", (f"message-metadata:{key}",)).fetchone()
        return json.loads(row[0]) if row else None

    def _is_sent_or_duplicate(self, db: sqlite3.Connection, cand: dict, now: float) -> bool:
        key = cand["key"]
        alt_key = cand.get("legacy_key") or key
        kind = cand["kind"]
        subject = cand["subject"]
        state_token = cand.get("state_token", "")
        fp = cand.get("fingerprint", "")

        if db.execute(
            "SELECT 1 FROM sent WHERE key IN (?, ?) OR (fingerprint<>'' AND fingerprint=?)",
            (key, alt_key, fp),
        ).fetchone():
            return True
        if kind == "subscription" and db.execute(
            "SELECT 1 FROM sent WHERE (subject=? OR instr(subject,?)>0) AND at>?",
            (subject, subject, now - 7 * 86400),
        ).fetchone():
            return True
        prior = db.execute(
            "SELECT state_token FROM sent WHERE subject=? ORDER BY at DESC LIMIT 1",
            (subject,),
        ).fetchone()
        if prior and state_token and prior[0] == state_token:
            return True
        return False

    @staticmethod
    def coalesce_same_kind(items: list[dict], *, aggressive: bool = False) -> tuple[list[dict], list[dict]]:
        """闸门二：合并同批次同类噪音提醒，保留底层 `members` 以确保幂等账本完整落库。"""
        if len(items) <= 1:
            return list(items), []

        buckets: dict[str, list[tuple[int, dict]]] = {}
        passthrough: list[tuple[int, dict]] = []

        for idx, cand in enumerate(items):
            kind = str(cand.get("kind") or "")
            state_tok = str(cand.get("state_token") or "")
            if kind == "express":
                b_key = f"express:{state_tok}"
                buckets.setdefault(b_key, []).append((idx, cand))
            elif kind == "travel":
                buckets.setdefault("travel:batch", []).append((idx, cand))
            elif kind == "subscription":
                buckets.setdefault("subscription:batch", []).append((idx, cand))
            elif aggressive and kind not in ("schedule", "reminder"):
                buckets.setdefault(f"{kind}:{state_tok}", []).append((idx, cand))
            else:
                passthrough.append((idx, cand))

        ordered_entries: list[tuple[int, dict]] = list(passthrough)
        merged_groups: list[dict] = []

        for b_key, group in buckets.items():
            min_merge = 3 if b_key == "subscription:batch" and not aggressive else 2
            if len(group) < min_merge:
                ordered_entries.extend(group)
                continue

            first_idx, first_cand = group[0]
            members = [c for _, c in group]
            kind = first_cand["kind"]
            max_score = max(score_candidate(c) for c in members)

            if kind == "express":
                is_pickup = first_cand.get("state_token") == "pickup"
                action_desc = "到了，记得一并去取。" if is_pickup else "正在派送，今天注意查收。"
                conclusion = _clip_conclusion(f"你有 {len(members)} 件快递{action_desc}", 40)
                detail_lines = [f"• {m['conclusion']}" for m in members[:5]]
                for m in members[:3]:
                    extra = [ln for ln in m["text"].splitlines()[1:] if ln.strip()]
                    if extra:
                        detail_lines.append(f"  {extra[0]}")
                text = conclusion + "\n" + "\n".join(detail_lines)
            elif kind == "travel":
                conclusion = _clip_conclusion(f"你有 {len(members)} 条出行变动，请留意最新时间。", 40)
                detail_lines = [f"• {m['text'].replace(chr(10), ' ｜ ')}" for m in members[:5]]
                text = conclusion + "\n" + "\n".join(detail_lines)
            elif kind == "subscription":
                conclusion = _clip_conclusion(f"近期有 {len(members)} 项订阅即将到期，确认是否续费。", 40)
                detail_lines = [f"• {m['text']}" for m in members[:5]]
                text = conclusion + "\n" + "\n".join(detail_lines)
            else:
                conclusion = _clip_conclusion(f"你有 {len(members)} 条同类提醒待留意。", 40)
                detail_lines = [f"• {m['conclusion']}" for m in members[:5]]
                text = conclusion + "\n" + "\n".join(detail_lines)

            merged_fp = hashlib.sha256(
                "|".join(sorted(m.get("fingerprint") or m["key"] for m in members)).encode("utf-8")
            ).hexdigest()[:24]
            merged_cand = {
                "key": f"{kind}:merged:{merged_fp}",
                "kind": kind,
                "subject": f"{kind}:merged:{first_cand.get('state_token', '')}",
                "state_token": merged_fp,
                "fingerprint": merged_fp,
                "matter_id": first_cand.get("matter_id", ""),
                "conclusion": conclusion,
                "text": text,
                "score": max_score + 2,
                "coalesced_count": len(members),
                "members": members,
            }
            ordered_entries.append((first_idx, merged_cand))
            merged_groups.append({"bucket": b_key, "count": len(members), "merged_key": merged_cand["key"]})

        ordered_entries.sort(key=lambda pair: pair[0])
        return [c for _, c in ordered_entries], merged_groups

    def _effective_daily_limit(self, cfg: dict[str, Any], *, force_four_gate: bool = False) -> int:
        daily_limits = self.rules.daily_max()
        intensity = str(cfg.get("intensity", "balanced"))
        base_limit = daily_limits.get(intensity, daily_limits["balanced"])

        env_cap = os.environ.get("COM_NUDGE_DAILY_CAP", "").strip()
        if env_cap.isdigit():
            return max(1, min(base_limit, int(env_cap)))
        if self.hard_daily_cap is not None:
            return max(1, min(base_limit, int(self.hard_daily_cap)))
        if "daily_cap" in cfg and cfg["daily_cap"] is not None:
            return max(1, min(base_limit, int(cfg["daily_cap"])))

        bound_owner = getattr(getattr(self.settings, "__self__", None), "__class__", None)
        is_proactive_service = getattr(bound_owner, "__name__", "") == "Proactive"
        use_hard_cap = bool(
            force_four_gate
            or cfg.get("four_gate")
            or is_proactive_service
            or ("intensity" not in cfg)
        )
        if use_hard_cap:
            return min(base_limit, PROACTIVE_HARD_CAP)
        return base_limit

    def _load_valid_deferred(self, now: float) -> list[dict]:
        loaded: list[dict] = []
        with self.db() as db:
            db.execute("DELETE FROM deferred WHERE expires_at < ?", (now,))
            rows = db.execute("SELECT key, payload FROM deferred ORDER BY deferred_at ASC").fetchall()
        for key, raw_payload in rows:
            try:
                obj = json.loads(raw_payload)
                if isinstance(obj, dict) and obj.get("key"):
                    loaded.append(obj)
            except ValueError:
                with self.db() as db:
                    db.execute("DELETE FROM deferred WHERE key=?", (key,))
        return loaded

    def _save_deferred(self, items: list[dict], day: str, now: float) -> None:
        if not items:
            return
        with self.db() as db:
            for cand in items:
                serializable = {k: v for k, v in cand.items() if k != "members"}
                if "members" in cand and isinstance(cand["members"], list):
                    serializable["members"] = [
                        {mk: mv for mk, mv in m.items() if mk != "members"} for m in cand["members"]
                    ]
                db.execute(
                    """
                    INSERT OR REPLACE INTO deferred(key, day, kind, subject, deferred_at, expires_at, payload)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        cand["key"],
                        day,
                        cand["kind"],
                        cand["subject"],
                        now,
                        now + DEFER_TTL_SECONDS,
                        json.dumps(serializable, ensure_ascii=False),
                    ),
                )

    def evaluate_four_gates(
        self,
        candidates: list | None = None,
        *,
        now: float | None = None,
        force_hard_cap: bool = True,
        aggressive_coalesce: bool = False,
    ) -> dict[str, Any]:
        """纯评估四闸门打分分流（幂等 -> 同类合并 -> 静默顺延 -> 每日上限 <=5），返回完整诊断轨迹。"""
        cfg = self.settings() or {}
        moment = float(self.clock() if now is None else now)
        if cfg.get("paused"):
            return {
                "paused": True,
                "quiet": False,
                "daily_limit": 0,
                "passed": [],
                "dropped_idempotent": [],
                "merged_groups": [],
                "deferred_quiet": [],
                "dropped_cap": [],
            }

        local = datetime.fromtimestamp(moment, TZ)
        start, end = int(cfg.get("quiet_start", 23)), int(cfg.get("quiet_end", 8))
        quiet = (local.hour >= start or local.hour < end) if start > end else (start <= local.hour < end)
        day = local.date().isoformat()
        limit = self._effective_daily_limit(cfg, force_four_gate=force_hard_cap)

        raw_pool = self.candidates(moment) if candidates is None else list(candidates)
        if not quiet:
            deferred_pool = self._load_valid_deferred(moment)
            existing_keys = {
                (c.get("key") if isinstance(c, dict) else str(c[0])) for c in raw_pool
            }
            raw_pool = [d for d in deferred_pool if d.get("key") not in existing_keys] + raw_pool

        normalized = [self._normalize_candidate(c) for c in raw_pool]

        # 闸门一：幂等去重（含同批次重复拦截与订阅对提醒去重）
        after_gate1: list[dict] = []
        dropped_idempotent: list[str] = []
        batch_seen_keys: set[str] = set()
        batch_seen_subjects: dict[str, str] = {}
        batch_reminder_subjects: list[str] = []

        with self.db() as db:
            sent_today = int(db.execute("SELECT count(*) FROM sent WHERE day=?", (day,)).fetchone()[0])
            for cand in normalized:
                key = cand["key"]
                fp = cand.get("fingerprint", "")
                subj = cand["subject"]
                st_tok = cand.get("state_token", "")

                if key in batch_seen_keys or (fp and f"fp:{fp}" in batch_seen_keys):
                    dropped_idempotent.append(key)
                    continue
                if st_tok and subj in batch_seen_subjects and batch_seen_subjects[subj] == st_tok:
                    dropped_idempotent.append(key)
                    continue
                if cand["kind"] == "subscription" and any(
                    subj == rs or (subj and subj in rs) for rs in batch_reminder_subjects
                ):
                    dropped_idempotent.append(key)
                    continue
                if self._is_sent_or_duplicate(db, cand, moment):
                    dropped_idempotent.append(key)
                    continue

                batch_seen_keys.add(key)
                if fp:
                    batch_seen_keys.add(f"fp:{fp}")
                batch_seen_subjects[subj] = st_tok
                if cand["kind"] == "reminder":
                    batch_reminder_subjects.append(subj)
                after_gate1.append(cand)

        # 闸门二：同类合并
        after_gate2, merged_groups = self.coalesce_same_kind(after_gate1, aggressive=aggressive_coalesce)

        # 闸门三：静默时段顺延
        if quiet:
            return {
                "paused": False,
                "quiet": True,
                "daily_limit": limit,
                "passed": [],
                "dropped_idempotent": dropped_idempotent,
                "merged_groups": merged_groups,
                "deferred_quiet": after_gate2,
                "dropped_cap": [],
            }

        # 闸门四：按优先级打分排序并执行每日主动上限
        indexed = list(enumerate(after_gate2))
        indexed.sort(key=lambda pair: (-score_candidate(pair[1]), pair[0]))
        remaining = max(0, limit - sent_today)
        chosen_pairs = sorted(indexed[:remaining], key=lambda pair: pair[0])
        dropped_pairs = indexed[remaining:]

        return {
            "paused": False,
            "quiet": False,
            "daily_limit": limit,
            "sent_today_before": sent_today,
            "passed": [c for _, c in chosen_pairs],
            "dropped_idempotent": dropped_idempotent,
            "merged_groups": merged_groups,
            "deferred_quiet": [],
            "dropped_cap": [c["key"] for _, c in dropped_pairs],
        }

    def tick(self, candidates: list | None = None, *, force_four_gate: bool = False) -> int:
        cfg = self.settings() or {}
        if cfg.get("paused"):
            return 0
        now = self.clock()
        local = datetime.fromtimestamp(now, TZ)
        day = local.date().isoformat()

        plan = self.evaluate_four_gates(
            candidates,
            now=now,
            force_hard_cap=force_four_gate,
            aggressive_coalesce=False,
        )
        if plan["quiet"]:
            self._save_deferred(plan["deferred_quiet"], day, now)
            return 0

        sent = 0
        for cand in plan["passed"]:
            key = cand["key"]
            members = cand.get("members") if isinstance(cand.get("members"), list) else [cand]
            with self.db() as db:
                if self._is_sent_or_duplicate(db, cand, now):
                    continue
                receipt_key = f"nudge:{key}"
                self.conversation.task_receipt(receipt_key, cand["text"])
                self._record_message_metadata(receipt_key, cand)
                db.execute(
                    "INSERT OR IGNORE INTO sent(key, day, kind, subject, at, matter_id, state_token, fingerprint) VALUES (?,?,?,?,?,?,?,?)",
                    (
                        key,
                        day,
                        cand["kind"],
                        cand["subject"],
                        now,
                        cand.get("matter_id", ""),
                        cand.get("state_token", ""),
                        cand.get("fingerprint", ""),
                    ),
                )
                # 若为合并提醒，把底层成员指纹一并登记到幂等账本（day 记空避免虚占配额计数，只用于防重发）
                if len(members) > 1:
                    for m in members:
                        db.execute(
                            "INSERT OR IGNORE INTO sent(key, day, kind, subject, at, matter_id, state_token, fingerprint) VALUES (?,?,?,?,?,?,?,?)",
                            (
                                m["key"],
                                "",
                                m["kind"],
                                m["subject"],
                                now,
                                m.get("matter_id", ""),
                                m.get("state_token", ""),
                                m.get("fingerprint", ""),
                            ),
                        )
                db.execute("DELETE FROM deferred WHERE key=?", (key,))
                for m in members:
                    db.execute("DELETE FROM deferred WHERE key=?", (m["key"],))
            sent += 1

        if sent and self.notifications is not None and hasattr(self.notifications, "enqueue"):
            try:
                self.notifications.enqueue()
            except Exception:
                pass
        return sent

    def status(self) -> dict:
        with self.db() as db:
            rows = [
                dict(zip(("key", "day", "kind", "subject", "at", "matter_id", "state_token", "fingerprint"), r))
                for r in db.execute(
                    "SELECT key, day, kind, subject, at, matter_id, state_token, fingerprint FROM sent WHERE day<>'' ORDER BY at DESC LIMIT 20"
                )
            ]
            deferred_count = int(db.execute("SELECT count(*) FROM deferred").fetchone()[0])
        return {
            "recent": rows,
            "deferred_count": deferred_count,
            "daily_max": self.rules.daily_max(),
            "proactive_hard_cap": PROACTIVE_HARD_CAP,
            "rules_error": self.rules.error,
            "ledger_readable": self.ledger.is_file(),
        }


def main() -> None:
    parser = argparse.ArgumentParser(description="Com 顺口提醒（nudges）手动触发与状态查看")
    parser.add_argument("--status", action="store_true", help="查看最近已发送的顺口提醒")
    parser.add_argument("--inject-express", metavar="TEXT", help="构造一条快递事项并立即触发顺口提醒（用于验收）")
    args = parser.parse_args()

    state = Path(os.environ.get("WORKBENCH_STATE", str(Path.home() / ".session-workbench")))
    from conversation import PersonalConversation
    from personal_hub import PersonalHub
    from proactive import Proactive
    from push_notifications import PushNotifications
    from triggers import Triggers

    hub = PersonalHub(state)
    triggers = Triggers(state)
    hub.on_matter = triggers.record
    proactive = Proactive(state)
    conv = PersonalConversation(state)
    notif = PushNotifications(state, conv, proactive.settings)
    engine = Nudges(state, conv, proactive.settings, hub=hub, triggers=triggers, notifications=notif)

    if args.inject_express:
        now = time.time()
        hub.matter(
            "sms",
            "manual-nudge-verify",
            "快递提醒",
            {"messages": [{"id": f"m-{int(now)}", "from": "顺丰速运", "text": args.inject_express, "at": now}]},
            source_updated_at=now,
        )
    delivered = engine.tick()
    print(json.dumps({"delivered": delivered, **engine.status()}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
