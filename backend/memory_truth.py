"""Meta Muse 式可读可改文件记忆真相层 (`MEMORY.md` + `SOUL.md`)。

设计契约：
- 生产环境默认真源落在 `/Users/eddiegao/AI_Work_System/_global/记忆库/Com/` 下的 `MEMORY.md` 与 `SOUL.md`。
- 测试隔离保护：传入非线上 `state_dir` 或处于 `PYTEST_CURRENT_TEST` / `COM_TRUTH_ISOLATED=1` 时，
  自动落入隔离目录（`Path(state_dir) / "com-memory-truth"`），绝不污染真实 `_global/记忆库/Com/`。
- 敏感词铁律：写入与读取均经过 `memory.SENSITIVE` 逐行校验，任何包含敏感词的行一律拦截并记录到 `sanitized_lines`。
- 上下文预算：`truth_prompt_header` 仅在实质对话注入紧凑真相摘要（默认 `<= 800` 字），寒暄与极短应答自动跳过，
  不触碰 `hermes_prompt.py` 的 `SYSTEM_PROMPT` / `system_chars`。
"""
from __future__ import annotations

import os
import re
import secrets
import tempfile
from pathlib import Path
from typing import Any

import memory
from auto_memory import should_skip_auto_recall
from memory import SENSITIVE

DEFAULT_TRUTH_DIR = Path(memory.ROOT) / "_global/记忆库/Com"
LIVE_WORKBENCH_STATE = Path.home() / ".session-workbench"

TRUTH_FILE_SPECS: tuple[tuple[str, str], ...] = (
    ("MEMORY.md", "长期记忆 (MEMORY.md)"),
    ("SOUL.md", "助理分寸 (SOUL.md)"),
)
TRUTH_TITLES: dict[str, str] = dict(TRUTH_FILE_SPECS)
ALLOWED_TRUTH_NAMES: frozenset[str] = frozenset(TRUTH_TITLES.keys())

TRUTH_PROMPT_TAG = "[长期记忆与助理分寸 (MEMORY.md / SOUL.md)]"

DEFAULT_MEMORY_MD = """# 长期记忆 (MEMORY.md)

## 核心身份
- 本名高杰（1997年生，河南籍，常驻北京，时区 Asia/Shanghai），私聊称呼 Eddie（用「你」不用「您」）；微信昵称野望，工作群称呼野哥、小野；伴侣 Rui，英短猫 Logo（家中地位最高）。

## 工作与搜狐户外
- 搜狐资深视频编辑（内容导演），执掌搜狐户外（UID 376622042）视频号与搜狐视频关注流；主栏目《全国岩馆路书》采用六段式真实评测不接硬广，文案禁用「最」字断言，合规与野生老马合同协同同事于超然；周报输出「【周报】」5-7 条清单（崔梦雨简写梦雨，结款报销日更置末）。

## 作息与生活系统
- 作息约 07:30 起床、23:30 入睡，工作日单程通勤 1.5 小时，周末不加班；工作日晚 19:30-20:30 固定健身或抱石攀岩；摩旅骑行关注凯旋 Scrambler 900。
- 日历标题统一用「【分类】标题」；个人记账用 NAS ezbookkeeping（默认招商银行储蓄卡，住宿归居住房租）；个人量化用 Obsidian LifeOS 配 Garmin 身体电量。

## 硬件拓扑与分工
- 双机 MacBook Pro（Eddie-MBP 主开发）+ Mac mini（EddiedeMac-mini 常驻承载 pi-gateway 与 Com 后端 :8650，Syncthing 同步）+ 绿联 NAS + 主力折叠屏真机 iPhone Duo（Android 旧端已停用）；多 Agent 禁调商业付费 Claude，iOS 派 cursor、盘点脚本派 pi、写作审查派 agy。

## 近期重点
- 推进 Com! 私人助理升级（极速路由分流、原生多态气泡、MEMORY/SOUL 真相层与夜间 /dream 整理、iPhone Duo 左聊右看双栏）及搜狐户外全国岩馆路书与 #大有可攀 交付。
"""

DEFAULT_SOUL_MD = """# 助理分寸 (SOUL.md)

## 说话分寸
- 默认中文称 Eddie，像熟识靠谱的朋友在手机上发微信，口语短句、少堆砌术语、不用客套开场白；先给结论（超两句首句加粗），排障部署直接给可执行命令与验证预期。
- 多选项取舍时必给明确倾向建议与一句贴合当前处境及投入产出比的理由，绝不只罗列优劣。

## 行动红线
- 外部邮件「发送」、搜狐 PR 劳务与报销「提交」、视频号与关注流内容「发布」，一律只填好核对并停在按钮前，由 Eddie 亲手点击。
- 微信消息只作背景上下文，绝不催回微信或代写寒暄，群聊只提炼待办、催办人与 @野望/@高杰/@野哥 点名；遵守数据只转移不删除；定位缺失或短信超 48 小时等信源陈旧时如实附新鲜度说明，绝不瞎编位置；禁碰账号私密字段。
"""

