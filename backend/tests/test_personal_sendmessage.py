"""Personal Agent SendMessage-as-tool 与中途追发事件队列全链路单测与本地模拟验证。"""
from __future__ import annotations

import asyncio
import hashlib
import json
import sys
import time
from pathlib import Path
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_tools import AgentTools
from artifacts import ArtifactAccess
from capabilities import CapabilityRegistry
from conversation import PersonalConversation
from goals import GoalEvents
from hermes_prompt import SYSTEM_PROMPT
from hermes_runtime import HermesRuntime
from send_message import (
    ContentAddressedStore,
    SendMessageStateError,
    SendMessageValidationError,
    SendMessageValidator,
)
from sse_stream import SSEBroadcaster, SSERingBuffer
from superagent_flags import SuperagentFlags
from tasks import TaskController, TaskStore
from work_dispatch import WorkProposalStore


async def until(predicate, timeout: float = 4.0) -> None:
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.005)


def enable_send_message_flag(state: Path, *, remind_after: int = 4) -> None:
    (Path(state) / "superagent-flags.json").write_text(
        json.dumps(
            {
                "router": "off",
                "mandate": "off",
                "herdr_write": "off",
                "send_message": "on",
                "send_message_remind_after": remind_after,
            }
        )
    )


def build_agent_tools(state: Path, workspace: Path, conversation: PersonalConversation) -> AgentTools:
    if conversation._session_id() is None:
        key = getattr(conversation.client, "session_key", None) or "hermes_session_id"
        with conversation.db() as db:
            db.execute("INSERT OR IGNORE INTO meta(key, value) VALUES(?, ?)", (key, "com-hermes-main"))
    proposals = WorkProposalStore(state, workspace)
    store = TaskStore(state)
    artifacts = ArtifactAccess(store, workspace, state)
    conversation.workspace = workspace
    conversation.cas_store = ContentAddressedStore(state, workspace)
    conversation.artifact_linker = artifacts.link_text
    conversation.artifact_register_fn = artifacts.register
    conversation.turn_file_linker = artifacts.link_turn_files
    caps = CapabilityRegistry(state)
    goals = GoalEvents(state)
    controller = TaskController(store, None, conversation)
    tools = AgentTools(state, conversation, proposals, store, controller, caps, goals)
    tools.artifact_access = artifacts
    return tools


# ---------------------------------------------------------------------------
# 1. 默认开关关闭回归：行为与现网 100% 一致，且 SYSTEM_PROMPT 预算零膨胀
# ---------------------------------------------------------------------------
def test_flag_off_preserves_exact_legacy_single_bubble(tmp_path: Path):
    assert SuperagentFlags(tmp_path).send_message_on() is False
    assert len(SYSTEM_PROMPT) < 2200

    seen_inputs: list[str] = []

    class LegacyClient:
        runtime_name = "hermes"
        session_key = "hermes_v2_session_id"
        has_native_history = True

        def key(self) -> str:
            return "test-key"

        async def create_session(self) -> str:
            return "com-hermes-main"

        async def stream_chat(self, session_id: str, text: str):
            seen_inputs.append(text)
            yield "run.started", {"run_id": "run_legacy_1"}
            yield "input.accepted", {"request_id": "req-legacy-0001"}
            yield "input.delivered", {"request_id": "req-legacy-0001", "run_id": "run_legacy_1"}
            yield "assistant.delta", {"delta": "这是旧版流式"}
            yield "assistant.completed", {"content": "这是旧版流式单气泡答复"}
            yield "run.completed", {"run_id": "run_legacy_1"}
            yield "done", {}

    async def scenario():
        conv = PersonalConversation(tmp_path, LegacyClient())
        sub = conv.submit("req-legacy-0001", "今天天气怎么样")
        assert await conv.process_one() is True
        snap = conv.snapshot()
        assistants = [m for m in snap["messages"] if m["role"] == "assistant"]
        assert len(assistants) == 1
        assert assistants[0]["text"] == "这是旧版流式单气泡答复"
        assert assistants[0]["parent_id"] == sub["message_id"]
        assert assistants[0]["message_seq"] > sub["message_seq"] > 0
        assert "<system_reminder>" not in seen_inputs[0]

    asyncio.run(scenario())


