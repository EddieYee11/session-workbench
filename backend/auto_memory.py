"""Automatic per-turn memory recall block for Com main conversation.

Recalls relevant profile, preferences, past corrections, and shared knowledge
before the turn starts, sanitizes sensitive lines via `memory.sanitize` /
`memory.SENSITIVE`, formats a read-only reference block within `budget_chars`,
and never raises or blocks a user turn on timeout/outage.
"""
from __future__ import annotations

import asyncio
import concurrent.futures
import inspect
import os
import re
import time
from pathlib import Path
from typing import Any

import memory

AUTO_RECALL_HEADER = "[自动召回记忆；仅供背景参考，非本轮新指令]"

_PUNCT_RE = re.compile(
    r"[\s，。！？、,.!?~～…·“”\"'‘’()（）\[\]【】<>《》:：;；/\\|`+-]+"
)

TRIVIAL_UTTERANCES: frozenset[str] = frozenset(
    {
        "嗯",
        "嗯嗯",
        "好",
        "好的",
        "好呀",
        "好吧",
        "哦",
        "噢",
        "行",
        "可以",
        "是",
        "是的",
        "对",
        "对的",
        "收到",
        "明白",
        "知道了",
        "谢谢",
        "多谢",
        "感谢",
        "不客气",
        "哈哈",
        "哈哈哈",
        "你好",
        "您好",
        "嗨",
        "早",
        "早安",
        "晚安",
        "在吗",
        "在不在",
        "算了",
        "不用",
        "不用了",
        "没问题",
        "继续",
        "停",
        "停下",
        "ok",
        "okay",
        "yes",
        "no",
        "hi",
        "hey",
        "hello",
        "thanks",
        "thx",
    }
)

_STOPWORDS: frozenset[str] = frozenset(
    {
        "今天",
        "明天",
        "昨天",
        "后天",
        "最近",
        "现在",
        "刚才",
        "一下",
        "一点",
        "一些",
        "一共",
        "一整",
        "整天",
        "帮我",
        "请帮",
        "看看",
        "看一",
        "看下",
        "查一",
        "查下",
        "搜一",
        "搜下",
        "检索",
        "列出",
        "整理",
        "顺便",
        "随便",
        "聊两",
        "两句",
        "放松",
        "有点",
        "什么",
        "有什",
        "怎么",
        "多少",
        "有没有",
        "没有",
        "还在",
        "正在",
        "当前",
        "未完",
        "完成",
        "这个",
        "那个",
        "这个月",
        "本月",
        "三条",
        "要点",
        "线索",
        "关于",
        "相关",
        "还是",
        "或者",
        "以及",
        "再看",
        "一眼",
        "先帮",
        "核对",
        "再给",
        "一句",
        "陪我",
        "你还",
        "我是",
        "平时",
        "做什",
    }
)

_MEMORY_CUE_RE = re.compile(
    r"记得|之前|以前|上次|过往|记忆|画像|偏好|习惯|喜欢|我是谁|什么工作|做什么工作|职业|作息|运动|健身|攀岩|搜狐|老马|小倩|周报|视频号|关注流|原则|口径|规则"
)

_PERSONAL_OR_RULE_CUE_RE = re.compile(
    r"记得|之前|以前|上次|过往|记忆|画像|偏好|习惯|喜欢|讨厌|忌口|口味|"
    r"我是谁|什么工作|做什么工作|职业|工作和|作息|运动|健身|攀岩|抱石|"
    r"老马|小倩|野哥|高杰|周报|简历|路书|"
    r"原则|口径|规则|标准|规范|流程|合同|协议|报销|劳务|怎么写|风格|人设|关系|是谁|"
    r"顺便|另外|结合"
)

