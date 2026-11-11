"""Adversarial Challenge Test Harness for Personal Agent Capabilities, Tools, Memory & Summary.

Empirical verification suite challenging:
1. Tool calling corner cases (invalid/millisecond timestamps, malformed args, missing fields)
2. Dual-write requirement on reminder_add (WeChat queue + Apple Calendar with 【分类】前缀)
3. Post-call summary pipeline under abnormal scenarios (empty, 100 turns, conflicting dates)
4. MemoryCatalog updates (confidence score thresholds, quote provenance, credential rejection)
"""

import asyncio
from datetime import datetime, timedelta
import json
from pathlib import Path
import re
import sys
import time
from typing import Any
import uuid
from zoneinfo import ZoneInfo
import pytest

from business_tools import BusinessTools
from conversation import PersonalConversation
from conversation_summary import (
    ConversationSummary,
    extract_rule_based_summary,
    post_call_summary_pipeline,
)
from memory_catalog import MemoryCatalog
from voice_live import execute_live_tool

TZ = ZoneInfo("Asia/Shanghai")


class DummyRuntime:
    runtime_name = "hermes"


def run_async(coro):
    return asyncio.run(coro)


# ==============================================================================
# Challenge 1: Tool Calling Corner Cases (Strict Validation & Malformed Inputs)
# ==============================================================================


def test_challenge_01_bookkeeping_add_rejects_millisecond_timestamp(tmp_path: Path):
    """CHALLENGE 1.1: Verify bookkeeping_add strictly rejects millisecond timestamps (> 1e11).

    Must raise ValueError with explicit message indicating millisecond overflow.
    """
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    # 1.3-trillion timestamp (representing ms timestamp in Nov 2023: 1700000000000)
    ms_timestamp = 1700000000000

    with pytest.raises(ValueError) as exc_info:
        run_async(
            execute_live_tool(
                "bookkeeping_add",
                {"amount": 35.0, "item": "午餐", "time": ms_timestamp},
                state=state_dir,
            )
        )

    err_msg = str(exc_info.value)
    assert "秒级整型" in err_msg or "毫秒级" in err_msg
    assert "溢出" in err_msg or "1.7e+12" in err_msg or "1700000000000" in err_msg


def test_challenge_02_bookkeeping_add_rejects_invalid_timestamp_formats(tmp_path: Path):
    """CHALLENGE 1.2: Verify bookkeeping_add strictly rejects invalid non-numeric timestamps."""
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    invalid_timestamps = [
        "not-a-timestamp",
        "2026-11-10T12:00:00",  # ISO string should be rejected if raw timestamp expected
        "1.2.3.4",
        [1731175200],
    ]

    for inv in invalid_timestamps:
        with pytest.raises(ValueError) as exc_info:
            run_async(
                execute_live_tool(
                    "bookkeeping_add",
                    {"amount": 50.0, "item": "打车", "time": inv},
                    state=state_dir,
                )
            )
        assert "无效时间戳" in str(exc_info.value) or "could not convert" in str(exc_info.value)