# ---------------------------------------------------------------------------
# 2. 确认气泡毫秒级下发 + 工具交错进度气泡 + 普通文本静默 + 文件内容寻址 + SSE 广播
# ---------------------------------------------------------------------------
def test_sendmessage_ack_latency_interleaved_progress_and_sse_stream(tmp_path: Path):
    state = tmp_path / "state"
    workspace = tmp_path / "AI_Work_System"
    state.mkdir()
    (workspace / "work" / "航程产出").mkdir(parents=True)
    enable_send_message_flag(state)

    sse_ring = SSERingBuffer(state / "sse_events.sqlite", capacity=200)
    broadcaster = SSEBroadcaster(sse_ring)
    subscriber_q: asyncio.Queue = asyncio.Queue(maxsize=200)
    timings: dict[str, float] = {}
    seen_prompts: list[str] = []

    class InterleavedAgentClient:
        runtime_name = "hermes"
        session_key = "hermes_v2_session_id"
        has_native_history = True

        def __init__(self):
            self.conv: PersonalConversation | None = None
            self.tools: AgentTools | None = None

        def key(self) -> str:
            return "test-key"

        async def create_session(self) -> str:
            return "com-hermes-main"

        async def stream_chat(self, session_id: str, text: str):
            seen_prompts.append(text)
            assert self.conv is not None and self.tools is not None
            mid = self.conv.active_user_message()
            assert mid is not None
            with self.conv.db() as db:
                req_id = db.execute("SELECT request_id FROM messages WHERE id=?", (mid,)).fetchone()["request_id"]
            ctx = {
                "origin_session_id": session_id,
                "origin_message_id": mid,
                "origin_request_id": req_id,
            }
            yield "run.started", {"run_id": "run_interleaved_01"}
            yield "input.accepted", {"request_id": req_id}
            yield "input.delivered", {"request_id": req_id, "run_id": "run_interleaved_01"}

            # Step 1: 内部思考（用户不可见）+ 第一时间发确认气泡 + 同时发起耗时工具调用
            yield "assistant.delta", {"delta": "内部思考：先确认收到，同时查日历和准备复盘文件。"}
            yield "tool.started", {"tool_name": "mcp__com_workbench__send_message", "tool_call_id": "tc-ack"}
            await self.tools.call(
                "send_message",
                {"type": "text", "content": "收到，我先帮你查今天日历并整理复盘文档。"},
                ctx,
            )
            yield "tool.completed", {"tool_name": "mcp__com_workbench__send_message", "tool_call_id": "tc-ack"}

            yield "tool.started", {"tool_name": "calendar_read", "tool_call_id": "tc-cal"}
            await asyncio.sleep(0.18)  # 模拟真实日历读取耗时 180ms
            yield "tool.completed", {"tool_name": "calendar_read", "tool_call_id": "tc-cal"}

            # Step 2: 工具中途发进度气泡 + 产出本地文件并通过 type=attachment 内容寻址下发
            yield "tool.started", {"tool_name": "mcp__com_workbench__send_message", "tool_call_id": "tc-prog"}
            await self.tools.call(
                "send_message",
                {"type": "text", "content": "日历查完了，下午 15:00 有产品评审；正在生成复盘文档。"},
                ctx,
            )
            yield "tool.completed", {"tool_name": "mcp__com_workbench__send_message", "tool_call_id": "tc-prog"}

            report_file = workspace / "work" / "航程产出" / "daily-review.md"
            report_bytes = "# 今日复盘\n- 15:00 产品评审\n- 晚间运动\n".encode("utf-8")
            report_file.write_bytes(report_bytes)
            timings["expected_sha256"] = hashlib.sha256(report_bytes).hexdigest()  # type: ignore[assignment]

            yield "tool.started", {"tool_name": "mcp__com_workbench__send_message", "tool_call_id": "tc-att"}
            await self.tools.call(
                "send_message",
                {
                    "type": "attachment",
                    "url": f"file://{report_file}",
                    "caption": "今日复盘 Markdown 已生成",
                },
                ctx,
            )
            yield "tool.completed", {"tool_name": "mcp__com_workbench__send_message", "tool_call_id": "tc-att"}

            yield "tool.started", {"tool_name": "business_operation", "tool_call_id": "tc-biz"}
            await asyncio.sleep(0.18)  # 模拟第二段工具耗时 180ms
            yield "tool.completed", {"tool_name": "business_operation", "tool_call_id": "tc-biz"}

            # Step 3: 发最终结果气泡 + 尾部思考（不应变成气泡）
            yield "tool.started", {"tool_name": "mcp__com_workbench__send_message", "tool_call_id": "tc-final"}
            await self.tools.call(
                "send_message",
                {
                    "type": "text",
                    "content": "全部办妥：下午 15:00 评审已核对，复盘文档也附在上面了。",
                    "suggestions": ["设个三点提醒", "看明天安排"],
                },
                ctx,
            )
            yield "tool.completed", {"tool_name": "mcp__com_workbench__send_message", "tool_call_id": "tc-final"}
            yield "assistant.completed", {"content": "内部收尾思考：全部发完，不再重复总结。"}
            yield "run.completed", {"run_id": "run_interleaved_01"}
            yield "done", {}

    async def scenario():
        client = InterleavedAgentClient()
        conv = PersonalConversation(state, client)
        tools = build_agent_tools(state, workspace, conv)
        client.conv = conv
        client.tools = tools
        conv.receipts_source = lambda: {
            user_mid_holder[0]: [{"summary": "日历核对完成", "tool": "calendar_read"}]
        }

        last_rev = conv.snapshot()["revision"]

        def on_notify():
            nonlocal last_rev
            change = conv.changes_since(last_rev)
            if change["revision"] > last_rev:
                last_rev = change["revision"]
                broadcaster.publish("update", change)

        conv._on_notify.append(on_notify)
        await broadcaster._add_subscriber(subscriber_q)

        user_mid_holder: list[str] = [""]
        t_submit = time.perf_counter()
        sub = conv.submit("req-interleaved-0001", "帮我查今天日历并生成一份今日复盘文档")
        user_mid_holder[0] = sub["message_id"]

        run_task = asyncio.create_task(conv.process_one())

        # 验证第一条确认气泡在工具还没跑完前就已经通过 SSE 实时推达！
        ack_bubble_frame = None
        while ack_bubble_frame is None:
            ev = await asyncio.wait_for(subscriber_q.get(), timeout=2.0)
            if ev.event_type == "update":
                for m in ev.data.get("messages", []):
                    if m.get("role") == "assistant":
                        ack_bubble_frame = m
                        timings["ack_sse_ms"] = (time.perf_counter() - t_submit) * 1000.0
                        break

        assert not run_task.done(), "确认气泡到达时后台工具链应当仍在运行中（不等工具跑完）"
        assert ack_bubble_frame["text"] == "收到，我先帮你查今天日历并整理复盘文档。"
        assert ack_bubble_frame["bubble_type"] == "text"
        assert timings["ack_sse_ms"] < 120.0

        await run_task
        timings["total_turn_ms"] = (time.perf_counter() - t_submit) * 1000.0
        print(
            f"[SENDMESSAGE_METRIC] ack_sse_ms={timings['ack_sse_ms']:.2f}ms "
            f"total_turn_ms={timings['total_turn_ms']:.2f}ms"
        )
        assert timings["total_turn_ms"] >= 350.0
        assert timings["ack_sse_ms"] < timings["total_turn_ms"] * 0.25

        snap = conv.snapshot()
        assert "<system_reminder>" in seen_prompts[0]
        # 用户落库原文绝不能被 <system_reminder> 污染
        user_msg = next(m for m in snap["messages"] if m["id"] == sub["message_id"])
        assert "<system_reminder>" not in user_msg["text"]
        assert user_msg["status"] == "completed"

        bubbles = [m for m in snap["messages"] if m["role"] == "assistant"]
        assert len(bubbles) == 4
        assert [b["bubble_type"] for b in bubbles] == ["text", "text", "attachment", "text"]

        # 严格单调递增的 message_seq > 0（兼容 iOS ChatTimeline 比较器）
        seqs = [user_msg["message_seq"], *[b["message_seq"] for b in bubbles]]
        assert all(s > 0 for s in seqs)
        assert seqs == sorted(set(seqs))

        # 普通文本输出完全不出现在用户可见气泡中，但保存在内部思考表
        for b in bubbles:
            assert "内部思考" not in b["text"]
            assert "内部收尾思考" not in b["text"]
            assert "# 今日复盘" not in b["text"]
        thinking = conv.send_store.thinking_logs(sub["message_id"])
        assert len(thinking) >= 2
        assert any("内部思考" in item["content"] for item in thinking)
        assert any("内部收尾思考" in item["content"] for item in thinking)

        # 附件气泡走 SHA-256 内容寻址 + ArtifactAccess 下载路径
        att_bubble = bubbles[2]
        assert att_bubble["bubble"]["sha256"] == timings["expected_sha256"]
        assert att_bubble["bubble"]["download_path"].startswith("/personal/artifacts/art_")
        assert len(att_bubble["artifacts"]) == 1
        cas_file = state / att_bubble["bubble"]["cas_relpath"]
        assert cas_file.is_file()

        # 末条气泡带 suggestions，且操作回执只挂在末条气泡上（不重复挂在前三条）
        assert bubbles[3]["suggestions"] == ["设个三点提醒", "看明天安排"]
        assert "receipts" not in bubbles[0]
        assert "receipts" not in bubbles[1]
        assert "receipts" not in bubbles[2]
        assert bubbles[3]["receipts"] == [{"summary": "日历核对完成", "tool": "calendar_read"}]

        # receipt() 与 turn_record() 返回最后一条最终结果气泡
        rcpt = conv.receipt("req-interleaved-0001")
        assert rcpt is not None and rcpt["reply"].startswith("全部办妥")
        trec = conv.turn_record(sub["message_id"])
        assert trec is not None and trec["reply"].startswith("全部办妥")

    asyncio.run(scenario())


