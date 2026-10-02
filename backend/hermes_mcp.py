"""Narrow, read-only Com! tools for the isolated Hermes Personal Agent.

Hermes starts this file as a stdio MCP server. The server deliberately owns a
fixed set of Com! GET routes; neither the model nor a tool argument can select
an arbitrary URL or HTTP method.
"""

from __future__ import annotations

import stat
import re
from pathlib import Path
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations
from work_dispatch import WorkProposalStore


COM_BASE_URL = "http://127.0.0.1:8650"
COM_TOKEN_FILE = Path.home() / ".session-workbench" / "token"
MAX_RESPONSE_BYTES = 1_000_000

mcp = FastMCP("com-personal-readonly")
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False)
PROPOSAL_ONLY = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)


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
        })
        if len(projected) >= limit:
            break
    return {"sessions": projected, "count": len(projected)}


@mcp.tool(
    description=(
        "Propose a Pi or Codex coding task for the user's approval in Com!. "
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
) -> dict[str, Any]:
    card = WorkProposalStore(Path.home() / ".session-workbench").propose(
        agent=agent,
        relative_cwd=relative_cwd,
        title=title,
        prompt=prompt,
        sandbox=sandbox,
        reason=reason,
        origin_session_id=origin_session_id,
        origin_message_id=origin_message_id,
        origin_request_id=origin_request_id,
        idempotency_key=idempotency_key,
    )
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
            result["work_status_available"] = True
        except RuntimeError:
            result["work_status_available"] = False
    return result


if __name__ == "__main__":
    mcp.run(transport="stdio")
