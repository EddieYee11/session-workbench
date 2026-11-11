"""看板 GET / POST move：移动语义、幂等、409/503/400。"""
import asyncio
import json
import sys
import time
from pathlib import Path
from unittest import mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from board import BoardBadRequest, BoardConflict, BoardTimeout, PersonalBoard
from next_steps import NextSteps
from today import Today, com_id_derive

NOW = time.mktime((2026, 11, 3, 10, 0, 0, 0, 0, -1))


def _vault(tmp_path):
    root = tmp_path / 'vault'
    pending = root / '任务' / '待处理'
    pending.mkdir(parents=True)
    (root / '任务' / '已完成').mkdir(parents=True)
    return root


def _board(tmp_path, vault=None):
    vault = vault or _vault(tmp_path)
    state = tmp_path / 'state'
    state.mkdir(exist_ok=True)
    today = Today(None, None, vault, clock=lambda: NOW)
    ns = NextSteps(state, vault=vault, clock=lambda: NOW)
    return PersonalBoard(state, today, ns, None, clock=lambda: NOW), today, ns, vault


def _todo(vault, name, state='待处理', end='2026-11-05', done=''):
    rel = f'任务/待处理/{name}.md'
    text = f'---\nflow: 任务\n状态: {state}\n计划结束: {end}\n完成时间: {done}\n下一步: 做\n---\n\n# {name}\n'
    path = vault / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')
    return com_id_derive(rel), rel


def test_snapshot_columns_by_state_not_folder(tmp_path):
    vault = _vault(tmp_path)
    cid, rel = _todo(vault, '积压已完成', state='已完成', done='2026-11-02')
    board, today, ns, vault = _board(tmp_path, vault)
    snap = board.snapshot()
    assert any(c['id'] == 'todo:' + cid for c in snap['columns']['done'])
    assert not any(c['title'] == '积压已完成' for c in snap['columns']['todo'])