# ---------------------------------------------------------------------------
# 3. Schema 枚举与跨字段强校验：拦截坏参数、返回模型可自修提示、脏输出零落库
# ---------------------------------------------------------------------------
def test_schema_and_cross_field_validation_bounces_bad_calls(tmp_path: Path):
    state = tmp_path / "state"
    workspace = tmp_path / "AI_Work_System"
    state.mkdir()
    (workspace / "work").mkdir(parents=True)
    enable_send_message_flag(state)

    conv = PersonalConversation(state)
    tools = build_agent_tools(state, workspace, conv)
    sub = conv.submit("req-validate-0001", "发几个不同类型的气泡")
    conv._set(sub["message_id"], "running", phase="thinking", received=True)
    conv.send_store.open_turn(sub["message_id"], "com-hermes-main", "req-validate-0001")
    ctx = {
        "origin_session_id": "com-hermes-main",
        "origin_message_id": sub["message_id"],
        "origin_request_id": "req-validate-0001",
    }

    # 1) cursor-agent 明确拒绝
    with pytest.raises(SendMessageValidationError, match="cursor-agent"):
        asyncio.run(tools.call("send_message", {"type": "cursor-agent", "content": "x"}, ctx))

    # 2) 枚举外 type 拒绝
    with pytest.raises(SendMessageValidationError, match="未知的 type"):
        asyncio.run(tools.call("send_message", {"type": "markdown", "content": "x"}, ctx))

    # 3) text 缺 content 或混带 url / widget
    with pytest.raises(SendMessageValidationError, match="非空的 content"):
        asyncio.run(tools.call("send_message", {"type": "text", "content": "   "}, ctx))
    with pytest.raises(SendMessageValidationError, match="不能混带 url"):
        asyncio.run(
            tools.call(
                "send_message",
                {"type": "text", "content": "看这个", "url": "https://example.com/a.pdf"},
                ctx,
            )
        )

    # 4) attachment 裸路径、http 明文协议、或混塞 content 正文一律拒绝
    with pytest.raises(SendMessageValidationError, match="协议不合法"):
        asyncio.run(tools.call("send_message", {"type": "attachment", "url": "work/a.pdf"}, ctx))
    with pytest.raises(SendMessageValidationError, match="协议不合法"):
        asyncio.run(tools.call("send_message", {"type": "attachment", "url": "http://example.com/a.pdf"}, ctx))
    with pytest.raises(SendMessageValidationError, match="禁止传 content"):
        asyncio.run(
            tools.call(
                "send_message",
                {"type": "attachment", "url": "https://example.com/a.pdf", "content": "文件内容全文..."},
                ctx,
            )
        )

    # 5) 隐藏文件与软链接拒绝
    hidden = workspace / ".secret.md"
    hidden.write_text("hidden")
    with pytest.raises(SendMessageValidationError, match="隐藏"):
        asyncio.run(tools.call("send_message", {"type": "attachment", "url": f"file://{hidden}"}, ctx))

    real_md = workspace / "work" / "ok.md"
    real_md.write_text("ok")
    symlink_md = workspace / "work" / "link.md"
    symlink_md.symlink_to(real_md)
    with pytest.raises(SendMessageValidationError, match="符号链接"):
        asyncio.run(tools.call("send_message", {"type": "attachment", "url": f"file://{symlink_md}"}, ctx))

    # 6) widget 缺 options / secret-request 夹带明文密钥拒绝
    with pytest.raises(SendMessageValidationError, match="options"):
        asyncio.run(
            tools.call(
                "send_message",
                {"type": "widget", "widget": {"kind": "picker", "title": "选一个", "options": []}},
                ctx,
            )
        )
    with pytest.raises(SendMessageValidationError, match="明文密钥"):
        asyncio.run(
            tools.call(
                "send_message",
                {"type": "secret-request", "secret_name": "API_KEY", "reason": "测试", "secret_value": "sk-123"},
                ctx,
            )
        )

    # 校验失败绝不污染 messages 表
    assert [m for m in conv.snapshot()["messages"] if m["role"] == "assistant"] == []

    # 模型根据报错修正参数后下一步调用成功
    res = asyncio.run(
        tools.call(
            "send_message",
            {"type": "attachment", "url": "https://example.com/spec.pdf", "caption": "外部参考规范"},
            ctx,
        )
    )
    assert res["ok"] is True
    assistants = [m for m in conv.snapshot()["messages"] if m["role"] == "assistant"]
    assert len(assistants) == 1
    assert assistants[0]["bubble_type"] == "attachment"
    assert assistants[0]["bubble"]["scheme"] == "https"


