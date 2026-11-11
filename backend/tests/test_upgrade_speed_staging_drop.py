"""P1 极速大小脑分流 + auto_memory 实时查询短路 + P3 外向 Staging 硬闸门 + 万能投递口全链路单测。"""
from __future__ import annotations

import asyncio
import base64
import importlib
import json
import sqlite3
import stat
import sys
import time
import types
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import auto_memory
import fast_classifier
import message_router
from agent_tools import AgentTools
from artifacts import ArtifactAccess
from auto_memory import AUTO_RECALL_HEADER, auto_recall_block, is_ephemeral_live_query
from capabilities import CapabilityRegistry
from conversation import PersonalConversation
from drop_inbox import DropInbox, detect_url_platform
from fast_classifier import (
    DEFAULT_FAST_MODEL,
    FALLBACK_FAST_MODEL,
    HARD_TIMEOUT_SECONDS,
    HTTP_TIMEOUT_SECONDS,
    classify_fast,
    degraded_models,
    reset_degraded_models,
)
from goals import GoalEvents
from message_router import (
    DEFAULT_CASUAL_MODEL,
    casual_fast_model,
    fast_model,
    mark_casual_model_degraded,
    reset_casual_model_state,
)
from task_tools import archive_stale_tasks, classify_outbound_action, stage_outbound_action
from tasks import TaskController, TaskStore
from work_dispatch import WorkProposalStore


def _make_agent_tools(tmp_path: Path, user_text: str = "帮我处理这项工作"):
    chat = PersonalConversation(tmp_path)
    msg = chat.submit("req-human-0001", user_text)
    with chat.db() as db:
        db.execute("INSERT OR REPLACE INTO meta VALUES ('hermes_session_id','com-personal-main')")
    store = TaskStore(tmp_path)
    controller = TaskController(store, types.SimpleNamespace(action_lock=asyncio.Lock()), chat)
    proposals = WorkProposalStore(tmp_path, tmp_path)
    tools = AgentTools(
        tmp_path,
        chat,
        proposals,
        store,
        controller,
        CapabilityRegistry(tmp_path),
        GoalEvents(tmp_path),
    )
    context = {
        "origin_message_id": msg["message_id"],
        "origin_request_id": "req-human-0001",
        "origin_session_id": "com-personal-main",
    }
    return tools, chat, store, context


def test_fast_classifier_vertex_default_timeouts_and_4xx_downgrade_chain(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    reset_degraded_models()
    monkeypatch.delenv("COM_FAST_CLASSIFIER_MODEL", raising=False)
    assert DEFAULT_FAST_MODEL == "vertex-948/gemini-3.5-flash-lite"
    assert FALLBACK_FAST_MODEL == "auto/gemini-3.8-flash"
    assert HTTP_TIMEOUT_SECONDS == pytest.approx(0.65)
    assert HARD_TIMEOUT_SECONDS == pytest.approx(0.72)

    models_json = tmp_path / "models.json"
    models_json.write_text(
        json.dumps({"providers": {"magpie": {"baseUrl": "http://127.0.0.1:3425/v1", "apiKey": "local-key"}}}),
        encoding="utf-8",
    )

    seen_models: list[str] = []

    def downgrade_handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content.decode("utf-8"))
        model = body["model"]
        seen_models.append(model)
        if model == "vertex-948/gemini-3.5-flash-lite":
            return httpx.Response(404, json={"error": "model not found on upstream"})
        content = json.dumps(
            {"intent": "query", "confidence": 0.93, "tools": ["memory_recall"], "level": "L1"},
            ensure_ascii=False,
        )
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    transport = httpx.MockTransport(downgrade_handler)
    first = asyncio.run(
        classify_fast(tmp_path, "req-dg-1", "查一下攀岩计划", transport=transport, models_path=models_json)
    )
    assert first.accepted is True
    assert first.intent == "query"
    assert seen_models == ["vertex-948/gemini-3.5-flash-lite", "auto/gemini-3.8-flash"]
    assert "vertex-948/gemini-3.5-flash-lite" in degraded_models()

    # Subsequent call remembers degradation in-process and skips the 404 model immediately
    second = asyncio.run(
        classify_fast(tmp_path, "req-dg-2", "再查一下攀岩计划", transport=transport, models_path=models_json)
    )
    assert second.accepted is True
    assert seen_models == [
        "vertex-948/gemini-3.5-flash-lite",
        "auto/gemini-3.8-flash",
        "auto/gemini-3.8-flash",
    ]

    # Env override takes top precedence when healthy
    reset_degraded_models()
    monkeypatch.setenv("COM_FAST_CLASSIFIER_MODEL", "auto/gemini-3.8-flash")
    seen_models.clear()
    third = asyncio.run(
        classify_fast(tmp_path, "req-dg-3", "测试环境变量覆盖", transport=transport, models_path=models_json)
    )
    assert third.accepted is True
    assert seen_models == ["auto/gemini-3.8-flash"]
    reset_degraded_models()


