from __future__ import annotations

import asyncio
import json
import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import channels
import context_builder
from channels import (
    CHANNEL_IDS,
    DEFAULT_CHANNEL,
    channels_enabled,
    get_channel_spec,
    is_valid_channel,
    normalize_channel,
    validate_channel,
)
from context_working_set import HISTORY_BYTES, HISTORY_ROWS, MARKER, history, read_history
from conversation import PersonalConversation
from hermes_prompt import SYSTEM_PROMPT


class FakeStreamClient:
    runtime_name = "hermes"

    def __init__(self, reply_prefix: str = "回复：") -> None:
        self.reply_prefix = reply_prefix
        self.seen_inputs: list[str] = []

    def key(self) -> str:
        return "fixture-key"

    async def create_session(self) -> str:
        return "com-personal-main"

    async def restore_request(self, _request_id: str):
        return None

    async def stream_chat(self, _session_id: str, text: str):
        self.seen_inputs.append(text)
        header = text[len(MARKER) :].partition("\n")[0] if text.startswith(MARKER) else "{}"
        ctx = json.loads(header)
        req_id = ctx.get("origin_request_id", "")
        yield "run.started", {"run_id": "run-" + req_id}
        yield "input.delivered", {"request_id": req_id, "run_id": "run-" + req_id}
        yield "assistant.delta", {"delta": self.reply_prefix}
        yield "assistant.completed", {"content": f"{self.reply_prefix}[ch={ctx.get('channel')}]"}
        yield "run.completed", {}
        yield "done", {}


