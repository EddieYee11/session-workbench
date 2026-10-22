#!/usr/bin/env python3
"""微信每小时汇总 · MBP 采集端（微信与解密库只在这台机器上）。

读窗口内的会话与消息，按「私聊全收 + 群里 @我 + 关键词命中」筛选，组装一份摘要 JSON。
--push-mini 走既有 SSH 通道（同 export_project_board.py）推给 mini 上的 --ingest 落进 personal_hub。

设计对齐 backend/probes/export_project_board.py：同一份脚本两端各跑一个分支——
MBP 用 ~/wechat-decrypt/venv/bin/python 采集，mini 用 ~/.session-workbench/venv/bin/python 入库。
"""
import argparse
import contextlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

WECHAT_DIR = Path(os.environ.get("WECHAT_DECRYPT_DIR", str(Path.home() / "wechat-decrypt")))
STATE = Path(os.environ.get("WORKBENCH_STATE", str(Path.home() / ".session-workbench")))
CONFIG_PATH = Path(os.environ.get("WECHAT_DIGEST_CONFIG", str(STATE / "wechat-digest.json")))

DEFAULT_CONFIG = {
    "window_minutes": 75,
    "max_chats": 20,
    "max_fetch": 40,
    "max_messages": 40,
    "self_aliases": ["高杰", "野望", "野哥"],
    # 命中即收：越具体越好，泛词会让每个游戏群/社区群都进来
    "keywords": ["岩馆", "搜狐", "视频号", "选题", "物料", "排期", "合同", "报销",
                 "攀岩", "直播", "剪辑", "拍摄", "推广", "上线"],
    # 只在 priority_chats 里当待办信号：这类泛词命中任何群都会变成噪音
    "action_words": ["待确认", "待反馈", "跟进", "确认一下", "截止", "尽快", "点前", "号前",
                     "你来", "麻烦你", "需要你"],
    "priority_chats": [
        "汽车营销策略&生活方式中心大群", "汽车内容上线推广", "欢迎光临",
        "sohu生活方式中心", "2026春关-内容账号",
    ],
    "redact": False,
    # 焦点项目：命中项目词的聊天（以及专属群）不再按「一小时里最后一句」打发，整段对话都交给下一步归纳。
    # chats 是专属群/人（整个会话都算项目）；keywords 在混合群里命中才算（小写比较）。
    "project_max_messages": 60,
    "ignore_chats": ["微信ClawBot"],  # 自己的机器人会话，转述的是别处的内容
    "projects": [{
        "name": "大有可攀·攀岩生活节", "venue": "北顶奥森", "date": "2026-10-25",
        "keywords": ["大有可攀", "北顶", "奥森", "秦max", "比亚迪", "生活节", "选手招募", "攀岩赛"],
        "chats": ["（内部）「大有可攀」攀岩生活节", "【汽车频道】比亚迪秦max攀岩活动沟通",
                  "搜狐户外-攀岩活动物料设计", "北顶 小倩"],
    }],
}

# 公众号 / 服务号 / 系统会话：不是人，不进私聊汇总
NON_HUMAN_PREFIX = ("gh_",)
NON_HUMAN = {"filehelper", "newsapp", "weixin", "floatbottle", "medianote", "fmessage", "qqmail"}
NON_HUMAN_SUFFIX = ("@openim",)

# redact 打开时丢弃的消息（默认关，按 Eddie 的口径不做内容过滤）
SECRET = re.compile(r"验证码|校验码|动态码|一次性密码|verification code|one.time code|\botp\b", re.I)
PLACEHOLDER = re.compile(r"当前微信版本不支持展示该内容")
MENTION_SEP = " "  # 微信 4.0 提及后跟的四分之一空格
MENTION_ALL = ("@所有人", "@All", "@all")


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.is_file():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text("utf-8")))
        except (ValueError, OSError):
            pass
    return cfg


def load_mcp():
    # mcp_server 会往 stdout 打 [DBCache] 一类的日志，JSON 走 stdout，必须先把它顶到 stderr。
    with contextlib.redirect_stdout(sys.stderr):
        sys.path.insert(0, str(WECHAT_DIR))
        import mcp_server  # noqa: E402
    return mcp_server


def load_names(mcp):
    """群名/昵称映射。

    不用 mcp_server.get_contact_names()：它优先读 decrypted/contact/contact.db 这个落盘副本，
    那份是 2026-07-28 的，比实时解密库少 30 多个群（新群名会退化成 `xxxxx@chatroom`）。
    """
    path = mcp._cache.get(os.path.join("contact", "contact.db"))
    if path:
        try:
            names, _ = mcp._load_contacts_from(path)
            if names:
                return names
        except Exception:
            pass
    return mcp.get_contact_names()


