"""Com! Live Voice (Realtime Audio-to-Audio) gateway over Vertex AI Gemini Live API,
OpenAI Realtime API, and Mock test engine.

Features:
- LiveUpstreamAdapter base class with:
  - GeminiLiveAdapter: Vertex AI BidiGenerateContent, 16kHz PCM in, 24kHz PCM out,
    server VAD interrupted: true, dual-project GCP failover, bidirectional transcripts.
  - OpenAIRealtimeAdapter: Fallback route specification and framing.
  - MockLiveAdapter: Fully deterministic offline adapter for 100% reliable test automation.
  - LegacyUpstreamAdapterWrapper: Backwards-compatible bridge for legacy custom test fixtures.
- Generation Epoch Fencing:
  - Tracks active epoch_id per WebSocket connection.
  - On barge-in interrupt (client {"type": "interrupt"} or server VAD {"type": "interrupted"}),
    increments epoch_id and purges queued and in-flight audio frames tagged with older epochs.
- Standardized JSON control envelopes (transcript, tool_call, emotion, ready, interrupted, turn_complete)
  alongside binary 24kHz PCM audio frames.
- Personal Agent tool calling (bookkeeping, calendar, reminders, next steps, memory recall, background dispatch).
- Durable persistence of completed turns into PersonalConversation.
"""
from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import hmac
import inspect
import json
import os
import subprocess
import threading
import time
import uuid
from abc import ABC, abstractmethod
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, AsyncIterator, Callable
from zoneinfo import ZoneInfo

import httpx
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

import fast_bookkeeping
from business_tools import BusinessTools
from conversation_summary import extract_rule_based_summary, post_call_summary_pipeline

TZ = ZoneInfo("Asia/Shanghai")
GCLOUD = "/opt/homebrew/bin/gcloud"
GOOGLE_PROXY = os.environ.get("COM_GOOGLE_PROXY", "http://127.0.0.1:7897")
VOICES = ("Aoede", "Kore", "Puck", "Charon", "Fenrir")

LIVE_TARGETS: tuple[dict[str, Any], ...] = (
    {
        "account": os.environ.get("ASR_GCP_PRIMARY_ACCOUNT", "eddiegao948@gmail.com"),
        "project": os.environ.get("ASR_GCP_PRIMARY_PROJECT", "project-816c0481-813e-4353-ab7"),
        "location": "us-central1",  # 实测 global 区没有这个模型（1008 not found）
        "model": "gemini-3.8-live",
        "affective": False,  # 实测 1007: Affective dialog is not yet supported
        "proactive": True,
    },
    {
        "account": os.environ.get("ASR_GCP_SECONDARY_ACCOUNT", "a123456z789z@gmail.com"),
        "project": os.environ.get("ASR_GCP_SECONDARY_PROJECT", "gen-lang-client-0792759409"),
        "location": "us-central1",  # 实测 global 区没有这个模型（1008 not found）
        "model": "gemini-3.8-live",
        "affective": False,  # 实测 1007: Affective dialog is not yet supported
        "proactive": True,
    },
    {
        "account": os.environ.get("ASR_GCP_PRIMARY_ACCOUNT", "eddiegao948@gmail.com"),
        "project": os.environ.get("ASR_GCP_PRIMARY_PROJECT", "project-816c0481-813e-4353-ab7"),
        "location": "us-central1",
        "model": "gemini-live-2.5-flash-native-audio",
        "affective": True,
        "proactive": True,
    },
    {
        "account": os.environ.get("ASR_GCP_SECONDARY_ACCOUNT", "a123456z789z@gmail.com"),
        "project": os.environ.get("ASR_GCP_SECONDARY_PROJECT", "gen-lang-client-0792759409"),
        "location": "us-central1",
        "model": "gemini-live-2.5-flash-native-audio",
        "affective": True,
        "proactive": True,
    },
    {
        "account": os.environ.get("ASR_GCP_PRIMARY_ACCOUNT", "eddiegao948@gmail.com"),
        "project": os.environ.get("ASR_GCP_PRIMARY_PROJECT", "project-816c0481-813e-4353-ab7"),
        "location": "global",
        "model": "gemini-live-2.5-flash",
        "affective": False,
        "proactive": False,
    },
    {
        "account": os.environ.get("ASR_GCP_SECONDARY_ACCOUNT", "a123456z789z@gmail.com"),
        "project": os.environ.get("ASR_GCP_SECONDARY_PROJECT", "gen-lang-client-0792759409"),
        "location": "global",
        "model": "gemini-live-2.5-flash",
        "affective": False,
        "proactive": False,
    },
)

_TOKEN_LOCK = threading.Lock()
_TOKENS: dict[str, dict[str, Any]] = {}

SESSION_RESUMPTION_TTL = 7200.0  # 2 小时过期清理
_SESSION_HANDLES: dict[str, dict[str, Any]] = {}


def _cleanup_expired_handles(now: float | None = None) -> None:
    ts_now = now if now is not None else time.time()
    expired = [
        sid
        for sid, info in list(_SESSION_HANDLES.items())
        if ts_now - float(info.get("ts") or 0) > SESSION_RESUMPTION_TTL
    ]
    for sid in expired:
        _SESSION_HANDLES.pop(sid, None)


def save_session_handle(session_id: str, handle: str, now: float | None = None) -> None:
    ts_now = now if now is not None else time.time()
    _cleanup_expired_handles(ts_now)
    if session_id and handle:
        _SESSION_HANDLES[session_id] = {"handle": handle, "ts": ts_now}


def get_session_handle(session_id: str, now: float | None = None) -> str | None:
    _cleanup_expired_handles(now)
    info = _SESSION_HANDLES.get(session_id)
    if isinstance(info, dict) and info.get("handle"):
        return str(info["handle"])
    return None


def _adc_path(account: str) -> Path:
    return Path.home() / ".config" / "gcloud" / "legacy_credentials" / account / "adc.json"


def fetch_gcp_token(account: str, force: bool = False) -> str:
    now = time.monotonic()
    with _TOKEN_LOCK:
        cached = _TOKENS.get(account)
        if not force and cached and cached["exp"] > now + 60 and cached["tok"]:
            return str(cached["tok"])

    tok = ""
    adc = _adc_path(account)
    if adc.exists():
        try:
            cred = json.loads(adc.read_text(encoding="utf-8"))
            with httpx.Client(proxy=GOOGLE_PROXY or None, timeout=8.0) as client:
                resp = client.post(
                    "https://oauth2.googleapis.com/token",
                    data={
                        "client_id": cred["client_id"],
                        "client_secret": cred["client_secret"],
                        "refresh_token": cred["refresh_token"],
                        "grant_type": "refresh_token",
                    },
                )
                if resp.status_code == 200:
                    tok = str(resp.json().get("access_token") or "").strip()
        except Exception as exc:  # noqa: BLE001
            print(f"voice_live adc token refresh failed for {account}: {exc}", flush=True)

    if not tok and os.path.exists(GCLOUD):
        try:
            env = dict(os.environ)
            if GOOGLE_PROXY:
                env["HTTPS_PROXY"] = GOOGLE_PROXY
                env["HTTP_PROXY"] = GOOGLE_PROXY
            tok = subprocess.check_output(
                [GCLOUD, "-q", "auth", "print-access-token", "--account=" + account],
                text=True,
                timeout=12,
                env=env,
            ).strip()
        except Exception as exc:  # noqa: BLE001
            print(f"voice_live gcloud token failed for {account}: {exc}", flush=True)

    if tok:
        with _TOKEN_LOCK:
            _TOKENS[account] = {"tok": tok, "exp": now + 3000}
    return tok


