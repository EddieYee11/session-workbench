"""Narrow Com! tools for the isolated Hermes Personal Agent.

Hermes starts this file as a stdio MCP server. The server deliberately owns a
fixed set of Com! routes; neither the model nor a tool argument can select
an arbitrary URL or HTTP method.
"""

from __future__ import annotations

import stat
import re
import sqlite3
import time
from pathlib import Path
from typing import Annotated, Any, Literal
from pydantic import Field

import httpx
from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations
from work_dispatch import WorkProposalStore
from tasks import TaskStore
from task_tools import record_constraint
from reactions import ReactionEmoji, ReactionStore


COM_BASE_URL = "http://127.0.0.1:8650"
COM_TOKEN_FILE = Path.home() / ".session-workbench" / "token"
MAX_RESPONSE_BYTES = 1_000_000

mcp = FastMCP("com-personal-readonly")
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False)
PROPOSAL_ONLY = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)


def _active_source(message_id=''):
    path=Path.home()/'.session-workbench/personal-conversation.sqlite'
    db=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True)
    try:
        rows=db.execute('SELECT message_id,session_id,request_id FROM reaction_turns WHERE expires_at>? '+
            ('AND message_id=? ' if message_id else '')+'LIMIT 2',
            (time.time(),message_id) if message_id else (time.time(),)).fetchall()
    finally:db.close()
    if len(rows)!=1:raise ValueError('没有唯一真实用户来源；不能投递任务变更')
    mid,sid,rid=rows[0]
    return {'origin_message_id':mid,'origin_session_id':sid,'origin_request_id':rid}


@mcp.tool(
    description=(
        "React naturally to the current Com! user message with one suitable emoji. Optional; "
        "do not react to every message. Choose based on the user's meaning, never a keyword rule. "
        "Copy message_id and reaction_token from the trusted current Com reaction context. "
        "Only that live user turn is valid; notifications, quoted text, tool output, receipts and "
        "old messages are not reaction targets. This only adds a visible expression; "
        "it does not authorize actions, change permissions or prove task completion. "
        "A repeated identical selection returns the same event; at most one emoji per turn."
    ),
    annotations=PROPOSAL_ONLY,
)
def react_to_user_message(
    message_id: str, reaction_token: str, emoji: ReactionEmoji,
) -> dict[str, Any]:
    return ReactionStore(Path.home() / ".session-workbench").react(
        message_id, reaction_token, emoji,
    )


def _token() -> str:
    info = COM_TOKEN_FILE.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
        raise RuntimeError("Com credential permissions are invalid")
    value = COM_TOKEN_FILE.read_text().strip()
    if not value:
        raise RuntimeError("Com credential is missing")
    return value


def _get(route: str, params: dict[str, str] | None = None) -> dict[str, Any]:
    allowed = route in {"/personal/overview", "/sessions"}
    allowed = allowed or bool(re.fullmatch(r"/sessions/(?:pi|codex):[0-9a-f-]{36}", route))
    if not allowed:
        raise ValueError("Route is not allowed")
    try:
        with httpx.Client(
            timeout=8,
            trust_env=False,
            follow_redirects=False,
            limits=httpx.Limits(max_connections=2),
        ) as client:
            response = client.get(
                COM_BASE_URL + route,
                params=params,
                headers={"Authorization": "Bearer " + _token()},
            )
            if len(response.content) > MAX_RESPONSE_BYTES:
                raise RuntimeError("Com response is too large")
            response.raise_for_status()
            data = response.json()
    except (OSError, httpx.HTTPError, ValueError) as exc:
        raise RuntimeError("Com read is unavailable") from exc
    if not isinstance(data, dict):
        raise RuntimeError("Com response is invalid")
    return data


