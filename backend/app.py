import asyncio
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
import pty
import secrets
import signal
import struct
import termios
import time
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, StreamingResponse

from agent_tools import AgentTools
from artifacts import ArtifactAccess
from attachments import AttachmentStore, attachment_router
from background_events import BackgroundEvents
from capabilities import CapabilityRegistry
from conversation import PersonalConversation
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
    PiMainClient(
        STATE, HOME / "AI_Work_System", tools=os.environ.get("COM_PI_SAFE_PROBE") != "1"
    )
    if MAIN_AGENT == "pi"
    else HermesRuntime(STATE),
)
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
from next_steps import INSTRUCTIONS as NEXT_INSTRUCTIONS
from news import News
from health_insight import HealthInsight
from next_steps import NextSteps


async def next_model(digest):
    from hermes_review import review_json

    return await review_json(
        STATE, "next-" + str(time.time_ns()), NEXT_INSTRUCTIONS, digest, timeout=150
    )


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
            row = db.execute(
                "SELECT id,role,text FROM messages WHERE id=?", (message_id,)
            ).fetchone()
            return dict(row) if row else None
    stored = presentations.project(
        source_session_id, history.messages(source_session_id)
    )
    actual_live = presentations.project(
        source_session_id, live_items(runtime.events(source_session_id))
    )
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
            if any(
                m["agent"] == "codex" and not m.get("ended")
                for m in history.managed().values()
            ):
                with contextlib.suppress(Exception):
                    await runtime.ensure_rpc()
            await asyncio.sleep(4)

    task = asyncio.create_task(scan_loop())
    work_proposals.recover_inflight()
    task_store.recover()
    goal_events.recover()

    async def scheduler_loop():
        while True:
            if goal_events.tick():
                conversation.wake.set()
            if proactive.tick(goal_events):
                conversation.wake.set()
            await asyncio.sleep(30)

    scheduler_task = asyncio.create_task(scheduler_loop())

    async def agency_loop():
        while True:
            with contextlib.suppress(Exception):
                await agency.process()
            await asyncio.sleep(5)

    agency_task = asyncio.create_task(agency_loop())

    async def notification_loop():
        while True:
            with contextlib.suppress(Exception):
                await notifications.process()
            await asyncio.sleep(5)

    notification_task = asyncio.create_task(notification_loop())

    async def project_loop():
        while True:
            with contextlib.suppress(Exception):
                snapshot = await asyncio.to_thread(
                    collect_project_sessions, HOME, STATE, "mini", history
                )
                project_board.ingest(snapshot)
                if not proactive.settings()["paused"]:
                    await project_board.review(limit=12)
                    actions = project_board.snapshot()["actions"]
                    for item in actions:
                        if agency.publish_observation(
                            "project:" + item["id"] + ":" + item["version"],
                            "「"
                            + item["project"]
                            + "」下一步："
                            + item["next_step"]
                            + " 可在工作看板查看依据。",
                        ):
                            break
            await asyncio.sleep(900)

    project_task = asyncio.create_task(project_loop())

    async def task_loop():
        while True:
            with contextlib.suppress(Exception):
                async with runtime.action_lock:
                    await task_controller.poll()
                conversation.sync_task_cards(task_store.list())
            await asyncio.sleep(1)

    ledger_loop = asyncio.create_task(task_loop())
    from service_logs import DailyServiceLogs

    service_logs = (
        DailyServiceLogs(STATE) if os.environ.get("COM_SERVICE_LOGS") == "1" else None
    )

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

    # 10-17：案例跑完联动下一步/待办（15 秒一次）；每晚 21:30 生成并推送明天建议。
    async def case_loop():
        await asyncio.sleep(25)
        while True:
            with contextlib.suppress(Exception):
                await asyncio.to_thread(cases.sync)
            with contextlib.suppress(Exception):
                if tomorrow_plan.due():
                    await asyncio.to_thread(tomorrow_plan.generate)
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
    agent_task = asyncio.create_task(
        agent_track_loop()
    )  # 轨道 agent：滚动摘要 + 主动提醒，定义见文件末尾
    quick_voice.start()
    conversation.start()
    inspector.start()
    yield
    task.cancel()
    ledger_loop.cancel()
    scheduler_task.cancel()
    agency_task.cancel()
    project_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await project_task
    notification_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await notification_task
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
app.include_router(attachment_router(attachment_store))
app.include_router(rayneo.router)