LIVE_TOOLS = [
    {
        "functionDeclarations": [
            {
                "name": "bookkeeping_add",
                "description": "记一笔开销或收入到 Eddie 的账本（ezBookkeeping）。当他说花了多少钱、买了什么、或者记一笔账时直接调用。",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "amount": {"type": "NUMBER", "description": "金额（人民币元，支持小数）"},
                        "item": {"type": "STRING", "description": "消费或收入用途备注，例如：午饭、拿铁咖啡、打车、岩馆门票"},
                        "category": {
                            "type": "STRING",
                            "description": "可选分类：餐饮外卖、出行交通、汽车摩托、居住房租、通讯话费、App订阅、健康医疗、个护美容、娱乐休闲、学习成长、人情社交、数码电子、宠物、购物消费、工资、奖金、报销、其他收入",
                        },
                        "account": {
                            "type": "STRING",
                            "description": "可选账户，默认招商银行储蓄卡。可选：现金、花呗、京东白条、信用卡-招商、信用卡-中信visa、信用卡-招商万事达、工商银行",
                        },
                    },
                    "required": ["amount", "item"],
                },
            },
            {
                "name": "bookkeeping_summary",
                "description": "查询本月或指定月份的账本收支汇总与最近几笔账单。",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "month": {"type": "STRING", "description": "可选月份 YYYY-MM，默认当前月"},
                    },
                },
            },
            {
                "name": "reminder_add",
                "description": "给 Eddie 设置提醒事项。",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "text": {"type": "STRING", "description": "提醒内容"},
                        "in_minutes": {"type": "NUMBER", "description": "多少分钟后提醒（与 at 二选一）"},
                        "at": {"type": "STRING", "description": "指定提醒时间，格式 YYYY-MM-DD HH:MM"},
                    },
                    "required": ["text"],
                },
            },
            {
                "name": "calendar_action",
                "description": "查询或创建 Apple 日历日程（标题自动或按【分类】标题格式）。",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "action": {"type": "STRING", "description": "list（查日程）或 create（建日程）"},
                        "date": {"type": "STRING", "description": "日期 YYYY-MM-DD，默认今天"},
                        "end_date": {"type": "STRING", "description": "查询结束日期 YYYY-MM-DD，默认与 date 相同"},
                        "summary": {"type": "STRING", "description": "建日程时的标题，建议带【分类】前缀"},
                        "hour": {"type": "INTEGER", "description": "开始小时（0-23），默认 10"},
                        "minute": {"type": "INTEGER", "description": "开始分钟（0-59），默认 0"},
                        "duration_minutes": {"type": "INTEGER", "description": "时长（分钟），默认 60"},
                    },
                    "required": ["action"],
                },
            },
            {
                "name": "next_steps_action",
                "description": "查看 Eddie 当前的「下一步」待办建议列表，或把某条建议标为已完成(done)/划掉不用(dismiss)。",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "action": {"type": "STRING", "description": "list（查看当前建议与待办）、done（标为完成）或 dismiss（划掉）"},
                        "item_id": {"type": "STRING", "description": "当 action 为 done 或 dismiss 时，条目 ID 或标题关键词"},
                    },
                    "required": ["action"],
                },
            },
            {
                "name": "memory_search",
                "description": "在 Eddie 的个人记忆库（Hindsight）中检索过往事实、人名、项目、设备或偏好。",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "query": {"type": "STRING", "description": "检索关键词或问题"},
                    },
                    "required": ["query"],
                },
            },
            {
                "name": "ask_com_main",
                "description": "把需要写代码、深入查资料或多步执行的复杂任务转交给 Com! 主对话后台异步执行，不阻塞当前语音通话。",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "instruction": {"type": "STRING", "description": "要交给 Com! 主对话后台执行的完整指令"},
                    },
                    "required": ["instruction"],
                },
            },
        ]
    }
]


IDENTITY_PROFILE_PATH = Path.home() / "AI_Work_System" / "_global" / "本体画像" / "00-核心身份.md"
OPENING_TURN_PREFIX = "[系统隐藏指令：开场招呼]"


def build_system_instruction(
    next_steps_service: Any = None,
    personal_hub: Any = None,
    conversation: Any = None,
) -> str:
    now_str = datetime.now(TZ).strftime("%Y-%m-%d %H:%M (%A)")
    lines = [
        f"你是 Com，Eddie（小野）的私人 AI 伙伴与老朋友。现在是北京时间 {now_str}，你们正在实时语音通话。",
        "说话方式硬约束：",
        "1. 全程中文口语短句，一次通常一两句，先说结论；可以用「嗯」「对」「行」这类自然应答，但不要每句都以「好的」开头、不要每句都叫名字。",
        "2. 听不清或信息不够就直接反问一句；要调用工具前先顺口应一声（如「我看一下」）再去查；不念列表、不念符号、数字按口语读；他打断你就停下听他说；他沉默时不要追问填空。",
        "3. 当他让你记账、设提醒、查/建日程、看「下一步」待办、查记忆，或者交办后台任务时，直接调用对应的工具执行，然后用嘴简短告诉他办好了什么。",
        "4. 事实必须准确，工具返回什么就说什么，不编造账目或日程。",
        "5. 你们的每一轮语音对话都会自动保存在 Eddie 私人的 Com! 聊天记录库（他自己 Mac mini 本地的 SQLite）中，挂断后回到 Com! 主界面就能看到，且可通过 ask_com_main 写入他的长期记忆库；绝不要说『不会保存你的个人信息』或『对话用于提升模型表现』这类通用客服套话。",
    ]

    try:
        if IDENTITY_PROFILE_PATH.exists():
            identity_text = IDENTITY_PROFILE_PATH.read_text(encoding="utf-8").strip()[:1200]
            if identity_text:
                lines.append(f"你对他的了解：\n{identity_text}")
    except Exception:  # noqa: BLE001
        pass

    conv = conversation or getattr(personal_hub, "conversation", None)
    if conv is not None:
        try:
            hist = conv.history(limit=12) if hasattr(conv, "history") else conv.snapshot()
            raw_msgs = hist.get("messages") if isinstance(hist, dict) else []
            recent_msgs = [
                m
                for m in (raw_msgs or [])
                if isinstance(m, dict) and str(m.get("text") or "").strip()
            ][-12:]
            if recent_msgs:
                snippets = []
                for m in recent_msgs:
                    role_tag = "Eddie" if m.get("role") == "user" else "Com"
                    txt = " ".join(str(m.get("text") or "").split())[:120]
                    snippets.append(f"{role_tag}: {txt}")
                joined_recent = "\n".join(snippets)[:1000]
                lines.append(f"主聊天最近对话摘要：\n{joined_recent}")
        except Exception:  # noqa: BLE001
            pass

    if next_steps_service is not None:
        try:
            snap = next_steps_service.snapshot()
            items = (snap.get("items") or [])[:5]
            if items:
                summary = "；".join(
                    f"[{it.get('id', '')}] {it.get('title', '')}" for it in items if isinstance(it, dict)
                )[:600]
                lines.append(f"当前「下一步」待办前几项：{summary}")
            brief = snap.get("brief")
            if isinstance(brief, dict) and brief.get("headline"):
                headline = str(brief.get("headline"))[:200]
                lines.append(f"今日简报头条：{headline}")
        except Exception:  # noqa: BLE001
            pass
    return "\n".join(lines)


def build_opening_prompt(next_steps_service: Any = None) -> str:
    now_dt = datetime.now(TZ)
    hour = now_dt.hour
    if 5 <= hour < 9:
        period = "早上"
    elif 9 <= hour < 12:
        period = "上午"
    elif 12 <= hour < 14:
        period = "中午"
    elif 14 <= hour < 18:
        period = "下午"
    elif 18 <= hour < 23:
        period = "晚上"
    else:
        period = "深夜"

    hint = ""
    if next_steps_service is not None:
        try:
            snap = next_steps_service.snapshot()
            brief = snap.get("brief")
            if isinstance(brief, dict) and brief.get("headline"):
                hint = f"，今日头条「{str(brief['headline'])[:24]}」"
            else:
                items = snap.get("items") or []
                if items and isinstance(items[0], dict) and items[0].get("title"):
                    hint = f"，当前待办「{str(items[0]['title'])[:24]}」"
        except Exception:  # noqa: BLE001
            pass
    return (
        f"{OPENING_TURN_PREFIX} 电话刚接通，现在是{period}{hint}。"
        "请主动先开口说一句很短的招呼，不超过15个字，不要自我介绍。"
    )


def record_live_turn(
    conversation: Any,
    user_text: str,
    assistant_text: str,
    tool_receipts: list[dict[str, Any]] | None = None,
) -> dict[str, str] | None:
    """Persist a completed Live Voice exchange into PersonalConversation so it shows in chat history."""
    u_clean = (user_text or "").strip()
    a_clean = (assistant_text or "").strip()
    if not u_clean and not a_clean:
        return None
    if not u_clean:
        u_clean = "（实时语音通话）"
    if not a_clean:
        a_clean = "（已通过语音回应）"

    user_id = uuid.uuid4().hex
    reply_id = uuid.uuid4().hex
    req_id = "live-" + user_id
    now = time.time()
    tasks_json = None
    if tool_receipts:
        tasks_payload = [
            {
                "id": f"live-tool-{idx + 1}",
                "kind": "tool",
                "tool": str(r.get("name") or "tool"),
                "title": str(r.get("title") or r.get("name") or "工具调用"),
                "status": "done" if r.get("ok", True) else "failed",
                "started_at": float(r.get("started_at") or now - 1.0),
                "finished_at": float(r.get("finished_at") or now),
            }
            for idx, r in enumerate(tool_receipts)
        ]
        tasks_json = json.dumps(tasks_payload, ensure_ascii=False)

    with conversation.db() as db:
        rev1 = conversation._bump(db)
        seq1 = conversation._next_seq(db)
        db.execute(
            "INSERT INTO messages(id,request_id,role,text,status,phase,revision,created_at,updated_at,received_at,tasks,origin_agent,message_seq)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (user_id, req_id, "user", u_clean, "completed", "completed", rev1, now, now, now, tasks_json, "gemini-live", seq1),
        )
        rev2 = conversation._bump(db)
        seq2 = conversation._next_seq(db)
        db.execute(
            "INSERT INTO messages(id,request_id,parent_id,role,text,status,phase,revision,created_at,updated_at,origin_agent,message_seq)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (reply_id, req_id + ":reply", user_id, "assistant", a_clean, "completed", "completed", rev2, now + 0.001, now + 0.001, "gemini-live", seq2),
        )
    conversation._notify()
    return {"user_message_id": user_id, "assistant_message_id": reply_id}


