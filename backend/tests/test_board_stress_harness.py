"""Adversarial stress harness for PersonalBoard.
Comprehensive empirical test suite covering:
1. Multi-hop state transitions and cycles
2. Stale revision concurrency conflicts (409 BoardConflict)
3. Idempotent request_id caching
4. Malformed and edge-case inputs
5. SQLite and Obsidian Vault persistence and consistency
"""
import asyncio
import json
import os
import sys
import time
from pathlib import Path
from unittest import mock
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from board import BoardBadRequest, BoardConflict, BoardError, BoardTimeout, PersonalBoard
from next_steps import NextSteps
from today import Today, com_id_derive, _front

NOW = 1793686314.0


def _setup_board(tmp_path):
    root = tmp_path / 'vault'
    pending = root / '任务' / '待处理'
    pending.mkdir(parents=True)
    (root / '任务' / '已完成').mkdir(parents=True)
    state = tmp_path / 'state'
    state.mkdir(exist_ok=True)
    current_time = [NOW]

    def get_time():
        return current_time[0]

    def advance_time(seconds=1.0):
        current_time[0] += seconds
        return current_time[0]

    today = Today(None, None, root, clock=get_time)
    ns = NextSteps(state, vault=root, clock=get_time)
    board = PersonalBoard(state, today, ns, None, clock=get_time)

    async def real_like_next_to_todo(ident, day=None, remind_at=None, state='待处理'):
        """Mirroring backend/app.py next_to_todo implementation."""
        item = ns.get(ident)
        day_str = day or '2026-11-06'
        made = today.todo_create(
            item['title'],
            day_str,
            item.get('prompt', '')[:200],
            item.get('why', ''),
            item.get('prompt', ''),
            ident,
            (),
            '',
            '',
            state,
        )
        if made.get('status') == 'exists':
            front = _front(root / made['path'])
            if front.get('状态') == '已取消':
                today.todo_set_state(made['path'], state)
        ns.act(ident, 'todo', todo={'path': made['path'], 'due': made.get('due', day_str)})
        return {'status': 'completed', 'id': ident, 'action': 'todo', 'todo': made}

    return board, today, ns, root, get_time, advance_time, real_like_next_to_todo


# =========================================================================
# 1. MULTI-HOP MOVES & STATE MACHINE INTEGRITY
# =========================================================================

def test_multihop_cycle_1_full(tmp_path):
    """Test standard single cycle: suggest -> todo -> doing -> done -> suggest"""
    board, today, ns, vault, get_time, advance_time, next_to_todo = _setup_board(tmp_path)

    ident = 'item_c1'
    item = {
        'id': ident, 'title': '首轮循环任务', 'why': '测试单轮全向流转',
        'prompt': '执行测试', 'urgency': 'today', 'score': 90, 'evidence': []
    }
    with ns.db() as db:
        db.execute(
            'INSERT INTO items VALUES (?,?,?,?,?)',
            (ident, json.dumps(item, ensure_ascii=False), 'open', get_time(), get_time())
        )
        db.commit()

    async def run():
        # 1. suggest -> todo
        snap = board.snapshot()
        card_sug = next(c for c in snap['columns']['suggest'] if c['id'] == 'next:' + ident)
        r1 = await board.move(
            {'request_id': 'op-1', 'card': card_sug['id'], 'to': 'todo', 'rev': card_sug['rev']},
            next_to_todo=next_to_todo
        )
        assert r1['ok'] and r1['card']['column'] == 'todo'
        todo_cid = r1['card']['id'].replace('todo:', '')

        # 2. todo -> doing
        advance_time()
        r2 = await board.move(
            {'request_id': 'op-2', 'card': r1['card']['id'], 'to': 'doing', 'rev': r1['card']['rev']}
        )
        assert r2['ok'] and r2['card']['column'] == 'doing'

        # 3. doing -> done
        advance_time()
        r3 = await board.move(
            {'request_id': 'op-3', 'card': r2['card']['id'], 'to': 'done', 'rev': r2['card']['rev']}
        )
        assert r3['ok'] and r3['card']['column'] == 'done'

        # 4. done -> suggest
        advance_time()
        r4 = await board.move(
            {'request_id': 'op-4', 'card': r3['card']['id'], 'to': 'suggest', 'rev': r3['card']['rev'], 'destructive_cancel': True}
        )
        assert r4['ok'] and r4['card']['column'] == 'suggest'
        assert r4['card']['id'] == 'next:' + ident

        # Persistence verification
        with ns.db() as db:
            row = db.execute('SELECT state FROM items WHERE id=?', (ident,)).fetchone()
            assert row['state'] == 'open'
        todo_path = today.resolve_com_id(todo_cid)
        assert '状态: 已取消' in todo_path.read_text(encoding='utf-8')

    asyncio.run(run())