def test_challenge_03_bookkeeping_add_accepts_valid_second_timestamps(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """CHALLENGE 1.3: Verify bookkeeping_add accepts valid integer & float second timestamps."""
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    # Mock bt.bookkeeping to capture incoming time parameter
    recorded_args = []

    async def mock_bookkeeping(self, args: dict[str, Any]) -> dict[str, Any]:
        recorded_args.append(dict(args))
        return {
            "verified": True,
            "id": "tx_test_01",
            "amount": float(args.get("amount", 0)),
            "source": "ezBookkeeping",
        }

    monkeypatch.setattr(BusinessTools, "bookkeeping", mock_bookkeeping)

    # 1. Integer second timestamp
    sec_ts = 1794276000  # 2026-11-10 02:00:00 UTC+8
    title, res = run_async(
        execute_live_tool(
            "bookkeeping_add",
            {"amount": 28.5, "item": "咖啡", "time": sec_ts},
            state=state_dir,
        )
    )
    assert res["time_seconds"] == sec_ts
    assert recorded_args[-1]["time"].startswith("2026-11-")

    # 2. Float second timestamp with decimals (e.g. 1731175200.75)
    title2, res2 = run_async(
        execute_live_tool(
            "bookkeeping_add",
            {"amount": 45.0, "item": "午餐", "time": 1731175200.75},
            state=state_dir,
        )
    )
    assert res2["time_seconds"] == 1731175200

    # 3. None / missing timestamp defaults to current second timestamp
    before = int(time.time())
    title3, res3 = run_async(
        execute_live_tool(
            "bookkeeping_add",
            {"amount": 10.0, "item": "矿泉水"},
            state=state_dir,
        )
    )
    after = int(time.time())
    assert before <= res3["time_seconds"] <= after


def test_challenge_04_bookkeeping_add_rejects_negative_or_zero_amount(tmp_path: Path):
    """CHALLENGE 1.4: Verify bookkeeping_add rejects <= 0 or malformed amounts."""
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    # Missing amount or zero amount
    with pytest.raises(ValueError):
        run_async(
            execute_live_tool(
                "bookkeeping_add",
                {"amount": 0, "item": "免费礼物"},
                state=state_dir,
            )
        )

    # Negative amount
    with pytest.raises(ValueError):
        run_async(
            execute_live_tool(
                "bookkeeping_add",
                {"amount": -50.0, "item": "退款"},
                state=state_dir,
            )
        )


def test_challenge_05_reminder_add_rejects_empty_text_and_invalid_time(tmp_path: Path):
    """CHALLENGE 1.5: Verify reminder_add rejects empty text or past/negative times."""
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    # Empty text
    with pytest.raises(ValueError, match="Reminder text required"):
        run_async(
            execute_live_tool(
                "reminder_add",
                {"text": "   ", "in_minutes": 10},
                state=state_dir,
            )
        )

    # Non-positive in_minutes without at
    with pytest.raises(ValueError, match="Reminder time required"):
        run_async(
            execute_live_tool(
                "reminder_add",
                {"text": "测试提醒", "in_minutes": -5},
                state=state_dir,
            )
        )

    # Past time in 'at' parameter
    past_str = "2020-01-01 08:00"
    with pytest.raises(ValueError, match="Reminder time is in the past"):
        run_async(
            execute_live_tool(
                "reminder_add",
                {"text": "过去提醒", "at": past_str},
                state=state_dir,
            )
        )


def test_challenge_06_calendar_action_malformed_arguments(tmp_path: Path):
    """CHALLENGE 1.6: Verify calendar_action strictly rejects invalid dates."""
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    # Malformed date format
    with pytest.raises(ValueError):
        run_async(
            execute_live_tool(
                "calendar_action",
                {"action": "create", "summary": "评审会", "date": "11-10-2026"},
                state=state_dir,
            )
        )


def test_challenge_07_unknown_tool_and_unready_services(tmp_path: Path):
    """CHALLENGE 1.7: Verify unknown tools and unready services fail gracefully."""
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    # Unknown tool
    title, res = run_async(execute_live_tool("nonexistent_hack_tool", {}, state=state_dir))
    assert "未知工具" in res.get("error", "")

    # ask_com_main with None conversation
    title, res = run_async(execute_live_tool("ask_com_main", {"instruction": "查询"}, state=state_dir, conversation=None))
    assert res.get("ok") is False
    assert "会话未就绪" in res.get("error", "")

    # next_steps_action with None service
    title, res = run_async(execute_live_tool("next_steps_action", {"action": "list"}, state=state_dir, next_steps_service=None))
    assert "服务未就绪" in res.get("error", "")


# ==============================================================================
# Challenge 2: Dual-Write Requirement on reminder_add
# ==============================================================================


def test_challenge_08_reminder_add_dual_write_targeting_and_formatting(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """CHALLENGE 2.1: Verify reminder_add executes dual-write to WeChat queue AND Apple Calendar.

    Specifically verifies calendar title is formatted with strict 【分类】前缀.
    """
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    remind_calls = []
    calendar_calls = []

    async def mock_remind(self, args: dict[str, Any]) -> dict[str, Any]:
        remind_calls.append(dict(args))
        return {
            "verified": True,
            "id": "rm_wechat_001",
            "item": {"text": args.get("text"), "status": "pending"},
        }

    async def mock_calendar(self, args: dict[str, Any]) -> dict[str, Any]:
        calendar_calls.append(dict(args))
        return {
            "verified": True,
            "event_id": "cal_apple_001",
            "summary": args.get("summary"),
            "date": args.get("date"),
        }

    monkeypatch.setattr(BusinessTools, "remind", mock_remind)
    monkeypatch.setattr(BusinessTools, "calendar", mock_calendar)

    # Case A: Default category (提醒) without explicit summary
    title_a, res_a = run_async(
        execute_live_tool(
            "reminder_add",
            {"text": "下班取快递", "in_minutes": 60},
            state=state_dir,
        )
    )
    assert res_a["dual_write"] is True
    assert res_a["calendar_summary"] == "【提醒】下班取快递"
    assert len(remind_calls) == 1
    assert remind_calls[-1]["text"] == "下班取快递"
    assert len(calendar_calls) == 1
    assert calendar_calls[-1]["summary"] == "【提醒】下班取快递"

    # Case B: Custom category (会议)
    title_b, res_b = run_async(
        execute_live_tool(
            "reminder_add",
            {"text": "项目周会", "category": "会议", "in_minutes": 30},
            state=state_dir,
        )
    )
    assert res_b["dual_write"] is True
    assert res_b["calendar_summary"] == "【会议】项目周会"
    assert calendar_calls[-1]["summary"] == "【会议】项目周会"

    # Case C: Text already contains bracketed category: do not double-bracket
    title_c, res_c = run_async(
        execute_live_tool(
            "reminder_add",
            {"text": "【工作】提交季度OKR", "in_minutes": 15},
            state=state_dir,
        )
    )
    assert res_c["dual_write"] is True
    assert res_c["calendar_summary"] == "【工作】提交季度OKR"
    assert not res_c["calendar_summary"].startswith("【提醒】【工作】")

    # Case D: Explicit summary provided without bracket
    title_d, res_d = run_async(
        execute_live_tool(
            "reminder_add",
            {"text": "备忘事项", "summary": "跟进预算审批", "category": "财务", "in_minutes": 20},
            state=state_dir,
        )
    )
    assert res_d["dual_write"] is True
    assert res_d["calendar_summary"] == "【财务】跟进预算审批"


def test_challenge_09_reminder_add_dual_write_calendar_failure_resilience(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """CHALLENGE 2.2: Verify that Apple Calendar failure does not break WeChat queue primary write."""
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    async def mock_remind(self, args: dict[str, Any]) -> dict[str, Any]:
        return {
            "verified": True,
            "id": "rm_wechat_002",
            "item": {"text": args.get("text"), "status": "pending"},
        }

    async def mock_calendar_failing(self, args: dict[str, Any]) -> dict[str, Any]:
        raise RuntimeError("AppleScript Calendar worker connection timeout")

    monkeypatch.setattr(BusinessTools, "remind", mock_remind)
    monkeypatch.setattr(BusinessTools, "calendar", mock_calendar_failing)

    title, res = run_async(
        execute_live_tool(
            "reminder_add",
            {"text": "晚上吃降压药", "in_minutes": 120},
            state=state_dir,
        )
    )
    # Primary remind write must be preserved
    assert res["verified"] is True
    assert res["id"] == "rm_wechat_002"
    # Secondary calendar write error must be captured cleanly
    assert res["dual_write"] is False
    assert "Calendar worker" in res["calendar_error"]


# ==============================================================================
# Challenge 3: Post-Call Summary Pipeline Under Abnormal Scenarios
# ==============================================================================


def test_challenge_10_post_call_summary_empty_conversation(tmp_path: Path):
    """CHALLENGE 3.1: Post-call summary pipeline under empty conversation scenario.

    Zero turns, zero tools, zero emotions. Must not crash with division by zero or index error.
    Must generate valid Markdown and JSON files with proper fallback sections.
    """
    records_dir = tmp_path / "records"
    vault_dir = tmp_path / "vault"
    memory_root = tmp_path / "memory_root"
    events_dir = tmp_path / "events"

    session_id = "sess_empty_" + uuid.uuid4().hex[:8]

    res = run_async(
        post_call_summary_pipeline(
            session_id=session_id,
            turns=[],
            tools_run=[],
            emotions=[],
            records_dir=records_dir,
            vault_dir=vault_dir,
            memory_root=memory_root,
            events_dir=events_dir,
        )
    )

    assert res["session_id"] == session_id
    assert res["turns_count"] == 0
    assert res["dominant_emotion"] == "calm"
    assert res["tasks_created"] == []
    assert res["facts_persisted"] == []
    assert res["decisions_persisted"] == []

    md_file = Path(res["files"]["markdown"])
    json_file = Path(res["files"]["json"])
    assert md_file.exists()
    assert json_file.exists()

    md_content = md_file.read_text(encoding="utf-8")
    assert "无对话文本" in md_content
    assert "未调用外部业务工具" in md_content
    assert "无新增待办" in md_content
    assert "无新事实沉淀" in md_content
    assert "本轮通话无重大决策变更" in md_content


def test_challenge_11_post_call_summary_100_turns_stress_testing(tmp_path: Path):
    """CHALLENGE 3.2: Post-call summary pipeline under massive 100-turn conversation.

    Verify pipeline survives 100 turns, aggregates 100 emotion packets, audit logs 20 tools,
    completes in sub-second time, and generates cleanly parsed transcript.
    """
    records_dir = tmp_path / "records"
    vault_dir = tmp_path / "vault"
    memory_root = tmp_path / "memory_root"
    events_dir = tmp_path / "events"

    session_id = "sess_100_turns_" + uuid.uuid4().hex[:8]

    # Generate 100 alternating turns
    turns = []
    emotions = []
    emotion_states = ["excited", "calm", "happy", "concerned"]
    for i in range(50):
        turns.append({"role": "user", "text": f"用户第 {i+1} 轮发言：讨论关于模块 {i%5} 的设计", "time": 1000 + i * 2})
        turns.append({"role": "assistant", "text": f"助手第 {i+1} 轮回复：模块 {i%5} 设计已确认", "time": 1000 + i * 2 + 1})
        emotions.append({"state": emotion_states[i % 4], "energy": 0.8})
        emotions.append({"state": "excited", "energy": 0.9})  # Excited is dominant

    # 20 tools run
    tools_run = [
        {"name": "bookkeeping_add", "title": f"记账 ¥{10+j} · 零食{j}", "ok": True}
        for j in range(20)
    ]

    t_start = time.perf_counter()
    res = run_async(
        post_call_summary_pipeline(
            session_id=session_id,
            turns=turns,
            tools_run=tools_run,
            emotions=emotions,
            records_dir=records_dir,
            vault_dir=vault_dir,
            memory_root=memory_root,
            events_dir=events_dir,
        )
    )
    duration = time.perf_counter() - t_start

    assert duration < 1.0  # Must be fast and non-blocking
    assert res["turns_count"] == 50
    assert res["dominant_emotion"] == "excited"
    assert len(res["tools_run"]) == 20

    md_content = Path(res["files"]["markdown"]).read_text(encoding="utf-8")
    assert "**总轮次数**: 50" in md_content
    assert "**主要情绪**: `excited`" in md_content
    assert "用户第 50 轮发言" in md_content
    assert "助手第 50 轮回复" in md_content
    assert "20. `bookkeeping_add`" in md_content


def test_challenge_12_post_call_summary_conflicting_dates_and_no_task_scenarios(tmp_path: Path):
    """CHALLENGE 3.3: Post-call summary under conflicting task dates vs zero tasks.

    Case 1: Chit-chat without tasks -> 0 Obsidian task cards created.
    Case 2: Multiple tasks with conflicting dates (e.g. two 3pm tasks) -> both cards created,
            proper sanitized titles, no silent card stomping.
    """
    records_dir = tmp_path / "records"
    vault_dir = tmp_path / "vault"
    memory_root = tmp_path / "memory_root"
    events_dir = tmp_path / "events"

    # --- Subcase 1: Conversation with NO tasks ---
    no_task_turns = [
        {"role": "user", "text": "今天深圳天气真的很好啊"},
        {"role": "assistant", "text": "是的，阳光很充足，适合外出！"},
        {"role": "user", "text": "刚才那首歌的吉他前奏真好听"},
        {"role": "assistant", "text": "那首是指弹吉他名曲。"},
    ]
    res_no_task = run_async(
        post_call_summary_pipeline(
            session_id="sess_no_task",
            turns=no_task_turns,
            tools_run=[],
            records_dir=records_dir,
            vault_dir=vault_dir,
            memory_root=memory_root,
            events_dir=events_dir,
        )
    )
    assert res_no_task["tasks_created"] == []
    obsidian_pending = vault_dir / "任务" / "待处理"
    if obsidian_pending.exists():
        assert len(list(obsidian_pending.glob("*.md"))) == 0

    # --- Subcase 2: Multiple tasks with conflicting dates ---
    conflicting_turns = [
        {"role": "user", "text": "计划明天下午3点跟李总开会"},
        {"role": "assistant", "text": "好的，已记录明天下午3点李总开会。"},
        {"role": "user", "text": "安排明天下午3点去搜狐大厦录制视频"},  # Conflicting same time
        {"role": "assistant", "text": "好的，已记录明天下午3点录制视频。"},
        {"role": "user", "text": "记得今晚8点前交周报"},
        {"role": "assistant", "text": "收到，今晚8点交周报。"},
    ]
    tool_tasks = [
        {
            "name": "reminder_add",
            "title": "设提醒 · 晚上十点吃降压药",
            "args": {"text": "晚上十点吃降压药", "at": "2026-11-10 22:00"},
            "ok": True,
        },
        {
            "name": "calendar_action",
            "title": "建日程 · 【会议】技术方案评审",
            "args": {"action": "create", "summary": "【会议】技术方案评审", "date": "2026-11-11"},
            "ok": True,
        },
    ]

    res_conflict = run_async(
        post_call_summary_pipeline(
            session_id="sess_conflict",
            turns=conflicting_turns,
            tools_run=tool_tasks,
            records_dir=records_dir,
            vault_dir=vault_dir,
            memory_root=memory_root,
            events_dir=events_dir,
        )
    )

    created_tasks = res_conflict["tasks_created"]
    assert len(created_tasks) >= 4

    # Verify both conflicting 3pm tasks produced separate cards in Obsidian vault
    task_filenames = [Path(p).name for p in created_tasks]
    meeting_card = next((f for f in task_filenames if "跟李总开会" in f), None)
    sohu_card = next((f for f in task_filenames if "录制视频" in f or "去搜狐大厦" in f), None)

    assert meeting_card is not None
    assert sohu_card is not None
    assert meeting_card != sohu_card

    # Verify Markdown cards have valid YAML frontmatter and due dates
    card_text_1 = (vault_dir / "任务" / "待处理" / meeting_card).read_text(encoding="utf-8")
    assert "flow: 任务" in card_text_1
    assert "状态: 待处理" in card_text_1
    assert "计划结束: 明天下午3点" in card_text_1


# ==============================================================================
# Challenge 4: MemoryCatalog Confidence Score Thresholds & Quote Provenance
# ==============================================================================


def test_challenge_13_memory_catalog_confidence_threshold_filter(tmp_path: Path):
    """CHALLENGE 4.1: Verify confidence threshold >= 0.8 strict enforcement.

    Facts with confidence < 0.8 (e.g. 0.79, 0.5, 0.0) MUST NOT be saved into MemoryCatalog.
    Facts with confidence >= 0.8 (e.g. 0.8, 0.95, 1.0) MUST be persisted.
    """
    records_dir = tmp_path / "records"
    vault_dir = tmp_path / "vault"
    memory_root = tmp_path / "memory_root"
    events_dir = tmp_path / "events"

    catalog = MemoryCatalog(memory_root)

    # Inject model that outputs 5 facts with varying confidence scores
    async def mock_model_with_confidence(data: dict[str, Any]) -> dict[str, Any]:
        return {
            "summary": {"goals": [], "preferences": [], "progress": [], "decisions": [], "commitments": [], "context": []},
            "facts": [
                {
                    "category": "关于我",
                    "content": "Eddie 偏好浅烘焙埃塞俄比亚咖啡",
                    "quote": "我喜欢浅烘焙的埃塞",
                    "confidence": 0.95,  # Valid (>= 0.8)
                },
                {
                    "category": "生活",
                    "content": "Eddie 每周二下午去抱石馆攀岩",
                    "quote": "我平时周二下午去攀岩",
                    "confidence": 0.80,  # Valid (>= 0.8 boundary)
                },
                {
                    "category": "关于我",
                    "content": "Eddie 偶尔在晚上喝普洱茶",
                    "quote": "我偶尔晚上喝点普洱",
                    "confidence": 0.79,  # REJECT (< 0.8)
                },
                {
                    "category": "工作",
                    "content": "Eddie 可能在试用新的编辑器",
                    "quote": "可能换个编辑器看看",
                    "confidence": 0.50,  # REJECT (< 0.8)
                },
                {
                    "category": "兴趣",
                    "content": "Eddie 考虑买公路车",
                    "quote": "公路车好像也不错",
                    "confidence": 0.0,   # REJECT (< 0.8)
                },
            ],
        }

    turns = [
        {"role": "user", "text": "我喜欢浅烘焙的埃塞咖啡，周二下午去攀岩"},
        {"role": "assistant", "text": "记下了！"},
    ]

    res = run_async(
        post_call_summary_pipeline(
            session_id="sess_memory_conf",
            turns=turns,
            tools_run=[],
            model=mock_model_with_confidence,
            records_dir=records_dir,
            vault_dir=vault_dir,
            memory_root=memory_root,
            events_dir=events_dir,
        )
    )

    persisted = res["facts_persisted"]
    # Strictly only the 2 facts with confidence >= 0.8 should be persisted
    assert len(persisted) == 2
    persisted_contents = [p["content"] for p in persisted]
    assert "Eddie 偏好浅烘焙埃塞俄比亚咖啡" in persisted_contents
    assert "Eddie 每周二下午去抱石馆攀岩" in persisted_contents
    assert not any("普洱茶" in c for c in persisted_contents)
    assert not any("编辑器" in c for c in persisted_contents)
    assert not any("公路车" in c for c in persisted_contents)

    # Verify actual catalog files on disk
    catalog_items = catalog.list()
    assert len(catalog_items) == 2


def test_challenge_14_memory_catalog_quote_provenance_and_security(tmp_path: Path):
    """CHALLENGE 4.2: Verify MemoryCatalog quote provenance and credential rejection.

    1. Missing quote or missing message_id strictly raises ValueError('Memory needs a real source').
    2. Credentials (passwords, tokens, Bearer, api_key) strictly rejected by regex.
    3. Invalid categories strictly rejected.
    """
    memory_root = tmp_path / "memory_root"
    catalog = MemoryCatalog(memory_root)

    # 1. Missing quote in source dictionary
    with pytest.raises(ValueError, match="Memory needs a real source"):
        catalog.save(
            content="Eddie 偏好极简桌面",
            category="关于我",
            source={"message_id": "m_001", "quote": ""},  # Empty quote
        )

    # 2. Missing message_id in source dictionary
    with pytest.raises(ValueError, match="Memory needs a real source"):
        catalog.save(
            content="Eddie 偏好极简桌面",
            category="关于我",
            source={"message_id": "", "quote": "桌面要极简"},  # Empty message_id
        )

    # 3. Security: SENSITIVE pattern / Credentials must be rejected
    sensitive_contents = [
        "Eddie 的密码是 secret123456",
        "API 密钥为 sk-abcdef1234567890abcdef",
        "使用 Bearer token-live-999888 进行鉴权",
        "服务器密码 password=supersecret",
    ]
    for s_content in sensitive_contents:
        with pytest.raises(ValueError, match="contains credentials"):
            catalog.save(
                content=s_content,
                category="关于我",
                source={"message_id": "m_002", "quote": s_content},
            )

    # 4. Invalid category must be rejected
    with pytest.raises(ValueError, match="Invalid memory category"):
        catalog.save(
            content="Eddie 正在测试系统",
            category="非法未定义分类",
            source={"message_id": "m_003", "quote": "测试系统"},
        )

    # 5. Legitimate save with valid quote provenance
    valid_source = {"message_id": "m_004", "quote": "我平时只用双显示器写代码"}
    saved = catalog.save(
        content="Eddie 习惯使用双显示器进行软件开发",
        category="关于我",
        source=valid_source,
    )
    assert saved["id"].startswith("mem_")
    assert saved["version"] == 1
    assert saved["source"]["quote"] == valid_source["quote"]

    # Read back from disk and verify Markdown format + JSON payload
    item_disk = catalog.get(saved["id"])
    assert item_disk["content"] == "Eddie 习惯使用双显示器进行软件开发"
    assert item_disk["source"]["message_id"] == "m_004"


def test_challenge_15_spoken_chinese_numerals_due_date_detection_vulnerability(tmp_path: Path):
    """CHALLENGE 4.3 (Adversarial Bug Finding):

    Demonstrate empirically that extract_rule_based_summary regex uses \\d{1,2} for dates,
    which fails to recognize natural spoken Chinese numerals ('明天下午三点', '今晚八点').
    When user speaks Chinese numerals without an external LLM summary_model, the due_date
    is extracted as None, causing the task to be dropped from Obsidian vault sync.
    """
    chinese_numeral_turns = [
        {"role": "user", "text": "计划明天下午三点跟李总开会"},
        {"role": "user", "text": "记得今晚八点前交周报"},
    ]

    extracted = extract_rule_based_summary(
        [{"role": "user", "text": t["text"]} for t in chinese_numeral_turns],
        [],
        [],
    )
    items = extracted["action_items"]
    assert len(items) == 2
    # Empirical proof: due_date is None because date_pat regex expects Arabic digits (\d{1,2})
    assert items[0]["due_date"] is None
    assert items[1]["due_date"] is None

    # As a consequence, post_call_summary_pipeline without an LLM model cannot write task cards:
    records_dir = tmp_path / "records"
    vault_dir = tmp_path / "vault"
    res = run_async(
        post_call_summary_pipeline(
            "sess_vuln_test",
            chinese_numeral_turns,
            [],
            records_dir=records_dir,
            vault_dir=vault_dir,
            model=None,  # No LLM fallback
        )
    )
    assert res["tasks_created"] == []  # Dropped from Obsidian sync due to None due_date!