async def execute_live_tool(
    name: str,
    args: dict[str, Any],
    *,
    state: Path,
    conversation: Any = None,
    next_steps_service: Any = None,
) -> tuple[str, dict[str, Any]]:
    """Execute a tool called by Gemini Live and return (human_title, result_dict)."""
    args = dict(args or {})
    op_id = "live_" + hashlib.sha256(f"{time.time_ns()}:{name}:{json.dumps(args, sort_keys=True, ensure_ascii=False)}".encode()).hexdigest()[:24]
    bt = BusinessTools(state)

    if name == "bookkeeping_add":
        amount = float(args.get("amount") or 0)
        item = str(args.get("item") or "").strip()
        category = str(args.get("category") or "").strip()
        if not category:
            category = (
                fast_bookkeeping._keyword(item, fast_bookkeeping.INCOME_KEYWORDS)
                or fast_bookkeeping._keyword(item, fast_bookkeeping.CATEGORY_KEYWORDS)
                or "餐饮外卖"
            )
        account = str(args.get("account") or "").strip() or (
            fast_bookkeeping._keyword(item, fast_bookkeeping.ACCOUNT_KEYWORDS) or fast_bookkeeping.DEFAULT_ACCOUNT
        )

        # Strict ezBookkeeping timestamp second validation
        raw_time = args.get("time")
        if raw_time is not None:
            try:
                time_f = float(raw_time)
            except (ValueError, TypeError) as exc:
                raise ValueError(f"ezBookkeeping 无效时间戳参数: {raw_time}") from exc
            if time_f > 1e11:
                raise ValueError(f"ezBookkeeping 时间戳必须为秒级整型（当前传入为毫秒级 {time_f:g}，公元5万年溢出）")
            time_sec = int(time_f)
            when_iso = datetime.fromtimestamp(time_sec, tz=TZ).isoformat()
        else:
            time_sec = int(time.time())
            when_iso = datetime.now(TZ).isoformat()

        res = await bt.bookkeeping(
            {
                "action": "add",
                "amount": amount,
                "category": category,
                "account": account,
                "comment": item,
                "time": when_iso,
                "_operation_id": op_id,
            }
        )
        res["time_seconds"] = time_sec
        return f"记账 ¥{amount:g} · {item}", res

    if name == "bookkeeping_summary":
        month = str(args.get("month") or "").strip() or None
        summary = await bt.bookkeeping({"action": "summary", "month": month})
        recent = await bt.bookkeeping({"action": "recent", "count": 5})
        return "查询账本汇总", {
            "month": summary.get("month"),
            "expense_yuan": round(int(summary.get("expense_minor") or 0) / 100.0, 2),
            "income_yuan": round(int(summary.get("income_minor") or 0) / 100.0, 2),
            "count": summary.get("count"),
            "recent": [
                {"amount_yuan": round(int(r.get("sourceAmount") or 0) / 100.0, 2), "comment": r.get("comment", "")}
                for r in (recent.get("items") or [])[:5]
            ],
        }

    if name == "reminder_add":
        text = str(args.get("text") or "").strip()
        remind_args: dict[str, Any] = {"action": "add", "text": text, "_operation_id": op_id}
        if args.get("at"):
            remind_args["at"] = str(args["at"])
            try:
                due_dt = datetime.strptime(args["at"], "%Y-%m-%d %H:%M").replace(tzinfo=TZ)
            except ValueError:
                due_dt = datetime.now(TZ) + timedelta(minutes=30)
        else:
            in_min = float(args.get("in_minutes") or 30)
            remind_args["in_minutes"] = in_min
            due_dt = datetime.now(TZ) + timedelta(minutes=in_min)

        # 1. Primary write: WeChat queue via reminder_store
        res = await bt.remind(remind_args)

        # 2. Dual-write: macOS Apple Calendar
        category = str(args.get("category") or "提醒").strip()
        cal_summary = str(args.get("summary") or "").strip()
        if not cal_summary:
            if text.startswith("【"):
                cal_summary = text
            else:
                cal_summary = f"【{category}】{text}"
        elif not cal_summary.startswith("【"):
            cal_summary = f"【{category}】{cal_summary}"

        cal_date = due_dt.strftime("%Y-%m-%d")
        cal_hour = due_dt.hour
        cal_minute = due_dt.minute

        try:
            cal_res = await bt.calendar(
                {
                    "action": "create",
                    "date": cal_date,
                    "hour": cal_hour,
                    "minute": cal_minute,
                    "duration_minutes": 15,
                    "summary": cal_summary,
                    "_operation_id": f"{op_id}_cal",
                }
            )
            res["calendar"] = cal_res
            res["dual_write"] = True
            res["calendar_summary"] = cal_summary
        except Exception as exc:
            res["calendar_error"] = str(exc)
            res["dual_write"] = False

        return f"设提醒 · {text}", res

    if name == "calendar_action":
        act = str(args.get("action") or "list").strip()
        today_str = datetime.now(TZ).strftime("%Y-%m-%d")
        date_str = str(args.get("date") or today_str).strip()
        if act == "create":
            summary = str(args.get("summary") or "【日程】新建安排").strip()
            if not summary.startswith("【"):
                summary = "【日程】" + summary
            res = await bt.calendar(
                {
                    "action": "create",
                    "date": date_str,
                    "summary": summary,
                    "hour": int(args.get("hour", 10)),
                    "minute": int(args.get("minute", 0)),
                    "duration_minutes": int(args.get("duration_minutes", 60)),
                    "_operation_id": op_id,
                }
            )
            return f"建日程 · {summary}", res
        end_str = str(args.get("end_date") or date_str).strip()
        res = await bt.calendar({"action": "list", "start_date": date_str, "end_date": end_str})
        return f"查日程 · {date_str}", res

    if name == "next_steps_action":
        if next_steps_service is None:
            return "查看下一步", {"error": "下一步服务未就绪"}
        act = str(args.get("action") or "list").strip()
        snap = next_steps_service.snapshot()
        items = snap.get("items") or []
        if act in ("done", "dismiss"):
            target_q = str(args.get("item_id") or "").strip()
            matched = next(
                (
                    it
                    for it in items
                    if isinstance(it, dict)
                    and (it.get("id") == target_q or (target_q and target_q in str(it.get("title", ""))))
                ),
                None,
            )
            if not matched:
                return "更新待办", {"ok": False, "error": f"未找到匹配「{target_q}」的待办项"}
            updated = await next_steps_service.act(matched["id"], act, reason="elsewhere" if act == "done" else "not_needed")
            return f"{'完成' if act == 'done' else '划掉'}待办 · {matched.get('title', '')}", {"ok": True, "item": matched.get("title"), "snapshot_count": len(updated.get("items") or [])}
        return "查看下一步待办", {
            "items": [
                {"id": it.get("id"), "title": it.get("title"), "why": it.get("why"), "status": it.get("status")}
                for it in items[:8]
                if isinstance(it, dict)
            ]
        }

    if name == "memory_search":
        query = str(args.get("query") or "").strip()
        from memory import recall_on_demand

        res = await recall_on_demand(query)
        return f"查记忆 · {query}", res

    if name == "ask_com_main":
        instruction = str(args.get("instruction") or "").strip()
        if not instruction or conversation is None:
            return "转交后台", {"ok": False, "error": "指令为空或会话未就绪"}
        req_id = "live-dispatch-" + uuid.uuid4().hex[:20]
        accepted = conversation.submit(req_id, instruction)
        if hasattr(conversation, "schedule"):
            conversation.schedule(accepted["message_id"])
        return f"转交后台 · {instruction[:18]}", {"ok": True, "dispatched": True, "message_id": accepted["message_id"]}

    return name, {"error": f"未知工具: {name}"}


# ==============================================================================
# Upstream Adapter Architecture
# ==============================================================================


class LiveUpstreamAdapter(ABC):
    """Abstract Base Class for full-duplex realtime speech-to-speech upstream engines."""

    model_name: str

    @abstractmethod
    async def connect(self, voice: str, system_prompt: str, tools: list[dict[str, Any]]) -> None:
        """Connect to the upstream service and initialize full-duplex session."""

    @abstractmethod
    async def send_audio(self, pcm_16k: bytes) -> None:
        """Stream 16kHz linear PCM audio chunk (100ms / 3200 bytes) upstream."""

    @abstractmethod
    async def send_text_turn(self, text: str) -> None:
        """Send explicit text input into the conversation."""

    @abstractmethod
    async def send_tool_response(self, call_id: str, name: str, output: dict[str, Any]) -> None:
        """Return execution result of a function call to the model."""

    @abstractmethod
    async def interrupt(self) -> None:
        """Notify upstream of client-side barge-in interruption."""

    @abstractmethod
    def incoming_events(self) -> AsyncIterator[dict[str, Any]]:
        """Asynchronously yield normalized events from upstream.

        Normalized event types:
          - {"type": "audio", "data": bytes} (24kHz PCM)
          - {"type": "transcript", "role": "user"|"assistant", "text": str, "finished": bool}
          - {"type": "tool_call", "calls": list[dict]}
          - {"type": "interrupted"}
          - {"type": "turn_complete"}
          - {"type": "emotion", "state": str, "energy": float}
        """

    @abstractmethod
    async def close(self) -> None:
        """Gracefully terminate upstream session."""


