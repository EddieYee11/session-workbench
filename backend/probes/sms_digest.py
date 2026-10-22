#!/usr/bin/env python3
"""短信 / iMessage · MBP 采集端（Messages 的 chat.db 只在登了 Apple ID 的 Mac 上有，mini 上被隐私保护挡着）。

读最近 48 小时别人发来的消息（不收自己发的），丢掉验证码一类，组装一份 JSON。
--push-mini 经 SSH 推给 mini 上的 --ingest 落进 personal_hub（同 wechat_digest.py 的两端写法）。
MBP 需要「信息」App 登录 Apple ID、开「iCloud 中的信息」，iPhone 开「短信转发」到这台 Mac，chat.db 才是新的。
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

STATE = Path(os.environ.get("WORKBENCH_STATE", str(Path.home() / ".session-workbench")))
CHAT_DB = Path(os.environ.get("SMS_CHAT_DB", str(Path.home() / "Library/Messages/chat.db")))
APPLE_EPOCH = 978307200
WINDOW = 48 * 3600
SECRET = re.compile(r"验证码|校验码|动态码|动态密码|登录码|verification code|security code|code is|OTP|一次性密码", re.I)


def text_of(text, body):
    """新系统里正文常常只在 attributedBody（typedstream）里：找 NSString 后面那段带长度前缀的 UTF-8。"""
    if text:
        return text
    if not body:
        return ""
    i = body.find(b"NSString")
    if i < 0:
        return ""
    j = body.find(b"+", i)
    if j < 0 or j + 1 >= len(body):
        return ""
    n, k = body[j + 1], j + 2
    if n == 0x81:
        n, k = int.from_bytes(body[k:k + 2], "little"), k + 2
    elif n == 0x82:
        n, k = int.from_bytes(body[k:k + 4], "little"), k + 4
    return body[k:k + n].decode("utf-8", "ignore")


def collect(now=None):
    now = now or time.time()
    with tempfile.TemporaryDirectory() as tmp:
        # 复制一份再读：不锁住「信息」App 正在写的库（连同 -wal，否则读不到最新几条）
        for suffix in ("", "-wal", "-shm"):
            src = Path(str(CHAT_DB) + suffix)
            if src.exists():
                shutil.copy2(src, Path(tmp) / ("chat.db" + suffix))
        db = sqlite3.connect(Path(tmp) / "chat.db")
        latest = db.execute("SELECT max(date) FROM message").fetchone()[0] or 0
        rows = db.execute(
            "SELECT m.guid, m.text, m.attributedBody, m.date, m.service, coalesce(h.id, '') FROM message m "
            "LEFT JOIN handle h ON m.handle_id = h.ROWID WHERE m.is_from_me = 0 AND m.date > ? ORDER BY m.date",
            (int((now - WINDOW - APPLE_EPOCH) * 1e9),)).fetchall()
        db.close()
    messages, skipped = [], 0
    for guid, text, body, date, service, handle in rows:
        content = text_of(text, body).replace("￼", "").strip()
        if not content:
            continue
        if SECRET.search(content):
            skipped += 1
            continue
        messages.append({"id": guid, "from": handle, "text": content[:500], "at": date / 1e9 + APPLE_EPOCH, "service": service})
    return {"generated_at": now, "window_start": now - WINDOW, "messages": messages[-60:], "skipped_codes": skipped,
            "latest_in_db": latest / 1e9 + APPLE_EPOCH if latest else 0}


def push_mini(payload):
    remote = ('cd "$HOME/AI_Work_System/work/工具与效率/会话工作台" && '
              '"$HOME/.session-workbench/venv/bin/python" backend/probes/sms_digest.py --ingest')
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "mini", remote],
                            input=json.dumps(payload, ensure_ascii=False), text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise SystemExit(f"短信摘要发送失败，下次重试: {result.stderr.strip()[:300]}")
    return result.stdout.strip()


def ingest(payload):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from personal_hub import PersonalHub, SOURCES
    hub = PersonalHub(STATE, Path.home())
    count = len(payload.get("messages") or [])
    hub.matter("sms", "latest", f"短信 · 最近 48 小时 {count} 条", payload, source_updated_at=payload.get("generated_at") or time.time(), deadline=None)
    stale = time.time() - float(payload.get("latest_in_db") or 0) > 7 * 86400
    with hub.db() as db:
        row = db.execute("SELECT data FROM sources WHERE name='sms'").fetchone()
        previous = json.loads(row[0]) if row else {}
        db.execute("INSERT OR REPLACE INTO sources VALUES (?,?)", ("sms", json.dumps({
            **previous, "name": "sms", "status": "connected", "interval_seconds": SOURCES["sms"], "attempted_at": time.time(),
            "updated_at": time.time(), "count": count, "enabled": previous.get("enabled", True),
            "coverage": "MBP 信息 App · 最近 48 小时" + ("（MBP 上的信息库超过 7 天没有新消息：检查 iCloud 信息 / 短信转发）" if stale else ""),
            "error": "", "error_type": None}, ensure_ascii=False)))
    return json.dumps({"status": "ok", "messages": count, "stale_db": stale}, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ingest", action="store_true", help="mini 端：从 stdin 读摘要写进 personal_hub")
    parser.add_argument("--push-mini", action="store_true", help="MBP 端：采集后经 SSH 推给 mini")
    parser.add_argument("--window-hours", type=float, help="调试用：放宽窗口")
    args = parser.parse_args()
    if args.ingest:
        print(ingest(json.load(sys.stdin)))
        return
    global WINDOW
    if args.window_hours:
        WINDOW = args.window_hours * 3600
    payload = collect()
    print(push_mini(payload) if args.push_mini else json.dumps(payload, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