def test_rapid_multihop_cycle_suggest_todo_doing_done_suggest_todo(tmp_path):
    """Stress test: Rapid back-and-forth multi-hop moves across 2 full cycles.
    suggest -> todo -> doing -> done -> suggest -> todo -> doing -> done -> suggest
    Demonstrates that moving back to suggest marks the Vault file '已取消', but moving to todo again
    fails to reactivate the cancelled file, causing card to vanish (None).
    """
    board, today, ns, vault, get_time, advance_time, next_to_todo = _setup_board(tmp_path)

    ident = 'cycle_item_adversarial'
    item = {
        'id': ident,
        'title': '多轮循环测试待办',
        'why': '验证多轮状态机迁移与持久化',
        'prompt': '执行测试任务',
        'urgency': 'today',
        'score': 90,
        'evidence': [],
    }
    with ns.db() as db:
        db.execute(
            'INSERT INTO items VALUES (?,?,?,?,?)',
            (ident, json.dumps(item, ensure_ascii=False), 'open', get_time(), get_time())
        )
        db.commit()

    async def run():
        # === CYCLE 1 ===
        snap = board.snapshot()
        card = next((c for c in snap['columns']['suggest'] if c['id'] == 'next:' + ident), None)
        assert card is not None and card['column'] == 'suggest'

        # suggest -> todo
        advance_time(1)
        r = await board.move({'request_id': 'op-c1-1', 'card': card['id'], 'to': 'todo', 'rev': card['rev']}, next_to_todo=next_to_todo)
        assert r['ok'] and r['card']['column'] == 'todo'
        todo_cid = r['card']['id'].replace('todo:', '')

        # todo -> doing
        advance_time(1)
        r = await board.move({'request_id': 'op-c1-2', 'card': r['card']['id'], 'to': 'doing', 'rev': r['card']['rev']})
        assert r['ok'] and r['card']['column'] == 'doing'

        # doing -> done
        advance_time(1)
        r = await board.move({'request_id': 'op-c1-3', 'card': r['card']['id'], 'to': 'done', 'rev': r['card']['rev']})
        assert r['ok'] and r['card']['column'] == 'done'

        # done -> suggest
        advance_time(1)
        r = await board.move({'request_id': 'op-c1-4', 'card': r['card']['id'], 'to': 'suggest', 'rev': r['card']['rev'], 'destructive_cancel': True})
        assert r['ok'] and r['card']['id'] == 'next:' + ident and r['card']['column'] == 'suggest'

        # === CYCLE 2: The critical re-entry! ===
        # suggest -> todo (SECOND TIME!)
        advance_time(1)
        card_c2 = r['card']
        r = await board.move({'request_id': 'op-c2-1', 'card': card_c2['id'], 'to': 'todo', 'rev': card_c2['rev']}, next_to_todo=next_to_todo)
        assert r['ok'], f"Cycle 2 move to todo failed: {r}"
        # BUG HERE: r['card'] is None!
        assert r['card'] is not None, "CRITICAL BUG: card disappeared (None) on second cycle to todo!"
        assert r['card']['column'] == 'todo'

    asyncio.run(run())