class GeminiLiveAdapter(LiveUpstreamAdapter):
    """Production Vertex AI Gemini Live API adapter with dual-project failover."""

    def __init__(
        self,
        targets: tuple[dict[str, Any], ...] = LIVE_TARGETS,
        resumption_handle: str | None = None,
        ws_connector: Any = None,
    ):
        self.targets = targets
        self.model_name = "gemini-3.8-live"
        self.resumption_handle: str | None = resumption_handle
        self._ws_connector = ws_connector
        self._ws: Any = None
        self._connected: bool = False
        self._suppress_audio: bool = False
        self.setup_attempts: list[dict[str, Any]] = []

    @staticmethod
    def build_setup_payload(
        target: dict[str, Any],
        voice: str,
        system_prompt: str,
        tools: list[dict[str, Any]],
        *,
        affective: bool,
        proactive: bool,
        resumption_handle: str | None = None,
    ) -> dict[str, Any]:
        loc = target["location"]
        gen_cfg: dict[str, Any] = {
            "responseModalities": ["AUDIO"],
            "speechConfig": {
                "voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}
            },
        }
        if affective:
            gen_cfg["enableAffectiveDialog"] = True

        resumption_cfg: dict[str, Any] = {"handle": resumption_handle} if resumption_handle else {}
        setup_body: dict[str, Any] = {
            "model": f"projects/{target['project']}/locations/{loc}/publishers/google/models/{target['model']}",
            "systemInstruction": {"parts": [{"text": system_prompt}]},
            "generationConfig": gen_cfg,
            "realtimeInputConfig": {
                "automaticActivityDetection": {
                    "disabled": False,
                    "silenceDurationMs": 650,
                    "prefixPaddingMs": 150,
                }
            },
            "inputAudioTranscription": {},
            "outputAudioTranscription": {},
            "sessionResumption": resumption_cfg,
            "contextWindowCompression": {"slidingWindow": {}},
            "tools": tools,
        }
        if proactive:
            setup_body["proactivity"] = {"proactiveAudio": True}
        return {"setup": setup_body}

    async def connect(
        self,
        voice: str,
        system_prompt: str,
        tools: list[dict[str, Any]],
        resumption_handle: str | None = None,
    ) -> None:
        if resumption_handle is not None:
            self.resumption_handle = resumption_handle
        if self._ws_connector is not None:
            ws_connect = self._ws_connector
        else:
            from websockets.asyncio.client import connect as ws_connect

        self._suppress_audio = False
        last_err: Exception | None = None
        for target in self.targets:
            tok = await asyncio.to_thread(fetch_gcp_token, target["account"], False)
            if not tok:
                continue
            loc = target["location"]
            host = f"{loc}-aiplatform.googleapis.com" if loc != "global" else "aiplatform.googleapis.com"
            uri = f"wss://{host}/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent"

            want_aff = bool(target.get("affective", False))
            want_pro = bool(target.get("proactive", False))
            attempts: list[tuple[bool, bool]] = [(want_aff, want_pro)]
            if want_aff or want_pro:
                attempts.append((False, False))

            for aff, pro in attempts:
                ws = None
                try:
                    ws = await ws_connect(
                        uri,
                        additional_headers={"Authorization": f"Bearer {tok}"},
                        proxy=GOOGLE_PROXY if GOOGLE_PROXY else None,
                        max_size=16 * 1024 * 1024,
                        open_timeout=8,
                    )
                    setup = self.build_setup_payload(
                        target,
                        voice,
                        system_prompt,
                        tools,
                        affective=aff,
                        proactive=pro,
                        resumption_handle=self.resumption_handle,
                    )
                    self.setup_attempts.append(setup)
                    await ws.send(json.dumps(setup, ensure_ascii=False))
                    raw = await asyncio.wait_for(ws.recv(), timeout=8)
                    ack = json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
                    if isinstance(ack, dict) and "setupComplete" in ack:
                        self._ws = ws
                        self.model_name = target["model"]
                        self._connected = True
                        return
                    last_err = RuntimeError(f"Non-setupComplete response: {ack}")
                    await ws.close()
                except Exception as exc:  # noqa: BLE001
                    last_err = exc
                    if ws is not None:
                        with contextlib.suppress(Exception):
                            await ws.close()
                    print(
                        f"voice_live target {target['project']}/{target['model']} (aff={aff}, pro={pro}) failed: {exc}",
                        flush=True,
                    )
                    continue
        raise RuntimeError(f"Vertex AI 实时语音连接失败: {last_err}")

    async def send_audio(self, pcm_16k: bytes) -> None:
        if not self._ws or not self._connected:
            return
        b64 = base64.b64encode(pcm_16k).decode("ascii")
        payload = {
            "realtimeInput": {
                "audio": {"mimeType": "audio/pcm;rate=16000", "data": b64}
            }
        }
        await self._ws.send(json.dumps(payload))

    async def send_text_turn(self, text: str) -> None:
        if not self._ws or not self._connected:
            return
        self._suppress_audio = False
        payload = {
            "clientContent": {
                "turns": [{"role": "user", "parts": [{"text": text}]}],
                "turnComplete": True,
            }
        }
        await self._ws.send(json.dumps(payload, ensure_ascii=False))

    async def send_tool_response(self, call_id: str, name: str, output: dict[str, Any]) -> None:
        if not self._ws or not self._connected:
            return
        self._suppress_audio = False
        payload = {
            "toolResponse": {
                "functionResponses": [
                    {"id": call_id, "name": name, "response": {"output": output}}
                ]
            }
        }
        await self._ws.send(json.dumps(payload, ensure_ascii=False))

    async def interrupt(self) -> None:
        # Server VAD handles barge-in; client interruption drains gateway pipeline.
        self._suppress_audio = True

    async def incoming_events(self) -> AsyncIterator[dict[str, Any]]:
        if not self._ws:
            return
        async for raw in self._ws:
            data = json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
            sru = data.get("sessionResumptionUpdate")
            if isinstance(sru, dict):
                new_handle = str(sru.get("newHandle") or "").strip()
                if sru.get("resumable") and new_handle:
                    self.resumption_handle = new_handle
                    yield {
                        "type": "session_resumption_update",
                        "handle": new_handle,
                        "resumable": True,
                    }

            if "goAway" in data:
                ga = data.get("goAway")
                time_left = ga.get("timeLeft") if isinstance(ga, dict) else None
                yield {"type": "go_away", "time_left": time_left}

            if "toolCall" in data:
                calls = data["toolCall"].get("functionCalls") or []
                yield {"type": "tool_call", "calls": calls}
                continue

            sc = data.get("serverContent")
            if not isinstance(sc, dict):
                continue

            if sc.get("interrupted"):
                self._suppress_audio = True
                yield {"type": "interrupted"}

            in_tr = sc.get("inputTranscription")
            if isinstance(in_tr, dict) and in_tr.get("text"):
                yield {
                    "type": "transcript",
                    "role": "user",
                    "text": str(in_tr["text"]),
                    "finished": bool(in_tr.get("finished")),
                }

            out_tr = sc.get("outputTranscription")
            if isinstance(out_tr, dict) and out_tr.get("text"):
                yield {
                    "type": "transcript",
                    "role": "assistant",
                    "text": str(out_tr["text"]),
                    "finished": bool(out_tr.get("finished")),
                }

            model_turn = sc.get("modelTurn")
            if isinstance(model_turn, dict):
                for part in model_turn.get("parts") or []:
                    inline = part.get("inlineData") if isinstance(part, dict) else None
                    if isinstance(inline, dict) and inline.get("data"):
                        pcm_out = base64.b64decode(inline["data"])
                        if pcm_out and not self._suppress_audio:
                            yield {"type": "audio", "data": pcm_out}

            if sc.get("turnComplete"):
                self._suppress_audio = False
                yield {"type": "turn_complete"}

    async def close(self) -> None:
        self._connected = False
        if self._ws:
            with contextlib.suppress(Exception):
                await self._ws.close()


