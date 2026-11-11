"""Adversarial stress test suite for Milestone 3 (Archive & FTS5 search).

Empirical challenger tests covering:
1. FTS5 Chinese search edge cases (1-char, 2-char, mixed English/CJK, injection/syntax attacks)
2. Obsidian markdown asset zero-deletion redline (SHA-256 byte-level preservation)
3. Dual-partition state transition consistency & concurrent restore idempotency
4. API query parameter contract verification (`q` vs `query`)
"""
import concurrent.futures
import hashlib
import json
import secrets
import sqlite3
import time
from pathlib import Path
from starlette.testclient import TestClient

import pytest

from matter_schema import (
    MatterConflict,
    MatterError,
    MatterIllegalTransition,
    MatterNotFound,
    MatterStore,
    UnifiedMatterEntity,
    build_fts_query,
    clean_cjk_snippet,
    cjk_unigram_tokenize,
)


# =====================================================================
# 1. FTS5 Chinese Search Edge Cases & Injection Resilience
# =====================================================================

def test_fts5_chinese_1char_and_2char_search(tmp_path):
    """验证 FTS5 中文单字检索（'账', '票', '开'）与双字词检索（'发票', '报销', '周报', '重构'）。"""
    db_file = tmp_path / "matters_cjk.sqlite"
    store = MatterStore(db_file)

    # 准备多条包含单字、双字词的测试事项
    m1 = store.create_matter(title="开具发票报销", source_type="manual", why="出差高铁票与餐饮发票入账")
    m2 = store.create_matter(title="本周技术周报整理", source_type="manual", why="完成会话工作台架构重构与性能优化")
    m3 = store.create_matter(title="银行对账单核对", source_type="manual", why="核对本月收支账目")

    # 单字检索断言
    for char, expected_ids in [
        ("账", {m1.matter_id, m3.matter_id}),
        ("票", {m1.matter_id}),
        ("开", {m1.matter_id}),
    ]:
        res = store.search_matters_fts(char)
        found_ids = {item["matter_id"] for item in res["items"]}
        assert expected_ids.issubset(found_ids), f"Single-char search for {char!r} failed to match {expected_ids}"

    # 双字词检索断言
    for word, expected_id in [
        ("发票", m1.matter_id),
        ("报销", m1.matter_id),
        ("周报", m2.matter_id),
        ("重构", m2.matter_id),
    ]:
        res = store.search_matters_fts(word)
        found_ids = [item["matter_id"] for item in res["items"]]
        assert expected_id in found_ids, f"Two-char search for {word!r} failed to match {expected_id}"


def test_fts5_mixed_english_cjk_and_version_strings(tmp_path):
    """验证中英混排检索：'iOS 优化', 'FTS5 引擎' 及包含版本号点号的 'PRD v2.2.0 重构'。"""
    db_file = tmp_path / "matters_mixed.sqlite"
    store = MatterStore(db_file)

    m1 = store.create_matter(title="iOS 优化与折叠屏适配", source_type="manual", why="优化 iPhone Duo 展开态手势体验")
    m2 = store.create_matter(title="PRD v2.2.0 重构落实", source_type="manual", why="全面对齐 PRD 2.2.0 架构规范")
    m3 = store.create_matter(title="接入 FTS5 引擎实现冷搜索", source_type="manual", why="提高历史任务召回率")

    # 1. "iOS 优化"
    res1 = store.search_matters_fts("iOS 优化")
    assert any(item["matter_id"] == m1.matter_id for item in res1["items"])

    # 2. "FTS5 引擎"
    res3 = store.search_matters_fts("FTS5 引擎")
    assert any(item["matter_id"] == m3.matter_id for item in res3["items"])

    # 3. "PRD v2.2.0 重构" (带点号版本号，必须安全执行且不抛 sqlite3.OperationalError)
    res2 = store.search_matters_fts("PRD v2.2.0 重构")
    assert any(item["matter_id"] == m2.matter_id for item in res2["items"])


