import asyncio
import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conversation import HermesClient, PersonalConversation
from reactions import REACTION_EMOJIS, ReactionStore


def live_turn(tmp_path, text="终于完成了", request="reaction-request-001"):
    convo = PersonalConversation(tmp_path)
    receipt = convo.submit(request, text)
    with convo.db() as db:
        db.execute("INSERT INTO meta VALUES('hermes_session_id','com-personal-main')")
    convo._set(receipt["message_id"], "running", "run_reaction", received=True)
    token = convo.reactions.open_turn(receipt["message_id"], "com-personal-main")
    return convo, receipt["message_id"], token


def test_selected_reaction_is_durable_targeted_and_idempotent(tmp_path):
    convo, mid, token = live_turn(tmp_path)
    previous_revision = convo.snapshot()["revision"]
    store = ReactionStore(tmp_path)  # MCP owns a separate connection/process.
    result = store.react(mid, token, "🎉")
    assert result["created"] is True
    assert result["message_id"] == mid
    reaction = result["reaction"]
    assert reaction["emoji"] == "🎉"
    assert reaction["actor"] == "hermes"
    assert reaction["event_id"].startswith("reaction_")
    assert reaction["created_at"] <= time.time()
    changed = convo.changes_since(previous_revision)
    assert changed["revision"] == previous_revision + 1
    assert len(changed["messages"]) == 1
    assert changed["messages"][0]["id"] == mid
    assert changed["messages"][0]["reaction"] == reaction
    assert token not in json.dumps(changed)
    repeated = store.react(mid, token, "🎉")
    assert repeated == {"message_id": mid, "reaction": reaction, "created": False}
    assert convo.snapshot()["revision"] == changed["revision"]
    with pytest.raises(ValueError, match="reaction_already_selected"):
        store.react(mid, token, "👍")
    store.close_turn(mid)
    with pytest.raises(ValueError, match="reaction_target_invalid"):
        store.react(mid, token, "🎉")
    reopened = PersonalConversation(tmp_path).snapshot()
    assert reopened["messages"][0]["reaction"] == reaction


@pytest.mark.parametrize("invalid", [
    "wrong_token", "different_message", "assistant", "completed", "expired",
    "different_session", "different_request", "tool_receipt",
])
def test_only_current_user_turn_can_receive_reaction(tmp_path, invalid):
    convo, mid, token = live_turn(tmp_path)
    if invalid == "wrong_token":
        token = "x" * 43
    elif invalid == "different_message":
        mid = convo.submit("another-request-001", "另一个用户回合")["message_id"]
    elif invalid == "tool_receipt":
        convo.task_receipt("fixture-result", "通知或工具输出")
        mid = "0" * 32
        with convo.db() as db:
            db.execute("UPDATE messages SET id=? WHERE role='assistant'", (mid,))
    else:
        with convo.db() as db:
            if invalid == "assistant":
                db.execute("UPDATE messages SET role='assistant' WHERE id=?", (mid,))
            elif invalid == "completed":
                db.execute("UPDATE messages SET status='completed' WHERE id=?", (mid,))
            elif invalid == "expired":
                db.execute("UPDATE reaction_turns SET expires_at=0 WHERE message_id=?", (mid,))
            elif invalid == "different_session":
                db.execute("UPDATE meta SET value='notification-session' WHERE key='hermes_session_id'")
            elif invalid == "different_request":
                db.execute("UPDATE messages SET request_id='changed-request' WHERE id=?", (mid,))
    revision = convo.snapshot()["revision"]
    with pytest.raises(ValueError, match="reaction_target_invalid"):
        ReactionStore(tmp_path).react(mid, token, "❤️")
    state = convo.snapshot()
    assert state["revision"] == revision
    assert all(message["reaction"] is None for message in state["messages"])


