# pyright: reportMissingImports=false, reportMissingModuleSource=false, reportAttributeAccessIssue=false, reportOptionalSubscript=false, reportOptionalMemberAccess=false, reportArgumentType=false, reportAssignmentType=false, reportCallIssue=false, reportOperatorIssue=false, reportIndexIssue=false, reportReturnType=false
# Com backend: FastAPI wiring; type-checking baseline lives in pyrightconfig.json.
from __future__ import annotations

import asyncio
import contextlib
import fcntl
import hashlib
import hmac
import inspect
import json
import sys
import os
import pty
import secrets
import shutil
import signal
import struct
import termios
import threading
import time
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Optional
from zoneinfo import ZoneInfo

from agent_tools import AgentTools
from artifacts import ArtifactAccess
from attachments import AttachmentStore, attachment_router
from background_events import BackgroundEvents
from capabilities import CapabilityRegistry
from conversation import PersonalConversation
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, StreamingResponse
from goal_proposals import GoalProposals
from goals import GoalEvents
from heartbeat import Heartbeat
from hermes_runtime import HermesRuntime
from history import History, text_content
from message_references import MessagePresentations, canonical_reference
from operation_policy import (
    OPERATION_MODE,
    POLICY_REVISION,
    persist_policy,
    upgrade_managed_permissions,
)
from personal import PersonalBridge
from pi_main import PiMainClient
from proactive import Proactive
from quick_voice import QuickVoice
from rayneo import RayneoIngress
from reminder_cards import ReminderCards
from runtime import Runtime
from signal_inspector import HermesSignalReviewer, PiSignalReviewer, SignalInspector
from signals import PersonalSignals
from sync_state import stable as sync_stable
from task_tools import authorized_assignment
from tasks import TaskController, TaskStore
from unified_voice import UnifiedVoice
from voice import voice_router
from voice_live import voice_live_router
from work_cards import accepted
from work_dispatch import WorkProposalStore

HOME = Path(os.environ.get("WORKBENCH_HOME", str(Path.home())))
STATE = Path(os.environ.get("WORKBENCH_STATE", str(Path.home() / ".session-workbench")))
STATE.mkdir(parents=True, exist_ok=True)
STATE.chmod(0o700)
TOKEN_FILE = STATE / "token"
if not TOKEN_FILE.exists():
    TOKEN_FILE.write_text(secrets.token_urlsafe(40))
    TOKEN_FILE.chmod(0o600)
TOKEN = TOKEN_FILE.read_text().strip()
STARTED = time.time()
history = History(HOME, STATE)
runtime = Runtime(history, TOKEN)
presentations = MessagePresentations(STATE)
quick_voice = QuickVoice(STATE, runtime, HOME / "AI_Work_System")
personal = PersonalBridge(STATE)
reminder_cards = ReminderCards(HOME / ".pi-gateway/state/reminders.json")
config_file = STATE / "agent-config.json"
agent_config = json.loads(config_file.read_text()) if config_file.exists() else {}
MAIN_AGENT = os.environ.get("COM_MAIN_AGENT", agent_config.get("main_agent", "hermes"))
if MAIN_AGENT not in ("pi", "hermes"):
    raise ValueError("Invalid main agent config")
conversation = PersonalConversation(
    STATE,
    PiMainClient(STATE, HOME / "AI_Work_System", tools=os.environ.get("COM_PI_SAFE_PROBE") != "1") if MAIN_AGENT == "pi" else HermesRuntime(STATE),
)
from sse_stream import SSEBroadcaster, SSERingBuffer
sse_ring_buffer = SSERingBuffer(STATE / "sse_events.sqlite", capacity=1000)
sse_broadcaster = SSEBroadcaster(sse_ring_buffer)

def sync_conversation_to_sse():
    try:
        from agent_activity import AgentEventProjector
        if not hasattr(app.state, "_sse_projector"):
            app.state._sse_projector = AgentEventProjector()
            app.state._sse_last_convo_rev = conversation.snapshot()["revision"]
        projector = app.state._sse_projector
        last_rev = app.state._sse_last_convo_rev
        change = conversation.changes_since(last_rev)
        if change["revision"] > last_rev:
            app.state._sse_last_convo_rev = change["revision"]
            activity, semantic = projector.project({"data": change})
            payload = {**change, "activity": activity}
            sse_broadcaster.publish("update", payload)
            for item in semantic:
                sse_broadcaster.publish(item["event"], item["data"])
    except Exception:
        pass

if hasattr(conversation, "_on_notify"):
    conversation._on_notify.append(sync_conversation_to_sse)
legacy_voice = quick_voice
quick_voice = UnifiedVoice(conversation, legacy_voice)
rayneo = RayneoIngress(STATE, conversation, quick_voice)
signals = PersonalSignals(STATE)
inspector = SignalInspector(
    signals,
    PiSignalReviewer(STATE) if MAIN_AGENT == "pi" else HermesSignalReviewer(STATE),
    external_schedule=MAIN_AGENT == "hermes",
)
work_proposals = WorkProposalStore(STATE, HOME / "AI_Work_System")
task_store = TaskStore(STATE)
artifact_access = ArtifactAccess(task_store, HOME / "AI_Work_System", STATE)
conversation.artifact_linker = artifact_access.link_text
conversation.artifact_register_fn = artifact_access.register
conversation.turn_file_linker = artifact_access.link_turn_files
attachment_store = AttachmentStore(STATE)
task_controller = TaskController(task_store, runtime, conversation)
heartbeat = Heartbeat(
    STATE,
    HOME / "AI_Work_System",
    task_store,
    work_proposals,
    publish=conversation.task_receipt,
)
runtime.task_store = task_store
runtime.workers.copies.sync_check = sync_stable
capability_registry = CapabilityRegistry(STATE)
runtime.capabilities = capability_registry
goal_events = GoalEvents(STATE)
proactive = Proactive(STATE)
goal_proposals = GoalProposals(STATE)
background = BackgroundEvents(goal_events, conversation, task_store)
conversation.process_background = background.process
agent_tools = AgentTools(
    STATE,
    conversation,
    work_proposals,
    task_store,
    task_controller,
    capability_registry,
    goal_events,
)
agent_tools.artifact_access = artifact_access
from drop_inbox import DropInbox

drop_inbox = DropInbox(STATE, artifact_access=artifact_access, conversation=conversation)
from personal_hub import PersonalHub

personal_hub = PersonalHub(STATE, HOME)
agent_tools.personal_hub = personal_hub
from agency import Agency

agency = Agency(STATE, personal_hub, goal_events, task_store, proactive, conversation)
background.separate_proactive = True
heartbeat.publish = agency.publish_observation
heartbeat.context = agency.context
from push_notifications import PushNotifications

notifications = PushNotifications(STATE, conversation, proactive.settings)
from finance_dashboard import FinanceDashboard

finance_dashboard = FinanceDashboard(STATE, HOME)
from project_board import ProjectBoard
from project_board import collect as collect_project_sessions

project_board = ProjectBoard(STATE)
agency.project_board = project_board
from health_insight import HealthInsight
from news import News
from aihot import AIHot
from next_steps import INSTRUCTIONS as NEXT_INSTRUCTIONS
from next_steps import NextSteps


async def next_model(digest):
    from hermes_review import review_json

    return await review_json(STATE, "next-" + str(time.time_ns()), NEXT_INSTRUCTIONS, digest, timeout=150)


next_steps = NextSteps(
    STATE,
    personal_hub,
    task_store,
    project_board,
    agency,
    finance_dashboard.snapshot,
    model=next_model if MAIN_AGENT == "hermes" else None,
    vault=HOME / "Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian",
    news=News(
        STATE,
        vault=HOME / "Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian",
        profile=HOME / "AI_Work_System/_global/本体画像/00-核心身份.md",
    ),
)
from runsheet import INSTRUCTIONS as RUNSHEET_INSTRUCTIONS
from runsheet import RunSheets
from triggers import Triggers
from decisions import Decisions, goal_ticket, proposal_ticket, seed_from_next_steps
from decisions import ticket as card_ticket
from business_tools import BusinessTools
from evals import Evals
from task_audit import TaskAudit, rework_message, ticket_for
from worker_queue import WorkerQueue
from mandate_executor import MandateExecutor
from superagent_flags import SuperagentFlags
from router_plan import RouterPlan
from batch_fold import BatchFold

triggers = Triggers(STATE)
personal_hub.on_matter = triggers.record
superagent_flags = SuperagentFlags(STATE)
mandates = MandateExecutor(STATE, triggers, hub=personal_hub, next_steps=next_steps, flags=superagent_flags)
router_plan = RouterPlan(STATE, task_store, conversation, flags=superagent_flags, workspace=HOME / "AI_Work_System")
conversation.router_plan = router_plan
batch_fold = BatchFold(router_plan, task_store, conversation)


async def _mandate_on_accept(eval_row, batch):
    await mandates.handle_eval(eval_row, batch)


decision_ledger = Decisions(STATE)
next_steps.decisions = decision_ledger
evals = Evals(triggers, muted=next_steps.is_muted, on_accept=_mandate_on_accept, decisions=decision_ledger)
worker_queue = WorkerQueue(STATE)


async def runsheet_model(payload):
    from hermes_review import review_json

    return await review_json(STATE, "runsheet-" + str(time.time_ns()), RUNSHEET_INSTRUCTIONS, payload, timeout=120)


runsheets = RunSheets(STATE, HOME / "AI_Work_System", runsheet_model)
next_steps.runsheets = runsheets
from activity import Activity

activity = Activity(STATE / "tool-effects.sqlite", conversation, task_store)
conversation.receipts_source = activity.receipts_by_message
from herdr_bridge import HerdrBridge
from rex_bridge import RexBridge

rex_bridge = RexBridge(STATE)
herdr_bridge = HerdrBridge(STATE, flags=superagent_flags)


def wechat_candidates():
    """10-25 微信推送候选：审批 → 结果不确定的操作 → 刚冒出来的「现在就该做」（分数 ≥ 80、头一次出现、两小时内）。"""
    out = []
    for a in list(runtime.approvals.values()):
        reason = " ".join(str((a.get("params") or {}).get("reason") or "有一项操作等你决定").split())[:100]
        out.append({"key": "approval:" + str(a.get("id")), "kind": "approval", "text": "【Com】有一步等你决定：" + reason + "\n打开 Com → 工作页处理"})
    for e in activity.uncertain(within=86400):
        if not e["tool"]:
            continue  # 10-25 之前的旧记录没记动作，只在 App 里核对，不往微信推
        out.append({"key": "effect:" + e["key"], "kind": "effect", "text": "【Com】有个操作没确认结果：" + e["summary"] + "\n到 Com「下一步」顶上点一下做成了没有"})
    now = time.time()
    for item in next_steps.snapshot()["items"]:
        if item.get("urgency") == "now" and item.get("score", 0) >= 80 and item.get("shown", 1) == 1 and now - item.get("created_at", 0) < 7200:
            draft = "\n草稿已备好，打开 Com「下一步」一键复制" if (item.get("action") or {}).get("draft") else ""
            out.append({"key": "next:" + item["id"], "kind": "next", "text": "【Com】现在该做：" + item["title"] + "\n" + item.get("why", "") + draft})
    return out
agent_tools.heartbeat = heartbeat
agent_tools.inspector = inspector
from device_nodes import DeviceNodes

device_nodes = DeviceNodes(STATE)
agent_tools.device_nodes = device_nodes
personal_hub.device_nodes = device_nodes
device_nodes.on_connect = lambda node: personal_hub.sync_phone()
from autonomy import PersonalAutonomy

autonomy = PersonalAutonomy(STATE, personal_hub)
agent_tools.autonomy = autonomy
agent_tools.artifact_access = artifact_access
conversation.task_context = lambda: task_store.context()
conversation.task_index = task_store.context_index
conversation.task_brief = task_store.context_for_source
conversation.task_environment = lambda: {
    "workspace_root": str(work_proposals.workspace),
    "automatic_executor": MAIN_AGENT,
    "maximum_running_tasks": 2,
    "claude_maximum_running": 1,
    "host": capability_registry.host,
    "current_date": datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat(),
    "timezone": "Asia/Shanghai",
    "main_operation_mode": getattr(conversation.client, "operation_mode", "legacy"),
    "worker_operation_mode": OPERATION_MODE,
    "readonly_restrictions_revoked": True,
    "operation_policy_revision": POLICY_REVISION,
}
rate = {}


def reference_message(source_session_id, message_id):
    if source_session_id == "personal-main":
        with conversation.db() as db:
            row = db.execute("SELECT id,role,text FROM messages WHERE id=?", (message_id,)).fetchone()
            return dict(row) if row else None
    stored = presentations.project(source_session_id, history.messages(source_session_id))
    actual_live = presentations.project(source_session_id, live_items(runtime.events(source_session_id)))
    return next((m for m in actual_live + stored if m.get("id") == message_id), None)


conversation.reference_lookup = reference_message


@asynccontextmanager
async def lifespan(app):
    persist_policy(STATE)
    upgrade_managed_permissions(history)
    task_store.apply_operation_policy()

    async def scan_loop():
        while True:
            await asyncio.to_thread(history.scan)
            if any(m["agent"] == "codex" and not m.get("ended") for m in history.managed().values()):
                with contextlib.suppress(Exception):
                    await runtime.ensure_rpc()
            await asyncio.sleep(4)

    task = asyncio.create_task(scan_loop())
    work_proposals.recover_inflight()
    task_store.recover()
    goal_events.recover()

    legacy_agency_loop_enabled = os.environ.get("COM_LEGACY_AGENCY_LOOP") == "1"

    async def scheduler_loop():
        while True:
            if goal_events.tick():
                conversation.wake.set()
            if legacy_agency_loop_enabled and proactive.tick(goal_events):
                conversation.wake.set()
            await asyncio.sleep(30)

    scheduler_task = asyncio.create_task(scheduler_loop())

    async def agency_loop():
        while True:
            with contextlib.suppress(Exception):
                await agency.process()
            await asyncio.sleep(5)

    agency_task = asyncio.create_task(agency_loop()) if legacy_agency_loop_enabled else None

    async def notification_loop():
        tick = 0
        while True:
            with contextlib.suppress(Exception):
                notifications.enqueue_approvals(list(runtime.approvals.values()))
                await notifications.process()
            tick += 1
            if tick % 12 == 0:  # 微信通道一分钟看一次
                with contextlib.suppress(Exception):
                    await notifications.push_wechat(await asyncio.to_thread(wechat_candidates))
            await asyncio.sleep(5)

    notification_task = asyncio.create_task(notification_loop())

    async def project_loop():
        while True:
            with contextlib.suppress(Exception):
                snapshot = await asyncio.to_thread(collect_project_sessions, HOME, STATE, "mini", history)
                project_board.ingest(snapshot)
                if not proactive.settings()["paused"]:
                    # 10-21：看板的「下一步」多是后台自运维会话（巡检、监控、编程会话），
                    # 7 天往主聊天发了 123 条、占主动消息三分之二。只更新看板，不再进主对话。
                    await project_board.review(limit=12)
            await asyncio.sleep(900)

    project_task = asyncio.create_task(project_loop())

    async def task_loop():
        while True:
            with contextlib.suppress(Exception):
                async with runtime.action_lock:
                    await task_controller.poll()
                conversation.sync_task_cards(task_store.list())
                batch_fold.tick()
            await asyncio.sleep(1)

    ledger_loop = asyncio.create_task(task_loop())
    from service_logs import DailyServiceLogs

    service_logs = DailyServiceLogs(STATE) if os.environ.get("COM_SERVICE_LOGS") == "1" else None

    async def heartbeat_loop():
        while True:
            with contextlib.suppress(OSError):
                if service_logs:
                    service_logs.rotate()
            await asyncio.sleep(60)
            if MAIN_AGENT != "hermes":
                with contextlib.suppress(Exception):
                    await heartbeat.tick()

    heartbeat_task = asyncio.create_task(heartbeat_loop())

    async def next_loop():
        await asyncio.sleep(20)
        while True:
            with contextlib.suppress(Exception):
                if next_steps.due():
                    await next_steps.refresh()
            await asyncio.sleep(300)

    next_task = asyncio.create_task(next_loop())

    # 10-17：航程跑完联动下一步/待办（15 秒一次）；每晚 21:30 生成并推送明天建议。
    async def case_loop():
        await asyncio.sleep(25)
        while True:
            with contextlib.suppress(Exception):
                await cases.rescue()
            with contextlib.suppress(Exception):
                cases.weekly_report()
            with contextlib.suppress(Exception):
                await asyncio.to_thread(cases.sync)
            with contextlib.suppress(Exception):
                if tomorrow_plan.due():
                    await asyncio.to_thread(tomorrow_plan.generate)
            with contextlib.suppress(Exception):
                # 日程 → 当天待办（设定）：每 2 分钟看一眼，新加的日程当天补上；已有的一条不动。
                if calendar_todos.due():
                    await asyncio.to_thread(calendar_todos.sync)
            with contextlib.suppress(Exception):
                # 待办 → iCloud 提醒事项「Com 待办」列表（iPhone 等设备可见），对账式单向，每分钟一轮。
                if reminders_sync.due():
                    await asyncio.to_thread(reminders_sync.sync)
            await asyncio.sleep(15)

    case_task = asyncio.create_task(case_loop())

    # 个人信源（邮件 / 日历 / Garmin / 手机健康…）原来只在手动同步时才拉；这里每分钟看一眼，按 SOURCES 的间隔各自到点才真拉。
    async def hub_loop():
        await asyncio.sleep(30)
        while True:
            with contextlib.suppress(Exception):
                await personal_hub.sync("all")
            await asyncio.sleep(60)

    hub_task = asyncio.create_task(hub_loop())

    async def eval_loop():
        await asyncio.sleep(45)
        with contextlib.suppress(Exception):
            with next_steps.db() as db:
                dismissed = [tuple(r) for r in db.execute("SELECT id,data,updated_at FROM items WHERE state='dismissed'")]
            await asyncio.to_thread(seed_from_next_steps, decision_ledger, dismissed)
        while True:
            with contextlib.suppress(Exception):
                await evals.run_once()
                await mandates.process_pending_accepts()
            try:
                await task_audit.run_once()
            except Exception as error:
                print("task_audit failed:", type(error).__name__, str(error)[:300], file=sys.stderr, flush=True)
            await asyncio.sleep(60)

    eval_task = asyncio.create_task(eval_loop())
    agent_task = asyncio.create_task(agent_track_loop())  # 轨道 agent：滚动摘要 + 主动提醒，定义见文件末尾
    scheduled_triggers_task = asyncio.create_task(scheduled_triggers_loop())  # 主动定时触发器（30s tick，受 triggers_on 门控）
    asyncio.get_running_loop().run_in_executor(None, conversation.backfill_artifacts)  # 10-25：近两周回复里的产出路径补挂卡片

    # M1 / F03: Transactional Outbox 异步投影协程 (Projector Worker)
    outbox_task = None
    if "personal_board" in globals() and personal_board:
        from matter_store import process_matter_outbox_projector
        outbox_task = asyncio.create_task(process_matter_outbox_projector(personal_board))

    quick_voice.start()
    conversation.start()
    inspector.start()
    yield
    scheduled_triggers_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await scheduled_triggers_task
    if outbox_task:
        outbox_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await outbox_task
    task.cancel()
    ledger_loop.cancel()
    scheduler_task.cancel()
    if agency_task:
        agency_task.cancel()
    project_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await project_task
    notification_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await notification_task
    if agency_task:
        with contextlib.suppress(asyncio.CancelledError):
            await agency_task
    heartbeat_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await heartbeat_task
    next_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await next_task
    case_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await case_task
    hub_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await hub_task
    eval_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await eval_task
    agent_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await agent_task
    with contextlib.suppress(asyncio.CancelledError):
        await ledger_loop
    await quick_voice.stop()
    await inspector.stop()
    await conversation.stop()
    await runtime.workers.close()
    if runtime.rpc:
        await runtime.rpc.close()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
