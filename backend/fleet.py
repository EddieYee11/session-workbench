"""Com「运行」面的后端：把工作会话 / 航程 / Rex / herdr 合成一张状态列表，并给会话看只读 git 改动。

约束：
- 任何来源失败只写进 sources，不拖垮其他来源，也不伪造在线。
- changes() 只跑只读 git 命令（status / diff），列表参数 + 超时，绝不写。
"""

from __future__ import annotations

import asyncio
import re
import inspect
import os
import socket
import subprocess
import time

WEEK = 7 * 86400
MAX_ITEMS = 40
DIFF_LIMIT = 200 * 1024
GIT_TIMEOUT = 8
RANK = {"needs_you": 0, "failed": 1, "running": 2}

SESSION_STATE = {
    "waiting": "needs_you",
    "running": "running",
    "failed": "failed",
    "error": "failed",
    "completed": "done",
    "ended": "done",
}
CASE_STATE = {
    "waiting": "needs_you",
    "attention": "needs_you",
    "running": "running",
    "queued": "running",
    "failed": "failed",
    "done": "done",
    "cancelled": "idle",
}
HERDR_STATE = {
    "working": "running",
    "running": "running",
    "blocked": "needs_you",
    "waiting": "needs_you",
    "done": "done",
    "error": "failed",
    "failed": "failed",
}
REX_STATE = {"running": "running", "error": "failed"}


def _clean_title(title):
    """会话标题可能是客户端注入的内部标记（<local-command-caveat>…），不给人看。"""
    text = re.sub(r"<[^>]*>.*?</[^>]*>|<[^>]*>", " ", str(title or ""), flags=re.S)
    return " ".join(text.split())[:80] or "未命名会话"


def _host() -> str:
    return os.environ.get("COM_HOST_LABEL") or socket.gethostname().split(".")[0]


def _item(**kw) -> dict:
    base = {
        "id": "", "kind": "", "title": "", "goal": "", "agent": "", "state": "idle", "waiting_reason": "",
        "last_activity_at": 0.0, "host": _host(), "session_id": "", "case_id": "",
    }
    base.update(kw)
    base["last_activity_at"] = float(base["last_activity_at"] or 0)
    return base


def from_sessions(data) -> list[dict]:
    out = []
    for s in (data or {}).get("sessions", []):
        state = SESSION_STATE.get(s.get("status", ""), "idle")
        cwd = str(s.get("cwd") or "")
        out.append(_item(
            id="session:" + s["id"], kind="session", title=_clean_title(s.get("display_title") or s.get("title")) or s["id"],
            goal=s.get("case_title") or s.get("snippet") or os.path.basename(cwd.rstrip("/")),
            agent=s.get("agent", ""), state=state, waiting_reason="等你批准或回话" if state == "needs_you" else "",
            last_activity_at=s.get("updated", 0), session_id=s["id"], case_id=s.get("case_id", ""),
        ))
    return out


def from_cases(data) -> list[dict]:
    out = []
    for c in (data or {}).get("items", []):
        state = CASE_STATE.get(c.get("state", ""), "idle")
        waiting = c.get("waiting") or {}
        reason = ""
        if state == "needs_you":
            reason = waiting.get("question") if isinstance(waiting, dict) and waiting.get("question") else (c.get("state_label") or "需要看一眼")
        out.append(_item(
            id="case:" + c["id"], kind="case", title=c.get("title") or c["id"], goal=c.get("now") or "",
            agent=c.get("agent", ""), state=state, waiting_reason=reason,
            last_activity_at=c.get("updated_at", 0), session_id=c.get("session_id", ""), case_id=c["id"],
        ))
    return out


def from_rex(snap) -> list[dict]:
    # Rex 快照没有活动时间，只能用快照时刻；状态也只是按标签推断（见 rex_bridge._status_for）。
    out = []
    for i in (snap or {}).get("items", []):
        status = i.get("status", "idle")
        out.append(_item(
            id="rex:" + str(i.get("id", "")), kind="rex", title=i.get("title") or str(i.get("id", "")),
            goal=i.get("detail", ""), agent=i.get("agent_hint", ""), state=REX_STATE.get(status, "idle"),
            last_activity_at=snap.get("at", 0),
            rex={k: i.get(k, "") for k in ("session_id", "window_id", "block_id")},
        ))
    return out


