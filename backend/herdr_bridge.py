"""Herdr 控制面：本机只读快照 + MBP 推送缓存 + 写操作入队（不在 mini 上 SSH 到 MBP）。

Config `~/.session-workbench/herdr-bridge.json`（不进仓库）:
  {"herdr_bin":"herdr","timeout_s":6,"local_machine":"mini"}

远程快照：POST /remote/herdr/ingest 写入 `herdr-remote/<machine>.json`
写操作：POST /remote/herdr/action 入队；MBP 拉取 GET .../actions/pending
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import time
import uuid
from pathlib import Path

ALLOWED_ACTIONS = frozenset({"focus_tab", "send_template", "agent_prompt"})
SEND_TEMPLATES = {"newline": "\n", "interrupt": "\x03"}
PROMPT_LIMIT = 500
STALE_S = 90
DEVICE_KEY_RE = re.compile(r"ssh-ed25519 [A-Za-z0-9+/=]{40,120}( [A-Za-z0-9_.@-]{1,64})?")

# herdr agent_status → fleet 粗状态
STATUS_MAP = {
    "working": "working",
    "running": "working",
    "blocked": "blocked",
    "waiting": "blocked",
    "needs_input": "blocked",
    "idle": "idle",
    "unknown": "unknown",
}


def unwrap_snapshot(data: dict) -> dict:
    """CLI 常包一层 {id,result:{snapshot:{...}}}。"""
    if not isinstance(data, dict):
        return {}
    if "tabs" in data or "panes" in data:
        return data
    result = data.get("result")
    if isinstance(result, dict):
        snap = result.get("snapshot")
        if isinstance(snap, dict):
            return snap
        if "tabs" in result or "panes" in result:
            return result
    snap = data.get("snapshot")
    return snap if isinstance(snap, dict) else data


class HerdrBridge:
    def __init__(self, state: Path, clock=time.time, flags=None):
        self.state = Path(state)
        self.path = self.state / "herdr-bridge.json"
        self.remote_dir = self.state / "herdr-remote"
        self.remote_dir.mkdir(parents=True, exist_ok=True)
        self.actions_path = self.state / "herdr-actions.sqlite"
        self.clock = clock
        self.flags = flags
        self._ensure_actions()

    def _ensure_actions(self):
        with self._adb() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS actions(
                    id TEXT PRIMARY KEY,
                    request_id TEXT NOT NULL UNIQUE,
                    machine TEXT NOT NULL,
                    action TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    status TEXT NOT NULL,
                    error TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS herdr_actions_pending ON actions(machine, status, created_at);
                """
            )
        self.actions_path.chmod(0o600)

    def _adb(self):
        db = sqlite3.connect(self.actions_path)
        db.row_factory = sqlite3.Row
        return db

    def config(self) -> dict:
        try:
            raw = json.loads(self.path.read_text())
        except (OSError, ValueError):
            raw = {}
        if not isinstance(raw, dict):
            raw = {}
        bin_name = str(raw.get("herdr_bin") or "herdr")
        resolved = shutil.which(bin_name) or bin_name
        timeout = raw.get("timeout_s", 6)
        try:
            timeout = max(2, min(20, float(timeout)))
        except (TypeError, ValueError):
            timeout = 6.0
        return {
            "herdr_bin": resolved,
            "timeout_s": timeout,
            "local_machine": str(raw.get("local_machine") or "mini"),
        }

    def terminal_machines(self) -> list:
        """内嵌终端可连的机器（herdr-machines.json，不进仓库）。"""
        try:
            raw = json.loads((self.state / "herdr-machines.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        return raw if isinstance(raw, list) else []

    def register_device_key(self, public_key: str) -> dict:
        """记下手机的公钥，不碰 authorized_keys：Com 令牌不能自己给自己开 SSH。"""
        line = (public_key or "").strip()
        if not DEVICE_KEY_RE.fullmatch(line):
            return {"ok": False, "error": "bad_key", "detail": "需要一行 ssh-ed25519 公钥。"}
        path = self.state / "herdr-device-keys.json"
        try:
            keys = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            keys = []
        if line not in keys:
            keys.append(line)
            path.write_text(json.dumps(keys, ensure_ascii=False, indent=2), encoding="utf-8")
            path.chmod(0o600)
        return {"ok": True, "machines": self.terminal_machines()}

    def snapshot(self) -> dict:
        """本机 herdr；失败诚实返回。"""
        at = self.clock()
        cfg = self.config()
        machine = cfg["local_machine"]
        cmd = [cfg["herdr_bin"], "api", "snapshot"]
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=cfg["timeout_s"],
                env={**os.environ, "TERM": "dumb"},
            )
        except FileNotFoundError:
            return {"ok": False, "error": "herdr_not_found", "detail": "本机没有 herdr 命令。", "items": [], "at": at, "machine": machine}
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": "timeout", "detail": "herdr api snapshot 超时。", "items": [], "at": at, "machine": machine}
        err = (proc.stderr or "").strip()
        out = (proc.stdout or "").strip()
        if proc.returncode != 0:
            detail = err or out or f"exit {proc.returncode}"
            code = "server_not_running" if "server_not_running" in detail or "no herdr server" in detail.lower() else "herdr_failed"
            return {"ok": False, "error": code, "detail": detail[:400], "items": [], "at": at, "machine": machine}
        try:
            data = unwrap_snapshot(json.loads(out))
        except ValueError:
            return {"ok": False, "error": "bad_json", "detail": out[:400], "items": [], "at": at, "machine": machine}
        return self._items_from_data(data, machine=machine, at=at, stale=False)

    def snapshot_all(self) -> dict:
        """本机 + 已推送的远程机；远程用缓存，不阻塞。"""
        local = self.snapshot()
        items = list(local.get("items") or [])
        sources = [{"name": "herdr-" + (local.get("machine") or "local"), "ok": local.get("ok"), "error": local.get("error"), "detail": local.get("detail", "")}]
        now = self.clock()
        for path in sorted(self.remote_dir.glob("*.json")):
            machine = path.stem
            if machine == (local.get("machine") or "mini"):
                continue
            try:
                cached = json.loads(path.read_text())
            except (OSError, ValueError):
                sources.append({"name": "herdr-" + machine, "ok": False, "error": "bad_cache", "detail": "远程快照损坏"})
                continue
            at = float(cached.get("at") or 0)
            stale = now - at > STALE_S
            snap = cached.get("snapshot") if isinstance(cached.get("snapshot"), dict) else cached
            built = self._items_from_data(unwrap_snapshot(snap) if isinstance(snap, dict) else {}, machine=machine, at=at, stale=stale)
            items.extend(built.get("items") or [])
            sources.append({
                "name": "herdr-" + machine,
                "ok": True,
                "error": "stale" if stale else None,
                "detail": f"上次推送 {int(now - at)}s 前" if at else "无时间戳",
                "stale": stale,
                "at": at,
            })
        ok = bool(local.get("ok")) or any(s.get("ok") for s in sources[1:])
        return {"ok": ok, "error": None if ok else local.get("error"), "detail": local.get("detail", ""), "items": items, "sources": sources, "at": now}

    def ingest(self, machine: str, snapshot: dict) -> dict:
        machine = "".join(c for c in str(machine) if c.isalnum() or c in "-_")[:40] or "remote"
        at = self.clock()
        path = self.remote_dir / f"{machine}.json"
        path.write_text(json.dumps({"at": at, "snapshot": snapshot}, ensure_ascii=False))
        path.chmod(0o600)
        return {"ok": True, "machine": machine, "at": at, "items": len((unwrap_snapshot(snapshot) or {}).get("tabs") or [])}

    def enqueue_action(self, machine: str, action: str, payload: dict, request_id: str) -> dict:
        if self.flags and not self.flags.herdr_write_on():
            return {"ok": False, "error": "herdr_write_off", "detail": "写操作开关关闭"}
        if action not in ALLOWED_ACTIONS:
            return {"ok": False, "error": "action_not_allowed", "detail": action}
        request_id = str(request_id or "").strip()
        if len(request_id) < 8:
            return {"ok": False, "error": "bad_request_id", "detail": "需要 request_id"}
        machine = str(machine or "").strip()
        if not machine:
            return {"ok": False, "error": "bad_machine", "detail": "需要 machine"}
        payload = dict(payload or {})
        if action == "send_template":
            name = str(payload.get("template") or "")
            if name not in SEND_TEMPLATES:
                return {"ok": False, "error": "bad_template", "detail": name}
            payload = {"template": name, "keys": SEND_TEMPLATES[name], "pane_id": payload.get("pane_id") or "", "tab_id": payload.get("tab_id") or "", "is_agent": bool(payload.get("is_agent"))}
            if name == "interrupt" and not payload.get("is_agent"):
                return {"ok": False, "error": "not_agent_pane", "detail": "中断只对 agent pane"}
        if action == "agent_prompt":
            text = str(payload.get("text") or "")[:PROMPT_LIMIT]
            if not text.strip():
                return {"ok": False, "error": "empty_prompt", "detail": ""}
            payload = {"text": text, "tab_id": payload.get("tab_id") or "", "pane_id": payload.get("pane_id") or ""}
        if action == "focus_tab":
            payload = {"tab_id": str(payload.get("tab_id") or "")}
            if not payload["tab_id"]:
                return {"ok": False, "error": "bad_tab", "detail": ""}
        # 执行前复核：目标须仍出现在最新快照（本机或缓存）
        if not self._target_exists(machine, action, payload):
            return {"ok": False, "error": "target_missing", "detail": "目标 tab/pane 不在当前快照"}
        now = self.clock()
        ident = "hact_" + uuid.uuid4().hex[:20]
        with self._adb() as db:
            row = db.execute("SELECT id,status FROM actions WHERE request_id=?", (request_id,)).fetchone()
            if row:
                return {"ok": True, "id": row["id"], "status": row["status"], "idempotent": True}
            db.execute(
                "INSERT INTO actions(id,request_id,machine,action,payload,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                (ident, request_id, machine, action, json.dumps(payload, ensure_ascii=False), "pending", now, now),
            )
            db.commit()
        return {"ok": True, "id": ident, "status": "pending"}

    def pending_actions(self, machine: str, limit: int = 10) -> list[dict]:
        with self._adb() as db:
            rows = db.execute(
                "SELECT * FROM actions WHERE machine=? AND status='pending' ORDER BY created_at LIMIT ?",
                (machine, max(1, min(limit, 50))),
            ).fetchall()
        return [dict(r) | {"payload": json.loads(r["payload"])} for r in rows]

    def ack_action(self, action_id: str, ok: bool, error: str = "") -> dict:
        with self._adb() as db:
            db.execute(
                "UPDATE actions SET status=?, error=?, updated_at=? WHERE id=?",
                ("done" if ok else "failed", (error or "")[:400], self.clock(), action_id),
            )
            db.commit()
        return {"ok": True, "id": action_id}

    def apply_local_action(self, action: str, payload: dict) -> dict:
        """本机（mini）直接执行白名单动作。"""
        cfg = self.config()
        bin_name = cfg["herdr_bin"]
        try:
            if action == "focus_tab":
                cmd = [bin_name, "tab", "focus", str(payload.get("tab_id"))]
            elif action == "send_template":
                pane = payload.get("pane_id") or payload.get("tab_id")
                cmd = [bin_name, "pane", "send-keys", str(pane), payload.get("keys") or ""]
            elif action == "agent_prompt":
                target = payload.get("pane_id") or payload.get("tab_id")
                cmd = [bin_name, "agent", "prompt", str(target), payload.get("text") or ""]
            else:
                return {"ok": False, "error": "action_not_allowed"}
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=cfg["timeout_s"], env={**os.environ, "TERM": "dumb"})
            if proc.returncode != 0:
                return {"ok": False, "error": "herdr_failed", "detail": (proc.stderr or proc.stdout or "")[:400]}
            return {"ok": True}
        except Exception as exc:
            return {"ok": False, "error": type(exc).__name__, "detail": str(exc)[:300]}

    def _target_exists(self, machine: str, action: str, payload: dict) -> bool:
        if machine == self.config()["local_machine"]:
            snap = self.snapshot()
        else:
            path = self.remote_dir / f"{machine}.json"
            if not path.exists():
                return False
            try:
                cached = json.loads(path.read_text())
                snap = self._items_from_data(unwrap_snapshot(cached.get("snapshot") or {}), machine=machine, at=cached.get("at") or 0, stale=False)
            except (OSError, ValueError):
                return False
        ids = {str(i.get("id") or "").split(":")[-1] for i in snap.get("items") or []}
        # items 里 id 已是纯 tab/pane id；fleet 会再加前缀
        raw_ids = set()
        for i in snap.get("items") or []:
            raw_ids.add(str(i.get("raw_id") or i.get("id") or ""))
        tab = str(payload.get("tab_id") or "")
        pane = str(payload.get("pane_id") or "")
        if action == "focus_tab":
            return tab in raw_ids or tab in ids
        return (pane in raw_ids or pane in ids or tab in raw_ids or tab in ids)

    def _items_from_data(self, data: dict, machine: str, at: float, stale: bool) -> dict:
        items = []
        tabs = data.get("tabs") if isinstance(data, dict) else None
        panes = data.get("panes") if isinstance(data, dict) else None
        agents = {a.get("pane_id"): a for a in (data.get("agents") or []) if isinstance(a, dict)} if isinstance(data, dict) else {}
        if isinstance(tabs, list):
            for tab in tabs:
                if not isinstance(tab, dict):
                    continue
                tid = str(tab.get("tab_id") or tab.get("id") or "")
                label = str(tab.get("label") or tid)
                status = str(tab.get("agent_status") or "unknown")
                mapped = STATUS_MAP.get(status, status)
                items.append(
                    {
                        "id": tid,
                        "raw_id": tid,
                        "kind": "tab",
                        "title": label[:80],
                        "status": mapped,
                        "agent_status": status,
                        "focused": bool(tab.get("focused")),
                        "workspace_id": str(tab.get("workspace_id") or ""),
                        "detail": f"{machine} · tab · {status}",
                        "machine": machine,
                        "is_agent": status not in ("", "unknown", "idle") or bool(tab.get("agent")),
                        "stale": stale,
                    }
                )
        if isinstance(panes, list) and not items:
            for pane in panes:
                if not isinstance(pane, dict):
                    continue
                pid = str(pane.get("pane_id") or "")
                title = str(pane.get("terminal_title_stripped") or pane.get("terminal_title") or pane.get("agent") or pid)
                status = str(pane.get("agent_status") or (agents.get(pid) or {}).get("status") or "unknown")
                mapped = STATUS_MAP.get(status, status)
                is_agent = bool(pane.get("agent") or (agents.get(pid) or {}).get("harness") or status in ("working", "blocked", "waiting"))
                items.append(
                    {
                        "id": pid,
                        "raw_id": pid,
                        "kind": "pane",
                        "title": title[:80],
                        "status": mapped,
                        "agent_status": status,
                        "focused": bool(pane.get("focused")),
                        "detail": str(pane.get("cwd") or "")[:120],
                        "machine": machine,
                        "is_agent": is_agent,
                        "stale": stale,
                    }
                )
        return {
            "ok": True,
            "error": "stale" if stale else None,
            "detail": "",
            "items": items,
            "focused_tab_id": (data.get("focused_tab_id") if isinstance(data, dict) else None),
            "protocol": (data.get("protocol") if isinstance(data, dict) else None),
            "at": at,
            "machine": machine,
            "stale": stale,
        }
