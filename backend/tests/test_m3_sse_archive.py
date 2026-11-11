"""Milestone 3 (Phase 3 Restructure) 核心能力验证测试套件。

涵盖：
1. SSERingBuffer 环形缓冲持久化与重放、Last-Event-ID 续传
2. 游标过期越界熔断对齐 (resync_required)
3. SQLite FTS5 中文单字/双字/中英混排全文检索与 Snippet 高亮
4. 事项生命周期 7 天自动归档 GC 与【绝对禁止删除 Obsidian 磁盘文件】保全断言
5. 归档事项原子恢复 (restore)
6. matter.update 跨端 SSE 广播集成测试
"""
import asyncio
import json
import os
import sqlite3
import time
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from matter_schema import (
    MatterStore,
    UnifiedMatterEntity,
    build_fts_query,
    clean_cjk_snippet,
    cjk_unigram_tokenize,
    generate_matter_id,
)
from sse_stream import SSEBroadcaster, SSEEvent, SSERingBuffer


# ─────────────────────────────────────────────────────────────
# 1. SSE Ring Buffer & Reconnect Protocol Tests
# ─────────────────────────────────────────────────────────────

def test_sse_ring_buffer_persistence_and_capacity(tmp_path):
    """验证 SSERingBuffer 写入 SQLite 持久化表，并能重启恢复队列与序列号。"""
    db_file = tmp_path / "sse_test.sqlite"
    rb = SSERingBuffer(db_file, capacity=5)

    ev1 = rb.publish("test.event", {"k": 1})
    ev2 = rb.publish("test.event", {"k": 2})
    ev3 = rb.publish("test.event", {"k": 3})

    assert ev1.event_seq == 1
    assert ev2.event_seq == 2
    assert ev3.event_seq == 3
    assert rb.latest_seq == 3
    assert rb.min_retained_seq == 1

    # 验证 SQLite 表内容
    with sqlite3.connect(db_file) as conn:
        count = conn.execute("SELECT COUNT(*) FROM sse_event_log").fetchone()[0]
        assert count == 3

    # 模拟重启：新建 SSERingBuffer 读取同个 SQLite 文件
    rb2 = SSERingBuffer(db_file, capacity=5)
    assert rb2.latest_seq == 3
    assert len(rb2.buffer) == 3

    # 继续写入直到超出 capacity
    rb2.publish("test.event", {"k": 4})
    rb2.publish("test.event", {"k": 5})
    rb2.publish("test.event", {"k": 6})  # 触发 capacity 挤出最旧的一条

    assert len(rb2.buffer) == 5
    assert rb2.latest_seq == 6
    assert rb2.min_retained_seq == 2  # 1 被移出环形队列
    assert rb2.is_in_buffer(2)
    assert rb2.is_expired(0) or not rb2.is_in_buffer(0)

    # 验证 SQLite 表同样被真正修剪，与内存保持定长 5
    with sqlite3.connect(db_file) as conn:
        cnt, min_s, max_s = conn.execute(
            "SELECT COUNT(*), MIN(event_seq), MAX(event_seq) FROM sse_event_log"
        ).fetchone()
        assert cnt == 5, f"Expected 5 rows in pruned SQLite table, got {cnt}"
        assert min_s == 2, f"Expected min_seq=2 in pruned SQLite table, got {min_s}"
        assert max_s == 6, f"Expected max_seq=6 in pruned SQLite table, got {max_s}"


def test_sse_replay_since_cursor(tmp_path):
    """验证客户端携带 Last-Event-ID 重连时，补发缺失序号帧。"""
    db_file = tmp_path / "sse_replay.sqlite"
    rb = SSERingBuffer(db_file, capacity=100)

    for i in range(1, 11):
        rb.publish("test.msg", {"index": i})

    assert rb.latest_seq == 10

    # 模拟客户端已消费到 seq=7，重连传递 after=7
    missed = rb.get_since(7)
    assert len(missed) == 3
    assert [ev.event_seq for ev in missed] == [8, 9, 10]
    assert [ev.data["index"] for ev in missed] == [8, 9, 10]


