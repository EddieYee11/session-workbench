"""四列看板：建议 / 需要做 / 正在做 / 已完成（P0 契约见 docs/COM_NEXT_KANBAN_PLAN_20261103.md §6）。"""
import asyncio
import hashlib
import json
import re
import sqlite3
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
from datetime import datetime
from urllib.parse import quote
from zoneinfo import ZoneInfo

from cases import ACTIVE
from next_steps import REASONS
from today import _front

TZ = ZoneInfo('Asia/Shanghai')
ICLOUD_TIMEOUT = 8
SUGGEST_MAX = 5
READY_MAX = 2
DONE_MAX = 10


class BoardError(Exception):
    """看板写失败（映射 HTTP）。"""


class BoardConflict(BoardError):
    pass


class BoardTimeout(BoardError):
    pass


class BoardBadRequest(BoardError):
    pass


def obsidian_url(rel):
    return 'obsidian://open?vault=obsidian&file=' + quote(rel[:-3] if rel.endswith('.md') else rel)


def _progress_line(path):
    try:
        text = path.read_text(encoding='utf-8', errors='ignore')
    except OSError:
        return ''
    if '## 进展' not in text:
        return ''
    block = text.split('## 进展', 1)[1]
    if '## ' in block:
        block = block.split('## ', 1)[0]
    lines = [ln.strip().lstrip('-').strip() for ln in block.splitlines() if ln.strip().startswith('-')]
    return lines[-1][:200] if lines else ''


def _sources(item):
    kinds = []
    for e in item.get('evidence') or []:
        k = e.get('kind')
        if k and k not in kinds:
            kinds.append(k)
        if len(kinds) >= 3:
            break
    return kinds


