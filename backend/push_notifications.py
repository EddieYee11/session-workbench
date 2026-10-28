# ruff: noqa: I001
# pyright: reportMissingImports=false, reportOptionalSubscript=false, reportOptionalMemberAccess=false, reportAttributeAccessIssue=false
"""Durable push outbox: APNs when a provider key exists, else Bark (self-hostable iOS push relay).

Bark 是个人 Apple 账号发不了 APNs 时的替代：mini 把通知 POST 到 Bark 服务器，手机上的 Bark App
负责显示，点开后通过 com-eddie:// 深链回到 Com。配置文件 bark-config.json：
{"device_key": "<Bark App 里的 Key>", "server": "https://api.day.app", "preview": false}
preview=false 时推送正文不含消息内容，只提示「已为你整理好」。
Provider acceptance is never described as device delivery.
Approvals are queued as a separate, actionable notification."""

import hashlib
import json
import re
import sqlite3
import time
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx  # type: ignore[import-not-found]


class PushNotifications:
    def __init__(self, state, conversation, settings, clock=time.time):
        self.state = Path(state)
        self.path = self.state / "notifications.sqlite"
        self.conversation = conversation
        self.settings = settings
        self.clock = clock
        self._jwt = ""
        self._jwt_at = 0
        with self.db() as db:
            db.executescript("""CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,token TEXT,environment TEXT,enabled INTEGER,registered REAL);
              CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY,message_id TEXT,device_id TEXT,state TEXT,attempts INTEGER,next_at REAL,created REAL,reason TEXT);
              CREATE TABLE IF NOT EXISTS approvals(id TEXT PRIMARY KEY,sid TEXT,title TEXT,method TEXT,created REAL,actionable INTEGER DEFAULT 0);
              CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT);
              CREATE TABLE IF NOT EXISTS wechat_pushes(key TEXT PRIMARY KEY,kind TEXT,text TEXT,at REAL,state TEXT,reason TEXT);""")
            columns = {row[1] for row in db.execute("PRAGMA table_info(approvals)")}
            if "actionable" not in columns:
                db.execute("ALTER TABLE approvals ADD COLUMN actionable INTEGER DEFAULT 0")
            if not db.execute("SELECT 1 FROM meta WHERE key='cursor'").fetchone():
                with self.conversation.db() as chat:
                    revision = chat.execute("SELECT COALESCE(MAX(revision),0) FROM messages").fetchone()[0]
                db.execute("INSERT INTO meta VALUES ('cursor',?)", (str(revision),))
        self.path.chmod(0o600)

    @staticmethod
    def _number(value, default=0.0):
        try:
            return float(value)
        except (TypeError, ValueError):
            return default

    @staticmethod
    def _whole(value, default=0):
        try:
            return int(value)
        except (TypeError, ValueError):
            return default

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def config(self):
        try:
            cfg = json.loads((self.state / "apns-config.json").read_text())
        except (OSError, ValueError):
            return None
        if not isinstance(cfg, dict):
            return None
        if any(not isinstance(cfg.get(k), str) or not cfg[k] for k in ("team_id", "key_id", "key_path")):
            return None
        if cfg.get("topic", "work.eddie.com") != "work.eddie.com":
            return None
        if not Path(cfg["key_path"]).expanduser().is_file():
            return None
        return cfg

    def bark(self):
        try:
            cfg = json.loads((self.state / "bark-config.json").read_text())
        except (OSError, ValueError):
            return None
        if not isinstance(cfg, dict):
            return None
        key = cfg.get("device_key")
        if not isinstance(key, str) or not re.fullmatch("[0-9A-Za-z]{8,64}", key):
            return None
        server = str(cfg.get("server") or "https://api.day.app").rstrip("/")
        if not server.startswith("https://"):
            return None
        return {"server": server, "device_key": key, "preview": bool(cfg.get("preview", False))}

    # ---------- 10-25 微信通道 ----------
    # APNs 没有开发者密钥、Bark 也没配：主动提醒其实一直送不到手机。Eddie 每天都在微信里，
    # 所以高优先级的事走 pi-gateway 发给他自己的微信（Poke 住在 iMessage 同一个思路）。
    # 只发三类：要他拍板的审批、刚冒出来的「现在就该做」、结果不确定的操作；每天最多 daily_max 条（审批不占额度），静默时段不发。
    def wechat(self):
        try:
            cfg = json.loads((self.state / "wechat-push.json").read_text())
        except (OSError, ValueError):
            return None
        if not isinstance(cfg, dict) or not cfg.get("enabled"):
            return None
        return {"daily_max": self._whole(cfg.get("daily_max"), 3), "url": str(cfg.get("url") or "http://127.0.0.1:8642/admin/weixin/send")}

    @staticmethod
    def gateway_key():
        try:
            for line in (Path.home() / ".pi-gateway/.env").read_text().splitlines():
                if line.startswith("API_8642_KEY="):
                    return line.split("=", 1)[1].strip().strip("\"'")
        except OSError:
            return ""
        return ""

    def quiet_now(self):
        cfg = self.settings()
        hour = datetime.fromtimestamp(self.clock(), ZoneInfo("Asia/Shanghai")).hour
        start, end = cfg.get("quiet_start", 23), cfg.get("quiet_end", 8)
        return (hour >= start or hour < end) if start > end else start <= hour < end

    async def send_wechat(self, cfg, text):
        async with httpx.AsyncClient(timeout=15, trust_env=False) as client:
            response = await client.post(cfg["url"], json={"text": text}, headers={"Authorization": "Bearer " + self.gateway_key()})
        return response.status_code, "" if response.status_code == 200 else response.text[:120]

    async def push_wechat(self, candidates, sender=None):
        """candidates: [{key, kind: approval|next|effect, text}]。一次最多发一条；同一个 key 只发一次。"""
        cfg = self.wechat()
        if not cfg or self.quiet_now():
            return None
        day = datetime.fromtimestamp(self.clock(), ZoneInfo("Asia/Shanghai")).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        with self.db() as db:
            done = {r[0] for r in db.execute("SELECT key FROM wechat_pushes")}
            used = db.execute("SELECT count(*) FROM wechat_pushes WHERE at>=? AND kind<>'approval' AND state='sent'", (day,)).fetchone()[0]
        pick = next((c for c in candidates if c["key"] not in done and (c["kind"] == "approval" or used < cfg["daily_max"])), None)
        if not pick:
            return None
        try:
            code, reason = await (sender or self.send_wechat)(cfg, pick["text"])
        except Exception as exc:
            code, reason = 0, type(exc).__name__
        with self.db() as db:
            db.execute("INSERT OR REPLACE INTO wechat_pushes VALUES (?,?,?,?,?,?)", (pick["key"], pick["kind"], pick["text"][:500], self.clock(), "sent" if code == 200 else "failed", reason[:120]))
        return pick["key"] if code == 200 else None

    def wechat_log(self, limit=20):
        with self.db() as db:
            return [dict(r) for r in db.execute("SELECT * FROM wechat_pushes ORDER BY at DESC LIMIT ?", (limit,))]

    def status(self):
        with self.db() as db:
            counts = {r[0]: r[1] for r in db.execute("SELECT state,count(*) FROM outbox GROUP BY state")}
            devices = db.execute("SELECT count(*) FROM devices WHERE enabled=1").fetchone()[0]
        delivery = "apns" if self.config() and devices else "bark" if self.bark() else "wechat" if self.wechat() else "background_refresh"
        return {
            "configured": bool(self.config()),
            "bark": bool(self.bark()),
            "wechat": bool(self.wechat()),
            "registered_devices": devices,
            "outbox": counts,
            "delivery": delivery,
            "note": "系统通知受权限、网络和专注模式影响；服务受理不等于已显示。",
        }

    def register(self, data):
        ident = data.get("id")
        token = data.get("token")
        env = data.get("environment", "sandbox")
        if not isinstance(ident, str) or not 8 <= len(ident) <= 100:
            raise ValueError("无效设备标识")
        if not isinstance(token, str) or not re.fullmatch("[0-9a-fA-F]{32,512}", token):
            raise ValueError("无效通知标识")
        if env not in ("sandbox", "production"):
            raise ValueError("无效推送环境")
        with self.db() as db:
            prior = db.execute("SELECT registered FROM devices WHERE id=?", (ident,)).fetchone()
            # Token changes should not leave a second receiver for the same installation.
            db.execute("INSERT OR REPLACE INTO devices VALUES (?,?,?,?,?)", (ident, token.lower(), env, 1, prior[0] if prior else self.clock()))
        return {"status": "completed", **self.status()}

    def disable(self, ident):
        with self.db() as db:
            db.execute("UPDATE devices SET enabled=0 WHERE id=?", (ident,))
            db.execute("UPDATE outbox SET state='cancelled',reason='设备已停用' WHERE device_id=? AND state='queued'", (ident,))
        return {"status": "completed"}

    def enqueue_approvals(self, approvals):
        """把 Agent 正在等的审批变成可操作推送；只保留一句摘要，不把命令正文写进通知库。"""
        items = [a for a in approvals if isinstance(a, dict) and a.get("id") and a.get("sid")]
        if not items:
            return 0
        sent = 0
        with self.db() as db:
            devices = [dict(r) for r in db.execute("SELECT * FROM devices WHERE enabled=1").fetchall()]
            if self.bark():
                since = db.execute("SELECT value FROM meta WHERE key='bark_registered'").fetchone()
                if since:
                    devices.append({"id": "bark", "registered": self._number(since[0])})
            if not devices:
                return 0
            for a in items:
                params = a.get("params") or {}
                # 通知库只存一句通用摘要；命令正文可能含路径/凭据，绝不出现在锁屏。
                reason = str(params.get("reason") or "有一项操作等你决定")
                reason = " ".join(reason.split())[:140]
                decisions = params.get("availableDecisions") or []
                actionable = 1 if "accept" in decisions and "decline" in decisions else 0
                db.execute("INSERT OR IGNORE INTO approvals VALUES (?,?,?,?,?,?)", (str(a["id"]), str(a["sid"]), reason, str(a.get("method") or ""), self.clock(), actionable))
                for device in devices:
                    if self.clock() < device.get("registered", 0):
                        continue
                    ident = str(uuid.uuid5(uuid.NAMESPACE_URL, device["id"] + ":approval:" + str(a["id"])))
                    cur = db.execute("INSERT OR IGNORE INTO outbox VALUES (?,?,?,?,?,?,?,?)", (ident, "approval:" + str(a["id"]), device["id"], "queued", 0, self.clock(), self.clock(), ""))
                    sent += cur.rowcount
            db.execute("DELETE FROM approvals WHERE created<?", (self.clock() - 86400,))
        return sent

    def enqueue(self):
        with self.db() as db:
            row = db.execute("SELECT value FROM meta WHERE key='cursor'").fetchone()
            cursor = self._whole(row[0]) if row else 0
            devices = [dict(r) for r in db.execute("SELECT * FROM devices WHERE enabled=1").fetchall()]
            if self.bark():
                # Bark 没有注册流程：第一次发现配置时记下时间，之前的旧消息不补推。
                since = db.execute("SELECT value FROM meta WHERE key='bark_registered'").fetchone()
                if not since:
                    db.execute("INSERT INTO meta VALUES ('bark_registered',?)", (str(self.clock()),))
                    since = (str(self.clock()),)
                devices.append({"id": "bark", "registered": self._number(since[0])})
            with self.conversation.db() as chat:
                messages = [dict(r) for r in chat.execute("SELECT id,request_id,revision,created_at FROM messages WHERE revision>? AND role='assistant' AND status='completed' ORDER BY revision LIMIT 100", (cursor,))]
            for message in messages:
                for device in devices:
                    if message["created_at"] < device["registered"]:
                        continue
                    # Bark 不知道 App 是否在前台：只推主动消息（简报、提醒、任务回执），不推当面对话的回复。
                    if device["id"] == "bark" and not str(message["request_id"] or "").startswith("task-result:"):
                        continue
                    ident = str(uuid.uuid5(uuid.NAMESPACE_URL, device["id"] + ":" + message["id"]))
                    db.execute("INSERT OR IGNORE INTO outbox VALUES (?,?,?,?,?,?,?,?)", (ident, message["id"], device["id"], "queued", 0, self.clock(), self.clock(), ""))
            if messages:
                db.execute("UPDATE meta SET value=? WHERE key='cursor'", (str(messages[-1]["revision"]),))
        return len(messages)

    def token(self, cfg):
        if self._jwt and self.clock() - self._jwt_at < 3000:
            return self._jwt
        import jwt  # type: ignore[import-not-found]

        self._jwt = jwt.encode({"iss": cfg["team_id"], "iat": self._whole(self.clock())}, Path(cfg["key_path"]).expanduser().read_bytes(), algorithm="ES256", headers={"kid": cfg["key_id"]})
        self._jwt_at = self.clock()
        return self._jwt

    async def send_bark(self, row):
        cfg = self.bark() or {}
        if not cfg:
            return 0, ""
        if str(row["message_id"]).startswith("approval:"):
            key = str(row["message_id"])[len("approval:") :]
            with self.db() as db:
                item = db.execute("SELECT title,sid,actionable FROM approvals WHERE id=?", (key,)).fetchone()
            title = item["title"] if item is not None else "有一步在等你决定"
            sid = item["sid"] if item is not None else ""
            url = "com-eddie://approval?id=" + key + ("&sid=" + str(sid) if sid else "")
            payload = {"device_key": cfg["device_key"], "title": "Com · 需要你决定", "body": title[:120], "group": "com", "url": url, "isArchive": "1"}
            async with httpx.AsyncClient(timeout=20, trust_env=False) as client:
                response = await client.post(cfg["server"] + "/push", json=payload)
            reason = ""
            if response.status_code != 200:
                try:
                    reason = str(response.json().get("message", ""))
                except ValueError:
                    reason = "invalid_response"
            return response.status_code, reason
        body = "已为你整理好，点开查看。"
        if cfg["preview"]:
            with self.conversation.db() as chat:
                found = chat.execute("SELECT text FROM messages WHERE id=?", (row["message_id"],)).fetchone()
            if found and found[0]:
                body = str(found[0]).strip().replace("\n", " ")[:80]
        # 10-17：明天建议点开到下一步页的建议卡，航程回执/等你点开到航程列表；其余照旧回对话
        mid = str(row["message_id"])
        url = "com-eddie://plan" if mid.startswith("task-result:plan:") else "com-eddie://cases" if mid.startswith(("task-result:case-wait:", "task-result:task_")) else "com-eddie://today"
        payload = {"device_key": cfg["device_key"], "title": "Com", "body": body, "group": "com", "url": url, "isArchive": "1"}
        async with httpx.AsyncClient(timeout=20, trust_env=False) as client:
            response = await client.post(cfg["server"] + "/push", json=payload)
        reason = ""
        if response.status_code != 200:
            try:
                reason = str(response.json().get("message", ""))
            except ValueError:
                reason = "invalid_response"
        return response.status_code, reason

    async def send(self, device, row):
        if device.get("id") == "bark":
            return await self.send_bark(row)
        cfg = self.config() or {}
        if not cfg:
            return 0, ""
        host = "api.sandbox.push.apple.com" if device["environment"] == "sandbox" else "api.push.apple.com"
        mid = str(row["message_id"])
        if mid.startswith("approval:"):
            key = mid[len("approval:") :]
            with self.db() as db:
                item = db.execute("SELECT title,sid,actionable FROM approvals WHERE id=?", (key,)).fetchone()
            title = item["title"] if item is not None else "有一步在等你决定"
            sid = item["sid"] if item is not None else ""
            payload = {
                "aps": {
                    "alert": {"title": "Com · 需要你决定", "body": title[:140]},
                    "sound": "default",
                    "thread-id": "com-approval",
                    **({"category": "COM_APPROVAL"} if item is not None and item["actionable"] else {}),
                },
                "comApprovalID": key,
                "comSessionID": sid,
            }
        else:
            payload = {"aps": {"alert": {"title": "Com 有新消息", "body": "已为你整理好，点开查看。"}, "sound": "default", "thread-id": "com-personal"}, "comMessageID": row["message_id"]}
        headers = {
            "authorization": "bearer " + self.token(cfg),
            "apns-topic": "work.eddie.com",
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-id": row["id"],
            "apns-collapse-id": hashlib.sha256(mid.encode()).hexdigest(),
            "apns-expiration": str(self._whole(row["created"] + 86400)),
        }
        async with httpx.AsyncClient(http2=True, timeout=20, trust_env=False) as client:
            response = await client.post("https://" + host + "/3/device/" + device["token"], json=payload, headers=headers)
        reason = ""
        if response.status_code != 200:
            try:
                reason = response.json().get("reason", "")
            except ValueError:
                reason = "invalid_response"
        return response.status_code, reason

    async def process(self, sender=None):
        self.enqueue()
        if not (self.config() or self.bark()) and sender is None:
            return False
        cfg = self.settings()
        hour = datetime.fromtimestamp(self.clock(), ZoneInfo("Asia/Shanghai")).hour
        start, end = cfg.get("quiet_start", 23), cfg.get("quiet_end", 8)
        quiet = (hour >= start or hour < end) if start > end else start <= hour < end
        if quiet:
            return False
        with self.db() as db:
            db.execute("UPDATE outbox SET state='expired',reason='超过24小时' WHERE state='queued' AND created<?", (self.clock() - 86400,))
            row = db.execute("SELECT * FROM outbox WHERE state='queued' AND next_at<=? ORDER BY created LIMIT 1", (self.clock(),)).fetchone()
            if not row:
                return False
            row = dict(row)
            if row["device_id"] == "bark":
                device = {"id": "bark", "token": "", "environment": "bark", "enabled": 1} if self.bark() else None
            else:
                device = db.execute("SELECT * FROM devices WHERE id=? AND enabled=1", (row["device_id"],)).fetchone()
            if not device:
                db.execute("UPDATE outbox SET state='cancelled' WHERE id=?", (row["id"],))
                return True
        try:
            code, reason = await (sender or self.send)(dict(device), row)
        except Exception as exc:
            code, reason = 0, type(exc).__name__
        attempts = row["attempts"] + 1
        state = "accepted" if code == 200 else "failed" if code in (400, 403, 404, 405, 410, 413) or attempts >= 6 else "queued"
        with self.db() as db:
            db.execute("UPDATE outbox SET state=?,attempts=?,next_at=?,reason=? WHERE id=?", (state, attempts, self.clock() + min(3600, 30 * 2**attempts), reason[:120], row["id"]))
            if device["id"] != "bark" and (code == 410 or reason in ("BadDeviceToken", "DeviceTokenNotForTopic")):
                db.execute("UPDATE devices SET enabled=0 WHERE id=?", (device["id"],))
        return True