def test_todo_card_internal_transitions(tmp_path):
    """Test transitions within todo card states: todo -> doing -> todo -> done -> todo"""
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    # Create a native todo card in vault
    rel = '任务/待处理/内部流转待办.md'
    cid = com_id_derive(rel)
    path = vault / rel
    path.write_text(f'---\nflow: 任务\n状态: 待处理\ncom_id: {cid}\n计划结束: 2026-11-06\n---\n# 内部流转待办\n', encoding='utf-8')

    async def run():
        # 1. todo -> doing
        rev0 = str(path.stat().st_mtime_ns)
        r1 = await board.move({'request_id': 'op-t-1', 'card': 'todo:' + cid, 'to': 'doing', 'rev': rev0})
        assert r1['ok'] and r1['card']['column'] == 'doing'
        assert '状态: 进行中' in path.read_text(encoding='utf-8')

        # 2. doing -> todo (put back to todo)
        rev1 = str(path.stat().st_mtime_ns)
        r2 = await board.move({'request_id': 'op-t-2', 'card': 'todo:' + cid, 'to': 'todo', 'rev': rev1})
        assert r2['ok'] and r2['card']['column'] == 'todo'
        assert '状态: 待处理' in path.read_text(encoding='utf-8')

        # 3. todo -> done
        rev2 = str(path.stat().st_mtime_ns)
        r3 = await board.move({'request_id': 'op-t-3', 'card': 'todo:' + cid, 'to': 'done', 'rev': rev2})
        assert r3['ok'] and r3['card']['column'] == 'done'
        assert '状态: 已完成' in path.read_text(encoding='utf-8')

        # 4. done -> todo (re-open completed todo)
        rev3 = str(path.stat().st_mtime_ns)
        r4 = await board.move({'request_id': 'op-t-4', 'card': 'todo:' + cid, 'to': 'todo', 'rev': rev3})
        assert r4['ok'] and r4['card']['column'] == 'todo'
        assert '状态: 待处理' in path.read_text(encoding='utf-8')

    asyncio.run(run())


def test_next_card_direct_transitions(tmp_path):
    """Test direct suggest -> doing, suggest -> done, done -> suggest, suggest -> out"""
    board, today, ns, vault, get_time, advance_time, next_to_todo = _setup_board(tmp_path)

    ident1 = 'direct_item_1'
    item1 = {'id': ident1, 'title': '直接进行中', 'why': '测试', 'prompt': '做', 'urgency': 'today', 'score': 90, 'evidence': []}
    ident2 = 'direct_item_2'
    item2 = {'id': ident2, 'title': '直接完成', 'why': '测试', 'prompt': '做', 'urgency': 'today', 'score': 85, 'evidence': []}
    ident3 = 'direct_item_3'
    item3 = {'id': ident3, 'title': '直接划掉', 'why': '测试', 'prompt': '做', 'urgency': 'today', 'score': 80, 'evidence': []}

    with ns.db() as db:
        for it in (item1, item2, item3):
            db.execute('INSERT INTO items VALUES (?,?,?,?,?)', (it['id'], json.dumps(it, ensure_ascii=False), 'open', get_time(), get_time()))
        db.commit()

    async def run():
        # 1. suggest -> doing directly
        snap = board.snapshot()
        c1 = next(c for c in snap['columns']['suggest'] if c['id'] == 'next:' + ident1)
        r1 = await board.move(
            {'request_id': 'op-d-1', 'card': c1['id'], 'to': 'doing', 'rev': c1['rev']},
            next_to_todo=next_to_todo
        )
        assert r1['ok'] and r1['card']['column'] == 'doing'
        assert r1['card']['kind'] == 'todo'

        # 2. suggest -> done directly
        snap = board.snapshot()
        c2 = next(c for c in snap['columns']['suggest'] if c['id'] == 'next:' + ident2)
        r2 = await board.move({'request_id': 'op-d-2', 'card': c2['id'], 'to': 'done', 'rev': c2['rev']})
        assert r2['ok'] and r2['card']['column'] == 'done'
        with ns.db() as db:
            row = db.execute('SELECT state FROM items WHERE id=?', (ident2,)).fetchone()
            assert row['state'] == 'done'

        # 3. done -> suggest directly
        r3 = await board.move({'request_id': 'op-d-3', 'card': r2['card']['id'], 'to': 'suggest', 'rev': r2['card']['rev']})
        assert r3['ok'] and r3['card']['column'] == 'suggest'
        with ns.db() as db:
            row = db.execute('SELECT state FROM items WHERE id=?', (ident2,)).fetchone()
            assert row['state'] == 'open'

        # 4. suggest -> out (dismiss)
        snap = board.snapshot()
        c3 = next(c for c in snap['columns']['suggest'] if c['id'] == 'next:' + ident3)
        r4 = await board.move({'request_id': 'op-d-4', 'card': c3['id'], 'to': 'out', 'rev': c3['rev'], 'reason': 'unimportant'})
        assert r4['ok'] and r4['card'] is None
        with ns.db() as db:
            row = db.execute('SELECT state, data FROM items WHERE id=?', (ident3,)).fetchone()
            assert row['state'] == 'dismissed'
            assert json.loads(row['data']).get('dismiss_reason') == 'unimportant'

    asyncio.run(run())