@pytest.mark.parametrize("emoji", [None, "", "😈", "<script>", "👍👍", "💖"])
def test_reaction_whitelist_has_no_invented_fallback(tmp_path, emoji):
    convo, mid, token = live_turn(tmp_path)
    with pytest.raises(ValueError, match="reaction_arguments_invalid"):
        convo.reactions.react(mid, token, emoji)
    assert convo.snapshot()["messages"][0]["reaction"] is None


def test_stream_sends_model_selection_and_reconnect_only_restores_it(tmp_path):
    class ChoosingHermes(HermesClient):
        def __init__(self):
            self.release = asyncio.Event()
            self.selected = asyncio.Event()
            self.token = None

        def key(self):
            return "fixture"

        async def create_session(self):
            return "com-personal-main"

        async def stream_chat(self, session_id, text):
            context = json.loads(text.splitlines()[1])
            self.token = context["reaction"]["token"]
            yield "run.started", {"run_id": "run_selected"}
            yield "tool.started", {"tool_name": "react_to_user_message"}
            ReactionStore(tmp_path).react(context["reaction"]["message_id"], self.token, "💪")
            yield "tool.completed", {"tool_name": "react_to_user_message"}
            self.selected.set()
            await self.release.wait()
            yield "assistant.completed", {"content": "一步一步来。"}
            yield "run.completed", {}
            yield "done", {}

    async def scenario():
        fake = ChoosingHermes()
        convo = PersonalConversation(tmp_path, fake)
        sent = convo.submit("stream-reaction-001", "明天继续努力")
        events = convo.stream()
        initial = await events.__anext__()
        assert initial["event"] == "snapshot"
        assert initial["data"]["messages"][0]["reaction"] is None
        task = asyncio.create_task(convo.process_one())
        await asyncio.wait_for(fake.selected.wait(), 2)
        update = await asyncio.wait_for(events.__anext__(), 2)
        assert update["event"] == "update"
        reaction = update["data"]["messages"][0]["reaction"]
        assert reaction["emoji"] == "💪"
        fake.release.set()
        await task
        assert convo.snapshot()["messages"][0]["reaction"] == reaction
        with pytest.raises(ValueError, match="reaction_target_invalid"):
            convo.reactions.react(sent["message_id"], fake.token, "💪")
        reconnect = PersonalConversation(tmp_path).stream(update["id"])
        restored = await reconnect.__anext__()
        assert restored["event"] == "update"  # Durable cursor resumes without replaying a selection pulse.
        assert restored["data"]["messages"][0]["reaction"] == reaction
        await reconnect.aclose()
        await events.aclose()

    asyncio.run(scenario())


def test_old_history_migrates_without_manufacturing_expressions(tmp_path):
    db = sqlite3.connect(tmp_path / "personal-conversation.sqlite")
    db.executescript("""
        CREATE TABLE messages(
            id TEXT PRIMARY KEY, request_id TEXT UNIQUE, parent_id TEXT,
            role TEXT NOT NULL, text TEXT NOT NULL, status TEXT NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, run_id TEXT, error TEXT
        );
        INSERT INTO messages VALUES(
            'historical-message', 'historical-request', NULL, 'user',
            '我很开心！', 'completed', 1, 1, NULL, NULL
        );
    """)
    db.close()
    convo = PersonalConversation(tmp_path)
    assert convo.snapshot()["messages"][0]["reaction"] is None
    with pytest.raises(ValueError, match="reaction_turn_invalid"):
        convo.reactions.open_turn("historical-message", "com-personal-main")


def test_model_facing_tool_requires_capability_and_restricted_emoji():
    pytest.importorskip("mcp")
    import hermes_mcp
    tools = asyncio.run(hermes_mcp.mcp.list_tools())
    tool = next(tool for tool in tools if tool.name == "react_to_user_message")
    assert set(tool.inputSchema["required"]) == {"message_id", "reaction_token", "emoji"}
    assert set(tool.inputSchema["properties"]["emoji"]["enum"]) == set(REACTION_EMOJIS)
    assert "Optional" in tool.description
