"""Grok Bot 式回合后静默 Capture + 03:30 `/dream` 夜间整理引擎。

硬性约束：
- 严禁新建 `.sqlite` 文件：所有 `captured_facts` 与 `dream_runs` 表一律复用现有 `memory-inbox.sqlite`（WAL + 0600）。
- 严禁引入商业付费 Claude 模型：默认走 100% 确定性的纯 Python 归一化/Jaccard 去重、过期归档与分节归并；
  可选接入本地网关快模型（如 `auto/gemini-3.8-flash`）或传入 `llm_fn` 润色，超时/断网/异常一律无感回退纯 Python 结果。
- 敏感词零容忍：Capture 入库前与 Dream 写回 `MEMORY.md` 前双重执行 `memory.SENSITIVE` 校验。
"""
from __future__ import annotations

import asyncio
import hashlib
import inspect
import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import httpx

from memory import SENSITIVE
from memory_truth import ensure_truth_files, sanitize_truth_content, update_truth_file

TZ = ZoneInfo("Asia/Shanghai")
MAX_MEMORY_MD_CHARS = 1800
MAGPIE_DEFAULT_URL = "http://127.0.0.1:3001/v1/chat/completions"
MAGPIE_FAST_MODEL = "auto/gemini-3.8-flash"

_TRIVIAL_RE = re.compile(
    r"^\s*(?:测试|test|ping|hello|hi|你好|好的|收到|明白|嗯+|哦+|哈哈+|谢谢)\s*[!！。.?？~～]*$",
    re.I,
)
_CLAUSE_SPLIT_RE = re.compile(r"[。\n；;！!]+")
_NORM_STRIP_RE = re.compile(r"[\s，。、,.;；:：!！?？\"“”'‘’()（）\[\]【】*`~\-—_]+")
_EXPLICIT_EXPIRY_RE = re.compile(
    r"(?:[\(（\[]\s*(?:有效至|截止|expires?\s*:?)\s*(\d{4}-\d{2}-\d{2})\s*[\)）\]])",
    re.I,
)
_ISO_DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
_TEMPORARY_CUE_RE = re.compile(r"临时|暂定|本周|这周|下周|这几天|最近几天|明天|后天|月底前|出差|待办")
_OVERRIDE_CUE_RE = re.compile(r"改用|换成|切换成|不再|别再|不要再|改为|调整为")

# 启发式捕获规则：(kind, pattern, confidence)
_CAPTURE_PATTERNS: tuple[tuple[str, re.Pattern[str], float], ...] = (
    (
        "correction",
        re.compile(
            r"(?:以后|之后|下次)?(?:别再|不要再|绝对不要|严禁|禁止|切记不要|千万别)([^?？]{2,120})"
        ),
        0.92,
    ),
    (
        "correction",
        re.compile(
            r"(?:纠正一下|更正一下|说错了)[，,:：\s]*([^?？]{3,120})"
        ),
        0.90,
    ),
    (
        "preference",
        re.compile(
            r"(?:请|麻烦|你要|帮我)?(?:记住|记一下|记在记忆里)[，,:：\s]*([^?？]{3,140})"
        ),
        0.95,
    ),
    (
        "preference",
        re.compile(
            r"(?:以后都|之后都|今后都|一律都?|默认都?|统一都?用|以后统一)([^?？]{2,120})"
        ),
        0.90,
    ),
    (
        "decision",
        re.compile(
            r"(?:我|我们|现在|已经)?(?:改用|换成用?|切换成|改成用|定下来用|拍板用?)([^?？]{2,120})"
        ),
        0.88,
    ),
    (
        "preference",
        re.compile(
            r"我(?:平时|日常|一贯|固定)?(?:习惯|偏好|喜欢用|不喜欢)([^?？]{2,120})"
        ),
        0.84,
    ),
    (
        "temporal",
        re.compile(
            r"(?:下周(?:要|去|准备|计划|安排)|这周(?:要|先|准备)|本周(?:要|先|计划)|这几天(?:要|先)|明天(?:要|先|去)|后天(?:要|去)|月底前(?:要|得)|(?:\d{4}-\d{2}-\d{2})前(?:要|得))([^?？]{2,120})"
        ),
        0.82,
    ),
)