# =========================================================================
# 2. CONCURRENT MOVES & STALE REVISIONS (409 BoardConflict)
# =========================================================================

def test_stale_revision_conflict_todo(tmp_path):
    """Verify that moving a todo card with a stale revision raises 409 BoardConflict."""
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    rel = '任务/待处理/冲突测试待办.md'
    cid = com_id_derive(rel)
    path = vault / rel
    path.write_text(f'---\nflow: 任务\n状态: 待处理\ncom_id: {cid}\n计划结束: 2026-11-06\n---\n# 冲突测试待办\n', encoding='utf-8')

    rev0 = str(path.stat().st_mtime_ns)

    async def run():
        # First move succeeds and updates mtime
        r1 = await board.move({'request_id': 'op-conf-1', 'card': 'todo:' + cid, 'to': 'doing', 'rev': rev0})
        assert r1['ok']

        # Second move using stale rev0 MUST raise BoardConflict
        with pytest.raises(BoardConflict):
            await board.move({'request_id': 'op-conf-2', 'card': 'todo:' + cid, 'to': 'done', 'rev': rev0})

    asyncio.run(run())


def test_stale_revision_conflict_next(tmp_path):
    """Verify that moving a next card with a stale revision raises 409 BoardConflict."""
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    ident = 'next_conf_item'
    item = {'id': ident, 'title': '建议冲突测试', 'why': '测试', 'prompt': '执行', 'urgency': 'today', 'score': 90, 'evidence': []}
    with ns.db() as db:
        db.execute('INSERT INTO items VALUES (?,?,?,?,?)', (ident, json.dumps(item, ensure_ascii=False), 'open', get_time(), get_time()))
        db.commit()

    snap = board.snapshot()
    c = next(c for c in snap['columns']['suggest'] if c['id'] == 'next:' + ident)
    stale_rev = c['rev']

    async def run():
        advance_time()
        # Move 1: suggest -> done (updates updated_at)
        r1 = await board.move({'request_id': 'op-nc-1', 'card': c['id'], 'to': 'done', 'rev': stale_rev})
        assert r1['ok']

        # Move 2: using old stale_rev MUST raise BoardConflict
        with pytest.raises(BoardConflict):
            await board.move({'request_id': 'op-nc-2', 'card': c['id'], 'to': 'suggest', 'rev': stale_rev})

    asyncio.run(run())


def test_concurrent_race_same_card_stale_rev(tmp_path):
    """Stress test: Two concurrent tasks trying to move the same card with the same initial rev.
    Exactly one must succeed, the other must raise BoardConflict (or BoardConflict via lock).
    """
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    rel = '任务/待处理/并发竞态待办.md'
    cid = com_id_derive(rel)
    path = vault / rel
    path.write_text(f'---\nflow: 任务\n状态: 待处理\ncom_id: {cid}\n计划结束: 2026-11-06\n---\n# 并发竞态待办\n', encoding='utf-8')

    rev0 = str(path.stat().st_mtime_ns)

    async def run():
        results = []
        errors = []

        async def worker(op_id, target_col):
            try:
                res = await board.move({'request_id': op_id, 'card': 'todo:' + cid, 'to': target_col, 'rev': rev0})
                results.append((op_id, res))
            except Exception as e:
                errors.append((op_id, e))

        # Launch both concurrently
        await asyncio.gather(
            worker('op-race-1', 'doing'),
            worker('op-race-2', 'done'),
        )

        # One should succeed, one should fail with BoardConflict
        assert len(results) == 1, f"Expected exactly 1 success, got {len(results)}: {results}"
        assert len(errors) == 1, f"Expected exactly 1 error, got {len(errors)}: {errors}"
        assert isinstance(errors[0][1], BoardConflict), f"Expected BoardConflict, got {type(errors[0][1])}: {errors[0][1]}"

    asyncio.run(run())