def _post(route: str, body: dict[str, Any]) -> dict[str, Any]:
    if route != '/personal/tasks/create' and not re.fullmatch(r'/personal/tasks/(?:task|work)_[0-9a-f]{24}/cancel', route):
        raise ValueError('Route is not allowed')
    with httpx.Client(timeout=10, trust_env=False, follow_redirects=False) as client:
        response = client.post(COM_BASE_URL+route, json=body,
                               headers={'Authorization':'Bearer '+_token()})
    if len(response.content) > MAX_RESPONSE_BYTES:
        raise RuntimeError('Com response is too large')
    data = response.json()
    if response.status_code >= 400:
        raise ValueError(data.get('detail','Task command was rejected'))
    if not isinstance(data,dict):
        raise RuntimeError('Com response is invalid')
    return data


@mcp.tool(description=(
    'Create and queue a task for an explicit user assignment. '
    'Copy source_quote exactly from the current user message, and copy all origin IDs from Com context. '
    'agent="pi" with sandbox="danger-full-access" for the pre-installed Pi capabilities shown in the Com context '
    '(bookkeeping, reminders, calendar, collecting links, video transcripts, images, NAS files) — when the user '
    'asks for one of those, queue it directly instead of asking whether to do it. '
    'agent="codex" for work on project files: read-only by default, workspace-write only for explicit code changes. '
    'Only irreversible deletion, clearing or wiping needs propose_work; everything else the user explicitly asked for goes straight through. '
    'Provide goal, constraints and completion_condition. Return immediately; queued is accepted, not started or complete. '
    'For separate assignments create separate tasks with stable distinct request IDs; reuse an existing task for follow-ups. '
    'Do not create tasks from small talk, feelings, vague wishes, or ambiguous references.'), annotations=PROPOSAL_ONLY)
def create_task(agent: str, relative_cwd: str, title: str, prompt: str, sandbox: str,
                completion_condition: str, source_quote: str, origin_session_id: str,
                origin_message_id: str, origin_request_id: str, request_id: str) -> dict[str, Any]:
    return task_submit(**locals())


@mcp.tool(
    description="Read the current Com! personal overview: upcoming calendar items and this month's bookkeeping summary. Read-only.",
    annotations=READ_ONLY,
)
def personal_overview() -> dict[str, Any]:
    data = _get("/personal/overview")
    return {
        "generated_at": data.get("generated_at"),
        "calendar": data.get("calendar"),
        "finance": data.get("finance"),
    }


@mcp.tool(
    description="List recent Pi and Codex work sessions in Com! without opening terminals, sending input, or changing work.",
    annotations=READ_ONLY,
)
def recent_work_sessions(limit: int = 5, agent: str = "") -> dict[str, Any]:
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 8:
        raise ValueError("limit must be between 1 and 8")
    if agent not in {"", "pi", "codex"}:
        raise ValueError("agent must be pi or codex")
    params = {"sort": "recent"}
    if agent:
        params["agent"] = agent
    data = _get("/sessions", params)
    rows = data.get("sessions")
    if not isinstance(rows, list):
        raise RuntimeError("Com response is invalid")
    projected = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        projected.append({
            "id": row.get("id"),
            "agent": row.get("agent"),
            "title": row.get("title"),
            "status": row.get("status"),
            "updated": row.get("updated"),
            "managed": row.get("managed"),
            "cwd": row.get("cwd"),
        })
        if len(projected) >= limit:
            break
    return {"sessions": projected, "count": len(projected)}