def test_casual_fast_model_override_and_fallback(monkeypatch: pytest.MonkeyPatch) -> None:
    reset_casual_model_state()
    monkeypatch.delenv("COM_CASUAL_MODEL", raising=False)
    default_casual = casual_fast_model()
    assert default_casual["model"] == DEFAULT_CASUAL_MODEL == "vertex-948/gemini-3.5-flash-lite"
    assert default_casual["provider"] == (fast_model().get("provider") or "magpie")

    monkeypatch.setenv("COM_CASUAL_MODEL", "auto/gemini-3.8-flash")
    assert casual_fast_model()["model"] == "auto/gemini-3.8-flash"

    fallback = mark_casual_model_degraded("auto/gemini-3.8-flash")
    assert fallback["model"] == fast_model()["model"]
    assert casual_fast_model()["model"] == fast_model()["model"]
    reset_casual_model_state()


@pytest.mark.parametrize(
    "live_query",
    [
        "近 7 天餐饮消费",
        "帮我查一下近30天开销汇总",
        "最近账单花了多少",
        "本月记账明细",
        "上个月餐饮花费多少钱？",
        "明天有什么日程",
        "今明两天有没有时间冲突",
        "查一下今天和明天的会议安排",
        "后天的日历",
        "未完成提醒有哪些",
        "帮我看看后台任务进度",
        "搜狐转发配额剩多少",
        "今天关注流转发配额还有多少？",
    ],
)
def test_auto_memory_short_circuits_live_queries_under_5ms(tmp_path: Path, live_query: str) -> None:
    called = False

    def forbidden_recall(_q: str):
        nonlocal called
        called = True
        raise AssertionError("Ephemeral live query must short-circuit without calling recall backend")

    assert is_ephemeral_live_query(live_query) is True
    t0 = time.perf_counter()
    out = auto_recall_block(tmp_path, live_query, recall_fn=forbidden_recall)
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    assert out == ""
    assert elapsed_ms < 5.0
    assert called is False


@pytest.mark.parametrize(
    "memory_query",
    [
        "老马是谁",
        "我的攀岩习惯",
        "搜狐劳务报销规则是什么",
        "小倩平时负责哪块业务",
        "我的饮食偏好和忌口",
        "结合我的习惯看看本月消费",
    ],
)
def test_auto_memory_preserves_recall_for_preferences_rules_and_people(
    tmp_path: Path, memory_query: str
) -> None:
    assert is_ephemeral_live_query(memory_query) is False
    recalled = auto_recall_block(
        tmp_path,
        memory_query,
        recall_fn=lambda q: {"items": [{"text": f"命中长期记忆：{q}", "source": "MEMORY.md"}]},
    )
    assert recalled.startswith(AUTO_RECALL_HEADER)
    assert f"命中长期记忆：{memory_query}" in recalled


