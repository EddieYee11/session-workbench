import asyncio
import importlib
import sys
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conversation import HermesClient, PersonalConversation


class FakeHermes:
    def __init__(self):
        self.created = 0
        self.turns = []

    def key(self):
        return "fixture"

    async def create_session(self):
        self.created += 1
        return "com-personal-main"

    async def stream_chat(self, session_id, text):
        self.turns.append((session_id, text))
        answer = f"第 {len(self.turns)} 轮：{text}"
        yield "run.started", {"run_id": f"run_{len(self.turns)}"}
        yield "message.started", {"message": {"role": "assistant"}}
        yield "assistant.delta", {"delta": answer[:3]}
        yield "assistant.delta", {"delta": answer[3:]}
        yield "assistant.completed", {"content": answer}
        yield "run.completed", {"completed": True}
        yield "done", {}


def test_persistent_main_chat_and_duplicate_delivery(tmp_path):
    fake = FakeHermes()
    convo = PersonalConversation(tmp_path, fake)
    first = convo.submit("request-00001", "今天有什么安排")
    assert first["status"] == "accepted"
    assert convo.submit("request-00001", "今天有什么安排")["message_id"] == first["message_id"]
    asyncio.run(convo.process_one())
    second = convo.submit("request-00002", "那下午呢")
    asyncio.run(convo.process_one())
    assert fake.created == 1
    assert fake.turns == [
        ("com-personal-main", "今天有什么安排"),
        ("com-personal-main", "那下午呢"),
    ]
    reopened = PersonalConversation(tmp_path, fake).snapshot()
    assert reopened["conversation_id"] == "personal-main"
    assert [m["role"] for m in reopened["messages"]] == [
        "user", "assistant", "user", "assistant"
    ]
    assert reopened["messages"][-1]["text"] == "第 2 轮：那下午呢"
    assert reopened["messages"][-1]["status"] == "completed"
    assert reopened["messages"][-1]["phase"] == "completed"
    assert reopened["messages"][2]["received_at"] is not None
    assert reopened["revision"] >= 8
    try:
        convo.submit("request-00001", "另一个内容")
    except ValueError as exc:
        assert str(exc) == "请求标识冲突"
    else:
        raise AssertionError("duplicate request_id accepted with different content")


def test_uncertain_send_is_not_replayed(tmp_path):
    fake = FakeHermes()
    convo = PersonalConversation(tmp_path, fake)
    receipt = convo.submit("request-00003", "记录这件事")
    convo._set(receipt["message_id"], "sending")
    asyncio.run(PersonalConversation(tmp_path, fake).process_one())
    messages = convo.snapshot()["messages"]
    assert messages[0]["status"] == "unknown"
    assert "未自动重试" in messages[0]["error"]
    assert fake.turns == []


def test_partial_and_observed_phases_are_durable_and_broadcast(tmp_path):
    class PausingHermes(FakeHermes):
        def __init__(self):
            super().__init__()
            self.release_tool = asyncio.Event()
            self.release = asyncio.Event()

        async def stream_chat(self, session_id, text):
            self.turns.append((session_id, text))
            yield "run.started", {"run_id": "run_phase"}
            yield "tool.started", {"tool_name": "personal_overview"}
            await self.release_tool.wait()
            yield "tool.completed", {"tool_name": "personal_overview"}
            yield "assistant.delta", {"delta": "这是部分"}
            await self.release.wait()
            yield "assistant.completed", {"content": "这是完整答复"}
            yield "run.completed", {"completed": True}
            yield "done", {}

    async def scenario():
        fake = PausingHermes()
        convo = PersonalConversation(tmp_path, fake)
        convo.submit("request-phases-001", "今天有什么安排")
        events = convo.stream()
        first = await events.__anext__()
        assert first["event"] == "snapshot"
        assert first["data"]["messages"][0]["phase"] == "queued"
        running = asyncio.create_task(convo.process_one())
        for _ in range(100):
            tool_state = convo.snapshot()
            if tool_state["messages"][0]["phase"] == "executing":
                break
            await asyncio.sleep(.01)
        else:
            raise AssertionError("tool phase did not arrive")
        assert tool_state["messages"][0]["active_tool"] == "personal_overview"
        fake.release_tool.set()
        for _ in range(100):
            state = convo.snapshot()
            if state["messages"][-1]["text"] == "这是部分":
                break
            await asyncio.sleep(.01)
        else:
            raise AssertionError("partial did not arrive")
        assert state["messages"][0]["phase"] == "responding"
        assert state["messages"][0]["run_id"] == "run_phase"
        assert state["messages"][0]["received_at"] is not None
        assert state["messages"][-1]["status"] == "streaming"
        update = await asyncio.wait_for(events.__anext__(), 2)
        assert update["event"] == "update"
        assert update["id"] == state["revision"]
        assert update["data"]["messages"][-1]["text"] == "这是部分"
        fake.release.set()
        await running
        final = convo.snapshot()
        assert final["messages"][-1]["text"] == "这是完整答复"
        assert final["messages"][-1]["id"] == state["messages"][-1]["id"]
        assert final["messages"][0]["status"] == "completed"
        await events.aclose()

    asyncio.run(scenario())