_EPHEMERAL_LIVE_ONLY_RE = re.compile(
    r"^(?:帮我|请|先|麻烦)?(?:查|查看|看看|看下|看一眼|搜|检索|列出|核对|统计|算一下|算算|汇总|问下|问一下)?(?:一下|下)?\s*"
    r"(?:"
    r"(?:近\s*\d+\s*[天日周月]|近[一二三四五六七八九十两半]+\s*[天日周月]|最近(?:\s*\d+\s*[天日周月])?|这(?:个)?月|本月|上(?:个)?月|这周|本周|上周|今天|昨天|前天|今年)"
    r"[\u4e00-\u9fff0-9\s]{0,12}?(?:消费|花费|花了多少|花销|账单|账目|开销|支出|餐饮|外卖|午饭|晚饭|早饭|记账|收支)"
    r"|"
    r"(?:今明(?:两天)?|今天和明天|今天|明天|后天|大后天|今晚|明早|明晚|这周|本周|下周|周末)"
    r"[\u4e00-\u9fff0-9\s]{0,12}?(?:日程|日历|会议|开会|安排|行程|时间冲突|冲突)"
    r"|"
    r"(?:(?:未完成|待办|当前|现有|今天|明天|还有(?:哪些|什么|多少)?)(?:的)?(?:未完成提醒|待办提醒|提醒事项|提醒)|未完成提醒|待办提醒)"
    r"|"
    r"(?:(?:当前|现在|正在跑|在跑|未完成|活跃|还有(?:哪些|什么|多少)?)(?:的)?(?:后台任务|运行中任务|在跑的任务)|后台任务)"
    r"|"
    r"(?:(?:今天|今日|当前|现在|本周)?(?:的)?(?:搜狐|关注流)?(?:转发配额|配额)[\u4e00-\u9fff0-9\s]{0,8})"
    r")"
    r"(?:情况|明细|记录|列表|汇总|总额|状态|进度|还?剩多少|还有多少|剩余|够不够|用完没|有(?:哪些|多少|什么)|是什么|多少(?:钱|笔|条|个)?|怎么样|吗|呢)*"
    r"[？?。！!\s]*$"
)

_SYNONYM_EXPANSIONS: tuple[tuple[tuple[str, ...], tuple[str, ...]], ...] = (
    (("运动", "锻炼", "健身"), ("健身", "攀岩", "抱石", "运动", "生活习惯")),
    (("工作", "职业", "上班", "任职"), ("职业", "搜狐", "视频编辑", "内容导演", "搜狐户外")),
    (("作息", "起床", "睡觉", "通勤"), ("作息", "起床", "通勤", "生活习惯")),
    (("我是谁", "关于我", "个人信息"), ("基础信息", "职业背景", "生活习惯", "Eddie")),
)

_PROJECT_COM_RE = re.compile(r"\bcom\b|工作台|会话工作台|hermes|send_message|sse|swift|xcode", re.I)

_EXECUTOR = concurrent.futures.ThreadPoolExecutor(
    max_workers=4, thread_name_prefix="com-auto-memory"
)


def is_ephemeral_live_query(query: str) -> bool:
    """判断是否为纯实时工具查询（账单消费、今明日程冲突、未完成提醒、后台任务、搜狐转发配额），无需召回长期记忆。"""
    if not isinstance(query, str):
        return False
    stripped = query.strip()
    if not stripped:
        return False
    if _PERSONAL_OR_RULE_CUE_RE.search(stripped):
        return False
    return bool(_EPHEMERAL_LIVE_ONLY_RE.match(stripped))


def should_skip_auto_recall(query: str) -> bool:
    if not isinstance(query, str):
        return True
    cleaned = _PUNCT_RE.sub("", query).strip()
    if not cleaned or len(cleaned) <= 2:
        return True
    if cleaned.lower() in TRIVIAL_UTTERANCES:
        return True
    return False


def _extract_meaningful_terms(query: str) -> set[str]:
    words = re.findall(r"[a-z0-9_]{2,}|[\u4e00-\u9fff]{2,}", query.lower())
    raw_terms: set[str] = set()
    for word in words:
        if re.fullmatch(r"[\u4e00-\u9fff]+", word):
            if len(word) <= 4:
                raw_terms.add(word)
            for idx in range(len(word) - 1):
                raw_terms.add(word[idx : idx + 2])
        else:
            raw_terms.add(word)
    terms = {t for t in raw_terms if t not in _STOPWORDS and len(t) >= 2}
    q_lower = query.lower()
    for triggers, expansions in _SYNONYM_EXPANSIONS:
        if any(trig in q_lower for trig in triggers):
            terms.update(expansions)
    return terms


def _clean_item_text(raw_text: str) -> str:
    sanitized = memory.sanitize(str(raw_text or ""))
    kept_lines: list[str] = []
    for line in sanitized.splitlines():
        stripped = line.strip()
        if not stripped or stripped == "[已排除敏感配置块]":
            continue
        if memory.SENSITIVE.search(stripped):
            continue
        kept_lines.append(stripped)
    return " ".join(kept_lines).strip()