class OpenAIRealtimeAdapter(LiveUpstreamAdapter):
    """Fallback route adapter for OpenAI Realtime API (WebSocket)."""

    def __init__(self, model: str = "gpt-4o-realtime-preview", api_key: str | None = None):
        self.model_name = model
        self.api_key = api_key or os.environ.get("OPENAI_API_KEY", "")
        self._ws: Any = None
        self._connected: bool = False
        self._suppress_audio: bool = False

    async def connect(self, voice: str, system_prompt: str, tools: list[dict[str, Any]]) -> None:
        from websockets.asyncio.client import connect

        self._suppress_audio = False
        if not self.api_key:
            raise RuntimeError("OPENAI_API_KEY 未配置，无法连接 OpenAI Realtime API")

        uri = f"wss://api.openai.com/v1/realtime?model={self.model_name}"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "OpenAI-Beta": "realtime=v1",
        }
        self._ws = await connect(uri, additional_headers=headers, open_timeout=8)
        self._connected = True

        openai_tools = []
        for group in tools:
            for fn in group.get("functionDeclarations") or []:
                openai_tools.append({
                    "type": "function",
                    "name": fn["name"],
                    "description": fn.get("description", ""),
                    "parameters": fn.get("parameters", {}),
                })

        oai_voice = voice.lower() if voice.lower() in ("alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse") else "alloy"
        setup_event = {
            "type": "session.update",
            "session": {
                "modalities": ["audio", "text"],
                "instructions": system_prompt,
                "voice": oai_voice,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "turn_detection": {
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 450,
                },
                "tools": openai_tools,
            },
        }
        await self._ws.send(json.dumps(setup_event, ensure_ascii=False))

    async def send_audio(self, pcm_16k: bytes) -> None:
        if not self._ws or not self._connected:
            return
        b64 = base64.b64encode(pcm_16k).decode("ascii")
        await self._ws.send(json.dumps({"type": "input_audio_buffer.append", "audio": b64}))

    async def send_text_turn(self, text: str) -> None:
        if not self._ws or not self._connected:
            return
        self._suppress_audio = False
        item_event = {
            "type": "conversation.item.create",
            "item": {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": text}],
            },
        }
        await self._ws.send(json.dumps(item_event, ensure_ascii=False))
        await self._ws.send(json.dumps({"type": "response.create"}))

    async def send_tool_response(self, call_id: str, name: str, output: dict[str, Any]) -> None:
        if not self._ws or not self._connected:
            return
        self._suppress_audio = False
        item_event = {
            "type": "conversation.item.create",
            "item": {
                "type": "function_call_output",
                "call_id": call_id,
                "output": json.dumps(output, ensure_ascii=False),
            },
        }
        await self._ws.send(json.dumps(item_event, ensure_ascii=False))
        await self._ws.send(json.dumps({"type": "response.create"}))

    async def interrupt(self) -> None:
        self._suppress_audio = True
        if not self._ws or not self._connected:
            return
        with contextlib.suppress(Exception):
            await self._ws.send(json.dumps({"type": "response.cancel"}))

    async def incoming_events(self) -> AsyncIterator[dict[str, Any]]:
        if not self._ws:
            return
        async for raw in self._ws:
            event = json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
            etype = event.get("type")
            if etype == "response.audio.delta":
                data = base64.b64decode(event.get("delta", ""))
                if data and not self._suppress_audio:
                    yield {"type": "audio", "data": data}
            elif etype == "response.audio_transcript.delta":
                yield {"type": "transcript", "role": "assistant", "text": event.get("delta", ""), "finished": False}
            elif etype == "response.audio_transcript.done":
                yield {"type": "transcript", "role": "assistant", "text": event.get("transcript", ""), "finished": True}
            elif etype == "conversation.item.input_audio_transcription.completed":
                yield {"type": "transcript", "role": "user", "text": event.get("transcript", ""), "finished": True}
            elif etype == "response.function_call_arguments.done":
                yield {
                    "type": "tool_call",
                    "calls": [{
                        "id": event.get("call_id", ""),
                        "name": event.get("name", ""),
                        "args": json.loads(event.get("arguments", "{}")),
                    }],
                }
            elif etype in ("response.cancelled", "conversation.item.truncated"):
                self._suppress_audio = True
                yield {"type": "interrupted"}
            elif etype == "response.done":
                self._suppress_audio = False
                yield {"type": "turn_complete"}

    async def close(self) -> None:
        self._connected = False
        if self._ws:
            with contextlib.suppress(Exception):
                await self._ws.close()


class MockLiveAdapter(LiveUpstreamAdapter):
    """Fully deterministic offline adapter simulating bidirectional audio frames,
    transcript events, emotion cues, interruption handling, and tool call responses."""

    def __init__(
        self,
        auto_respond: bool = True,
        default_model: str = "mock-live-2.5-flash",
        *,
        auto_respond_opening: bool = False,
        reject_advanced_setup: bool = False,
        targets: tuple[dict[str, Any], ...] | None = None,
    ):
        self.model_name = default_model
        self.auto_respond = auto_respond
        self.auto_respond_opening = auto_respond_opening
        self.reject_advanced_setup = reject_advanced_setup
        self.targets = targets or LIVE_TARGETS
        self.event_queue: asyncio.Queue[dict[str, Any] | Exception | None] = asyncio.Queue()
        self.received_audio: list[bytes] = []
        self.received_texts: list[str] = []
        self.opening_prompts: list[str] = []
        self.received_tool_responses: list[dict[str, Any]] = []
        self.interrupted: bool = False
        self.interrupt_count: int = 0
        self._closed: bool = False
        self.connected_voice: str = "Aoede"
        self.resumption_handle: str | None = None
        self.connect_calls: list[dict[str, Any]] = []
        self.setup_attempts: list[dict[str, Any]] = []

    async def connect(
        self,
        voice: str,
        system_prompt: str,
        tools: list[dict[str, Any]],
        resumption_handle: str | None = None,
    ) -> None:
        if resumption_handle is not None:
            self.resumption_handle = resumption_handle
        self.connected_voice = voice
        self._closed = False

        # Preserve queued events across silent reconnects while stripping old None sentinels
        kept: list[dict[str, Any] | Exception] = []
        while not self.event_queue.empty():
            try:
                item = self.event_queue.get_nowait()
                if item is not None:
                    kept.append(item)
            except asyncio.QueueEmpty:
                break
        for item in kept:
            self.event_queue.put_nowait(item)

        target = self.targets[0] if self.targets else {
            "project": "mock-proj",
            "location": "global",
            "model": self.model_name,
            "affective": True,
            "proactive": True,
        }
        want_aff = bool(target.get("affective", False))
        want_pro = bool(target.get("proactive", False))
        attempts: list[tuple[bool, bool]] = [(want_aff, want_pro)]
        if want_aff or want_pro:
            attempts.append((False, False))

        for aff, pro in attempts:
            setup = GeminiLiveAdapter.build_setup_payload(
                target,
                voice,
                system_prompt,
                tools,
                affective=aff,
                proactive=pro,
                resumption_handle=self.resumption_handle,
            )
            self.setup_attempts.append(setup)
            if self.reject_advanced_setup and (aff or pro):
                continue
            self.connect_calls.append(
                {
                    "voice": voice,
                    "system_prompt": system_prompt,
                    "tools": tools,
                    "resumption_handle": self.resumption_handle,
                    "affective": aff,
                    "proactive": pro,
                    "setup": setup,
                }
            )
            return
        raise RuntimeError("MockLiveAdapter setup failed")

    def enqueue_event(self, event: dict[str, Any] | Exception) -> None:
        self.event_queue.put_nowait(event)

    def enqueue_events(self, events: list[dict[str, Any] | Exception]) -> None:
        for ev in events:
            self.event_queue.put_nowait(ev)

    async def send_audio(self, pcm_16k: bytes) -> None:
        if self._closed:
            return
        self.received_audio.append(pcm_16k)
        if self.auto_respond and len(self.received_audio) == 1:
            # First audio packet triggers simulated speech exchange
            self.enqueue_events([
                {"type": "transcript", "role": "user", "text": "嗨，今天怎么样", "finished": True},
                {"type": "emotion", "state": "calm", "energy": 0.6},
                {"type": "transcript", "role": "assistant", "text": "挺好的，随时找我聊！", "finished": True},
                {"type": "audio", "data": b"\x01\x02\x03\x04" * 300},
                {"type": "turn_complete"},
            ])

    async def send_text_turn(self, text: str) -> None:
        if self._closed:
            return
        if text.startswith(OPENING_TURN_PREFIX):
            self.opening_prompts.append(text)
            if self.auto_respond_opening:
                self.enqueue_events([
                    {"type": "transcript", "role": "assistant", "text": "嗨，忙完了吗？", "finished": True},
                    {"type": "audio", "data": b"\x01\x02\x03\x04" * 100},
                    {"type": "turn_complete"},
                ])
            return

        self.received_texts.append(text)
        if self.auto_respond:
            if any(k in text for k in ("记账", "记一笔", "花了", "bookkeeping")):
                self.enqueue_events([
                    {"type": "transcript", "role": "user", "text": text, "finished": True},
                    {"type": "emotion", "state": "calm", "energy": 0.7},
                    {
                        "type": "tool_call",
                        "calls": [
                            {
                                "id": f"call_{len(self.received_texts)}",
                                "name": "bookkeeping_add",
                                "args": {"amount": 35.0, "item": "午饭", "category": "餐饮外卖"},
                            }
                        ],
                    },
                ])
            else:
                self.enqueue_events([
                    {"type": "transcript", "role": "user", "text": text, "finished": True},
                    {"type": "emotion", "state": "calm", "energy": 0.5},
                    {"type": "transcript", "role": "assistant", "text": f"收到：{text}", "finished": True},
                    {"type": "audio", "data": b"\xaa\xbb\xcc\xdd" * 300},
                    {"type": "turn_complete"},
                ])

    async def send_tool_response(self, call_id: str, name: str, output: dict[str, Any]) -> None:
        if self._closed:
            return
        self.received_tool_responses.append({"call_id": call_id, "name": name, "output": output})
        if self.auto_respond:
            self.enqueue_events([
                {"type": "transcript", "role": "assistant", "text": f"已为你完成{name}操作。", "finished": True},
                {"type": "audio", "data": b"\x11\x22\x33\x44" * 300},
                {"type": "turn_complete"},
            ])

    async def interrupt(self) -> None:
        self.interrupted = True
        self.interrupt_count += 1
        # Drain queued audio packets from event queue
        remaining: list[dict[str, Any] | Exception] = []
        while not self.event_queue.empty():
            try:
                ev = self.event_queue.get_nowait()
                if ev is not None and not (isinstance(ev, dict) and ev.get("type") == "audio"):
                    remaining.append(ev)
            except asyncio.QueueEmpty:
                break
        for ev in remaining:
            self.event_queue.put_nowait(ev)

    async def incoming_events(self) -> AsyncIterator[dict[str, Any]]:
        while not self._closed:
            try:
                ev = await asyncio.wait_for(self.event_queue.get(), timeout=0.1)
                if ev is None:
                    break
                if isinstance(ev, Exception):
                    raise ev
                if "sessionResumptionUpdate" in ev:
                    sru = ev["sessionResumptionUpdate"]
                    if isinstance(sru, dict) and sru.get("resumable") and sru.get("newHandle"):
                        new_h = str(sru["newHandle"]).strip()
                        self.resumption_handle = new_h
                        yield {
                            "type": "session_resumption_update",
                            "handle": new_h,
                            "resumable": True,
                        }
                    continue
                if "goAway" in ev:
                    ga = ev.get("goAway")
                    yield {
                        "type": "go_away",
                        "time_left": ga.get("timeLeft") if isinstance(ga, dict) else None,
                    }
                    continue
                yield ev
            except asyncio.TimeoutError:
                if self._closed:
                    break
                continue

    async def close(self) -> None:
        self._closed = True
        self.event_queue.put_nowait(None)