@app.middleware("http")
async def auth(request, call_next):
    if request.url.path not in ("/health", "/pair", "/rayneo/v1/pair"):
        supplied = request.headers.get("authorization", "")
        valid = (
            rayneo.authorized(supplied)
            if request.url.path.startswith("/rayneo/")
            else hmac.compare_digest(supplied, "Bearer " + TOKEN)
        )
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
    BUILD_COMMIT = (
        json.loads((STATE / "service-build.json").read_text()).get("commit", "unknown")
        if (STATE / "service-build.json").exists()
        else "unknown"
    )


def deployed_build_commit():
    try:
        return json.loads((STATE / "service-build.json").read_text()).get(
            "commit", BUILD_COMMIT
        )
    except (OSError, ValueError):
        return BUILD_COMMIT


@app.get("/health")
async def health():
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
            "voice_bookkeeping_intent_v1": True,
            "markdown_hindsight_memory_v1": True,
            "direct_business_queries_v1": True,
            "work_chat_v1": True,
            "goal_proposals_v1": True,
            "goals_scheduler": goal_events.enabled(),
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
    data = json.loads(p.read_text())
    if data["expires"] < now or not hmac.compare_digest(
        str(body.get("code", "")), data["code"]
    ):
        raise HTTPException(403, "配对码无效或已过期")
    p.unlink()
    return {"token": TOKEN}


@app.get("/status")
async def status():
    return {
        "index": history.progress,
        "managed": len(history.managed()),
        "host": "Mac mini",
        "default_cwd": str(HOME / "AI_Work_System"),
    }


@app.get("/personal/overview")
async def personal_overview():
    return await personal.overview()


@app.get("/personal/conversation")
async def personal_conversation():
    return conversation.snapshot()


@app.get("/personal/conversation/history")
async def conversation_history(before: str = "", around: str = "", limit: int = 60):
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
    messages = [
        {**item, "kind": "message"} for item in conversation.search(q, date)["items"]
    ]
    start, end = 0, float("inf")
    if date:
        start = (
            datetime.strptime(date, "%Y-%m-%d")
            .replace(tzinfo=ZoneInfo("Asia/Shanghai"))
            .timestamp()
        )
        end = start + 86400

    def match(title, at):
        return (
            (bool(q.strip()) or bool(date))
            and q.strip().lower() in title.lower()
            and start <= at < end
        )

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
    artifacts = [
        {**a, "kind": "artifact", "source": "成果", "text": a["name"]}
        for a in artifact_access.index()
        if match(a["name"], a["created_at"])
    ]
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
            "Content-Disposition": "attachment; filename*=UTF-8''"
            + quote(record["name"]),
        },
    )