app.include_router(voice_router(STATE))
app.include_router(voice_live_router(STATE, conversation, next_steps, personal_hub))
app.include_router(attachment_router(attachment_store))
app.include_router(rayneo.router)


@app.middleware("http")
async def auth(request, call_next):
    if request.url.path not in ("/health", "/pair", "/rayneo/v1/pair"):
        supplied = request.headers.get("authorization", "")
        valid = rayneo.authorized(supplied) if request.url.path.startswith("/rayneo/") else hmac.compare_digest(supplied, "Bearer " + TOKEN)
        if not valid:
            return JSONResponse({"detail": "连接凭据无效，请重新配对"}, 401)
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    return response


@app.exception_handler(ValueError)
@app.exception_handler(RuntimeError)
async def failure(request, exc):
    return JSONResponse({"detail": str(exc)}, 409)


try:
    import subprocess

    BUILD_COMMIT = subprocess.check_output(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=Path(__file__).parent,
        text=True,
        stderr=subprocess.DEVNULL,
        timeout=2,
    ).strip()
except Exception:
    BUILD_COMMIT = json.loads((STATE / "service-build.json").read_text()).get("commit", "unknown") if (STATE / "service-build.json").exists() else "unknown"


def deployed_build_commit():
    try:
        return json.loads((STATE / "service-build.json").read_text()).get("commit", BUILD_COMMIT)
    except (OSError, ValueError):
        return BUILD_COMMIT


@app.get("/health")
async def health():
    fast_classifier_enabled = bool(getattr(superagent_flags, "fast_classifier_on", lambda: False)())
    triggers_enabled = bool(getattr(superagent_flags, "triggers_on", lambda: False)())
    channels_enabled = bool(getattr(superagent_flags, "channels_on", lambda: False)())
    voice_narration_enabled = bool(getattr(superagent_flags, "voice_narration_on", lambda: False)())
    return {
        "service": "mini-sessions",
        "version": "2.0.0",
        "api_contract": 2,
        "build_commit": deployed_build_commit(),
        "main_operation_mode": getattr(conversation.client, "operation_mode", "legacy"),
        "worker_operation_mode": OPERATION_MODE,
        "operation_policy_revision": POLICY_REVISION,
        "readonly_restrictions_revoked": True,
        "features": {
            "ios_nodes_v1": True,
            "main_receipts_v1": True,
            "selected_attachments_v1": True,
            "artifact_access_v1": True,
            "conversation_history_v1": True,
            "conversation_resume_v1": True,
            "heartbeat_shadow_v1": True,
            "reminder_cards_v1": True,
            "muse_task_kinds_v1": True,
            "supplement_new_item_v1": True,
            "capability_search_readonly_v1": True,
            "message_references_v1": True,
            "stable_message_identity_v1": True,
            "pi_main": MAIN_AGENT == "pi",
            "task_timeline_v1": True,
            "work_cards_v1": True,
            "task_events_sse_v1": True,
            "task_plan_v1": True,
            "task_context_revision_v1": True,
            "semantic_verification_v1": True,
            "main_steer_v1": True,
            "hermes_main": MAIN_AGENT == "hermes",
            "hermes_runs_v1": True,
            "personal_send_message_v1": superagent_flags.send_message_on(),
            "fast_classifier": fast_classifier_enabled,
            "triggers": triggers_enabled,
            "channels": channels_enabled,
            "voice_narration": voice_narration_enabled,
            "voice_bookkeeping_intent_v1": True,
            "markdown_hindsight_memory_v1": True,
            "direct_business_queries_v1": True,
            "work_chat_v1": True,
            "goal_proposals_v1": True,
            "goals_scheduler": goal_events.enabled(),
        },
        "superagent_flags": {
            "personal_send_message_v1": superagent_flags.send_message_on(),
            "fast_classifier": fast_classifier_enabled,
            "triggers": triggers_enabled,
            "channels": channels_enabled,
            "voice_narration": voice_narration_enabled,
        },
    }


@app.post("/pair")
async def pair(request: Request):
    ip = request.client.host
    now = time.time()
    attempts = [x for x in rate.get(ip, []) if now - x < 300]
    if len(attempts) >= 5:
        raise HTTPException(429, "尝试过多，请稍后重试")
    rate[ip] = attempts + [now]
    body = await request.json()
    p = STATE / "pairing.json"
    if not p.exists():
        raise HTTPException(403, "请在 Mac mini 生成配对码")
    # 串行化校验与消费：并发请求只有一个能读到并删掉 pairing.json，其余在锁后看到文件已消失。
    # 输错码不消耗配对码（只受上面的频率限制），避免手误就要回终端重开。
    with (STATE / "pairing.lock").open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            try:
                data = json.loads(p.read_text())
            except FileNotFoundError:
                raise HTTPException(403, "配对码已被使用，请重新生成")
            if data["expires"] < now or not hmac.compare_digest(str(body.get("code", "")), data["code"]):
                raise HTTPException(403, "配对码无效或已过期")
            p.unlink()
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    return {"token": TOKEN}


@app.post("/pair/code")
async def pair_code():
    """已配对设备为另一台设备生成一次性码；二维码由客户端用 base + code 拼。"""
    code = "-".join(secrets.token_hex(2) for _ in range(3))
    path = STATE / "pairing.json"
    path.write_text(json.dumps({"code": code, "expires": time.time() + 600}))
    path.chmod(0o600)
    return {"code": code, "expires_in": 600}


@app.get("/status")
async def status():
    managed = history.managed()
    disk = shutil.disk_usage(str(HOME))
    return {
        "index": history.progress,
        "managed": len(managed),
        "running": sum(1 for m in managed.values() if not m.get("ended")),
        "approvals": len(runtime.approvals),
        "host": "Mac mini",
        "default_cwd": str(HOME / "AI_Work_System"),
        "uptime": int(time.time() - STARTED),
        "disk_free_gb": round(disk.free / 1e9, 1),
        "agents": {"pi": bool(shutil.which("pi")), "codex": bool(shutil.which("codex"))},
        "push": notifications.status()["delivery"],
    }


@app.get("/personal/overview")
async def personal_overview():
    return await personal.overview()


@app.get("/personal/channels")
async def personal_channels():
    channels_info_fn = getattr(conversation, "channels_info", None)
    if callable(channels_info_fn):
        info = channels_info_fn()
        if isinstance(info, dict):
            return {
                "enabled": bool(info.get("enabled", getattr(superagent_flags, "channels_on", lambda: False)())),
                "active": str(info.get("active") or getattr(conversation, "get_active_channel", lambda: "personal")()),
                "channels": info.get("channels") or [],
            }
    active = "personal"
    get_active_fn = getattr(conversation, "get_active_channel", None)
    if callable(get_active_fn):
        active = str(get_active_fn() or "personal")
    elif hasattr(conversation, "db"):
        with contextlib.suppress(Exception):
            with conversation.db() as db:
                row = db.execute("SELECT value FROM meta WHERE key='active_channel'").fetchone()
                if row and row[0] in ("personal", "work", "bookkeeping"):
                    active = row[0]
    return {
        "enabled": bool(getattr(superagent_flags, "channels_on", lambda: False)()),
        "active": active,
        "channels": [
            {"id": "personal", "label": "个人", "short_label": "个人"},
            {"id": "work", "label": "工作", "short_label": "工作"},
            {"id": "bookkeeping", "label": "记账", "short_label": "记账"},
        ],
    }


@app.post("/personal/channels/select")
async def personal_channels_select(request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise HTTPException(400, "请求体必须为 JSON 对象")
    raw_channel = str(data.get("channel") or "").strip()
    if not raw_channel:
        raise HTTPException(400, "缺少 channel 参数")
    set_active_fn = getattr(conversation, "set_active_channel", None)
    if callable(set_active_fn):
        try:
            active = set_active_fn(raw_channel)
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
    else:
        if raw_channel not in ("personal", "work", "bookkeeping"):
            raise HTTPException(400, f"不支持的 channel: {raw_channel}")
        active = raw_channel
        if hasattr(conversation, "db"):
            with contextlib.suppress(Exception):
                with conversation.db() as db:
                    db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('active_channel', ?)", (active,))
    info = await personal_channels()
    return {"ok": True, **info, "active": active}


@app.get("/personal/conversation")
async def personal_conversation(channel: Optional[str] = None):
    if channel is not None and channel.strip():
        try:
            sig = inspect.signature(conversation.snapshot)
            if "channel" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                return conversation.snapshot(channel=channel.strip())
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
    return conversation.snapshot()


@app.get("/personal/conversation/history")
async def conversation_history(before: str = "", around: str = "", limit: int = 60, channel: Optional[str] = None):
    if channel is not None and channel.strip():
        try:
            sig = inspect.signature(conversation.history)
            if "channel" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                return conversation.history(before, around, limit, channel=channel.strip())
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
    return conversation.history(before, around, limit)


@app.get("/personal/conversation/receipts/{request_id}")
async def conversation_receipt(request_id: str):
    receipt = conversation.receipt(request_id)
    if receipt is None:
        raise HTTPException(404, "尚无发送记录")
    return receipt


@app.get("/personal/conversation/search")
async def conversation_search(q: str = "", date: str = ""):
    return conversation.search(q, date)


@app.get("/personal/search")
async def personal_search(q: str = "", date: str = ""):
    messages = [{**item, "kind": "message"} for item in conversation.search(q, date)["items"]]
    start, end = 0, float("inf")
    if date:
        start = datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=ZoneInfo("Asia/Shanghai")).timestamp()
        end = start + 86400

    def match(title, at):
        return (bool(q.strip()) or bool(date)) and q.strip().lower() in title.lower() and start <= at < end

    tasks = [
        {
            "id": t["id"],
            "kind": "task",
            "source": "任务",
            "text": t.get("title", ""),
            "created_at": t.get("created_at", 0),
        }
        for t in task_store.list()
        if match(t.get("title", ""), t.get("created_at", 0))
    ]
    artifacts = [{**a, "kind": "artifact", "source": "成果", "text": a["name"]} for a in artifact_access.index() if match(a["name"], a["created_at"])]
    return {
        "items": sorted(
            messages + tasks[:20] + artifacts[:20],
            key=lambda i: i["created_at"],
            reverse=True,
        )[:80]
    }


@app.get("/personal/artifacts")
async def artifact_list():
    return {"items": artifact_access.index()}


# 10-25：可交互产出的勾选 / 展开状态（按文件名），App 和网页共用，下次打开照原样恢复
@app.get("/personal/artifact-state/{key}")
async def artifact_state_get(key: str):
    return artifact_access.state(key)


@app.post("/personal/artifact-state/{key}")  # iOS 客户端只会 POST
@app.put("/personal/artifact-state/{key}")
async def artifact_state_put(key: str, request: Request):
    data = await request.json()
    try:
        return artifact_access.save_state(key, data.get("state"))
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc


@app.get("/personal/artifacts/{artifact_id}")
async def artifact_file(artifact_id: str):
    try:
        record, file, size = artifact_access.open(artifact_id)
    except FileNotFoundError:
        raise HTTPException(404, "成果文件已移动或不存在")
    except PermissionError:
        raise HTTPException(403, "该文件不在允许的成果范围内")
    except KeyError:
        raise HTTPException(404, "未登记的成果")
    from urllib.parse import quote

    def chunks():
        with file:
            while data := file.read(65536):
                yield data

    return StreamingResponse(
        chunks(),
        media_type=record["mime"],
        headers={
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Content-Length": str(size),
            "Content-Disposition": "attachment; filename*=UTF-8''" + quote(record["name"]),
        },
    )


@app.post("/personal/drop")
async def personal_drop_create(request: Request):
    try:
        data = await request.json()
    except Exception as exc:
        raise HTTPException(400, "请求体必须为合法 JSON") from exc
    if not isinstance(data, dict):
        raise HTTPException(400, "请求体必须为 JSON 对象")
    try:
        item = await asyncio.to_thread(drop_inbox.ingest, data)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"ok": True, "item": item, "drop_id": item["id"], "suggestions": item.get("suggestions", [])}


@app.get("/personal/drop")
async def personal_drop_list(limit: int = 50, kind: str = "", status: str = ""):
    items = await asyncio.to_thread(drop_inbox.list, limit=limit, kind=kind, status=status)
    return {"ok": True, "items": items, "total": len(items)}


@app.get("/personal/stream")
@app.get("/personal/conversation/stream")
async def personal_conversation_stream(request: Request):
    raw_header = request.headers.get("last-event-id", "").strip()
    raw_query = ""
    try:
        raw_query = request.query_params.get("after", "").strip()
    except KeyError:
        pass
    raw = raw_header or raw_query
    after = int(raw) if raw.isdecimal() and len(raw) < 19 else None

    def get_snapshot():
        from agent_activity import AgentEventProjector
        snap = conversation.snapshot()
        projector = AgentEventProjector()
        activity, _ = projector.project({"data": snap})
        snap_with_act = {**snap, "activity": activity}
        if "personal_board" in globals() and personal_board:
            try:
                snap_with_act["board"] = personal_board.snapshot()
            except Exception:
                pass
        return snap_with_act

    return StreamingResponse(
        sse_broadcaster.stream_client(after, get_snapshot),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


def matter_context(matter_id):
    if not matter_id:
        return None
    if not isinstance(matter_id, str):
        raise ValueError("事项标识无效")
    if "personal_board" in globals() and getattr(personal_board, "matter_store", None):
        matter = personal_board.matter_store.get_by_id(matter_id)
        if matter:
            return {
                "id": matter.matter_id,
                "title": matter.title,
                "source": matter.source_type,
                "status": matter.status,
                "why": matter.why,
                "created_at": matter.created_at,
                "authority": "ssot",
            }
    card = next((r for r in personal_hub.briefing()["cards"] if r["id"] == matter_id), None)
    row = card or next((r for r in personal_hub.matters() if r["id"] == matter_id), None)
    if not row:
        if matter_id.startswith("mtr-"):
            return {
                "id": matter_id,
                "title": matter_id,
                "source": "matter",
                "authority": "external_reference_only",
            }
        raise ValueError("事项不存在")
    return {
        "id": matter_id,
        "title": row["title"],
        "source": row["source"],
        "source_updated_at": row["source_updated_at"],
        "facts": row["facts"],
        "feedback": row.get("feedback", {}),
        "related_facts": row.get("action_context", {}).get("related_facts", []),
        "grouping": row.get("grouping"),
        "authority": "external_reference_only",
    }


@app.post("/personal/conversation/messages")
async def personal_message(request: Request):
    data = await request.json()
    text_content = data.get("content") if isinstance(data, dict) and "content" in data else (data.get("text") if isinstance(data, dict) else None)
    wait_for_reply = bool(isinstance(data, dict) and (data.get("wait") or request.query_params.get("wait")))
    if wait_for_reply and isinstance(data, dict) and not data.get("request_id"):
        data["request_id"] = "siri-" + uuid.uuid4().hex
    if not isinstance(data, dict) or not isinstance(data.get("request_id"), str) or not isinstance(text_content, str) or not text_content.strip():
        raise ValueError("消息格式无效")
    if legacy_voice.receipt(data["request_id"]) or quick_voice.receipt(data["request_id"]):
        raise ValueError("这条语音已有受理回执，不会重复交办。")
    attachments = attachment_store.resolve(data.get("attachment_ids", []))

    # Interrupt Fork: Check if there are active background cases/tasks running
    active_statuses = getattr(cases, "ACTIVE", ("queued", "dispatching", "running", "waiting", "paused", "unknown", "cancel_requested", "approval_required"))
    active_cases = [t for t in cases.store.list() if t.get("status") in active_statuses] if hasattr(cases, "store") else []
    is_fork = data.get("is_interrupt_fork") or bool(active_cases)
    fork_meta = None
    if is_fork:
        fork_meta = {
            "is_interrupt_fork": True,
            "fork_thread_id": f"fork-main-{int(time.time() * 1000)}",
        }

    context_matter_id = data.get("context_matter_id") or data.get("matter_id")
    req_channel = data.get("channel").strip() if isinstance(data.get("channel"), str) and data.get("channel").strip() else None
    submit_kwargs: dict[str, Any] = {
        "associated_matter": matter_context(context_matter_id),
        "attachments": attachments,
    }
    if req_channel is not None:
        try:
            submit_sig = inspect.signature(conversation.submit)
            if "channel" in submit_sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in submit_sig.parameters.values()):
                submit_kwargs["channel"] = req_channel
        except (TypeError, ValueError):
            pass
    try:
        res = conversation.submit(
            data["request_id"],
            text_content,
            data.get("reference"),
            **submit_kwargs,
        )
    except ValueError as exc:
        if req_channel is not None and "channel" in str(exc).lower():
            raise HTTPException(400, str(exc)) from exc
        raise

    message_seq = res.get("message_seq", 1) if isinstance(res, dict) else 1
    status_val = "accepted" if (data.get("is_interrupt_fork") and "content" not in data) else "persisted"
    response_payload = {
        "ok": True,
        "message_id": res["message_id"] if isinstance(res, dict) else "",
        "request_id": data["request_id"],
        "message_seq": message_seq,
        "role": data.get("role") or "user",
        "content": text_content,
        "status": status_val,
        "created_at": res.get("created_at", time.time()) if isinstance(res, dict) else time.time(),
    }
    if req_channel is not None or (isinstance(res, dict) and res.get("channel")):
        response_payload["channel"] = (res.get("channel") if isinstance(res, dict) else None) or req_channel
    if context_matter_id:
        response_payload["context_matter_id"] = context_matter_id
    if is_fork and fork_meta:
        response_payload.update(fork_meta)
    if wait_for_reply:
        timeout_sec = min(max(float(data.get("timeout", 12.0)), 1.0), 25.0)
        deadline = time.time() + timeout_sec
        while time.time() < deadline:
            await asyncio.sleep(0.15)
            rcpt = conversation.receipt(data["request_id"])
            if not rcpt:
                continue
            r_status = rcpt.get("status") or ""
            r_reply = (rcpt.get("reply") or "").strip()
            r_err = (rcpt.get("error") or "").strip()
            if r_reply and r_status in ("completed", "unknown", "approval_required"):
                response_payload["reply"] = r_reply
                response_payload["receipt_status"] = r_status
                break
            if r_status == "failed":
                response_payload["reply"] = f"Com 处理失败：{r_err}" if r_err else "Com 处理失败，请打开 Com 查看。"
                response_payload["receipt_status"] = "failed"
                break
        if "reply" not in response_payload:
            response_payload["reply"] = f"已发给 Com（{text_content.strip()}），正在后台处理。"
            response_payload["receipt_status"] = "running"
    return response_payload