def is_human(username):
    return not (username.startswith(NON_HUMAN_PREFIX)
                or username in NON_HUMAN
                or username.endswith(NON_HUMAN_SUFFIX))


# ---------- 会话筛选 ----------

def active_sessions(mcp, cutoff):
    """窗口内有动静的会话。session.db 只有 2MB，解密快。"""
    path = mcp._cache.get(os.path.join("session", "session.db"))
    if not path:
        raise RuntimeError("无法解密 session.db；确认微信在运行且 all_keys.json 里有 key")
    conn = sqlite3.connect(path)
    try:
        rows = conn.execute("""
            SELECT username, unread_count, summary, last_timestamp, last_msg_type,
                   last_msg_sender, last_sender_display_name
            FROM SessionTable WHERE last_timestamp > ? ORDER BY last_timestamp DESC
        """, (int(cutoff),)).fetchall()
    finally:
        conn.close()
    out = []
    for username, unread, summary, ts, msg_type, sender, sender_name in rows:
        if isinstance(summary, bytes):
            try:
                summary = mcp._zstd_dctx.decompress(summary).decode("utf-8", errors="replace")
            except Exception:
                summary = ""
        if isinstance(summary, str) and ":\n" in summary:
            summary = summary.split(":\n", 1)[1]
        out.append({"username": username, "unread": unread or 0, "summary": str(summary or ""),
                    "at": int(ts or 0), "msg_type": msg_type, "sender_id": sender,
                    "sender_name": sender_name or ""})
    return out


def chat_messages(mcp, username, names, self_user, limit):
    """某个会话最近 limit 条消息，结构化返回（跨分库合并，与 MCP 的 get_chat_history 同口径）。"""
    is_group = "@chatroom" in username
    tables = mcp._find_msg_tables_for_user(username)
    if not tables:
        return []
    rows, name2id_by_db = [], {}
    for db_path, table in tables:
        conn = sqlite3.connect(db_path)
        try:
            part = conn.execute(f"""
                SELECT local_id, local_type, create_time, real_sender_id, message_content,
                       WCDB_CT_message_content
                FROM [{table}] ORDER BY create_time DESC LIMIT ?
            """, (limit,)).fetchall()
        except Exception:
            part = []
        finally:
            conn.close()
        if part:
            name2id_by_db[db_path] = mcp._load_name2id_map(db_path)
            rows.extend((r, db_path) for r in part)
    if not rows:
        return []
    rows.sort(key=lambda item: item[0][2], reverse=True)
    rows = rows[:limit]

    out = []
    for (local_id, local_type, create_time, real_sender_id, content, ct), src_db in rows:
        content = mcp._decompress_content(content, ct)
        if content is None:
            continue
        sender_from_content, text = mcp._parse_message_content(content, local_type, is_group)
        sender_username = name2id_by_db.get(src_db, {}).get(real_sender_id, "")
        if is_group:
            if sender_username and sender_username != username:
                sender_name = names.get(sender_username, sender_username)
            elif sender_from_content:
                sender_name = names.get(sender_from_content, sender_from_content)
            else:
                sender_name = ""
        else:
            if sender_username == username or sender_from_content == username:
                sender_name = names.get(username, username)
            elif sender_username == self_user:
                sender_name = "我"
            else:
                sender_name = names.get(sender_username, sender_username) if sender_username else "我"

        base = mcp.base_msg_type(local_type)
        if base == 3:
            text = "[图片]"
        elif base == 47:
            text = "[表情]"
        elif base != 1:
            label = mcp.format_msg_type(local_type)
            summary = mcp._xml_summary(text)
            text = f"[{label}] {summary}" if summary else f"[{label}]"
        if text and len(text) > 300:
            text = text[:300] + "…"
        out.append({"sender": sender_name or "", "at": int(create_time or 0), "text": text,
                    "local_id": int(local_id or 0), "is_text": base == 1})
    out.reverse()
    return out


def searchable(message):
    """能不能拿来做关键词/@ 匹配。

    非文本消息只留了 `[视频号]`、`[图片]` 这样的类型标签，拿它匹配会命中「视频号」这类
    词根，把社区群、亲友群全拉进来。有真实摘要的（链接标题、引用正文）才参与匹配。
    """
    text = message.get("text") or ""
    if not text or PLACEHOLDER.search(text):
        return False
    return bool(message.get("is_text")) or len(text) > 8


def mentions_me(text, aliases):
    if not text:
        return False
    if any(a in text for a in MENTION_ALL):
        return True
    for alias in aliases:
        if not alias:
            continue
        for m in re.finditer(re.escape("@" + alias), text):
            tail = text[m.end():m.end() + 1]
            # 微信 4.0 的 @ 后面跟四分之一空格；没有分隔符时要求后面不是字母数字
            if tail == MENTION_SEP or tail == "" or not tail.isalnum():
                return True
    return False