@pytest.mark.parametrize(
    "tool_name,tool_args,expected_type,expected_url_prefix",
    [
        (
            "email_send",
            {"to": "brand@example.com", "subject": "全国岩馆路书合作报价", "body": "您好，附件为报价单"},
            "email_send",
            "https://mail.google.com/",
        ),
        (
            "business_call",
            {"tool": "sohu_labor", "args": {"action": "submit", "guest": "老马", "amount": 1500}},
            "labor_submit",
            "https://pr.sohu.com/",
        ),
        (
            "content_publish",
            {"platform": "视频号", "title": "全国岩馆路书·北京站成片", "video_path": "out.mp4"},
            "content_publish",
            "https://channels.weixin.qq.com/",
        ),
        (
            "bash",
            {"command": "gws gmail +send --to partner@sohu-inc.com --subject 周报"},
            "email_send",
            "https://mail.sohu.com/",
        ),
    ],
)
def test_outbound_staging_gate_intercepts_final_actions_and_emits_widget(
    tmp_path: Path,
    tool_name: str,
    tool_args: dict,
    expected_type: str,
    expected_url_prefix: str,
) -> None:
    tools, chat, _store, context = _make_agent_tools(tmp_path, "帮我处理这项外发操作")
    external_executed = False

    class ForbiddenBusiness:
        async def call(self, *_a, **_kw):
            nonlocal external_executed
            external_executed = True
            return {"sent": True}

    tools.business = ForbiddenBusiness()

    if tool_name == "bash":
        res = tools.authorize_tool({"tool": tool_name, "args": tool_args, "tool_call_id": "tc-bash-1"}, context)
    else:
        res = asyncio.run(tools.call(tool_name, tool_args, context))

    assert external_executed is False
    assert res["staged"] is True
    assert res["blocked"] is True
    assert res["executed"] is False
    assert res["action_type"] == expected_type

    widget = res["widget"]
    assert widget["kind"] == "staging_review"
    assert widget["action_type"] == expected_type
    assert widget["confirm_label"] == "打开页面我去点"
    assert widget["cancel_label"] == "打回重改"
    assert widget["target_url"].startswith(expected_url_prefix)
    assert widget["title"] and widget["summary"]

    # Persisted inside existing business-operations.sqlite (0600) with zero new sqlite files
    ops_db = tmp_path / "business-operations.sqlite"
    assert ops_db.exists()
    assert stat.S_IMODE(ops_db.stat().st_mode) == 0o600
    with sqlite3.connect(ops_db) as db:
        row = db.execute(
            "SELECT action_type, status, target_url FROM staged_outbound_actions WHERE id=?",
            (res["staging_id"],),
        ).fetchone()
    assert row == (expected_type, "staged", widget["target_url"])

    # Conversation snapshot contains the projected staging_review widget bubble
    snap = chat.snapshot()
    asst_msgs = [m for m in snap["messages"] if m["role"] == "assistant"]
    assert asst_msgs
    last_bubble = asst_msgs[-1]
    assert last_bubble["bubble_type"] == "widget"
    assert last_bubble["widgets"] and last_bubble["widgets"][0]["kind"] == "staging_review"


@pytest.mark.parametrize(
    "tool_name,tool_args,desc",
    [
        ("email", {"action": "draft", "to": "a@b.com", "subject": "草稿"}, "起草邮件草稿"),
        ("email_send", {"draft": True, "to": "a@b.com", "subject": "仅存草稿"}, ""),
        ("sohu_labor", {"action": "prepare", "guest": "老马", "amount": 1500}, "自动填表准备并停在按钮前"),
        ("content_publish", {"dry_run": True, "title": "测试干跑"}, ""),
        ("sohu_repost", {"action": "status"}, "查询转发配额"),
        ("bookkeeping", {"action": "add", "amount": 35, "comment": "午饭"}, "记账"),
        ("calendar_event", {"action": "create", "summary": "选题会"}, "加日历"),
        ("bash", {"command": "gws gmail drafts create --to a@b.com"}, "创建草稿"),
        ("bash", {"command": "python3 sohu_labor.py --fill -- guest 老马 # 停在按钮前"}, ""),
    ],
)
def test_outbound_staging_gate_allows_drafts_prepare_dry_run_queries_and_daily_tools(
    tmp_path: Path, tool_name: str, tool_args: dict, desc: str
) -> None:
    assert classify_outbound_action(tool_name, tool_args, description=desc) is None
    assert stage_outbound_action(tmp_path, tool=tool_name, args=tool_args, description=desc) is None