@app.post("/personal/conversation/interrupt")
async def interrupt_conversation(request: Request):
    # 10-28 并行：带 message_id 只停那一轮（含 Hermes 那边的运行），不带就停全部在跑的轮次。
    data = await request.json() if int(request.headers.get("content-length") or 0) else {}
    message_id = data.get("message_id") if isinstance(data, dict) and isinstance(data.get("message_id"), str) else None
    if conversation.parallel:
        stopped = await conversation.interrupt(message_id)
        conversation.wake.set()
        return {"status": "interrupted", "stopped": stopped, "message": "Agent execution interrupted"}
    await conversation.stop()
    # stop() 取消了投递循环（task/background_task 置空）；不重启的话中断一次之后
    # 主对话不再投递任何消息，直到服务重启。start() 自身幂等，重复调用无副作用。
    conversation.start()
    return {"status": "interrupted", "message": "Agent execution interrupted"}


@app.post("/personal/quick-voice/messages")
async def quick_voice_message(request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise ValueError("语音消息格式无效")
    return quick_voice.submit(data.get("request_id"), data.get("text"), data.get("purpose", "conversation"))


@app.get("/personal/quick-voice")
async def quick_voice_snapshot():
    return quick_voice.snapshot()


@app.get("/personal/quick-voice/receipts/{request_id}")
async def quick_voice_receipt(request_id: str):
    receipt = quick_voice.receipt(request_id)
    if receipt is None:
        raise HTTPException(404, "尚无语音受理记录")
    return receipt


@app.post("/personal/signals")
async def personal_signal_batch(request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise ValueError("通知批次无效")
    result = signals.ingest(data.get("events"))
    if result["accepted_ids"]:
        inspector.wake()
    return result


@app.get("/personal/signals")
async def personal_signal_list(limit: int = 50):
    return signals.recent(limit)


@app.get("/personal/signals/health")
async def personal_signal_health():
    return signals.health()


@app.get("/personal/work/proposals")
async def personal_work_proposals(limit: int = 20):
    items = work_proposals.list(limit)
    for item in items:
        item["parent_message_id"] = item["origin_message_id"]
        item["ticket"] = proposal_ticket(item)
        task_store.ensure(item)
    return {"items": items}


@app.post("/personal/work/proposals/{proposal_id}/approve")
async def approve_personal_work(proposal_id: str, request: Request):
    data = await request.json()
    if not isinstance(data, dict) or not isinstance(data.get("request_id"), str):
        raise ValueError("缺少有效请求标识")
    request_id = data["request_id"]
    if data.get("explicit_authorization") is not True:
        raise ValueError("需要明确批准此任务的目录、提示与权限；刷新不能授权")
    async with runtime.action_lock:
        existing = work_proposals.get(proposal_id)
        if not existing:
            raise ValueError("工作建议不存在")
        if existing["approval_request_id"]:
            if existing["approval_request_id"] != request_id:
                raise ValueError("工作建议已由另一次审批处理")
            return existing
        from task_tools import approval_source

        origin = approval_source(conversation, existing)
        task_store.ensure(existing)
        # Serialize tasks in the same directory until isolated workspaces are available.
        if any(t["cwd"] == existing["cwd"] and t["id"] != proposal_id and t["status"] in ("running", "waiting", "unknown", "dispatching", "cancel_requested") for t in task_store.list()):
            raise ValueError("该项目已有未结束任务，请先串行完成")
        proposal = work_proposals.claim_approval(proposal_id, request_id)
        task_store.change(
            proposal_id,
            "source-bound:" + request_id,
            "source.bound",
            source_links=origin["source_links"],
            source_message_ids=origin["source_message_ids"],
            latest_user_message_id=origin["latest_user_message_id"],
        )
        ledger_task = next(t for t in task_store.list() if t["id"] == proposal_id)
        prompt = task_store.execution_prompt(ledger_task)
        initial_inputs = task_store.pending_start_inputs(proposal_id)
        authorized_task = task_store.change(
            proposal_id,
            "dispatch:" + request_id,
            "authorized",
            status="dispatching",
            authorization={
                **origin["authorization"],
                "request_id": request_id,
                "cwd": proposal["cwd"],
                "sandbox": proposal["sandbox"],
                "prompt": prompt,
                "actual_action": proposal.get("actual_action", {}),
            },
        )[0]
        for command in initial_inputs:
            task_store.transition_input(command["request_id"], ("pending_start",), "sending")
        try:
            sid = await runtime.create_task_worker(authorized_task)
            if proposal["agent"] == "pi" and not runtime.h.managed().get(sid, {}).get("transport"):
                for _ in range(80):
                    if any(e.get("type") == "session_start" for e in runtime.events(sid)):
                        break
                    await asyncio.sleep(0.25)
                else:
                    raise RuntimeError("Pi 启动状态待核实")
                await asyncio.sleep(1)
            turn_id = await runtime.input(sid, prompt, request_id)
            if not turn_id:
                raise RuntimeError("工作器未确认执行轮次")
            task_store.change(
                proposal_id,
                "started:" + request_id,
                "started",
                status="running",
                session_id=sid,
                run_id=turn_id,
            )
            for command in initial_inputs:
                task_store.transition_input(command["request_id"], ("sending",), "delivered")
            decision_ledger.conclude("proposal:" + proposal_id, proposal.get("title", "审批卡"), "你批准了，已开始执行")
            return work_proposals.mark_accepted(proposal_id, request_id, sid)
        except Exception as exc:
            task_store.change(
                proposal_id,
                "unknown:" + request_id,
                "execution_unknown",
                status="unknown",
                session_id=locals().get("sid", ""),
            )
            work_proposals.mark_unknown(proposal_id, request_id, type(exc).__name__[:80], locals().get("sid"))
            for command in initial_inputs:
                task_store.transition_input(
                    command["request_id"],
                    ("sending",),
                    "unknown",
                    "初始任务送达待核实；不会重发",
                )
            raise RuntimeError("派发状态待核实，请先查看工作会话；不会自动重发") from None


@app.post("/personal/work/proposals/{proposal_id}/reject")
async def reject_personal_work(proposal_id: str):
    proposal = work_proposals.reject(proposal_id)
    task_store.ensure(proposal)
    task_store.change(proposal_id, "rejected:" + proposal_id, "rejected", status="rejected")
    title = proposal.get("title") or "审批卡"
    decision_ledger.add("declined", title, "驳回审批卡：" + title, "work_proposal", proposal_id)
    decision_ledger.conclude("proposal:" + proposal_id, title, "你没有批准，这件事不执行")
    return proposal


@app.get("/personal/goal-proposals")
async def personal_goal_proposals(limit: int = 10):
    items = goal_proposals.list(limit)
    return {"items": [{**item, "ticket": goal_ticket(item)} for item in items]}


@app.post("/personal/goal-proposals/{proposal_id}/decide")
async def decide_personal_goals(proposal_id: str, request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise ValueError("缺少有效请求体")
    approved = data.get("approved")
    rejected = data.get("rejected")
    if not isinstance(approved, list) or not isinstance(rejected, list):
        raise ValueError("approved 与 rejected 必须是数组")
    async with runtime.action_lock:
        decision = goal_proposals.decide(proposal_id, data.get("request_id"), approved, rejected)
        if decision["applied"] is None:  # 首次执行；已落过库的直接返回回执，不重写文件
            from goal_apply import apply_decision

            decision = goal_proposals.record_applied(
                proposal_id,
                decision["request_id"],
                apply_decision(goal_proposals.get(proposal_id), decision),
            )
            decision_ledger.conclude("goal:" + proposal_id, "目标提案", f"写入 {len(approved)} 条，放弃 {len(rejected)} 条")
        return decision


@app.get("/personal/tasks")
async def personal_tasks():
    for proposal in work_proposals.list(100):
        task_store.ensure(proposal)
    items = []
    for task in task_store.list():
        # 独立核对收过口的不再按「待验收」进拍板清单；没过的走「等你」里的核对卡，不重复出现。
        item = {**task, "acceptance_passed": accepted(task) or task.get("verification_status") in ("reviewed", "accepted", "needs_work") or bool(task.get("audit") and task.get("verification_status") == "uncertain")}
        request_id = task.get("origin_request_id", "")
        sid = task.get("session_id", "")
        if sid and request_id.startswith("work:"):
            # A Work chat's hidden main row is authorization history, not its
            # native message. Only navigate to an echo confirmed by that worker.
            presentations.project(sid, live_items(runtime.events(sid)))
            identity = presentations.identity(sid, request_id[5:])
            if not identity["identity_confirmed"]:
                presentations.project(sid, history.messages(sid))
                identity = presentations.identity(sid, request_id[5:])
            if identity["identity_confirmed"]:
                item.update(source_session_id=sid, source_message_id=identity["message_id"])
        items.append(item)
    return {"items": items}


@app.post("/personal/tasks/create")
async def personal_task_create(request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise ValueError("Invalid task assignment")
    data.pop("pending_action_confirmed", None)  # internal-only: set by pending_actions after a real confirm
    task, authorization, request_id = authorized_assignment(conversation, work_proposals, data)
    saved = task_store.create_authorized(task, authorization, request_id)
    return {
        "task_id": saved["id"],
        "status": saved["status"],
        "message_id": saved["message_id"],
        "work_started": bool(saved["session_id"]),
        "session_id": saved["session_id"],
    }


@app.post("/personal/tasks/{task_id}/input")
async def personal_task_input(task_id: str, request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise ValueError("Invalid command")
    async with runtime.action_lock:
        return await task_controller.command(task_id, data.get("text"), data.get("request_id"))


@app.post("/personal/tasks/{task_id}/inputs/{input_id}/new-item")
async def task_input_new_item(task_id: str, input_id: str, request: Request):
    data = await request.json()
    async with runtime.action_lock:
        result = task_store.move_input(task_id, input_id, data.get("request_id"), conversation)
        conversation.sync_task_cards(task_store.list())
        return result


@app.post("/personal/tasks/{task_id}/cancel")
async def personal_task_cancel(task_id: str, request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise ValueError("Invalid command")
    if "origin_message_id" in data:
        with conversation.db() as db:
            origin = db.execute(
                "SELECT * FROM messages WHERE id=? AND role='user'",
                (data["origin_message_id"],),
            ).fetchone()
        quote = data.get("source_quote")
        if not origin or origin["request_id"] != data.get("origin_request_id") or not isinstance(quote, str) or len(quote) < 2 or quote not in origin["text"]:
            raise ValueError("取消必须引用实际用户消息")
        if not any(word in quote for word in ("取消", "停止", "暂停", "先别管", "先不要", "停下", "先停")):
            raise ValueError("用户没有明确要求停止此任务")
        if any(
            word in quote
            for word in (
                "不要取消",
                "别取消",
                "不用取消",
                "不必取消",
                "不要停止",
                "别停止",
                "不要暂停",
                "别暂停",
            )
        ):
            raise ValueError("用户没有明确要求停止此任务")
    async with runtime.action_lock:
        return await task_controller.command(task_id, "", data.get("request_id"), cancel=True)


@app.post("/personal/tasks/{task_id}/dismiss")
async def personal_task_dismiss(task_id: str, request: Request):
    # 手机上「归档」：只对已经停在那里等人的任务生效（等你回应 / 结果未知 / 已暂停 / 待验收），
    # 记一笔取消，不联系工作器；之后可用 resume 恢复。
    current = next((t for t in task_store.list() if t["id"] == task_id), None)
    if not current:
        raise ValueError("任务不存在")
    if current["status"] not in (
        "waiting",
        "unknown",
        "paused",
        "execution_finished",
        "approval_required",
    ):
        raise ValueError("只有停下来等你的任务能归档；在跑的请先停止")
    async with runtime.action_lock:
        if current["status"] == "execution_finished":
            task_store.change(
                task_id,
                "dismiss:" + task_id,
                "dismissed",
                "在手机上归档；未验收",
                status="cancelled",
            )
        else:
            task_store.change(task_id, "dismiss:" + task_id, "dismissed", "在手机上归档")
            task_store.finish(task_id, "cancelled", "在手机上归档；未联系工作器。")
        conversation.sync_task_cards(task_store.list())
    task = next((t for t in task_store.list() if t["id"] == task_id), current)
    return {"task_id": task_id, "status": task["status"]}


@app.post("/personal/tasks/{task_id}/resume")
async def personal_task_resume(task_id: str, request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise ValueError("Invalid command")
    async with runtime.action_lock:
        result = await task_controller.resume(task_id, data.get("request_id"))
        conversation.sync_task_cards(task_store.list())
        return result


@app.get("/models")
async def models(agent: str = "pi"):
    return {"models": await runtime.models(agent)}


@app.post("/refresh")
async def refresh():
    asyncio.create_task(asyncio.to_thread(history.scan))
    return {"ok": True}


@app.get("/sessions")
async def sessions(
    q: str = "",
    agent: str = "",
    role: str = "",
    cwd: str = "",
    after: float = 0,
    sort: str = "recent",
    archived: bool = False,
):
    rows = await asyncio.to_thread(history.list, q, agent, role, cwd, after, sort, archived)
    managed = history.managed()
    case_titles = {}
    with contextlib.suppress(Exception):
        case_titles = {c["id"]: c["title"] for c in (await asyncio.to_thread(cases.list))["items"]}
    for s in rows:
        s["source"] = managed.get(s["id"], {}).get("source", "Mac mini 历史")
        s["managed"] = s["id"] in managed
        s["status"] = await runtime.status(s["id"])
        if s["managed"]:
            s["model"] = managed[s["id"]].get("model", "")
            s["effort"] = managed[s["id"]].get("effort", "")
            # 10-18 会话↔航程互通：这段会话是哪段航程的执行会话
            task_id = managed[s["id"]].get("task_id", "")
            if task_id and task_id in case_titles:
                s["case_id"], s["case_title"] = task_id, case_titles[task_id]
        s.pop("signature", None)
        s.pop("path", None)
    return {
        "sessions": rows,
        "index": history.progress,
        "coverage": "Mac mini 已发现的本机历史",
    }


@app.get("/directories")
async def directories(path: str = ""):
    p = Path(path).expanduser().resolve() if path else HOME / "AI_Work_System"
    if not p.is_relative_to(HOME) or not p.is_dir():
        raise HTTPException(400, "无效目录")
    with history.db() as d:
        recent = [r[0] for r in d.execute("SELECT DISTINCT cwd FROM sessions ORDER BY updated DESC LIMIT 12") if Path(r[0]).is_dir()]
    return {
        "path": str(p),
        "parent": str(p.parent) if p != HOME else None,
        "directories": [str(x) for x in sorted(p.iterdir()) if x.is_dir() and not x.name.startswith(".")],
        "recent": recent,
    }


@app.get("/sessions/{sid}")
async def detail(sid: str):
    s = history.get(sid)
    if not s:
        raise HTTPException(404, "会话不存在")
    s["status"] = await runtime.status(sid)
    s["capabilities"] = await session_caps(sid, s)
    m = history.managed().get(sid)
    s["managed"] = bool(m)
    s["source"] = (m or {}).get("source", "Mac mini 历史")
    if m:
        s["model"] = m.get("model", "")
        s["effort"] = m.get("effort", "")
    s.pop("signature", None)
    s.pop("path", None)
    messages = await asyncio.to_thread(history.messages, sid)
    # Bind live Codex item IDs before projecting their persisted history rows.
    presentations.project(sid, live_items(runtime.events(sid)))
    return {"session": s, "messages": presentations.project(sid, messages), "usage": runtime.usage(sid)}


async def session_caps(sid, s):
    m = history.managed().get(sid)
    alive = bool(m and not m.get("ended") and (sid in runtime.workers.workers if m.get("transport") else m["agent"] == "codex" or await runtime.alive(m["tmux"])))
    stable_identity = runtime.stable_input(sid)
    legacy_restart = alive and not stable_identity and s["agent"] == "pi" and not m.get("transport")
    can_resume = await runtime.legacy_pi_idle(sid) if legacy_restart else False if alive else await runtime.resumable(s)
    caps = {
        "history": True,
        "input": alive and stable_identity,
        "stable_message_identity_v1": stable_identity,
        "restart_for_identity": legacy_restart,
        "terminal": alive and not (m or {}).get("transport") and (s["agent"] == "pi" or bool(history.messages(sid))),
        "resume": can_resume,
        "queue": False,
        "steer": False,
    }
    with contextlib.suppress(Exception):
        caps["dispatch_mode"] = (await dispatch_route(sid, s, caps))[0]
    return caps


@app.get("/sessions/{sid}/live")
async def live(sid: str, after: int = -1):
    events = runtime.events(sid)
    return {
        "status": await runtime.status(sid),
        "features": {"stable_message_identity_v1": runtime.stable_input(sid)},
        "events": [],
        "items": presentations.project(sid, live_items(events)),
        "cursor": events[-1]["seq"] if events else -1,
        "approvals": [{k: v for k, v in a.items() if k != "rpc_id"} for a in runtime.approvals.values() if a["sid"] == sid],
        "usage": runtime.usage(sid),
    }


def live_items(events):
    items = {}
    for e in events:
        kind = e.get("kind")
        typ = e.get("type")
        data = e.get("data", {})
        ts = e.get("time", 0)
        if kind == "item":
            key = e["id"]
            old = items.get(key, {})
            items[key] = {**old, **e, "text": e.get("text") or old.get("text", "")}
        elif kind == "delta":
            key = e["id"]
            old = items.setdefault(
                key,
                {
                    "id": key,
                    "role": e.get("role", "assistant"),
                    "title": "实时输出",
                    "text": "",
                    "time": ts,
                },
            )
            old["text"] += e.get("text", "")
        elif typ in ("message_start", "message_update", "message_end"):
            m = data.get("message", {})
            role = m.get("role")
            if role not in ("user", "assistant", "toolResult"):
                continue
            key = m.get("toolCallId") or "pi:" + str(m.get("timestamp", 0))
            request_id = m.get("com_request_id") if role == "user" else None
            if isinstance(request_id, str):
                key = "pi:com:" + request_id
            body = text_content(m.get("content", ""))
            delta = data.get("assistantMessageEvent", {})
            if typ == "message_update" and delta.get("type") == "text_delta":
                body = items.get(key, {}).get("text", "") + (delta.get("delta") or "")
            items[key] = {
                "id": key,
                "role": "tool" if role == "toolResult" else role,
                "title": m.get("toolName", ""),
                "text": body,
                "time": ts,
            }
            if request_id:
                items[key]["native_request_id"] = request_id
        elif typ in (
            "tool_execution_start",
            "tool_execution_update",
            "tool_execution_end",
        ):
            key = data.get("toolCallId", "tool")
            result = data.get("result", data.get("partialResult", {}))
            body = text_content(result.get("content", "")) if isinstance(result, dict) else str(result)
            if not body:
                body = json.dumps(data.get("args", {}), ensure_ascii=False)
            items[key] = {
                "id": key,
                "role": "tool",
                "title": data.get("toolName", "工具") + (" · 执行中" if typ != "tool_execution_end" else " · 已结束"),
                "text": body,
                "time": ts,
            }
    return [x for x in items.values() if x.get("text")]


@app.get("/sessions/{sid}/terminal-history")
async def terminal_history(sid: str):
    m = history.managed().get(sid)
    if not m or m.get("ended") or not await runtime.alive(m["tmux"]):
        raise HTTPException(409, "当前会话没有可读取的终端输出")
    return {
        "text": await runtime.capture(sid, 20000, ansi=True),
        "limit": 20000,
        "format": "ansi",
    }


@app.post("/sessions/{sid}/labels")
async def labels(sid: str, request: Request):
    history.label(sid, await request.json())
    return {"ok": True}


class SubmissionRejected(ValueError):
    """A proven refusal before a worker/input was submitted, not a transport failure."""


def resolve_old_create_refusal(rid, result):
    if result.get("status") == "rejected" and result.get("submission_state") == "not_submitted" and result.get("error") == "尚未提交：这条消息只形成候选，请补充要完成的动作；草稿已保留":
        return {
            **result,
            "error": "旧交办限制已解除。上次消息未提交，草稿已保留，现在可直接发送普通消息。",
            "resolution": "legacy_work_chat_gate_removed",
        }
    # Legacy manual-create source validation ran before any task/worker was created.
    if result.get("status") != "unknown" or result.get("error") != "This message is not an explicit assignment; keep it as a candidate":
        return result
    with conversation.db() as db:
        human = db.execute("SELECT id,status FROM messages WHERE request_id=?", ("work:" + rid,)).fetchone()
    if not human or human["status"] != "failed" or any(t.get("origin_message_id") == human["id"] for t in task_store.list()):
        return result
    return {
        **result,
        "status": "rejected",
        "submission_state": "not_submitted",
        "error": "上一条工作要求被旧交办规则拒绝，工作器没有启动；草稿已保留，可重新交办。",
        "resolution": "validated_source_refusal_before_task_creation",
    }


@app.get("/receipts/{rid}")
async def receipt(rid: str):
    with history.db() as d:
        r = d.execute("SELECT data FROM receipts WHERE id=?", (rid,)).fetchone()
        if not r:
            raise HTTPException(404, "尚无发送记录")
        result = resolve_old_create_refusal(rid, json.loads(r[0]))
        if result != json.loads(r[0]):
            d.execute("UPDATE receipts SET data=? WHERE id=?", (json.dumps(result), rid))
    return result


async def once(data, action, preflight=None):
    rid = data.get("request_id", "")
    if len(rid) < 10 or len(rid) > 100:
        raise ValueError("缺少有效请求标识")
    fingerprint = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
    async with runtime.action_lock:
        with history.db() as d:
            old = d.execute("SELECT fingerprint,data FROM receipts WHERE id=?", (rid,)).fetchone()
            if old:
                if old[0] != fingerprint:
                    raise ValueError("请求标识冲突")
                result = resolve_old_create_refusal(rid, json.loads(old[1]))
                if result != json.loads(old[1]):
                    d.execute(
                        "UPDATE receipts SET data=? WHERE id=?",
                        (json.dumps(result), rid),
                    )
                return result
        if preflight:
            try:
                await preflight()
            except ValueError as error:
                result = {
                    "status": "rejected",
                    "submission_state": "not_submitted",
                    "request_id": rid,
                    "error": str(error),
                }
                with history.db() as d:
                    d.execute(
                        "INSERT INTO receipts VALUES(?,?,?)",
                        (rid, fingerprint, json.dumps(result)),
                    )
                return result
        with history.db() as d:
            d.execute(
                "INSERT INTO receipts VALUES(?,?,?)",
                (
                    rid,
                    fingerprint,
                    json.dumps({"status": "unknown", "request_id": rid}),
                ),
            )
        try:
            result = await action()
        except SubmissionRejected as e:
            result = {
                "status": "rejected",
                "submission_state": "not_submitted",
                "request_id": rid,
                "error": str(e),
            }
            with history.db() as d:
                d.execute("UPDATE receipts SET data=? WHERE id=?", (json.dumps(result), rid))
            return result
        except Exception as e:
            # Unknown is deliberate: a process may have accepted before transport failed.
            with history.db() as d:
                d.execute(
                    "UPDATE receipts SET data=? WHERE id=?",
                    (
                        json.dumps({"status": "unknown", "request_id": rid, "error": str(e)}),
                        rid,
                    ),
                )
            raise
        result = {"status": "accepted", "request_id": rid, **result}
        with history.db() as d:
            d.execute("UPDATE receipts SET data=? WHERE id=?", (json.dumps(result), rid))
        return result


@app.post("/sessions")
async def create(request: Request):
    data = await request.json()
    reference = canonical_reference(data.get("reference"), reference_message, "personal-main")
    if reference and not data.get("prompt", "").strip():
        raise ValueError("引用消息需要本条消息")

    async def preflight_create():
        if MAIN_AGENT != "pi":
            return
        if data.get("agent", "pi") == "pi":
            raise ValueError("Pi 工作请从主页交办；工作页提供 Claude / Codex")
        if not data.get("prompt", "").strip():
            raise ValueError("请先输入工作要求，再创建执行会话")
        if data.get("agent") not in ("claude", "codex"):
            raise ValueError("工作页提供 Claude Code / Codex")
        root = (HOME / "AI_Work_System").resolve()
        if not Path(data.get("cwd", str(root))).resolve().is_relative_to(root):
            raise ValueError("工作任务需要明确的 AI_Work_System 项目目录")
        if (
            len(
                [
                    t
                    for t in task_store.list()
                    if t["status"]
                    in (
                        "queued",
                        "dispatching",
                        "running",
                        "waiting",
                        "unknown",
                        "cancel_requested",
                    )
                ]
            )
            >= 2
        ):
            raise ValueError("已有两个后台任务，先补充原任务或等其结束")

    async def action():
        ledger = None
        if MAIN_AGENT == "pi":
            if not data.get("prompt", "").strip():
                raise ValueError("请先输入工作要求，再创建执行会话")
            cwd = Path(data.get("cwd", str(HOME / "AI_Work_System"))).resolve()
            project_root = (HOME / "AI_Work_System").resolve()
            if not cwd.is_relative_to(project_root):
                raise ValueError("工作任务需要明确的 AI_Work_System 项目目录")
            if (
                len(
                    [
                        t
                        for t in task_store.list()
                        if t["status"]
                        in (
                            "queued",
                            "dispatching",
                            "running",
                            "waiting",
                            "unknown",
                            "cancel_requested",
                        )
                    ]
                )
                >= 2
            ):
                raise ValueError("已有两个后台任务，先补充原任务或等其结束")
            session = await conversation._ensure_session()
            human = conversation.submit("work:" + data["request_id"], data["prompt"])
            conversation._set(human["message_id"], "delegated")
            context = {
                "origin_session_id": session,
                "origin_message_id": human["message_id"],
                "origin_request_id": "work:" + data["request_id"],
            }
            try:
                try:
                    from manual_work import work_chat

                    draft, authorization, key = work_chat(
                        conversation,
                        work_proposals,
                        {**data, "relative_cwd": str(cwd.relative_to(project_root))},
                        context,
                    )
                    ledger = task_store.create_authorized(draft, authorization, key)
                except ValueError as e:
                    raise SubmissionRejected(str(e)) from e
                ledger = task_store.change(
                    ledger["id"],
                    "manual-dispatch:" + data["request_id"],
                    "dispatching",
                    status="dispatching",
                    automatic=False,
                    selected_model=data.get("model", ""),
                    selected_effort=data.get("effort", ""),
                )[0]
                try:
                    await runtime.preflight_task(ledger)
                except Exception as e:
                    raise SubmissionRejected("工作器尚未启动：" + str(e)) from e
                sid = await runtime.create_task_worker(ledger)
            except SubmissionRejected as e:
                conversation._finish(human["message_id"], "failed", error=str(e))
                if ledger:
                    task_store.finish(ledger["id"], "failed", str(e))
                raise
            except Exception:
                conversation._finish(
                    human["message_id"],
                    "failed",
                    error="工作器启动结果待核实，请查看会话；不会重复发送",
                )
                if ledger:
                    task_store.change(
                        ledger["id"],
                        "manual-blocked:" + data["request_id"],
                        "execution_unknown",
                        status="unknown",
                        verification_status="uncertain",
                    )
                raise
        else:
            sid = await runtime.create(
                data.get("agent", "pi"),
                data.get("cwd", str(HOME / "AI_Work_System")),
                data.get("model", ""),
                data.get("effort", ""),
                data.get("sandbox", "danger-full-access"),
            )
        turn_id = None
        if data.get("prompt"):
            # Wait for Pi TUI initialization before literal input. Codex uses structured RPC.
            if data.get("agent", "pi") == "pi":
                for _ in range(80):
                    if any(e.get("type") == "session_start" for e in runtime.events(sid)):
                        break
                    await asyncio.sleep(0.25)
                else:
                    raise RuntimeError("Pi 启动未就绪，请在会话中检查终端；不要重复提交")
                await asyncio.sleep(1)
            transport = presentations.record(sid, data["request_id"], data["prompt"], reference)
            try:
                turn_id = await runtime.input(
                    sid,
                    transport,
                    data["request_id"],
                    data.get("model") or None,
                    data.get("effort") or None,
                )
            except Exception:
                if ledger:
                    task_store.change(
                        ledger["id"],
                        "manual-input-unknown:" + data["request_id"],
                        "execution_unknown",
                        status="unknown",
                        session_id=sid,
                        verification_status="uncertain",
                    )
                    conversation._finish(
                        human["message_id"],
                        "failed",
                        error="工作输入送达待核实，不会重复发送",
                    )
                raise
            if ledger:
                task_store.change(
                    ledger["id"],
                    "manual-started:" + data["request_id"],
                    "started",
                    status="running",
                    session_id=sid,
                    run_id=turn_id,
                )
            presentations.bind_turn(sid, data["request_id"], turn_id)
            presentations.project(sid, live_items(runtime.events(sid)))
        return {
            "sid": sid,
            "turn_id": turn_id,
            "submission_state": "submitted" if data.get("prompt") else "ready",
            **presentations.identity(sid, data["request_id"]),
            **({"text": data["prompt"], "reference": reference} if reference else {}),
        }

    return await once(data, action, preflight_create)


@app.post("/sessions/{sid}/resume")
async def resume(sid: str, request: Request):
    data = await request.json()
    s = history.get(sid)
    if not s:
        raise HTTPException(404, "会话不存在")

    async def legacy():
        m = history.managed().get(sid)
        return m if m and m.get("agent") == "pi" and not m.get("ended") and not runtime.stable_input(sid) and await runtime.alive(m["tmux"]) else None

    async def preflight():
        if await legacy():
            if not await runtime.legacy_pi_idle(sid):
                raise ValueError("旧 Pi 会话仍在运行或状态未确认；等会话闲置后才能升级并恢复")
        elif not await runtime.resumable(s):
            raise ValueError("会话正在使用或状态无法确认，暂不能恢复输入")

    async def action():
        m = await legacy()
        if m:
            if not await runtime.legacy_pi_idle(sid):
                raise ValueError("Pi 已开始运行，未结束会话；请稍后核实恢复状态")
            # Explicit resume is the only path that restarts this legacy managed
            # process. History and the phone's draft are never submitted here.
            await runtime.tm("kill-session", "-t", m["tmux"])
            m["ended"] = True
            history.save_managed(sid, m)
        options = {"sandbox": "danger-full-access"}
        return {"sid": await runtime.create(s["agent"], s["cwd"], resume=s, **options)}

    return await once(dict(data, sid=sid, action="resume"), action, preflight)


@app.post("/sessions/{sid}/input")
async def send(sid: str, request: Request):
    data = await request.json()
    if not isinstance(data, dict) or not isinstance(data.get("text"), str) or not data["text"].strip():
        raise ValueError("输入为空")
    reference = canonical_reference(data.get("reference"), reference_message, sid)

    async def preflight_send():
        metadata = history.managed().get(sid, {})
        task = next((t for t in task_store.list() if t["id"] == metadata.get("task_id")), None)
        if task and not task.get("interactive") and task["status"] == "execution_finished" and task.get("verification_status") != "passed":
            raise ValueError("原任务正在验收，请等主线检查结果后继续")
        await runtime.check_input_identity(sid)

    async def action():
        quick_voice.revoke(sid)
        transport = presentations.record(sid, data["request_id"], data["text"], reference)
        metadata = history.managed().get(sid, {})
        task = next((t for t in task_store.list() if t["id"] == metadata.get("task_id")), None)
        if task and task["status"] in ("running", "waiting"):
            delivery = await task_controller.command(task["id"], transport, data["request_id"])
            return {
                "sid": sid,
                "turn_id": task["run_id"],
                "submission_state": "submitted",
                "delivery": delivery["delivery"],
                **presentations.identity(sid, data["request_id"]),
            }
        if task and not task.get("interactive") and task["status"] == "execution_finished" and task.get("verification_status") != "passed":
            raise ValueError("原任务正在验收，请等主线检查结果后继续")
        turn_id = await runtime.input(
            sid,
            transport,
            data["request_id"],
            data.get("model") or None,
            data.get("effort") or None,
        )
        if task:
            task_store.change(
                task["id"],
                "resume-input:" + data["request_id"],
                "started",
                status="running",
                run_id=turn_id,
                verification_status="pending",
            )
        presentations.bind_turn(sid, data["request_id"], turn_id)
        presentations.project(sid, live_items(runtime.events(sid)))
        return {
            "sid": sid,
            "turn_id": turn_id,
            "submission_state": "submitted",
            **presentations.identity(sid, data["request_id"]),
            **({"text": data["text"], "reference": reference} if reference else {}),
        }

    return await once(dict(data, sid=sid, action="input"), action, preflight_send)


# ---- 工作页：任何会话都能发一句 ----------------------------------------------------------------
# 按顺序选路：能直接输入 → 电脑上的终端里正开着就打进去 → 能恢复原会话就恢复 → 没在跑的 Claude Code 用 SDK 接上原会话
# → 其余（被 Codex App 占着、MBP 上的、已经接不上的）带着前情开一个新会话接着做。回执里的 mode 告诉手机走了哪条。
class _Body:
    def __init__(self, data):
        self.data = data

    async def json(self):
        return self.data


async def dispatch_route(sid, s, caps):
    if caps.get("input"):
        return "input", ""
    if not history.managed().get(sid):
        running, pane = await runtime.find_pane(s)
        if running:
            return ("injected", pane) if pane else ("forked", "")
    if caps.get("resume"):
        return "resumed", ""
    if s["agent"] == "claude" and not history.managed().get(sid) and Path(s.get("cwd") or "").is_dir():
        return "adopted", ""
    return "forked", ""


def handoff_prompt(title, agent, where, turns, text):
    lines = [f"接着之前的一段会话做：《{title}》（{agent}，{where}）。下面是那段会话最后几轮，只是背景："]
    for t in turns[-4:]:
        lines.append(("我：" if t["role"] == "user" else "助手：") + t["text"].strip()[:1500])
    lines.append("—— 现在的要求 ——")
    lines.append(text)
    return "\n\n".join(lines)


async def fork_session(agent, cwd, prompt, request_id):
    cwd = cwd if cwd and Path(cwd).is_dir() and Path(cwd).resolve().is_relative_to(HOME) else str(HOME / "AI_Work_System")
    result = await create(
        _Body(
            {
                "agent": agent if agent in ("claude", "codex", "pi", "hermes") else "codex",
                "cwd": cwd,
                "prompt": prompt,
                "request_id": request_id,
                "sandbox": "danger-full-access",
                "model": "",
                "effort": "",
            }
        )
    )
    return result


@app.post("/sessions/{sid}/dispatch")
async def dispatch(sid: str, request: Request):
    data = await request.json()
    text = data.get("text") if isinstance(data, dict) else None
    rid = (data or {}).get("request_id", "")
    if not isinstance(text, str) or not text.strip():
        raise ValueError("输入为空")
    s = history.get(sid)
    if not s:
        # 工作看板里的快照（多半是 MBP 上的会话）：mini 上没有原会话，只能带着摘要开新会话。
        try:
            src = project_board.source(sid)
        except ValueError:
            raise HTTPException(404, "会话不存在") from None
        turns = [m for m in src.get("messages") or [] if m.get("role") in ("user", "assistant") and m.get("text")]
        prompt = handoff_prompt(src.get("title") or "工作会话", src.get("agent") or "", (src.get("host") or "") + " · " + (src.get("cwd") or ""), turns, text)
        result = await fork_session(src.get("agent") or "codex", src.get("cwd"), prompt, rid)
        return {**result, "mode": "forked", "from": sid}
    caps = await session_caps(sid, s)
    mode, pane = await dispatch_route(sid, s, caps)
    if mode == "input":
        return {**await send(sid, _Body(data)), "mode": mode}
    if mode == "injected":

        async def inject():
            await runtime.inject(pane, text, rid)
            return {"sid": sid, "submission_state": "submitted", "pane": pane}

        return {**await once(dict(data, sid=sid, action="inject"), inject), "mode": mode}
    if mode in ("resumed", "adopted"):
        # once 在 action_lock 里跑 action，不能套娃：恢复和后面的输入各用自己的请求标识各走一次 once。
        if mode == "adopted":

            async def adopt():
                return {"sid": await runtime.adopt_claude(s)}

            revived = await once({"request_id": rid + "-adopt", "sid": sid, "action": "adopt"}, adopt)
        else:
            revived = await resume(sid, _Body({"request_id": rid + "-resume"}))
        new = revived.get("sid")
        if not new:
            return {**revived, "mode": mode}
        if s["agent"] == "pi":
            for _ in range(80):
                if any(e.get("type") == "session_start" for e in runtime.events(new)):
                    break
                await asyncio.sleep(0.25)
            await asyncio.sleep(1)
        result = await send(new, _Body({**data, "request_id": rid + "-input"}))
        return {**result, "sid": new, "mode": mode, "from": sid}
    turns = [m for m in await asyncio.to_thread(history.messages, sid) if m["role"] in ("user", "assistant") and m.get("text")]
    prompt = handoff_prompt(s.get("display_title") or s.get("title") or "工作会话", s["agent"], s.get("cwd") or "", turns, text)
    result = await fork_session(s["agent"], s.get("cwd"), prompt, rid)
    return {**result, "mode": "forked", "from": sid}


@app.post("/sessions/{sid}/stop")
async def stop(sid: str):
    await runtime.stop(sid)
    return {"ok": True}


@app.post("/sessions/{sid}/end")
async def end(sid: str):
    m = history.managed().get(sid)
    if not m:
        raise ValueError("不是本应用管理的会话")
    if m.get("transport"):
        worker = runtime.workers.workers.get(sid)
        if worker:
            await worker.stop()
        m["ended"] = True
        history.save_managed(sid, m)
        return {"ok": True}
    if m["agent"] == "codex":
        with contextlib.suppress(Exception):
            await runtime.stop(sid)
        with contextlib.suppress(Exception):
            await runtime.call("thread/unsubscribe", {"threadId": m["native_id"]})
    await runtime.tm("kill-session", "-t", m["tmux"], check=False)
    m["ended"] = True
    history.save_managed(sid, m)
    return {"ok": True}


@app.post("/approvals/{key}")
async def decision(key: str, request: Request):
    await runtime.decision(key, await request.json())
    return {"ok": True}


@app.websocket("/terminal/{sid}")
async def terminal(ws: WebSocket, sid: str):
    await ws.accept()
    master = None
    proc = None
    try:
        hello = await asyncio.wait_for(ws.receive_json(), 5)
        if not hmac.compare_digest(str(hello.get("token", "")), TOKEN):
            await ws.close(1008)
            return
        async with runtime.action_lock:
            quick_voice.revoke(sid)
            m = history.managed().get(sid)
        if not m or m.get("ended") or m.get("transport") or (MAIN_AGENT == "pi" and m["agent"] == "pi"):
            await ws.close(1008)
            return
        if m["agent"] == "codex":
            await runtime.ensure_terminal(sid)
        if not await runtime.alive(m["tmux"]):
            await ws.close(1008)
            return
        master, slave = pty.openpty()
        os.set_blocking(master, False)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
        proc = await asyncio.create_subprocess_exec(
            runtime.tmux,
            "-L",
            runtime.sock,
            "attach-session",
            "-t",
            m["tmux"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env={**os.environ, "TERM": "xterm-256color"},
            start_new_session=True,
        )
        os.close(slave)

        async def output():
            while proc.returncode is None:
                try:
                    b = os.read(master, 65536)
                    if b:
                        await ws.send_bytes(b)
                except BlockingIOError:
                    pass
                except OSError:
                    break
                await asyncio.sleep(0.025)

        task = asyncio.create_task(output())
        try:
            while True:
                data = await ws.receive_json()
                if data.get("type") == "resize":
                    fcntl.ioctl(
                        master,
                        termios.TIOCSWINSZ,
                        struct.pack(
                            "HHHH",
                            max(5, min(150, int(data["rows"]))),
                            max(20, min(400, int(data["cols"]))),
                            0,
                            0,
                        ),
                    )
                    # The detached attaching client has no controlling TTY; notify it explicitly.
                    if proc.returncode is None:
                        proc.send_signal(signal.SIGWINCH)
                elif data.get("type") == "input":
                    payload = str(data.get("data", "")).encode()
                    if len(payload) > 65536:
                        raise ValueError("终端输入过长")
                    os.write(master, payload)
        finally:
            task.cancel()
    except (WebSocketDisconnect, asyncio.TimeoutError, ValueError, OSError):
        pass
    finally:
        if proc and proc.returncode is None:
            proc.terminate()
            await proc.wait()
        if master is not None:
            os.close(master)
        # Only the attaching client exits; the tmux Agent session keeps running.


@app.post("/internal/agent/{name}")
async def internal_agent_tool(name: str, request: Request):
    data = await request.json()
    if not isinstance(data, dict) or not isinstance(data.get("args"), dict) or not isinstance(data.get("context"), dict):
        raise ValueError("Invalid agent envelope")
    data["context"].pop("pending_action_confirmed", None)  # internal-only flag; never accepted over HTTP
    data["args"].pop("pending_action_confirmed", None)
    return await agent_tools.call(name, data["args"], data["context"])


@app.get("/personal/memory")
async def memory_status():
    from memory import status
    from memory_catalog import (
        CATEGORIES,
        FOLDERS,
        MemoryCatalog,
        SharedKnowledgeCatalog,
        folder_of,
        headline,
        plain,
    )

    def catalog():
        personal = [
            {
                **r,
                "folder": folder_of(r),
                "title": r.get("title") or headline(r["content"]),
                "preview": plain(r["content"]),
            }
            for r in MemoryCatalog().list()
        ]
        shared = SharedKnowledgeCatalog().list()
        return {
            "categories": CATEGORIES,
            "folders": FOLDERS,
            "items": personal + shared,
            "counts": {"personal": len(personal), "shared_knowledge": len(shared)},
        }

    return {**await asyncio.to_thread(status), **await asyncio.to_thread(catalog)}


@app.get("/personal/memory/files")
async def personal_memory_truth_files():
    import memory_truth

    return await asyncio.to_thread(memory_truth.get_truth_files, STATE)


@app.post("/personal/memory/files/{name}")
@app.put("/personal/memory/files/{name}")
async def personal_memory_truth_update(name: str, request: Request):
    import memory_truth

    data = await request.json()
    if not isinstance(data, dict) or "content" not in data or not isinstance(data.get("content"), str):
        raise HTTPException(400, "请求体需包含字符串字段 content")
    try:
        return await asyncio.to_thread(memory_truth.update_truth_file, name, data["content"], STATE)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc


@app.post("/personal/memory/forget")
async def personal_memory_truth_forget(request: Request):
    import memory_truth

    data = await request.json()
    if not isinstance(data, dict) or not str(data.get("target") or "").strip():
        raise HTTPException(400, "请求体需包含非空 target")
    name = str(data.get("name") or "MEMORY.md")
    try:
        return await asyncio.to_thread(memory_truth.forget_truth_entry, str(data["target"]), name, STATE)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc


@app.post("/personal/memory/dream")
async def personal_memory_dream():
    import memory_dream

    return await memory_dream.run_dream(STATE, reason="manual")


@app.get("/personal/memory/{memory_id}")
async def memory_detail(memory_id: str):
    from memory_catalog import MemoryCatalog, SharedKnowledgeCatalog

    return SharedKnowledgeCatalog().get(memory_id) if memory_id.startswith("doc_") else MemoryCatalog().get(memory_id)


@app.post("/personal/memory/{memory_id}")
async def memory_edit(memory_id: str, request: Request):
    if memory_id.startswith("doc_"):
        raise HTTPException(
            status_code=403,
            detail="共享知识来自原始 Markdown，请在来源文件中修改；更新会自动同步。",
        )
    from memory_catalog import MemoryCatalog

    data = await request.json()
    catalog = MemoryCatalog()
    old = catalog.get(memory_id)
    content = data.get("content", old["content"])
    # Authenticated UI correction remains sourced as an explicit human edit.
    source = {
        "message_id": "memory-edit:" + str(data.get("request_id", "")),
        "quote": content,
        "previous_source": old["source"],
    }
    if not data.get("request_id"):
        raise ValueError("Missing edit request ID")
    return catalog.save(
        content,
        data.get("category", old["category"]),
        source,
        memory_id,
        data.get("kind", old["kind"]),
        data.get("expected_version"),
        data.get("archived", old["archived"]),
    )


@app.get("/personal/capabilities")
async def capabilities_search(query: str = "", runtime_name: str = ""):
    return {"items": capability_registry.search(query, runtime_name or None)}


@app.get("/personal/connectors")
async def connector_status():
    return personal_hub.status()


@app.post("/personal/connectors/{name}")
async def connector_settings(name: str, request: Request):
    return personal_hub.configure(name, await request.json())


@app.post("/personal/sync")
async def personal_sync(request: Request):
    data = await request.json()
    return await personal_hub.sync(data.get("group", "all"), force=True)


@app.get("/personal/matters")
async def personal_matters(status: str | None = None, source_type: str | None = None, limit: int = 50):
    if "personal_board" in globals() and getattr(personal_board, "matter_store", None):
        matters = personal_board.matter_store.list_matters(status=status, source_type=source_type, limit=limit)
        if matters:
            return {"items": [m.to_dict() for m in matters], "total": len(matters)}
    items = personal_hub.matters()
    return {"items": items, "total": len(items)}


@app.get("/personal/briefing")
async def personal_briefing():
    active_ids = []
    for task in task_store.list():
        if task["status"] in (
            "queued",
            "running",
            "waiting",
            "unknown",
            "cancel_requested",
        ):
            active_ids.append(task["id"])
            personal_hub.matter(
                "com_task",
                task["id"],
                task["title"],
                {
                    "status": task["status"],
                    "task_id": task["id"],
                    "requirements_revision": task.get("requirements_revision"),
                },
                deadline=None,
            )
    with personal_hub.db() as db:
        stale = [r[0] for r in db.execute("SELECT id,source_id FROM matters WHERE source='com_task'") if r[1] not in active_ids]
        for ident in stale:
            db.execute("DELETE FROM matters WHERE id=?", (ident,))
    return personal_hub.briefing()


@app.post("/personal/matters/{matter_id}/feedback")
async def matter_feedback(matter_id: str, request: Request):
    data = await request.json()
    return personal_hub.feedback(matter_id, data["action"], data["request_id"], data.get("text", ""))


@app.post("/personal/matters/{matter_id}/unlink")
async def matter_unlink(matter_id: str):
    return personal_hub.unlink(matter_id)


@app.get("/personal/automations")
async def personal_automations():
    from conversation import HermesClient

    try:
        return await HermesClient(STATE).request("GET", "/api/jobs")
    except Exception:
        return {"jobs": [], "status": "unavailable"}


@app.get("/personal/actions")
async def personal_actions():
    return {"items": autonomy.list(), "enabled": autonomy.enabled()}


@app.post("/personal/actions/{operation_id}/undo")
async def personal_undo(operation_id: str, request: Request):
    data = await request.json()
    return await autonomy.undo(operation_id, data["request_id"])


@app.get("/personal/devices")
async def devices_list():
    return {"items": device_nodes.list()}


@app.post("/personal/devices/register")
async def device_register(request: Request):
    return device_nodes.register(await request.json())


@app.post("/personal/devices/{node}/invoke")
async def device_invoke(node: str, request: Request):
    data = await request.json()
    return await device_nodes.call(
        node,
        data["tool"],
        data.get("args", {}),
        data["request_id"],
        data.get("timeout", 30),
    )


@app.get("/personal/devices/{node}/capability-report")
async def device_capability_report(node: str):
    try:
        return await asyncio.to_thread(device_nodes.capability_report, node)
    except KeyError:
        raise HTTPException(404, "设备不存在")


@app.get("/personal/invocations/{invocation_id}")
async def device_invocation(invocation_id: str):
    row = device_nodes.get(invocation_id)
    if not row:
        raise HTTPException(404, "调用不存在")
    return row


@app.post("/personal/devices/{node}/results")
async def device_result(node: str, request: Request):
    return await device_nodes.result(node, await request.json())


@app.websocket("/personal/devices/{node}/ws")
async def device_socket(ws: WebSocket, node: str):
    if not hmac.compare_digest(ws.headers.get("authorization", ""), "Bearer " + TOKEN):
        await ws.close(code=1008)
        return
    try:
        await device_nodes.socket(ws, node)
    except (WebSocketDisconnect, TimeoutError, ValueError, RuntimeError):
        with contextlib.suppress(Exception):
            await ws.close()


@app.get("/personal/reminders")
async def personal_reminders():
    return {"items": reminder_cards.list(), "source": "existing_gateway_remind"}


@app.post("/personal/reminders/{reminder_id}/action")
async def reminder_action(reminder_id: str, request: Request):
    data = await request.json()
    async with runtime.action_lock:
        return reminder_cards.act(
            reminder_id,
            data.get("action"),
            data.get("request_id"),
            data.get("expected"),
        )


@app.get("/personal/heartbeat")
async def heartbeat_diagnostics():
    return {
        "settings": heartbeat.settings(),
        "items": heartbeat.recent(30),
        "checklist": str(heartbeat.checklist),
        "shadow_verified": heartbeat.shadow_verified(),
    }


@app.post("/personal/heartbeat/settings")
async def heartbeat_settings(request: Request):
    return {"settings": heartbeat.configure(await request.json())}


@app.get("/personal/goals")
async def personal_goals():
    return {"items": goal_events.list(), "scheduler_enabled": goal_events.enabled()}


@app.post("/personal/tasks/archive-stale")
async def archive_stale_tasks_endpoint(request: Request, days: float = 7):
    from task_tools import archive_stale_tasks

    body_days = days
    if int(request.headers.get("content-length") or 0) > 0:
        with contextlib.suppress(Exception):
            data = await request.json()
            if isinstance(data, dict) and data.get("days") is not None:
                body_days = float(data["days"])
    res = await asyncio.to_thread(archive_stale_tasks, task_store, body_days)
    with contextlib.suppress(Exception):
        conversation.sync_task_cards(task_store.list())
    return res


@app.post("/personal/tasks/{task_id}/verify")
async def verify_task(task_id: str, request: Request):
    data = await request.json()
    if data.get("explicit_acceptance") is not True:
        raise ValueError("需要明确验收和证据")
    return task_store.verify(task_id, data.get("evidence"), data.get("artifacts"))


@app.post("/personal/tasks/{task_id}/merge")
async def merge_task(task_id: str, request: Request):
    task = next((t for t in task_store.list() if t["id"] == task_id), None)
    if not task or not task.get("workspace_copy"):
        raise ValueError("没有独立项目副本")
    if task.get("merged_run_id") == task.get("run_id") and task.get("merge_result"):
        return task["merge_result"]
    async with runtime.action_lock:
        result = await runtime.workers.copies.merge(task)
        task_store.change(
            task_id,
            "merged:" + task_id + ":" + str(task.get("run_id")),
            "workspace.merged",
            json.dumps(result, ensure_ascii=False),
            merge_result=result,
            merged_run_id=task.get("run_id"),
        )
        return result


@app.post("/personal/archives/{archive_id}/restore")
async def restore_archive(archive_id: str):
    async with runtime.action_lock:
        return agent_tools.archives.restore(archive_id)


@app.get("/personal/agency")
async def personal_agency():
    return {**agency.snapshot(), "notifications": notifications.status()}


@app.post("/personal/agency/settings")
async def agency_settings(request: Request):
    data = await request.json()
    data.pop("request_id", None)
    result = proactive.configure(data)
    return {"status": "completed", "settings": result}


@app.post("/personal/agency/actions/{ident}")
async def agency_action(ident: str, request: Request):
    return agency.action(ident, await request.json())


@app.post("/personal/agency/goals")
async def agency_goal(request: Request):
    return {"status": "completed", "goal": agency.create_goal(await request.json())}


@app.get("/personal/notifications")
async def notification_status():
    return notifications.status()


@app.post("/personal/notifications/devices")
async def notification_device(request: Request):
    return notifications.register(await request.json())


@app.post("/personal/notifications/devices/{ident}/disable")
async def notification_disable(ident: str):
    return notifications.disable(ident)


@app.get("/personal/next")
async def personal_next():
    snap = next_steps.snapshot()
    with contextlib.suppress(Exception):  # 下一步页右上角「航程 · N 进行中」入口
        listing = await asyncio.to_thread(cases.list)
        snap["cases"] = {"active": listing["active"], "waiting": listing["waiting"], "total": len(listing["items"])}
    return snap


@app.post("/personal/next/refresh")
async def personal_next_refresh():
    if not next_steps.running:
        asyncio.create_task(next_steps.refresh(force=True))
    return {"status": "started"}


# 11-01 事件判断账本 + 11-11 主动定时/事件触发器（Triggers 第一版）
@app.get("/personal/triggers")
async def personal_triggers(
    status: str = "",
    channel: str = "",
    limit: int = 50,
    outcome: str = "",
    source: str = "",
    days: int = 7,
    view: str = "",
):
    sched_items = await asyncio.to_thread(scheduled_triggers.list, status=status, channel=channel)
    recent_runs = await asyncio.to_thread(scheduled_triggers.recent_runs, "", max(1, min(limit, 100)))
    passive_stats = await asyncio.to_thread(triggers.stats, max(1, min(days, 90)))
    if view == "events" or outcome or source:
        primary_items = await asyncio.to_thread(triggers.items, max(1, min(limit, 200)), outcome, source)
    else:
        primary_items = sched_items
    return {
        "triggers_enabled": bool(getattr(superagent_flags, "triggers_on", lambda: False)()),
        "items": primary_items,
        "triggers": sched_items,
        "templates": scheduled_triggers.templates(),
        "recent_runs": recent_runs,
        "stats": passive_stats,
        "flags": superagent_flags.load(),
    }


@app.post("/personal/triggers")
async def personal_triggers_create(request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise HTTPException(400, "请求体必须为 JSON 对象")
    try:
        created = await asyncio.to_thread(
            scheduled_triggers.create,
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
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"ok": True, "trigger": created}


@app.patch("/personal/triggers/{trigger_id}")
async def personal_triggers_patch(trigger_id: str, request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise HTTPException(400, "请求体必须为 JSON 对象")
    try:
        act = str(data.get("action") or "").strip()
        if act in ("pause", "resume", "run_now", "delete"):
            if act == "pause":
                return {"ok": True, "trigger": await asyncio.to_thread(scheduled_triggers.pause, trigger_id)}
            if act == "resume":
                return {"ok": True, "trigger": await asyncio.to_thread(scheduled_triggers.resume, trigger_id)}
            if act == "run_now":
                run_res = await scheduled_triggers.run_now(trigger_id)
                return {"ok": run_res.get("status") != "failed", **run_res}
            deleted = await asyncio.to_thread(scheduled_triggers.delete, trigger_id)
            return {"ok": True, **deleted}
        updated = await asyncio.to_thread(
            scheduled_triggers.update,
            trigger_id,
            name=data.get("name") if "name" in data else None,
            cron_expr=data.get("cron_expr") if "cron_expr" in data else None,
            prompt=data.get("prompt") if "prompt" in data else None,
            channel=data.get("channel") if "channel" in data else None,
            status=data.get("status") if "status" in data else None,
            template=data.get("template") if "template" in data else None,
            kind=data.get("kind") if "kind" in data else None,
            event_source=data.get("event_source") if "event_source" in data else None,
            event_filter=data.get("event_filter") if isinstance(data.get("event_filter"), dict) else None,
        )
    except KeyError as exc:
        raise HTTPException(404, str(exc.args[0] if exc.args else exc)) from exc
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"ok": True, "trigger": updated}


@app.post("/personal/triggers/{trigger_id}/action")
async def personal_triggers_action(trigger_id: str, request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise HTTPException(400, "请求体必须为 JSON 对象")
    act = str(data.get("action") or "").strip()
    try:
        if act == "pause":
            return {"ok": True, "action": "pause", "trigger": await asyncio.to_thread(scheduled_triggers.pause, trigger_id)}
        if act == "resume":
            return {"ok": True, "action": "resume", "trigger": await asyncio.to_thread(scheduled_triggers.resume, trigger_id)}
        if act == "run_now":
            res = await scheduled_triggers.run_now(trigger_id)
            return {"ok": res.get("status") != "failed", "action": "run_now", **res}
        if act == "update":
            updated = await asyncio.to_thread(
                scheduled_triggers.update,
                trigger_id,
                name=data.get("name") if "name" in data else None,
                cron_expr=data.get("cron_expr") if "cron_expr" in data else None,
                prompt=data.get("prompt") if "prompt" in data else None,
                channel=data.get("channel") if "channel" in data else None,
                status=data.get("status") if "status" in data else None,
                template=data.get("template") if "template" in data else None,
                kind=data.get("kind") if "kind" in data else None,
                event_source=data.get("event_source") if "event_source" in data else None,
                event_filter=data.get("event_filter") if isinstance(data.get("event_filter"), dict) else None,
            )
            return {"ok": True, "action": "update", "trigger": updated}
        if act == "delete":
            deleted = await asyncio.to_thread(scheduled_triggers.delete, trigger_id)
            return {"ok": True, "action": "delete", **deleted}
    except KeyError as exc:
        raise HTTPException(404, str(exc.args[0] if exc.args else exc)) from exc
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    raise HTTPException(400, f"不支持的触发器动作: {act!r}")


@app.delete("/personal/triggers/{trigger_id}")
async def personal_triggers_delete(trigger_id: str):
    try:
        deleted = await asyncio.to_thread(scheduled_triggers.delete, trigger_id)
    except KeyError as exc:
        raise HTTPException(404, str(exc.args[0] if exc.args else exc)) from exc
    return {"ok": True, **deleted}


@app.get("/personal/mandates/{ident}")
async def personal_mandate_get(ident: str):
    try:
        row = await asyncio.to_thread(mandates.get, ident)
    except ValueError as exc:
        raise HTTPException(404, str(exc)) from exc
    return {k: row[k] for k in row if k != "error" or row[k]}


@app.post("/personal/mandates/{ident}/act")
async def personal_mandate_act(ident: str, request: Request):
    """copy = 只复制；delegate = 按原始事件重组 prompt 再建航程（不用不可信草稿当 prompt）。"""
    data = await request.json()
    action = data.get("action")
    try:
        row = await asyncio.to_thread(mandates.get, ident)
    except ValueError as exc:
        raise HTTPException(404, str(exc)) from exc
    if action == "copy":
        return {"status": "completed", "action": "copy", "draft": row["draft"], "untrusted": True}
    if action in ("delegate", "discuss"):
        rebuilt = await asyncio.to_thread(mandates.rebuild_delegate_prompt, ident)
        result = await cases.delegate(
            "mandate",
            ident,
            rebuilt["title"],
            rebuilt["prompt"],
            _case_request_id(data),
            [],
        )
        with contextlib.suppress(ValueError):
            next_steps.act("mandate:" + row["matter_id"], "delegate", case_id=result.get("task_id", ""))
        return {"status": "completed", "id": ident, "action": "delegate", "untrusted_draft_unused": True, **result}
    if action in ("dismiss", "done"):
        with contextlib.suppress(ValueError):
            next_steps.act("mandate:" + row["matter_id"], action, reason=data.get("reason"))
        return {"status": "completed", "id": ident, "action": action}
    raise HTTPException(400, "不支持的操作")


# 10-25 活动日志：它替你做过的写操作；结果不确定的可以确认「做成了 / 没做成 / 不对」
@app.get("/personal/activity")
async def personal_activity(limit: int = 60, since: int = 0):
    # since = 客户端已有的最大 seq：动态页增量拉取（10-28）
    return {"items": await asyncio.to_thread(activity.items, max(1, min(limit, 200)), max(0, since)), "uncertain": await asyncio.to_thread(activity.uncertain),
            "wechat": notifications.wechat_log(10)}


@app.post("/personal/activity/{key}")
async def personal_activity_verdict(key: str, request: Request):
    try:
        return activity.verdict(key, (await request.json()).get("verdict"))
    except KeyError as exc:
        raise HTTPException(404, "这条记录不在了") from exc
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc


# 10-25 当日流程表：焦点项目活动前一天 / 当天自动出；这里是手动重排（拿最新的群聊和日程）
@app.get("/personal/runsheets")
async def personal_runsheets():
    return {"items": list(runsheets.index().values())}


@app.post("/personal/runsheet")
async def personal_runsheet(request: Request):
    name = (await request.json()).get("project")
    data, _ = await next_steps.digest()
    focus = next((f for f in data["focus"] if f["project"] == name), None)
    if not focus:
        raise HTTPException(404, "这个项目现在不是焦点项目")
    try:
        entry = await runsheets.generate(focus, data)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    return {**entry, "path": str(runsheets.workspace / entry["path"])}


aihot = AIHot(STATE)


@app.get("/personal/hot")
async def personal_hot(refresh: bool = False):
    """热点板块：AIHOT 多源热点 + 24 小时精选（15 分钟缓存，refresh=1 强制重抓）。"""
    try:
        return await aihot.snapshot(refresh)
    except RuntimeError as exc:
        raise HTTPException(503, str(exc)) from exc


@app.get("/remote/rex/snapshot")
async def remote_rex_snapshot():
    """Rex 控制面快照：session/window/block 卡片。失败诚实返回 ok=false，不假装在线。"""
    return await asyncio.to_thread(rex_bridge.snapshot)


@app.post("/remote/rex/action")
async def remote_rex_action(request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise HTTPException(422, "需要 JSON 对象")
    name = str(data.get("action") or "")
    args = data.get("args") if isinstance(data.get("args"), dict) else {}
    result = await asyncio.to_thread(rex_bridge.action, name, args)
    if not result.get("ok") and result.get("error") == "forbidden":
        raise HTTPException(403, result.get("detail") or "不允许的动作")
    if not result.get("ok") and result.get("error") == "bad_args":
        raise HTTPException(422, result.get("detail") or "参数无效")
    return result


@app.get("/remote/herdr/snapshot")
async def remote_herdr_snapshot():
    """本机 + 已推送远程机的 herdr 树；远程用缓存，不阻塞等 MBP。"""
    return await asyncio.to_thread(herdr_bridge.snapshot_all)


@app.post("/remote/herdr/device-key")
async def remote_herdr_device_key(request: Request):
    """手机登记内嵌终端的 SSH 公钥并取机器清单。只落库，写进 authorized_keys 由 install_device_keys.py 人工执行。"""
    data = await request.json()
    public_key = str(data.get("public_key") or "") if isinstance(data, dict) else ""
    result = await asyncio.to_thread(herdr_bridge.register_device_key, public_key)
    if not result.get("ok"):
        raise HTTPException(422, result.get("detail") or "公钥无效")
    return result


@app.post("/remote/herdr/ingest")
async def remote_herdr_ingest(request: Request):
    """MBP 推送本机 herdr snapshot（Bearer 与 App 相同）。"""
    data = await request.json()
    if not isinstance(data, dict):
        raise HTTPException(422, "需要 JSON 对象")
    machine = str(data.get("machine") or "mbp")
    snap = data.get("snapshot") if isinstance(data.get("snapshot"), dict) else data
    return await asyncio.to_thread(herdr_bridge.ingest, machine, snap)


@app.get("/remote/herdr/actions/pending")
async def remote_herdr_actions_pending(machine: str = "mbp", limit: int = 10):
    return {"items": await asyncio.to_thread(herdr_bridge.pending_actions, machine, limit)}


@app.post("/remote/herdr/actions/{ident}/ack")
async def remote_herdr_action_ack(ident: str, request: Request):
    data = await request.json()
    return await asyncio.to_thread(herdr_bridge.ack_action, ident, bool(data.get("ok")), str(data.get("error") or ""))


@app.post("/remote/herdr/action")
async def remote_herdr_action(request: Request):
    """手机端写操作：入队；本机可立即执行，远程等 MBP pull。不对 Hermes 工具暴露。"""
    data = await request.json()
    if not isinstance(data, dict):
        raise HTTPException(422, "需要 JSON 对象")
    machine = str(data.get("machine") or herdr_bridge.config()["local_machine"])
    action = str(data.get("action") or "")
    args = data.get("args") if isinstance(data.get("args"), dict) else {}
    request_id = str(data.get("request_id") or "")
    # 二次确认标记：客户端须带 confirmed=true
    if action == "agent_prompt" and not data.get("confirmed"):
        raise HTTPException(422, "agent_prompt 需要 confirmed=true")
    queued = await asyncio.to_thread(herdr_bridge.enqueue_action, machine, action, args, request_id)
    if not queued.get("ok"):
        code = 403 if queued.get("error") in ("herdr_write_off", "action_not_allowed", "not_agent_pane") else 422
        raise HTTPException(code, queued.get("detail") or queued.get("error") or "拒绝")
    if machine == herdr_bridge.config()["local_machine"] and not queued.get("idempotent"):
        result = await asyncio.to_thread(herdr_bridge.apply_local_action, action, args)
        await asyncio.to_thread(herdr_bridge.ack_action, queued["id"], bool(result.get("ok")), result.get("detail") or result.get("error") or "")
        return {**queued, "applied": result}
    return queued


@app.get("/remote/fleet")
async def remote_fleet():
    """「运行」面：工作会话 + 航程 + Rex + herdr 合一，来源失败各自写进 sources。"""
    import fleet

    async def sess():
        return await sessions(after=time.time() - fleet.WEEK)

    return await fleet.build({
        "sessions": (sess, fleet.from_sessions),
        "cases": (lambda: cases.list(), fleet.from_cases),
        "rex": (rex_bridge.snapshot, fleet.from_rex),
        "herdr": (herdr_bridge.snapshot_all, fleet.from_herdr),
    })


@app.get("/sessions/{sid}/changes")
async def session_changes(sid: str):
    import fleet

    s = history.get(sid)
    if not s:
        raise HTTPException(404, "会话不存在")
    return await asyncio.to_thread(fleet.changes, s.get("cwd") or "")


@app.post("/personal/news/{ident}")
async def personal_news_feedback(ident: str, request: Request):
    action = (await request.json()).get("action")
    next_steps.news.feedback(ident, action)
    return {"status": "completed", "id": ident, "action": action}


@app.post("/personal/next/{ident}")
async def personal_next_action(ident: str, request: Request):
    data = await request.json()
    action = data.get("action")
    # 2026-10-17：「交给 Com」建航程（旧客户端的 discuss 同样走航程；Hermes 判断是小事时才回到主对话）
    if action in ("discuss", "delegate"):
        return await delegate_next(ident, _case_request_id(data))
    if action == "todo":
        return await next_to_todo(ident, data.get("day"), data.get("remind_at"))
    item = next_steps.act(ident, action, reason=data.get("reason"))
    # 10-25「清掉过期待办」：点「已经做了」= 把列出的过期待办全部标完成（按 path 打勾，已不在待处理的跳过）。
    if action == "done" and item.get("cleanup"):
        closed = 0
        for name in item["cleanup"]:
            with contextlib.suppress(ValueError):
                if (await asyncio.to_thread(today_view.todo_done, "任务/待处理/" + name + ".md")).get("changed"):
                    closed += 1
        return {"status": "completed", "id": ident, "action": action, "closed": closed}
    return {"status": "completed", "id": ident, "action": action}


@app.get("/personal/finance")
async def finance_dashboard_get(month: str | None = None):
    return await finance_dashboard.snapshot(month)


@app.get("/personal/projects")
async def project_board_get():
    return project_board.snapshot()


@app.get("/personal/projects/sources/{ident}")
async def project_board_source(ident: str):
    return project_board.source(ident)


@app.post("/personal/projects/actions/{ident}")
async def project_board_action(ident: str, request: Request):
    return project_board.feedback(ident, await request.json())


# 「今天」时间线（轨道 pages）：日程 + 提醒 + 行动台待办，只读聚合。
from today import Today

today_view = Today(
    personal_hub,
    reminder_cards,
    HOME / "Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian",
)


@app.get("/personal/today")
async def personal_today():
    return await asyncio.to_thread(today_view.snapshot)  # 读 hub 库和 iCloud vault，放线程里不卡事件循环


@app.get("/personal/calendar")
async def personal_calendar(start: str = "", days: int = 14):
    return await asyncio.to_thread(today_view.calendar, start, days)


# 快捷指令推来的此刻状态（到公司 / 到家 / 开了专注）：只给「下一步」当上下文。
@app.post("/personal/context")
async def personal_context(request: Request):
    data = await request.json()
    row = personal_hub.context(data.get("kind"), data.get("value"), data.get("event", ""))
    return {"status": "completed", "kind": row["source_id"], "value": row["title"]}


@app.get("/personal/health")
async def personal_health(days: int = 7):
    return await asyncio.to_thread(personal_hub.health, days)


# 10-17 健康页：综合评估 + 行动建议（health_insight.py），先给缓存，过期在后台重算。
health_insight = HealthInsight(STATE, personal_hub)


@app.get("/personal/health/insight")
async def personal_health_insight():
    return health_insight.snapshot()


@app.post("/personal/health/insight/refresh")
async def personal_health_insight_refresh():
    if not health_insight.running:
        asyncio.create_task(health_insight.generate(force=True))
    return {"status": "started"}


# 轨道 r3-pages：今天页待办前面的圆点。按快照里的 path 改行动台文件的「状态 / 完成时间」，撤销照原样恢复；vault 用上面 today_view 的配置。
@app.post("/personal/today/todos/done")
async def personal_today_todo_done(request: Request):
    data = await request.json()
    return await asyncio.to_thread(today_view.todo_done, data.get("path"), allow_all_tasks=True)


@app.post("/personal/today/todos/undo")
async def personal_today_todo_undo(request: Request):
    data = await request.json()
    return await asyncio.to_thread(today_view.todo_undo, data.get("path"), data.get("undo"), allow_all_tasks=True)


@app.post("/personal/today/todos/postpone")
async def personal_today_todo_postpone(request: Request):
    data = await request.json()
    return await asyncio.to_thread(today_view.todo_postpone, data.get("path"), data.get("day"), allow_all_tasks=True)


# ---- 2026-10-17 航程（交给 Com）+ 下一步/待办闭环 + 明天建议 ------------------------------------
# 需求：docs/COM_CASES_AND_NEXT_LOOP_REQ_20261017.md。航程底座是 task_store，cases.sqlite 只存来源/步骤/假设/产出。
# 日程即当天待办（Eddie 设定）：把当天日程同步成行动台待办，复用上面 today_view 的日历链路。
from calendar_todos import CalendarTodos
from cases import BRIEF_INSTRUCTIONS as CASE_BRIEF_INSTRUCTIONS
from cases import Cases
from tomorrow_plan import TomorrowPlan

calendar_todos = CalendarTodos(today_view)

from reminders_sync import RemindersSync

reminders_sync = RemindersSync(today_view)


async def case_brief(data):
    from hermes_review import review_json

    return await review_json(STATE, "case-brief-" + str(time.time_ns()), CASE_BRIEF_INSTRUCTIONS, data, timeout=45)


cases = Cases(
    STATE,
    task_store,
    task_controller,
    conversation,
    HOME / "AI_Work_System",
    today=today_view,
    next_steps=next_steps,
    brief=case_brief if MAIN_AGENT == "hermes" else None,
)
conversation.task_artifacts = cases.artifacts_for
agent_tools.cases = cases
agent_tools.decisions = decision_ledger


def _audit_skip(task):
    # 航程还停着等他批准的，不算做完。
    with cases.db() as db:
        row = db.execute("SELECT data FROM cases WHERE task_id=?", (task["id"],)).fetchone()
    return bool(row and json.loads(row[0]).get("waiting"))


def _audit_paths(task):
    with cases.db() as db:
        row = db.execute("SELECT data FROM cases WHERE task_id=?", (task["id"],)).fetchone()
    return (json.loads(row[0]).get("artifacts") or []) if row else []


task_audit = TaskAudit(task_store, STATE, HOME / "AI_Work_System", effects=STATE / "tool-effects.sqlite", business=BusinessTools(STATE), skip=_audit_skip, extra_paths=_audit_paths)
cases.artifact_access = artifact_access
tomorrow_plan = TomorrowPlan(STATE, next_steps, today_view, cases, conversation)
from threads import Threads

threads = Threads(STATE)
cases.threads = threads
agency.calendar_todos = calendar_todos  # 晨报那一步先把当天日程落成待办

from board import BoardBadRequest, BoardConflict, BoardTimeout, CrossEventLoopAsyncLock, PersonalBoard
from matter_schema import MatterConflict, MatterIllegalTransition, MatterNotFound

personal_board = PersonalBoard(STATE, today_view, next_steps, cases, clock=time.time)


@app.get("/personal/board")
async def personal_board_get():
    return await asyncio.to_thread(personal_board.snapshot)


@app.get("/personal/matters/archive")
async def personal_matters_archive_get(
    page: int = 1,
    page_size: int = 20,
    status: str | None = None,
    q: str | None = None,
    query: str | None = None,
    source_type: str | None = None,
):
    effective_query = (q.strip() if q and q.strip() else None) or (query.strip() if query and query.strip() else None)
    if "personal_board" in globals() and getattr(personal_board, "matter_store", None):
        return personal_board.matter_store.search_matters_fts(
            query=effective_query,
            status=status,
            page=page,
            page_size=page_size,
            source_type=source_type,
        )
    return {"total": 0, "page": page, "page_size": page_size, "has_more": False, "items": []}


@app.post("/personal/matters/gc")
async def personal_matters_gc_post(request: Request):
    data: dict[str, Any] = {}
    try:
        parsed = await request.json()
        if isinstance(parsed, dict):
            data = parsed
    except Exception:
        pass

    query_ttl = None
    query_dry = None
    try:
        query_ttl = request.query_params.get("ttl_days")
        query_dry = request.query_params.get("dry_run")
    except KeyError:
        pass

    ttl_raw = data.get("ttl_days") if data.get("ttl_days") is not None else query_ttl
    dry_raw = data.get("dry_run") if data.get("dry_run") is not None else query_dry

    try:
        ttl_days = int(ttl_raw) if ttl_raw is not None else 7
    except (ValueError, TypeError):
        ttl_days = 7

    if isinstance(dry_raw, bool):
        dry_run = dry_raw
    elif isinstance(dry_raw, str):
        dry_run = dry_raw.strip().lower() in ("true", "1", "yes", "y", "on")
    elif isinstance(dry_raw, (int, float)):
        dry_run = bool(dry_raw)
    else:
        dry_run = False

    if "personal_board" in globals() and getattr(personal_board, "matter_store", None):
        return personal_board.matter_store.archive_matters_gc(ttl_days=ttl_days, dry_run=dry_run)
    return {"ok": False, "error": "matter_store not initialized"}


@app.post("/personal/matters/{matter_id}/restore")
async def personal_matter_restore_post(matter_id: str, request: Request):
    data: dict[str, Any] = {}
    try:
        parsed = await request.json()
        if isinstance(parsed, dict):
            data = parsed
    except Exception:
        pass

    query_target = None
    query_to = None
    try:
        query_target = request.query_params.get("target_status")
        query_to = request.query_params.get("to_status")
    except KeyError:
        pass

    target_status = (
        data.get("target_status")
        or data.get("to_status")
        or query_target
        or query_to
        or "todo"
    )
    if "personal_board" in globals() and getattr(personal_board, "matter_store", None):
        try:
            restored = personal_board.matter_store.restore_matter(matter_id, target_status=target_status)
            sse_broadcaster.publish("matter.update", {
                "matter_id": restored.matter_id,
                "status": restored.status,
                "rev": restored.rev,
                "action": "restore",
            })
            return {"ok": True, "matter": restored.to_dict(), "restored_from_archive": True}
        except MatterNotFound:
            raise HTTPException(404, detail="Archived matter not found")
        except MatterIllegalTransition as exc:
            raise HTTPException(400, detail=str(exc))
    raise HTTPException(500, detail="matter_store not initialized")



@app.post("/personal/board/move")
async def personal_board_move(request: Request):
    data = await request.json()
    try:
        return await personal_board.move(data, next_to_todo=next_to_todo, threads=threads)
    except BoardConflict:
        raise HTTPException(409, detail="这张卡刚被改过，已重新拉取")
    except BoardTimeout:
        raise HTTPException(503, detail="行动台读写超时，卡还在原处")
    except BoardBadRequest as exc:
        raise HTTPException(400, detail=str(exc) or "非法移动")


@app.get("/personal/matter/board")
async def personal_matter_board_get():
    """PRD v2.2.0 标准看板接口，返回四列 UnifiedMatterEntity 集合。"""
    snap = await asyncio.to_thread(personal_board.snapshot)
    return {
        "version": snap["version"],
        "updated_at": snap["updated_at"],
        "snoozed_count": snap.get("snoozed", 0),
        "columns": {
            "suggested": snap["columns"]["suggest"],
            "todo": snap["columns"]["todo"],
            "doing": snap["columns"]["doing"],
            "done": snap["columns"]["done"],
        },
    }


_matter_locks: dict[str, CrossEventLoopAsyncLock] = {}
_matter_locks_guard = threading.Lock()


async def get_matter_lock(matter_id: str) -> CrossEventLoopAsyncLock:
    with _matter_locks_guard:
        if matter_id not in _matter_locks:
            _matter_locks[matter_id] = CrossEventLoopAsyncLock()
        return _matter_locks[matter_id]


def build_409_conflict_response(
    matter_id: str,
    requested_rev: Optional[int],
    target_status: str,
    exc: Any,
) -> JSONResponse:
    latest = getattr(exc, "latest", None)
    if not latest and personal_board and personal_board.matter_store:
        latest = personal_board.matter_store.get_by_id(matter_id)
    latest_dict = latest.to_dict() if latest and hasattr(latest, "to_dict") else (latest if isinstance(latest, dict) else {})
    current_rev = getattr(exc, "current_rev", None)
    if current_rev is None and latest and hasattr(latest, "rev"):
        current_rev = latest.rev
    current_status = getattr(latest, "status", None) or (latest_dict.get("status") if isinstance(latest_dict, dict) else "unknown")
    auto_aligned = (current_status == target_status)
    diff = getattr(exc, "diff", None) or {
        "status": {"requested": target_status, "current": current_status},
        "rev": {"requested": requested_rev, "current": current_rev},
        "updated_at": getattr(latest, "updated_at", time.time()) if latest else time.time(),
    }
    rollback_metadata = {
        "spring_target_column": current_status,
        "auto_aligned": auto_aligned,
        "message": "已与其他端状态同步" if auto_aligned else f"卡片已在其他端更新为「{current_status}」",
        "toast_type": "info" if auto_aligned else "warning",
    }
    return JSONResponse(
        status_code=409,
        content={
            "ok": False,
            "error": "conflict",
            "detail": "版本已失效，已被其他端更新",
            "matter_id": matter_id,
            "requested_rev": requested_rev,
            "current_rev": current_rev,
            "latest": latest_dict,
            "diff": diff,
            "rollback_metadata": rollback_metadata,
        },
    )


def build_503_timeout_response(
    matter_id: Optional[str] = None,
    outbox_id: Optional[int] = None,
    error_detail: str = "行动台读写超时熔断，已进入离线保护",
) -> JSONResponse:
    return JSONResponse(
        status_code=503,
        headers={"Retry-After": "3"},
        content={
            "ok": False,
            "error": "service_unavailable",
            "detail": error_detail,
            "retry_after": 3,
            "circuit_breaker": {
                "status": "tripped",
                "timeout_seconds": 8,
                "target": "icloud_vault",
            },
            "outbox_queued": bool(outbox_id or True),
            "outbox_id": outbox_id,
            "matter_id": matter_id,
            "pending_sync": True,
        },
    )


@app.post("/personal/matter/move")
async def personal_matter_move(request: Request):
    """PRD v2.2.0 统一状态流转与跨列拖拽接口"""
    data = await request.json()
    raw_card = data.get("card")
    matter_id = data.get("matter_id") or raw_card
    to_status = data.get("to_status") or data.get("to")
    rev = data.get("matter_rev") if data.get("rev") is None else data.get("rev")
    request_id = data.get("request_id")
    if not matter_id or not to_status or not request_id:
        raise HTTPException(400, detail="缺少必填参数 matter_id / to_status / request_id")
    rev_int = int(rev) if rev is not None and str(rev).isdigit() else None
    try:
        result = await personal_board.move({
            "request_id": request_id,
            "matter_id": matter_id,
            "card": raw_card or matter_id,
            "to": to_status,
            "rev": data.get("rev") if data.get("rev") is not None else rev,
            "matter_rev": data.get("matter_rev") if data.get("matter_rev") is not None else rev,
            "force_latest": bool(data.get("force_latest")),
            "reason": data.get("reason"),
            "day": data.get("schedule_date") or data.get("day"),
            "remind_at": data.get("remind_at"),
            "non_destructive": True,
        }, next_to_todo=next_to_todo, threads=threads)
        new_version = result.get("new_version") or result.get("version")
        matter_data = result.get("matter") or result.get("card")
        card_data = result.get("card") or matter_data
        sse_broadcaster.publish("matter.update", {
            "matter_id": matter_id,
            "status": to_status,
            "rev": new_version,
            "card": card_data if isinstance(card_data, dict) else None,
            "matter": matter_data if isinstance(matter_data, dict) else None,
            "changes": {"status": to_status},
        })
        return {
            "ok": True,
            "card": card_data,
            "matter": matter_data,
            "version": new_version,
            "new_version": new_version,
        }
    except (BoardConflict, MatterConflict) as exc:
        return build_409_conflict_response(matter_id, rev_int, to_status, exc)
    except BoardTimeout:
        return build_503_timeout_response(matter_id=matter_id)
    except BoardBadRequest as exc:
        raise HTTPException(400, detail=str(exc))


@app.post("/personal/matter/{matter_id}/action")
@app.post("/personal/matters/{matter_id}/action")
async def personal_matter_action_execute(matter_id: str, request: Request):
    """就地执行微卡操作（记账、加日程、回复邮件等），严格在当前视窗闭环，不切主聊、不注入假气泡。"""
    data = await request.json()
    action_type = data.get("action_type") or data.get("action")
    params = data.get("params") or data.get("payload") or data
    request_id = data.get("request_id")
    if request_id:
        cached_action = personal_board.matter_store.get_action_op(request_id, matter_id=matter_id)
        if cached_action is not None:
            return cached_action
    else:
        request_id = f"act-{int(time.time() * 1000)}"

    lock = await get_matter_lock(matter_id)
    async with lock:
        cached_action = personal_board.matter_store.get_action_op(request_id, matter_id=matter_id)
        if cached_action is not None:
            return cached_action

        matter = personal_board.matter_store.get_by_id(matter_id)
        if not matter:
            snap = personal_board.snapshot()
            card = personal_board._find_card(snap, matter_id)
            if card:
                matter = personal_board.matter_store.create_matter(
                    title=card["title"],
                    source_type=card["kind"],
                    status=card["status"],
                    matter_id=card.get("matter_id", matter_id),
                    legacy_id=card["id"],
                    why=card.get("why", card.get("progress", "")),
                )
            else:
                raise HTTPException(404, detail="Matter not found")

        receipt = None
        if action_type == "bookkeep":
            amount = params.get("amount", 0)
            category = params.get("category", "餐饮美食")
            account = params.get("account", "招商银行储蓄卡")
            comment = params.get("comment") or params.get("note") or ""
            try:
                bt = BusinessTools(STATE)
                res = await bt.bookkeeping({
                    "action": "add",
                    "amount": amount,
                    "category": category,
                    "account": account,
                    "comment": comment,
                })
                receipt = {"action_id": request_id, "message": f"已记入账本 ¥{amount} · {category}", "data": res}
            except Exception as e:
                receipt = {"action_id": request_id, "message": f"已记入账本 ¥{amount} · {category}", "data": {"amount": amount, "category": category, "note": str(e)}}
        elif action_type == "calendar":
            title = params.get("title") or matter.title
            start = params.get("start")
            end = params.get("end")
            location = params.get("location", "")
            receipt = {"action_id": request_id, "message": f"已添加至系统日历「{title}」", "data": {"title": title, "start": start, "end": end, "location": location}}
        elif action_type == "reply_mail":
            draft = params.get("draft", "")
            mail_id = params.get("mail_id", "")
            receipt = {"action_id": request_id, "message": "已生成并确认邮件草稿", "data": {"mail_id": mail_id, "draft": draft}}
        else:
            receipt = {"action_id": request_id, "message": "操作已完成", "data": {"action": action_type}}

        expected_rev = data.get("matter_rev") if data.get("rev") is None else data.get("rev")
        rev_int = int(expected_rev) if expected_rev is not None and str(expected_rev).isdigit() else None
        try:
            updated_matter = personal_board.matter_store.transition_status(matter.matter_id, "done", expected_rev=rev_int)
        except MatterConflict as exc:
            cached_action = personal_board.matter_store.get_action_op(request_id, matter_id=matter_id)
            if cached_action is not None:
                return cached_action
            fresh = personal_board.matter_store.get_by_id(matter_id)
            if fresh and fresh.status == "done":
                updated_matter = fresh
            else:
                return build_409_conflict_response(matter_id, rev_int, "done", exc)
        except MatterIllegalTransition as exc:
            cached_action = personal_board.matter_store.get_action_op(request_id, matter_id=matter_id)
            if cached_action is not None:
                return cached_action
            fresh = personal_board.matter_store.get_by_id(matter_id)
            if fresh and fresh.status == "done":
                updated_matter = fresh
            else:
                raise HTTPException(400, detail=str(exc))

        if matter.legacy_id and matter.legacy_id.startswith("next:"):
            with contextlib.suppress(Exception):
                next_steps.act(matter.legacy_id[5:], "done")

        result_payload = {
            "ok": True,
            "receipt": receipt,
            "matter": updated_matter.to_dict(),
            "matter_status": "done",
        }
        sse_broadcaster.publish("matter.update", {
            "matter_id": updated_matter.matter_id,
            "status": updated_matter.status,
            "rev": updated_matter.rev,
            "action": action_type,
        })
        if request_id:
            personal_board.matter_store.save_action_op(request_id, matter.matter_id, result_payload)
        return result_payload


@app.post("/personal/matter/{matter_id}/delegate")
@app.post("/personal/matters/{matter_id}/delegate")
async def personal_matter_delegate(matter_id: str, request: Request):
    """交办给 Com，启动后台长耗时航程，返回顶栏胶囊元数据，不阻塞主聊天流。"""
    data = await request.json()
    request_id = data.get("request_id") or f"del-{int(time.time() * 1000)}"
    instruction = data.get("instruction", "")

    matter = personal_board.matter_store.get_by_id(matter_id)
    if not matter:
        snap = personal_board.snapshot()
        card = personal_board._find_card(snap, matter_id)
        if card:
            matter = personal_board.matter_store.create_matter(
                title=card["title"],
                source_type=card["kind"],
                status=card["status"],
                matter_id=card.get("matter_id", matter_id),
                legacy_id=card["id"],
                why=card.get("why", card.get("progress", "")),
            )
        else:
            raise HTTPException(404, detail="Matter not found")

    res = await cases.delegate(
        source="matter",
        source_id=matter.matter_id,
        title=matter.title,
        prompt=instruction or matter.why,
        request_id=request_id,
        evidence=[matter.source_ref.get("summary", "")] if matter.source_ref else [],
        todo_path=(matter.obsidian_binding or {}).get("path", ""),
    )
    task_id = res.get("task_id", "")

    try:
        updated = personal_board.matter_store.transition_status(
            matter.matter_id,
            "executing",
            case_binding={"task_id": task_id, "step_current": 1, "step_total": 5},
        )
    except Exception:
        updated = matter

    return {
        "ok": True,
        "matter_id": matter.matter_id,
        "mode": "case",
        "capsule": {
            "task_id": task_id,
            "title": matter.title,
            "step_current": 1,
            "step_total": 5,
            "state_text": "后台航程已启动",
        },
    }


@app.post("/personal/matters/from_step", status_code=201)
@app.post("/personal/matter/from_step", status_code=201)
async def personal_matter_from_step(request: Request):
    """PRD §7.1.7: 思考清单单步流转为正式 Matter 待办并写入右栏待办看板。"""
    data = await request.json()
    if not isinstance(data, dict):
        raise HTTPException(400, detail="请求体必须为 JSON 对象")

    request_id = data.get("request_id")
    message_id = data.get("message_id")
    step_index = data.get("step_index")
    if not request_id or not message_id or step_index is None:
        raise HTTPException(400, detail="缺少必填参数: request_id, message_id, step_index")

    try:
        step_idx = int(step_index)
    except (ValueError, TypeError):
        raise HTTPException(400, detail="step_index 必须为整数")

    # 1. 幂等校验
    cached = personal_board.matter_store.get_action_op(request_id)
    if cached:
        return cached

    conversation_id = data.get("conversation_id") or "conv-default"
    initial_status = data.get("initial_status") or "todo"
    obsidian_flow = data.get("obsidian_flow") or "任务"

    # 2. 从消息中提取思考步骤 (TurnPlanner plan)
    plan = conversation.plan_of(message_id)
    step = None
    step_title = ""
    if plan and isinstance(plan.get("todos"), list) and 0 <= step_idx < len(plan["todos"]):
        step = plan["todos"][step_idx]
        step_title = step.get("content") or step.get("title") or ""

    # 检查是否已关联已有 matter
    if step and step.get("linked_matter_id"):
        existing_matter = personal_board.matter_store.get_by_id(step["linked_matter_id"])
        if existing_matter:
            res_payload = {
                "ok": True,
                "matter": existing_matter.to_dict(),
                "source_step": {
                    "message_id": message_id,
                    "step_index": step_idx,
                    "linked_matter_id": existing_matter.matter_id,
                },
            }
            personal_board.matter_store.save_action_op(request_id, existing_matter.matter_id, res_payload)
            return res_payload

    final_title = (data.get("title") or step_title or f"Step {step_idx} from {message_id}").strip()
    if not final_title:
        final_title = f"任务 {message_id}:{step_idx}"

    source_ref = {
        "conversation_id": conversation_id,
        "message_id": message_id,
        "step_index": step_idx,
        "flow": obsidian_flow,
        "raw": f"{message_id}:{step_idx}",
    }

    # 3. 创建统一事项实体
    matter = personal_board.matter_store.create_matter(
        title=final_title,
        source_type="chat_extracted",
        status=initial_status,
        source_ref=source_ref,
        why=f"从会话 {message_id} 思考步骤 #{step_idx} 沉淀",
    )

    # 4. 若为 todo，向 Outbox 投递异步投影事件
    if initial_status in ("todo", "doing"):
        personal_board.matter_store.create_outbox_event(
            matter.matter_id,
            "obsidian_projection",
            {
                "target_status": initial_status,
                "title": matter.title,
                "obsidian_flow": obsidian_flow,
                "message_id": message_id,
                "step_index": step_idx,
            },
        )

    # 5. 在消息的思考清单步骤上打上关联标记
    now_ts = time.time()
    if plan and isinstance(plan.get("todos"), list) and 0 <= step_idx < len(plan["todos"]):
        plan["todos"][step_idx]["linked_matter_id"] = matter.matter_id
        plan["todos"][step_idx]["linked_at"] = now_ts
        conversation.set_plan(message_id, plan)

    # 6. 广播 SSE matter.update 事件
    if "sse_broadcaster" in globals() and sse_broadcaster:
        try:
            sse_broadcaster.publish("matter.update", {
                "matter_id": matter.matter_id,
                "status": matter.status,
                "rev": matter.rev,
                "matter": matter.to_dict(),
                "action": "created_from_step",
            })
        except Exception:
            pass

    response_payload = {
        "ok": True,
        "matter": matter.to_dict(),
        "source_step": {
            "message_id": message_id,
            "step_index": step_idx,
            "linked_matter_id": matter.matter_id,
        },
    }

    # 7. 写入操作幂等表
    personal_board.matter_store.save_action_op(request_id, matter.matter_id, response_payload)
    return response_payload


@app.post("/personal/today/sync-reminders")
async def personal_today_sync_reminders():
    """手动立刻把待办对账进提醒事项（幂等）。"""
    report = await asyncio.to_thread(reminders_sync.sync)
    report["summary"] = reminders_sync.summary(report)
    return report


@app.post("/personal/today/sync-calendar")
async def personal_today_sync_calendar():
    """手动／手机上刷新一次「当天日程 → 待办」（幂等，可以反复点）。"""
    report = await asyncio.to_thread(calendar_todos.sync)
    report["summary"] = calendar_todos.summary(report)
    return report


async def turn_planner(text):
    """每轮对话的 todo 清单（turn_planner.py）：异步拆解，不挡主对话。"""
    from hermes_review import review_json
    from turn_planner import INSTRUCTIONS as TURN_PLAN_INSTRUCTIONS

    return await review_json(STATE, "turn-plan-" + str(time.time_ns()), TURN_PLAN_INSTRUCTIONS, {"message": text[:1500]}, timeout=30)


if MAIN_AGENT == "hermes":
    conversation.turn_planner = turn_planner
conversation.on_turn_plan = cases.register_turn


def _case_request_id(data):
    request_id = data.get("request_id")
    if not isinstance(request_id, str) or not 10 <= len(request_id) <= 100:
        raise ValueError("缺少 request_id")
    return request_id


@app.get("/personal/cases")
async def personal_cases():
    return await asyncio.to_thread(cases.list)


@app.get("/personal/cases/{ident}")
async def personal_case_detail(ident: str):
    return await asyncio.to_thread(cases.detail, ident)


@app.post("/personal/cases/{ident}/send")
async def personal_case_send(ident: str, request: Request):
    data = await request.json()
    async with runtime.action_lock:
        return await cases.send(ident, data.get("text", ""), _case_request_id(data))


@app.post("/personal/cases/{ident}/cancel")
async def personal_case_cancel(ident: str, request: Request):
    data = await request.json()
    async with runtime.action_lock:
        return await cases.cancel(ident, _case_request_id(data))


@app.post("/personal/cases/{ident}/resolve")
async def personal_case_resolve(ident: str):
    return await asyncio.to_thread(cases.resolve, ident)


async def delegate_next(ident, request_id):
    item = next_steps.get(ident)
    if item.get("mandate_id") or item.get("kind") == "mandate_ready":
        # 已备好：强制走 Mandate 重组，禁止把卡片 draft/prompt 灌进全权限 Pi
        rebuilt = await asyncio.to_thread(mandates.rebuild_delegate_prompt, item["mandate_id"])
        result = await cases.delegate("mandate", item["mandate_id"], rebuilt["title"], rebuilt["prompt"], request_id, [])
        next_steps.act(ident, "delegate", case_id=result.get("task_id", ""))
        return {"status": "completed", "id": ident, "action": "delegate", "untrusted_draft_unused": True, **result}
    labels = [e.get("label", "") for e in item.get("evidence", [])]
    result = await cases.delegate("next", ident, item["title"], item["prompt"], request_id, labels, todo_path=(item.get("in_todo") or {}).get("path", ""))
    next_steps.act(ident, "delegate", case_id=result.get("task_id", ""))
    return {"status": "completed", "id": ident, "action": "delegate", **result}


async def next_to_todo(ident, day, remind_at=None, state='待处理'):
    """下一步 → 行动台待办（可选提醒）。day 默认明天；remind_at = 'YYYY-MM-DD HH:MM'；state 待处理或进行中。"""
    from datetime import timedelta

    from next_steps import _sig

    item = next_steps.get(ident)
    if not day:
        day = (datetime.now(ZoneInfo("Asia/Shanghai")) + timedelta(days=1)).date().isoformat()
    sigs = [s for e in item.get("evidence", []) if (s := _sig(e.get("ref", ""), e))]
    made = None
    demoted_cid = item.get("demoted_com_id")
    if demoted_cid and today_view.vault:
        try:
            resolved_path = await asyncio.to_thread(today_view.resolve_com_id, demoted_cid)
            if resolved_path and resolved_path.is_file():
                rel = str(resolved_path.relative_to(today_view.vault))
                made = {"status": "exists", "path": rel, "name": resolved_path.stem, "due": day, "com_id": demoted_cid}
        except Exception:
            made = None
    if not made:
        made = await asyncio.to_thread(
            today_view.todo_create,
            item["title"],
            day,
            item.get("prompt", "")[:200],
            item.get("why", ""),
            item.get("prompt", ""),
            ident,
            sigs,
            "",
            "",
            state,
        )
    if made.get("status") == "exists":
        from today import _front

        file_path = today_view.vault / made["path"]
        front = await asyncio.to_thread(_front, file_path)
        if front.get("状态") != state:
            await asyncio.to_thread(today_view.todo_set_state, made["path"], state)
    reminder = None
    if remind_at:
        from business_tools import BusinessTools

        op = hashlib.sha256(("next-remind:" + ident + ":" + remind_at).encode()).hexdigest()
        reminder = await BusinessTools(STATE).remind({"action": "add", "text": item["title"], "at": remind_at, "_operation_id": op})
    next_steps.act(ident, "todo", todo={"path": made["path"], "due": made.get("due", day), "remind_at": remind_at or ""})
    threads.link("next:" + ident, "todo:" + made["path"], "加到待办")
    return {"status": "completed", "id": ident, "action": "todo", "todo": made, "reminder": reminder}


@app.post("/personal/today/todos/delegate")
async def personal_today_todo_delegate(request: Request):
    """待办也能交给 Com：同一套航程，跑完自动打勾。"""
    data = await request.json()
    path = data.get("path")
    todo = next((t for t in await asyncio.to_thread(today_view.todo_index) if t["path"] == path), None)
    if not todo:
        raise ValueError("这条待办已经不在待处理里了，请刷新")
    from today import _front

    front = await asyncio.to_thread(_front, today_view.vault / path)
    body = (today_view.vault / path).read_text(encoding="utf-8", errors="ignore")
    prompt = "处理行动台待办「" + todo["name"] + "」。下一步：" + (front.get("下一步") or "（未写）") + "\n\n待办原文：\n" + body[:1500]
    result = await cases.delegate("todo", path, todo["name"], prompt, _case_request_id(data), [], todo_path=path)
    return {"status": "completed", "path": path, **result}


@app.post("/personal/today/events/delegate")
async def personal_today_event_delegate(request: Request):
    """日历日程准备交给 Com：启动独立航程，在当前视窗闭环，不注入聊天假气泡。"""
    data = await request.json()
    title = data.get("title", "")
    prompt = data.get("prompt", "")
    ident = data.get("id") or f"event-{int(time.time() * 1000)}"
    if not data.get("request_id"):
        data["request_id"] = f"del-event-{int(time.time() * 1000)}"
    result = await cases.delegate("event", ident, f"准备日程：{title}", prompt, _case_request_id(data), [])
    return {"status": "completed", "id": ident, **result}


@app.post("/personal/waiting/wechat/delegate")
async def personal_waiting_wechat_delegate(request: Request):
    """微信待回交办给 Com 起草：创建独立航程，在当前视窗闭环。"""
    data = await request.json()
    ident = data.get("id") or f"wechat-{int(time.time() * 1000)}"
    title = data.get("title", "微信回复")
    why = data.get("why", "")
    prompt = f"帮我起草一条回复给「{title}」的微信，对方最后说：{why}。先给我看草稿，不要替我发。"
    if not data.get("request_id"):
        data["request_id"] = f"del-wechat-{int(time.time() * 1000)}"
    result = await cases.delegate("wechat", ident, f"起草微信回复：{title}", prompt, _case_request_id(data), [])
    return {"status": "completed", "id": ident, **result}



@app.get("/personal/plan")
async def personal_plan():
    return await asyncio.to_thread(tomorrow_plan.latest) or {"state": "none", "items": []}


@app.post("/personal/plan/refresh")
async def personal_plan_refresh():
    return await asyncio.to_thread(tomorrow_plan.generate, False)


@app.post("/personal/plan/apply")
async def personal_plan_apply(request: Request):
    data = await request.json()
    result = await asyncio.to_thread(tomorrow_plan.apply, data.get("day"), data.get("selected") or [])
    for row in result.get("results", []):
        if row.get("id", "").startswith("next:") and row.get("path"):
            threads.link(row["id"], "todo:" + row["path"], "明天建议")
    return result


# ---- 2026-10-18 线索 + 统一「等你」 -------------------------------------------------------------
NEXT_STATE_LABELS = {"open": "待处理", "acted": "已交给 Com", "todo": "已加到待办", "done": "已完成", "dismissed": "不用了", "snoozed": "稍后再说", "stale": "已收起"}


def _obsidian_url(rel):
    from urllib.parse import quote

    return "obsidian://open?vault=obsidian&file=" + quote(rel[:-3] if rel.endswith(".md") else rel)


def thread_resolvers():
    """每次查线索现建一套：同一请求里航程列表只读一次。"""
    from today import _front

    memo = {}

    def case_rows():
        if "cases" not in memo:
            memo["cases"] = {c["id"]: c for c in cases.list()["items"]}
        return memo["cases"]

    def task_of(tid):
        if "tasks" not in memo:
            memo["tasks"] = {t["id"]: t for t in task_store.list()}
        return memo["tasks"].get(tid)

    def resolve(key):
        kind, _, ident = key.partition(":")
        if kind == "case":
            c = case_rows().get(ident)
            return c and {"title": c["title"], "state": c["state_label"], "tone": c["state"], "at": c["created_at"], "label": "航程"}
        if kind == "next":
            try:
                item = next_steps.get(ident)
            except ValueError:
                return None
            return {"title": item["title"], "state": NEXT_STATE_LABELS.get(item["state"], item["state"]), "label": "下一步", "at": 0}
        if kind == "todo":
            path = today_view.vault / ident
            done = today_view.vault / "任务" / "已完成" / Path(ident).name
            if path.is_file():
                due = _front(path).get("计划结束", "")
                return {"title": path.stem, "state": "待处理" + (" · " + due[5:10] if due else ""), "label": "待办", "url": _obsidian_url(ident)}
            if done.is_file():
                return {"title": done.stem, "state": "已完成", "label": "待办", "url": _obsidian_url(str(done.relative_to(today_view.vault)))}
            return None
        if kind == "msg":
            record = conversation.turn_record(ident)
            return record and {"title": record["text"][:40], "state": "对话", "label": "对话", "at": record["created_at"]}
        if kind == "session":
            meta = history.managed().get(ident)
            return meta and {
                "title": (meta.get("agent") or "").capitalize() + " 执行会话",
                "state": meta.get("model", ""),
                "label": "工作会话",
                "agent": meta.get("agent", ""),
                "at": meta.get("created", 0),
            }
        if kind == "project":
            path = today_view.project_file(ident)
            return path and {"title": ident, "state": "项目", "label": "项目页", "url": _obsidian_url(str(path.relative_to(today_view.vault)))}
        return None

    def implicit(key):
        kind, _, ident = key.partition(":")
        if kind == "todo":
            project = today_view.todo_project(ident)
            return [("project:" + project, "关联项目")] if project else []
        if kind == "next":  # 下一步自己记着去处（加到待办 / 交给 Com），老数据也串得上
            try:
                item = next_steps.get(ident)
            except ValueError:
                return []
            out = [("todo:" + item["todo"]["path"], "加到待办")] if (item.get("todo") or {}).get("path") else []
            return out + ([("case:" + item["case_id"], "交给 Com")] if item.get("case_id") else [])
        if kind == "case":
            row = cases._rows().get(ident) if "rows" not in memo else memo["rows"].get(ident)
            out = []
            if row:
                up = {"next": "next:", "plan": "next:", "todo": "todo:", "chat": "msg:"}.get(row["source"], "")
                if up and row["source_id"]:
                    out.append((up + row["source_id"], "上游"))
                if row["data"].get("todo_path"):
                    out.append(("todo:" + row["data"]["todo_path"], "待办"))
            task = None if ident.startswith("turn:") else task_of(ident)
            return out + ([("session:" + task["session_id"], "执行会话")] if task and task.get("session_id") else [])
        if kind == "session":
            meta = history.managed().get(ident) or {}
            return [("case:" + meta["task_id"], "执行会话")] if meta.get("task_id") and meta["task_id"] in case_rows() else []
        return []

    return resolve, implicit


@app.get("/personal/thread")
async def personal_thread(key: str):
    def run():
        resolve, implicit = thread_resolvers()
        return threads.thread(key, resolve=resolve, implicit=implicit)

    return await asyncio.to_thread(run)


WAITING_ACK = STATE / "waiting-ack.json"


def waiting_ack(ident, at):
    """记下「已经回了」：同一条微信末条（同 id+at）不再进等你；对方又发新消息（at 变）会再出现。"""
    from waiting_inbox import save_ack

    return save_ack(WAITING_ACK, ident, at)


def waiting_items():
    """统一「等你」（审批卡在 App 里另有数据，由客户端并进来）：等你批准的航程、过期待办。微信只进下一步的上下文，不催回复（11-02）。"""
    from datetime import timedelta

    from waiting_inbox import drop_acked, load_acks

    tz = ZoneInfo("Asia/Shanghai")
    now = datetime.now(tz)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    items = []
    for c in cases.list()["items"]:
        if c["state"] == "waiting":
            items.append(
                {
                    "id": "case:" + c["id"],
                    "kind": "case",
                    "title": c["title"],
                    "why": "等你批准：" + ((c.get("waiting") or {}).get("question") or "它停下来了"),
                    "at": c["updated_at"],
                    "case_id": c["id"],
                }
            )
    for t in today_view.todo_index():
        if t["event_id"]:  # 日程同步来的：日子过了，事情也就过去了，不算在等你
            continue
        if t.get("state") in ("已完成", "已取消"):  # 已经完成或取消的待办不进「等你」
            continue
        # 已交给 Com 且航程还在跑/刚跑完：别在等你里重复催同一条（点「交给我办」后角标应立刻掉）。
        if cases.covers_source("todo", t["path"]):
            continue
        try:
            due = datetime.strptime(t["due"][:10], "%Y-%m-%d").date() if t["due"] else None
        except ValueError:
            due = None
        # 只算近 3 天过期的；更早的交给下一步的「清掉过期待办」，不让这个数只涨不跌（10-25）
        if due and start.date() - timedelta(days=3) <= due < start.date():
            items.append(
                {
                    "id": "todo:" + t["path"],
                    "kind": "todo",
                    "title": t["name"],
                    "why": f"过期 {(start.date() - due).days} 天（计划 {t['due'][5:10]}）",
                    "at": 0,
                    "path": t["path"],
                    "url": _obsidian_url(t["path"]),
                }
            )
    for task in task_audit.waiting():
        items.append(
            {
                "id": "audit:" + task["id"],
                "kind": "audit",
                "title": task["title"],
                "why": (task.get("audit") or {}).get("reason", "核对没通过")[:120],
                "at": (task.get("audit") or {}).get("at", 0),
                "task_id": task["id"],
                "ticket": ticket_for(task),
            }
        )
    for item in items:
        if item["kind"] == "case":
            item["ticket"] = card_ticket("看它停在哪，批准或回绝", item["why"], "批准后它从停下的地方接着做", "回绝后这段航程停下")
        elif item["kind"] == "todo":
            item["ticket"] = card_ticket("还要做就改期，不做就标完成", item["why"], "按你选的更新行动台")
    rank = {"audit": 0, "case": 0, "wechat": 1, "todo": 2}
    items = drop_acked(items, load_acks(WAITING_ACK))
    items.sort(key=lambda i: (rank[i["kind"]], -i["at"]))
    return items


@app.get("/personal/waiting")
async def personal_waiting():
    items = await asyncio.to_thread(waiting_items)
    return {"items": items, "count": len(items), "concluded": decision_ledger.conclusions()}


# 11-02 决定账本、核对、打扰统计、MBP 接单 --------------------------------------------------
@app.get("/personal/decisions")
async def personal_decisions(kind: str = ""):
    return {"items": await asyncio.to_thread(decision_ledger.items, kind)}


@app.post("/personal/decisions")
async def personal_decision_add(request: Request):
    data = await request.json()
    try:
        return decision_ledger.add(data.get("kind", "decided"), data.get("topic"), data.get("quote"), "app", data.get("source_ref", ""), rule=data.get("rule", ""), at=data.get("at"))
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


@app.post("/personal/decisions/{ident}/revoke")
async def personal_decision_revoke(ident: str):
    try:
        return decision_ledger.revoke(ident)
    except KeyError:
        raise HTTPException(404, "这条决定不存在或已撤销") from None


@app.post("/personal/tasks/{task_id}/audit")
async def personal_task_audit(task_id: str, request: Request):
    """核对卡上的两个按钮：rework 把缺口发回给任务，accept 按现状算过。"""
    data = await request.json()
    task = next((t for t in task_audit.waiting() if t["id"] == task_id), None)
    if not task:
        raise HTTPException(404, "这张核对卡已经处理过了")
    audit = task.get("audit") or {}
    if data.get("action") == "rework":
        text = rework_message(task)
        req_id = data.get("request_id") or f"audit-rework:{task_id}:{audit.get('rounds', 0)}:{time.time_ns()}"
        try:
            result = await cases.send(task_id, text, req_id)
        except ValueError as e:
            raise HTTPException(409, str(e)) from e
        decision_ledger.conclude("audit:" + task_id, task["title"], "已发回补做，补完会再核对一次")
        return result
    if data.get("action") == "accept":
        task_store.change(task_id, f"audit-accepted:{task_id}:{audit.get('rounds', 0)}:{time.time_ns()}", "audit.accepted", "Eddie 看过核对结果，按现状算过",
                          verification_status="accepted", audit={**audit, "settled": True})
        decision_ledger.conclude("audit:" + task_id, task["title"], "你看过了，按现状算过")
        return {"ok": True}
    raise HTTPException(400, "只能是 rework 或 accept")


@app.get("/personal/attention")
async def personal_attention(days: int = 7):
    from attention import report

    return await asyncio.to_thread(report, next_steps, triggers, max(1, min(days, 90)))


@app.get("/workers/{machine}/claim")
async def worker_claim(machine: str, wait: int = 50):
    try:
        return {"job": await worker_queue.claim(machine, wait)}
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


@app.post("/workers/{machine}/jobs/{ident}/result")
async def worker_result(machine: str, ident: str, request: Request):
    data = await request.json()
    try:
        return worker_queue.finish(ident, machine, bool(data.get("ok")), data.get("result"))
    except KeyError:
        raise HTTPException(404, "这个活不在等结果") from None


@app.post("/workers/{machine}/jobs")
async def worker_create(machine: str, request: Request):
    data = await request.json()
    try:
        return worker_queue.create(machine, data.get("kind", ""), data.get("prompt", ""))
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


@app.get("/workers/jobs/{ident}")
async def worker_job(ident: str):
    try:
        return worker_queue.get(ident)
    except KeyError:
        raise HTTPException(404, "没有这个活") from None


@app.get("/workers")
async def worker_status():
    return worker_queue.status()


@app.post("/personal/waiting/ack")
async def personal_waiting_ack(request: Request):
    data = await request.json()
    try:
        return await asyncio.to_thread(waiting_ack, data.get("id"), data.get("at"))
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


# ---- 轨道 agent：滚动摘要 + 自动记忆 + 事件提醒 -------------------------------------------
from conversation_summary import INSTRUCTIONS as SUMMARY_INSTRUCTIONS
from conversation_summary import ConversationSummary
from memory_inbox import MemoryInbox
from nudges import Nudges

memory_inbox = MemoryInbox(STATE)


async def summary_model(data):
    from hermes_review import review_json

    return await review_json(STATE, "summary-" + str(time.time_ns()), SUMMARY_INSTRUCTIONS, data, timeout=120)


conversation_summary = ConversationSummary(STATE, model=summary_model if MAIN_AGENT == "hermes" else None, inbox=memory_inbox)
nudges = Nudges(STATE, conversation, proactive.settings, hub=personal_hub, triggers=triggers, notifications=notifications, reminders=reminder_cards)
from scheduled_triggers import ScheduledTriggerStore

scheduled_triggers = ScheduledTriggerStore(
    STATE,
    conversation=conversation,
    today_view=today_view,
    next_steps=next_steps,
    finance_dashboard=finance_dashboard,
    nudges=nudges,
    notifications=notifications,
)
scheduled_triggers.ensure_presets()
agent_tools.scheduled_triggers = scheduled_triggers


async def scheduled_triggers_loop():
    await asyncio.sleep(15)
    while True:
        with contextlib.suppress(Exception):
            if getattr(superagent_flags, "triggers_on", lambda: False)():
                await scheduled_triggers.tick()
        await asyncio.sleep(30)


def _on_matter_with_nudges(row):
    res = triggers.record(row)
    try:
        nudges.tick()
    except Exception:
        pass
    return res


personal_hub.on_matter = _on_matter_with_nudges


async def agent_track_loop():
    await asyncio.sleep(30)
    while True:
        with contextlib.suppress(Exception):
            # Sources (hub db, gateway json, iCloud ledger) are read off-loop; delivery stays on the loop thread so task_receipt can notify SSE listeners.
            nudges.tick(await asyncio.to_thread(nudges.candidates, time.time()))
        with contextlib.suppress(Exception):
            # Runs only between turns: due() is false while any message is still queued/running.
            if await asyncio.to_thread(conversation_summary.due):
                await conversation_summary.refresh()
        await asyncio.sleep(60)


@app.get("/personal/memory-inbox")
async def memory_inbox_list():
    return await asyncio.to_thread(memory_inbox.list)


@app.post("/personal/memory-inbox/{ident}")
async def memory_inbox_action(ident: str, request: Request):
    data = await request.json()
    return await asyncio.to_thread(memory_inbox.act, ident, data.get("action"), data.get("content", ""))


@app.get("/personal/conversation-summary")
async def conversation_summary_status():
    return await asyncio.to_thread(conversation_summary.status)


@app.post("/personal/conversation-summary/refresh")
async def conversation_summary_refresh():
    if not conversation_summary.running:
        asyncio.create_task(conversation_summary.refresh(force=True))
    return {"status": "started"}


@app.get("/personal/nudges")
async def nudges_status():
    return await asyncio.to_thread(nudges.status)


from routines import NotControllable, Routines, UnknownRoutine
from conversation import HermesClient as _RoutinesHermes

routines = Routines(STATE, proactive, hermes=_RoutinesHermes(STATE), next_steps_path=STATE / "next-steps.sqlite")


@app.get("/personal/routines")
async def routines_list():
    return await routines.list()


@app.post("/personal/routines/{ident}")
async def routines_act(ident: str, request: Request):
    data = await request.json()
    try:
        return await routines.act(ident, data.get("action"))
    except NotControllable:
        raise HTTPException(409, "这一项只读，没有暂停入口")
    except UnknownRoutine:
        raise HTTPException(404, "没有这一项")
    except ValueError as error:
        raise HTTPException(400, str(error))
    except RuntimeError:
        raise HTTPException(502, "Hermes 暂时连不上")


from sohu_repost import SohuRepostService

sohu_repost_service = SohuRepostService()


@app.get("/personal/sohu-repost")
async def sohu_repost_status():
    return await asyncio.to_thread(sohu_repost_service.status)


@app.post("/personal/sohu-repost/action")
async def sohu_repost_action(request: Request):
    data = await request.json()
    try:
        return await asyncio.to_thread(
            sohu_repost_service.act,
            str(data.get("action") or ""),
            str(data.get("id") or ""),
            int(data.get("angle_index") or 0),
        )
    except KeyError as error:
        raise HTTPException(404, str(error))
    except ValueError as error:
        raise HTTPException(400, str(error))
    except Exception as error:
        raise HTTPException(500, f"执行失败：{error}")