def test_todo_set_state_and_com_id(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    cid, rel = _todo(vault, '写看板')
    path = vault / rel
    rev = str(path.stat().st_mtime_ns)
    out = today.todo_set_state(rel, '进行中', int(rev))
    assert out['changed'] and '进行中' in path.read_text(encoding='utf-8')


def test_move_todo_to_doing_and_done(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    cid, rel = _todo(vault, '拖一下')
    path = vault / rel
    rev = str(path.stat().st_mtime_ns)

    async def run():
        r = await board.move({'request_id': 'op-doing-1', 'card': 'todo:' + cid, 'to': 'doing', 'rev': rev})
        assert r['ok'] and r['card']['column'] == 'doing'
        rev2 = str(path.stat().st_mtime_ns)
        r2 = await board.move({'request_id': 'op-done-1', 'card': 'todo:' + cid, 'to': 'done', 'rev': rev2})
        assert r2['ok'] and r2['card']['column'] == 'done'

    asyncio.run(run())


def test_move_idempotent_request_id(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    cid, rel = _todo(vault, '幂等')
    path = vault / rel
    rev = str(path.stat().st_mtime_ns)
    writes = []
    real_write = today._write

    def track_write(path, text, stamp):
        writes.append(1)
        return real_write(path, text, stamp)

    today._write = track_write

    async def run():
        body = {'request_id': 'same-op-99', 'card': 'todo:' + cid, 'to': 'doing', 'rev': rev}
        await board.move(body)
        await board.move(body)
        assert len(writes) == 1

    asyncio.run(run())


def test_move_rev_mismatch_409(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    cid, rel = _todo(vault, '冲突')
    with pytest.raises(BoardConflict):
        asyncio.run(board.move({'request_id': 'op-rev', 'card': 'todo:' + cid, 'to': 'doing', 'rev': '0'}))


def test_move_illegal_400(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    cid, rel = _todo(vault, '非法')
    path = vault / rel
    rev = str(path.stat().st_mtime_ns)
    with pytest.raises(BoardBadRequest):
        asyncio.run(board.move({'request_id': 'op-bad', 'card': 'todo:' + cid, 'to': 'invalid', 'rev': rev}))


def test_move_timeout_503(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    cid, rel = _todo(vault, '超时')
    path = vault / rel
    rev = str(path.stat().st_mtime_ns)
    with mock.patch.object(board, '_vault', side_effect=BoardTimeout()):
        with pytest.raises(BoardTimeout):
            asyncio.run(board.move({'request_id': 'op-slow', 'card': 'todo:' + cid, 'to': 'doing', 'rev': rev}))


def test_next_to_todo_via_move(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    ident = 'abc123'
    item = {'id': ident, 'title': '回邮件', 'why': '急', 'prompt': '起草', 'urgency': 'today', 'score': 90, 'evidence': []}
    with ns.db() as db:
        db.execute('INSERT INTO items VALUES (?,?,?,?,?)', (ident, json.dumps(item, ensure_ascii=False), 'open', NOW, NOW))
        db.commit()

    async def fake_next_to_todo(i, day, remind_at=None, state='待处理'):
        made = today.todo_create('回邮件', day or '2026-11-04', next_id=i, state=state)
        return {'todo': made}

    async def run():
        snap = board.snapshot()
        card = next(c for c in snap['columns']['suggest'] if c['id'] == 'next:' + ident)
        r = await board.move(
            {'request_id': 'op-next-todo', 'card': card['id'], 'to': 'doing', 'rev': card['rev']},
            next_to_todo=fake_next_to_todo,
        )
        assert r['card']['kind'] == 'todo' and r['card']['column'] == 'doing'

    asyncio.run(run())


def test_move_next_done_to_suggest(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    ident = 'done_next_1'
    item = {'id': ident, 'title': '已办完建议', 'why': '测试', 'prompt': '跟进', 'urgency': 'today', 'score': 85,
            'evidence': [], 'done_via': 'elsewhere', 'completed_at': NOW}
    with ns.db() as db:
        db.execute('INSERT INTO items VALUES (?,?,?,?,?)', (ident, json.dumps(item, ensure_ascii=False), 'done', NOW, NOW))
        db.commit()

    async def run():
        snap = board.snapshot()
        card = next(c for c in snap['columns']['done'] if c['id'] == 'next:' + ident)
        r = await board.move({'request_id': 'op-next-suggest-1', 'card': card['id'], 'to': 'suggest', 'rev': card['rev']})
        assert r['ok'] and r['card']['column'] == 'suggest'
        with ns.db() as db:
            row = db.execute('SELECT state, data FROM items WHERE id=?', (ident,)).fetchone()
            assert row['state'] == 'open'
            saved_data = json.loads(row['data'])
            assert 'done_via' not in saved_data and 'completed_at' not in saved_data

        snap_after = board.snapshot()
        assert any(c['id'] == 'next:' + ident for c in snap_after['columns']['suggest'])

    asyncio.run(run())


def test_move_todo_linked_to_suggest(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    ident = 'linked_next_2'
    item = {'id': ident, 'title': '关联下一步', 'why': '原先的下一步', 'prompt': '执行', 'urgency': 'today', 'score': 88, 'evidence': []}
    with ns.db() as db:
        db.execute('INSERT INTO items VALUES (?,?,?,?,?)', (ident, json.dumps(item, ensure_ascii=False), 'todo', NOW, NOW))
        db.commit()

    rel = '任务/待处理/关联下一步.md'
    cid = com_id_derive(rel)
    path = vault / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f'---\nflow: 任务\n状态: 待处理\n计划结束: 2026-11-05\ncom_id: {cid}\ncom_next_id: {ident}\n下一步: 执行\n---\n\n# 关联下一步\n', encoding='utf-8')
    rev = str(path.stat().st_mtime_ns)

    async def run():
        r = await board.move({'request_id': 'op-todo-linked-suggest', 'card': 'todo:' + cid, 'to': 'suggest', 'rev': rev, 'destructive_cancel': True})
        assert r['ok']
        assert r['card']['id'] == 'next:' + ident
        assert r['card']['column'] == 'suggest'

        # Check SQLite reset to open
        with ns.db() as db:
            row = db.execute('SELECT state FROM items WHERE id=?', (ident,)).fetchone()
            assert row['state'] == 'open'

        # Check Vault todo cancelled
        assert '状态: 已取消' in path.read_text(encoding='utf-8')

        # Check snapshot
        snap = board.snapshot()
        assert any(c['id'] == 'next:' + ident for c in snap['columns']['suggest'])
        assert not any(c['id'] == 'todo:' + cid for c in snap['columns']['todo'])

    asyncio.run(run())


def test_move_todo_unlinked_to_suggest(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    cid, rel = _todo(vault, '纯手建待办')
    path = vault / rel
    rev = str(path.stat().st_mtime_ns)

    async def run():
        r = await board.move({'request_id': 'op-todo-unlinked-suggest', 'card': 'todo:' + cid, 'to': 'suggest', 'rev': rev, 'destructive_cancel': True})
        assert r['ok']
        assert r['card']['column'] == 'suggest'
        new_id = r['card']['id'].replace('next:', '')

        # Check SQLite new open item created
        with ns.db() as db:
            row = db.execute('SELECT state, data FROM items WHERE id=?', (new_id,)).fetchone()
            assert row is not None
            assert row['state'] == 'open'
            data = json.loads(row['data'])
            assert data['title'] == '纯手建待办'

        # Check Vault cancelled
        assert '状态: 已取消' in path.read_text(encoding='utf-8')

        # Check snapshot
        snap = board.snapshot()
        assert any(c['id'] == 'next:' + new_id for c in snap['columns']['suggest'])
        assert not any(c['id'] == 'todo:' + cid for c in snap['columns']['todo'])

    asyncio.run(run())


def test_full_roundtrip_suggest_todo_doing_done_suggest(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    ident = 'rt_item_1'
    item = {'id': ident, 'title': '全流程流转', 'why': '测试全向流转', 'prompt': '执行', 'urgency': 'today', 'score': 95, 'evidence': []}
    with ns.db() as db:
        db.execute('INSERT INTO items VALUES (?,?,?,?,?)', (ident, json.dumps(item, ensure_ascii=False), 'open', NOW, NOW))
        db.commit()

    async def fake_next_to_todo(i, day, remind_at=None, state='待处理'):
        made = today.todo_create('全流程流转', day or '2026-11-04', next_id=i, state=state)
        return {'todo': made}

    async def run():
        # Step 1: In suggest
        snap1 = board.snapshot()
        card_sug = next(c for c in snap1['columns']['suggest'] if c['id'] == 'next:' + ident)
        assert card_sug['column'] == 'suggest'

        # Step 2: suggest -> todo
        r_todo = await board.move(
            {'request_id': 'op-rt-1', 'card': card_sug['id'], 'to': 'todo', 'rev': card_sug['rev']},
            next_to_todo=fake_next_to_todo,
        )
        assert r_todo['ok'] and r_todo['card']['kind'] == 'todo' and r_todo['card']['column'] == 'todo'
        todo_cid = r_todo['card']['id'].replace('todo:', '')

        # Step 3: todo -> doing
        r_doing = await board.move(
            {'request_id': 'op-rt-2', 'card': r_todo['card']['id'], 'to': 'doing', 'rev': r_todo['card']['rev']}
        )
        assert r_doing['ok'] and r_doing['card']['column'] == 'doing'

        # Step 4: doing -> done
        r_done = await board.move(
            {'request_id': 'op-rt-3', 'card': r_doing['card']['id'], 'to': 'done', 'rev': r_doing['card']['rev']}
        )
        assert r_done['ok'] and r_done['card']['column'] == 'done'

        # Step 5: done -> suggest (move todo card back to suggest)
        r_back = await board.move(
            {'request_id': 'op-rt-4', 'card': r_done['card']['id'], 'to': 'suggest', 'rev': r_done['card']['rev'], 'destructive_cancel': True}
        )
        assert r_back['ok']
        assert r_back['card']['id'] == 'next:' + ident
        assert r_back['card']['column'] == 'suggest'

        # Verify state in SQLite & Vault
        with ns.db() as db:
            row = db.execute('SELECT state FROM items WHERE id=?', (ident,)).fetchone()
            assert row['state'] == 'open'
        todo_path = today.resolve_com_id(todo_cid)
        assert '状态: 已取消' in todo_path.read_text(encoding='utf-8')

        # Step 6: suggest -> done (direct completion)
        snap_sug2 = board.snapshot()
        card_sug2 = next(c for c in snap_sug2['columns']['suggest'] if c['id'] == 'next:' + ident)
        r_direct_done = await board.move(
            {'request_id': 'op-rt-5', 'card': card_sug2['id'], 'to': 'done', 'rev': card_sug2['rev']}
        )
        assert r_direct_done['ok'] and r_direct_done['card']['column'] == 'done'
        with ns.db() as db:
            row = db.execute('SELECT state FROM items WHERE id=?', (ident,)).fetchone()
            assert row['state'] == 'done'

        # Step 7: done -> suggest (move next card back to suggest)
        r_direct_back = await board.move(
            {'request_id': 'op-rt-6', 'card': r_direct_done['card']['id'], 'to': 'suggest', 'rev': r_direct_done['card']['rev']}
        )
        assert r_direct_back['ok'] and r_direct_back['card']['column'] == 'suggest'
        with ns.db() as db:
            row = db.execute('SELECT state FROM items WHERE id=?', (ident,)).fetchone()
            assert row['state'] == 'open'

    asyncio.run(run())


def test_move_doing_todo_to_suggest(tmp_path):
    board, today, ns, vault = _board(tmp_path)
    cid, rel = _todo(vault, '进行中的待办', state='进行中')
    path = vault / rel
    rev = str(path.stat().st_mtime_ns)

    async def run():
        snap_before = board.snapshot()
        assert any(c['id'] == 'todo:' + cid for c in snap_before['columns']['doing'])

        r = await board.move({'request_id': 'op-doing-to-suggest', 'card': 'todo:' + cid, 'to': 'suggest', 'rev': rev, 'destructive_cancel': True})
        assert r['ok']
        assert r['card']['column'] == 'suggest'
        new_id = r['card']['id'].replace('next:', '')

        # Check SQLite new open item created
        with ns.db() as db:
            row = db.execute('SELECT state FROM items WHERE id=?', (new_id,)).fetchone()
            assert row['state'] == 'open'

        # Check Vault cancelled
        assert '状态: 已取消' in path.read_text(encoding='utf-8')

        # Check snapshot
        snap_after = board.snapshot()
        assert any(c['id'] == 'next:' + new_id for c in snap_after['columns']['suggest'])
        assert not any(c['id'] == 'todo:' + cid for c in snap_after['columns']['doing'])

    asyncio.run(run())


def test_ios_matter_move_payload_and_non_destructive_reverse_drag(tmp_path):
    """回归：iOS BoardModel 发送 matter_id + 10位时间戳 rev + force_latest + non_destructive 时，
    卡片跨列拖拽不得误判 409，且非破坏性逆向拖回 suggest 在 snapshot 中真正移出 todo 进入 suggest。"""
    board, today, ns, vault = _board(tmp_path)
    ident = 'ios_drag_item_1'
    item = {'id': ident, 'title': 'iOS拖拽回归测试', 'why': '验证不回弹', 'prompt': '执行', 'urgency': 'today', 'score': 92, 'evidence': []}
    with ns.db() as db:
        db.execute('INSERT INTO items VALUES (?,?,?,?,?)', (ident, json.dumps(item, ensure_ascii=False), 'open', NOW, NOW))
        db.commit()

    async def fake_next_to_todo(i, day, remind_at=None, state='待处理'):
        made = today.todo_create('iOS拖拽回归测试', day or '2026-11-04', next_id=i, state=state)
        ns.act(i, 'todo', todo={'path': made['path'], 'due': made.get('due', '2026-11-04'), 'remind_at': ''})
        return {'todo': made}

    async def run():
        snap1 = board.snapshot()
        c_sug = next(c for c in snap1['columns']['suggest'] if c['id'] == 'next:' + ident)

        # 1) Simulate legacy iOS payload where only matter_id & 10-digit timestamp rev were forwarded
        r1 = await board.move(
            {
                'request_id': 'op-ios-1',
                'matter_id': c_sug['matter_id'],
                'card': c_sug['id'],
                'to': 'todo',
                'rev': int(float(c_sug['rev'])),
                'matter_rev': c_sug['matter_rev'],
                'force_latest': True,
                'non_destructive': True,
            },
            next_to_todo=fake_next_to_todo,
        )
        assert r1['ok'] and r1['card']['column'] == 'todo'
        todo_card = r1['card']
        todo_cid = todo_card['id'].replace('todo:', '')
        todo_path = today.resolve_com_id(todo_cid)

        # 2) Non-destructive reverse drag: todo -> suggest (Obsidian file NOT marked 已取消, but snapshot moves it to suggest)
        r2 = await board.move(
            {
                'request_id': 'op-ios-2',
                'matter_id': todo_card['matter_id'],
                'card': todo_card['id'],
                'to': 'suggest',
                'rev': todo_card['rev'],
                'matter_rev': todo_card['matter_rev'],
                'force_latest': True,
                'non_destructive': True,
            },
            next_to_todo=fake_next_to_todo,
        )
        assert r2['ok'] and r2['card']['column'] == 'suggest'
        assert '状态: 已取消' not in todo_path.read_text(encoding='utf-8')
        snap2 = board.snapshot()
        assert any(c['id'] == 'next:' + ident for c in snap2['columns']['suggest'])
        assert not any(c['id'] == 'todo:' + todo_cid for c in snap2['columns']['todo'])

        # 3) Forward drag from suggest -> doing: file state updates to 进行中 and appears in doing
        sug_card2 = r2['card']
        r3 = await board.move(
            {
                'request_id': 'op-ios-3',
                'matter_id': sug_card2['matter_id'],
                'card': sug_card2['id'],
                'to': 'doing',
                'rev': sug_card2['rev'],
                'matter_rev': sug_card2['matter_rev'],
                'force_latest': True,
                'non_destructive': True,
            },
            next_to_todo=fake_next_to_todo,
        )
        assert r3['ok'] and r3['card']['column'] == 'doing'
        assert '状态: 进行中' in todo_path.read_text(encoding='utf-8')
        snap3 = board.snapshot()
        assert any(c['id'] == 'todo:' + todo_cid for c in snap3['columns']['doing'])
        assert not any(c['id'] == 'next:' + ident for c in snap3['columns']['suggest'])

    asyncio.run(run())