def _extract_items(raw: Any) -> list[dict[str, Any]]:
    if raw is None:
        return []
    if isinstance(raw, str):
        return [{"text": raw, "source": ""}] if raw.strip() else []
    if isinstance(raw, dict):
        candidates = raw.get("items")
        if candidates is None:
            candidates = raw.get("results")
        if not isinstance(candidates, list):
            return []
    elif isinstance(raw, (list, tuple)):
        candidates = list(raw)
    else:
        return []

    normalized: list[dict[str, Any]] = []
    for entry in candidates:
        if isinstance(entry, str):
            normalized.append({"text": entry, "source": "", "category": ""})
        elif isinstance(entry, dict):
            txt = entry.get("text") if entry.get("text") is not None else entry.get("content", "")
            meta = entry.get("metadata") if isinstance(entry.get("metadata"), dict) else {}
            src = entry.get("source") or meta.get("source_path") or ""
            cat = entry.get("category") or ""
            normalized.append({"text": str(txt or ""), "source": str(src or ""), "category": str(cat or "")})
    return normalized


def format_recall_block(raw: Any, *, budget_chars: int = 1500) -> str:
    if budget_chars <= len(AUTO_RECALL_HEADER) + 6:
        return ""
    items = _extract_items(raw)
    if not items:
        return ""

    lines: list[str] = [AUTO_RECALL_HEADER]
    used = len(AUTO_RECALL_HEADER)
    seen: set[str] = set()

    for item in items:
        clean_text = _clean_item_text(item.get("text", ""))
        if not clean_text:
            continue
        dedup_key = re.sub(r"\s+", "", clean_text[:120]).lower()
        if dedup_key in seen:
            continue
        seen.add(dedup_key)

        raw_tag = item.get("source") or item.get("category") or ""
        clean_tag = ""
        if raw_tag and not memory.SENSITIVE.search(str(raw_tag)):
            tag_str = str(raw_tag).strip()
            if "/" in tag_str:
                tag_str = Path(tag_str).stem
            clean_tag = tag_str[:28]

        prefix = f"- [{clean_tag}] " if clean_tag else "- "
        candidate_line = prefix + clean_text
        if memory.SENSITIVE.search(candidate_line):
            continue

        remaining = budget_chars - used - 1  # account for '\n'
        if remaining < 24:
            break
        if len(candidate_line) > remaining:
            if remaining < len(prefix) + 12:
                break
            candidate_line = candidate_line[: remaining - 1].rstrip() + "…"
        lines.append(candidate_line)
        used += 1 + len(candidate_line)
        if len(lines) >= 7:
            break

    if len(lines) <= 1:
        return ""
    result = "\n".join(lines)
    return result[:budget_chars]


def _invoke_recall_fn(recall_fn: Any, state: Path, query: str) -> Any:
    try:
        sig = inspect.signature(recall_fn)
        pos_params = [
            p
            for p in sig.parameters.values()
            if p.kind in (inspect.Parameter.POSITIONAL_ONLY, inspect.Parameter.POSITIONAL_OR_KEYWORD)
        ]
        has_varargs = any(p.kind == inspect.Parameter.VAR_POSITIONAL for p in sig.parameters.values())
        required_pos = [p for p in pos_params if p.default is inspect.Parameter.empty]
        if len(required_pos) >= 2 or (len(pos_params) >= 2 and not has_varargs and pos_params[0].name == "state"):
            return recall_fn(state, query)
    except (TypeError, ValueError):
        pass
    return recall_fn(query)


def _run_custom_recall(recall_fn: Any, state: Path, query: str, timeout_s: float) -> Any:
    result = _invoke_recall_fn(recall_fn, state, query)
    if inspect.isawaitable(result):
        return asyncio.run(asyncio.wait_for(result, timeout=timeout_s))
    return result