def keyword_hits(text, keywords):
    return [k for k in keywords if k and k in text]


def project_of(display, scannable, projects):
    """这个聊天属于哪个焦点项目：专属群整体算，混合群里有项目词才算。返回 (项目名, 命中词)。"""
    for project in projects:
        low = [k.lower() for k in project.get("keywords") or []]
        hits = sorted({k for m in scannable for k in low if k in m["text"].lower()})
        if display in (project.get("chats") or []) or hits:
            return project["name"], hits[:6]
    return "", []


# ---------- 采集 ----------

def collect(cfg, verbose=False):
    mcp = load_mcp()
    names = load_names(mcp)
    self_user = mcp.get_self_username()
    aliases = list(cfg["self_aliases"])
    self_name = names.get(self_user, "")
    if self_name and self_name not in aliases:
        aliases.append(self_name)

    now = int(time.time())
    cutoff = now - cfg["window_minutes"] * 60
    sessions = active_sessions(mcp, cutoff)

    private = [s for s in sessions if "@chatroom" not in s["username"] and is_human(s["username"])]
    groups = [s for s in sessions if "@chatroom" in s["username"]]
    # 私聊优先，其次白名单群，再按活跃时间
    priority = {n for n in cfg["priority_chats"]}
    groups.sort(key=lambda s: (names.get(s["username"], "") not in priority, -s["at"]))
    ordered = private + groups
    # 焦点项目的专属群/人先取，别被 max_fetch 挤掉
    dedicated = {c for p in cfg.get("projects") or [] for c in p.get("chats") or []}
    ordered.sort(key=lambda s: names.get(s["username"], "") not in dedicated)
    fetched = ordered[: cfg["max_fetch"]]
    skipped = len(ordered) - len(fetched)

    chats, counts = [], {"private": 0, "group": 0, "mentions": 0, "keyword": 0,
                         "scanned": len(sessions), "fetched": len(fetched), "skipped": skipped}
    for s in fetched:
        username = s["username"]
        is_group = "@chatroom" in username
        display = names.get(username, username)
        if display in (cfg.get("ignore_chats") or []):
            continue
        msgs = [m for m in chat_messages(mcp, username, names, self_user, cfg["max_messages"] * 2)
                if m["at"] >= cutoff]
        if not msgs:
            continue
        if cfg.get("redact"):
            msgs = [m for m in msgs if not SECRET.search(m["text"])]
            if not msgs:
                continue
        scannable = [m for m in msgs if searchable(m)]
        mentions = [m for m in scannable if mentions_me(m["text"], aliases)]
        hits = sorted({k for m in scannable for k in keyword_hits(m["text"], cfg["keywords"])})
        is_priority = display in priority
        # 待办泛词只认白名单群，否则「今天/尽快」会让每个群都进来
        actions = sorted({k for m in scannable for k in keyword_hits(m["text"], cfg.get("action_words") or [])}) if is_priority else []

        project, project_hits = project_of(display, scannable, cfg.get("projects") or [])
        if is_group and not (mentions or hits or is_priority or project):
            continue  # 群聊只留 @我 / 关键词命中 / 白名单 / 焦点项目

        limit = cfg.get("project_max_messages", cfg["max_messages"]) if project else cfg["max_messages"]
        keep = msgs[-limit:]
        if len(msgs) > limit:
            # 截断时把 @我 的消息捞回来，别把要紧的丢掉
            seen = {m["local_id"] for m in keep}
            keep = [m for m in msgs if m["local_id"] in seen or m in mentions]

        counts["private" if not is_group else "group"] += 1
        if mentions:
            counts["mentions"] += 1
        if hits:
            counts["keyword"] += 1
        # 摘要取「最该被看到的那条」而不是最后一条：群里最后一句常是表情或图片，
        # 拿它当摘要等于什么都没说。@我的优先，其次最近一句真话。
        head = (mentions or [None])[-1] or next((m for m in reversed(scannable) if m["is_text"]), None) or (keep or [None])[-1]
        chats.append({
            "name": display, "username": username, "is_group": is_group, "unread": s["unread"],
            "mention": bool(mentions), "keyword": bool(hits), "priority": is_priority,
            "keywords": hits[:6], "actions": actions[:6],
            "project": project, "project_hits": project_hits,
            "anchor": str(keep[-1]["local_id"]) if keep else "",
            "sender": head["sender"] if head else "", "summary": head["text"] if head else "",
            "messages": keep,
        })

    chats.sort(key=lambda c: (not c["project"], not c["mention"], not c["priority"], not c["keyword"], -len(c["messages"])))
    chats = chats[: cfg["max_chats"]]
    payload = {"window_start": cutoff, "window_end": now, "generated_at": now,
               "aliases": aliases, "counts": counts, "chats": chats,
               "projects": [{k: p.get(k, "") for k in ("name", "venue", "date")} for p in cfg.get("projects") or []]}
    if verbose:
        print(f"[wechat-digest] 窗口 {(now - cutoff) // 60} 分钟；活跃会话 {len(sessions)}"
              f"（私聊 {len(private)} / 群 {len(groups)}），取 {len(fetched)} 个"
              + (f"，另有 {skipped} 个未取" if skipped else ""), file=sys.stderr)
        for c in chats:
            tag = "项目" if c["project"] else "私聊" if not c["is_group"] else ("@我" if c["mention"] else "关键词" if c["keyword"] else "白名单")
            print(f"  [{tag}] {c['name']} · {len(c['messages'])} 条 · 未读 {c['unread']}", file=sys.stderr)
    return payload