def test_fts5_adversarial_syntax_and_injection_strings(tmp_path):
    """攻击性测试：输入 SQL 注入与特殊 FTS5 语法符号，断言零崩溃（无未捕获异常）。"""
    db_file = tmp_path / "matters_adv_fts.sqlite"
    store = MatterStore(db_file)

    store.create_matter(title="安全渗透基线验证事项", source_type="manual", why="用于验证恶意字符串是否引发 SQL 注入或崩溃")

    hostile_queries = [
        "\"'; DROP TABLE matter_fts; --",
        "' OR '1'='1",
        "*",
        "^",
        ":",
        "AND",
        "OR",
        "NOT",
        "NEAR",
        "-foo",
        "(test)",
        "{bad}",
        "foo OR bar",
        "foo AND bar",
        "???",
        "!",
        "@#$%",
        "'''''",
        '"""""',
        "SELECT * FROM matter_state WHERE 1=1;",
    ]

    for q in hostile_queries:
        try:
            res = store.search_matters_fts(q)
            assert isinstance(res, dict)
            assert "items" in res
            assert "total" in res
        except sqlite3.OperationalError as exc:
            pytest.fail(f"CRITICAL STABILITY BUG: Hostile query {q!r} crashed FTS5 with sqlite3.OperationalError: {exc}")
        except Exception as exc:
            pytest.fail(f"CRITICAL STABILITY BUG: Hostile query {q!r} raised unexpected {type(exc).__name__}: {exc}")


# =====================================================================
# 2. Obsidian Markdown File Zero-Deletion Redline
# =====================================================================

def test_obsidian_markdown_zero_deletion_redline(tmp_path):
    """红线测试：真实绑定多份 Obsidian 本地 Markdown 资产，高频多次激进 GC (ttl=0)，

    断言 100% 磁盘文件完整无损、SHA-256 强一致、无一删除或覆写。
    """
    db_file = tmp_path / "matters_gc_redline.sqlite"
    vault_dir = tmp_path / "ObsidianVault" / "Work" / "Matters"
    vault_dir.mkdir(parents=True, exist_ok=True)

    files_manifest: dict[str, dict] = {}

    # 生成 10 份带有真实 Markdown 内容的文件
    for i in range(1, 11):
        filename = f"Task-{i:03d}-关键工作汇报.md"
        filepath = vault_dir / filename
        content = f"""---
title: Task {i} 关键工作汇报
date: 2026-11-0{min(i, 9)}
tags: [work, sohu, project]
---
# 工作任务 {i}

这是 Eddie 的本地重要工作笔记内容。
- 重点事项详情 {i}
- 历史流水凭据与沟通记录
- 严禁任何后台进程与 GC 机制删除此文件！

---
Checksum Seed: {hashlib.sha256(f'seed_{i}'.encode()).hexdigest()}
"""
        filepath.write_text(content, encoding="utf-8")
        files_manifest[filename] = {
            "path": filepath,
            "size": filepath.stat().st_size,
            "sha256": hashlib.sha256(filepath.read_bytes()).hexdigest(),
        }

    store = MatterStore(db_file)
    matter_ids = []

    # 将 10 个 Markdown 文件分别绑定到 10 个已完成事项中
    now = time.time()
    for i, (fname, meta) in enumerate(files_manifest.items(), start=1):
        entity = store.create_matter(
            title=f"事项 {i}: {fname}",
            source_type="obsidian",
            status="todo",
            why=f"关联本地笔记 {fname}",
            obsidian_binding={"path": str(meta["path"])},
            clock=lambda: now - 100000,
        )
        # 转为 done
        store.transition_status(entity.matter_id, "done", clock=lambda: now - 100000)
        matter_ids.append(entity.matter_id)

    # 运行 5 轮激进 GC (ttl_days=0 强制归档全部已办结任务)
    for round_idx in range(1, 6):
        gc_res = store.archive_matters_gc(ttl_days=0, dry_run=False, clock=lambda: now)
        assert gc_res["ok"] is True

        # 断言所有 10 份 Markdown 资产完整无损
        for fname, meta in files_manifest.items():
            fpath: Path = meta["path"]
            assert fpath.exists(), f"REDLINE VIOLATION: File {fname} was DELETED during GC round {round_idx}!"
            assert fpath.stat().st_size == meta["size"], f"REDLINE VIOLATION: File {fname} size altered during GC!"
            current_sha = hashlib.sha256(fpath.read_bytes()).hexdigest()
            assert current_sha == meta["sha256"], f"REDLINE VIOLATION: File {fname} SHA-256 mismatch during GC round {round_idx}!"

    # 验证数据库层面：热表 0 条，冷表 10 条
    assert len(store.list_matters(status="done")) == 0
    with store.db() as db:
        archived_count = db.execute("SELECT COUNT(*) FROM matter_archive").fetchone()[0]
        assert archived_count == 10

    # 抽样恢复 3 条事项，再次断言文件仍然完好
    for mid in matter_ids[:3]:
        restored = store.restore_matter(mid, target_status="todo")
        assert restored.status == "todo"

    for fname, meta in files_manifest.items():
        fpath = meta["path"]
        assert fpath.exists()
        assert hashlib.sha256(fpath.read_bytes()).hexdigest() == meta["sha256"]


