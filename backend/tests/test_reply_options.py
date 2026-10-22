"""r2-chat：回复末尾的下一步选项从正文剥离并随快照下发。"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conversation import PersonalConversation
from hermes_prompt import SYSTEM_PROMPT
from reply_options import split_options, strip_partial

ANSWER = "**明天下午三点有个会**，跟老王对预算。\n\n我已经把材料放进待办了。\n[[选项: 帮我改到后天 | 先不管 | 看看详情]]"


class OptionsHermes:
    def __init__(self, answer=ANSWER, deltas=None):
        self.answer, self.deltas, self.seen = answer, deltas, []
    def key(self): return "fixture"
    async def create_session(self): return "com-personal-main"
    async def stream_chat(self, session_id, text):
        yield "run.started", {"run_id": "run_1"}
        for delta in self.deltas or [self.answer]:
            yield "assistant.delta", {"delta": delta}
        yield "assistant.completed", {"content": self.answer}
        yield "run.completed", {"completed": True}
        yield "done", {}


def test_split_options_parses_trailing_marker():
    body, options = split_options(ANSWER)
    assert options == ["帮我改到后天", "先不管", "看看详情"]
    assert body.endswith("我已经把材料放进待办了。") and "[[" not in body
    assert split_options("没有选项的回复") == ("没有选项的回复", [])
    # 全角冒号/竖线、超长与重复项、最多三个
    _, options = split_options("好\n[[选项：甲｜乙 | 甲 | 这一项实在是写得太长太长太长了超过限制 | 丙 | 丁]]")
    assert options == ["甲", "乙", "丙"]


def test_strip_partial_hides_unfinished_marker_while_streaming():
    for tail in ["[", "[[", "[[选", "[[选项", "[[选项: 帮我改", "[[ 选项：先"]:
        assert strip_partial("记好了。\n" + tail) == "记好了。"
    assert strip_partial("数组写法 a[0] 不受影响") == "数组写法 a[0] 不受影响"
    assert strip_partial("记好了。\n[[选项: 好 | 不]]") == "记好了。"


def test_completed_reply_stores_suggestions_and_clean_text(tmp_path):
    convo = PersonalConversation(tmp_path, OptionsHermes())
    convo.submit("request-opt-0001", "明天有什么安排")
    asyncio.run(convo.process_one())
    assistant = [m for m in convo.snapshot()["messages"] if m["role"] == "assistant"][-1]
    assert assistant["suggestions"] == ["帮我改到后天", "先不管", "看看详情"]
    assert "[[" not in assistant["text"]
    with convo.db() as db:
        raw = db.execute("SELECT text FROM messages WHERE role='assistant'").fetchone()[0]
    # 落库的正文也是干净的，推送、语音、搜索读到的都不带标记。
    assert "选项" not in raw
    # 旧消息、用户消息没有 suggestions 字段也能投影成空数组。
    user = [m for m in convo.snapshot()["messages"] if m["role"] == "user"][-1]
    assert user["suggestions"] == []


def test_streaming_projection_never_leaks_marker(tmp_path):
    convo = PersonalConversation(tmp_path, OptionsHermes())
    mid = convo.submit("request-opt-0002", "明天呢")["message_id"]
    convo._assistant(mid, "好的，已经记下。\n[[选项: 改", append=True)
    assistant = [m for m in convo.snapshot()["messages"] if m["role"] == "assistant"][-1]
    assert assistant["status"] == "streaming" and assistant["text"] == "好的，已经记下。"


def test_reply_without_options_has_empty_suggestions(tmp_path):
    convo = PersonalConversation(tmp_path, OptionsHermes(answer="记好了：午饭 30 元。"))
    convo.submit("request-opt-0003", "明天有什么安排")
    asyncio.run(convo.process_one())
    assistant = [m for m in convo.snapshot()["messages"] if m["role"] == "assistant"][-1]
    assert assistant["suggestions"] == [] and assistant["text"] == "记好了：午饭 30 元。"


def test_prompt_asks_for_layout_and_options():
    assert "不堆列表" not in SYSTEM_PROMPT
    assert "### 小标题" in SYSTEM_PROMPT and "**加粗**" in SYSTEM_PROMPT
    assert "[[选项:" in SYSTEM_PROMPT