class PersonalBoard:
    def __init__(self, state, today, next_steps, cases, clock=time.time):
        self.state = state
        self.today = today
        self.next_steps = next_steps
        self.cases = cases
        self.clock = clock
        self.path = state / 'board-ops.sqlite'
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS board_ops(op_id TEXT PRIMARY KEY, result TEXT NOT NULL, at REAL NOT NULL)')
            db.commit()

    def db(self):
        self.state.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        return db

    def _vault(self, fn, *args, **kwargs):
        with ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(fn, *args, **kwargs)
            try:
                return fut.result(timeout=ICLOUD_TIMEOUT)
            except FuturesTimeout:
                raise BoardTimeout()

    def _active_cases(self):
        out = {}
        if not self.cases:
            return out
        rows = self.cases._rows()
        tasks = {t['id']: t for t in self.cases.store.list()}
        for task_id, row in rows.items():
            if task_id.startswith('turn:'):
                continue
            todo_path = row['data'].get('todo_path') or ''
            if not todo_path:
                continue
            task = tasks.get(task_id)
            if not task or task.get('status') not in ACTIVE:
                continue
            summary = self.cases.summary(task, row)
            prog = summary.get('progress') or {'done': 0, 'total': 0}
            total = int(prog.get('total') or 0)
            done = int(prog.get('done') or 0)
            st = summary.get('state')
            if st == 'waiting':
                status = 'waiting'
            elif st == 'done':
                status = 'done'
            else:
                status = 'running'
            step = done + 1 if status == 'running' and total and done < total else max(done, 1)
            if status == 'done' and total:
                step = total
            out[todo_path] = {'id': task_id, 'status': status, 'step': step, 'total': total or max(step, 1)}
        return out

    def _next_rows(self):
        with self.next_steps.db() as db:
            open_rows = [(r['id'], json.loads(r['data']), r['updated_at']) for r in db.execute("SELECT id, data, updated_at FROM items WHERE state='open'")]
            done_rows = [(r['id'], json.loads(r['data']), r['updated_at']) for r in db.execute("SELECT id, data, updated_at FROM items WHERE state='done'")]
            snoozed = sum(1 for r in db.execute("SELECT data FROM items WHERE state='snoozed'")
                          if json.loads(r['data']).get('snooze_until', 0) > self.clock())
        items = [{**d, 'id': ident, 'updated_at': at} for ident, d, at in open_rows]
        items = self.next_steps.todo_match(items, board=True)
        if self.cases:
            items = [i for i in items if not self.cases.covers_source('next', i['id'])]
        ready = [i for i in items if i.get('phase') == 'ready' or i.get('mandate_id') or i.get('kind') == 'mandate_ready']
        normal = [i for i in items if i not in ready]
        order = {'now': 0, 'today': 1, 'week': 2}
        normal.sort(key=lambda i: (order.get(i.get('urgency'), 1), -i.get('score', 0)))
        ready.sort(key=lambda i: -i.get('score', 0))
        suggest_items = normal[:SUGGEST_MAX] + ready[:READY_MAX]
        now = self.clock()
        cutoff = now - 2 * 86400
        done_items = [{**d, 'id': ident, 'updated_at': at} for ident, d, at in done_rows if at >= cutoff]
        done_items.sort(key=lambda i: -i['updated_at'])
        done_items = done_items[:DONE_MAX]
        return suggest_items, done_items, snoozed

    def _todo_cards(self, cases_by_path):
        today = datetime.fromtimestamp(self.clock(), TZ).date()
        todo, doing, done = [], [], []
        for row in self.today.todo_board_rows() if self.today.vault else []:
            cid = row['com_id']
            f = row['front']
            project = re.sub(r'^\[\[|\]\]$', '', f.get('关联项目', '')).split('|')[0].strip()
            due_s = f.get('计划结束', '') or ''
            due_d = row['due']
            overdue = bool(due_d and due_d < today and row['state'] == '待处理')
            card = {
                'id': 'todo:' + cid,
                'kind': 'todo',
                'title': row['name'],
                'rev': str(row['mtime_ns']),
                'urgency': '',
                'phase': '',
                'due': due_s[:10] if due_s else '',
                'overdue': overdue,
                'sources': [],
                'progress': _progress_line(self.today.vault / row['path']) if row['state'] == '进行中' else '',
                'completed_at': 0,
                'case': cases_by_path.get(row['path']),
                'next': None,
                'todo': {'path': row['path'], 'project': project, 'next_step': f.get('下一步', ''), 'url': obsidian_url(row['path'])},
            }
            if row['completed']:
                card['completed_at'] = datetime.combine(row['completed'], datetime.min.time(), tzinfo=TZ).timestamp()
            if row['state'] == '待处理':
                card['column'] = 'todo'
                todo.append(card)
            elif row['state'] == '进行中':
                card['column'] = 'doing'
                doing.append(card)
            elif row['state'] == '已完成':
                card['column'] = 'done'
                done.append(card)
        todo.sort(key=lambda c: (not c['overdue'], c['due'] or '9999'))
        doing.sort(key=lambda c: -float(c['rev']))
        done.sort(key=lambda c: -c['completed_at'])
        done = done[:DONE_MAX]
        return todo, doing, done

    def _next_card(self, item, column):
        from decisions import next_step_ticket
        ticket = next_step_ticket(item)
        full = {k: item[k] for k in item if k != 'updated_at'}
        full['ticket'] = ticket
        return {
            'id': 'next:' + item['id'],
            'kind': 'next',
            'column': column,
            'title': item.get('title', ''),
            'rev': str(item.get('updated_at', 0)),
            'urgency': item.get('urgency') or '',
            'phase': item.get('phase') or '',
            'due': '',
            'overdue': False,
            'sources': _sources(item),
            'progress': (item.get('history') or [{}])[-1].get('text', '')[:200] if item.get('history') else '',
            'completed_at': item.get('updated_at', 0) if column == 'done' else 0,
            'case': None,
            'next': full,
            'todo': None,
        }

    def _version(self, cards):
        blob = '|'.join(sorted(c['id'] + ':' + str(c['rev']) for c in cards))
        return hashlib.sha256(blob.encode()).hexdigest()[:16]

    def snapshot(self):
        cases_by_path = self._active_cases()
        todo, doing, done_md = self._todo_cards(cases_by_path)
        suggest_raw, done_next, snoozed = self._next_rows()
        suggest = [self._next_card(i, 'suggest') for i in suggest_raw]
        done_next_cards = [self._next_card(i, 'done') for i in done_next]
        done = sorted(done_md + done_next_cards, key=lambda c: -c['completed_at'])[:DONE_MAX]
        columns = {'suggest': suggest, 'todo': todo, 'doing': doing, 'done': done}
        all_cards = suggest + todo + doing + done
        now = self.clock()
        return {'version': self._version(all_cards), 'updated_at': now, 'snoozed': snoozed, 'columns': columns}

    def _parse_card(self, card_id):
        if not isinstance(card_id, str):
            raise BoardBadRequest('未知 card')
        if card_id.startswith('next:'):
            return 'next', card_id[5:]
        if card_id.startswith('todo:'):
            return 'todo', card_id[5:]
        raise BoardBadRequest('未知 card')

    def _stored_op(self, op_id):
        db = self.db()
        try:
            row = db.execute('SELECT result FROM board_ops WHERE op_id=?', (op_id,)).fetchone()
            return json.loads(row['result']) if row else None
        finally:
            db.close()

    def _save_op(self, op_id, result):
        db = self.db()
        try:
            db.execute('INSERT OR REPLACE INTO board_ops VALUES (?,?,?)', (op_id, json.dumps(result, ensure_ascii=False), self.clock()))
            db.commit()
        finally:
            db.close()

    def _check_rev_todo(self, com_id, rev):
        path = self.today.resolve_com_id(com_id)
        current = str(path.stat().st_mtime_ns)
        if str(rev) != current:
            raise BoardConflict()

    @property
    def _lock(self):
        if not hasattr(self, '_board_lock') or self._board_lock is None:
            self._board_lock = asyncio.Lock()
        return self._board_lock

    def _check_rev_next(self, ident, rev):
        with self.next_steps.db() as db:
            row = db.execute('SELECT updated_at FROM items WHERE id=?', (ident,)).fetchone()
        if not row:
            raise BoardBadRequest('建议不存在')
        if str(rev) != str(row['updated_at']):
            raise BoardConflict('卡片版本已失效')

    def _act_next(self, ident, rev, action, **extra):
        if action not in ('discuss', 'delegate', 'dismiss', 'done', 'todo', 'snooze', 'drafted'):
            raise BoardBadRequest('不支持的操作')
        with self.next_steps.db() as db:
            row = db.execute('SELECT * FROM items WHERE id=?', (ident,)).fetchone()
            if not row:
                raise BoardBadRequest('建议不存在')
            if str(rev) != str(row['updated_at']):
                raise BoardConflict('卡片版本已失效')
            item = json.loads(row['data'])
            state = {'discuss': 'acted', 'delegate': 'acted', 'dismiss': 'dismissed', 'done': 'done', 'todo': 'todo', 'snooze': 'snoozed', 'drafted': 'open'}[action]
            if action == 'dismiss' and extra.get('reason') in REASONS:
                if extra['reason'] == 'elsewhere':
                    state, item['done_via'] = 'done', 'elsewhere'
                else:
                    item['dismiss_reason'] = extra['reason']
            for key in ('todo', 'case_id'):
                if extra.get(key):
                    item[key] = extra[key]
            now = max(self.clock(), float(row['updated_at']) + 0.001)
            cur = db.execute(
                'UPDATE items SET state=?, data=?, updated_at=? WHERE id=? AND updated_at=?',
                (state, json.dumps(item, ensure_ascii=False), now, ident, row['updated_at'])
            )
            if cur.rowcount == 0:
                raise BoardConflict('卡片版本已失效')
            db.commit()
        if state == 'dismissed' and item.get('dismiss_reason') != 'others' and getattr(self.next_steps, 'decisions', None):
            self.next_steps.decisions.add('declined', item.get('title', ''), '划掉下一步：' + item.get('title', ''), 'next_step', ident)
        return item

    async def move(self, body, next_to_todo=None, threads=None):
        op_id = body.get('request_id') or body.get('op_id')
        if not isinstance(op_id, str) or not op_id.strip():
            raise BoardBadRequest('缺少 request_id')
        cached = self._stored_op(op_id)
        if cached is not None:
            return cached
        card_id = body.get('card')
        to = body.get('to')
        rev = body.get('rev')
        reason = body.get('reason')
        if to not in ('suggest', 'todo', 'doing', 'done', 'out'):
            raise BoardBadRequest('非法移动')
        kind, ident = self._parse_card(card_id)
        if to == 'todo' and kind == 'todo':
            # 只允许从 doing/done 回到 todo，已在 todo 则幂等
            pass
        async with self._lock:
            cached = self._stored_op(op_id)
            if cached is not None:
                return cached
            try:
                if kind == 'next':
                    if to == 'todo' or to == 'doing':
                        if not next_to_todo:
                            raise BoardError('next_to_todo 未接入')
                        self._check_rev_next(ident, rev)
                        state = '进行中' if to == 'doing' else '待处理'
                        result = await self._vault_async(next_to_todo, ident, body.get('day'), body.get('remind_at'), state)
                        com_id = result.get('todo', {}).get('com_id') or ''
                        if not com_id:
                            path = result.get('todo', {}).get('path', '')
                            from today import com_id_derive
                            com_id = com_id_derive(path) if path else ''
                        snap = self.snapshot()
                        card = self._find_card(snap, 'todo:' + com_id)
                        if not card and result.get('todo', {}).get('path'):
                            todo_path = result['todo']['path']
                            path = self.today.vault / todo_path if self.today.vault else None
                            if path and path.is_file():
                                if _front(path).get('状态') == '已取消':
                                    self._vault(self.today.todo_set_state, todo_path, state)
                                    snap = self.snapshot()
                                    card = self._find_card(snap, 'todo:' + com_id)
                        out = {'ok': True, 'card': card, 'version': snap['version']}
                        self._save_op(op_id, out)
                        return out
                    if to == 'done':
                        self._act_next(ident, rev, 'done')
                    elif to == 'suggest':
                        with self.next_steps.db() as db:
                            row = db.execute('SELECT data, updated_at FROM items WHERE id=?', (ident,)).fetchone()
                            if not row:
                                raise BoardBadRequest('建议不存在')
                            if str(rev) != str(row['updated_at']):
                                raise BoardConflict('卡片版本已失效')
                            item_data = json.loads(row['data'])
                            for k in ('done_via', 'dismiss_reason', 'resolved', 'completed_at', 'todo'):
                                item_data.pop(k, None)
                            now = max(self.clock(), float(row['updated_at']) + 0.001)
                            cur = db.execute(
                                "UPDATE items SET state='open', data=?, updated_at=? WHERE id=? AND updated_at=?",
                                (json.dumps(item_data, ensure_ascii=False), now, ident, row['updated_at'])
                            )
                            if cur.rowcount == 0:
                                raise BoardConflict('卡片版本已失效')
                            db.commit()
                    elif to == 'out':
                        if reason not in REASONS:
                            raise BoardBadRequest('非法移动')
                        self._act_next(ident, rev, 'dismiss', reason=reason)
                    else:
                        raise BoardBadRequest('非法移动')
                    snap = self.snapshot()
                    card = self._find_card(snap, card_id) if to != 'out' else None
                    if not card and to != 'out':
                        with self.next_steps.db() as db:
                            r = db.execute("SELECT data, updated_at FROM items WHERE id=?", (ident,)).fetchone()
                            if r:
                                card = self._next_card({**json.loads(r['data']), 'id': ident, 'updated_at': r['updated_at']}, to)
                    out = {'ok': True, 'card': card, 'version': snap['version']}
                    self._save_op(op_id, out)
                    return out
                # todo card
                if to == 'todo':
                    self._check_rev_todo(ident, rev)
                    self._vault(self.today.todo_set_state, '', '待处理', int(rev), com_id=ident)
                elif to == 'doing':
                    self._check_rev_todo(ident, rev)
                    self._vault(self.today.todo_set_state, '', '进行中', int(rev), com_id=ident)
                elif to == 'done':
                    self._check_rev_todo(ident, rev)
                    path = self.today.resolve_com_id(ident)
                    rel = str(path.relative_to(self.today.vault))
                    self._vault(self.today.todo_done, rel, from_board=True)
                elif to == 'suggest':
                    self._check_rev_todo(ident, rev)
                    path = self.today.resolve_com_id(ident)
                    front = _front(path)
                    com_next_id = front.get('com_next_id', '').strip()
                    target_id = None
                    if com_next_id:
                        with self.next_steps.db() as db:
                            row = db.execute('SELECT id, data FROM items WHERE id=?', (com_next_id,)).fetchone()
                            if row:
                                target_id = com_next_id
                                item_data = json.loads(row['data'])
                                for k in ('done_via', 'dismiss_reason', 'resolved', 'completed_at', 'todo'):
                                    item_data.pop(k, None)
                                now = self.clock()
                                db.execute("UPDATE items SET state='open', data=?, updated_at=? WHERE id=?",
                                           (json.dumps(item_data, ensure_ascii=False), now, com_next_id))
                                db.commit()
                    if not target_id:
                        now = self.clock()
                        target_id = com_next_id if com_next_id else ('todo_' + ident)
                        item_title = path.stem
                        new_item = {
                            'id': target_id,
                            'title': item_title,
                            'why': front.get('备注') or front.get('下一步') or '从待办转为建议',
                            'prompt': front.get('下一步') or item_title,
                            'urgency': 'today',
                            'score': 80,
                            'evidence': [{'ref': f'todo:{ident}', 'kind': 'todo', 'label': item_title, 'detail': ''}],
                            'phase': 'new',
                            'history': [{'at': now, 'text': '从待办转为建议待办', 'phase': 'new', 'refs': []}],
                            'action': None,
                            'source': 'todo',
                        }
                        with self.next_steps.db() as db:
                            db.execute(
                                "INSERT OR REPLACE INTO items (id, data, state, created_at, updated_at) VALUES (?, ?, 'open', ?, ?)",
                                (target_id, json.dumps(new_item, ensure_ascii=False), now, now)
                            )
                            db.commit()
                    self._vault(self.today.todo_set_state, '', '已取消', int(rev), com_id=ident)
                    snap = self.snapshot()
                    card = self._find_card(snap, 'next:' + target_id)
                    if not card:
                        with self.next_steps.db() as db:
                            r = db.execute("SELECT data, updated_at FROM items WHERE id=?", (target_id,)).fetchone()
                            if r:
                                card = self._next_card({**json.loads(r['data']), 'id': target_id, 'updated_at': r['updated_at']}, 'suggest')
                    out = {'ok': True, 'card': card, 'version': snap['version']}
                    self._save_op(op_id, out)
                    return out
                elif to == 'out':
                    self._check_rev_todo(ident, rev)
                    self._vault(self.today.todo_set_state, '', '已取消', int(rev), com_id=ident)
                snap = self.snapshot()
                card = self._find_card(snap, 'todo:' + ident) if to != 'out' else None
                out = {'ok': True, 'card': card, 'version': snap['version']}
                self._save_op(op_id, out)
                return out
            except BoardConflict:
                raise
            except BoardBadRequest:
                raise
            except BoardTimeout:
                raise
            except ValueError as exc:
                if '改过' in str(exc):
                    raise BoardConflict() from exc
                raise BoardBadRequest(str(exc)) from exc

    async def _vault_async(self, fn, *args, **kwargs):
        import asyncio
        try:
            return await asyncio.wait_for(fn(*args, **kwargs), timeout=ICLOUD_TIMEOUT)
        except asyncio.TimeoutError:
            raise BoardTimeout()

    @staticmethod
    def _find_card(snap, card_id):
        for col in snap['columns'].values():
            for c in col:
                if c['id'] == card_id:
                    return c
        return None