def test_channel_specs_and_validation(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    assert CHANNEL_IDS == ("personal", "work", "bookkeeping")
    assert normalize_channel(None) == DEFAULT_CHANNEL
    assert normalize_channel("") == "personal"
    assert normalize_channel(" WORK ") == "work"
    assert normalize_channel("unknown-chan") == "personal"
    assert is_valid_channel("bookkeeping") is True
    assert is_valid_channel("invalid") is False
    assert validate_channel("Work") == "work"
    with pytest.raises(ValueError):
        validate_channel("entertainment")

    assert get_channel_spec("personal").history_rows == 12
    assert get_channel_spec("work").history_rows == 14
    assert get_channel_spec("bookkeeping").history_rows == 10

    monkeypatch.delenv("COM_CHANNELS_MODE", raising=False)
    assert channels_enabled(tmp_path) is False
    (tmp_path / "superagent-flags.json").write_text(json.dumps({"channels": "on"}), encoding="utf-8")
    assert channels_enabled(tmp_path) is True
    monkeypatch.setenv("COM_CHANNELS_MODE", "off")
    assert channels_enabled(tmp_path) is False
    monkeypatch.setenv("COM_CHANNELS_MODE", "on")
    assert channels_enabled(tmp_path) is True


def test_legacy_sqlite_migration_preserves_message_seq(tmp_path: Path) -> None:
    db_path = tmp_path / "personal-conversation.sqlite"
    conn = sqlite3.connect(db_path)
    try:
        conn.executescript(
            """
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE messages(
                id TEXT PRIMARY KEY, request_id TEXT UNIQUE, parent_id TEXT,
                role TEXT NOT NULL, text TEXT NOT NULL, status TEXT NOT NULL,
                created_at REAL NOT NULL, updated_at REAL NOT NULL,
                run_id TEXT, error TEXT, message_seq INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO messages(id, request_id, role, text, status, created_at, updated_at, message_seq)
            VALUES ('legacy-u1', 'req-legacy-001', 'user', '旧消息1', 'completed', 10.0, 10.0, 0),
                   ('legacy-a1', 'req-legacy-002', 'assistant', '旧回复1', 'completed', 11.0, 11.0, 0);
            """
        )
        conn.commit()
    finally:
        conn.close()

    convo = PersonalConversation(tmp_path)
    snap = convo.snapshot()
    assert snap["active_channel"] == "personal"
    assert [m["id"] for m in snap["messages"]] == ["legacy-u1", "legacy-a1"]
    assert [m["message_seq"] for m in snap["messages"]] == [1, 2]
    assert [m["channel"] for m in snap["messages"]] == ["personal", "personal"]

    with convo.db() as db:
        indexes = {r["name"] for r in db.execute("PRAGMA index_list(messages)").fetchall()}
        assert "idx_messages_channel_seq" in indexes


def test_flag_off_keeps_legacy_behavior_100_percent(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("COM_CHANNELS_MODE", raising=False)
    convo = PersonalConversation(tmp_path, client=FakeStreamClient())

    # Even if active_channel is set or channel="work" is passed, flag=off writes 'personal' and legacy keys
    convo.set_active_channel("work")
    res = convo.submit("req-off-channel-0001", "关闭开关时的测试消息", channel="work")
    assert set(res.keys()) == {"status", "request_id", "message_id", "message_seq", "created_at"}
    asyncio.run(convo.process_one())

    snap_all = convo.snapshot()
    snap_work = convo.snapshot(channel="work")
    assert len(snap_all["messages"]) == 2
    assert len(snap_work["messages"]) == 2
    assert all(m["channel"] == "personal" for m in snap_all["messages"])

    # Seed 12 completed messages manually across channels: flag=off still uses HISTORY_ROWS=8 unfiltered
    with convo.db() as db:
        for idx in range(12):
            ch = "work" if idx % 2 == 0 else "bookkeeping"
            db.execute(
                "INSERT INTO messages(id,request_id,role,text,status,created_at,updated_at,message_seq,channel)"
                " VALUES(?,?,?,?,?,?,?,?,?)",
                (f"m{idx}", f"r-hist-off-{idx:03d}", "user", f"条目{idx}", "completed", 100 + idx, 100 + idx, 10 + idx, ch),
            )

    turns = history(tmp_path, "")
    assert len(turns) == 1 + HISTORY_ROWS
    assert HISTORY_ROWS == 8 and HISTORY_BYTES == 14000

    ws = context_builder.build(
        tmp_path,
        MARKER + json.dumps({"origin_request_id": "r-hist-off-011", "channel": "work"}) + "\n用户消息：\n看下进展",
    )
    assert "【当前频道：" not in ws.instructions
    assert '"channel"' not in ws.instructions
    assert ws.sizes["system_chars"] == len(SYSTEM_PROMPT)


def test_flag_on_isolates_channels_and_inherits_assistant_bubbles_and_receipts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("COM_CHANNELS_MODE", "on")
    client = FakeStreamClient()
    convo = PersonalConversation(tmp_path, client=client)

    assert convo.get_active_channel() == "personal"
    assert convo.set_active_channel("work") == "work"
    assert convo.get_active_channel() == "work"

    # 1. Submit without explicit channel -> uses active_channel ('work')
    sub_work = convo.submit("req-on-work-0001", "推进全国岩馆路书排期")
    assert sub_work["channel"] == "work"
    asyncio.run(convo.process_one())

    # 2. Submit with explicit channel='bookkeeping' -> overrides active_channel for this turn
    sub_bk = convo.submit("req-on-bk-000002", "对一下这个月订阅预算怎么规划", channel="bookkeeping")
    assert sub_bk["channel"] == "bookkeeping"
    # Conflicting channel on idempotent retry is rejected
    with pytest.raises(ValueError):
        convo.submit("req-on-bk-000002", "对一下这个月订阅预算怎么规划", channel="work")
    assert convo.submit("req-on-bk-000002", "对一下这个月订阅预算怎么规划", channel="bookkeeping")["channel"] == "bookkeeping"
    asyncio.run(convo.process_one())

    # 3. SendMessage independent bubble inherits parent user message's channel
    monkeypatch.setenv("COM_SEND_MESSAGE_MODE", "on")
    sub_sm = convo.submit("req-on-sm-work-03", "发一张工作进度气泡", channel="work")
    sm_mid = sub_sm["message_id"]
    convo.send_store.open_turn(sm_mid, "com-personal-main", "req-on-sm-work-03")
    bubble_res = convo.emit_bubble(
        sm_mid,
        {"type": "text", "content": "这是工作频道里的独立气泡", "blocking": False},
        session_id="com-personal-main",
        request_id="req-on-sm-work-03",
    )
    convo._finish_send_message_turn(sm_mid, "completed")
    monkeypatch.delenv("COM_SEND_MESSAGE_MODE", raising=False)

    # 4. Outbox task_receipt inherits parent's channel (and explicit channel when no parent)
    rk_work = convo.task_receipt("task-work-1", "后台航程已完成", parent_id=sub_work["message_id"])
    rk_pers = convo.task_receipt("task-pers-1", "早安晨报已生成", channel="personal")
    assert rk_work == "task-result:task-work-1"
    assert rk_pers == "task-result:task-pers-1"

    # Verify channel-filtered snapshot & changes_since
    snap_work = convo.snapshot(channel="work")
    assert snap_work["channel"] == "work"
    assert snap_work["active_channel"] == "work"
    assert all(m["channel"] == "work" for m in snap_work["messages"])
    work_ids = {m["id"] for m in snap_work["messages"]}
    assert {sub_work["message_id"], sm_mid, bubble_res["bubble_id"], rk_work}.issubset(work_ids)
    assert sub_bk["message_id"] not in work_ids

    snap_bk = convo.snapshot(channel="bookkeeping")
    assert len(snap_bk["messages"]) == 2
    assert all(m["channel"] == "bookkeeping" for m in snap_bk["messages"])
    assert "[ch=bookkeeping]" in snap_bk["messages"][-1]["text"]

    delta_pers = convo.changes_since(0, channel="personal")
    assert [m["id"] for m in delta_pers["messages"]] == [rk_pers]

    page_work = convo.history(limit=20, channel="work")
    assert all(m["channel"] == "work" for m in page_work["messages"])

    info = convo.channels_info()
    assert info["enabled"] is True
    assert info["active"] == "work"
    by_id = {c["id"]: c for c in info["channels"]}
    assert by_id["work"]["message_count"] == len(snap_work["messages"])
    assert by_id["bookkeeping"]["message_count"] == 2
    assert by_id["personal"]["message_count"] == 1
    assert by_id["work"]["last_updated_at"] is not None


def test_flag_on_context_working_set_windows_and_cross_channel_supplement_isolation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("COM_CHANNELS_MODE", "on")
    convo = PersonalConversation(tmp_path, client=FakeStreamClient())

    # Insert 16 work messages and 12 bookkeeping messages interleaved
    with convo.db() as db:
        seq = 0
        for i in range(16):
            seq += 1
            db.execute(
                "INSERT INTO messages(id,request_id,role,text,status,created_at,updated_at,message_seq,channel)"
                " VALUES(?,?,?,?,?,?,?,?,?)",
                (f"w-{i}", f"req-w-{i:03d}", "user" if i % 2 == 0 else "assistant", f"工作历史记录 {i}", "completed", 200 + i, 200 + i, seq, "work"),
            )
            if i < 12:
                seq += 1
                db.execute(
                    "INSERT INTO messages(id,request_id,role,text,status,created_at,updated_at,message_seq,channel)"
                    " VALUES(?,?,?,?,?,?,?,?,?)",
                    (f"b-{i}", f"req-b-{i:03d}", "user" if i % 2 == 0 else "assistant", f"记账历史记录 {i}", "completed", 200 + i + 0.5, 200 + i + 0.5, seq, "bookkeeping"),
                )

    # work channel gets 14 turns (excluding bookkeeping!), bookkeeping gets 10 turns (excluding work!)
    work_turns = history(tmp_path, "", channel="work")
    assert len(work_turns) == 1 + 14
    assert all("记账历史记录" not in t["content"] for t in work_turns[1:])

    bk_turns = history(tmp_path, "", channel="bookkeeping")
    assert len(bk_turns) == 1 + 10
    assert all("工作历史记录" not in t["content"] for t in bk_turns[1:])

    search_work = read_history(tmp_path, query="历史记录", limit=8, channel="work")
    assert search_work["items"] and all(it["channel"] == "work" for it in search_work["items"])

    # context_builder injects channel supplement & resolves channel from request_id / context
    ws_work = context_builder.build(
        tmp_path,
        MARKER + json.dumps({"origin_request_id": "req-w-015", "channel": "work"}) + "\n用户消息：\n继续排期",
    )
    assert "【当前频道：工作与项目】" in ws_work.instructions
    assert '"channel":"work"' in ws_work.instructions
    assert ws_work.sizes["system_chars"] == len(SYSTEM_PROMPT)

    # Cross-channel supplement isolation when send_message mode is active
    monkeypatch.setenv("COM_SEND_MESSAGE_MODE", "on")
    u_work = convo.submit("req-active-work-01", "正在跑的工作任务", channel="work")["message_id"]
    u_bk = convo.submit("req-queued-bk-002", "补充：记一笔午饭 35", channel="bookkeeping")["message_id"]
    u_work_sup = convo.submit("req-queued-wk-003", "补充：把截止日改到周五", channel="work")["message_id"]
    convo._set(u_work, "running", phase="thinking", received=True)
    with convo.db() as db:
        row_bk = db.execute("SELECT * FROM messages WHERE id=?", (u_bk,)).fetchone()
        row_wk_sup = db.execute("SELECT * FROM messages WHERE id=?", (u_work_sup,)).fetchone()
    assert convo._is_supplement(row_bk, u_work) is False
    assert convo._is_supplement(row_wk_sup, u_work) is True


def test_http_channels_endpoints_and_filtering(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import importlib
    from fastapi.testclient import TestClient

    monkeypatch.setenv("WORKBENCH_HOME", str(tmp_path))
    monkeypatch.setenv("WORKBENCH_STATE", str(tmp_path / "state"))
    monkeypatch.setenv("COM_CHANNELS_MODE", "on")
    import app as app_mod

    app_mod = importlib.reload(app_mod)
    headers = {"Authorization": "Bearer " + app_mod.TOKEN}
    with TestClient(app_mod.app) as client:
        # Pause background worker so queued messages are deterministically inspected via REST
        app_mod.conversation._processing = True

        r_info = client.get("/personal/channels", headers=headers)
        assert r_info.status_code == 200
        info_body = r_info.json()
        assert info_body["enabled"] is True
        assert info_body["active"] == "personal"
        assert [c["id"] for c in info_body["channels"]] == ["personal", "work", "bookkeeping"]

        # Invalid channel -> 400
        r_bad = client.post("/personal/channels/select", headers=headers, json={"channel": "gaming"})
        assert r_bad.status_code == 400

        # Select work channel -> active becomes work
        r_sel = client.post("/personal/channels/select", headers=headers, json={"channel": "work"})
        assert r_sel.status_code == 200
        assert r_sel.json()["active"] == "work"

        # Post message without explicit channel -> goes to active ('work')
        r_m1 = client.post(
            "/personal/conversation/messages",
            headers=headers,
            json={"request_id": "req-http-work-0001", "text": "工作频道测试消息"},
        )
        assert r_m1.status_code == 200
        assert r_m1.json().get("channel") == "work"

        # Post message with explicit channel='bookkeeping'
        r_m2 = client.post(
            "/personal/conversation/messages",
            headers=headers,
            json={"request_id": "req-http-bk-000002", "text": "记账频道测试消息", "channel": "bookkeeping"},
        )
        assert r_m2.status_code == 200
        assert r_m2.json().get("channel") == "bookkeeping"

        # Filtered GET /personal/conversation?channel=work only returns work messages
        r_conv_work = client.get("/personal/conversation?channel=work", headers=headers)
        assert r_conv_work.status_code == 200
        conv_work = r_conv_work.json()
        assert conv_work["active_channel"] == "work"
        assert [m["text"] for m in conv_work["messages"]] == ["工作频道测试消息"]

        # Unfiltered GET /personal/conversation returns both
        r_conv_all = client.get("/personal/conversation", headers=headers)
        assert r_conv_all.status_code == 200
        assert len(r_conv_all.json()["messages"]) == 2