def _inbox_db_path(state_dir: Path | str) -> Path:
    st = Path(state_dir)
    st.mkdir(parents=True, exist_ok=True)
    return st / "memory-inbox.sqlite"


def _ensure_dream_schema(state_dir: Path | str) -> Path:
    db_path = _inbox_db_path(state_dir)
    with sqlite3.connect(db_path, timeout=20) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute(
            "CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,fingerprint TEXT UNIQUE,state TEXT,created REAL,data TEXT)"
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS captured_facts (
                id TEXT PRIMARY KEY,
                fingerprint TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                section TEXT NOT NULL,
                content TEXT NOT NULL,
                source_quote TEXT NOT NULL,
                channel TEXT NOT NULL DEFAULT 'personal',
                confidence REAL NOT NULL DEFAULT 0.85,
                expires_at REAL,
                status TEXT NOT NULL DEFAULT 'pending',
                created_at REAL NOT NULL,
                merged_at REAL,
                dream_run_id TEXT NOT NULL DEFAULT ''
            )
            """
        )
        db.execute(
            "CREATE INDEX IF NOT EXISTS idx_captured_facts_status ON captured_facts(status, created_at ASC)"
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS dream_runs (
                id TEXT PRIMARY KEY,
                reason TEXT NOT NULL,
                ran_at REAL NOT NULL,
                finished_at REAL NOT NULL,
                updated INTEGER NOT NULL DEFAULT 0,
                merged_count INTEGER NOT NULL DEFAULT 0,
                archived_count INTEGER NOT NULL DEFAULT 0,
                deduped_count INTEGER NOT NULL DEFAULT 0,
                used_llm INTEGER NOT NULL DEFAULT 0,
                summary TEXT NOT NULL DEFAULT '',
                error TEXT NOT NULL DEFAULT ''
            )
            """
        )
    os.chmod(db_path, 0o600)
    return db_path


@contextmanager
def _dream_db(state_dir: Path | str):
    db_path = _ensure_dream_schema(state_dir)
    conn = sqlite3.connect(db_path, timeout=20)
    conn.row_factory = sqlite3.Row
    try:
        with conn:
            yield conn
    finally:
        conn.close()


def _norm_text(text: str) -> str:
    stripped = _EXPLICIT_EXPIRY_RE.sub("", str(text or ""))
    stripped = re.sub(r"^\s*[-*•]\s*", "", stripped)
    return _NORM_STRIP_RE.sub("", stripped).lower()


def _shingles(norm: str) -> set[str]:
    if not norm:
        return set()
    if len(norm) == 1:
        return {norm}
    grams = {norm[i : i + 2] for i in range(len(norm) - 1)}
    en_words = set(re.findall(r"[a-z0-9]{2,}", norm))
    return grams | en_words


def jaccard_similarity(a: str, b: str) -> float:
    na, nb = _norm_text(a), _norm_text(b)
    if not na or not nb:
        return 0.0
    if na == nb:
        return 1.0
    sa, sb = _shingles(na), _shingles(nb)
    if not sa or not sb:
        return 0.0
    union = len(sa | sb)
    return (len(sa & sb) / union) if union else 0.0


def _are_near_duplicates(a: str, b: str, *, threshold: float = 0.68) -> bool:
    na, nb = _norm_text(a), _norm_text(b)
    if not na or not nb:
        return False
    if na == nb:
        return True
    shorter, longer = (na, nb) if len(na) <= len(nb) else (nb, na)
    if len(shorter) >= 6 and shorter in longer:
        return True
    return jaccard_similarity(na, nb) >= threshold


def _infer_section(text: str, kind: str) -> str:
    low = text.lower()
    if kind == "temporal":
        return "近期重点"
    if any(k in low for k in ("搜狐", "岩馆", "路书", "视频号", "关注流", "周报", "于超然", "梦雨", "老马", "剪辑", "选题")):
        return "工作与搜狐户外"
    if any(k in low for k in ("起床", "入睡", "睡觉", "健身", "攀岩", "抱石", "骑行", "摩旅", "日历", "记账", "ezbookkeeping", "房租", "通勤", "周末")):
        return "作息与生活系统"
    if any(k in low for k in ("mbp", "macbook", "mac mini", "nas", "iphone", "syncthing", "cursor", "agy", "pi-gateway", "8650", "模型", "agent")):
        return "硬件拓扑与分工"
    if any(k in low for k in ("称呼", "昵称", "本名", "伴侣", "猫", "logo", "rui")):
        return "核心身份"
    return "近期重点"


