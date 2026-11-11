"""回合前轻量意图与预绑定工具分类器（对标 OpenMausBot / Muse Ember 快决策通道）。

设计契约：
- 仅在 `SuperagentFlags(state).fast_classifier_on()` 开启且未命中确定性 `L0` 时触发；
- 优先使用环境变量 `COM_FAST_CLASSIFIER_MODEL`，默认走本地 Magpie `:3425` 的 GCP Vertex 极速模型 `vertex-948/gemini-3.5-flash-lite`（上游 4xx/不可用时进程内自动降级 `auto/gemini-3.8-flash` -> `message_router.fast_model()`）；
- HTTP 超时 `0.65s`、`asyncio.wait_for` 硬时限 `0.72s`；
- 仅当严格 JSON 合法且 `confidence >= 0.6` 时采纳，任何超时、网络异常、非法 JSON 或低置信度均无感回退至 `MessageRouter.decide()`，绝不阻塞主回合；
- 每次调用落一行 `0600` 权限审计日志至 `Path(state) / "fast-classifier.ndjson"`。
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable

import httpx

from direct_tools import DIRECT_TOOL_NAMES, normalize_tool_names

ALLOWED_INTENTS = frozenset({"chat", "query", "action", "bookkeeping"})
ALLOWED_LEVELS = frozenset({"L1", "L2", "L3"})
CONFIDENCE_THRESHOLD = 0.6
HTTP_TIMEOUT_SECONDS = 0.65
HARD_TIMEOUT_SECONDS = 0.72
DEFAULT_FAST_MODEL = "vertex-948/gemini-3.5-flash-lite"
FALLBACK_FAST_MODEL = "auto/gemini-3.8-flash"
DEFAULT_MAGPIE_BASE_URL = "http://127.0.0.1:3425/v1"
PI_MODELS_PATH = Path.home() / ".pi" / "agent" / "models.json"

_DEGRADED_MODELS: set[str] = set()

_FENCE_RE = re.compile(r"^\s*```(?:json)?\s*(.*?)\s*```\s*$", re.S | re.I)

CLASSIFIER_SYSTEM_PROMPT = (
    "你是 Com 个人助理回合前路由分类器。只根据用户当前一句话做意图与高频工具预绑定判断，不回答问题，不调用工具。\n"
    "只输出一个严格合法的 JSON 对象，格式固定为：\n"
    '{"intent":"chat|query|action|bookkeeping","confidence":0.0,"tools":[],"level":"L1|L2|L3"}\n'
    "规则：\n"
    "- intent: 纯寒暄/闲聊选 chat；查信息/查记忆/查日程提醒选 query；记账/查账/预算选 bookkeeping；执行操作/设触发器/派发后台任务选 action。\n"
    f"- tools: 仅从 {list(DIRECT_TOOL_NAMES)} 中挑选本轮高概率需要的 0..4 个工具名；chat 传 []。\n"
    "- level: 简单寒暄或单步轻量查询选 L1；多步日常查询/业务操作选 L2；需要派发后台代码开发/修复/部署任务选 L3。\n"
    "- confidence: 0.0 到 1.0 之间的浮点数；语义含糊或不确定时给 < 0.6。"
)

ClassifierCaller = Callable[[str, float], Awaitable[str | dict[str, Any]]]


@dataclass(frozen=True)
class FastClassification:
    intent: str = ""
    confidence: float = 0.0
    tools: list[str] = field(default_factory=list)
    level: str = ""
    accepted: bool = False
    fallback: str = ""
    elapsed_ms: float = 0.0


def reset_degraded_models() -> None:
    """清空进程内已标记降级的快分类模型集合（供测试与恢复探测使用）。"""
    _DEGRADED_MODELS.clear()


def degraded_models() -> list[str]:
    return sorted(_DEGRADED_MODELS)


def _candidate_models() -> list[str]:
    from message_router import fast_model

    configured = fast_model()
    env_override = os.environ.get("COM_FAST_CLASSIFIER_MODEL", "").strip()
    configured_model = str(configured.get("model") or "").strip()
    raw_chain = [
        env_override,
        DEFAULT_FAST_MODEL,
        FALLBACK_FAST_MODEL,
        configured_model,
    ]
    unique: list[str] = []
    for item in raw_chain:
        if item and item not in unique:
            unique.append(item)
    healthy = [m for m in unique if m not in _DEGRADED_MODELS]
    degraded = [m for m in unique if m in _DEGRADED_MODELS]
    return healthy + degraded


def _resolve_magpie_endpoint(models_path: Path | None = None) -> tuple[str, str, str]:
    """读取快分类首选模型名称与本地 Magpie 地址，支持环境变量覆盖与进程内 4xx 降级记忆。"""
    candidates = _candidate_models()
    model_name = candidates[0] if candidates else DEFAULT_FAST_MODEL
    base_url = os.environ.get("COM_FAST_CLASSIFIER_BASE_URL", "").strip()
    api_key = ""
    target_models = models_path or PI_MODELS_PATH
    try:
        raw = json.loads(target_models.read_text(encoding="utf-8"))
        magpie = ((raw.get("providers") or {}).get("magpie")) or {}
        if not base_url:
            base_url = str(magpie.get("baseUrl") or "").strip()
        api_key = str(magpie.get("apiKey") or "").strip()
    except (OSError, ValueError, TypeError):
        pass
    if not base_url:
        base_url = DEFAULT_MAGPIE_BASE_URL
    return model_name, base_url.rstrip("/"), api_key


def _parse_strict_payload(raw: str | dict[str, Any]) -> tuple[dict[str, Any] | None, str]:
    if isinstance(raw, dict):
        data = raw
    elif isinstance(raw, str):
        stripped = raw.strip()
        fenced = _FENCE_RE.match(stripped)
        if fenced:
            stripped = fenced.group(1).strip()
        if not stripped.startswith("{") or not stripped.endswith("}"):
            return None, "invalid_json"
        try:
            parsed = json.loads(stripped)
        except ValueError:
            return None, "invalid_json"
        if not isinstance(parsed, dict):
            return None, "invalid_json"
        data = parsed
    else:
        return None, "invalid_json"

    intent = data.get("intent")
    level = data.get("level")
    confidence = data.get("confidence")
    tools_raw = data.get("tools")

    if not isinstance(intent, str) or intent not in ALLOWED_INTENTS:
        return None, "invalid_schema"
    if not isinstance(level, str) or level not in ALLOWED_LEVELS:
        return None, "invalid_schema"
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        return None, "invalid_schema"
    conf_val = float(confidence)
    if not (0.0 <= conf_val <= 1.0):
        return None, "invalid_schema"
    if not isinstance(tools_raw, list) or any(not isinstance(item, str) for item in tools_raw):
        return None, "invalid_schema"

    tools = normalize_tool_names(tools_raw)
    if intent == "bookkeeping" and "business_operation" not in tools:
        tools = ["business_operation", *tools]
    if intent == "chat":
        tools = []

    return {
        "intent": intent,
        "confidence": round(conf_val, 4),
        "tools": tools,
        "level": level,
    }, ""


def append_classifier_log(
    state: Path,
    *,
    request_id: str,
    result: FastClassification,
) -> Path:
    state_dir = Path(state)
    state_dir.mkdir(parents=True, exist_ok=True)
    log_path = state_dir / "fast-classifier.ndjson"
    record = {
        "at": round(time.time(), 3),
        "request_id": str(request_id or ""),
        "elapsed_ms": round(float(result.elapsed_ms), 2),
        "intent": result.intent,
        "confidence": result.confidence,
        "tools": list(result.tools),
        "level": result.level,
        "accepted": bool(result.accepted),
        "fallback": result.fallback,
    }
    line = (json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)
    try:
        os.chmod(log_path, 0o600)
    except OSError:
        pass
    return log_path


async def _call_magpie(
    text: str,
    timeout_s: float,
    *,
    transport: httpx.AsyncBaseTransport | None = None,
    models_path: Path | None = None,
) -> str:
    _, base_url, api_key = _resolve_magpie_endpoint(models_path=models_path)
    candidates = _candidate_models() or [DEFAULT_FAST_MODEL]
    healthy_candidates = [m for m in candidates if m not in _DEGRADED_MODELS] or [candidates[0]]
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    deadline = time.monotonic() + timeout_s
    last_http_error: httpx.HTTPStatusError | None = None

    async with httpx.AsyncClient(
        timeout=httpx.Timeout(min(HTTP_TIMEOUT_SECONDS, timeout_s), connect=min(0.20, timeout_s)),
        trust_env=False,
        transport=transport,
    ) as client:
        for idx, model_name in enumerate(healthy_candidates):
            remaining = deadline - time.monotonic()
            if idx > 0 and remaining < 0.08:
                break
            req_timeout = httpx.Timeout(
                min(HTTP_TIMEOUT_SECONDS, max(0.05, remaining)),
                connect=min(0.20, max(0.05, remaining)),
            )
            body = {
                "model": model_name,
                "temperature": 0.0,
                "max_tokens": 160,
                "thinking": {"type": "disabled"},
                "response_format": {"type": "json_object"},
                "messages": [
                    {"role": "system", "content": CLASSIFIER_SYSTEM_PROMPT},
                    {"role": "user", "content": str(text or "")[:600]},
                ],
            }
            resp = await client.post(
                f"{base_url}/chat/completions",
                json=body,
                headers=headers,
                timeout=req_timeout,
            )
            if resp.status_code >= 400:
                err = httpx.HTTPStatusError(
                    f"magpie_status_{resp.status_code}",
                    request=resp.request,
                    response=resp,
                )
                last_http_error = err
                if 400 <= resp.status_code < 500:
                    _DEGRADED_MODELS.add(model_name)
                    if idx + 1 < len(healthy_candidates) and (deadline - time.monotonic()) >= 0.08:
                        continue
                raise err
            payload = resp.json()
            choices = payload.get("choices") if isinstance(payload, dict) else None
            if not isinstance(choices, list) or not choices:
                raise ValueError("missing_choices")
            message = choices[0].get("message") if isinstance(choices[0], dict) else None
            content = (message or {}).get("content")
            if not isinstance(content, str):
                raise ValueError("missing_content")
            return content

    if last_http_error is not None:
        raise last_http_error
    raise ValueError("no_available_classifier_model")


async def classify_fast(
    state: Path,
    request_id: str,
    text: str,
    *,
    timeout_s: float = HARD_TIMEOUT_SECONDS,
    caller: ClassifierCaller | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
    models_path: Path | None = None,
) -> FastClassification:
    """执行预分类并写入 NDJSON 审计日志；任何异常均捕获并标记 fallback。"""
    started = time.monotonic()
    effective_timeout = max(0.02, min(HARD_TIMEOUT_SECONDS, float(timeout_s)))

    raw_output: str | dict[str, Any] | None = None
    fallback_reason = ""
    try:
        if caller is not None:
            caller_budget = min(0.48, effective_timeout)
            raw_output = await asyncio.wait_for(
                caller(str(text or ""), caller_budget),
                timeout=effective_timeout,
            )
        else:
            raw_output = await asyncio.wait_for(
                _call_magpie(
                    str(text or ""),
                    effective_timeout,
                    transport=transport,
                    models_path=models_path,
                ),
                timeout=effective_timeout,
            )
    except (asyncio.TimeoutError, TimeoutError, httpx.TimeoutException):
        fallback_reason = "timeout"
    except httpx.HTTPStatusError as exc:
        fallback_reason = f"http_{exc.response.status_code}"
    except httpx.HTTPError:
        fallback_reason = "http_error"
    except ValueError:
        fallback_reason = "invalid_json"
    except Exception:
        fallback_reason = "classifier_error"

    elapsed_ms = round((time.monotonic() - started) * 1000, 2)
    if fallback_reason:
        result = FastClassification(
            accepted=False,
            fallback=fallback_reason,
            elapsed_ms=elapsed_ms,
        )
        append_classifier_log(state, request_id=request_id, result=result)
        return result

    parsed, parse_err = _parse_strict_payload(raw_output if raw_output is not None else "")
    if parse_err or parsed is None:
        result = FastClassification(
            accepted=False,
            fallback=parse_err or "invalid_json",
            elapsed_ms=elapsed_ms,
        )
        append_classifier_log(state, request_id=request_id, result=result)
        return result

    accepted = parsed["confidence"] >= CONFIDENCE_THRESHOLD
    result = FastClassification(
        intent=parsed["intent"],
        confidence=parsed["confidence"],
        tools=parsed["tools"],
        level=parsed["level"],
        accepted=accepted,
        fallback="" if accepted else "low_confidence",
        elapsed_ms=elapsed_ms,
    )
    append_classifier_log(state, request_id=request_id, result=result)
    return result
