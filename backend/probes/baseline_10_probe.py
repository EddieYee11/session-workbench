"""10 representative read-only prompts latency probe over real MessageRouter + HermesRuntime."""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import os
import sqlite3
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

BACKEND_DIR = Path(os.environ.get("COM_BACKEND_DIR") or Path(__file__).resolve().parent.parent)
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from business_tools import BusinessTools  # noqa: E402
from conversation import PersonalConversation  # noqa: E402
from hermes_runtime import HermesRuntime  # noqa: E402
from message_router import MessageRouter, receipt  # noqa: E402

PROMPTS: list[tuple[str, str, str]] = [
    ("记账1", "bookkeeping", "查一下最近的记账记录"),
    ("记账2", "bookkeeping", "帮我看看这个月一共花了多少钱，顺便列最近 3 笔消费"),
    ("记账3", "bookkeeping", "帮我搜一下最近 7 天有没有餐饮相关的消费记录"),
    ("闲聊1", "chat", "你好"),
    ("闲聊2", "chat", "今天忙了一整天有点累，陪我随便聊两句放松一下"),
    ("闲聊3", "chat", "你还记得我是做什么工作的、平时有什么运动习惯吗？"),
    ("办事1", "action", "帮我看看今天和明天的日程安排，有没有时间冲突？"),
    ("办事2", "action", "帮我列出当前未完成的提醒事项，再看一眼有没有正在跑的后台任务"),
    ("办事3", "action", "帮我检索一下之前关于搜狐户外或攀岩的记忆线索，整理成三条要点"),
    ("办事4", "action", "先帮我核对一下明天的日历安排和本月记账概况，再给我一句明天的行动建议"),
]


def _cleanup_probe_artifacts(
    state: Path,
    *,
    mid: str,
    req_id: str,
    run_id: str = "",
) -> None:
    convo_db = state / "personal-conversation.sqlite"
    if convo_db.exists():
        with sqlite3.connect(convo_db, timeout=20) as db:
            tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if "messages" in tables:
                db.execute("DELETE FROM messages WHERE id = ? OR parent_id = ? OR request_id = ?", (mid, mid, req_id))
            if "send_message_turns" in tables:
                db.execute("DELETE FROM send_message_turns WHERE turn_message_id = ? OR request_id = ?", (mid, req_id))
            if "send_message_thinking" in tables:
                db.execute("DELETE FROM send_message_thinking WHERE turn_message_id = ? OR request_id = ?", (mid, req_id))
            if "reaction_turns" in tables:
                db.execute("DELETE FROM reaction_turns WHERE message_id = ? OR request_id = ?", (mid, req_id))
            if "user_events" in tables:
                db.execute("DELETE FROM user_events WHERE message_id = ? OR request_id = ?", (mid, req_id))

    reactions_db = state / "reactions.sqlite"
    if reactions_db.exists():
        with sqlite3.connect(reactions_db, timeout=10) as db:
            tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if "reaction_turns" in tables:
                db.execute("DELETE FROM reaction_turns WHERE message_id = ? OR request_id = ?", (mid, req_id))
            if "reactions" in tables:
                db.execute("DELETE FROM reactions WHERE message_id = ?", (mid,))

    routing_db = state / "message-routing.sqlite"
    if routing_db.exists():
        with sqlite3.connect(routing_db, timeout=10) as db:
            db.execute("DELETE FROM decisions WHERE request_id = ?", (req_id,))

    runs_db = state / "hermes-runs.sqlite"
    if runs_db.exists():
        with sqlite3.connect(runs_db, timeout=10) as db:
            for tbl in ("runs", "context_requests", "tool_sources", "context_metrics", "steering"):
                db.execute(f"DELETE FROM {tbl} WHERE request_id = ? OR request_id LIKE ?", (req_id, f"{req_id}:%"))
            if run_id:
                db.execute("DELETE FROM run_events WHERE run_id = ?", (run_id,))