# =====================================================================
# 3. Dual-Partition State Transition Consistency & Idempotency
# =====================================================================

def test_dual_partition_lifecycle_transitions(tmp_path):
    """验证热冷双分区流转严格一致性：

    1. 热表 (matter_state) 结项 -> GC 迁移至冷表 (matter_archive)
    2. 全文检索返回 is_archived=True
    3. 恢复 (restore) -> 冷表清除，热表重新呈现 todo 态且 rev 严格单调递增
    4. 全文检索返回 is_archived=False
    """
    db_file = tmp_path / "matters_partition.sqlite"
    store = MatterStore(db_file)

    now = 1793680000.0
    entity = store.create_matter(
        title="双分区一致性生命周期事项",
        source_type="manual",
        why="验证冷热分区隔离与恢复",
        clock=lambda: now,
    )
    mid = entity.matter_id
    initial_rev = entity.rev

    # 1. 活跃状态推进至 done
    entity = store.transition_status(mid, "doing", clock=lambda: now + 10)
    entity = store.transition_status(mid, "done", clock=lambda: now + 20)
    assert entity.rev == initial_rev + 2

    # 2. GC 迁移
    gc_res = store.archive_matters_gc(ttl_days=0, dry_run=False, clock=lambda: now + 100)
    assert mid in gc_res["matter_ids"]

    # 断言热表不存在，冷表存在
    assert store.get_by_id(mid) is None
    with store.db() as db:
        cold_row = db.execute("SELECT * FROM matter_archive WHERE matter_id=?", (mid,)).fetchone()
        assert cold_row is not None
        assert cold_row["status"] == "done"

    # 断言 FTS5 检索显示 is_archived = True
    fts_res = store.search_matters_fts("双分区一致性")
    assert len(fts_res["items"]) == 1
    assert fts_res["items"][0]["matter_id"] == mid
    assert fts_res["items"][0]["is_archived"] is True

    # 3. 恢复至 todo 态
    restored = store.restore_matter(mid, target_status="todo", clock=lambda: now + 200)
    assert restored.matter_id == mid
    assert restored.status == "todo"
    assert restored.rev == entity.rev + 1  # rev 必须递增，防止并发覆盖

    # 断言冷表已清除，热表重现
    with store.db() as db:
        cold_check = db.execute("SELECT * FROM matter_archive WHERE matter_id=?", (mid,)).fetchone()
        assert cold_check is None
    hot_entity = store.get_by_id(mid)
    assert hot_entity is not None
    assert hot_entity.status == "todo"

    # 断言 FTS5 检索显示 is_archived = False
    fts_res_after = store.search_matters_fts("双分区一致性")
    assert len(fts_res_after["items"]) == 1
    assert fts_res_after["items"][0]["matter_id"] == mid
    assert fts_res_after["items"][0]["is_archived"] is False


def test_concurrent_double_restore_idempotency_and_safety(tmp_path):
    """并发测试：多线程同时调用 restore_matter 对同一归档事项执行恢复。

    断言：
    - 不发生死锁或 SQLite 数据库锁坏
    - 绝不导致热表出现重复数据 (PRIMARY KEY integrity)
    - 至少一个恢复成功，并发冲突时另一个得到明确的 MatterNotFound 异常 (HTTP 404 等价物)
    - 最终热表中恰好只有 1 条恢复记录，冷表中彻底清除
    """
    db_file = tmp_path / "matters_concurrent_restore.sqlite"
    store = MatterStore(db_file)

    now = time.time()
    entity = store.create_matter(
        title="并发恢复冲突事项",
        source_type="manual",
        status="done",
        clock=lambda: now - 1000,
    )
    mid = entity.matter_id
    store.archive_matters_gc(ttl_days=0, clock=lambda: now)

    # 验证冷表中已就绪
    with store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM matter_archive WHERE matter_id=?", (mid,)).fetchone()[0] == 1
        assert db.execute("SELECT COUNT(*) FROM matter_state WHERE matter_id=?", (mid,)).fetchone()[0] == 0

    results = []
    errors = []

    def run_restore():
        try:
            res = store.restore_matter(mid, target_status="todo")
            results.append(res)
        except Exception as exc:
            errors.append(exc)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = [executor.submit(run_restore) for _ in range(4)]
        concurrent.futures.wait(futures)

    # 校验结果
    assert len(results) >= 1, "At least one restore must succeed!"
    # 其余并发请求应抛出 MatterNotFound
    for err in errors:
        assert isinstance(err, MatterNotFound), f"Unexpected exception in concurrent restore: {err}"

    # 最终数据完整性断言
    with store.db() as db:
        hot_count = db.execute("SELECT COUNT(*) FROM matter_state WHERE matter_id=?", (mid,)).fetchone()[0]
        cold_count = db.execute("SELECT COUNT(*) FROM matter_archive WHERE matter_id=?", (mid,)).fetchone()[0]
        assert hot_count == 1, f"Expected exactly 1 record in matter_state, found {hot_count}"
        assert cold_count == 0, f"Expected 0 records in matter_archive, found {cold_count}"