DEFAULT_CONTENT_BY_NAME: dict[str, str] = {
    "MEMORY.md": DEFAULT_MEMORY_MD,
    "SOUL.md": DEFAULT_SOUL_MD,
}

_GREETING_ONLY_RE = re.compile(
    r"^\s*(?:你好(?:呀|啊|吗)?|您好|嗨|哈喽|早上好|早安|早|中午好|下午好|晚上好|晚安|在吗|在不在(?:呀)?|忙吗|收到|好的(?:呀)?|明白|谢谢(?:你)?|多谢|哈哈+|hello|hi|hey|ping|test|测试(?:一下)?)\s*[!！。,.，?？~～]*$",
    re.I,
)
_MD_DECORATION_RE = re.compile(r"(\*\*|`+)")
_QUERY_SYNONYMS: tuple[tuple[tuple[str, ...], tuple[str, ...]], ...] = (
    (("运动", "锻炼", "健身", "训练", "攀岩", "抱石"), ("19:30", "健身", "抱石", "攀岩", "作息")),
    (("工作", "职业", "公司", "业务", "栏目", "路书"), ("搜狐", "内容导演", "搜狐户外", "全国岩馆路书", "于超然", "周报")),
    (("设备", "电脑", "手机", "机器", "双机", "部署", "硬件"), ("MacBook", "Mac mini", "NAS", "iPhone Duo", "8650", "Syncthing")),
    (("微信", "群聊", "消息", "催回", "回复"), ("微信消息只作背景上下文", "催回", "野望", "高杰", "野哥")),
    (("邮件", "发信", "报销", "劳务", "发布", "发送", "提交"), ("停在按钮前", "发送", "提交", "发布")),
    (("方案", "选择", "哪个好", "选哪个", "对比", "取舍", "建议"), ("倾向建议", "投入产出比", "先给结论")),
    (("猫", "宠物", "家里", "家人", "伴侣", "对象"), ("Rui", "Logo", "高杰", "河南", "北京")),
    (("记账", "消费", "房租", "日历", "日程", "提醒"), ("ezbookkeeping", "招商银行", "居住房租", "【分类】标题", "LifeOS")),
    (("删除", "清理", "过期", "定位", "短信"), ("只转移不删除", "新鲜度", "48")),
)


def _validate_name(name: str) -> str:
    if not isinstance(name, str):
        raise ValueError("文件名必须为字符串")
    cleaned = name.strip()
    if cleaned not in ALLOWED_TRUTH_NAMES or "/" in cleaned or "\\" in cleaned or ".." in cleaned:
        raise ValueError(f"仅允许读写 MEMORY.md 或 SOUL.md，非法文件名: {name!r}")
    return cleaned


def resolve_truth_dir(state_dir: Path | str | None = None) -> Path:
    """解析真相文件目录；测试环境或非线上自定义 state_dir 自动隔离，绝不污染真实 `_global/记忆库/Com/`。"""
    env_override = os.environ.get("COM_MEMORY_TRUTH_DIR", "").strip()
    if env_override:
        return Path(env_override)

    in_pytest = bool(os.environ.get("PYTEST_CURRENT_TEST")) or os.environ.get("COM_TRUTH_ISOLATED") == "1"
    live_truth = os.environ.get("COM_USE_LIVE_TRUTH") == "1"

    if state_dir is not None:
        st_path = Path(state_dir)
        try:
            is_live_state = st_path.resolve() == LIVE_WORKBENCH_STATE.resolve()
        except OSError:
            is_live_state = False
        if (in_pytest and not live_truth) or not is_live_state:
            return st_path / "com-memory-truth"
        return DEFAULT_TRUTH_DIR

    # state_dir is None
    default_unpatched = DEFAULT_TRUTH_DIR == (Path(memory.ROOT) / "_global/记忆库/Com")
    if in_pytest and not live_truth and default_unpatched:
        test_key = re.sub(r"[^A-Za-z0-9_.-]+", "_", os.environ.get("PYTEST_CURRENT_TEST", "pytest"))[:80]
        return Path(tempfile.gettempdir()) / f"com-truth-pytest-{os.getpid()}" / test_key
    return DEFAULT_TRUTH_DIR