# ---------------------------------------------------------------------------
# 4. 会话状态机：发出 widget 或 secret-request 后进入 awaiting_user，同轮后续禁发
# ---------------------------------------------------------------------------
def test_session_state_machine_blocks_after_widget_and_secret_request(tmp_path: Path):
    state = tmp_path / "state"
    workspace = tmp_path / "AI_Work_System"
    state.mkdir()
    workspace.mkdir()
    enable_send_message_flag(state)

    conv = PersonalConversation(state)
    tools = build_agent_tools(state, workspace, conv)

    # 场景 A：发出 picker widget 后同轮再调 send_message 被硬拦截
    u1 = conv.submit("req-state-widget-01", "帮我记一笔 88 元晚饭")
    conv._set(u1["message_id"], "running", phase="thinking", received=True)
    conv.send_store.open_turn(u1["message_id"], "com-hermes-main", "req-state-widget-01")
    ctx1 = {
        "origin_session_id": "com-hermes-main",
        "origin_message_id": u1["message_id"],
        "origin_request_id": "req-state-widget-01",
    }
    first = asyncio.run(
        tools.call(
            "send_message",
            {
                "type": "widget",
                "content": "这笔晚饭记在哪个账户？",
                "widget": {
                    "kind": "picker",
                    "title": "选择记账账户",
                    "options": ["招商银行储蓄卡", "微信零钱"],
                },
            },
            ctx1,
        )
    )
    assert first["turn_state"] == "awaiting_user"

    with pytest.raises(SendMessageStateError, match="awaiting_user"):
        asyncio.run(
            tools.call(
                "send_message",
                {"type": "text", "content": "不等你选了，我先记招行卡了"},
                ctx1,
            )
        )

    # 场景 B：发出 secret-request 后同轮再调 send_message 同样被硬拦截
    u2 = conv.submit("req-state-secret-02", "连接飞书文档")
    conv._set(u2["message_id"], "running", phase="thinking", received=True)
    conv.send_store.open_turn(u2["message_id"], "com-hermes-main", "req-state-secret-02")
    ctx2 = {
        "origin_session_id": "com-hermes-main",
        "origin_message_id": u2["message_id"],
        "origin_request_id": "req-state-secret-02",
    }
    sec = asyncio.run(
        tools.call(
            "send_message",
            {
                "type": "secret-request",
                "secret_name": "FEISHU_APP_SECRET",
                "reason": "读取飞书知识库文档需要应用凭据",
            },
            ctx2,
        )
    )
    assert sec["turn_state"] == "awaiting_user"

    with pytest.raises(SendMessageStateError, match="awaiting_user"):
        asyncio.run(tools.call("send_message", {"type": "text", "content": "继续追问一句"}, ctx2))

    bubbles = [m for m in conv.snapshot()["messages"] if m["role"] == "assistant"]
    assert len(bubbles) == 2
    assert bubbles[0]["bubble_type"] == "widget"
    assert bubbles[0]["widgets"][0]["kind"] == "picker"
    assert bubbles[1]["bubble_type"] == "secret-request"
    assert bubbles[1]["bubble"]["masked"] is True


