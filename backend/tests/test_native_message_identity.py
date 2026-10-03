import asyncio
import importlib
import json
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from history import History
from message_references import MessagePresentations
from runtime import Runtime


def test_identical_native_text_requires_real_turn_identity_and_survives_restart(tmp_path):
    store = MessagePresentations(tmp_path)
    for rid in ("same-native-send-001", "same-native-send-002"):
        assert store.record("codex:target", rid, "相同文字", None) == "相同文字"
    echo = {"id": "real-user-item-2", "role": "user", "text": "相同文字", "time": 1}
    assert store.project("codex:target", [echo]) == [echo]
    store.bind_turn("codex:target", "same-native-send-002", "actual-turn-2")
    wrong_turn = {**echo, "turn_id": "unrelated-turn"}
    assert store.project("codex:target", [wrong_turn]) == [wrong_turn]
    actual = store.project("codex:target", [{**echo, "turn_id": "actual-turn-2"}])[0]
    assert actual["request_id"] == "same-native-send-002"
    assert store.identity("codex:target", "same-native-send-001") == {"identity_confirmed": False}
    assert store.identity("codex:target", "same-native-send-002") == {
        "identity_confirmed": True, "message_id": "real-user-item-2",
    }
    historical = MessagePresentations(tmp_path).project("codex:target", [echo])[0]
    assert historical["request_id"] == "same-native-send-002"
    assert historical["text"] == "相同文字"
    assistant = {**echo, "role": "assistant", "turn_id": "actual-turn-2"}
    assert store.project("codex:target", [assistant]) == [assistant]


def test_pi_real_history_identity_uses_rid_even_with_identical_text_and_timestamp(tmp_path):
    home, state = tmp_path / "home", tmp_path / "state"
    state.mkdir()
    native = home / ".pi/agent/sessions/source.jsonl"
    native.parent.mkdir(parents=True)
    rows = [{"type": "session", "id": "source", "cwd": str(home)}]
    store = MessagePresentations(state)
    for rid in ("pi-native-send-001", "pi-native-send-002"):
        store.record("pi:source", rid, "相同文字", None)
        rows.append({"type": "message", "id": "entry-" + rid, "message": {
            "role": "user", "content": [{"type": "text", "text": "相同文字"}],
            "timestamp": 100, "com_request_id": rid,
        }})
    native.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
    original = native.read_bytes()
    history = History(home, state)
    history.scan()
    messages = store.project("pi:source", history.messages("pi:source"))
    assert [message["request_id"] for message in messages] == ["pi-native-send-001", "pi-native-send-002"]
    assert [message["id"] for message in messages] == ["pi:com:pi-native-send-001", "pi:com:pi-native-send-002"]
    assert native.read_bytes() == original
    # Native metadata without a private dispatch cannot claim an app receipt.
    outsider = {"id": "pi:com:not-dispatched", "role": "user", "text": "相同文字"}
    assert store.project("pi:source", [outsider]) == [outsider]


