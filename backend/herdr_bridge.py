"""Read-only herdr session tree for Com's Work › 终端 surface.

Uses `herdr api snapshot` against the local herdr.sock (Mac mini / MBP).
Does not open a PTY and does not accept write actions yet — phone SSH / HerdrKit
can be layered later. Config: `~/.session-workbench/herdr-bridge.json`
  {"herdr_bin": "herdr", "timeout_s": 6}
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path


class HerdrBridge:
    def __init__(self, state: Path, clock=time.time):
        self.state = Path(state)
        self.path = self.state / "herdr-bridge.json"
        self.clock = clock

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
        return {"herdr_bin": resolved, "timeout_s": timeout}

    def snapshot(self) -> dict:
        at = self.clock()
        cfg = self.config()
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
            return {
                "ok": False,
                "error": "herdr_not_found",
                "detail": "本机没有 herdr 命令。",
                "items": [],
                "at": at,
            }
        except subprocess.TimeoutExpired:
            return {
                "ok": False,
                "error": "timeout",
                "detail": "herdr api snapshot 超时。",
                "items": [],
                "at": at,
            }
        err = (proc.stderr or "").strip()
        out = (proc.stdout or "").strip()
        if proc.returncode != 0:
            detail = err or out or f"exit {proc.returncode}"
            code = "server_not_running" if "server_not_running" in detail or "no herdr server" in detail.lower() else "herdr_failed"
            return {"ok": False, "error": code, "detail": detail[:400], "items": [], "at": at}
        try:
            data = json.loads(out)
        except ValueError:
            return {"ok": False, "error": "bad_json", "detail": out[:400], "items": [], "at": at}
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
                items.append(
                    {
                        "id": tid,
                        "kind": "tab",
                        "title": label[:80],
                        "status": status,
                        "focused": bool(tab.get("focused")),
                        "workspace_id": str(tab.get("workspace_id") or ""),
                        "detail": f"tab · {status}",
                    }
                )
        if isinstance(panes, list) and not items:
            for pane in panes:
                if not isinstance(pane, dict):
                    continue
                pid = str(pane.get("pane_id") or "")
                title = str(pane.get("terminal_title_stripped") or pane.get("terminal_title") or pane.get("agent") or pid)
                status = str(pane.get("agent_status") or (agents.get(pid) or {}).get("status") or "unknown")
                items.append(
                    {
                        "id": pid,
                        "kind": "pane",
                        "title": title[:80],
                        "status": status,
                        "focused": bool(pane.get("focused")),
                        "detail": str(pane.get("cwd") or pane.get("foreground_cwd") or "")[:120],
                    }
                )
        return {
            "ok": True,
            "error": None,
            "detail": "",
            "items": items,
            "focused_tab_id": (data.get("focused_tab_id") if isinstance(data, dict) else None),
            "protocol": (data.get("protocol") if isinstance(data, dict) else None),
            "at": at,
        }