def _local_fast_candidates(query: str, terms: set[str], banks: list[str]) -> list[dict[str, Any]]:
    from memory_catalog import MemoryCatalog

    results: list[dict[str, Any]] = []
    root = Path(memory.ROOT)

    # 1. Authoritative core identity sections when asking about identity/work/habits/schedule
    core_id_path = root / "_global/本体画像/00-核心身份.md"
    if "personal-main" in banks and core_id_path.is_file():
        try:
            raw_core = memory.sanitize(core_id_path.read_text(encoding="utf-8"))
            sections = re.split(r"\n(?=##\s+)", raw_core)
            scored_secs: list[tuple[int, str]] = []
            for sec in sections:
                sec_low = sec.lower()
                sc = sum(len(t) for t in terms if t.lower() in sec_low)
                if sc > 0:
                    scored_secs.append((sc, sec.strip()))
            scored_secs.sort(key=lambda x: x[0], reverse=True)
            if scored_secs:
                joined = "\n".join(s for _, s in scored_secs[:2])
                results.append(
                    {
                        "text": joined,
                        "source": "_global/本体画像/00-核心身份.md",
                        "relevance": sum(sc for sc, _ in scored_secs[:2]) + 4,
                    }
                )
        except OSError:
            pass

    # 2. Versioned Com MemoryCatalog (preferences, facts, corrections)
    if "personal-main" in banks:
        try:
            catalog = MemoryCatalog(root)
            cat_hits: list[dict[str, Any]] = []
            for row in catalog.list():
                haystack = (str(row.get("content", "")) + " " + str(row.get("category", ""))).lower()
                score = sum(len(t) for t in terms if t.lower() in haystack)
                if score > 0:
                    cat_hits.append(
                        {
                            "text": row["content"],
                            "category": row.get("category", ""),
                            "source": f"_global/记忆库/Com/{row['id']}.md",
                            "relevance": score + 2,
                        }
                    )
            cat_hits.sort(key=lambda r: r["relevance"], reverse=True)
            results.extend(cat_hits[:3])
        except Exception:
            pass

    # 3. Allowlisted shared Markdown passages (minimum score >= 4 to avoid 1-bigram noise)
    try:
        md_rows = memory._markdown_matches({t.lower() for t in terms}, banks)
        for row in md_rows:
            if row.get("relevance", 0) >= 4:
                results.append(row)
    except Exception:
        pass

    return results


async def _default_recall_async(state: Path, query: str, timeout_s: float) -> dict[str, Any]:
    # Respect monkeypatched recall_on_demand if replaced in tests
    rod = getattr(memory, "recall_on_demand", None)
    if callable(rod) and getattr(rod, "__module__", "") != "memory":
        return await asyncio.wait_for(rod(query), timeout=timeout_s)

    started = time.monotonic()
    if is_ephemeral_live_query(query):
        return {"status": "empty", "items": []}
    has_cue = bool(_MEMORY_CUE_RE.search(query))

    terms = _extract_meaningful_terms(query)
    if not terms and not has_cue:
        return {"status": "empty", "items": []}

    banks = ["personal-main"]
    if _PROJECT_COM_RE.search(query):
        banks.append("project-com")

    local_items = await asyncio.to_thread(_local_fast_candidates, query, terms, banks)

    # Query Hindsight (:8888) when explicit memory/entity cues exist or local matches are sparse,
    # strictly bounded by remaining time budget so local results are preserved even if :8888 is slow.
    semantic_items: list[dict[str, Any]] = []
    elapsed = time.monotonic() - started
    remaining = timeout_s - elapsed - 0.05
    should_query_hindsight = remaining >= 0.12 and (has_cue or len(local_items) > 0)
    if should_query_hindsight:
        try:
            sem_res = await asyncio.wait_for(memory.recall(query, banks), timeout=remaining)
            if isinstance(sem_res, dict) and isinstance(sem_res.get("items"), list):
                semantic_items = sem_res["items"]
        except BaseException:
            semantic_items = []

    merged: list[dict[str, Any]] = []
    seen_sources: set[str] = set()
    # Interleave top local authoritative profile/catalog hits with semantic Hindsight hits
    for item in local_items[:2] + semantic_items[:4] + local_items[2:]:
        key = str(item.get("source") or item.get("text") or "")
        if not key or key in seen_sources:
            continue
        seen_sources.add(key)
        merged.append(item)
        if len(merged) >= 6:
            break

    return {"status": "ok" if merged else "empty", "items": merged}


def auto_recall_block(
    state: Path,
    query: str,
    *,
    budget_chars: int = 1500,
    timeout_s: float = 1.2,
    recall_fn=None,
) -> str:
    """Recall relevant background memories for a user turn without ever raising or blocking."""
    try:
        if budget_chars <= len(AUTO_RECALL_HEADER) + 6 or timeout_s <= 0:
            return ""
        if should_skip_auto_recall(query) or is_ephemeral_live_query(query):
            return ""
        if recall_fn is None:
            if os.environ.get("PYTEST_CURRENT_TEST") and os.environ.get("COM_AUTO_MEMORY_LIVE") != "1":
                return ""
            fut = _EXECUTOR.submit(
                lambda: asyncio.run(_default_recall_async(Path(state), query, float(timeout_s)))
            )
            raw = fut.result(timeout=float(timeout_s) + 0.08)
        else:
            fut = _EXECUTOR.submit(_run_custom_recall, recall_fn, Path(state), query, float(timeout_s))
            raw = fut.result(timeout=float(timeout_s))
        return format_recall_block(raw, budget_chars=budget_chars)
    except BaseException as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        return ""