# ---------------------------------------------------------------------------
# 5. 进度提醒中间件：连续 N=4 次非 send_message 工具调用自动注入催报提醒
# ---------------------------------------------------------------------------
def test_progress_reminder_middleware_injects_after_threshold(tmp_path: Path):
    state = tmp_path / "state"
    workspace = tmp_path / "AI_Work_System"
    state.mkdir()
    workspace.mkdir()
    enable_send_message_flag(state, remind_after=4)

    injected_reminders: list[str] = []

    class SilentToolsClient:
        runtime_name = "hermes"
        session_key = "hermes_v2_session_id"
        has_native_history = True

        def __init__(self):
            self.conv: PersonalConversation | None = None
            self.tools: AgentTools | None = None

        def key(self) -> str:
            return "test-key"

        async def create_session(self) -> str:
            return "com-hermes-main"

        async def inject_reminder(self, session_id: str, reminder_text: str) -> dict:
            injected_reminders.append(reminder_text)
            return {"state": "injected"}

        async def stream_chat(self, session_id: str, text: str):
            assert self.conv is not None and self.tools is not None
            mid = self.conv.active_user_message()
            assert mid is not None
            with self.conv.db() as db:
                req_id = db.execute("SELECT request_id FROM messages WHERE id=?", (mid,)).fetchone()["request_id"]
            ctx = {"origin_session_id": session_id, "origin_message_id": mid, "origin_request_id": req_id}

            yield "run.started", {"run_id": "run_silent_tools"}
            yield "input.delivered", {"request_id": req_id, "run_id": "run_silent_tools"}

            # 连续 4 次非 send_message 工具调用
            for i, tname in enumerate(["tool_search", "tool_describe", "calendar_read", "memory_recall"], start=1):
                yield "tool.started", {"tool_name": tname, "tool_call_id": f"c-{i}"}
                yield "tool.completed", {"tool_name": tname, "tool_call_id": f"c-{i}"}

            # 收到中间件提醒后，模型发起真实 send_message 汇报进度并收尾
            assert len(injected_reminders) == 1
            yield "tool.started", {"tool_name": "tool_call", "tool_call_id": "c-send"}
            await self.tools.call(
                "send_message",
                {"type": "text", "content": "刚查完日历和历史记忆，马上给你汇总。"},
                ctx,
            )
            yield "tool.completed", {"tool_name": "tool_call", "tool_call_id": "c-send"}

            # 再跑 2 次工具不应误触发第二次提醒（计数已被 send_message 归零）
            for i in (5, 6):
                yield "tool.started", {"tool_name": "context_read", "tool_call_id": f"c-{i}"}
                yield "tool.completed", {"tool_name": "context_read", "tool_call_id": f"c-{i}"}

            await self.tools.call(
                "send_message",
                {"type": "text", "content": "汇总完毕：今天日程清爽，无冲突。"},
                ctx,
            )
            yield "run.completed", {"run_id": "run_silent_tools"}
            yield "done", {}

    async def scenario():
        client = SilentToolsClient()
        conv = PersonalConversation(state, client)
        tools = build_agent_tools(state, workspace, conv)
        client.conv = conv
        client.tools = tools

        sub = conv.submit("req-remind-0001", "帮我深度核对日历和记忆")
        await conv.process_one()
        assert len(injected_reminders) == 1
        assert "<system_reminder>" in injected_reminders[0]
        assert "连续执行 4 次工具调用" in injected_reminders[0]
        turn_meta = conv.send_store.get_turn(sub["message_id"])
        assert turn_meta is not None and turn_meta["reminder_count"] == 1
        bubbles = [m for m in conv.snapshot()["messages"] if m["role"] == "assistant"]
        assert len(bubbles) == 2

    asyncio.run(scenario())