class LegacyUpstreamAdapterWrapper(LiveUpstreamAdapter):
    """Wraps legacy raw websocket / fake upstream objects to adhere to LiveUpstreamAdapter."""

    def __init__(self, raw_upstream: Any, model_name: str = "gemini-live-2.5-flash-native-audio"):
        self.raw_upstream = raw_upstream
        self.model_name = model_name
        self.resumption_handle: str | None = None

    async def connect(
        self,
        voice: str,
        system_prompt: str,
        tools: list[dict[str, Any]],
        resumption_handle: str | None = None,
    ) -> None:
        if resumption_handle is not None:
            self.resumption_handle = resumption_handle

    async def send_audio(self, pcm_16k: bytes) -> None:
        b64 = base64.b64encode(pcm_16k).decode("ascii")
        payload = {
            "realtimeInput": {
                "audio": {"mimeType": "audio/pcm;rate=16000", "data": b64}
            }
        }
        await self.raw_upstream.send(json.dumps(payload))

    async def send_text_turn(self, text: str) -> None:
        payload = {
            "clientContent": {
                "turns": [{"role": "user", "parts": [{"text": text}]}],
                "turnComplete": True,
            }
        }
        await self.raw_upstream.send(json.dumps(payload, ensure_ascii=False))

    async def send_tool_response(self, call_id: str, name: str, output: dict[str, Any]) -> None:
        payload = {
            "toolResponse": {
                "functionResponses": [
                    {"id": call_id, "name": name, "response": {"output": output}}
                ]
            }
        }
        await self.raw_upstream.send(json.dumps(payload, ensure_ascii=False))

    async def interrupt(self) -> None:
        pass

    async def incoming_events(self) -> AsyncIterator[dict[str, Any]]:
        async for raw in self.raw_upstream:
            data = json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
            sru = data.get("sessionResumptionUpdate")
            if isinstance(sru, dict):
                new_handle = str(sru.get("newHandle") or "").strip()
                if sru.get("resumable") and new_handle:
                    self.resumption_handle = new_handle
                    yield {
                        "type": "session_resumption_update",
                        "handle": new_handle,
                        "resumable": True,
                    }
            if "goAway" in data:
                ga = data.get("goAway")
                yield {
                    "type": "go_away",
                    "time_left": ga.get("timeLeft") if isinstance(ga, dict) else None,
                }
            if "toolCall" in data:
                yield {
                    "type": "tool_call",
                    "calls": data["toolCall"].get("functionCalls") or [],
                }
                continue
            sc = data.get("serverContent")
            if not isinstance(sc, dict):
                continue
            if sc.get("interrupted"):
                yield {"type": "interrupted"}
            in_tr = sc.get("inputTranscription")
            if isinstance(in_tr, dict) and in_tr.get("text"):
                yield {
                    "type": "transcript",
                    "role": "user",
                    "text": str(in_tr["text"]),
                    "finished": bool(in_tr.get("finished")),
                }
            out_tr = sc.get("outputTranscription")
            if isinstance(out_tr, dict) and out_tr.get("text"):
                yield {
                    "type": "transcript",
                    "role": "assistant",
                    "text": str(out_tr["text"]),
                    "finished": bool(out_tr.get("finished")),
                }
            model_turn = sc.get("modelTurn")
            if isinstance(model_turn, dict):
                for part in model_turn.get("parts") or []:
                    inline = part.get("inlineData") if isinstance(part, dict) else None
                    if isinstance(inline, dict) and inline.get("data"):
                        pcm_out = base64.b64decode(inline["data"])
                        if pcm_out:
                            yield {"type": "audio", "data": pcm_out}
            if sc.get("turnComplete"):
                yield {"type": "turn_complete"}

    async def close(self) -> None:
        if hasattr(self.raw_upstream, "close"):
            await self.raw_upstream.close()


# ==============================================================================
# Router with Generation Epoch Fencing
# ==============================================================================


def detect_emotion_state(text: str, current_state: str = "calm") -> tuple[str, float]:
    """Analyze conversation context text for emotional tone and energy."""
    txt = text.strip()
    if not txt:
        return current_state, 0.5

    # 5-dimensional emotional state mapping
    if any(k in txt for k in ("好累", "终于弄完了", "叹气", "累死", "头疼", "睡觉", "熬夜", "筋疲力尽", "休息一下", "心累")):
        return "exhausted", 0.3
    if any(k in txt for k in ("快点", "马上", "赶不及", "出问题", "紧急", "立刻", "抓紧", "要迟到", "着火", "报警")):
        return "urgent", 0.9
    if any(k in txt for k in ("太棒了", "哈哈", "搞定啦", "开心", "牛逼", "好耶", "完美", "太好了", "惊喜", "高兴")):
        return "excited", 0.85
    if any(k in txt for k in ("分析", "为什么", "方案", "怎么看", "排查", "思考", "评估", "对比", "琢磨", "深思")):
        return "thoughtful", 0.65

    return "calm", 0.5


async def _invoke_adapter_connect(
    adapter: LiveUpstreamAdapter,
    voice: str,
    sys_prompt: str,
    tools: list[dict[str, Any]],
    handle: str | None,
) -> None:
    setattr(adapter, "resumption_handle", handle)
    params = inspect.signature(adapter.connect).parameters
    if "resumption_handle" in params:
        await adapter.connect(voice, sys_prompt, tools, resumption_handle=handle)  # type: ignore[call-arg]
    else:
        await adapter.connect(voice, sys_prompt, tools)