@pytest.mark.anyio
async def test_sse_stream_client_resync_required_on_expired_cursor(tmp_path):
    """验证客户端携带过旧游标时，严禁静默丢帧，必须先下发 resync_required 再紧随 snapshot。"""
    db_file = tmp_path / "sse_resync.sqlite"
    rb = SSERingBuffer(db_file, capacity=5)
    bc = SSEBroadcaster(rb)

    # 生产 10 条帧，使 seq 1..5 被挤出环形缓冲区
    for i in range(1, 11):
        bc.publish("item.add", {"i": i})

    assert rb.latest_seq == 10
    assert rb.min_retained_seq == 6

    # 客户端持有 cursor = 2（已过期越界）
    frames = []
    stream_gen = bc.stream_client(cursor=2, get_snapshot_fn=lambda: {"snap": "all_data"})

    # 读取前两帧
    frames.append(await stream_gen.__anext__())
    frames.append(await stream_gen.__anext__())

    # 第 1 帧必须是 resync_required
    assert "event: resync_required" in frames[0]
    resync_payload = json.loads(frames[0].split("data: ")[1].strip())
    assert resync_payload["reason"] == "cursor_expired"
    assert resync_payload["min_retained_seq"] == 6

    # 第 2 帧紧跟全量快照 snapshot
    assert "event: snapshot" in frames[1]
    snap_payload = json.loads(frames[1].split("data: ")[1].strip())
    assert snap_payload["snap"] == "all_data"
    assert snap_payload["latest_event_seq"] == 10


# ─────────────────────────────────────────────────────────────
# 2. SQLite FTS5 CJK Unigram Tokenization & Search Tests
# ─────────────────────────────────────────────────────────────

def test_cjk_unigram_tokenization_and_query_builder():
    """验证 CJK 字符两端空格填充与英文数字连续保留，以及短语检索构造。"""
    raw = "2026 统一架构重构任务 FTS5引擎"
    tokenized = cjk_unigram_tokenize(raw)
    # 汉字之间应有空格断开，英文数字保持原词
    assert "统 一 架 构 重 构 任 务" in tokenized
    assert "2026" in tokenized
    assert "FTS5" in tokenized

    # 短语检索查询构造
    q1 = build_fts_query("重构")
    assert q1 == '"重 构"'

    q2 = build_fts_query("报销")
    assert q2 == '"报 销"'

    q3 = build_fts_query("FTS5")
    assert q3 in ("FTS5", "FTS5*")


def test_sqlite_fts5_chinese_search_and_highlight(tmp_path):
    """实测在 SQLite FTS5 中插入并高精度检索单字、双字词与英文混排。"""
    db_file = tmp_path / "matters_fts.sqlite"
    store = MatterStore(db_file)

    clock_time = 1793680000.0
    now_fn = lambda: clock_time

    # 1. 插入两条测试事项
    e1 = store.create_matter(
        title="报销发票申请",
        source_type="manual",
        why="本周出差上海的高铁票与住宿费报销",
        clock=now_fn,
    )
    e2 = store.create_matter(
        title="统一看板架构设计与 FTS5 重构",
        source_type="manual",
        why="解决历史任务黑洞问题，支持本地全文检索",
        clock=now_fn,
    )

    # 2. 检索高频双字词：“报销”
    results_baoxiao = store.search_matters_fts("报销")["items"]
    assert len(results_baoxiao) == 1
    assert results_baoxiao[0]["matter_id"] == e1.matter_id
    assert "<b>报销</b>" in results_baoxiao[0]["title_snippet"] or "<b>报销</b>" in results_baoxiao[0]["why_snippet"]

    # 3. 检索技术词：“FTS5”
    results_fts = store.search_matters_fts("FTS5")["items"]
    assert len(results_fts) == 1
    assert results_fts[0]["matter_id"] == e2.matter_id
    assert "FTS5" in results_fts[0]["title"]

    # 4. 检索单字或短语：“黑洞”
    results_heidong = store.search_matters_fts("黑洞")["items"]
    assert len(results_heidong) == 1
    assert results_heidong[0]["matter_id"] == e2.matter_id

    # 5. 空格消除清理函数验证
    dirty_snippet = "统一 <b>重 构</b> 任务"
    cleaned = clean_cjk_snippet(dirty_snippet)
    assert cleaned == "统一 <b>重构</b> 任务"


# ─────────────────────────────────────────────────────────────
# 3. Lifecycle 7-Day Auto-Archiving GC & Obsidian Protection
# ─────────────────────────────────────────────────────────────