def test_codex_canonical_turn_is_preserved_without_live_poll_and_old_index_migrates(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    # The existing messages table keeps its columns and old INSERT semantics.
    with sqlite3.connect(state / "index.sqlite") as db:
        db.execute("CREATE TABLE messages(sid,mid,position,role,title,body,time,PRIMARY KEY(sid,mid))")
    source = tmp_path / ".codex/sessions/source.jsonl"
    source.parent.mkdir(parents=True)
    source.write_text(json.dumps({"type": "session_meta", "payload": {"id": "source", "cwd": str(tmp_path)}}) + "\n")
    with sqlite3.connect(tmp_path / ".codex/thread_history_1.sqlite") as db:
        db.execute("CREATE TABLE thread_items(thread_id,item_id,item_json,created_at_ms,rollout_ordinal,turn_id)")
        db.execute("INSERT INTO thread_items VALUES(?,?,?,?,?,?)", (
            "source", "real-native-item", json.dumps({"type": "userMessage", "content": [{"type": "text", "text": "原消息"}]}),
            100, 1, "real-native-turn",
        ))
    store = MessagePresentations(state)
    store.record("codex:source", "codex-private-send-001", "原消息", None)
    store.bind_turn("codex:source", "codex-private-send-001", "real-native-turn")
    history = History(tmp_path, state)
    history.scan()
    actual = store.project("codex:source", history.messages("codex:source"))[0]
    assert actual["id"] == "real-native-item" and actual["turn_id"] == "real-native-turn"
    assert actual["request_id"] == "codex-private-send-001"
    history = History(tmp_path, state)
    history.scan()
    assert history.messages("codex:source")[0]["turn_id"] == "real-native-turn"
    with history.db() as db:
        assert db.execute("SELECT COUNT(*) FROM message_turns").fetchone()[0] == 1
        assert len(db.execute("PRAGMA table_info(messages)").fetchall()) == 7


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("WORKBENCH_HOME", str(tmp_path))
    monkeypatch.setenv("WORKBENCH_STATE", str(tmp_path / "state"))
    import app
    app = importlib.reload(app)
    monkeypatch.setattr(app.conversation, "start", lambda: None)
    monkeypatch.setattr(app.quick_voice, "start", lambda: None)
    with TestClient(app.app) as client:
        yield app, client, {"Authorization": "Bearer " + app.TOKEN}


def test_health_advertises_loaded_reference_migrations(api):
    app, client, _ = api
    health = client.get("/health").json()
    assert health["features"]["message_references_v1"] is True
    assert health["features"]["stable_message_identity_v1"] is True
    with app.conversation.db() as db:
        assert "reference" in [row["name"] for row in db.execute("PRAGMA table_info(messages)")]
    with app.presentations.db() as db:
        assert db.execute("SELECT COUNT(*) FROM dispatches").fetchone()[0] == 0


def test_manual_native_work_no_longer_needs_an_artificial_task_binding(api,monkeypatch):
    app,client,headers=api
    monkeypatch.setattr(app,'MAIN_AGENT','pi')
    sid='codex:legacy-unbound'
    app.history.save_managed(sid,{'agent':'codex','native_id':'legacy-unbound','cwd':str(app.HOME),'ended':False,'tmux':''})
    with app.history.db() as db:
        db.execute('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?)',(sid,'codex','legacy-unbound','',str(app.HOME),'旧任务',1,'','历史'))
    async def status(_):return 'completed'
    calls=[]
    async def forbidden(*args,**kwargs):raise AssertionError('查看历史不能启动原生执行器')
    async def native_input(*args,**kwargs):calls.append(args);return 'actual-native-turn'
    monkeypatch.setattr(app.runtime,'status',status)
    monkeypatch.setattr(app.runtime,'stable_input',lambda _:True)
    monkeypatch.setattr(app.runtime,'create',forbidden)
    monkeypatch.setattr(app.runtime,'input',native_input)
    monkeypatch.setattr(app.runtime,'events',lambda _:[])
    caps=client.get('/sessions/'+sid,headers=headers).json()['session']['capabilities']
    assert caps['input'] and not caps['resume'] and calls==[]
    result=client.post('/sessions/'+sid+'/input',headers=headers,json={'request_id':'legacy-unbound-001','text':'请修改文件'}).json()
    assert result['status']=='accepted' and result['submission_state']=='submitted'
    assert len(calls)==1 and calls[0][0]==sid
    assert client.post('/sessions/'+sid+'/input',headers=headers,json={'request_id':'legacy-unbound-001','text':'请修改文件'}).json()==result
    assert len(calls)==1
    blocked=client.post('/sessions/'+sid+'/resume',headers=headers,json={'request_id':'legacy-resume-001'}).json()
    assert blocked['status']=='rejected' and blocked['submission_state']=='not_submitted'


@pytest.mark.parametrize("busy", [False, True])
def test_known_pi_preflight_rejection_is_durable_and_dispatches_nothing(api, monkeypatch, busy):
    app, client, headers = api
    sid = "pi:old"
    app.history.save_managed(sid, {"sid": sid, "agent": "pi", "native_id": "old", "ended": False})
    events = [{"type": "com_input_capabilities", "data": {"stable_message_identity_v1": True}}] if busy else []
    monkeypatch.setattr(app.runtime, "events", lambda _: events)
    async def status(_):
        return "running" if busy else "ready"
    async def forbidden(*args, **kwargs):
        raise AssertionError("Preflight rejection must never reach native input or tmux")
    monkeypatch.setattr(app.runtime, "status", status)
    monkeypatch.setattr(app.runtime, "input", forbidden)
    monkeypatch.setattr(app.runtime, "tm", forbidden)
    body = {"request_id": "rejected-native-001", "text": "保留草稿"}
    receipt = client.post("/sessions/" + sid + "/input", headers=headers, json=body).json()
    assert receipt["status"] == "rejected" and receipt["submission_state"] == "not_submitted"
    assert client.get("/receipts/" + body["request_id"], headers=headers).json() == receipt
    # A later recovery must not silently replay this rejected original request.
    monkeypatch.setattr(app.runtime, "stable_input", lambda _: True)
    assert client.post("/sessions/" + sid + "/input", headers=headers, json=body).json() == receipt
    assert app.presentations.project(sid, []) == []


def test_native_create_receipt_is_submitted_without_fake_running_or_history(api, monkeypatch):
    app, client, headers = api
    async def create(*args, **kwargs):
        return "codex:new"
    async def native_input(*args, **kwargs):
        return "actual-turn"
    monkeypatch.setattr(app.runtime, "create", create)
    monkeypatch.setattr(app.runtime, "input", native_input)
    receipt = client.post("/sessions", headers=headers, json={
        "request_id": "create-native-001", "agent": "codex", "prompt": "原消息",
    }).json()
    assert receipt["status"] == "accepted" and receipt["submission_state"] == "submitted"
    assert receipt["turn_id"] == "actual-turn" and receipt["identity_confirmed"] is False
    assert "message_id" not in receipt
    assert app.history.messages("codex:new") == []


@pytest.mark.parametrize("busy_events", [None, [{"type": "agent_start"}],
    [{"type": "agent_start"}, {"type": "agent_end"}],
    [{"type": "queue_update", "data": {"followUp": ["pending native input"]}}]])
def test_explicit_legacy_pi_upgrade_requires_native_idle_and_keeps_history(api, monkeypatch, busy_events):
    app, client, headers = api
    sid = "pi:legacy"
    native = app.HOME / ".pi/agent/sessions/legacy.jsonl"
    native.parent.mkdir(parents=True)
    native.write_text("\n".join(json.dumps(row) for row in [
        {"type": "session", "id": "legacy", "cwd": str(app.HOME)},
        {"type": "message", "id": "original-user", "message": {"role": "user", "content": "保留原生历史"}},
    ]) + "\n")
    original = native.read_bytes()
    app.history.scan()
    managed = {"sid": sid, "agent": "pi", "native_id": "legacy", "tmux": "s-legacy", "ended": False}
    app.history.save_managed(sid, managed)
    events = [{"type": "session_start"}, {"type": "agent_settled"}] + (busy_events or [])
    monkeypatch.setattr(app.runtime, "events", lambda _: events)
    calls = []
    async def alive(name):
        return True
    async def status(_):
        return "running" if busy_events else "completed"
    async def tm(*args, **kwargs):
        calls.append(args)
        assert args == ("kill-session", "-t", "s-legacy")
        return ""
    async def create(agent, cwd, resume, sandbox):
        assert sandbox=='danger-full-access'
        calls.append(("create", agent, cwd, resume["path"]))
        assert app.history.managed()[sid]["ended"] is True
        assert resume["native_id"] == "legacy" and resume["path"] == str(native)
        app.history.save_managed(sid, {**managed, "tmux": "s-upgraded", "ended": False})
        events.append({"type": "com_input_capabilities", "data": {"stable_message_identity_v1": True}})
        return sid
    monkeypatch.setattr(app.runtime, "alive", alive)
    monkeypatch.setattr(app.runtime, "status", status)
    monkeypatch.setattr(app.runtime, "tm", tm)
    monkeypatch.setattr(app.runtime, "create", create)
    caps = client.get("/sessions/" + sid, headers=headers).json()["session"]["capabilities"]
    assert caps["restart_for_identity"] is True and caps["input"] is False
    assert caps["resume"] is (busy_events is None)
    assert calls == []  # Opening history/capabilities never reloads or restarts.
    body = {"request_id": "explicit-legacy-resume-001"}
    receipt = client.post("/sessions/" + sid + "/resume", headers=headers, json=body).json()
    if busy_events:
        assert receipt["status"] == "rejected" and receipt["submission_state"] == "not_submitted"
        assert calls == [] and app.history.managed()[sid]["ended"] is False
    else:
        assert receipt["status"] == "accepted" and receipt["sid"] == sid
        assert len(calls) == 2
    assert client.post("/sessions/" + sid + "/resume", headers=headers, json=body).json() == receipt
    assert len(calls) == (0 if busy_events else 2)
    assert native.read_bytes() == original
    assert app.history.messages(sid)[0]["text"] == "保留原生历史"


def test_pi_protocol_encodes_plain_input_and_waits_for_actual_user_echo(tmp_path):
    history = History(tmp_path, tmp_path / "state")
    runtime = Runtime(history, "test")
    sid, rid = "pi:new", "pi-protocol-send-001"
    history.save_managed(sid, {"sid": sid, "agent": "pi", "native_id": "new", "tmux": "pane", "ended": False})
    events = [{"type": "com_input_capabilities", "data": {"stable_message_identity_v1": True}}]
    runtime.events = lambda _: events
    async def status(_):
        return "ready"
    async def alive(_):
        return True
    inputs = []
    async def tm(*args, **kwargs):
        if args[0] == "load-buffer":
            import base64
            command = kwargs["input"].decode()
            assert command.startswith("/com-input ")
            encoded = command.split(" ", 1)[1]
            inputs.append(json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))))
        if args[0] == "send-keys":
            events.append({"type": "com_input_result", "data": {
                "requestId": rid, "ok": True, "messageId": "pi:com:" + rid,
            }})
        return ""
    runtime.tm, runtime.status, runtime.alive = tm, status, alive
    text = "普通文字\n$(不要执行) /skill"
    assert asyncio.run(runtime.input(sid, text, rid)) == rid
    assert inputs == [{"requestId": rid, "text": text}]