def test_concurrent_race_next_card_stale_rev(tmp_path):
    """Stress test: Two concurrent tasks trying to move the same next card with the same initial rev.
    Task A moves to 'done', Task B moves to 'out'.
    Exactly one must succeed, the other must fail with BoardConflict.
    """
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    ident = 'next_race_item'
    item = {'id': ident, 'title': '并发竞态建议', 'why': '测试', 'prompt': '执行', 'urgency': 'today', 'score': 90, 'evidence': []}
    with ns.db() as db:
        db.execute('INSERT INTO items VALUES (?,?,?,?,?)', (ident, json.dumps(item, ensure_ascii=False), 'open', get_time(), get_time()))
        db.commit()

    snap = board.snapshot()
    c = next(c for c in snap['columns']['suggest'] if c['id'] == 'next:' + ident)
    rev0 = c['rev']

    async def run():
        results = []
        errors = []

        async def worker(op_id, target_col, reason=None):
            try:
                body = {'request_id': op_id, 'card': c['id'], 'to': target_col, 'rev': rev0}
                if reason:
                    body['reason'] = reason
                res = await board.move(body)
                results.append((op_id, res))
            except Exception as e:
                errors.append((op_id, e))

        await asyncio.gather(
            worker('op-nrace-1', 'done'),
            worker('op-nrace-2', 'out', reason='unimportant'),
        )

        # In a robust concurrent system, exactly 1 should succeed and 1 should fail with BoardConflict
        assert len(results) == 1, f"Concurrency failure: {len(results)} tasks succeeded: {results}"
        assert len(errors) == 1, f"Expected 1 conflict error, got {len(errors)}: {errors}"
        assert isinstance(errors[0][1], BoardConflict)

    asyncio.run(run())


def test_concurrent_race_todo_to_done_stale_rev(tmp_path):
    """Stress test: Two concurrent tasks trying to mark the same todo card done with the same initial rev.
    Task A moves to 'done', Task B moves to 'done'.
    Exactly one must succeed, the second MUST fail with BoardConflict (not succeed silently).
    """
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    rel = '任务/待处理/双重完成待办.md'
    cid = com_id_derive(rel)
    path = vault / rel
    path.write_text(f'---\nflow: 任务\n状态: 待处理\ncom_id: {cid}\n计划结束: 2026-11-06\n---\n# 双重完成待办\n', encoding='utf-8')
    rev0 = str(path.stat().st_mtime_ns)

    async def run():
        results = []
        errors = []

        async def worker(op_id):
            try:
                res = await board.move({'request_id': op_id, 'card': 'todo:' + cid, 'to': 'done', 'rev': rev0})
                results.append((op_id, res))
            except Exception as e:
                errors.append((op_id, e))

        await asyncio.gather(
            worker('op-done-race-1'),
            worker('op-done-race-2'),
        )

        assert len(results) == 1, f"Concurrency defect: both concurrent tasks succeeded on same card! Results: {results}"
        assert len(errors) == 1, f"Expected 1 conflict, got {len(errors)}: {errors}"
        assert isinstance(errors[0][1], BoardConflict)

    asyncio.run(run())




# =========================================================================
# 3. IDEMPOTENT RESPONSE CACHING (request_id)
# =========================================================================

def test_idempotent_request_id_caching(tmp_path):
    """Verify identical response caching and zero extra side-effects on repeated request_id."""
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    rel = '任务/待处理/幂等测试.md'
    cid = com_id_derive(rel)
    path = vault / rel
    path.write_text(f'---\nflow: 任务\n状态: 待处理\ncom_id: {cid}\n计划结束: 2026-11-06\n---\n# 幂等测试\n', encoding='utf-8')

    rev0 = str(path.stat().st_mtime_ns)

    write_count = [0]
    real_write = today._write

    def counting_write(*args, **kwargs):
        write_count[0] += 1
        return real_write(*args, **kwargs)

    today._write = counting_write

    async def run():
        body = {'request_id': 'idempotent-key-42', 'card': 'todo:' + cid, 'to': 'doing', 'rev': rev0}

        # First call
        r1 = await board.move(body)
        assert r1['ok']
        assert write_count[0] == 1

        # Second to fifth sequential calls with same request_id
        for i in range(4):
            r = await board.move(body)
            assert r == r1, f"Mismatch at call {i}: expected {r1}, got {r}"
            assert write_count[0] == 1, f"Write occurred on cached request! Count: {write_count[0]}"

        # Concurrent repeated calls with same request_id
        tasks = [board.move(body) for _ in range(10)]
        concurrent_results = await asyncio.gather(*tasks)
        for r in concurrent_results:
            assert r == r1
            assert write_count[0] == 1

        # Check SQLite board_ops table
        with board.db() as db:
            row = db.execute('SELECT op_id, result FROM board_ops WHERE op_id=?', ('idempotent-key-42',)).fetchone()
            assert row is not None
            assert json.loads(row['result']) == r1

    asyncio.run(run())