def sanitize_truth_content(content: str) -> tuple[str, list[str]]:
    """逐行并跨代码块拦截命中 `memory.SENSITIVE` 的内容，返回 `(clean_text, sanitized_lines)`。"""
    raw = str(content or "").replace("\r\n", "\n").replace("\r", "\n")
    lines = raw.split("\n")
    kept: list[str] = []
    sanitized_lines: list[str] = []

    in_fence = False
    fence_marker = ""
    fence_buf: list[tuple[int, str]] = []

    for idx, line in enumerate(lines, start=1):
        stripped = line.lstrip()
        if stripped.startswith(("```", "~~~")):
            marker = stripped[:3]
            if not in_fence:
                in_fence = True
                fence_marker = marker
                fence_buf = [(idx, line)]
                continue
            if marker == fence_marker:
                fence_buf.append((idx, line))
                block_text = "\n".join(ln for _, ln in fence_buf)
                if SENSITIVE.search(block_text):
                    first_ln = fence_buf[0][0]
                    last_ln = fence_buf[-1][0]
                    sanitized_lines.append(f"L{first_ln}-L{last_ln}: [已拦截含敏感词代码块]")
                else:
                    kept.extend(ln for _, ln in fence_buf)
                in_fence = False
                fence_marker = ""
                fence_buf = []
                continue

        if in_fence:
            fence_buf.append((idx, line))
            continue

        if SENSITIVE.search(line):
            sanitized_lines.append(f"L{idx}: [已拦截含敏感词行]")
            continue
        kept.append(line)

    if fence_buf:
        for f_idx, f_line in fence_buf:
            if SENSITIVE.search(f_line):
                sanitized_lines.append(f"L{f_idx}: [已拦截含敏感词行]")
            else:
                kept.append(f_line)

    # 防御性二次校验：确保落盘文本 0 行命中 SENSITIVE
    final_lines: list[str] = []
    for idx, line in enumerate(kept, start=1):
        if SENSITIVE.search(line):
            sanitized_lines.append(f"L{idx}: [已拦截含敏感词行]")
            continue
        final_lines.append(line)

    cleaned = "\n".join(final_lines).strip()
    if cleaned:
        cleaned += "\n"
    return cleaned, sanitized_lines