def voice_live_router(
    state: Path,
    conversation: Any = None,
    next_steps_service: Any = None,
    personal_hub: Any = None,
    upstream_factory: Callable[[str, str], Any] | None = None,
    adapter_factory: Callable[[str, str, list[dict[str, Any]]], Any] | None = None,
    default_adapter: str = "gemini",
    records_dir: Path | None = None,
    vault_dir: Path | None = None,
    memory_root: Path | None = None,
    events_dir: Path | None = None,
    summary_model: Any = None,
) -> APIRouter:
    router = APIRouter()
    token_file = state / "token"

    def authorized(ws: WebSocket) -> bool:
        expected = token_file.read_text().strip() if token_file.exists() else ""
        if not expected:
            return False
        presented = ws.headers.get("authorization", "")
        if hmac.compare_digest(presented, "Bearer " + expected):
            return True
        q_tok = ws.query_params.get("token", "")
        if q_tok and hmac.compare_digest(q_tok, expected):
            return True
        return False

    @router.websocket("/voice/live")
    async def live_session(ws: WebSocket):
        if not authorized(ws):
            await ws.close(code=1008)
            return
        await ws.accept()
        requested_voice = ws.query_params.get("voice", "Aoede").strip()
        voice = requested_voice if requested_voice in VOICES else "Aoede"
        session_id = (
            ws.query_params.get("session")
            or ws.query_params.get("session_id")
            or f"com-live-{uuid.uuid4().hex[:12]}"
        ).strip()
        resume_requested = ws.query_params.get("resume", "").strip().lower() in ("1", "true", "yes")
        current_handle: str | None = get_session_handle(session_id) if resume_requested else None
        sys_prompt = build_system_instruction(next_steps_service, personal_hub, conversation)

        # Adapter resolution
        adapter: LiveUpstreamAdapter
        try:
            if adapter_factory is not None:
                af_res = adapter_factory(voice, sys_prompt, LIVE_TOOLS)
                adapter = await af_res if inspect.isawaitable(af_res) else af_res
                await _invoke_adapter_connect(adapter, voice, sys_prompt, LIVE_TOOLS, current_handle)
            elif upstream_factory is not None:
                uf_res = upstream_factory(voice, sys_prompt)
                res = await uf_res if inspect.isawaitable(uf_res) else uf_res
                if isinstance(res, tuple):
                    raw_up, m_name = res
                else:
                    raw_up, m_name = res, "gemini-live-2.5-flash-native-audio"
                if isinstance(raw_up, LiveUpstreamAdapter):
                    adapter = raw_up
                else:
                    adapter = LegacyUpstreamAdapterWrapper(raw_up, m_name)
                await _invoke_adapter_connect(adapter, voice, sys_prompt, LIVE_TOOLS, current_handle)
            else:
                adapter_name = ws.query_params.get("adapter", default_adapter).strip().lower()
                if adapter_name == "mock":
                    adapter = MockLiveAdapter()
                elif adapter_name == "openai":
                    adapter = OpenAIRealtimeAdapter()
                else:
                    adapter = GeminiLiveAdapter()
                await _invoke_adapter_connect(adapter, voice, sys_prompt, LIVE_TOOLS, current_handle)
        except Exception as exc:  # noqa: BLE001
            with contextlib.suppress(Exception):
                await ws.send_text(
                    json.dumps(
                        {"type": "error", "message": f"实时语音连接未建立：{exc}"},
                        ensure_ascii=False,
                    )
                )
                await ws.close()
            return

        # Generation Epoch State
        active_epoch: int = 1
        dropped_audio_frames: int = 0
        audio_suppressed: bool = False

        # Session tracking for post-call summary & interactive features
        session_turns: list[dict[str, Any]] = []
        session_tools: list[dict[str, Any]] = []
        session_emotions: list[dict[str, Any]] = []
        active_emotion: dict[str, Any] = {"state": "calm", "energy": 0.5}
        summary_executed: bool = False

        await ws.send_text(
            json.dumps(
                {
                    "type": "ready",
                    "session_id": session_id,
                    "voice": voice,
                    "model": adapter.model_name,
                    "sample_rate_in": 16000,
                    "sample_rate_out": 24000,
                    "epoch": active_epoch,
                },
                ensure_ascii=False,
            )
        )

        user_parts: list[str] = []
        assistant_parts: list[str] = []
        turn_tools: list[dict[str, Any]] = []
        pending_tool_turn = False
        opening_turn_pending = False

        if not resume_requested:
            opening_turn_pending = True
            opening_prompt = build_opening_prompt(next_steps_service)
            with contextlib.suppress(Exception):
                await adapter.send_text_turn(opening_prompt)

        async def reconnect_upstream() -> bool:
            nonlocal adapter, current_handle
            handle_to_use = (
                get_session_handle(session_id)
                or current_handle
                or getattr(adapter, "resumption_handle", None)
            )
            if not handle_to_use:
                return False
            with contextlib.suppress(Exception):
                await adapter.close()
            if adapter_factory is not None:
                af_res = adapter_factory(voice, sys_prompt, LIVE_TOOLS)
                new_ad = await af_res if inspect.isawaitable(af_res) else af_res
                await _invoke_adapter_connect(new_ad, voice, sys_prompt, LIVE_TOOLS, handle_to_use)
                adapter = new_ad
            elif upstream_factory is not None:
                uf_res = upstream_factory(voice, sys_prompt)
                res = await uf_res if inspect.isawaitable(uf_res) else uf_res
                raw_up, m_name = res if isinstance(res, tuple) else (res, "gemini-live-2.5-flash-native-audio")
                new_ad = raw_up if isinstance(raw_up, LiveUpstreamAdapter) else LegacyUpstreamAdapterWrapper(raw_up, m_name)
                await _invoke_adapter_connect(new_ad, voice, sys_prompt, LIVE_TOOLS, handle_to_use)
                adapter = new_ad
            else:
                await _invoke_adapter_connect(adapter, voice, sys_prompt, LIVE_TOOLS, handle_to_use)
            return True

        async def handle_interrupt(source: str):
            """Generation Epoch Fencing: advance epoch and purge stale in-flight frames."""
            nonlocal active_epoch, dropped_audio_frames, audio_suppressed
            active_epoch += 1
            audio_suppressed = True
            # Tell upstream to abort generation
            with contextlib.suppress(Exception):
                await adapter.interrupt()
            # Notify client of the new epoch
            await ws.send_text(
                json.dumps(
                    {
                        "type": "interrupted",
                        "epoch": active_epoch,
                        "source": source,
                    },
                    ensure_ascii=False,
                )
            )

        async def client_to_upstream():
            nonlocal summary_executed, active_emotion, audio_suppressed, opening_turn_pending
            try:
                while True:
                    msg = await ws.receive()
                    if msg.get("type") == "websocket.disconnect":
                        return
                    if (pcm := msg.get("bytes")) is not None:
                        if not pcm:
                            continue
                        await adapter.send_audio(pcm)
                    elif (raw_text := msg.get("text")) is not None:
                        try:
                            event = json.loads(raw_text)
                        except ValueError:
                            continue
                        etype = event.get("type")
                        if etype == "ping":
                            await ws.send_text(
                                json.dumps({"type": "pong", "epoch": active_epoch}, ensure_ascii=False)
                            )
                        elif etype in ("pause", "vad_pause", "audio_pause", "backchannel_request"):
                            duration_ms = float(event.get("duration_ms") or event.get("duration") or 0)
                            # Support 600-900ms pause backchanneling signal
                            if 600 <= duration_ms <= 900:
                                bc_text = str(event.get("preferred_text") or "嗯").strip()
                                await ws.send_text(
                                    json.dumps(
                                        {
                                            "type": "backchannel",
                                            "text": bc_text,
                                            "pause_duration_ms": duration_ms,
                                            "epoch": active_epoch,
                                        },
                                        ensure_ascii=False,
                                    )
                                )
                        elif etype == "end":
                            # Finalize any pending turn into session_turns
                            u_fin = "".join(user_parts).strip()
                            a_fin = "".join(assistant_parts).strip()
                            t_fin = list(turn_tools)
                            if u_fin or a_fin or t_fin:
                                session_turns.append({
                                    "user": u_fin,
                                    "assistant": a_fin,
                                    "tools": t_fin,
                                    "epoch": active_epoch,
                                    "timestamp": time.time(),
                                })
                                session_tools.extend(t_fin)
                                user_parts.clear()
                                assistant_parts.clear()
                                turn_tools.clear()

                            if not summary_executed:
                                try:
                                    s_res = await post_call_summary_pipeline(
                                        session_id=session_id,
                                        turns=list(session_turns),
                                        tools_run=list(session_tools),
                                        emotions=list(session_emotions),
                                        state=state,
                                        records_dir=records_dir,
                                        vault_dir=vault_dir,
                                        memory_root=memory_root,
                                        events_dir=events_dir,
                                        model=summary_model,
                                    )
                                    summary_executed = True
                                    await ws.send_text(
                                        json.dumps(
                                            {
                                                "type": "summary_ready",
                                                "session_id": session_id,
                                                "path": s_res.get("files", {}).get("markdown", ""),
                                                "tasks_created": s_res.get("tasks_created", []),
                                            },
                                            ensure_ascii=False,
                                        )
                                    )
                                except Exception as exc:
                                    print(f"post_call_summary_pipeline error on end: {exc}", flush=True)
                            return
                        elif etype == "interrupt":
                            await handle_interrupt(source="client")
                        elif etype == "text":
                            txt = str(event.get("text") or "").strip()
                            if txt:
                                opening_turn_pending = False
                                audio_suppressed = False
                                user_parts.append(txt)
                                full_u = "".join(user_parts)
                                # Emit both standardized transcript and legacy user_transcript
                                await ws.send_text(
                                    json.dumps(
                                        {
                                            "type": "transcript",
                                            "role": "user",
                                            "text": full_u,
                                            "finished": True,
                                            "epoch": active_epoch,
                                        },
                                        ensure_ascii=False,
                                    )
                                )
                                await ws.send_text(
                                    json.dumps(
                                        {
                                            "type": "user_transcript",
                                            "text": full_u,
                                            "finished": True,
                                            "epoch": active_epoch,
                                        },
                                        ensure_ascii=False,
                                    )
                                )
                                await adapter.send_text_turn(txt)
            except (WebSocketDisconnect, asyncio.CancelledError):
                return
            except Exception as exc:  # noqa: BLE001
                print(f"voice_live client_to_upstream error: {exc}", flush=True)

        async def upstream_to_client():
            nonlocal pending_tool_turn, dropped_audio_frames, active_emotion, audio_suppressed
            nonlocal current_handle, opening_turn_pending
            try:
                while True:
                    should_reconnect = False
                    try:
                        async for event in adapter.incoming_events():
                            ev_type = event.get("type")

                            if ev_type == "session_resumption_update":
                                new_h = str(event.get("handle") or "").strip()
                                if event.get("resumable", True) and new_h:
                                    current_handle = new_h
                                    save_session_handle(session_id, new_h)
                                continue

                            if ev_type in ("go_away", "goAway"):
                                should_reconnect = True
                                break

                            if ev_type == "interrupted":
                                await handle_interrupt(source="server")
                                continue

                            if ev_type == "audio":
                                pcm_data = event.get("data") or b""
                                if pcm_data:
                                    if event.get("epoch") is not None:
                                        frame_epoch = int(event["epoch"])
                                        if frame_epoch == active_epoch:
                                            audio_suppressed = False
                                            await ws.send_bytes(pcm_data)
                                        else:
                                            dropped_audio_frames += 1
                                    else:
                                        if audio_suppressed:
                                            dropped_audio_frames += 1
                                        else:
                                            await ws.send_bytes(pcm_data)
                                continue

                            if ev_type == "transcript":
                                role = event.get("role", "assistant")
                                txt = str(event.get("text") or "")
                                finished = bool(event.get("finished", False))
                                if role == "user":
                                    if txt.startswith(OPENING_TURN_PREFIX):
                                        continue
                                    opening_turn_pending = False
                                    user_parts.append(txt)
                                    full_u = "".join(user_parts).strip()
                                    await ws.send_text(
                                        json.dumps(
                                            {
                                                "type": "transcript",
                                                "role": "user",
                                                "text": full_u,
                                                "finished": finished,
                                                "epoch": active_epoch,
                                            },
                                            ensure_ascii=False,
                                        )
                                    )
                                    await ws.send_text(
                                        json.dumps(
                                            {
                                                "type": "user_transcript",
                                                "text": full_u,
                                                "finished": finished,
                                                "epoch": active_epoch,
                                            },
                                            ensure_ascii=False,
                                        )
                                    )
                                else:
                                    assistant_parts.append(txt)
                                    full_a = "".join(assistant_parts).strip()
                                    await ws.send_text(
                                        json.dumps(
                                            {
                                                "type": "transcript",
                                                "role": "assistant",
                                                "text": full_a,
                                                "finished": finished,
                                                "epoch": active_epoch,
                                            },
                                            ensure_ascii=False,
                                        )
                                    )
                                    await ws.send_text(
                                        json.dumps(
                                            {
                                                "type": "assistant_transcript",
                                                "text": full_a,
                                                "finished": finished,
                                                "epoch": active_epoch,
                                            },
                                            ensure_ascii=False,
                                        )
                                    )
                                continue

                            if ev_type == "emotion":
                                st = str(event.get("state", "calm"))
                                eg = float(event.get("energy", 0.5))
                                active_emotion = {"state": st, "energy": eg}
                                session_emotions.append({
                                    "state": st,
                                    "energy": eg,
                                    "timestamp": time.time(),
                                    "source": "upstream",
                                })
                                await ws.send_text(
                                    json.dumps(
                                        {
                                            "type": "emotion",
                                            "state": st,
                                            "energy": eg,
                                            "epoch": active_epoch,
                                        },
                                        ensure_ascii=False,
                                    )
                                )
                                continue

                            if ev_type == "tool_call":
                                opening_turn_pending = False
                                pending_tool_turn = True
                                calls = event.get("calls") or []
                                for fc in calls:
                                    fname = str(fc.get("name") or "")
                                    fargs = fc.get("args") or {}
                                    fid = str(fc.get("id") or "")
                                    started_at = time.time()
                                    await ws.send_text(
                                        json.dumps(
                                            {
                                                "type": "tool_call",
                                                "name": fname,
                                                "arguments": fargs,
                                                "title": f"正在执行 {fname}…",
                                                "status": "running",
                                                "state": "executing",
                                                "epoch": active_epoch,
                                            },
                                            ensure_ascii=False,
                                        )
                                    )
                                    try:
                                        title, result = await execute_live_tool(
                                            fname,
                                            fargs,
                                            state=state,
                                            conversation=conversation,
                                            next_steps_service=next_steps_service,
                                        )
                                        ok = True
                                    except Exception as exc:  # noqa: BLE001
                                        title = f"{fname} 执行失败"
                                        result = {"error": str(exc)}
                                        ok = False
                                    finished_at = time.time()
                                    turn_tools.append(
                                        {
                                            "name": fname,
                                            "title": title,
                                            "ok": ok,
                                            "arguments": fargs,
                                            "result": result,
                                            "started_at": started_at,
                                            "finished_at": finished_at,
                                        }
                                    )
                                    await ws.send_text(
                                        json.dumps(
                                            {
                                                "type": "tool_call",
                                                "name": fname,
                                                "arguments": fargs,
                                                "title": title,
                                                "status": "done" if ok else "failed",
                                                "state": "completed" if ok else "failed",
                                                "epoch": active_epoch,
                                            },
                                            ensure_ascii=False,
                                        )
                                    )
                                    await adapter.send_tool_response(fid, fname, result)
                                continue

                            if ev_type == "turn_complete":
                                audio_suppressed = False
                                if pending_tool_turn and not assistant_parts:
                                    pending_tool_turn = False
                                    continue
                                pending_tool_turn = False
                                u_txt = "".join(user_parts).strip()
                                a_txt = "".join(assistant_parts).strip()
                                tools_snapshot = list(turn_tools)
                                user_parts.clear()
                                assistant_parts.clear()
                                turn_tools.clear()

                                is_hidden_opening = opening_turn_pending and not u_txt and not tools_snapshot
                                opening_turn_pending = False

                                if not is_hidden_opening and (u_txt or a_txt or tools_snapshot):
                                    session_turns.append({
                                        "user": u_txt,
                                        "assistant": a_txt,
                                        "tools": tools_snapshot,
                                        "epoch": active_epoch,
                                        "timestamp": time.time(),
                                    })
                                    session_tools.extend(tools_snapshot)
                                await ws.send_text(
                                    json.dumps(
                                        {
                                            "type": "turn_complete",
                                            "user_text": u_txt,
                                            "assistant_text": a_txt,
                                            "epoch": active_epoch,
                                        },
                                        ensure_ascii=False,
                                    )
                                )
                                if not is_hidden_opening and conversation is not None and (u_txt or a_txt or tools_snapshot):
                                    async def _save_bg(u: str, a: str, t: list[dict[str, Any]]) -> None:
                                        with contextlib.suppress(Exception):
                                            await asyncio.to_thread(record_live_turn, conversation, u, a, t)
                                    asyncio.create_task(_save_bg(u_txt, a_txt, tools_snapshot))
                                continue

                        if should_reconnect:
                            reconnected = await reconnect_upstream()
                            if reconnected:
                                continue
                            raise RuntimeError("收到 goAway 但无有效恢复句柄，重连失败")
                        break
                    except (WebSocketDisconnect, asyncio.CancelledError):
                        raise
                    except Exception as stream_exc:  # noqa: BLE001
                        try:
                            reconnected = await reconnect_upstream()
                        except Exception as reconn_exc:  # noqa: BLE001
                            reconnected = False
                            stream_exc = reconn_exc
                        if reconnected:
                            continue
                        raise stream_exc

            except (WebSocketDisconnect, asyncio.CancelledError):
                return
            except Exception as exc:  # noqa: BLE001
                with contextlib.suppress(Exception):
                    await ws.send_text(
                        json.dumps({"type": "error", "message": f"语音流中断：{exc}"}, ensure_ascii=False)
                    )

        t_in = asyncio.create_task(client_to_upstream())
        t_out = asyncio.create_task(upstream_to_client())
        try:
            await asyncio.wait({t_in, t_out}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            t_in.cancel()
            t_out.cancel()
            u_fin = "".join(user_parts).strip()
            a_fin = "".join(assistant_parts).strip()
            t_fin = list(turn_tools)
            if u_fin or a_fin or t_fin:
                session_turns.append({
                    "user": u_fin,
                    "assistant": a_fin,
                    "tools": t_fin,
                    "epoch": active_epoch,
                    "timestamp": time.time(),
                })
                session_tools.extend(t_fin)
            if conversation is not None and (u_fin or a_fin or t_fin):
                with contextlib.suppress(Exception):
                    record_live_turn(
                        conversation,
                        u_fin,
                        a_fin,
                        t_fin,
                    )

            # Automated post-call summary pipeline triggered on WebSocket session disconnect/close
            if not summary_executed:
                try:
                    await post_call_summary_pipeline(
                        session_id=session_id,
                        turns=list(session_turns),
                        tools_run=list(session_tools),
                        emotions=list(session_emotions),
                        state=state,
                        records_dir=records_dir,
                        vault_dir=vault_dir,
                        memory_root=memory_root,
                        events_dir=events_dir,
                        model=summary_model,
                    )
                    summary_executed = True
                except Exception as exc:  # noqa: BLE001
                    print(f"post_call_summary_pipeline in finally failed: {exc}", flush=True)

            with contextlib.suppress(Exception):
                await adapter.close()

    return router
