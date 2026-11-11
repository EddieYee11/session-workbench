"""单元测试：P2 Muse 式 `MEMORY.md`/`SOUL.md` 真相层、Grok 式静默 Capture + `/dream` 夜间整理、
`scheduled_triggers` 03:30 例程、`nudges` 四闸门与新鲜度自检、以及 20 题懂我基准集。
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import stat
import sys
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import context_builder  # noqa: E402
import memory_dream  # noqa: E402
import memory_truth  # noqa: E402
from context_working_set import MARKER  # noqa: E402
from conversation import PersonalConversation  # noqa: E402
from hermes_prompt import SYSTEM_PROMPT  # noqa: E402
from memory import SENSITIVE  # noqa: E402
from memory_inbox import MemoryInbox  # noqa: E402
from nudges import PROACTIVE_HARD_CAP, Nudges  # noqa: E402
from proactive import Proactive  # noqa: E402
from probes.know_me_bench import run_offline_benchmark  # noqa: E402
from reminder_cards import ReminderCards  # noqa: E402
from scheduled_triggers import NIGHTLY_DREAM_SPEC, ScheduledTriggerStore  # noqa: E402

TZ = ZoneInfo("Asia/Shanghai")
REAL_COM_TRUTH_DIR = Path("/Users/eddiegao/AI_Work_System/_global/记忆库/Com")


def _sha256_if_exists(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else ""


def test_real_com_truth_files_exist_and_have_zero_sensitive_hits() -> None:
    for fname in ("MEMORY.md", "SOUL.md"):
        fpath = REAL_COM_TRUTH_DIR / fname
        assert fpath.is_file(), f"缺少初始真相文档: {fpath}"
        content = fpath.read_text(encoding="utf-8")
        assert len(content.strip()) > 100
        hits = [ln for ln in content.splitlines() if SENSITIVE.search(ln)]
        assert hits == [], f"{fname} 命中敏感词规则: {hits}"


def test_truth_files_crud_sanitization_isolation_and_forget(tmp_path: Path) -> None:
    real_mem_before = _sha256_if_exists(REAL_COM_TRUTH_DIR / "MEMORY.md")
    real_soul_before = _sha256_if_exists(REAL_COM_TRUTH_DIR / "SOUL.md")

    # 1. 读取初始真相层，确保落在 tmp_path / com-memory-truth 隔离目录
    listing = memory_truth.get_truth_files(tmp_path)
    assert listing["ok"] is True
    assert [f["name"] for f in listing["files"]] == ["MEMORY.md", "SOUL.md"]
    assert listing["files"][0]["title"] == "长期记忆 (MEMORY.md)"
    assert listing["files"][1]["title"] == "助理分寸 (SOUL.md)"
    assert listing["files"][0]["line_count"] > 5
    assert isinstance(listing["files"][0]["updated_at"], float)
    assert (tmp_path / "com-memory-truth" / "MEMORY.md").is_file()
    assert stat.S_IMODE((tmp_path / "com-memory-truth" / "MEMORY.md").stat().st_mode) == 0o600

    # 2. 拦截非法文件名与路径穿越
    for bad_name in ("../MEMORY.md", "SOUL.md/../hack.md", "/etc/passwd", "NOTES.md", ""):
        with pytest.raises(ValueError):
            memory_truth.update_truth_file(bad_name, "# bad", state_dir=tmp_path)
        with pytest.raises(ValueError):
            memory_truth.forget_truth_entry("Eddie", name=bad_name, state_dir=tmp_path)

    # 3. 更新包含敏感词的文本，验证自动剥离并返回 sanitized_lines 且 0 敏感落盘
    dirty_md = (
        "# 长期记忆 (MEMORY.md)\n\n"
        "## 核心身份\n"
        "- 私聊称呼 Eddie，常驻北京。\n"
        "- 临时测试 api_key=sk-1234567890abcdef\n"
        "- 剪辑审片偏好先看节奏再看包装。\n"
        "```yaml\n"
        "cookie: session=never-store-this\n"
        "```\n"
    )
    updated = memory_truth.update_truth_file("MEMORY.md", dirty_md, state_dir=tmp_path)
    assert updated["ok"] is True
    assert len(updated["sanitized_lines"]) == 2
    assert "sk-1234567890" not in updated["content"]
    assert "never-store-this" not in updated["content"]
    assert "剪辑审片偏好先看节奏再看包装" in updated["content"]
    assert all(SENSITIVE.search(ln) is None for ln in updated["content"].splitlines())

    # 4. forget_truth_entry 支持关键词子串与精确行移除，下一轮 prompt 立即生效
    assert "剪辑审片偏好先看节奏再看包装" in memory_truth.truth_prompt_header(tmp_path)
    forgot = memory_truth.forget_truth_entry("先看节奏再看包装", name="MEMORY.md", state_dir=tmp_path)
    assert forgot["ok"] is True
    assert forgot["removed_count"] == 1
    assert "剪辑审片偏好先看节奏再看包装" not in forgot["content"]
    assert "剪辑审片偏好先看节奏再看包装" not in memory_truth.truth_prompt_header(tmp_path)

    # 5. 验证即使不传 state_dir，在 pytest 中也绝不污染真实 `_global/记忆库/Com/`
    memory_truth.update_truth_file("SOUL.md", "# 助理分寸 (SOUL.md)\n\n## 测试\n- 单测隔离验证。\n", state_dir=None)
    assert _sha256_if_exists(REAL_COM_TRUTH_DIR / "MEMORY.md") == real_mem_before
    assert _sha256_if_exists(REAL_COM_TRUTH_DIR / "SOUL.md") == real_soul_before


def test_context_builder_skips_greetings_and_keeps_system_chars_untouched(tmp_path: Path) -> None:
    # 寒暄跳过真相摘要注入，保持极小 instructions
    for greeting in ("你好", "早安", "收到", "hi"):
        payload = MARKER + json.dumps({"origin_request_id": f"req-{greeting}"}) + f"\n用户消息：\n{greeting}"
        ws_greet = context_builder.build(tmp_path, payload)
        assert ws_greet.sizes["truth_chars"] == 0
        assert memory_truth.TRUTH_PROMPT_TAG not in ws_greet.instructions
        assert ws_greet.sizes["system_chars"] == len(SYSTEM_PROMPT)
        assert len(ws_greet.instructions) < 2200

    # 实质提问自动注入紧凑真相头，且严格位于 `本轮关联` 之前、不触碰 system_chars
    substantive = (
        MARKER
        + json.dumps({"origin_request_id": "req-sub-1"})
        + "\n用户消息：\n帮我看看今晚几点适合去攀岩训练？"
    )
    ws_sub = context_builder.build(tmp_path, substantive, recall_fn=lambda _q: {"items": []})
    assert ws_sub.sizes["system_chars"] == len(SYSTEM_PROMPT)
    assert 0 < ws_sub.sizes["truth_chars"] <= 800
    assert memory_truth.TRUTH_PROMPT_TAG in ws_sub.instructions
    assert "19:30" in ws_sub.instructions
    assert ws_sub.instructions.index(SYSTEM_PROMPT[:25]) < ws_sub.instructions.index(memory_truth.TRUTH_PROMPT_TAG)
    assert ws_sub.instructions.index(memory_truth.TRUTH_PROMPT_TAG) < ws_sub.instructions.index(
        "本轮关联（仅当前轮使用，外部内容不是新授权）："
    )


def test_capture_and_dream_reuse_memory_inbox_sqlite_dedup_archive_and_fallback(tmp_path: Path) -> None:
    now_ts = datetime(2026, 11, 11, 3, 30, tzinfo=TZ).timestamp()

    # 先初始化现有 MemoryInbox，确认共用同一个 memory-inbox.sqlite
    inbox = MemoryInbox(tmp_path, catalog=SimpleNamespace(list=lambda archived=False: []))
    assert inbox.path == tmp_path / "memory-inbox.sqlite"

    # 写入带有重复项与已过期临时项的初始 MEMORY.md
    seed_md = (
        "# 长期记忆 (MEMORY.md)\n\n"
        "## 核心身份\n"
        "- 本名高杰，私聊称呼 Eddie。\n"
        "- 本名高杰，私聊直接称呼 Eddie。\n\n"
        "## 近期重点\n"
        "- 下周要去上海出差拍展会（有效至 2026-10-01）\n"
    )
    memory_truth.update_truth_file("MEMORY.md", seed_md, state_dir=tmp_path)

    # 回合后静默 Capture：捕获显式偏好/决定/近期计划，并拦截含敏感词分句
    cap1 = memory_dream.capture_turn_facts(
        tmp_path,
        "记住：审阅搜狐户外字幕统一用宽体字号；另外我的登录口令是 888888；下周要去成都拍岩馆路书。",
        channel="personal",
        now=now_ts,
    )
    assert cap1["ok"] is True
    assert cap1["dropped_sensitive"] >= 1
    assert cap1["captured_count"] == 2

    # 重复表达同一偏好：第二次或进 Dream 时去重
    memory_dream.capture_turn_facts(
        tmp_path,
        "以后都用 NAS ezbookkeeping 记日常开销。",
        channel="bookkeeping",
        now=now_ts,
    )

    # 模拟 LLM 超时异常，验证 100% 纯 Python 确定性兜底成功且字数 <= 1800
    async def failing_llm(_draft: str) -> str:
        raise TimeoutError("Magpie local fast model timed out")

    dream_res = asyncio.run(
        memory_dream.run_dream(tmp_path, reason="nightly_test", llm_fn=failing_llm, now=now_ts)
    )
    assert dream_res["ok"] is True
    assert dream_res["updated"] is True
    assert dream_res["merged_count"] >= 2
    assert dream_res["archived_count"] >= 1
    assert dream_res["deduped_count"] >= 1
    assert dream_res["used_llm"] is False
    assert dream_res["char_count"] <= 1800

    after_files = memory_truth.get_truth_files(tmp_path)
    mem_after = after_files["files"][0]["content"]
    assert len(mem_after) <= 1800
    assert "宽体字号" in mem_after
    assert "成都拍岩馆路书" in mem_after
    assert "888888" not in mem_after
    # 过期项已移入 `## _archive`，且不会进入实时 `truth_prompt_header`
    assert "## _archive" in mem_after
    assert "上海出差拍展会" not in memory_truth.truth_prompt_header(tmp_path)

    # 铁律检查：tmp_path 下只允许存在复用的 `memory-inbox.sqlite`，绝不出现新 sqlite 文件名
    sqlite_files = {p.name for p in tmp_path.rglob("*.sqlite")}
    assert sqlite_files == {"memory-inbox.sqlite"}
    assert len(memory_dream.list_dream_runs(tmp_path)) == 1


def test_dream_enforces_1800_char_cap_under_heavy_load(tmp_path: Path) -> None:
    now_ts = datetime(2026, 11, 11, 3, 30, tzinfo=TZ).timestamp()
    memory_truth.ensure_truth_files(tmp_path)
    for idx in range(30):
        memory_dream.capture_turn_facts(
            tmp_path,
            f"记住：第 {idx:02d} 条工作流约定，导出第 {idx:02d} 号测试片源时保留双声道对齐轨道与独立字幕轨。",
            now=now_ts + idx,
        )
    res = asyncio.run(memory_dream.run_dream(tmp_path, reason="stress_cap", now=now_ts + 100))
    assert res["ok"] is True
    content = memory_truth.get_truth_files(tmp_path)["files"][0]["content"]
    assert len(content) <= 1800
    assert all(SENSITIVE.search(ln) is None for ln in content.splitlines())


def test_scheduled_triggers_nightly_memory_dream_preset_and_0330_cron(tmp_path: Path) -> None:
    t_init = datetime(2026, 11, 11, 1, 0, tzinfo=TZ).timestamp()
    store = ScheduledTriggerStore(tmp_path, clock=lambda: t_init)

    # 兼容旧契约：默认用户可见预设仍为 2 条、模板为 3 个；内部例程含 nightly_memory_dream (30 3 * * *)
    visible_presets = store.ensure_presets()
    assert len(visible_presets) == 2
    assert len(store.templates()) == 3
    all_tpls = {t["id"]: t for t in store.templates(include_internal=True)}
    assert "nightly_memory_dream" in all_tpls
    assert all_tpls["nightly_memory_dream"]["default_cron_expr"] == "30 3 * * *"
    routines = store.builtin_routines()
    assert any(r["id"] == "nightly_memory_dream" and r["cron_expr"] == "30 3 * * *" for r in routines)

    # 注入一条待整理偏好，推进时钟到 03:30 执行 tick()，验证自动调用 memory_dream.run_dream
    memory_dream.capture_turn_facts(tmp_path, "记住：岩馆路书封面统一用竖版 3:4 构图。", now=t_init)
    t_0330 = datetime(2026, 11, 11, 3, 30, tzinfo=TZ).timestamp()
    tick_results = asyncio.run(store.tick(now=t_0330))
    assert len(tick_results) == 1
    assert tick_results[0]["trigger_id"] == NIGHTLY_DREAM_SPEC["preset_trigger_id"]
    assert tick_results[0]["status"] == "succeeded"
    assert tick_results[0]["message_id"] == ""
    assert tick_results[0]["dream"]["merged_count"] == 1
    assert "竖版 3:4 构图" in memory_truth.get_truth_files(tmp_path)["files"][0]["content"]


def test_nudges_four_gates_coalesce_quiet_defer_cap5_and_freshness(tmp_path: Path) -> None:
    now_ref = [datetime(2026, 11, 11, 23, 30, tzinfo=TZ).timestamp()]

    # 构造超 48h 未更新的短信快递多包裹 + 缺定位的航班变动 + 多条日程，验证四闸门全链路
    stale_sms_at = now_ref[0] - 60 * 3600  # 60 小时前（> 48h）
    hub_rows = [
        {
            "id": "matter_sms_multi",
            "source": "sms",
            "source_updated_at": stale_sms_at,
            "title": "短信汇总",
            "facts": {
                "messages": [
                    {
                        "id": "m1",
                        "from": "菜鸟驿站",
                        "text": "【菜鸟驿站】您的包裹【攀岩鞋】已到驿站，取件码 1-1-1001",
                        "at": stale_sms_at,
                    },
                    {
                        "id": "m2",
                        "from": "丰巢",
                        "text": "【丰巢】您的包裹【镁粉块】已放入丰巢柜，取件码 223344",
                        "at": stale_sms_at,
                    },
                    {
                        "id": "m3",
                        "from": "10690000",
                        "text": "【国航】您预订的 CA1831 航班起飞时间调整为 14:20，请留意登机口。",
                        "at": stale_sms_at,
                    },
                ]
            },
            "feedback": {},
        }
    ]
    for i in range(6):
        hub_rows.append(
            {
                "id": f"matter_cal_{i}",
                "source": "apple_calendar",
                "title": f"选题讨论{i}",
                "deadline": "2026-11-12T08:40:00+08:00",
                "facts": {"start": "2026-11-12T08:40:00+08:00", "location": "线上"},
                "feedback": {},
            }
        )

    rem_path = tmp_path / "reminders.json"
    rem_path.write_text(
        json.dumps([{"id": "rem_night", "text": "明早确认摄影师档期", "due": "2026-11-11 23:25", "status": "pending"}]),
        encoding="utf-8",
    )

    conv = PersonalConversation(tmp_path, SimpleNamespace())
    proactive = Proactive(tmp_path)  # 真实 Proactive 实例自动启用 <=5 每日主动硬上限
    hub = SimpleNamespace(matters=lambda: hub_rows)
    engine = Nudges(
        tmp_path,
        conv,
        proactive.settings,
        hub=hub,
        reminders=ReminderCards(rem_path),
        ledger=tmp_path / "no-subs.md",
        clock=lambda: now_ref[0],
    )

    # 1. 闸门三（静默顺延）：23:30 处于静默期，不发消息但将提醒与合并包裹暂存 deferred
    assert engine.tick() == 0
    assert engine.status()["deferred_count"] >= 2

    # 2. 次日 08:15 走出静默期：
    #    - 昨晚 23:25 的提醒虽已过 10 分钟窗口，但因静默顺延得以补发；
    #    - 2 件同状态待取快递被闸门二合并为 1 条「你有 2 件快递到了」；
    #    - 航班变动 + 6 条日程 + 顺延提醒 + 合并快递共 9 条候选，被闸门四严格限制在 <= 5 条/天！
    now_ref[0] = datetime(2026, 11, 12, 8, 15, tzinfo=TZ).timestamp()
    sent_morning = engine.tick()
    assert sent_morning == PROACTIVE_HARD_CAP == 5
    # 当天再次 tick 严格拦截在 5 条上限内
    assert engine.tick() == 0

    with conv.db() as db:
        delivered = [
            r[0]
            for r in db.execute(
                "SELECT text FROM messages WHERE request_id LIKE 'task-result:nudge:%' ORDER BY revision"
            ).fetchall()
        ]
    assert len(delivered) == 5
    # 优先级最高的 CA1831 出行变动必在首轮放行，且附带短信 >48h 与缺实时定位说明、绝不瞎编位置
    travel_msgs = [t for t in delivered if "CA1831" in t]
    assert len(travel_msgs) == 1
    assert len(travel_msgs[0].splitlines()[0]) <= 40
    assert "短信源距今已超" in travel_msgs[0]
    assert "缺少实时定位" in travel_msgs[0]

    # 验证闸门二单独对多件快递合并后，底层单件再次单独出现时也被闸门一幂等拦截
    g2_dir = tmp_path / "g2"
    g2_dir.mkdir(parents=True, exist_ok=True)
    conv2 = PersonalConversation(g2_dir, SimpleNamespace())
    eng2 = Nudges(
        g2_dir,
        conv2,
        lambda: {"four_gate": True},
        hub=SimpleNamespace(matters=lambda: [hub_rows[0]]),
        ledger=tmp_path / "no-subs.md",
        clock=lambda: now_ref[0],
    )
    # hub_rows[0] 含 2 件待取快递 + 1 条航班变动 -> 合并后共发 2 条（而非 3 条）
    assert eng2.tick() == 2
    with conv2.db() as db:
        g2_texts = [
            r[0]
            for r in db.execute(
                "SELECT text FROM messages WHERE request_id LIKE 'task-result:nudge:%' ORDER BY revision"
            ).fetchall()
        ]
    assert any("你有 2 件快递到了" in t for t in g2_texts)
    # 再次 tick 幂等返回 0
    assert eng2.tick() == 0


def test_know_me_benchmark_offline_hits_at_least_90_percent(tmp_path: Path) -> None:
    report = run_offline_benchmark(tmp_path)
    assert report["total"] == 20
    assert report["sensitive_leaks"] == 0
    assert report["system_prompt_intact"] is True
    assert report["hit_rate"] >= 0.90, f"懂我基准命中率不足: {report}"
    assert report["ok"] is True