def test_pi_extension_tags_only_its_real_user_message_and_keeps_native_text(tmp_path):
    node = shutil.which("node")
    if not node:
        pytest.skip("Node is required for the actual Pi extension contract")
    extension = Path(__file__).resolve().parents[1] / "pi-events.ts"
    script = r"""
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
process.env.SESSION_WORKBENCH_EVENTS = process.argv[1];
const {default:extension} = await import(process.argv[2]);
const hooks = new Map(), commands = new Map(), native = [];
const ctx = {sessionManager:{getSessionId:()=> 'sid',getSessionFile:()=> 'native.jsonl',getBranch:()=> native.map((message,i)=>({id:'real-entry-'+i,type:'message',message}))},isIdle:()=>true,hasPendingMessages:()=>false};
async function emit(type,event) {
  let result;
  for (const hook of hooks.get(type) || []) result = await hook(event,ctx) || result;
  return result;
}
const pi = {
  on:(type,handler)=> hooks.set(type,[...(hooks.get(type)||[]),handler]),
  registerCommand:(name,command)=> commands.set(name,command),
  sendUserMessage:(text,options)=> {
    assert.equal(options.expandPromptTemplates,false);
    (async()=> {
      assert.equal((await emit('input',{source:'interactive',text})).action,'handled');
      assert.equal((await emit('input',{source:'extension',text})).action,'continue');
      const assistant={role:'assistant',content:[{type:'text',text}],timestamp:100};
      await emit('message_start',{message:assistant});
      await emit('message_end',{message:assistant});
      assert.equal(assistant.com_request_id,undefined);
      const user={role:'user',content:[{type:'text',text}],timestamp:100};
      await emit('message_start',{message:user});
      const result=await emit('message_end',{message:user});
      native.push(result.message);
    })().catch(error=> {console.error(error);process.exit(1);});
  }
};
extension(pi);
await emit('session_start',{});
const rid='actual-pi-user-send-001',text='普通文字\n/com-input 不是另一个命令';
const arg=Buffer.from(JSON.stringify({requestId:rid,text})).toString('base64url');
await commands.get('com-input').handler(arg,ctx);
assert.equal(native.length,1);
assert.equal(native[0].content[0].text,text);
assert.equal(native[0].com_request_id,rid);
await commands.get('com-input').handler(arg,ctx);
assert.equal(native.length,1);
const events=readFileSync(process.argv[1],'utf8').trim().split('\n').map(JSON.parse);
assert(events.some(e=>e.type==='com_input_capabilities'&&e.data.stable_message_identity_v1));
assert(events.some(e=>e.type==='com_input_result'&&e.data.ok&&e.data.messageId==='pi:com:'+rid));
assert(events.some(e=>e.type==='message_end'&&e.data.message.role==='user'&&e.data.message.com_request_id===rid));
"""
    result = subprocess.run([node, "--input-type=module", "--eval", script,
                             str(tmp_path / "events.jsonl"), extension.as_uri()],
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