def test_send_message_staging_review_widget_passthrough(tmp_path: Path) -> None:
    tools, chat, _store, context = _make_agent_tools(tmp_path, "帮我把劳务单填好停在提交前")
    res = asyncio.run(
        tools.call(
            "send_message",
            {
                "type": "widget",
                "content": "老马的 1500 元劳务报酬单已填妥，停在提交按钮前。",
                "blocking": True,
                "widget": {
                    "kind": "staging_review",
                    "title": "搜狐 PR 劳务单已填好",
                    "summary": "嘉宾：老马｜税后 ¥1500｜附件已传齐",
                    "action_type": "labor_submit",
                    "confirm_label": "打开页面我去点",
                    "cancel_label": "打回重改",
                    "target_url": "https://pr.sohu.com/apply/123",
                },
            },
            context,
        )
    )
    assert res["ok"] is True
    assert res["widget"]["kind"] == "staging_review"
    msgs = [m for m in chat.snapshot()["messages"] if m["role"] == "assistant"]
    assert msgs[-1]["widgets"][0]["target_url"] == "https://pr.sohu.com/apply/123"


def test_archive_stale_tasks_archives_old_unaccepted_without_deleting_rows(tmp_path: Path) -> None:
    store = TaskStore(tmp_path)
    now = 1_800_000_000.0
    ten_days_ago = now - 10 * 86400
    two_days_ago = now - 2 * 86400

    fixtures = [
        {"id": "t_stale_wait", "title": "旧等待单", "status": "waiting", "verification_status": "pending", "updated_at": ten_days_ago, "created_at": ten_days_ago},
        {"id": "t_stale_unk", "title": "旧未知单", "status": "unknown", "verification_status": "uncertain", "updated_at": ten_days_ago, "created_at": ten_days_ago},
        {"id": "t_stale_fin", "title": "旧未验收完成单", "status": "execution_finished", "verification_status": "pending", "updated_at": ten_days_ago, "created_at": ten_days_ago},
        {"id": "t_passed_fin", "title": "已验收完成单", "status": "execution_finished", "verification_status": "passed", "updated_at": ten_days_ago, "created_at": ten_days_ago},
        {"id": "t_fresh_wait", "title": "两天内等待单", "status": "waiting", "verification_status": "pending", "updated_at": two_days_ago, "created_at": two_days_ago},
        {"id": "t_running", "title": "正在运行单", "status": "running", "verification_status": "pending", "updated_at": ten_days_ago, "created_at": ten_days_ago},
    ]
    with store.db() as db:
        for item in fixtures:
            store._save(db, dict(item))

    res = archive_stale_tasks(store, days=7, now=now)
    assert res["ok"] is True
    assert res["archived_count"] == 3
    assert set(res["archived_ids"]) == {"t_stale_wait", "t_stale_unk", "t_stale_fin"}

    tasks_by_id = {t["id"]: t for t in store.list()}
    assert len(tasks_by_id) == 6  # 不物理删行
    for tid in ("t_stale_wait", "t_stale_unk", "t_stale_fin"):
        assert tasks_by_id[tid]["status"] == "dismissed"
        assert any(ev["kind"] == "archived_stale" for ev in tasks_by_id[tid]["events"])

    assert tasks_by_id["t_passed_fin"]["status"] == "execution_finished"
    assert tasks_by_id["t_fresh_wait"]["status"] == "waiting"
    assert tasks_by_id["t_running"]["status"] == "running"

    # Idempotent on second run
    second = archive_stale_tasks(store, days=7, now=now)
    assert second["archived_count"] == 0