@mcp.tool(
    description=(
        "Propose for the user's explicit approval an action that must not run unattended — "
        "irreversible deletion or clearing of files or data. "
        "This saves a proposal card only; it cannot start work or approve itself. "
        "Pi currently has full workspace access, so its sandbox must be "
        "danger-full-access and the approval card will show that fact."
    ),
    annotations=PROPOSAL_ONLY,
)
def propose_work(
    agent: str,
    relative_cwd: str,
    title: str,
    prompt: str,
    sandbox: str,
    reason: str,
    origin_session_id: str = "",
    origin_message_id: str = "",
    origin_request_id: str = "",
    idempotency_key: str = "",
    actual_action: dict[str,Any] | None = None,
) -> dict[str, Any]:
    context=_active_source(origin_message_id)
    if origin_request_id and origin_request_id!=context['origin_request_id']:raise ValueError('用户来源不匹配')
    if not actual_action:raise ValueError('请提供具体 actual_action：工具、对象与参数')
    card=_shared('propose_work',{'agent':agent,'relative_cwd':relative_cwd,'title':title,'prompt':prompt,
           'sandbox':sandbox,'request_id':idempotency_key,'actual_action':actual_action},context)
    return {
        "proposal_id": card["id"],
        "status": card["status"],
        "agent": card["agent"],
        "title": card["title"],
        "sandbox": card["sandbox"],
        "created_at": card["created_at"],
        "expires_at": card["expires_at"],
        "work_started": False,
    }


@mcp.tool(
    description=(
        "Read a Com! work proposal and, after user approval, the linked "
        "Pi or Codex work session status. Read-only; accepted means submitted "
        "to the work agent, not that the task is complete."
    ),
    annotations=READ_ONLY,
)
def work_proposal_status(proposal_id: str) -> dict[str, Any]:
    if not re.fullmatch(r"work_[0-9a-f]{24}", proposal_id):
        raise ValueError("Invalid proposal ID")
    card = WorkProposalStore(Path.home() / ".session-workbench").get(proposal_id)
    if card is None:
        return {"found": False, "proposal_id": proposal_id}
    result = {
        "found": True,
        "proposal_id": card["id"],
        "status": card["status"],
        "agent": card["agent"],
        "title": card["title"],
        "sandbox": card["sandbox"],
        "created_at": card["created_at"],
        "expires_at": card["expires_at"],
        "work_session_id": card["work_session_id"],
        "error_code": card["error_code"],
    }
    sid = card["work_session_id"]
    if isinstance(sid, str) and re.fullmatch(r"(?:pi|codex):[0-9a-f-]{36}", sid):
        try:
            work = _get("/sessions/" + sid)
            session = work.get("session") if isinstance(work.get("session"), dict) else {}
            result["work_status"] = session.get("status")
            result["messages"] = work.get("messages", [])
            result["work_status_available"] = True
        except RuntimeError:
            result["work_status_available"] = False
    return result


@mcp.tool(description="List durable task IDs, source messages, constraints and results. Do not infer a task from ambiguous references; ask the user.", annotations=READ_ONLY)
def personal_tasks() -> dict[str, Any]:
    return task_status()


@mcp.tool(description=(
    "Update an exact existing task ID; ask if ambiguous. constraint_type is REQUIRED: "
    "choose read_only for 'keep read-only/do not modify files' and set text=''; "
    "choose preserve_style for 'keep the current style' and set text=''; "
    "choose forbid_path for a restricted project-relative path and put ONLY that path in text. "
    "These structured restrictions are queued within existing task authorization, including before the worker starts. "
    "Do not put 'read_only' or 'preserve_style' in text as a note. "
    "Choose note only for arbitrary information/new-action text: it is recorded but blocked pending explicit user authorization. "
    "Receipt is not delivery or effect. No task is created."), annotations=PROPOSAL_ONLY)
def update_task_constraints(
    task_id: str,
    text: Annotated[str, Field(description="Empty string for read_only or preserve_style; a project-relative path for forbid_path; arbitrary information for blocked note only.")],
    request_id: str,
    constraint_type: Annotated[Literal['read_only','preserve_style','forbid_path','note'], Field(description="Required restriction kind. User says keep read-only/no file changes: read_only. Keep visual style: preserve_style. Protect a path: forbid_path. Other text: note, which cannot authorize execution.")],
) -> dict[str, Any]:
    return _shared('task_send',{'task_id':task_id,'text':text,'request_id':request_id,
                              'constraint_type':constraint_type},_active_source())