def from_herdr(snap) -> list[dict]:
    out = []
    for i in (snap or {}).get("items", []):
        status = i.get("status", "unknown")
        state = HERDR_STATE.get(status, "idle")
        out.append(_item(
            id="herdr:" + str(i.get("id", "")), kind="herdr", title=i.get("title") or str(i.get("id", "")),
            goal=i.get("detail", ""), agent="herdr", state=state,
            waiting_reason="herdr 里的 agent 在等输入" if state == "needs_you" else "",
            last_activity_at=snap.get("at", 0),
        ))
    return out


async def _call(fn):
    if inspect.iscoroutinefunction(fn):
        return await fn()
    return await asyncio.to_thread(fn)


async def build(sources: dict, now: float | None = None) -> dict:
    """sources: name -> (fetch, convert)；fetch 可同步可异步。Rex/herdr 的 snapshot 返回 ok=false 也算来源失败。"""
    now = time.time() if now is None else now
    names = list(sources)
    results = await asyncio.gather(*[_call(sources[n][0]) for n in names], return_exceptions=True)
    items, report = [], []
    for name, res in zip(names, results):
        if isinstance(res, BaseException):
            report.append({"name": name, "ok": False, "detail": (str(res) or type(res).__name__)[:200], "error": "exception"})
            continue
        if isinstance(res, dict) and res.get("ok") is False:
            report.append({"name": name, "ok": False, "detail": str(res.get("detail") or res.get("error") or "")[:200], "error": str(res.get("error") or "")})
            continue
        try:
            got = sources[name][1](res)
        except Exception as exc:  # 来源返回了意外结构：同样只记在这个来源上
            report.append({"name": name, "ok": False, "detail": ("数据格式不对：" + str(exc))[:200], "error": "bad_shape"})
            continue
        items += got
        report.append({"name": name, "ok": True, "detail": "", "error": "", "count": len(got)})
    # 航程已代表它的执行会话：别在列表里出现两次。
    case_ids = {i["case_id"] for i in items if i["kind"] == "case"}
    case_sessions = {i["session_id"] for i in items if i["kind"] == "case" and i["session_id"]}
    items = [i for i in items if not (i["kind"] == "session" and (i["case_id"] in case_ids or i["session_id"] in case_sessions))]
    items = [i for i in items if i["last_activity_at"] >= now - WEEK]
    items.sort(key=lambda i: -i["last_activity_at"])
    items.sort(key=lambda i: RANK.get(i["state"], 3))
    return {"items": items[:MAX_ITEMS], "sources": report, "at": now}


# ---------- 只读 git 改动 ----------

def _git(cwd: str, *args: str, limit: int | None = None):
    env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat", "LC_ALL": "C.UTF-8"}
    proc = subprocess.run(["git", "-C", cwd, "-c", "core.quotepath=false", *args], capture_output=True, timeout=GIT_TIMEOUT, env=env)
    out = proc.stdout
    cut = limit is not None and len(out) > limit
    if cut:
        out = out[:limit]
    return proc.returncode, out.decode("utf-8", "replace"), cut


def changes(cwd: str) -> dict:
    if not cwd or not os.path.isdir(cwd):
        return {"git": False, "reason": "工作目录不存在"}
    try:
        code, inside, _ = _git(cwd, "rev-parse", "--is-inside-work-tree")
        if code != 0 or inside.strip() != "true":
            return {"git": False, "reason": "不在 git 仓库里"}
        _, status, _ = _git(cwd, "status", "--porcelain")
        _, stat, stat_cut = _git(cwd, "diff", "HEAD", "--stat", "--no-color", limit=DIFF_LIMIT)
        _, diff, diff_cut = _git(cwd, "diff", "HEAD", "--no-color", "--no-ext-diff", limit=DIFF_LIMIT)
    except FileNotFoundError:
        return {"git": False, "reason": "本机没有 git"}
    except subprocess.TimeoutExpired:
        return {"git": True, "error": "timeout", "reason": "git 超过 8 秒没返回", "files": [], "stat": "", "diff": "", "truncated": False}
    files = [{"status": line[:2].strip() or "?", "path": line[3:].strip()} for line in status.splitlines() if len(line) > 3]
    return {"git": True, "cwd": cwd, "files": files, "stat": stat, "diff": diff, "truncated": bool(diff_cut or stat_cut)}