async def run_single_prompt(state: Path, label: str, category: str, text: str) -> dict[str, Any]:
    tag = uuid.uuid4().hex[:10]
    mid = "f0000000" + uuid.uuid4().hex[:24]  # 32-char hex required by ReactionStore
    req_id = f"probe10-req-{tag}"
    convo = PersonalConversation(state, HermesRuntime(state))
    main_session_id = convo._session_id() or "com-hermes-main"
    convo.task_environment = lambda: {
        "current_date": dt.datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y-%m-%d"),
        "timezone": "Asia/Shanghai",
        "host": "mini",
    }
    router = MessageRouter(state)
    started = time.monotonic()
    run_id = ""

    try:
        # Step 1: MessageRouter decision (and fast_classifier if enabled in router/runtime)
        if hasattr(router, "decide_async"):
            route = await router.decide_async(req_id, text)
        else:
            route = router.decide(req_id, text)

        if route.level == "L0":
            ctx = {
                "origin_request_id": req_id,
                "origin_message_id": mid,
                "origin_session_id": main_session_id,
                "conversation": convo,
            }
            res = await router.execute(route, ctx, BusinessTools(state))
            out_text = str(receipt(route, res))
            elapsed_ms = round((time.monotonic() - started) * 1000, 1)
            router.complete(req_id, elapsed_ms=elapsed_ms, first_text_ms=elapsed_ms, prompt_chars=0)
            return {
                "label": label,
                "category": category,
                "prompt": text,
                "route_level": route.level,
                "route_group": route.group,
                "model_tier": "L0_deterministic",
                "first_bubble_ms": elapsed_ms,
                "first_text_ms": elapsed_ms,
                "elapsed_ms": elapsed_ms,
                "tools": [route.tool] if route.tool else [],
                "tools_count": 1 if route.tool else 0,
                "discovery_calls": 0,
                "send_message_calls": 0,
                "snippet": out_text[:120].replace("\n", " "),
            }

        # Step 2: Real HermesRuntime.stream_chat turn on an isolated probe lane
        now_ts = time.time()
        with convo.db() as db:
            seq = convo._next_seq(db)
            db.execute(
                "INSERT INTO messages(id, request_id, role, text, status, phase, created_at, updated_at, message_seq) "
                "VALUES (?, ?, 'user', ?, 'running', 'thinking', ?, ?, ?)",
                (mid, req_id, text, now_ts, now_ts, seq),
            )
            row = db.execute("SELECT * FROM messages WHERE id = ?", (mid,)).fetchone()

        reaction_token = convo.reactions.open_turn(mid, main_session_id)
        if convo._send_message_enabled():
            convo.send_store.open_turn(mid, main_session_id, req_id)

        transport_text, _ctx = convo._pi_input(row, main_session_id, reaction_token)
        rt = HermesRuntime(state, session_id=main_session_id)
        rt.lane_suffix = f"-probe-{tag}"

        tools: list[str] = []
        first_bubble_ms: float | None = None
        first_stream_text_ms: float | None = None
        final_output = ""

        async for event, payload in rt.stream_chat(main_session_id, transport_text):
            if event == "run.started":
                run_id = str(payload.get("run_id") or "")
            elif event == "tool.started":
                tname = str(payload.get("tool_name") or payload.get("tool") or "")
                tools.append(tname)
                if (tname == "send_message" or tname.endswith("__send_message")) and first_bubble_ms is None:
                    first_bubble_ms = round((time.monotonic() - started) * 1000, 1)
            elif event == "tool.completed":
                tname = str(payload.get("tool_name") or payload.get("tool") or "")
                if (tname == "send_message" or tname.endswith("__send_message")) and first_bubble_ms is None:
                    first_bubble_ms = round((time.monotonic() - started) * 1000, 1)
            elif event in ("assistant.delta", "assistant.completed"):
                chunk = payload.get("delta") or payload.get("content") or payload.get("text")
                if chunk and first_stream_text_ms is None:
                    first_stream_text_ms = round((time.monotonic() - started) * 1000, 1)
                if event == "assistant.completed" and isinstance(payload.get("content"), str):
                    final_output = payload["content"]

        elapsed_ms = round((time.monotonic() - started) * 1000, 1)

        # Read recorded router & context metrics before cleanup
        router_first_ms = None
        router_elapsed_ms = None
        classify_ms = None
        with sqlite3.connect(state / "message-routing.sqlite", timeout=10) as db:
            drow = db.execute(
                "SELECT route, classify_ms, first_text_ms, elapsed_ms FROM decisions WHERE request_id = ?",
                (req_id,),
            ).fetchone()
            if drow:
                saved_rt = json.loads(drow[0])
                route_level = saved_rt.get("level", route.level)
                route_group = saved_rt.get("group", route.group)
                classify_ms = round(float(drow[1]), 2) if drow[1] is not None else None
                router_first_ms = round(float(drow[2]), 1) if drow[2] is not None else None
                router_elapsed_ms = round(float(drow[3]), 1) if drow[3] is not None else None
            else:
                route_level = route.level
                route_group = route.group

        model_tier = "unknown"
        ctx_metrics: dict[str, Any] = {}
        with sqlite3.connect(state / "hermes-runs.sqlite", timeout=10) as db:
            mrow = db.execute("SELECT data FROM context_metrics WHERE request_id = ?", (req_id,)).fetchone()
            if mrow:
                ctx_metrics = json.loads(mrow[0])
                model_tier = str(ctx_metrics.get("model_tier") or "unknown")

        # Read emitted bubbles text snippet if send_message produced child rows
        bubble_texts: list[str] = []
        with convo.db() as db:
            brows = db.execute(
                "SELECT text FROM messages WHERE parent_id = ? AND role = 'assistant' ORDER BY message_seq ASC",
                (mid,),
            ).fetchall()
            bubble_texts = [str(r["text"]) for r in brows if r["text"]]

        snippet_src = " | ".join(bubble_texts) if bubble_texts else final_output
        discovery_calls = sum(
            1 for t in tools if t in ("tool_search", "tool_describe") or t.endswith("__tool_search") or t.endswith("__tool_describe")
        )
        send_calls = sum(1 for t in tools if t == "send_message" or t.endswith("__send_message"))

        effective_first_bubble = first_bubble_ms or router_first_ms or first_stream_text_ms or elapsed_ms
        return {
            "label": label,
            "category": category,
            "prompt": text,
            "route_level": route_level,
            "route_group": route_group,
            "classify_ms": classify_ms,
            "model_tier": model_tier,
            "first_bubble_ms": effective_first_bubble,
            "router_first_text_ms": router_first_ms,
            "first_stream_text_ms": first_stream_text_ms,
            "elapsed_ms": router_elapsed_ms or elapsed_ms,
            "wall_elapsed_ms": elapsed_ms,
            "tools": tools,
            "tools_count": len(tools),
            "discovery_calls": discovery_calls,
            "send_message_calls": send_calls,
            "bubbles_emitted": len(bubble_texts),
            "memory_chars": ctx_metrics.get("memory_chars", 0),
            "assembly_ms": ctx_metrics.get("assembly_ms"),
            "prebound_tools": ctx_metrics.get("prebound_tools", []),
            "snippet": str(snippet_src)[:140].replace("\n", " "),
        }
    finally:
        _cleanup_probe_artifacts(state, mid=mid, req_id=req_id, run_id=run_id)