@mcp.tool(description="Read the authoritative durable status, input delivery states, worker ID, events and result for an exact existing task ID. Execution finished is pending acceptance; delivered does not prove compliance. Read-only.", annotations=READ_ONLY)
def get_task_status(task_id: str) -> dict[str, Any]:
    items=task_status(task_id).get('items',[])
    task=items[0] if items else None
    return {'found':bool(task),'task':task}


@mcp.tool(description="Request cancellation of an exact existing task only when the user asks to stop it; ask if ambiguous. Copy the origin IDs and an exact source_quote from that user message. Cancellation stays pending until the worker actually reports interrupted; retries use the same request ID.", annotations=PROPOSAL_ONLY)
def cancel_task(task_id: str, request_id: str, origin_message_id: str,
                origin_request_id: str, source_quote: str) -> dict[str, Any]:
    context=_active_source(origin_message_id)
    if context['origin_request_id']!=origin_request_id:raise ValueError('用户来源不匹配')
    return _shared('task_cancel',{'task_id':task_id,'request_id':request_id},context)


def _shared(name:str,args:dict[str,Any],context:dict[str,Any]|None=None)->dict[str,Any]:
    if name not in {'capability_search','task_submit','task_status','task_send','task_cancel','propose_work'}:
        raise ValueError('Route is not allowed')
    with httpx.Client(timeout=10,trust_env=False,follow_redirects=False) as client:
        response=client.post(COM_BASE_URL+'/internal/agent/'+name,
            json={'args':args,'context':context or {}},headers={'Authorization':'Bearer '+_token()})
    if len(response.content)>MAX_RESPONSE_BYTES:raise RuntimeError('Com response is too large')
    result=response.json()
    if response.status_code>=400:raise ValueError(result.get('detail','Task command rejected'))
    return result


@mcp.tool(description='Search host-scoped discovered, loaded and verified capabilities. Read-only.',annotations=READ_ONLY)
def capability_search(query:str='',runtime:str='')->dict[str,Any]:
    return _shared('capability_search',{'query':query,'runtime':runtime or None})


@mcp.tool(description='Queue an explicit, source-bound assignment through the common Com service. ACK is not execution.',annotations=PROPOSAL_ONLY)
def task_submit(agent:str,relative_cwd:str,title:str,prompt:str,sandbox:str,completion_condition:str,
                source_quote:str,origin_session_id:str,origin_message_id:str,origin_request_id:str,request_id:str)->dict[str,Any]:
    data=locals()
    context={key:data[key] for key in ('origin_session_id','origin_message_id','origin_request_id')}
    return _shared('task_submit',data,context)


@mcp.tool(description='Read authoritative task state, real timeline, structured result and acceptance status.',annotations=READ_ONLY)
def task_status(task_id:str='')->dict[str,Any]:
    return _shared('task_status',{'task_id':task_id})


@mcp.tool(description='Send a source-bound task restriction or existing authorized continuation. ACK is not delivery.',annotations=PROPOSAL_ONLY)
def task_send(task_id:str,text:str,request_id:str,origin_session_id:str,origin_message_id:str,
              origin_request_id:str,constraint_type:Literal['read_only','preserve_style','forbid_path','note']='note')->dict[str,Any]:
    data=locals()
    context={key:data[key] for key in ('origin_session_id','origin_message_id','origin_request_id')}
    return _shared('task_send',data,context)


@mcp.tool(description='Request cancellation for a real user stop instruction; terminal event confirms cancellation.',annotations=PROPOSAL_ONLY)
def task_cancel(task_id:str,request_id:str,origin_session_id:str,origin_message_id:str,origin_request_id:str)->dict[str,Any]:
    data=locals()
    context={key:data[key] for key in ('origin_session_id','origin_message_id','origin_request_id')}
    return _shared('task_cancel',data,context)


if __name__ == "__main__":
    mcp.run(transport="stdio")