@app.get("/personal/conversation/stream")
async def personal_conversation_stream(request: Request):
    raw = request.headers.get("last-event-id", "")
    after = int(raw) if raw.isdecimal() and len(raw) < 19 else None

    async def events():
        from agent_activity import AgentEventProjector

        projector = AgentEventProjector()
        if after is not None:
            # Resume deltas omit unchanged background jobs; seed their durable state
            # once without sending/replaying historical deliveries to the client.
            projector.project({"data": conversation.snapshot()})
        async for frame in conversation.stream(after):
            if frame["event"] == "keepalive":
                yield "event: heartbeat\ndata: {}\n\n"
            else:
                activity, semantic = projector.project(frame)
                payload = json.dumps(
                    {**frame["data"], "activity": activity},
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                yield f"id: {frame['id']}\nevent: {frame['event']}\ndata: {payload}\n\n"
                for item in semantic:
                    payload = json.dumps(
                        item["data"], ensure_ascii=False, separators=(",", ":")
                    )
                    yield f"event: {item['event']}\ndata: {payload}\n\n"

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


def matter_context(matter_id):
    if not matter_id:
        return None
    if not isinstance(matter_id, str):
        raise ValueError("事项标识无效")
    card = next(
        (r for r in personal_hub.briefing()["cards"] if r["id"] == matter_id), None
    )
    row = card or next(
        (r for r in personal_hub.matters() if r["id"] == matter_id), None
    )
    if not row:
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
    if (
        not isinstance(data, dict)
        or not isinstance(data.get("request_id"), str)
        or not isinstance(data.get("text"), str)
    ):
        raise ValueError("消息格式无效")
    if legacy_voice.receipt(data["request_id"]) or quick_voice.receipt(
        data["request_id"]
    ):
        raise ValueError("这条语音已有受理回执，不会重复交办。")
    attachments = attachment_store.resolve(data.get("attachment_ids", []))
    return conversation.submit(
        data["request_id"],
        data["text"],
        data.get("reference"),
        associated_matter=matter_context(data.get("matter_id")),
        attachments=attachments,
    )


@app.post("/personal/conversation/interrupt")
async def interrupt_conversation():
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
    return quick_voice.submit(
        data.get("request_id"), data.get("text"), data.get("purpose", "conversation")
    )


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
        if any(
            t["cwd"] == existing["cwd"]
            and t["id"] != proposal_id
            and t["status"]
            in ("running", "waiting", "unknown", "dispatching", "cancel_requested")
            for t in task_store.list()
        ):
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
            task_store.transition_input(
                command["request_id"], ("pending_start",), "sending"
            )
        try:
            sid = await runtime.create_task_worker(authorized_task)
            if proposal["agent"] == "pi" and not runtime.h.managed().get(sid, {}).get(
                "transport"
            ):
                for _ in range(80):
                    if any(
                        e.get("type") == "session_start" for e in runtime.events(sid)
                    ):
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
                task_store.transition_input(
                    command["request_id"], ("sending",), "delivered"
                )
            return work_proposals.mark_accepted(proposal_id, request_id, sid)
        except Exception as exc:
            task_store.change(
                proposal_id,
                "unknown:" + request_id,
                "execution_unknown",
                status="unknown",
                session_id=locals().get("sid", ""),
            )
            work_proposals.mark_unknown(
                proposal_id, request_id, type(exc).__name__[:80], locals().get("sid")
            )
            for command in initial_inputs:
                task_store.transition_input(
                    command["request_id"],
                    ("sending",),
                    "unknown",
                    "初始任务送达待核实；不会重发",
                )
            raise RuntimeError(
                "派发状态待核实，请先查看工作会话；不会自动重发"
            ) from None


@app.post("/personal/work/proposals/{proposal_id}/reject")
async def reject_personal_work(proposal_id: str):
    proposal = work_proposals.reject(proposal_id)
    task_store.ensure(proposal)
    task_store.change(
        proposal_id, "rejected:" + proposal_id, "rejected", status="rejected"
    )
    return proposal


@app.get("/personal/goal-proposals")
async def personal_goal_proposals(limit: int = 10):
    return {"items": goal_proposals.list(limit)}


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
        decision = goal_proposals.decide(
            proposal_id, data.get("request_id"), approved, rejected
        )
        if decision["applied"] is None:  # 首次执行；已落过库的直接返回回执，不重写文件
            from goal_apply import apply_decision

            decision = goal_proposals.record_applied(
                proposal_id,
                decision["request_id"],
                apply_decision(goal_proposals.get(proposal_id), decision),
            )
        return decision


@app.get("/personal/tasks")
async def personal_tasks():
    for proposal in work_proposals.list(100):
        task_store.ensure(proposal)
    items = []
    for task in task_store.list():
        item = {**task, "acceptance_passed": accepted(task)}
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
                item.update(
                    source_session_id=sid, source_message_id=identity["message_id"]
                )
        items.append(item)
    return {"items": items}


@app.post("/personal/tasks/create")
async def personal_task_create(request: Request):
    data = await request.json()
    if not isinstance(data, dict):
        raise ValueError("Invalid task assignment")
    task, authorization, request_id = authorized_assignment(
        conversation, work_proposals, data
    )
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
        return await task_controller.command(
            task_id, data.get("text"), data.get("request_id")
        )


@app.post("/personal/tasks/{task_id}/inputs/{input_id}/new-item")
async def task_input_new_item(task_id: str, input_id: str, request: Request):
    data = await request.json()
    async with runtime.action_lock:
        result = task_store.move_input(
            task_id, input_id, data.get("request_id"), conversation
        )
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
        if (
            not origin
            or origin["request_id"] != data.get("origin_request_id")
            or not isinstance(quote, str)
            or len(quote) < 2
            or quote not in origin["text"]
        ):
            raise ValueError("取消必须引用实际用户消息")
        if not any(
            word in quote
            for word in ("取消", "停止", "暂停", "先别管", "先不要", "停下", "先停")
        ):
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
        return await task_controller.command(
            task_id, "", data.get("request_id"), cancel=True
        )


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
            task_store.change(
                task_id, "dismiss:" + task_id, "dismissed", "在手机上归档"
            )
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
    rows = await asyncio.to_thread(
        history.list, q, agent, role, cwd, after, sort, archived
    )
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
            # 10-18 会话↔案例互通：这段会话是哪个案例的执行会话
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
        recent = [
            r[0]
            for r in d.execute(
                "SELECT DISTINCT cwd FROM sessions ORDER BY updated DESC LIMIT 12"
            )
            if Path(r[0]).is_dir()
        ]
    return {
        "path": str(p),
        "parent": str(p.parent) if p != HOME else None,
        "directories": [
            str(x)
            for x in sorted(p.iterdir())
            if x.is_dir() and not x.name.startswith(".")
        ],
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
    return {"session": s, "messages": presentations.project(sid, messages)}


async def session_caps(sid, s):
    m = history.managed().get(sid)
    alive = bool(
        m
        and not m.get("ended")
        and (
            sid in runtime.workers.workers
            if m.get("transport")
            else m["agent"] == "codex" or await runtime.alive(m["tmux"])
        )
    )
    stable_identity = runtime.stable_input(sid)
    legacy_restart = (
        alive and not stable_identity and s["agent"] == "pi" and not m.get("transport")
    )
    can_resume = (
        await runtime.legacy_pi_idle(sid)
        if legacy_restart
        else False
        if alive
        else await runtime.resumable(s)
    )
    caps = {
        "history": True,
        "input": alive and stable_identity,
        "stable_message_identity_v1": stable_identity,
        "restart_for_identity": legacy_restart,
        "terminal": alive
        and not (m or {}).get("transport")
        and (s["agent"] == "pi" or bool(history.messages(sid))),
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
        "approvals": [
            {k: v for k, v in a.items() if k != "rpc_id"}
            for a in runtime.approvals.values()
            if a["sid"] == sid
        ],
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
            body = (
                text_content(result.get("content", ""))
                if isinstance(result, dict)
                else str(result)
            )
            if not body:
                body = json.dumps(data.get("args", {}), ensure_ascii=False)
            items[key] = {
                "id": key,
                "role": "tool",
                "title": data.get("toolName", "工具")
                + (" · 执行中" if typ != "tool_execution_end" else " · 已结束"),
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
    if (
        result.get("status") == "rejected"
        and result.get("submission_state") == "not_submitted"
        and result.get("error")
        == "尚未提交：这条消息只形成候选，请补充要完成的动作；草稿已保留"
    ):
        return {
            **result,
            "error": "旧交办限制已解除。上次消息未提交，草稿已保留，现在可直接发送普通消息。",
            "resolution": "legacy_work_chat_gate_removed",
        }
    # Legacy manual-create source validation ran before any task/worker was created.
    if (
        result.get("status") != "unknown"
        or result.get("error")
        != "This message is not an explicit assignment; keep it as a candidate"
    ):
        return result
    with conversation.db() as db:
        human = db.execute(
            "SELECT id,status FROM messages WHERE request_id=?", ("work:" + rid,)
        ).fetchone()
    if (
        not human
        or human["status"] != "failed"
        or any(t.get("origin_message_id") == human["id"] for t in task_store.list())
    ):
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
            d.execute(
                "UPDATE receipts SET data=? WHERE id=?", (json.dumps(result), rid)
            )
    return result


async def once(data, action, preflight=None):
    rid = data.get("request_id", "")
    if len(rid) < 10 or len(rid) > 100:
        raise ValueError("缺少有效请求标识")
    fingerprint = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
    async with runtime.action_lock:
        with history.db() as d:
            old = d.execute(
                "SELECT fingerprint,data FROM receipts WHERE id=?", (rid,)
            ).fetchone()
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
                d.execute(
                    "UPDATE receipts SET data=? WHERE id=?", (json.dumps(result), rid)
                )
            return result
        except Exception as e:
            # Unknown is deliberate: a process may have accepted before transport failed.
            with history.db() as d:
                d.execute(
                    "UPDATE receipts SET data=? WHERE id=?",
                    (
                        json.dumps(
                            {"status": "unknown", "request_id": rid, "error": str(e)}
                        ),
                        rid,
                    ),
                )
            raise
        result = {"status": "accepted", "request_id": rid, **result}
        with history.db() as d:
            d.execute(
                "UPDATE receipts SET data=? WHERE id=?", (json.dumps(result), rid)
            )
        return result


@app.post("/sessions")
async def create(request: Request):
    data = await request.json()
    reference = canonical_reference(
        data.get("reference"), reference_message, "personal-main"
    )
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
                    if any(
                        e.get("type") == "session_start" for e in runtime.events(sid)
                    ):
                        break
                    await asyncio.sleep(0.25)
                else:
                    raise RuntimeError(
                        "Pi 启动未就绪，请在会话中检查终端；不要重复提交"
                    )
                await asyncio.sleep(1)
            transport = presentations.record(
                sid, data["request_id"], data["prompt"], reference
            )
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
    managed = history.managed().get(sid, {})

    async def legacy():
        m = history.managed().get(sid)
        return (
            m
            if m
            and m.get("agent") == "pi"
            and not m.get("ended")
            and not runtime.stable_input(sid)
            and await runtime.alive(m["tmux"])
            else None
        )

    async def preflight():
        if await legacy():
            if not await runtime.legacy_pi_idle(sid):
                raise ValueError(
                    "旧 Pi 会话仍在运行或状态未确认；等会话闲置后才能升级并恢复"
                )
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
    if (
        not isinstance(data, dict)
        or not isinstance(data.get("text"), str)
        or not data["text"].strip()
    ):
        raise ValueError("输入为空")
    reference = canonical_reference(data.get("reference"), reference_message, sid)

    async def preflight_send():
        metadata = history.managed().get(sid, {})
        task = next(
            (t for t in task_store.list() if t["id"] == metadata.get("task_id")), None
        )
        if (
            task
            and not task.get("interactive")
            and task["status"] == "execution_finished"
            and task.get("verification_status") != "passed"
        ):
            raise ValueError("原任务正在验收，请等主线检查结果后继续")
        await runtime.check_input_identity(sid)

    async def action():
        quick_voice.revoke(sid)
        transport = presentations.record(
            sid, data["request_id"], data["text"], reference
        )
        metadata = history.managed().get(sid, {})
        task = next(
            (t for t in task_store.list() if t["id"] == metadata.get("task_id")), None
        )
        if task and task["status"] in ("running", "waiting"):
            delivery = await task_controller.command(
                task["id"], transport, data["request_id"]
            )
            return {
                "sid": sid,
                "turn_id": task["run_id"],
                "submission_state": "submitted",
                "delivery": delivery["delivery"],
                **presentations.identity(sid, data["request_id"]),
            }
        if (
            task
            and not task.get("interactive")
            and task["status"] == "execution_finished"
            and task.get("verification_status") != "passed"
        ):
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
    lines = [
        f"接着之前的一段会话做：《{title}》（{agent}，{where}）。下面是那段会话最后几轮，只是背景："
    ]
    for t in turns[-4:]:
        lines.append(("我：" if t["role"] == "user" else "助手：") + t["text"].strip()[:1500])
    lines.append("—— 现在的要求 ——")
    lines.append(text)
    return "\n\n".join(lines)


async def fork_session(agent, cwd, prompt, request_id):
    cwd = cwd if cwd and Path(cwd).is_dir() and Path(cwd).resolve().is_relative_to(HOME) else str(HOME / "AI_Work_System")
    result = await create(
        _Body({"agent": agent if agent in ("claude", "codex", "pi", "hermes") else "codex", "cwd": cwd,
               "prompt": prompt, "request_id": request_id, "sandbox": "danger-full-access", "model": "", "effort": ""})
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
        if (
            not m
            or m.get("ended")
            or m.get("transport")
            or (MAIN_AGENT == "pi" and m["agent"] == "pi")
        ):
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
    if (
        not isinstance(data, dict)
        or not isinstance(data.get("args"), dict)
        or not isinstance(data.get("context"), dict)
    ):
        raise ValueError("Invalid agent envelope")
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


@app.get("/personal/memory/{memory_id}")
async def memory_detail(memory_id: str):
    from memory_catalog import MemoryCatalog, SharedKnowledgeCatalog

    return (
        SharedKnowledgeCatalog().get(memory_id)
        if memory_id.startswith("doc_")
        else MemoryCatalog().get(memory_id)
    )


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
async def personal_matters():
    return {"items": personal_hub.matters()}


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
        stale = [
            r[0]
            for r in db.execute(
                "SELECT id,source_id FROM matters WHERE source='com_task'"
            )
            if r[1] not in active_ids
        ]
        for ident in stale:
            db.execute("DELETE FROM matters WHERE id=?", (ident,))
    return personal_hub.briefing()


@app.post("/personal/matters/{matter_id}/feedback")
async def matter_feedback(matter_id: str, request: Request):
    data = await request.json()
    return personal_hub.feedback(
        matter_id, data["action"], data["request_id"], data.get("text", "")
    )


@app.post("/personal/matters/{matter_id}/unlink")
async def matter_unlink(matter_id: str):
    return personal_hub.unlink(matter_id)


@app.post("/personal/matters/{matter_id}/action")
async def matter_action(matter_id: str, request: Request):
    data = await request.json()
    return conversation.submit(
        data["request_id"],
        data.get("goal", "分析这件事并给出下一步"),
        associated_matter=matter_context(matter_id),
    )


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
    with contextlib.suppress(Exception):  # 下一步页右上角「案例 · N 进行中」入口
        listing = await asyncio.to_thread(cases.list)
        snap["cases"] = {"active": listing["active"], "waiting": listing["waiting"], "total": len(listing["items"])}
    return snap


@app.post("/personal/next/refresh")
async def personal_next_refresh():
    if not next_steps.running:
        asyncio.create_task(next_steps.refresh(force=True))
    return {"status": "started"}


@app.post("/personal/news/{ident}")
async def personal_news_feedback(ident: str, request: Request):
    action = (await request.json()).get("action")
    next_steps.news.feedback(ident, action)
    return {"status": "completed", "id": ident, "action": action}


@app.post("/personal/next/{ident}")
async def personal_next_action(ident: str, request: Request):
    data = await request.json()
    action = data.get("action")
    # 2026-10-17：「交给 Com」建案例（旧客户端的 discuss 同样走案例；Hermes 判断是小事时才回到主对话）
    if action in ("discuss", "delegate"):
        return await delegate_next(ident, _case_request_id(data))
    if action == "todo":
        return await next_to_todo(ident, data.get("day"), data.get("remind_at"))
    next_steps.act(ident, action)
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
    return await asyncio.to_thread(
        today_view.snapshot
    )  # 读 hub 库和 iCloud vault，放线程里不卡事件循环


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
    return await asyncio.to_thread(today_view.todo_done, data.get("path"))


@app.post("/personal/today/todos/undo")
async def personal_today_todo_undo(request: Request):
    data = await request.json()
    return await asyncio.to_thread(
        today_view.todo_undo, data.get("path"), data.get("undo")
    )


@app.post("/personal/today/todos/postpone")
async def personal_today_todo_postpone(request: Request):
    data = await request.json()
    return await asyncio.to_thread(
        today_view.todo_postpone, data.get("path"), data.get("day")
    )


# ---- 2026-10-17 案例（交给 Com）+ 下一步/待办闭环 + 明天建议 ------------------------------------
# 需求：docs/COM_CASES_AND_NEXT_LOOP_REQ_20261017.md。案例底座是 task_store，cases.sqlite 只存来源/步骤/假设/产出。
from cases import BRIEF_INSTRUCTIONS as CASE_BRIEF_INSTRUCTIONS
from cases import Cases
from tomorrow_plan import TomorrowPlan


async def case_brief(data):
    from hermes_review import review_json

    return await review_json(
        STATE, "case-brief-" + str(time.time_ns()), CASE_BRIEF_INSTRUCTIONS, data, timeout=45
    )


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
agent_tools.cases = cases
tomorrow_plan = TomorrowPlan(STATE, next_steps, today_view, cases, conversation)
from threads import Threads

threads = Threads(STATE)
cases.threads = threads


async def turn_planner(text):
    """每轮对话的 todo 清单（turn_planner.py）：异步拆解，不挡主对话。"""
    from hermes_review import review_json
    from turn_planner import INSTRUCTIONS as TURN_PLAN_INSTRUCTIONS

    return await review_json(
        STATE, "turn-plan-" + str(time.time_ns()), TURN_PLAN_INSTRUCTIONS, {"message": text[:1500]}, timeout=30
    )


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
    labels = [e.get("label", "") for e in item.get("evidence", [])]
    result = await cases.delegate("next", ident, item["title"], item["prompt"], request_id, labels,
                                  todo_path=(item.get("in_todo") or {}).get("path", ""))
    next_steps.act(ident, "delegate", case_id=result.get("task_id", ""))
    return {"status": "completed", "id": ident, "action": "delegate", **result}


async def next_to_todo(ident, day, remind_at=None):
    """下一步 → 行动台待办（可选提醒）。day 默认明天；remind_at = 'YYYY-MM-DD HH:MM'。"""
    from datetime import timedelta

    from next_steps import _sig

    item = next_steps.get(ident)
    if not day:
        day = (datetime.now(ZoneInfo("Asia/Shanghai")) + timedelta(days=1)).date().isoformat()
    sigs = [s for e in item.get("evidence", []) if (s := _sig(e.get("ref", ""), e))]
    made = await asyncio.to_thread(
        today_view.todo_create, item["title"], day, item.get("prompt", "")[:200], item.get("why", ""),
        item.get("prompt", ""), ident, sigs,
    )
    reminder = None
    if remind_at:
        from business_tools import BusinessTools

        op = hashlib.sha256(("next-remind:" + ident + ":" + remind_at).encode()).hexdigest()
        reminder = await BusinessTools(STATE).remind(
            {"action": "add", "text": item["title"], "at": remind_at, "_operation_id": op}
        )
    next_steps.act(ident, "todo", todo={"path": made["path"], "due": made.get("due", day), "remind_at": remind_at or ""})
    threads.link("next:" + ident, "todo:" + made["path"], "加到待办")
    return {"status": "completed", "id": ident, "action": "todo", "todo": made, "reminder": reminder}


@app.post("/personal/today/todos/delegate")
async def personal_today_todo_delegate(request: Request):
    """待办也能交给 Com：同一套案例，跑完自动打勾。"""
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
NEXT_STATE_LABELS = {"open": "待处理", "acted": "已交给 Com", "todo": "已加到待办", "done": "已完成", "dismissed": "不用了",
                     "snoozed": "稍后再说", "stale": "已收起"}


def _obsidian_url(rel):
    from urllib.parse import quote

    return "obsidian://open?vault=obsidian&file=" + quote(rel[:-3] if rel.endswith(".md") else rel)


def thread_resolvers():
    """每次查线索现建一套：同一请求里案例列表只读一次。"""
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
            return c and {"title": c["title"], "state": c["state_label"], "tone": c["state"], "at": c["created_at"], "label": "案例"}
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
            return meta and {"title": (meta.get("agent") or "").capitalize() + " 执行会话", "state": meta.get("model", ""), "label": "工作会话",
                             "agent": meta.get("agent", ""), "at": meta.get("created", 0)}
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


WECHAT_SELF = {"我", "高杰", "野望", "野哥", "小野", "Eddie"}


def waiting_items():
    """统一「等你」（审批卡在 App 里另有数据，由客户端并进来）：等你批准的案例、过期待办、微信里有人在等回话。"""
    import re
    from datetime import timedelta

    tz = ZoneInfo("Asia/Shanghai")
    now = datetime.now(tz)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    items = []
    for c in cases.list()["items"]:
        if c["state"] == "waiting":
            items.append({"id": "case:" + c["id"], "kind": "case", "title": c["title"], "why": "等你批准：" + ((c.get("waiting") or {}).get("question") or "它停下来了"),
                          "at": c["updated_at"], "case_id": c["id"]})
    for chat in (today_view.wechat_digest(start, start + timedelta(days=1)) or {}).get("chats", []):
        last = (chat.get("messages") or [{}])[-1]
        if re.search(r"bot|机器人|助手|通知|提醒", chat["name"], re.I):  # 自己的提醒机器人（如 微信ClawBot / 果到雷达）不算有人在等
            continue
        if (not chat["is_group"] or chat["mention"]) and last.get("sender") and last["sender"] not in WECHAT_SELF:
            items.append({"id": "wechat:" + chat["name"], "kind": "wechat", "title": chat["name"] + ("（群里 @你）" if chat["is_group"] else ""),
                          "why": last["sender"] + "：" + str(last.get("text") or "")[:60], "at": last.get("at") or chat["at"]})
    for t in today_view.todo_index():
        try:
            due = datetime.strptime(t["due"][:10], "%Y-%m-%d").date() if t["due"] else None
        except ValueError:
            due = None
        if due and due < start.date():
            items.append({"id": "todo:" + t["path"], "kind": "todo", "title": t["name"], "why": f"过期 {(start.date() - due).days} 天（计划 {t['due'][5:10]}）",
                          "at": 0, "path": t["path"], "url": _obsidian_url(t["path"])})
    rank = {"case": 0, "wechat": 1, "todo": 2}
    items.sort(key=lambda i: (rank[i["kind"]], -i["at"]))
    return items


@app.get("/personal/waiting")
async def personal_waiting():
    items = await asyncio.to_thread(waiting_items)
    return {"items": items, "count": len(items)}


# ---- 轨道 agent：滚动摘要 + 自动记忆 + 事件提醒 -------------------------------------------
from conversation_summary import INSTRUCTIONS as SUMMARY_INSTRUCTIONS
from conversation_summary import ConversationSummary
from memory_inbox import MemoryInbox
from proactive import Nudges

memory_inbox = MemoryInbox(STATE)


async def summary_model(data):
    from hermes_review import review_json

    return await review_json(
        STATE, "summary-" + str(time.time_ns()), SUMMARY_INSTRUCTIONS, data, timeout=120
    )


conversation_summary = ConversationSummary(
    STATE, model=summary_model if MAIN_AGENT == "hermes" else None, inbox=memory_inbox
)
nudges = Nudges(
    STATE, conversation, proactive.settings, hub=personal_hub, reminders=reminder_cards
)


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
    return await asyncio.to_thread(
        memory_inbox.act, ident, data.get("action"), data.get("content", "")
    )


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
