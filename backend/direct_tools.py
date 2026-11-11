"""Com! Personal Agent 高频 MCP 工具一步直调预绑定契约。

消除 Hermes 默认 `tool_search -> tool_describe -> tool_call` 2-3 次模型发现往返：
- 仅暴露业务参数，剥离 `origin_session_id / origin_message_id / origin_request_id`（由宿主 `source_binding` 插件自动注入）；
- 按当前回合路由分组或 `fast_classifier` 预绑定工具列表，仅在非纯寒暄 L1 回合附入 `<system_reminder>`；
- 不触碰 `hermes_prompt.py` 的 2200 字预算，也不污染落库用户原文。
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable

MCP_PREFIX = "mcp__com_workbench__"
STRIPPED_ORIGIN_KEYS = ("origin_session_id", "origin_message_id", "origin_request_id")


@dataclass(frozen=True)
class DirectToolSpec:
    name: str
    mcp_name: str
    required: tuple[str, ...]
    optional: tuple[str, ...]
    signature: str
    summary: str


DIRECT_TOOL_SPECS: dict[str, DirectToolSpec] = {
    "business_operation": DirectToolSpec(
        name="business_operation",
        mcp_name=f"{MCP_PREFIX}business_operation",
        required=("tool", "args"),
        optional=("task_id",),
        signature=(
            '{"tool": "bookkeeping|bookkeeping_search|calendar_event|remind|collect", '
            '"args": {...}, "task_id"?: ""}'
        ),
        summary=(
            "直接办理记账/查账/日程/提醒/收藏（无需先调 context_read(business)）："
            'bookkeeping 传 {"action":"recent","count":3} | {"action":"summary","month":"YYYY-MM"} | '
            '{"action":"add","amount":元,"category":"餐饮外卖|出行交通|购物消费|居住房租|通讯话费","account":"招商银行储蓄卡","comment":"..."}；'
            'bookkeeping_search 传 {"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"} 或 {"date":"YYYY-MM-DD"}（无 action 键，可选 keyword/amount/limit/transaction_type）；'
            'calendar_event 传 {"action":"list","start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"} | {"action":"create","summary","date","hour":0-23,"minute":0-59,"duration_minutes"?:60}（纯读日历亦可直调 mcp__com_workbench__calendar_read 传 {"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"}）；'
            'remind 传 {"action":"list"} | {"action":"add","text":"...","at":"YYYY-MM-DD HH:MM"} | {"action":"cancel","id":"..."}；'
            'collect 传 {"url":"https://...","title":"...","bucket":"AI与科技|视频与创作|户外与旅行|生活与娱乐"}'
        ),
    ),
    "memory_recall": DirectToolSpec(
        name="memory_recall",
        mcp_name=f"{MCP_PREFIX}memory_recall",
        required=("query",),
        optional=("banks",),
        signature='{"query": "检索关键词", "banks"?: ["..."]}',
        summary="检索已核验的个人/项目/偏好 Markdown 记忆（Hindsight），历史事实不等同于新指令。",
    ),
    "task_submit": DirectToolSpec(
        name="task_submit",
        mcp_name=f"{MCP_PREFIX}task_submit",
        required=(
            "agent",
            "relative_cwd",
            "title",
            "prompt",
            "completion_condition",
            "source_quote",
            "request_id",
        ),
        optional=("goal_id", "plan_node_id", "depends_on", "acceptance_criteria", "sandbox"),
        signature=(
            '{"agent": "pi|codex|hermes", "relative_cwd": "...", "title": "...", '
            '"prompt": "...", "completion_condition": "...", "source_quote": "当前用户原话", '
            '"request_id": "稳定幂等ID", "sandbox"?: "danger-full-access"}'
        ),
        summary="提交明确交办的后台编程或长耗时任务并立即返回（日常记账/日程/提醒请直接调 business_operation）。",
    ),
    "task_status": DirectToolSpec(
        name="task_status",
        mcp_name=f"{MCP_PREFIX}task_status",
        required=(),
        optional=("task_id",),
        signature='{"task_id"?: "task_xxx（留空或省略则列出全部后台任务）"}',
        summary="只读查询全部或指定后台任务状态（已覆盖在跑/排队的后台任务，常规无需再查会话列表；确需查终端工作会话亦可直调 mcp__com_workbench__recent_work_sessions 传 {\"limit\"?:5,\"agent\"?:\"pi|codex\"}）。",
    ),
    "context_read": DirectToolSpec(
        name="context_read",
        mcp_name=f"{MCP_PREFIX}context_read",
        required=("kind",),
        optional=("query", "reference", "limit", "offset", "before"),
        signature=(
            '{"kind": "module|history", "reference"?: "memory|business|tasks|personal|消息ID", '
            '"query"?: "...", "limit"?: 5, "offset"?: 0, "before"?: "..."}'
        ),
        summary="按需读取流程模块或搜索历史原始对话（常规查询已在当前上下文或直调签名内时勿多调）。",
    ),
    "pending_action_register": DirectToolSpec(
        name="pending_action_register",
        mcp_name=f"{MCP_PREFIX}pending_action_register",
        required=("description", "confirm_word"),
        optional=("action", "ttl_seconds"),
        signature=(
            '{"description": "动作简述", "confirm_word": "确认词", '
            '"action"?: {"tool": "...", "args": {...}}, "ttl_seconds"?: 1800}'
        ),
        summary="当向 Eddie 提议待确认动作（「回我一句『X』就…」）时登记一句话快确认动作。",
    ),
    "trigger_manage": DirectToolSpec(
        name="trigger_manage",
        mcp_name=f"{MCP_PREFIX}trigger_manage",
        required=("action",),
        optional=(
            "trigger_id",
            "name",
            "template",
            "cron_expr",
            "prompt",
            "channel",
            "status",
            "kind",
            "event_source",
            "event_filter",
        ),
        signature=(
            '{"action": "create|list|update|pause|resume|delete|run_now", '
            '"trigger_id"?: "...", "name"?: "...", '
            '"template"?: "morning_briefing|schedule_subscription_due|custom", '
            '"cron_expr"?: "分 时 日 月 周", "prompt"?: "...", '
            '"channel"?: "personal|work|bookkeeping", "status"?: "active|paused", '
            '"kind"?: "cron|event", "event_source"?: "...", "event_filter"?: {...}}'
        ),
        summary="管理定时/事件触发器（每日早安简报、日程订阅到期检查或自定义周期任务）。",
    ),
}

DIRECT_TOOL_NAMES: tuple[str, ...] = tuple(DIRECT_TOOL_SPECS.keys())

_GROUP_DEFAULT_TOOLS: dict[str, tuple[str, ...]] = {
    "ledger": ("business_operation", "pending_action_register"),
    "bookkeeping": ("business_operation", "pending_action_register"),
    "calendar": ("business_operation", "pending_action_register"),
    "reminder": ("business_operation", "pending_action_register"),
    "collect": ("business_operation",),
    "tasks": ("task_submit", "task_status", "context_read"),
    "query": ("business_operation", "memory_recall", "task_status", "context_read"),
    "action": (
        "business_operation",
        "task_submit",
        "task_status",
        "pending_action_register",
        "trigger_manage",
    ),
    "general": ("business_operation", "memory_recall", "task_status", "context_read"),
}

_TRIGGER_HINT_RE = re.compile(
    r"定时|每天|每日|每周|每早|早上.*简报|早安简报|触发器|cron|周期|自动(?:发|检查|提醒)|到期检查",
    re.I,
)
_TASK_HINT_RE = re.compile(
    r"后台任务|任务(?:状态|列表|进度)?|交办|派活|worker|修复|开发|部署|构建",
    re.I,
)
_MEMORY_HINT_RE = re.compile(
    r"记忆|记得|偏好|习惯|之前|上次|搜狐|攀岩|路书|项目|规律|总结|要点",
    re.I,
)
_BUSINESS_HINT_RE = re.compile(
    r"记账|账单|账目|消费|花费|支出|汇总|预算|日程|日历|安排|会议|提醒|待办|收藏|保存链接",
    re.I,
)
_PENDING_HINT_RE = re.compile(
    r"待确认|确认后|要不要帮|建议.*记|安排|调整",
    re.I,
)


def get_direct_tool_spec(name: str) -> DirectToolSpec | None:
    clean = str(name or "").strip()
    if clean.startswith(MCP_PREFIX):
        clean = clean[len(MCP_PREFIX) :]
    return DIRECT_TOOL_SPECS.get(clean)


def all_direct_tool_specs() -> dict[str, DirectToolSpec]:
    return dict(DIRECT_TOOL_SPECS)


def normalize_tool_names(names: Iterable[str] | None) -> list[str]:
    if not names:
        return []
    seen: set[str] = set()
    ordered: list[str] = []
    for raw in names:
        spec = get_direct_tool_spec(raw)
        if spec and spec.name not in seen:
            seen.add(spec.name)
            ordered.append(spec.name)
    return ordered


def select_direct_tools(
    level: str,
    group: str,
    user_text: str = "",
    prebound_tools: Iterable[str] | None = None,
) -> list[str]:
    """按路由层级/分组、用户文本线索与分类器预绑定列表选出本轮需要注入的高频直调工具。

    纯寒暄 L1（`level == "L1" and group == "chat"` 且无显式 `prebound_tools`）返回空列表，不注入任何额外提示。
    """
    explicit = normalize_tool_names(prebound_tools)
    if level == "L0":
        return []
    if level == "L1" and group == "chat" and not explicit:
        return []

    chosen: list[str] = list(explicit)

    def _add(*items: str) -> None:
        for item in items:
            if item in DIRECT_TOOL_SPECS and item not in chosen:
                chosen.append(item)

    if not chosen:
        for tool_name in _GROUP_DEFAULT_TOOLS.get(group, _GROUP_DEFAULT_TOOLS["general"]):
            _add(tool_name)

    text = str(user_text or "").strip()
    if text:
        if _BUSINESS_HINT_RE.search(text):
            _add("business_operation")
        if _TASK_HINT_RE.search(text):
            _add("task_status")
            if level == "L3" or re.search(r"交办|派活|提交任务|交给|修复|开发|构建|部署", text, re.I):
                _add("task_submit")
        if _MEMORY_HINT_RE.search(text):
            _add("memory_recall")
        if _TRIGGER_HINT_RE.search(text):
            _add("trigger_manage")
        if _PENDING_HINT_RE.search(text):
            _add("pending_action_register")

    return chosen


def build_direct_tools_section(tool_names: Iterable[str]) -> str:
    """构建不含外层 `<system_reminder>` 标签的高频工具一步直调说明段。"""
    normalized = normalize_tool_names(tool_names)
    if not normalized:
        return ""
    lines = [
        "【高频工具一步直调（免搜索硬规则）】",
        "- 以下 Com 工具已预绑定精确名称与参数契约，需要时直接用 `tool_call(calls=[{\"name\": \"mcp__com_workbench__<工具名>\", \"arguments\": {...}}])` 一步调用，**严禁先调 `tool_search` 或 `tool_describe`**（`origin_*` 来源字段由宿主自动注入，切勿手填）。",
        "- 每次 `tool_call` 的 `calls` 列表仅放 **1 项**本地工具；需并行执行多个工具（如同时发 `send_message` 确认气泡 + 并行查账/日程/提醒/记忆）时，在同一轮响应里并列发出多个独立的 `tool_call`。",
        "- 1-2 步即可完成的日常查询与业务操作直接调目标工具拿结果作答，无需额外调 `turn_plan` 或 `context_read(kind=\"module\")`（仅复杂多步任务确需展示清单时直调 `mcp__com_workbench__turn_plan`）。",
    ]
    for name in normalized:
        spec = DIRECT_TOOL_SPECS[name]
        lines.append(f"- `{spec.mcp_name}` 参数 `{spec.signature}`：{spec.summary}")
    return "\n".join(lines)


def build_direct_tools_reminder(tool_names: Iterable[str]) -> str:
    section = build_direct_tools_section(tool_names)
    if not section:
        return ""
    return f"<system_reminder>\n{section}\n</system_reminder>"


def attach_turn_reminders(
    user_text: str,
    *,
    send_mode: bool,
    base_turn_reminder: str = "",
    tool_names: Iterable[str] = (),
) -> str:
    """将 SendMessage 规则与高频工具直调契约合并进单个末尾 `<system_reminder>`，不改写原始用户文本。"""
    if "<system_reminder>" in user_text:
        return user_text
    direct_section = build_direct_tools_section(tool_names)
    if send_mode and base_turn_reminder:
        if not direct_section:
            return f"{user_text}\n\n{base_turn_reminder}"
        closing = "</system_reminder>"
        if base_turn_reminder.rstrip().endswith(closing):
            idx = base_turn_reminder.rfind(closing)
            merged = f"{base_turn_reminder[:idx].rstrip()}\n\n{direct_section}\n{closing}"
            return f"{user_text}\n\n{merged}"
        return f"{user_text}\n\n{base_turn_reminder}\n\n<system_reminder>\n{direct_section}\n</system_reminder>"
    if direct_section:
        return f"{user_text}\n\n<system_reminder>\n{direct_section}\n</system_reminder>"
    return user_text