# =====================================================================
# 4. API Query Parameter Contract Verification (`q` vs `query`)
# =====================================================================

def test_api_archive_search_query_param_contract():
    """验证 GET /personal/matters/archive API 契约：

    iOS 客户端与 Web 客户端均通过 `?q=<term>` 传递检索关键词。
    服务端必须正确接收 `q` 参数并执行 FTS5 过滤，绝不可静默忽略。
    """
    import app as app_module
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    # 构造唯一关键词
    unique_keyword = f"特异检索词{int(time.time())}"
    if "personal_board" in globals() or getattr(app_module.personal_board, "matter_store", None):
        store = app_module.personal_board.matter_store
        e = store.create_matter(title=f"测试事项_{unique_keyword}", source_type="manual", why="用于测试 API q 参数")
        store.transition_status(e.matter_id, "done")
        store.archive_matters_gc(ttl_days=0)

    # 用 ?q= 检索一个绝不存在的关键词，断言应当返回 0 条匹配，而不是返回冷库全量
    nonexistent_keyword = f"不存在随机词_{secrets.token_hex(8)}"
    res_nonexistent = client.get(f"/personal/matters/archive?q={nonexistent_keyword}", headers=headers)
    assert res_nonexistent.status_code == 200
    data_nonexistent = res_nonexistent.json()
    assert data_nonexistent["total"] == 0, (
        f"API CONTRACT BUG: GET /personal/matters/archive?q={nonexistent_keyword} returned {data_nonexistent['total']} items! "
        "The endpoint declares `query: str | None = None` and silently drops `?q=`, breaking both iOS (MatterArchiveSheet.swift) and Web (next.js)!"
    )

    # 用 ?q= 检索真实存在的关键词
    res_q = client.get(f"/personal/matters/archive?q={unique_keyword}", headers=headers)
    assert res_q.status_code == 200
    data_q = res_q.json()
    assert data_q["total"] >= 1
    assert any(unique_keyword in item["title"] for item in data_q["items"])