def test_stream_break_after_partial_is_unknown_and_not_replayed(tmp_path):
    class BrokenHermes(FakeHermes):
        async def stream_chat(self, session_id, text):
            self.turns.append((session_id, text))
            yield "run.started", {"run_id": "run_broken"}
            yield "assistant.delta", {"delta": "已生成的部分"}
            raise RuntimeError("connection closed")

    fake = BrokenHermes()
    convo = PersonalConversation(tmp_path, fake)
    convo.submit("request-broken-001", "处理这件事")
    asyncio.run(convo.process_one())
    rows = PersonalConversation(tmp_path, fake).snapshot()["messages"]
    assert rows[0]["status"] == "unknown"
    assert "未自动重试" in rows[0]["error"]
    assert rows[1]["text"] == "已生成的部分"
    assert rows[1]["status"] == "unknown"
    asyncio.run(convo.process_one())
    assert len(fake.turns) == 1


def test_assistant_completed_without_run_completed_remains_unknown(tmp_path):
    class MissingTerminalHermes(FakeHermes):
        async def stream_chat(self, session_id, text):
            self.turns.append((session_id, text))
            yield "run.started", {"run_id": "run_missing_terminal"}
            yield "assistant.delta", {"delta": "草稿"}
            yield "assistant.completed", {"content": "完整文字"}
            yield "done", {}

    fake = MissingTerminalHermes()
    convo = PersonalConversation(tmp_path, fake)
    convo.submit("request-terminal-001", "帮我检查")
    asyncio.run(convo.process_one())
    rows = convo.snapshot()["messages"]
    assert rows[0]["status"] == "unknown"
    assert rows[1]["status"] == "unknown"
    assert rows[1]["text"] == "完整文字"


def test_restart_preserves_partial_but_never_replays_running_turn(tmp_path):
    fake = FakeHermes()
    convo = PersonalConversation(tmp_path, fake)
    receipt = convo.submit("request-restart-001", "帮我检查")
    convo._set(receipt["message_id"], "running", "run_old", phase="responding", received=True)
    convo._assistant(receipt["message_id"], "重启前的部分")
    asyncio.run(PersonalConversation(tmp_path, fake).process_one())
    rows = convo.snapshot()["messages"]
    assert rows[0]["status"] == "unknown"
    assert rows[1]["text"] == "重启前的部分"
    assert rows[1]["status"] == "unknown"
    assert fake.turns == []


def test_hermes_key_must_be_private(tmp_path):
    client = HermesClient(tmp_path)
    try:
        client.key()
    except ValueError as exc:
        assert str(exc) == "hermes_key_missing"
    else:
        raise AssertionError("missing key accepted")
    client.key_file.write_text("fixture")
    client.key_file.chmod(0o644)
    try:
        client.key()
    except ValueError as exc:
        assert str(exc) == "hermes_key_permissions"
    else:
        raise AssertionError("public key accepted")


def test_personal_chat_requires_pairing(tmp_path, monkeypatch):
    monkeypatch.setenv("WORKBENCH_HOME", str(tmp_path))
    monkeypatch.setenv("WORKBENCH_STATE", str(tmp_path / "state"))
    import app
    app = importlib.reload(app)
    app.conversation.client = FakeHermes()
    with TestClient(app.app) as client:
        assert client.get("/personal/conversation").status_code == 401
        headers = {"Authorization": "Bearer " + app.TOKEN}
        assert client.get("/personal/conversation", headers=headers).status_code == 200
        sent = client.post(
            "/personal/conversation/messages", headers=headers,
            json={"request_id": "request-00004", "text": "你好"},
        )
        assert sent.status_code == 200
        assert sent.json()["message_id"]


class FakeHermesWithTools:
    def __init__(self):
        self.created = 0

    def key(self):
        return "fixture"

    async def create_session(self):
        self.created += 1
        return "com-personal-main"

    async def stream_chat(self, session_id, text):
        yield "run.started", {"run_id": "run_9"}
        yield "tool.started", {"tool_name": "mcp__personal_overview"}
        yield "tool.completed", {}
        yield "tool.started", {"tool_name": "mcp__git_pull"}
        yield "tool.failed", {}
        yield "assistant.completed", {"content": "搞定了"}
        yield "run.completed", {"completed": True}
        yield "done", {}


def test_work_tasks_recorded_on_user_message(tmp_path):
    fake = FakeHermesWithTools()
    convo = PersonalConversation(tmp_path, fake)
    mid = convo.submit("request-00009", "帮我查一下")["message_id"]
    asyncio.run(convo.process_one())
    snap = convo.snapshot()
    user_msg = next(m for m in snap["messages"] if m["id"] == mid)
    assert user_msg["tasks"] == [
        {"id": "think", "title": "分析用户请求", "status": "done"},
        {"id": "tool-1", "title": "正在读取日历与账本概览", "status": "done"},
        {"id": "tool-2", "title": "正在使用 mcp__git_pull", "status": "failed"},
        {"id": "reply", "title": "撰写回复", "status": "done"},
    ]
    # 持久化：重开后任务清单仍在
    reopened = PersonalConversation(tmp_path, fake).snapshot()
    user_msg2 = next(m for m in reopened["messages"] if m["id"] == mid)
    assert user_msg2["tasks"] == user_msg["tasks"]