# ---------------------------------------------------------------------------
# 6. 中途追发消息事件队列（OpenHands 模式 + 压哨未消费自动回退重排零丢消息）
# ---------------------------------------------------------------------------
def test_mid_turn_followup_event_queue_and_boundary_race_requeue(tmp_path: Path):
    state = tmp_path / "state"
    workspace = tmp_path / "AI_Work_System"
    state.mkdir()
    workspace.mkdir()
    enable_send_message_flag(state)

    seen_lanes: list[tuple[int, str]] = []
    steered_inputs: list[tuple[str, str]] = []

    class EventQueueRuntime:
        runtime_name = "hermes"
        session_key = "hermes_v2_session_id"
        has_native_history = True

        def __init__(self, lane_num: int = 0):
            self.lane_num = lane_num
            self.conv: PersonalConversation | None = None
            self.tools: AgentTools | None = None
            self.mid_steer_ready = asyncio.Event()
            self.race_gate = asyncio.Event()
            self._turn_index = 0

        def lane(self, n: int):
            clone = EventQueueRuntime(n)
            clone.conv = self.conv
            clone.tools = self.tools
            return clone

        def key(self) -> str:
            return "test-key"

        async def create_session(self) -> str:
            return "com-hermes-main"

        async def steer_chat(self, session_id: str, text: str, request_id: str, context: dict) -> dict:
            steered_inputs.append((request_id, text))
            if request_id == "req-followup-0002":
                self.mid_steer_ready.set()
                return {"state": "delivered", "run_id": "run_turn_1"}
            if request_id == "req-race-0003":
                # 模拟压哨竞态：已被推入 steer 队列（worker_queued），但本轮恰好在消费前结束
                self.race_gate.set()
                return {"state": "worker_queued", "run_id": "run_turn_1"}
            return {"state": "not_sent"}

        async def stream_chat(self, session_id: str, text: str):
            assert self.conv is not None and self.tools is not None
            self._turn_index += 1
            seen_lanes.append((self.lane_num, text))

            if self._turn_index == 1:
                u1_id = "req-main-0001"
                with self.conv.db() as db:
                    mid = db.execute("SELECT id FROM messages WHERE request_id=?", (u1_id,)).fetchone()["id"]
                ctx = {"origin_session_id": session_id, "origin_message_id": mid, "origin_request_id": u1_id}

                yield "run.started", {"run_id": "run_turn_1"}
                yield "input.delivered", {"request_id": u1_id, "run_id": "run_turn_1"}

                # Step 1: 立即发确认气泡并开始跑工具
                await self.tools.call(
                    "send_message",
                    {"type": "text", "content": "收到，正在查今天日程。"},
                    ctx,
                )
                yield "tool.started", {"tool_name": "calendar_read", "tool_call_id": "t-1"}
                # 等待用户中途自然追发第 2 条消息（无“补充：”前缀！）
                await asyncio.wait_for(self.mid_steer_ready.wait(), timeout=3.0)
                yield "tool.completed", {"tool_name": "calendar_read", "tool_call_id": "t-1"}
                yield "input.delivered", {"request_id": "req-followup-0002", "run_id": "run_turn_1"}

                # Step 2 (下一 Agent.step): 一并处理原请求 + 追发的“晚上七点健身”
                await self.tools.call(
                    "send_message",
                    {"type": "text", "content": "今天日程已整理好，并且顺手把晚上 19:00 健身也加进去了！"},
                    ctx,
                )

                # 模拟第 3 条消息在最后收尾瞬间压哨到达（落入 pending_steer 未被本轮消费）
                self.conv.submit("req-race-0003", "再帮我列一下下周出差要带的充电器")
                await asyncio.wait_for(self.race_gate.wait(), timeout=3.0)
                yield "run.completed", {
                    "run_id": "run_turn_1",
                    "unconsumed_supplements": ["req-race-0003"],
                }
                yield "done", {}
            else:
                # 第 2 轮：验证压哨未消费的 req-race-0003 自动回退为 queued 并被紧接着完整处理！
                u3_id = "req-race-0003"
                with self.conv.db() as db:
                    mid3 = db.execute("SELECT id FROM messages WHERE request_id=?", (u3_id,)).fetchone()["id"]
                ctx3 = {"origin_session_id": session_id, "origin_message_id": mid3, "origin_request_id": u3_id}
                yield "run.started", {"run_id": "run_turn_2"}
                yield "input.delivered", {"request_id": u3_id, "run_id": "run_turn_2"}
                await self.tools.call(
                    "send_message",
                    {"type": "text", "content": "下周出差充电器清单已备好：氮化镓快充头 + 双 C 口线。"},
                    ctx3,
                )
                yield "run.completed", {"run_id": "run_turn_2"}
                yield "done", {}

    async def scenario():
        runtime = EventQueueRuntime(0)
        conv = PersonalConversation(state, runtime)
        tools = build_agent_tools(state, workspace, conv)
        runtime.conv = conv
        runtime.tools = tools

        conv.start()
        try:
            t_u1 = time.perf_counter()
            u1 = conv.submit("req-main-0001", "帮我查今天日历并整理一份出差行李清单")
            # 等确认气泡发出（说明 Turn 1 正在工具执行中）
            await until(
                lambda: any(
                    m["role"] == "assistant" and "正在查今天日程" in m["text"]
                    for m in conv.snapshot()["messages"]
                )
            )
            # 用户中途自然追发一句（没有任何“补充：/改成”前缀！）
            t_u2 = time.perf_counter()
            u2 = conv.submit("req-followup-0002", "顺便把晚上七点健身也加上")

            # 等待全部三条用户消息（含压哨重排的第 3 条）都变为 completed
            await until(
                lambda: len([m for m in conv.snapshot()["messages"] if m["role"] == "user" and m["status"] == "completed"]) == 3
            )
            print(
                f"[FOLLOWUP_METRIC] u1_to_all3_done_ms={(time.perf_counter() - t_u1) * 1000.0:.2f}ms "
                f"u2_to_all3_done_ms={(time.perf_counter() - t_u2) * 1000.0:.2f}ms"
            )

            snap = conv.snapshot()
            # 验证没有拆去孤立的 -p1 分身（全部走主线 lane 0）
            assert [lane for lane, _ in seen_lanes] == [0, 0]
            assert any(req == "req-followup-0002" and "<system_reminder>" in txt for req, txt in steered_inputs)

            # 验证时间线顺序：u1 -> 确认气泡 -> u2(中途追发) -> 合并结果气泡 -> u3(压哨追发) -> 出差充电器气泡
            ordered_roles_texts = [(m["role"], m["text"], m["message_seq"]) for m in snap["messages"]]
            seqs = [item[2] for item in ordered_roles_texts]
            assert seqs == sorted(set(seqs))
            texts = [item[1] for item in ordered_roles_texts]
            assert texts.index("收到，正在查今天日程。") < texts.index("顺便把晚上七点健身也加上")
            assert texts.index("顺便把晚上七点健身也加上") < texts.index(
                "今天日程已整理好，并且顺手把晚上 19:00 健身也加进去了！"
            )
            assert any("氮化镓快充头" in t for t in texts)

            # 零丢消息：三条用户消息全部是 completed，没有任何一条卡在 unknown
            for m in snap["messages"]:
                if m["role"] == "user":
                    assert m["status"] == "completed", f"消息 {m['request_id']} 状态异常: {m}"
        finally:
            await conv.stop()

    asyncio.run(scenario())