# =========================================================================
# 4. MALFORMED MOVES & BOUNDARY CONDITIONS
# =========================================================================

def test_malformed_moves_bad_request(tmp_path):
    """Verify that all malformed inputs raise BoardBadRequest, never unhandled 500s."""
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    rel = '任务/待处理/异常参数测试.md'
    cid = com_id_derive(rel)
    path = vault / rel
    path.write_text(f'---\nflow: 任务\n状态: 待处理\ncom_id: {cid}\n计划结束: 2026-11-06\n---\n# 异常参数测试\n', encoding='utf-8')
    rev0 = str(path.stat().st_mtime_ns)

    async def run():
        # 1. Missing or invalid request_id
        for bad_req in [None, '', '   ', 123, [], {}]:
            with pytest.raises(BoardBadRequest, match='缺少 request_id'):
                await board.move({'request_id': bad_req, 'card': 'todo:' + cid, 'to': 'doing', 'rev': rev0})

        # 2. Invalid target column 'to'
        for bad_to in [None, '', 'invalid_col', 'backlog', 'in_progress', 999]:
            with pytest.raises(BoardBadRequest, match='非法移动'):
                await board.move({'request_id': f'req-bad-to-{bad_to}', 'card': 'todo:' + cid, 'to': bad_to, 'rev': rev0})

        # 3. Invalid card string
        for bad_card in [None, '', 'just_id', 'unknown:123', 456, []]:
            with pytest.raises(BoardBadRequest, match='未知 card'):
                await board.move({'request_id': f'req-bad-card-{bad_card}', 'card': bad_card, 'to': 'doing', 'rev': rev0})

        # 4. 'to: out' without valid reason
        with pytest.raises(BoardBadRequest, match='非法移动'):
            await board.move({'request_id': 'req-bad-out-1', 'card': 'next:some_item', 'to': 'out', 'rev': '1', 'reason': 'invalid_reason'})
        with pytest.raises(BoardBadRequest, match='非法移动'):
            await board.move({'request_id': 'req-bad-out-2', 'card': 'next:some_item', 'to': 'out', 'rev': '1', 'reason': None})

        # 5. Non-existent todo card
        with pytest.raises(BoardBadRequest):
            await board.move({'request_id': 'req-no-todo', 'card': 'todo:non_existent_cid_9999', 'to': 'doing', 'rev': '123'})

    asyncio.run(run())


def test_nonexistent_next_card_behavior(tmp_path):
    """Test behavior when moving non-existent next card.
    Investigating whether it raises BoardConflict or BoardBadRequest.
    """
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    async def run():
        # Non-existent next card must raise BoardBadRequest('建议不存在')
        with pytest.raises(BoardBadRequest, match='建议不存在'):
            await board.move({'request_id': 'req-no-next', 'card': 'next:non_existent_item_9999', 'to': 'done', 'rev': '123'})

    asyncio.run(run())


# =========================================================================
# 5. HIGH-FREQUENCY RAPID MOVES & DATA CONSISTENCY
# =========================================================================

def test_high_frequency_rapid_moves_todo_doing(tmp_path):
    """Stress test: Rapidly bounce a card between todo and doing 20 times.
    Verify state consistency and revision integrity at each hop.
    """
    board, today, ns, vault, get_time, advance_time, _ = _setup_board(tmp_path)

    rel = '任务/待处理/高频跳动待办.md'
    cid = com_id_derive(rel)
    path = vault / rel
    path.write_text(f'---\nflow: 任务\n状态: 待处理\ncom_id: {cid}\n计划结束: 2026-11-06\n---\n# 高频跳动待办\n', encoding='utf-8')

    async def run():
        current_rev = str(path.stat().st_mtime_ns)
        for i in range(20):
            target = 'doing' if i % 2 == 0 else 'todo'
            advance_time(1)
            r = await board.move({'request_id': f'rapid-{i}', 'card': 'todo:' + cid, 'to': target, 'rev': current_rev})
            assert r['ok']
            assert r['card']['column'] == target
            current_rev = r['card']['rev']

            # Verify file content on disk matches
            expected_state = '进行中' if target == 'doing' else '待处理'
            assert f'状态: {expected_state}' in path.read_text(encoding='utf-8')
            assert str(path.stat().st_mtime_ns) == current_rev

    asyncio.run(run())