def _atomic_write_text(target: Path, content: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    resolved_dir = target.parent.resolve()
    resolved_target = (resolved_dir / target.name).resolve()
    if resolved_target.parent != resolved_dir:
        raise ValueError(f"检测到非法路径穿越: {target}")

    for line in content.splitlines():
        if SENSITIVE.search(line):
            raise ValueError("写入真相层失败：检测到未脱敏的敏感词")

    tmp = resolved_dir / f".{target.name}.tmp.{os.getpid()}.{secrets.token_hex(4)}"
    try:
        tmp.write_text(content, encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, resolved_target)
        os.chmod(resolved_target, 0o600)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass


def ensure_truth_files(state_dir: Path | str | None = None) -> Path:
    """确保目标真相目录中存在合法且无敏感词的 `MEMORY.md` 与 `SOUL.md`。"""
    truth_dir = resolve_truth_dir(state_dir)
    truth_dir.mkdir(parents=True, exist_ok=True)
    for name, _title in TRUTH_FILE_SPECS:
        fpath = truth_dir / name
        if not fpath.is_file():
            seed_source = DEFAULT_TRUTH_DIR / name
            if truth_dir != DEFAULT_TRUTH_DIR and seed_source.is_file():
                raw_seed = seed_source.read_text(encoding="utf-8")
            else:
                raw_seed = DEFAULT_CONTENT_BY_NAME[name]
            clean_seed, _ = sanitize_truth_content(raw_seed)
            _atomic_write_text(fpath, clean_seed)
    return truth_dir


def _read_truth_pair_readonly(state_dir: Path | str | None = None) -> tuple[str, str]:
    """只读读取 `(memory_md, soul_md)`，对尚未初始化的临时 `state_dir` 不产生磁盘写入副作用。"""
    truth_dir = resolve_truth_dir(state_dir)
    out: dict[str, str] = {}
    for name in ("MEMORY.md", "SOUL.md"):
        candidate = truth_dir / name
        if candidate.is_file():
            try:
                raw = candidate.read_text(encoding="utf-8")
                clean, _ = sanitize_truth_content(raw)
                out[name] = clean
                continue
            except OSError:
                pass
        live_fallback = DEFAULT_TRUTH_DIR / name
        if live_fallback.is_file():
            try:
                clean, _ = sanitize_truth_content(live_fallback.read_text(encoding="utf-8"))
                out[name] = clean
                continue
            except OSError:
                pass
        clean_default, _ = sanitize_truth_content(DEFAULT_CONTENT_BY_NAME[name])
        out[name] = clean_default
    return out["MEMORY.md"], out["SOUL.md"]


def get_truth_files(state_dir: Path | None = None) -> dict[str, Any]:
    """读取 `MEMORY.md` 与 `SOUL.md` 元信息与全文，供 API 与 iOS 记忆页直接展示编辑。"""
    truth_dir = ensure_truth_files(state_dir)
    files: list[dict[str, Any]] = []
    for name, title in TRUTH_FILE_SPECS:
        fpath = truth_dir / name
        raw = fpath.read_text(encoding="utf-8")
        clean, stripped = sanitize_truth_content(raw)
        if stripped:
            _atomic_write_text(fpath, clean)
        st = fpath.stat()
        files.append(
            {
                "name": name,
                "title": title,
                "content": clean,
                "updated_at": float(st.st_mtime),
                "line_count": len(clean.splitlines()),
            }
        )
    return {"ok": True, "files": files}


def update_truth_file(name: str, content: str, state_dir: Path | None = None) -> dict[str, Any]:
    """原子更新 `MEMORY.md` 或 `SOUL.md`，拦截路径穿越并自动剥离命中 `SENSITIVE` 的行。"""
    valid_name = _validate_name(name)
    truth_dir = ensure_truth_files(state_dir)
    fpath = truth_dir / valid_name
    clean_content, sanitized_lines = sanitize_truth_content(content)
    _atomic_write_text(fpath, clean_content)
    st = fpath.stat()
    return {
        "ok": True,
        "name": valid_name,
        "title": TRUTH_TITLES[valid_name],
        "content": clean_content,
        "updated_at": float(st.st_mtime),
        "line_count": len(clean_content.splitlines()),
        "sanitized_lines": sanitized_lines,
    }


def _strip_bullet_prefix(line: str) -> str:
    return re.sub(r"^\s*[-*•]\s*", "", line).strip()


def _plain_for_match(line: str) -> str:
    return _MD_DECORATION_RE.sub("", _strip_bullet_prefix(line)).strip().lower()


def forget_truth_entry(target: str, name: str = "MEMORY.md", state_dir: Path | None = None) -> dict[str, Any]:
    """按精确行文本或关键词子串移除对应 bullet 条目并原子写回。"""
    valid_name = _validate_name(name)
    needle_raw = str(target or "").strip()
    if not needle_raw:
        raise ValueError("缺少要遗忘的目标文本或关键词")

    truth_dir = ensure_truth_files(state_dir)
    fpath = truth_dir / valid_name
    current = fpath.read_text(encoding="utf-8")
    lines = current.splitlines()

    needle_body = _strip_bullet_prefix(needle_raw)
    needle_plain = _plain_for_match(needle_raw)

    # 优先精确匹配整行或 bullet 正文；未命中时回退到非标题行的子串关键词匹配
    exact_indices: set[int] = set()
    substring_indices: set[int] = set()

    for idx, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        body = _strip_bullet_prefix(stripped)
        plain = _plain_for_match(stripped)
        if stripped == needle_raw or body == needle_body or (needle_plain and plain == needle_plain):
            exact_indices.add(idx)
        elif needle_plain and needle_plain in plain:
            is_bullet = stripped.startswith(("-", "*", "•"))
            if is_bullet or not any(ln.lstrip().startswith(("-", "*", "•")) for ln in lines):
                substring_indices.add(idx)

    to_remove = exact_indices if exact_indices else substring_indices
    removed_lines = [lines[i] for i in sorted(to_remove)]
    kept_lines = [line for idx, line in enumerate(lines) if idx not in to_remove]

    collapsed: list[str] = []
    blank_run = 0
    for ln in kept_lines:
        if not ln.strip():
            blank_run += 1
            if blank_run <= 1:
                collapsed.append("")
        else:
            blank_run = 0
            collapsed.append(ln)

    new_content, _ = sanitize_truth_content("\n".join(collapsed))
    if to_remove:
        _atomic_write_text(fpath, new_content)
    st = fpath.stat()
    return {
        "ok": True,
        "name": valid_name,
        "title": TRUTH_TITLES[valid_name],
        "removed_count": len(removed_lines),
        "removed_lines": removed_lines,
        "content": new_content,
        "updated_at": float(st.st_mtime),
        "line_count": len(new_content.splitlines()),
    }


def should_skip_truth_header(user_text: str | None) -> bool:
    """寒暄与极短应答跳过真相层注入，保持极速响应与最小上下文。"""
    if user_text is None:
        return False
    if should_skip_auto_recall(user_text):
        return True
    if _GREETING_ONLY_RE.match(user_text.strip()):
        return True
    return False


def _extract_active_bullets(markdown_text: str, source_tag: str) -> list[tuple[str, str, str]]:
    """提取非 `_archive` 区块的条目，返回 `(source_tag, section_name, compact_bullet)`。"""
    out: list[tuple[str, str, str]] = []
    section = ""
    in_archive = False
    for raw_line in markdown_text.splitlines():
        stripped = raw_line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            heading = stripped.lstrip("#").strip()
            section = heading
            low_h = heading.lower()
            in_archive = ("_archive" in low_h) or ("归档" in low_h)
            continue
        if in_archive:
            continue
        if stripped.startswith("<!--") and stripped.endswith("-->"):
            continue
        if SENSITIVE.search(stripped):
            continue
        body = _MD_DECORATION_RE.sub("", _strip_bullet_prefix(stripped))
        body = re.sub(r"\s+", " ", body).strip()
        if body and not SENSITIVE.search(body):
            out.append((source_tag, section, f"- {body}"))
    return out


def _score_bullet_for_query(bullet_entry: tuple[str, str, str], index: int, total: int, user_text: str | None) -> tuple[int, int]:
    source_tag, section, line = bullet_entry
    low_line = line.lower()
    score = 0

    # SOUL 分寸红线与核心身份具备稳定基础权重
    if source_tag == "SOUL":
        score += 6
    elif "核心身份" in section:
        score += 5
    elif "新学" in section or "捕获" in section or "近期" in section:
        score += 4

    if user_text:
        q_low = user_text.lower()
        words = re.findall(r"[a-z0-9_]{2,}|[\u4e00-\u9fff]{2,}", q_low)
        terms: set[str] = set()
        for w in words:
            if re.fullmatch(r"[\u4e00-\u9fff]+", w):
                if len(w) <= 4:
                    terms.add(w)
                for i in range(len(w) - 1):
                    terms.add(w[i : i + 2])
            else:
                terms.add(w)
        for triggers, expansions in _QUERY_SYNONYMS:
            if any(t in q_low for t in triggers):
                terms.update(e.lower() for e in expansions)
        for term in terms:
            if len(term) >= 2 and term in low_line:
                score += len(term) * 3

    # 次级排序保持原文稳定顺序（同分时优先靠前核心条目与最新追加条目）
    recency_tie = -(index if index < 2 else (total - index if "近期" in section else index))
    return score, -index if recency_tie == 0 else recency_tie


def truth_prompt_header(
    state_dir: Path | None = None,
    max_chars: int = 800,
    *,
    user_text: str | None = None,
) -> str:
    """生成紧凑真相层摘要（默认 `<= 800` 字），寒暄自动返回空串。"""
    if max_chars <= len(TRUTH_PROMPT_TAG) + 8:
        return ""
    if should_skip_truth_header(user_text):
        return ""

    mem_md, soul_md = _read_truth_pair_readonly(state_dir)
    all_entries = _extract_active_bullets(mem_md, "MEMORY") + _extract_active_bullets(soul_md, "SOUL")
    if not all_entries:
        return ""

    # 若全部紧凑条目可直接放入预算，按原顺序完整保留 100% 真相条目
    full_candidate = TRUTH_PROMPT_TAG + "\n" + "\n".join(line for _, _, line in all_entries)
    if len(full_candidate) <= max_chars:
        return full_candidate

    # 超出预算时（如 MEMORY.md 累积至 1800 字），按本轮问题相关性 + 红线权重挑选后再恢复阅读顺序
    total = len(all_entries)
    ranked_indices = sorted(
        range(total),
        key=lambda idx: _score_bullet_for_query(all_entries[idx], idx, total, user_text),
        reverse=True,
    )

    chosen_indices: list[int] = []
    used = len(TRUTH_PROMPT_TAG)
    for idx in ranked_indices:
        line = all_entries[idx][2]
        if used + 1 + len(line) <= max_chars:
            chosen_indices.append(idx)
            used += 1 + len(line)
        elif not chosen_indices:
            avail = max_chars - used - 2
            if avail > 12:
                clipped = line[:avail].rstrip() + "…"
                if not SENSITIVE.search(clipped):
                    return f"{TRUTH_PROMPT_TAG}\n{clipped}"

    if not chosen_indices:
        return ""
    chosen_indices.sort()
    lines = [all_entries[i][2] for i in chosen_indices]
    result = TRUTH_PROMPT_TAG + "\n" + "\n".join(lines)
    return result[:max_chars]
