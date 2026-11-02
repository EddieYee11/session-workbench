#!/usr/bin/env python3
"""MBP 侧：推送 herdr snapshot 到 mini，并拉取待执行写操作。

环境变量（不进仓库）：
  COM_HERDR_INGEST_URL   默认 http://127.0.0.1:8650  （建议 ssh -L 或 Tailscale 到 mini）
  COM_HERDR_TOKEN_FILE   默认 ~/.session-workbench/token（需能读到与 mini 相同的 Bearer；可单独拷贝）
  COM_HERDR_MACHINE      默认 mbp
  COM_HERDR_BIN          默认 herdr

launchd 建议每 15–30s 跑一次。不在 mini 上开到 MBP 的 SSH。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

HOME = Path.home()
URL = os.environ.get("COM_HERDR_INGEST_URL", "http://127.0.0.1:8650").rstrip("/")
TOKEN_FILE = Path(os.environ.get("COM_HERDR_TOKEN_FILE", HOME / ".session-workbench" / "herdr-ingest.token"))
MACHINE = os.environ.get("COM_HERDR_MACHINE", "mbp")
BIN = os.environ.get("COM_HERDR_BIN", "herdr")


def token() -> str:
    for path in (TOKEN_FILE, HOME / ".session-workbench" / "token"):
        if path.exists():
            return path.read_text().strip()
    raise SystemExit("missing token file")


def api(method: str, path: str, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        URL + path,
        data=data,
        method=method,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=12) as resp:
        return json.loads(resp.read().decode() or "{}")


def unwrap(data: dict) -> dict:
    if "tabs" in data or "panes" in data:
        return data
    result = data.get("result") if isinstance(data, dict) else None
    if isinstance(result, dict) and isinstance(result.get("snapshot"), dict):
        return result["snapshot"]
    if isinstance(result, dict) and ("tabs" in result or "panes" in result):
        return result
    return data if isinstance(data, dict) else {}


def local_snapshot() -> dict:
    proc = subprocess.run([BIN, "api", "snapshot"], capture_output=True, text=True, timeout=8)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr or proc.stdout or "herdr failed")
    return unwrap(json.loads(proc.stdout))


def apply(action: str, payload: dict) -> tuple[bool, str]:
    try:
        if action == "focus_tab":
            cmd = [BIN, "tab", "focus", str(payload.get("tab_id"))]
        elif action == "send_template":
            target = payload.get("pane_id") or payload.get("tab_id")
            cmd = [BIN, "pane", "send-keys", str(target), payload.get("keys") or ""]
        elif action == "agent_prompt":
            target = payload.get("pane_id") or payload.get("tab_id")
            cmd = [BIN, "agent", "prompt", str(target), payload.get("text") or ""]
        else:
            return False, "unknown action"
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if proc.returncode != 0:
            return False, (proc.stderr or proc.stdout or "")[:300]
        return True, ""
    except Exception as exc:
        return False, f"{type(exc).__name__}: {exc}"


def main():
    snap = local_snapshot()
    api("POST", "/remote/herdr/ingest", {"machine": MACHINE, "snapshot": snap})
    pending = api("GET", f"/remote/herdr/actions/pending?machine={MACHINE}&limit=10")
    for item in pending.get("items") or []:
        ok, err = apply(item["action"], item.get("payload") or {})
        api("POST", f"/remote/herdr/actions/{item['id']}/ack", {"ok": ok, "error": err})
    print(json.dumps({"ok": True, "machine": MACHINE, "tabs": len(snap.get("tabs") or []), "actions": len(pending.get("items") or [])}))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        raise SystemExit(1)