def _compute_temporal_expiry(clause: str, now_ts: float) -> tuple[float | None, str]:
    base_dt = datetime.fromtimestamp(now_ts, TZ)
    m_iso = _ISO_DATE_RE.search(clause)
    if m_iso:
        try:
            d = datetime.strptime(m_iso.group(1), "%Y-%m-%d").date()
            end_dt = datetime(d.year, d.month, d.day, 23, 59, 59, tzinfo=TZ)
            return end_dt.timestamp(), d.isoformat()
        except ValueError:
            pass

    days_delta: int | None = None
    if "明天" in clause:
        days_delta = 2
    elif "后天" in clause:
        days_delta = 3
    elif any(k in clause for k in ("这几天", "最近几天", "这周", "本周")):
        days_delta = 7
    elif "下周" in clause:
        days_delta = 14
    elif "月底前" in clause:
        days_delta = 31

    if days_delta is None:
        return None, ""
    exp_date = (base_dt + timedelta(days=days_delta)).date()
    exp_ts = datetime(exp_date.year, exp_date.month, exp_date.day, 23, 59, 59, tzinfo=TZ).timestamp()
    return exp_ts, exp_date.isoformat()


def _clean_captured_statement(clause: str, kind: str, expiry_date: str) -> str:
    txt = re.sub(r"\s+", " ", clause).strip(" ，,。；;！!：:")
    # 去掉口语前缀，保留完整语义
    txt = re.sub(r"^(?:请|麻烦|你要|帮我)?(?:记住|记一下|记在记忆里)[，,:：\s]*", "", txt).strip()
    txt = re.sub(r"^(?:纠正一下|更正一下|说错了)[，,:：\s]*", "", txt).strip()
    if kind == "temporal" and expiry_date and not _EXPLICIT_EXPIRY_RE.search(txt):
        txt = f"{txt}（有效至 {expiry_date}）"
    return txt[:180]


def capture_turn_facts(
    state_dir: Path,
    user_text: str,
    assistant_text: str = "",
    channel: str = "personal",
    *,
    now: float | None = None,
) -> dict[str, Any]:
    """静默识别用户回合中的显式偏好、纠正、新决定与近期临时安排，脱敏后写入 `memory-inbox.sqlite` 的 `captured_facts`。"""
    _ = assistant_text  # 严格只从用户本人显式表态提取事实，绝不把助理猜测当成用户事实
    moment = float(time.time() if now is None else now)
    _ensure_dream_schema(state_dir)

    raw_user = str(user_text or "").strip()
    if not raw_user or len(raw_user) < 4 or _TRIVIAL_RE.match(raw_user):
        return {"ok": True, "captured": [], "captured_count": 0, "dropped_sensitive": 0}

    captured_rows: list[dict[str, Any]] = []
    dropped_sensitive = 0
    seen_fps: set[str] = set()

    for raw_clause in _CLAUSE_SPLIT_RE.split(raw_user):
        clause = raw_clause.strip()
        if len(clause) < 4 or len(clause) > 220:
            continue
        if SENSITIVE.search(clause):
            dropped_sensitive += 1
            continue
        # 纯疑问句（不含「记住」指令）不作为稳定事实捕获
        if (clause.endswith("?") or clause.endswith("？")) and "记住" not in clause and "记一下" not in clause:
            continue

        matched_kind = ""
        matched_conf = 0.0
        for kind, pat, conf in _CAPTURE_PATTERNS:
            if pat.search(clause):
                matched_kind = kind
                matched_conf = conf
                break
        if not matched_kind:
            continue

        expires_at: float | None = None
        expiry_label = ""
        if matched_kind == "temporal":
            expires_at, expiry_label = _compute_temporal_expiry(clause, moment)

        statement = _clean_captured_statement(clause, matched_kind, expiry_label)
        if len(statement) < 3 or SENSITIVE.search(statement):
            if SENSITIVE.search(statement):
                dropped_sensitive += 1
            continue

        norm = _norm_text(statement)
        if len(norm) < 3:
            continue
        fp = hashlib.sha256(norm.encode("utf-8")).hexdigest()[:32]
        if fp in seen_fps:
            continue
        seen_fps.add(fp)

        section = _infer_section(statement, matched_kind)
        fact_id = f"cf_{fp[:20]}"
        ch = (channel or "personal").strip() or "personal"

        with _dream_db(state_dir) as db:
            existing = db.execute(
                "SELECT id, status FROM captured_facts WHERE fingerprint=?",
                (fp,),
            ).fetchone()
            if existing:
                continue
            db.execute(
                """
                INSERT INTO captured_facts (
                    id, fingerprint, kind, section, content, source_quote,
                    channel, confidence, expires_at, status, created_at, merged_at, dream_run_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, NULL, '')
                """,
                (
                    fact_id,
                    fp,
                    matched_kind,
                    section,
                    statement,
                    clause[:200],
                    ch,
                    matched_conf,
                    expires_at,
                    moment,
                ),
            )
        captured_rows.append(
            {
                "id": fact_id,
                "kind": matched_kind,
                "section": section,
                "content": statement,
                "channel": ch,
                "confidence": matched_conf,
                "expires_at": expires_at,
            }
        )

    return {
        "ok": True,
        "captured": captured_rows,
        "captured_count": len(captured_rows),
        "dropped_sensitive": dropped_sensitive,
    }


