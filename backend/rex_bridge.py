"""Com ↔ Rex control plane: status cards + whitelisted actions via `rex --json`.

Does not embed a PTY. Runs on the session-workbench host (Mac mini). Config:
`~/.session-workbench/rex-bridge.json`
  {
    "rex_bin": "rex",
    "server": "",          # empty = this machine; or a hosts label like "mini"
    "timeout_s": 8
  }
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

ALLOWED_ACTIONS = frozenset({"focus_window", "open_shell", "send_template"})
# Phone may only inject these canned lines — never free-form shell from the WAN.
SEND_TEMPLATES = {
    "newline": "\n",
    "interrupt": "\x03",
    "clear": "clear\n",
}


class RexBridge:
    def __init__(self, state: Path, clock=time.time):
        self.state = Path(state)
        self.path = self.state / "rex-bridge.json"
        self.clock = clock

    def config(self) -> dict:
        try:
            raw = json.loads(self.path.read_text())
        except (OSError, ValueError):
            raw = {}
        if not isinstance(raw, dict):
            raw = {}
        bin_name = str(raw.get("rex_bin") or "rex")
        resolved = shutil.which(bin_name) or bin_name
        server = str(raw.get("server") or "").strip()
        timeout = raw.get("timeout_s", 8)
        try:
            timeout = max(2, min(30, float(timeout)))
        except (TypeError, ValueError):
            timeout = 8.0
        return {"rex_bin": resolved, "server": server, "timeout_s": timeout}

    def _argv(self, *parts: str) -> list[str]:
        cfg = self.config()
        cmd = [cfg["rex_bin"]]
        if cfg["server"]:
            cmd += ["-S", cfg["server"]]
        cmd += list(parts)
        return cmd

    def _run(self, *parts: str) -> dict:
        cfg = self.config()
        cmd = self._argv(*parts)
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=cfg["timeout_s"],
                env={**os.environ, "TERM": "dumb"},
            )
        except FileNotFoundError:
            return {"ok": False, "error": "rex_not_found", "detail": "本机没有 rex 命令——装 Rex 或改 rex-bridge.json 里的 rex_bin。"}
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": "timeout", "detail": "rex 超时——服务或隧道可能挂了。"}
        out = (proc.stdout or "").strip()
        err = (proc.stderr or "").strip()
        if proc.returncode != 0:
            detail = err or out or f"exit {proc.returncode}"
            # Honest: do not pretend the remote control plane is up.
            if "not accepting" in detail.lower() or "connection refused" in detail.lower():
                return {"ok": False, "error": "unreachable", "detail": detail[:400]}
            return {"ok": False, "error": "rex_failed", "detail": detail[:400], "code": proc.returncode}
        if not out:
            return {"ok": True, "data": {}}
        try:
            return {"ok": True, "data": json.loads(out)}
        except ValueError:
            return {"ok": False, "error": "bad_json", "detail": out[:400]}

    @staticmethod
    def _agent_hint(label: str, flavor: str = "") -> str:
        text = f"{label} {flavor}".lower()
        if "claude" in text:
            return "claude"
        if "pi" in text or "π" in label:
            return "pi"
        if "codex" in text:
            return "codex"
        if "herdr" in text:
            return "herdr"
        if "shell" in text or "terminal" in text:
            return "shell"
        return "other"

    @staticmethod
    def _status_for(label: str, agent: str) -> str:
        # Rex CLI snapshot does not always expose running/waiting; label heuristics only.
        low = label.lower()
        if any(x in low for x in ("error", "fail", "崩溃")):
            return "error"
        if agent in ("claude", "pi", "codex"):
            return "running"
        return "idle"

    def snapshot(self) -> dict:
        """Flatten session → window → block into Com remote cards."""
        at = self.clock()
        listed = self._run("ls", "--json")
        if not listed["ok"]:
            return {
                "ok": False,
                "error": listed.get("error"),
                "detail": listed.get("detail", ""),
                "items": [],
                "at": at,
                "server": self.config()["server"] or "local",
            }
        sessions = listed["data"].get("sessions") if isinstance(listed["data"], dict) else None
        if not isinstance(sessions, list):
            sessions = []
        items = []
        for session in sessions:
            if not isinstance(session, dict):
                continue
            sid = str(session.get("session_id") or "")
            slabel = str(session.get("label") or sid or "session")
            if not sid:
                continue
            win = self._run("-s", sid, "window", "list", "--json")
            if not win["ok"]:
                items.append(
                    {
                        "id": sid,
                        "kind": "session",
                        "session_id": sid,
                        "title": slabel,
                        "agent_hint": "other",
                        "status": "error",
                        "detail": win.get("detail", "window list failed")[:160],
                    }
                )
                continue
            data = win["data"] if isinstance(win["data"], dict) else {}
            windows = data.get("windows") if isinstance(data.get("windows"), list) else []
            active = str(data.get("active_window_id") or "")
            for window in windows:
                if not isinstance(window, dict):
                    continue
                wid = str(window.get("window_id") or "")
                wlabel = str(window.get("label") or wid)
                focused = str(window.get("focused_block_id") or "")
                blocks = []
                for layer in window.get("layers") or []:
                    if not isinstance(layer, dict):
                        continue
                    for block in layer.get("blocks") or []:
                        if isinstance(block, dict):
                            blocks.append(block)
                if not blocks:
                    items.append(
                        {
                            "id": wid or sid,
                            "kind": "window",
                            "session_id": sid,
                            "window_id": wid,
                            "title": wlabel,
                            "agent_hint": "other",
                            "status": "idle",
                            "focused": wid == active,
                            "detail": slabel,
                        }
                    )
                    continue
                for block in blocks:
                    bid = str(block.get("block_id") or "")
                    blabel = str(block.get("label") or bid)
                    flavor = str(block.get("flavor") or "")
                    agent = self._agent_hint(blabel, flavor)
                    title = wlabel if wlabel and not wlabel.lower().startswith("window ") else blabel
                    items.append(
                        {
                            "id": bid or wid,
                            "kind": "block",
                            "session_id": sid,
                            "window_id": wid,
                            "block_id": bid,
                            "title": title[:80],
                            "block_label": blabel[:60],
                            "agent_hint": agent,
                            "status": self._status_for(blabel, agent),
                            "focused": bid == focused or wid == active,
                            "detail": f"{slabel} · {blabel}"[:120],
                        }
                    )
        return {
            "ok": True,
            "error": None,
            "detail": "",
            "items": items,
            "at": at,
            "server": self.config()["server"] or "local",
            "session_count": len(sessions),
        }

    def action(self, name: str, args: dict | None = None) -> dict:
        args = args if isinstance(args, dict) else {}
        if name not in ALLOWED_ACTIONS:
            return {"ok": False, "error": "forbidden", "detail": f"不允许的动作：{name}"}
        if name == "focus_window":
            sid = str(args.get("session_id") or "")
            wid = str(args.get("window_id") or "")
            if not sid or not wid:
                return {"ok": False, "error": "bad_args", "detail": "focus_window 需要 session_id 与 window_id"}
            # Prefer client.queue when a GUI is attached; fall back to focus CLI.
            result = self._run("-s", sid, "focus", "--window", wid, "--json")
            if not result["ok"]:
                # Older builds: `rex focus` may not take --json; retry without.
                result = self._run("-s", sid, "focus", "--window", wid)
            return {**result, "action": name}
        if name == "open_shell":
            sid = str(args.get("session_id") or "")
            cmd = ["run", "--keep-open", "--json", "--", "zsh", "-l"]
            if sid:
                result = self._run("-s", sid, *cmd)
            else:
                result = self._run(*cmd)
            return {**result, "action": name}
        if name == "send_template":
            bid = str(args.get("block_id") or "")
            template = str(args.get("template") or "")
            if template not in SEND_TEMPLATES:
                return {"ok": False, "error": "bad_args", "detail": "template 必须是 " + ",".join(sorted(SEND_TEMPLATES))}
            if not bid:
                return {"ok": False, "error": "bad_args", "detail": "send_template 需要 block_id"}
            payload = SEND_TEMPLATES[template]
            # `rex send` writes to the focused / named block; never accept free text from the client.
            result = self._run("-b", bid, "send", "--json", "--", payload)
            if not result["ok"] and "unknown flag" in str(result.get("detail", "")).lower():
                result = self._run("-b", bid, "send", "--", payload)
            return {**result, "action": name}
        return {"ok": False, "error": "unreachable", "detail": "未实现"}