def test_adversarial_fts5_exhaustive_punctuation_and_operators(tmp_path):
    """攻击性压测：针对 FTS5 引擎在版本号、复杂标点、通配符、C++ 及保留操作符场景下的健壮性。

    断言：
    1. 零 sqlite3.OperationalError 及 500 崩溃
    2. 针对版本号 (v2.2.0, PRD v2.2.0 重构)、C++、保留关键字 (AND, OR, NOT, NEAR) 准确召回
    3. 纯无意义标点或注入片段安全过滤，返回 total=0 且不泄漏全量数据
    """
    db_file = tmp_path / "matters_fts_exhaustive.sqlite"
    store = MatterStore(db_file)

    m1 = store.create_matter(
        title="PRD v2.2.0 重构与 C++ 引擎优化",
        source_type="manual",
        why="详细技术方案，涉及 C++20 模块化与 v2.2.0-rc1 发版验证，(foo) [bar] {baz} -test +test",
    )
    m2 = store.create_matter(
        title="网络协议与版本兼容性报告",
        source_type="manual",
        why="包含 HTTP/2.0 与 TLS 1.3 协议标准，以及 user@domain.com 联系方式",
    )
    m3 = store.create_matter(
        title="日常会议记录与工作周报",
        source_type="manual",
        why="普通中文任务，不含任何特殊英数字符号",
    )

    # 1. 验证关键版本号和技术词准确召回 m1
    recall_queries = [
        ("PRD v2.2.0 重构", {m1.matter_id}),
        ("v2.2.0", {m1.matter_id}),
        ("C++", {m1.matter_id}),
        ("C++20", {m1.matter_id}),
        ("v2.2.0-rc1", {m1.matter_id}),
        ("引擎优化", {m1.matter_id}),
        ("foo", {m1.matter_id}),
        ("bar", {m1.matter_id}),
        ("baz", {m1.matter_id}),
    ]
    for q, expected in recall_queries:
        res = store.search_matters_fts(q)
        found = {item["matter_id"] for item in res["items"]}
        assert expected.issubset(found), f"Recall failure for query {q!r}: expected {expected}, got {found}"

    # 2. 验证高难度标点、运算符与保留字查询零崩溃
    adversarial_inputs = [
        "PRD v2.2.0 重构",
        "C++",
        "v2.2.0",
        "AND", "OR", "NOT", "NEAR",
        "and", "or", "not", "near",
        "AND OR NOT NEAR",
        "PRD AND 重构 OR NOT 优化",
        "NEAR/5",
        "title:PRD", "why:C++", "unknown_col:test",
        "-foo", "--foo", "---", "+bar", "++bar",
        "foo-bar", "foo_bar", "foo.bar", "foo/bar",
        "user@domain.com", "#tag", "127.0.0.1",
        "(foo", "bar)", "((foo))", "(((", ")))",
        "{foo}", "[bar]", "<baz>",
        "...", "..", ".", "....",
        "?", "???", "!", "!!!", "@", "#", "$", "%", "&", ";", ",", "~", "`",
        "\"foo\"", "\"\"\"foo\"\"\"", "''''bar''''", '"""""',
        "*", "**", "***", "foo*", "*bar", "foo*bar",
        "^foo", "foo^",
        "\\foo", "foo\\bar",
        "🚀 🔥 💡", "🚀 v2.2.0 🔥",
        "日本語のテスト", "한국어 테스트",
        "a" * 1000,
        "\"\"", "''", " ", "   \t\n  ",
        "DROP TABLE matter_fts;",
        "SELECT * FROM matter_archive WHERE 1=1;",
        "1 UNION ALL SELECT 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24;",
    ]
    for q in adversarial_inputs:
        try:
            res = store.search_matters_fts(q)
            assert isinstance(res, dict)
            assert "total" in res
            assert "items" in res
        except sqlite3.OperationalError as exc:
            pytest.fail(f"FTS5 CRASH BUG: Query {q!r} failed with sqlite3.OperationalError: {exc}")
        except Exception as exc:
            pytest.fail(f"UNEXPECTED EXCEPTION: Query {q!r} raised {type(exc).__name__}: {exc}")

    # 3. 纯特殊字符输入必须返回 0 条匹配，绝不能回退为返回全量
    pure_noise_queries = ["***", "...", "!@#$%", "()", "{}", "[]", "   ", ":::"]
    for q in pure_noise_queries:
        res = store.search_matters_fts(q)
        assert res["total"] == 0, f"Pure noise query {q!r} must return total=0, got {res['total']}"
        assert len(res["items"]) == 0