# ---------------------------------------------------------------------------
# 7. 零气泡收尾单次自愈守卫：模型忘了调 send_message 时自动续跑补发一次
# ---------------------------------------------------------------------------
def test_zero_bubble_turn_triggers_one_shot_self_repair(tmp_path: Path):
    state = tmp_path / "state"
    workspace = tmp_path / "AI_Work_System"
    state.mkdir()
    workspace.mkdir()
    enable_send_message_flag(state)

    repair_calls: list[str] = []

    class ForgetfulClient:
        runtime_name = "hermes"
        session_key = "hermes_v2_session_id"
        has_native_history = True

        def __init__(self):
            self.conv: PersonalConversation | None = None
            self.tools: AgentTools | None = None

        def key(self) -> str:
            return "test-key"

        async def create_session(self) -> str:
            return "com-hermes-main"

        async def repair_missing_send_message(self, session_id: str, parent_request_id: str, context: dict) -> None:
            repair_calls.append(parent_request_id)
            assert self.tools is not None
            await self.tools.call(
                "send_message",
                {"type": "text", "content": "已通过自愈补发：明天上午十点没有会议冲突。"},
                context,
            )

        async def stream_chat(self, session_id: str, text: str):
            assert self.conv is not None
            mid = self.conv.active_user_message()
            with self.conv.db() as db:
                req_id = db.execute("SELECT request_id FROM messages WHERE id=?", (mid,)).fetchone()["request_id"]
            yield "run.started", {"run_id": "run_forgetful_1"}
            yield "input.delivered", {"request_id": req_id, "run_id": "run_forgetful_1"}
            yield "assistant.completed", {"content": "我只在思考里回答了，忘了调工具"}
            yield "run.completed", {"run_id": "run_forgetful_1"}
            yield "done", {}

    async def scenario():
        client = ForgetfulClient()
        conv = PersonalConversation(state, client)
        tools = build_agent_tools(state, workspace, conv)
        client.conv = conv
        client.tools = tools

        sub = conv.submit("req-repair-0001", "明天十点有会吗")
        await conv.process_one()
        assert repair_calls == ["req-repair-0001"]
        snap = conv.snapshot()
        user_msg = next(m for m in snap["messages"] if m["id"] == sub["message_id"])
        assert user_msg["status"] == "completed"
        bubbles = [m for m in snap["messages"] if m["role"] == "assistant"]
        assert len(bubbles) == 1
        assert bubbles[0]["text"] == "已通过自愈补发：明天上午十点没有会议冲突。"

    asyncio.run(scenario())


