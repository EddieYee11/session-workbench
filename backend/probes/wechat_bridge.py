#!/usr/bin/env python3
"""微信按需查询桥 · MBP 端只读 HTTP 服务（2026-10-22）。

背景：微信明文库只在 MBP（~/wechat-decrypt/decrypted），mini 上跑着 Com 的后端。
mini 无法主动连 MBP（Tailscale 那只节点离线、两台也不在同一网段），所以由 MBP 出一条
SSH 反向隧道，把「mini 的 127.0.0.1:18771」接到「MBP 的 127.0.0.1:18771」：

    ssh -N -R 18771:127.0.0.1:18771 mini

只读：不写微信库、不改会话状态、不导出图片。鉴权复用 Com 自己的 API token
（启动时经 SSH 从 mini 读一次并缓存），隧道两端都只绑 127.0.0.1。

接口：
    GET  /health                      → {"ok":true,"ts":...,"self":...}
    POST /query {"kind":"chat",  "chat":"欢迎光临","limit":30,"hours":72}
    POST /query {"kind":"search","query":"秦MAX","limit":20}
    POST /query {"kind":"recent","hours":24,"limit":20}
"""

import json
import os
import subprocess
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
STATE = Path(os.environ.get("WORKBENCH_STATE", str(Path.home() / ".session-workbench")))
HOST = "127.0.0.1"
PORT = int(os.environ.get("WECHAT_BRIDGE_PORT", "18771"))

_lock = threading.Lock()
_loaded = {"mcp": None, "names": None, "self": ""}
_token = {"value": os.environ.get("WECHAT_BRIDGE_TOKEN", ""), "at": 0.0}


def com_token():
    """Com 的 API token：从 mini 读一次，缓存一小时；读不到就让请求失败，不降级。"""
    if _token["value"] and time.time() - _token["at"] < 3600:
        return _token["value"]
    try:
        out = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "mini", "cat ~/.session-workbench/token"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if out.returncode == 0 and out.stdout.strip():
            _token.update(value=out.stdout.strip(), at=time.time())
    except Exception:
        pass
    return _token["value"]


def digest():
    import wechat_digest as module

    return module


def load():
    """微信库与联系人映射只加载一次；mcp_server 会往 stdout 打日志，这里已经由服务自己接管。"""
    with _lock:
        if _loaded["mcp"] is None:
            module = digest()
            mcp = module.load_mcp()
            _loaded.update(mcp=mcp, names=module.load_names(mcp), self=mcp.get_self_username())
    return _loaded["mcp"], _loaded["names"], _loaded["self"]


def _limit(body, default=30, top=200):
    try:
        return max(1, min(int(body.get("limit") or default), top))
    except (TypeError, ValueError):
        return default


def _stamp(epoch):
    return datetime.fromtimestamp(int(epoch or 0)).strftime("%m-%d %H:%M")


def q_chat(body):
    mcp, names, self_user = load()
    chat = str(body.get("chat") or "").strip()
    if not chat:
        raise ValueError("chat 必填：群名、备注名或 wxid")
    username = mcp.resolve_username(chat)
    if not username:
        raise LookupError("找不到会话「%s」；可以用 kind=recent 查看最近的会话名" % chat)
    rows = digest().chat_messages(mcp, username, names, self_user, _limit(body))
    since = float(body.get("since") or 0)
    if since:
        rows = [r for r in rows if r["at"] >= since]
    return {
        "kind": "chat",
        "chat": names.get(username, chat),
        "username": username,
        "messages": [{"at": _stamp(r["at"]), "sender": r["sender"], "text": r["text"]} for r in rows],
    }


def q_search(body):
    mcp, _names, _self = load()
    query = str(body.get("query") or "").strip()
    if not query:
        raise ValueError("query 必填")
    return {"kind": "search", "query": query, "result": mcp.search_messages(query, _limit(body, 20))}


def q_recent(body):
    mcp, names, _self = load()
    try:
        hours = max(1, min(int(body.get("hours") or 24), 24 * 14))
    except (TypeError, ValueError):
        hours = 24
    rows = digest().active_sessions(mcp, time.time() - hours * 3600)
    return {
        "kind": "recent",
        "hours": hours,
        "sessions": [{"name": names.get(r["username"], r["username"]), "unread": r["unread"], "at": _stamp(r["at"]), "summary": r["summary"]} for r in rows[: _limit(body, 20)]],
    }


KINDS = {"chat": q_chat, "search": q_search, "recent": q_recent}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 不把聊天内容写进日志
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        supplied = self.headers.get("authorization", "")
        expected = com_token()
        return bool(expected) and supplied == "Bearer " + expected

    def do_GET(self):
        if self.path not in ("/health", "/"):
            return self._send(404, {"ok": False, "error": "unknown path"})
        if not self._authorized():
            return self._send(401, {"ok": False, "error": "unauthorized"})
        return self._send(200, {"ok": True, "ts": int(time.time())})

    def do_POST(self):
        if self.path != "/query":
            return self._send(404, {"ok": False, "error": "unknown path"})
        if not self._authorized():
            return self._send(401, {"ok": False, "error": "unauthorized"})
        try:
            length = int(self.headers.get("content-length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            kind = str(body.get("kind") or "chat")
            if kind not in KINDS:
                raise ValueError("kind 只能是 chat / search / recent")
            return self._send(200, {"ok": True, **KINDS[kind](body)})
        except LookupError as exc:
            return self._send(404, {"ok": False, "error": str(exc)})
        except ValueError as exc:
            return self._send(400, {"ok": False, "error": str(exc)})
        except Exception as exc:  # 解密库被占用、微信没启动等
            return self._send(503, {"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)})


def main():
    STATE.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("wechat-bridge listening on %s:%s" % (HOST, PORT), flush=True)

    def warm():
        # 冷启动要解密所有消息库（首次 search 可达 30 秒以上），放后台预熟，避免第一次查询就超时。
        try:
            load()
        except Exception as exc:
            print("warm-up failed: %s" % exc, file=sys.stderr, flush=True)

    threading.Thread(target=warm, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