def test_adversarial_api_archive_filter_vs_all_contract():
    """验证 GET /personal/matters/archive API 契约：

    断言：
    1. ?q= 与 ?query= 均能正确过滤检索结果，而非返回全量冷库
    2. 不存在的关键词返回 total=0, items=[]
    3. ?q= 优先级高于 ?query=
    4. ?q= 为空时降级支持 ?query=
    5. 状态过滤参数与全文检索组合生效
    """
    import app as app_module
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    store = app_module.personal_board.matter_store
    uniq = secrets.token_hex(6)

    m_done = store.create_matter(
        title=f"完成事项_{uniq}_PRD_v2.2.0",
        source_type="manual",
        status="done",
        why="已完成版本升级归档",
    )
    m_cancelled = store.create_matter(
        title=f"取消事项_{uniq}_日常维护",
        source_type="manual",
        status="cancelled",
        why="已取消废弃归档",
    )
    store.archive_matters_gc(ttl_days=0)

    # 1. ?q= 过滤正确性
    res_q = client.get(f"/personal/matters/archive?q={uniq}_PRD", headers=headers)
    assert res_q.status_code == 200
    data_q = res_q.json()
    assert data_q["total"] >= 1
    matched_ids = [it["matter_id"] for it in data_q["items"]]
    assert m_done.matter_id in matched_ids
    assert m_cancelled.matter_id not in matched_ids

    # 2. ?query= 兼容性过滤
    res_query = client.get(f"/personal/matters/archive?query={uniq}_日常维护", headers=headers)
    assert res_query.status_code == 200
    data_query = res_query.json()
    assert data_query["total"] >= 1
    matched_ids = [it["matter_id"] for it in data_query["items"]]
    assert m_cancelled.matter_id in matched_ids
    assert m_done.matter_id not in matched_ids

    # 3. 不存在的关键词返回 0 条匹配，不泄漏冷库全量
    res_none = client.get(f"/personal/matters/archive?q=notfound_{secrets.token_hex(8)}", headers=headers)
    assert res_none.status_code == 200
    assert res_none.json()["total"] == 0
    assert len(res_none.json()["items"]) == 0

    # 4. ?q= 优先于 ?query=
    res_both = client.get(
        f"/personal/matters/archive?q={uniq}_PRD&query={uniq}_日常维护",
        headers=headers,
    )
    assert res_both.status_code == 200
    matched_ids = [it["matter_id"] for it in res_both.json()["items"]]
    assert m_done.matter_id in matched_ids
    assert m_cancelled.matter_id not in matched_ids

    # 5. 空白 ?q= 降级使用 ?query=
    res_fallback = client.get(
        f"/personal/matters/archive?q=%20%20&query={uniq}_日常维护",
        headers=headers,
    )
    assert res_fallback.status_code == 200
    matched_ids = [it["matter_id"] for it in res_fallback.json()["items"]]
    assert m_cancelled.matter_id in matched_ids

    # 6. status 组合过滤
    res_status = client.get(
        f"/personal/matters/archive?q={uniq}&status=cancelled",
        headers=headers,
    )
    assert res_status.status_code == 200
    for it in res_status.json()["items"]:
        assert it["status"] == "cancelled"


def test_adversarial_api_gc_dry_run_contract_and_zero_live_deletion():
    """验证 POST /personal/matters/gc 接口安全契约与零活体误删红线：

    断言：
    1. 无 Request Body 时正确解析 URL 查询参数 ?dry_run=true
    2. 支持多种 dry_run 表示形式 (true, 1, True, yes)
    3. dry_run=True 时，绝不向冷表插入数据，绝不从热表删除数据
    4. 活跃状态 (doing, todo, suggested, executing) 的事项绝不被 GC 误删
    """
    import app as app_module
    client = TestClient(app_module.app)
    headers = {"Authorization": f"Bearer {app_module.TOKEN}"}

    store = app_module.personal_board.matter_store

    # 创建各状态事项
    live_doing = store.create_matter(title="活跃中事项", source_type="manual", status="doing")
    live_todo = store.create_matter(title="待办中事项", source_type="manual", status="todo")
    live_suggested = store.create_matter(title="建议中事项", source_type="manual", status="suggested")
    done_matter = store.create_matter(title="已完成待归档事项", source_type="manual", status="done")

    # 1. POST /personal/matters/gc?dry_run=true 无 request body
    resp1 = client.post("/personal/matters/gc?dry_run=true&ttl_days=0", headers=headers)
    assert resp1.status_code == 200
    d1 = resp1.json()
    assert d1["ok"] is True
    assert d1["dry_run"] is True
    assert done_matter.matter_id in d1["matter_ids"]
    assert live_doing.matter_id not in d1["matter_ids"]
    assert live_todo.matter_id not in d1["matter_ids"]
    assert live_suggested.matter_id not in d1["matter_ids"]

    # 断言热表中全部实体均完好，零删除
    assert store.get_by_id(live_doing.matter_id) is not None
    assert store.get_by_id(live_todo.matter_id) is not None
    assert store.get_by_id(live_suggested.matter_id) is not None
    assert store.get_by_id(done_matter.matter_id) is not None

    # 断言冷表中不存在 done_matter
    with store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM matter_archive WHERE matter_id=?", (done_matter.matter_id,)).fetchone()[0] == 0

    # 2. 测试 dry_run=1 与 dry_run=yes 等形式
    for dry_val in ["1", "True", "yes", "ON"]:
        resp = client.post(f"/personal/matters/gc?dry_run={dry_val}&ttl_days=0", headers=headers)
        assert resp.status_code == 200
        assert resp.json()["dry_run"] is True
        # 热表仍未被动
        assert store.get_by_id(done_matter.matter_id) is not None