# ---------------------------------------------------------------------------
# 8. HermesRuntime pending_steer 解析清理 + MCP send_message 紧凑 Schema 验真
# ---------------------------------------------------------------------------
def test_hermes_runtime_unconsumed_extraction_and_mcp_schema_compaction(tmp_path: Path):
    import sqlite3
    import hermes_mcp
    from hermes_metrics.source_binding import SOURCE_TOOLS

    assert "send_message" in SOURCE_TOOLS

    mcp_tools = {t.name: t for t in hermes_mcp.mcp._tool_manager.list_tools()}
    assert "send_message" in mcp_tools
    send_schema = mcp_tools["send_message"].parameters
    props = send_schema.get("properties", {})
    assert "type" in props
    # 宿主自动绑定的 origin IDs 已在模型可见 JSON Schema 中剥离，但真实校验仍保留
    for hidden_id in ("origin_session_id", "origin_message_id", "origin_request_id"):
        assert hidden_id not in props

    rt = HermesRuntime(tmp_path, "system prompt")
    with sqlite3.connect(rt.path) as db:
        db.execute(
            "INSERT INTO steering VALUES(?,?,?,?)",
            ("req-race-99", "run_1", "[Com supplement req-race-99]\nhi", "uncertain"),
        )
    unconsumed = rt._extract_unconsumed_supplements(
        [{"input": "[Com supplement req-race-99]\n补充内容\n\n<system_reminder>..."}]
    )
    assert unconsumed == ["req-race-99"]
    with sqlite3.connect(rt.path) as db:
        state_val = db.execute("SELECT state FROM steering WHERE request_id='req-race-99'").fetchone()[0]
    assert state_val == "unconsumed"

    rt.clear_unconsumed_steer("req-race-99")
    with sqlite3.connect(rt.path) as db:
        left = db.execute("SELECT COUNT(*) FROM steering WHERE request_id='req-race-99'").fetchone()[0]
    assert left == 0

