#!/usr/bin/env python3
"""Plaud 录音纪要 · MBP 采集端（Plaud 的登录在 MBP 的 ~/.plaud，经官方 MCP @plaud-ai/mcp 取数）。

最近 7 天的录音：每条新录音取一次 AI 纪要，只留「行动项目」那一节（谁、做什么、截止），
--push-mini 经 SSH 推给 mini 的 --ingest 落进 personal_hub，「下一步」从里面挑他自己要做的。
纪要还没生成好的录音下次再取，最多试 6 次。纪要是录音转写出来的资料，到了模型那里也只当资料。
"""
import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

STATE = Path(os.environ.get("WORKBENCH_STATE", str(Path.home() / ".session-workbench")))
SEEN = STATE / "plaud-seen.json"
DAYS = 7
MIN_SECONDS = 60  # 几秒钟的误触录音不看


def unwrap(result):
    """MCP 返回的文字里，数据包在一层「不可信数据」标签里：取标签中间那段 JSON。"""
    text = "".join(getattr(c, "text", "") for c in result.content)
    start = min([i for i in (text.find("{"), text.find("[")) if i >= 0], default=-1)
    end = max(text.rfind("}"), text.rfind("]"))
    return json.loads(text[start:end + 1]) if start >= 0 and end > start else None


def actions(note_text):
    """纪要里「行动项目」到下一个二级标题为止；没有这一节就退回「做出的决策」。"""
    for heading in ("## 行动项目", "## Action Items", "## 做出的决策"):
        i = note_text.find(heading)
        if i >= 0:
            j = note_text.find("\n## ", i + len(heading))
            return note_text[i:j if j > 0 else None].strip()[:4000]
    return ""


async def collect():
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
    seen = json.loads(SEEN.read_text()) if SEEN.exists() else {}
    today = datetime.now().date()
    params = StdioServerParameters(command="npx", args=["-y", "@plaud-ai/mcp@latest"],
                                   env={**os.environ, "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"})
    out = []
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listing = unwrap(await session.call_tool("list_files", {"date_from": str(today - timedelta(days=DAYS)), "date_to": str(today), "page_size": 50})) or {}
            for f in listing.get("data") or []:
                state = seen.get(f["id"], {})
                if state.get("done") or state.get("tries", 0) >= 6 or (f.get("duration") or 0) < MIN_SECONDS * 1000:
                    continue
                notes = unwrap(await session.call_tool("get_note", {"file_id": f["id"]})) or []
                summary = next((n.get("data_content") or "" for n in notes if n.get("data_type") == "auto_sum_note"), "")
                if not summary:
                    seen[f["id"]] = {"tries": state.get("tries", 0) + 1}
                    continue
                out.append({"id": f["id"], "name": f.get("name") or "录音", "start_at": f.get("start_at"), "duration": f.get("duration"),
                            "actions": actions(summary)})
                seen[f["id"]] = {"done": True}
    return {"generated_at": time.time(), "recordings": out}, seen


def push_mini(payload):
    remote = ('cd "$HOME/AI_Work_System/work/工具与效率/会话工作台" && '
              '"$HOME/.session-workbench/venv/bin/python" backend/probes/plaud_digest.py --ingest')
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "mini", remote],
                            input=json.dumps(payload, ensure_ascii=False), text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise SystemExit(f"录音纪要发送失败，下次重试: {result.stderr.strip()[:300]}")
    return result.stdout.strip()


def ingest(payload):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from personal_hub import PersonalHub, SOURCES
    hub = PersonalHub(STATE, Path.home())
    for r in payload.get("recordings") or []:
        try:
            at = datetime.fromisoformat(str(r.get("start_at")).replace("Z", "+00:00")).timestamp()
        except ValueError:
            at = payload.get("generated_at") or time.time()
        hub.matter("plaud", r["id"], r["name"], {"start_at": r.get("start_at"), "duration": r.get("duration"), "actions": r.get("actions", "")},
                   source_updated_at=at, deadline=None)
    with hub.db() as db:
        row = db.execute("SELECT data FROM sources WHERE name='plaud'").fetchone()
        previous = json.loads(row[0]) if row else {}
        total = db.execute("SELECT count(*) FROM matters WHERE source='plaud'").fetchone()[0]
        db.execute("INSERT OR REPLACE INTO sources VALUES (?,?)", ("plaud", json.dumps({
            **previous, "name": "plaud", "status": "connected", "interval_seconds": SOURCES["plaud"], "attempted_at": time.time(),
            "updated_at": time.time(), "count": total, "enabled": previous.get("enabled", True),
            "coverage": f"Plaud 录音纪要 · 最近 {DAYS} 天的行动项", "error": "", "error_type": None}, ensure_ascii=False)))
        # 只留最近 30 天
        for ident, data in db.execute("SELECT id, data FROM matters WHERE source='plaud'").fetchall():
            if time.time() - float(json.loads(data).get("source_updated_at") or 0) > 30 * 86400:
                db.execute("DELETE FROM matters WHERE id=?", (ident,))
    return json.dumps({"status": "ok", "new": len(payload.get("recordings") or []), "total": total}, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ingest", action="store_true", help="mini 端：从 stdin 读纪要写进 personal_hub")
    parser.add_argument("--push-mini", action="store_true", help="MBP 端：采集后经 SSH 推给 mini")
    args = parser.parse_args()
    if args.ingest:
        print(ingest(json.load(sys.stdin)))
        return
    payload, seen = asyncio.run(collect())
    if args.push_mini:
        print(push_mini(payload))  # 推成功了才记「已取过」，推失败下次整批重来
    else:
        print(json.dumps({"recordings": [{**r, "actions": r["actions"][:200]} for r in payload["recordings"]]}, ensure_ascii=False, indent=2))
        return
    SEEN.parent.mkdir(parents=True, exist_ok=True)
    SEEN.write_text(json.dumps(seen))


if __name__ == "__main__":
    main()