def _is_bullet_expired(line: str, today_iso: str) -> bool:
    m_exp = _EXPLICIT_EXPIRY_RE.search(line)
    if m_exp:
        return m_exp.group(1) < today_iso
    if _TEMPORARY_CUE_RE.search(line):
        dates = _ISO_DATE_RE.findall(line)
        if dates and max(dates) < today_iso:
            return True
    return False


def _parse_memory_sections(md_text: str) -> tuple[str, list[tuple[str, list[str]]], list[str]]:
    title = "# 长期记忆 (MEMORY.md)"
    sections: list[tuple[str, list[str]]] = []
    archive_bullets: list[str] = []
    current_sec: str | None = None
    in_archive = False

    for raw_line in md_text.splitlines():
        stripped = raw_line.strip()
        if not stripped:
            continue
        if stripped.startswith("# ") and not stripped.startswith("## "):
            title = stripped
            continue
        if stripped.startswith("## "):
            sec_name = stripped[3:].strip()
            low_name = sec_name.lower()
            if "_archive" in low_name or "归档" in low_name:
                in_archive = True
                current_sec = None
            else:
                in_archive = False
                current_sec = sec_name
                if not any(s == sec_name for s, _ in sections):
                    sections.append((sec_name, []))
            continue

        bullet_body = re.sub(r"^\s*[-*•]\s*", "", stripped).strip()
        if not bullet_body or SENSITIVE.search(bullet_body):
            continue
        formatted = f"- {bullet_body}"
        if in_archive:
            archive_bullets.append(formatted)
        else:
            if current_sec is None:
                current_sec = "近期重点"
                sections.append((current_sec, []))
            for s_name, s_list in sections:
                if s_name == current_sec:
                    s_list.append(formatted)
                    break

    if not sections:
        sections.append(("核心身份", []))
        sections.append(("近期重点", []))
    return title, sections, archive_bullets


def _render_memory_sections(
    title: str,
    sections: list[tuple[str, list[str]]],
    archive_bullets: list[str],
    *,
    max_chars: int = MAX_MEMORY_MD_CHARS,
) -> str:
    # 归档区最多保留最近 4 条，且超出 1800 字上限时优先裁剪归档区
    kept_archive = list(dict.fromkeys(archive_bullets))[-4:]
    work_sections = [(name, list(items)) for name, items in sections if items]

    def _assemble(sec_list: list[tuple[str, list[str]]], arch_list: list[str]) -> str:
        blocks = [title]
        for s_name, s_items in sec_list:
            if not s_items:
                continue
            blocks.append(f"## {s_name}\n" + "\n".join(s_items))
        if arch_list:
            blocks.append("## _archive\n" + "\n".join(arch_list))
        return "\n\n".join(blocks).strip() + "\n"

    rendered = _assemble(work_sections, kept_archive)
    while len(rendered) > max_chars and kept_archive:
        kept_archive.pop(0)
        rendered = _assemble(work_sections, kept_archive)

    # 若正文仍超过 1800 字，优先从「近期重点」最早的非核心条目开始温和裁剪，再裁剪最长分节末尾
    while len(rendered) > max_chars:
        trimmed = False
        for idx in range(len(work_sections) - 1, -1, -1):
            s_name, s_items = work_sections[idx]
            if ("近期" in s_name or len(s_items) > 1) and len(s_items) > 1:
                s_items.pop(0)
                trimmed = True
                break
        if not trimmed:
            # 单条过长时裁剪最长的一条 bullet
            longest_pair: tuple[int, int, int] = (-1, -1, 0)
            for s_i, (_, s_items) in enumerate(work_sections):
                for b_i, b_txt in enumerate(s_items):
                    if len(b_txt) > longest_pair[2]:
                        longest_pair = (s_i, b_i, len(b_txt))
            s_i, b_i, b_len = longest_pair
            if s_i >= 0 and b_len > 60:
                excess = max(20, len(rendered) - max_chars + 4)
                new_len = max(40, b_len - excess)
                work_sections[s_i][1][b_i] = work_sections[s_i][1][b_i][: new_len - 1].rstrip() + "…"
            else:
                break
        rendered = _assemble(work_sections, kept_archive)

    return rendered[:max_chars]