def test_drop_inbox_and_app_routes_end_to_end(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    ws = tmp_path / "AI_Work_System"
    ws.mkdir(parents=True)
    state_dir = tmp_path / "state"
    monkeypatch.setenv("WORKBENCH_HOME", str(tmp_path))
    monkeypatch.setenv("WORKBENCH_STATE", str(state_dir))

    # Stub memory_truth and memory_dream if @backend-memory hasn't written them yet, or verify real ones if present
    fake_truth = types.ModuleType("memory_truth")
    truth_store = {"MEMORY.md": "- 核心身份：搜狐户外内容导演\n- 每周攀岩三次\n", "SOUL.md": "- 先给结论\n"}

    def _get_truth_files(_s=None):
        return {
            "ok": True,
            "files": [
                {"name": k, "title": k, "content": v, "updated_at": 1.0, "line_count": len(v.splitlines())}
                for k, v in truth_store.items()
            ],
        }

    def _update_truth_file(name: str, content: str, _s=None):
        if name not in truth_store:
            raise ValueError("只允许修改 MEMORY.md 或 SOUL.md")
        truth_store[name] = content
        return {"ok": True, "name": name, "content": content, "sanitized_lines": []}

    def _forget_truth_entry(target: str, name: str = "MEMORY.md", _s=None):
        if name not in truth_store:
            raise ValueError("非法文件名")
        kept = [ln for ln in truth_store[name].splitlines() if target not in ln]
        removed = len(truth_store[name].splitlines()) - len(kept)
        truth_store[name] = ("\n".join(kept) + "\n") if kept else ""
        return {"ok": True, "name": name, "removed_count": removed, "content": truth_store[name]}

    fake_truth.get_truth_files = _get_truth_files  # type: ignore[attr-defined]
    fake_truth.update_truth_file = _update_truth_file  # type: ignore[attr-defined]
    fake_truth.forget_truth_entry = _forget_truth_entry  # type: ignore[attr-defined]

    fake_dream = types.ModuleType("memory_dream")

    async def _run_dream(_s=None, *, reason: str = "manual"):
        return {"ok": True, "reason": reason, "merged_count": 2}

    fake_dream.run_dream = _run_dream  # type: ignore[attr-defined]

    if not (Path(__file__).resolve().parents[1] / "memory_truth.py").exists():
        monkeypatch.setitem(sys.modules, "memory_truth", fake_truth)
    if not (Path(__file__).resolve().parents[1] / "memory_dream.py").exists():
        monkeypatch.setitem(sys.modules, "memory_dream", fake_dream)

    import app as app_mod

    app_mod = importlib.reload(app_mod)
    client = TestClient(app_mod.app)
    headers = {"Authorization": "Bearer " + app_mod.TOKEN}

    # Platform recognition coverage
    assert detect_url_platform("https://www.capcut.cn/share/abc123")["platform"] == "capcut"
    assert detect_url_platform("https://v.douyin.com/iY123/")["platform"] == "douyin"
    assert detect_url_platform("https://www.xiaohongshu.com/explore/123")["platform"] == "xiaohongshu"
    assert detect_url_platform("https://tv.sohu.com/s/follow/999")["platform"] == "sohu"
    assert detect_url_platform("https://github.com/google/genai")["platform"] == "github"

    # 1. URL drop without auto_chat
    r_url = client.post(
        "/personal/drop",
        headers=headers,
        json={"url": "https://www.capcut.cn/share/demo999", "source": "ios_shortcut", "auto_chat": False},
    )
    assert r_url.status_code == 200
    url_item = r_url.json()["item"]
    assert url_item["kind"] == "url"
    assert url_item["platform"] == "capcut"
    assert any("剪映" in s for s in url_item["suggestions"])
    assert app_mod.conversation.snapshot()["messages"] == []

    # 2. Text drop with auto_chat=True
    r_txt = client.post(
        "/personal/drop",
        headers=headers,
        json={"text": "下周三拍北京奥森岩馆路书第 5 期，记得带双机位麦", "auto_chat": True},
    )
    assert r_txt.status_code == 200
    txt_item = r_txt.json()["item"]
    assert txt_item["kind"] == "text" and txt_item["status"] == "chatted"
    msgs = app_mod.conversation.snapshot()["messages"]
    assert len(msgs) == 2
    assert msgs[0]["role"] == "user" and "奥森岩馆" in msgs[0]["text"]
    assert msgs[1]["role"] == "assistant" and msgs[1]["bubble_type"] == "widget"
    assert msgs[1]["widgets"][0]["kind"] == "picker"

    # 3. Base64 PNG drop -> CAS + ArtifactAccess registration + downloadable /personal/artifacts/art_...
    png_bytes = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2ioAAAAASUVORK5CYII="
    )
    r_img = client.post(
        "/personal/drop",
        headers=headers,
        json={
            "data_base64": "data:image/png;base64," + base64.b64encode(png_bytes).decode("ascii"),
            "filename": "climb_ poster.png",
            "title": "岩馆海报初稿",
            "auto_chat": True,
        },
    )
    assert r_img.status_code == 200
    img_item = r_img.json()["item"]
    assert img_item["kind"] == "image"
    assert img_item["artifact_id"].startswith("art_")
    dl = client.get(img_item["download_path"], headers=headers)
    assert dl.status_code == 200
    assert dl.content == png_bytes

    # Verify drop_items lives inside existing artifacts.sqlite (0600) and NO extra drop sqlite exists
    art_db = state_dir / "artifacts.sqlite"
    assert art_db.exists()
    assert stat.S_IMODE(art_db.stat().st_mode) == 0o600
    sqlite_names = {p.name for p in state_dir.glob("*.sqlite")}
    assert not any("drop" in n for n in sqlite_names)

    r_list = client.get("/personal/drop?limit=10", headers=headers)
    assert r_list.status_code == 200
    assert r_list.json()["total"] == 3

    # 4. Stale task archive HTTP endpoint
    old_ts = time.time() - 9 * 86400
    with app_mod.task_store.db() as db:
        app_mod.task_store._save(
            db,
            {
                "id": "task_http_zombie_1",
                "title": "9天前僵尸任务",
                "status": "waiting",
                "verification_status": "pending",
                "created_at": old_ts,
                "updated_at": old_ts,
            },
        )
    r_arch = client.post("/personal/tasks/archive-stale", headers=headers, json={"days": 7})
    assert r_arch.status_code == 200
    assert r_arch.json()["archived_count"] == 1
    assert "task_http_zombie_1" in r_arch.json()["archived_ids"]

    # 5. Memory truth & dream HTTP endpoints (must not be shadowed by /personal/memory/{memory_id})
    r_mfiles = client.get("/personal/memory/files", headers=headers)
    assert r_mfiles.status_code == 200
    assert r_mfiles.json()["ok"] is True
    assert any(f["name"] == "MEMORY.md" for f in r_mfiles.json()["files"])

    r_mput = client.put(
        "/personal/memory/files/SOUL.md",
        headers=headers,
        json={"content": "- 先说结论\n- 严禁自动点发送按钮\n"},
    )
    assert r_mput.status_code == 200 and r_mput.json()["ok"] is True

    r_mpost = client.post(
        "/personal/memory/files/MEMORY.md",
        headers=headers,
        json={"content": "- 搜狐户外导演\n- 临时待忘条目\n"},
    )
    assert r_mpost.status_code == 200 and r_mpost.json()["ok"] is True

    r_mforget = client.post(
        "/personal/memory/forget",
        headers=headers,
        json={"target": "临时待忘条目", "name": "MEMORY.md"},
    )
    assert r_mforget.status_code == 200 and r_mforget.json()["removed_count"] >= 1

    r_mdream = client.post("/personal/memory/dream", headers=headers)
    assert r_mdream.status_code == 200 and r_mdream.json()["ok"] is True


def test_backend_core_touched_files_follow_hard_invariants() -> None:
    backend_dir = Path(__file__).resolve().parents[1]
    touched = (
        "fast_classifier.py",
        "message_router.py",
        "auto_memory.py",
        "task_tools.py",
        "agent_tools.py",
        "drop_inbox.py",
        "app.py",
        "superagent_flags.py",
    )
    banned_commercial_models = ("claude-3", "claude-sonnet", "claude-opus", "claude-haiku")
    for name in touched:
        content = (backend_dir / name).read_text(encoding="utf-8")
        assert "from __future__ import annotations" in content.splitlines()[:15], f"Missing future annotations in {name}"
        low = content.lower()
        for banned in banned_commercial_models:
            assert banned not in low, f"Forbidden commercial model {banned} in {name}"
        assert list(backend_dir.glob(f"{name}.bak*")) == []