# ---------- 推送 / 入库 ----------

def push_mini(payload):
    remote = (
        'cd "$HOME/AI_Work_System/work/工具与效率/会话工作台" && '
        '"$HOME/.session-workbench/venv/bin/python" backend/probes/wechat_digest.py --ingest'
    )
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "mini", remote],
        input=json.dumps(payload, ensure_ascii=False), text=True, capture_output=True, timeout=180)
    if result.returncode:
        raise SystemExit(f"微信摘要发送失败，下次重试: {result.stderr.strip()[:300]}")
    return result.stdout.strip()


def ingest(payload):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from personal_hub import PersonalHub, SOURCES
    hub = PersonalHub(STATE, Path.home())
    window_end = int(payload.get("window_end") or time.time())
    hour = datetime.fromtimestamp(window_end).replace(minute=0, second=0, microsecond=0)
    title = f"微信 · {hour:%H}:00–{(hour + timedelta(hours=1)):%H}:00"
    source_id = f"hour:{int(hour.timestamp())}"
    hub.matter("wechat", source_id, title, payload, source_updated_at=window_end, deadline=None)

    # 这次推送就是微信这一路的「同步」：顺手把连接器状态写掉，
    # 否则连接器页要等人在 App 里点过「检查连接」才不是「未检查」。
    chats = len(payload.get("chats") or [])
    with hub.db() as db:
        row = db.execute("SELECT data FROM sources WHERE name='wechat'").fetchone()
        previous = json.loads(row[0]) if row else {}
        db.execute("INSERT OR REPLACE INTO sources VALUES (?,?)", ("wechat", json.dumps({
            **previous, "name": "wechat", "status": "connected", "interval_seconds": SOURCES["wechat"],
            "attempted_at": window_end, "updated_at": time.time(), "count": chats, "enabled": previous.get("enabled", True),
            "coverage": f"{title}；保留最近 48 小时", "error": "", "error_type": None}, ensure_ascii=False)))

    # 48 小时前的旧摘要没有再看的价值，清掉（只清自己的来源）
    pruned = 0
    with hub.db() as db:
        stale = db.execute(
            "SELECT id, data FROM matters WHERE source='wechat'").fetchall()
        for ident, data in stale:
            try:
                row = json.loads(data)
            except ValueError:
                continue
            if window_end - float(row.get("source_updated_at") or 0) > 48 * 3600:
                db.execute("DELETE FROM matters WHERE id=?", (ident,))
                pruned += 1
    return json.dumps({"status": "ok", "title": title, "chats": chats, "pruned": pruned}, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ingest", action="store_true", help="mini 端：从 stdin 读摘要写进 personal_hub")
    parser.add_argument("--push-mini", action="store_true", help="MBP 端：采集后经 SSH 推给 mini")
    parser.add_argument("--dry-run", action="store_true", help="只打印摘要，不推送")
    parser.add_argument("--window-minutes", type=int)
    parser.add_argument("--max-chats", type=int)
    parser.add_argument("--write-config", action="store_true", help="把默认配置写到 ~/.session-workbench/wechat-digest.json")
    args = parser.parse_args()

    if args.ingest:
        print(ingest(json.load(sys.stdin)))
        return
    if args.write_config:
        if CONFIG_PATH.exists():
            raise SystemExit(f"配置已存在，未覆盖：{CONFIG_PATH}")
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(json.dumps(DEFAULT_CONFIG, ensure_ascii=False, indent=2), "utf-8")
        print(f"已写入 {CONFIG_PATH}")
        return

    cfg = load_config()
    if args.window_minutes:
        cfg["window_minutes"] = args.window_minutes
    if args.max_chats:
        cfg["max_chats"] = args.max_chats
    # JSON 走 stdout，MCP 的日志必须顶到 stderr，否则推给 mini 的内容会被污染
    with contextlib.redirect_stdout(sys.stderr):
        payload = collect(cfg, verbose=not args.dry_run or sys.stderr.isatty())
    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    elif args.push_mini:
        print(push_mini(payload))
    else:
        print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()