async def main() -> None:
    state = Path(os.environ.get("WORKBENCH_STATE") or (Path.home() / ".session-workbench"))
    out_file = os.environ.get("PROBE_OUT_JSON", "")
    results: list[dict[str, Any]] = []
    print("=== STARTING 10-PROMPT LATENCY PROBE ===", flush=True)
    for label, category, prompt in PROMPTS:
        try:
            item = await run_single_prompt(state, label, category, prompt)
            results.append(item)
            print(
                f"[{label}] route={item['route_level']}/{item['route_group']} tier={item['model_tier']} "
                f"first_bubble={item['first_bubble_ms']}ms router_first={item.get('router_first_text_ms')}ms "
                f"elapsed={item['elapsed_ms']}ms discovery={item['discovery_calls']} tools={item['tools']} "
                f"-> {item['snippet'][:60]}",
                flush=True,
            )
        except Exception as exc:
            err_item = {"label": label, "category": category, "prompt": prompt, "error": repr(exc)}
            results.append(err_item)
            print(f"[{label}] ERROR: {exc!r}", flush=True)

    summary = {
        "timestamp": dt.datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(),
        "env_flags": {
            k: os.environ.get(k, "")
            for k in (
                "COM_SEND_MESSAGE_MODE",
                "COM_FAST_CLASSIFIER_MODE",
                "COM_CHANNELS_MODE",
                "COM_TRIGGERS_MODE",
                "COM_VOICE_NARRATION_MODE",
            )
            if os.environ.get(k)
        },
        "results": results,
    }
    print("=== PROBE_JSON_BEGIN ===", flush=True)
    print(json.dumps(summary, ensure_ascii=False), flush=True)
    print("=== PROBE_JSON_END ===", flush=True)
    if out_file:
        Path(out_file).write_text(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