async def _optional_polish_markdown(draft_md: str, llm_fn: Any = None) -> tuple[str, bool]:
    """可选使用传入 `llm_fn` 或本地 Magpie 快模型润色，严格校验结构、长度与零敏感词，失败无感回退。"""
    candidate_raw = ""
    if llm_fn is not None:
        res = llm_fn(draft_md)
        if inspect.isawaitable(res):
            res = await asyncio.wait_for(res, timeout=4.0)
        candidate_raw = str(res or "").strip()
    elif os.environ.get("COM_DREAM_USE_MAGPIE") == "1" and not os.environ.get("PYTEST_CURRENT_TEST"):
        url = os.environ.get("MAGPIE_COMPLETIONS_URL", MAGPIE_DEFAULT_URL)
        api_key = os.environ.get("MAGPIE_API_KEY", "local")
        prompt = (
            "请在不丢失任何事实、人名、时间、数字与规则的前提下，将以下 MEMORY.md 整理得更紧凑清晰，"
            f"保持 `# 长期记忆 (MEMORY.md)` 与 `## ` 二级标题及 `- ` 列表结构，总字数严格不超过 {MAX_MEMORY_MD_CHARS} 字，"
            "只输出整理后的 Markdown 原文：\n\n" + draft_md
        )
        async with httpx.AsyncClient(timeout=4.0, trust_env=False) as client:
            resp = await client.post(
                url,
                headers={"Authorization": f"Bearer {api_key}"},
                json={
                    "model": MAGPIE_FAST_MODEL,
                    "messages": [{"role": "user", "content": prompt}],
                    "temperature": 0.1,
                },
            )
            resp.raise_for_status()
            data = resp.json()
            candidate_raw = str(((data.get("choices") or [{}])[0].get("message") or {}).get("content") or "").strip()

    if not candidate_raw:
        return draft_md, False

    # 剥离可能包裹的外层 ```markdown 代码围栏
    if candidate_raw.startswith("```"):
        lines = candidate_raw.splitlines()
        if len(lines) >= 3 and lines[-1].strip().startswith("```"):
            candidate_raw = "\n".join(lines[1:-1]).strip()

    clean_cand, stripped_sens = sanitize_truth_content(candidate_raw)
    if stripped_sens or not clean_cand or len(clean_cand) > MAX_MEMORY_MD_CHARS:
        return draft_md, False
    if not clean_cand.lstrip().startswith("#"):
        return draft_md, False
    orig_bullets = sum(1 for ln in draft_md.splitlines() if ln.lstrip().startswith("- "))
    cand_bullets = sum(1 for ln in clean_cand.splitlines() if ln.lstrip().startswith("- "))
    if orig_bullets > 0 and cand_bullets < max(1, int(orig_bullets * 0.7)):
        return draft_md, False
    return clean_cand, True