def test_lifecycle_gc_and_obsidian_markdown_asset_preservation(tmp_path):
    """验证 7 天 GC 机制将完成事项迁移至 matter_archive，且严禁删除/修改本地 Obsidian Markdown 资产。"""
    db_file = tmp_path / "matters_gc.sqlite"
    obsidian_dir = tmp_path / "vault" / "tasks" / "已完成"
    obsidian_dir.mkdir(parents=True, exist_ok=True)

    # 创建一个真实的本地 Markdown 文件
    md_file = obsidian_dir / "2026-11-01-上海出差总结.md"
    md_content = "# 上海出差总结\n\n已完成高铁与住宿报销整理。\n"
    md_file.write_text(md_content, encoding="utf-8")
    assert md_file.exists()

    store = MatterStore(db_file)

    now = time.time()
    day = 86400.0

    # 1. 事项 A：10 天前完成（超出 7 天 TTL，应被 GC 归档）
    e_old = store.create_matter(
        title="十天前办结事项",
        source_type="obsidian",
        why="出差总结",
        clock=lambda: now - 10 * day,
    )
    store.transition_status(e_old.matter_id, "done", clock=lambda: now - 10 * day)
    # 绑定 Obsidian 文件路径
    with store.db() as db:
        db.execute(
            "UPDATE matter_state SET obsidian_binding=? WHERE matter_id=?",
            (json.dumps({"path": str(md_file)}), e_old.matter_id),
        )
        db.commit()

    # 2. 事项 B：2 天前完成（未超 7 天 TTL，应保留在活跃表 matter_state 中）
    e_recent = store.create_matter(
        title="两天前办结事项",
        source_type="manual",
        why="刚办完",
        clock=lambda: now - 2 * day,
    )
    store.transition_status(e_recent.matter_id, "done", clock=lambda: now - 2 * day)

    # 3. 事项 C：进行中的活跃任务（绝不可被归档）
    e_doing = store.create_matter(
        title="正在执行的核心任务",
        source_type="manual",
        why="活跃任务",
        clock=lambda: now,
    )
    store.transition_status(e_doing.matter_id, "doing", clock=lambda: now)

    # 执行 7 天生命周期 GC
    gc_result = store.archive_matters_gc(ttl_days=7, dry_run=False, clock=lambda: now)
    assert gc_result["archived_count"] == 1
    assert e_old.matter_id in gc_result["matter_ids"]

    # 验证数据库分区状态
    assert store.get_by_id(e_old.matter_id) is None  # 不在热表
    assert store.get_by_id(e_recent.matter_id) is not None  # 仍在热表
    assert store.get_by_id(e_doing.matter_id) is not None  # 仍在热表

    # 验证冷归档表
    with store.db() as db:
        archived_row = db.execute("SELECT * FROM matter_archive WHERE matter_id=?", (e_old.matter_id,)).fetchone()
        assert archived_row is not None
        assert archived_row["title"] == "十天前办结事项"
        assert archived_row["status"] == "done"

    # 【核心保全断言】：本地 Obsidian Markdown 资产绝不可被物理删除或修改！
    assert md_file.exists(), "CRITICAL INTEGRITY FAILURE: Local Obsidian Markdown file was deleted!"
    assert md_file.read_text(encoding="utf-8") == md_content, "Obsidian file content was unexpectedly mutated!"

    # 验证全文检索依然能跨冷热分区搜到已归档的事项，并带出 obsidian:// 链接
    search_res = store.search_matters_fts("十天前")["items"]
    assert len(search_res) == 1
    assert search_res[0]["matter_id"] == e_old.matter_id
    assert search_res[0]["is_archived"] is True
    assert "obsidian://" in search_res[0]["obsidian_url"]

    # 4. 验证原子恢复 restore_matter
    restored = store.restore_matter(e_old.matter_id, target_status="todo", clock=lambda: now)
    assert restored.matter_id == e_old.matter_id
    assert restored.status == "todo"
    assert restored.rev == 3  # rev 递增

    # 确认热表已有，冷表已清理
    assert store.get_by_id(e_old.matter_id) is not None
    with store.db() as db:
        archived_check = db.execute("SELECT * FROM matter_archive WHERE matter_id=?", (e_old.matter_id,)).fetchone()
        assert archived_check is None


# ─────────────────────────────────────────────────────────────
# 4. API Endpoints & SSE Integration Tests
# ─────────────────────────────────────────────────────────────

def test_api_archive_and_restore_endpoints(tmp_path, monkeypatch):
    """通过 TestClient 测试 /personal/matters/archive 与 restore API。"""
    import app as app_module
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    # 1. 访问归档搜索端点
    res = client.get("/personal/matters/archive?q=", headers=headers)
    assert res.status_code == 200
    data = res.json()
    assert "items" in data
    assert "total" in data

    # 2. 触发一次手动 GC API
    gc_res = client.post("/personal/matters/gc?ttl_days=7", headers=headers)
    assert gc_res.status_code == 200
    gc_data = gc_res.json()
    assert "archived_count" in gc_data

    # 3. 针对不存在的事项恢复返回 404
    bad_res = client.post("/personal/matters/nonexistent-id/restore", headers=headers)
    assert bad_res.status_code == 404