async def run_dream(
    state_dir: Path,
    reason: str = "manual",
    llm_fn: Any = None,
    *,
    now: float | None = None,
) -> dict[str, Any]:
    """执行 `/dream` 夜间或手动记忆整理：近似去重、过期归档、新偏好并入 `MEMORY.md`（<= 1800 字）。"""
    moment = float(time.time() if now is None else now)
    today_iso = datetime.fromtimestamp(moment, TZ).date().isoformat()
    run_id = f"dream_{secrets.token_hex(6)}"

    _ensure_dream_schema(state_dir)
    truth_dir = ensure_truth_files(state_dir)
    mem_path = truth_dir / "MEMORY.md"
    original_md, _ = sanitize_truth_content(mem_path.read_text(encoding="utf-8"))

    title, sections, archive_bullets = _parse_memory_sections(original_md)
    archived_count = 0
    deduped_count = 0
    merged_count = 0

    # 1. 归档 MEMORY.md 中已过期的临时状态，并在已有分节内执行确定性近似去重
    deduped_sections: list[tuple[str, list[str]]] = []
    global_kept_bullets: list[tuple[int, int, str]] = []  # (sec_idx, item_idx, text)

    for sec_name, bullets in sections:
        kept_for_sec: list[str] = []
        sec_idx = len(deduped_sections)
        for b in bullets:
            if _is_bullet_expired(b, today_iso):
                archived_count += 1
                archive_bullets.append(f"- [归档 {today_iso}] {re.sub(r'^-\s*', '', b)}")
                continue
            dup_found = False
            for g_sec_i, g_item_i, existing_b in list(global_kept_bullets):
                if _are_near_duplicates(b, existing_b):
                    dup_found = True
                    deduped_count += 1
                    # 保留信息量更完整的一条
                    if len(_norm_text(b)) > len(_norm_text(existing_b)):
                        target_list = kept_for_sec if g_sec_i == sec_idx else deduped_sections[g_sec_i][1]
                        target_list[g_item_i] = b
                        idx_in_global = global_kept_bullets.index((g_sec_i, g_item_i, existing_b))
                        global_kept_bullets[idx_in_global] = (g_sec_i, g_item_i, b)
                    break
            if not dup_found:
                item_idx = len(kept_for_sec)
                kept_for_sec.append(b)
                global_kept_bullets.append((sec_idx, item_idx, b))
        deduped_sections.append((sec_name, kept_for_sec))

    # 2. 读取待归并的 `captured_facts`
    with _dream_db(state_dir) as db:
        pending_rows = [
            dict(r)
            for r in db.execute(
                "SELECT * FROM captured_facts WHERE status='pending' ORDER BY created_at ASC"
            ).fetchall()
        ]

    merged_ids: list[str] = []
    deduped_ids: list[str] = []
    archived_ids: list[str] = []

    for row in pending_rows:
        fid = str(row["id"])
        content = str(row.get("content") or "").strip()
        conf = float(row.get("confidence") or 0.0)
        exp_ts = row.get("expires_at")
        target_sec = str(row.get("section") or "近期重点")

        if not content or SENSITIVE.search(content):
            deduped_ids.append(fid)
            continue

        if (exp_ts is not None and float(exp_ts) < moment) or _is_bullet_expired(content, today_iso):
            archived_ids.append(fid)
            archived_count += 1
            archive_bullets.append(f"- [归档 {today_iso}] {content}")
            continue

        if conf < 0.70:
            continue

        new_bullet = f"- {re.sub(r'^[-*•]\s*', '', content)}"
        matched_existing: tuple[int, int, str] | None = None
        for entry in global_kept_bullets:
            if _are_near_duplicates(new_bullet, entry[2]):
                matched_existing = entry
                break

        if matched_existing is not None:
            g_sec_i, g_item_i, old_bullet = matched_existing
            # 若新事实带有明确纠正/改用语义或更丰富细节且不超长，则原地更新该条真相
            if (_OVERRIDE_CUE_RE.search(content) or len(_norm_text(new_bullet)) > len(_norm_text(old_bullet)) + 4) and _norm_text(new_bullet) != _norm_text(old_bullet):
                deduped_sections[g_sec_i][1][g_item_i] = new_bullet
                idx_pos = global_kept_bullets.index(matched_existing)
                global_kept_bullets[idx_pos] = (g_sec_i, g_item_i, new_bullet)
                merged_ids.append(fid)
                merged_count += 1
            else:
                deduped_ids.append(fid)
                deduped_count += 1
            continue

        # 并入对应二级标题分节
        sec_pos = next((i for i, (s_name, _) in enumerate(deduped_sections) if s_name == target_sec), None)
        if sec_pos is None:
            sec_pos = len(deduped_sections)
            deduped_sections.append((target_sec, []))
        item_pos = len(deduped_sections[sec_pos][1])
        deduped_sections[sec_pos][1].append(new_bullet)
        global_kept_bullets.append((sec_pos, item_pos, new_bullet))
        merged_ids.append(fid)
        merged_count += 1

    draft_md = _render_memory_sections(title, deduped_sections, archive_bullets, max_chars=MAX_MEMORY_MD_CHARS)

    used_llm = False
    if merged_count > 0 or archived_count > 0 or deduped_count > 0 or llm_fn is not None:
        try:
            polished_md, used_llm = await _optional_polish_markdown(draft_md, llm_fn=llm_fn)
            final_md = polished_md if len(polished_md) <= MAX_MEMORY_MD_CHARS else draft_md
        except BaseException as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            final_md = draft_md
            used_llm = False
    else:
        final_md = draft_md

    clean_final_md, _ = sanitize_truth_content(final_md)
    if len(clean_final_md) > MAX_MEMORY_MD_CHARS:
        t2, s2, a2 = _parse_memory_sections(clean_final_md)
        clean_final_md = _render_memory_sections(t2, s2, a2, max_chars=MAX_MEMORY_MD_CHARS)

    updated = clean_final_md.strip() != original_md.strip()
    if updated:
        update_truth_file("MEMORY.md", clean_final_md, state_dir=state_dir)

    finished_at = float(time.time() if now is None else now)
    summary_parts = [
        f"合并新事实 {merged_count} 条",
        f"归档过期状态 {archived_count} 条",
        f"近似去重 {deduped_count} 条",
    ]
    summary = "夜间记忆整理完成：" + "，".join(summary_parts) + f"（当前 {len(clean_final_md)} 字）。"

    with _dream_db(state_dir) as db:
        for fid in merged_ids:
            db.execute(
                "UPDATE captured_facts SET status='merged', merged_at=?, dream_run_id=? WHERE id=?",
                (moment, run_id, fid),
            )
        for fid in deduped_ids:
            db.execute(
                "UPDATE captured_facts SET status='deduped', merged_at=?, dream_run_id=? WHERE id=?",
                (moment, run_id, fid),
            )
        for fid in archived_ids:
            db.execute(
                "UPDATE captured_facts SET status='archived', merged_at=?, dream_run_id=? WHERE id=?",
                (moment, run_id, fid),
            )
        db.execute(
            """
            INSERT INTO dream_runs (
                id, reason, ran_at, finished_at, updated, merged_count,
                archived_count, deduped_count, used_llm, summary, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '')
            """,
            (
                run_id,
                str(reason or "manual")[:60],
                moment,
                finished_at,
                1 if updated else 0,
                merged_count,
                archived_count,
                deduped_count,
                1 if used_llm else 0,
                summary[:500],
            ),
        )

    return {
        "ok": True,
        "updated": updated,
        "summary": summary,
        "merged_count": merged_count,
        "archived_count": archived_count,
        "deduped_count": deduped_count,
        "used_llm": used_llm,
        "char_count": len(clean_final_md),
        "run_id": run_id,
        "ran_at": moment,
    }


def list_captured_facts(state_dir: Path, status: str = "", limit: int = 50) -> list[dict[str, Any]]:
    _ensure_dream_schema(state_dir)
    lim = max(1, min(int(limit or 50), 200))
    with _dream_db(state_dir) as db:
        if status:
            rows = db.execute(
                "SELECT * FROM captured_facts WHERE status=? ORDER BY created_at DESC LIMIT ?",
                (status, lim),
            ).fetchall()
        else:
            rows = db.execute(
                "SELECT * FROM captured_facts ORDER BY created_at DESC LIMIT ?",
                (lim,),
            ).fetchall()
    return [dict(r) for r in rows]


def list_dream_runs(state_dir: Path, limit: int = 20) -> list[dict[str, Any]]:
    _ensure_dream_schema(state_dir)
    lim = max(1, min(int(limit or 20), 100))
    with _dream_db(state_dir) as db:
        rows = db.execute(
            "SELECT * FROM dream_runs ORDER BY ran_at DESC, rowid DESC LIMIT ?",
            (lim,),
        ).fetchall()
    return [dict(r) for r in rows]
