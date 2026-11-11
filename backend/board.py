"""四列看板：建议 / 需要做 / 正在做 / 已完成（P0 契约见 docs/COM_NEXT_KANBAN_PLAN_20261103.md §6）。"""
import asyncio
import hashlib
import json
import re
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
from datetime import datetime
from typing import Any
from urllib.parse import quote
from zoneinfo import ZoneInfo

from cases import ACTIVE
from matter_schema import (
    FSM_STATES,
    MATTER_ID_REGEX,
    VALID_TRANSITIONS,
    MatterConflict,
    MatterIllegalTransition,
    MatterNotFound,
    MatterStore,
    generate_matter_id,
    validate_matter_id,
)
from next_steps import REASONS
from today import _front, com_id_derive

TZ = ZoneInfo('Asia/Shanghai')
ICLOUD_TIMEOUT = 8
SUGGEST_MAX = 5
READY_MAX = 2
DONE_MAX = 10


def _safe_matter_id(raw_id: Any, ts: float, candidate: Any = None) -> str:
    if isinstance(candidate, str) and MATTER_ID_REGEX.match(candidate):
        return candidate
    cleaned = re.sub(r'^(com_|todo_|next:|todo:)+', '', str(raw_id or '').lower())
    cleaned = re.sub(r'[^a-z0-9]', '', cleaned)
    if len(cleaned) < 8:
        cleaned = (cleaned + hashlib.sha256(str(raw_id or 'mtr').encode()).hexdigest())[:8]
    else:
        cleaned = cleaned[:8]
    try:
        day = datetime.fromtimestamp(float(ts or 0), TZ).strftime('%Y%m%d')
    except Exception:
        day = datetime.now(TZ).strftime('%Y%m%d')
    return f"mtr-{day}-{cleaned}"


class BoardError(Exception):
    """看板写失败（映射 HTTP）。"""


class BoardConflict(BoardError):
    def __init__(
        self,
        message: str = "版本已失效，已被其他端更新",
        latest: Any = None,
        requested_rev: Any = None,
        current_rev: Any = None,
        diff: Any = None,
    ):
        super().__init__(message)
        self.latest = latest
        self.requested_rev = requested_rev
        self.current_rev = current_rev
        self.diff = diff


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


class CrossEventLoopAsyncLock:
    """Async lock safe across multiple threads / distinct event loops (e.g. Starlette TestClient)."""
    def __init__(self):
        self._lock = threading.Lock()

    async def __aenter__(self):
        while not self._lock.acquire(blocking=False):
            await asyncio.sleep(0.001)
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        try:
            self._lock.release()
        except RuntimeError:
            pass


class PersonalBoard:
    def __init__(self, state, today, next_steps, cases, clock=time.time):
        self.state = state
        self.today = today
        self.next_steps = next_steps
        self.cases = cases
        self.clock = clock
        self.path = state / 'board-ops.sqlite'
        self.matter_store = MatterStore(state / 'matter-state.sqlite', clock=clock)
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

    def _matter_map(self):
        by_id = {}
        by_legacy = {}
        db = None
        try:
            db = self.matter_store.db()
            rows = db.execute("SELECT matter_id, legacy_id, rev, status FROM matter_state").fetchall()
            for r in rows:
                mid = r['matter_id']
                if not isinstance(mid, str) or not MATTER_ID_REGEX.match(mid):
                    continue
                info = {'matter_id': mid, 'rev': r['rev'], 'status': r['status']}
                by_id[mid] = info
                if r['legacy_id']:
                    by_legacy[r['legacy_id']] = info
        except Exception:
            pass
        finally:
            if db is not None:
                try:
                    db.close()
                except Exception:
                    pass
        return by_id, by_legacy

    def _demoted_todo_map(self):
        out = {}
        try:
            with self.next_steps.db() as db:
                rows = db.execute("SELECT id, data, state FROM items WHERE state IN ('open', 'dismissed', 'snoozed')").fetchall()
            for r in rows:
                d = json.loads(r['data'])
                cid = d.get('demoted_com_id')
                if cid:
                    out[cid] = {'next_id': r['id'], 'mtime_ns': d.get('demoted_mtime_ns'), 'state': r['state']}
        except Exception:
            pass
        return out

    def _demote_todo_to_suggest(self, ident, live_rev=None):
        path = self.today.resolve_com_id(ident)
        if live_rev is None:
            live_rev = int(path.stat().st_mtime_ns)
        front = _front(path)
        com_next_id = front.get('com_next_id', '').strip()
        target_id = None
        now = self.clock()
        if com_next_id:
            with self.next_steps.db() as db:
                row = db.execute('SELECT id, data FROM items WHERE id=?', (com_next_id,)).fetchone()
                if row:
                    target_id = com_next_id
                    item_data = json.loads(row['data'])
                    for k in ('done_via', 'dismiss_reason', 'resolved', 'completed_at', 'todo'):
                        item_data.pop(k, None)
                    item_data['demoted_com_id'] = ident
                    item_data['demoted_mtime_ns'] = int(live_rev)
                    db.execute("UPDATE items SET state='open', data=?, updated_at=? WHERE id=?",
                               (json.dumps(item_data, ensure_ascii=False), now, com_next_id))
                    db.commit()
        if not target_id:
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
                'demoted_com_id': ident,
                'demoted_mtime_ns': int(live_rev),
            }
            with self.next_steps.db() as db:
                db.execute(
                    "INSERT OR REPLACE INTO items (id, data, state, created_at, updated_at) VALUES (?, ?, 'open', ?, ?)",
                    (target_id, json.dumps(new_item, ensure_ascii=False), now, now)
                )
                db.commit()
        return target_id, int(live_rev)

    def _clear_demoted_todo(self, com_id=None, next_id=None):
        try:
            with self.next_steps.db() as db:
                rows = db.execute("SELECT id, data, state FROM items WHERE state IN ('open', 'todo', 'done', 'dismissed', 'snoozed')").fetchall()
                changed = False
                for r in rows:
                    try:
                        d = json.loads(r['data'])
                    except Exception:
                        continue
                    if (com_id and d.get('demoted_com_id') == com_id) or (next_id and r['id'] == next_id):
                        if 'demoted_com_id' in d or 'demoted_mtime_ns' in d:
                            d.pop('demoted_com_id', None)
                            d.pop('demoted_mtime_ns', None)
                            new_state = 'todo' if r['state'] == 'open' else r['state']
                            db.execute("UPDATE items SET state=?, data=? WHERE id=?", (new_state, json.dumps(d, ensure_ascii=False), r['id']))
                            changed = True
                if changed:
                    db.commit()
        except Exception:
            pass

    def _next_rows(self):
        with self.next_steps.db() as db:
            open_rows = [(r['id'], json.loads(r['data']), r['updated_at']) for r in db.execute("SELECT id, data, updated_at FROM items WHERE state='open'")]
            done_rows = [(r['id'], json.loads(r['data']), r['updated_at']) for r in db.execute("SELECT id, data, updated_at FROM items WHERE state='done'")]
            snoozed = sum(1 for r in db.execute("SELECT data FROM items WHERE state='snoozed'")
                          if json.loads(r['data']).get('snooze_until', 0) > self.clock())
        items = [{**d, 'id': ident, 'updated_at': at} for ident, d, at in open_rows]
        demoted_items = [i for i in items if i.get('demoted_com_id')]
        regular_items = [i for i in items if not i.get('demoted_com_id')]
        regular_items = self.next_steps.todo_match(regular_items, board=True)
        items = demoted_items + regular_items
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

    def _todo_cards(self, cases_by_path, matter_by_id=None, matter_by_legacy=None):
        today = datetime.fromtimestamp(self.clock(), TZ).date()
        todo, doing, done = [], [], []
        demoted = self._demoted_todo_map()
        if matter_by_id is None or matter_by_legacy is None:
            matter_by_id, matter_by_legacy = self._matter_map()
        for row in self.today.todo_board_rows() if self.today.vault else []:
            cid = row['com_id']
            d_info = demoted.get(cid)
            if d_info and (d_info['mtime_ns'] is None or int(d_info['mtime_ns']) == int(row['mtime_ns'])):
                continue
            f = row['front']
            project = re.sub(r'^\[\[|\]\]$', '', f.get('关联项目', '')).split('|')[0].strip()
            due_s = f.get('计划结束', '') or ''
            due_d = row['due']
            overdue = bool(due_d and due_d < today and row['state'] == '待处理')
            fallback_mid = _safe_matter_id(cid, row['mtime_ns'] / 1e9, row.get('matter_id'))
            m_info = matter_by_legacy.get('todo:' + cid) or matter_by_id.get(fallback_mid)
            mtr_id = m_info['matter_id'] if m_info else fallback_mid
            mtr_rev = int(m_info['rev']) if m_info else 1
            st = 'todo' if row['state'] == '待处理' else ('doing' if row['state'] == '进行中' else 'done')
            card = {
                'id': 'todo:' + cid,
                'matter_id': mtr_id,
                'status': st,
                'kind': 'todo',
                'title': row['name'],
                'rev': str(row['mtime_ns']),
                'matter_rev': mtr_rev,
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

    def _next_card(self, item, column, matter_by_id=None, matter_by_legacy=None):
        from decisions import next_step_ticket
        ticket = next_step_ticket(item)
        full = {k: item[k] for k in item if k != 'updated_at'}
        full['ticket'] = ticket
        if matter_by_id is None or matter_by_legacy is None:
            matter_by_id, matter_by_legacy = self._matter_map()
        fallback_mid = _safe_matter_id(item['id'], item.get('updated_at', self.clock()), item.get('matter_id'))
        m_info = matter_by_legacy.get('next:' + item['id']) or matter_by_id.get(fallback_mid)
        if not m_info and item.get('demoted_com_id'):
            m_info = matter_by_legacy.get('todo:' + item['demoted_com_id'])
        mtr_id = m_info['matter_id'] if m_info else fallback_mid
        mtr_rev = int(m_info['rev']) if m_info else int(item.get('rev', 1))
        return {
            'id': 'next:' + item['id'],
            'matter_id': mtr_id,
            'status': 'suggested' if column == 'suggest' else 'done',
            'kind': 'next',
            'column': column,
            'title': item.get('title', ''),
            'rev': str(item.get('updated_at', 0)),
            'matter_rev': mtr_rev,
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
        matter_by_id, matter_by_legacy = self._matter_map()
        todo, doing, done_md = self._todo_cards(cases_by_path, matter_by_id, matter_by_legacy)
        suggest_raw, done_next, snoozed = self._next_rows()
        suggest = [self._next_card(i, 'suggest', matter_by_id, matter_by_legacy) for i in suggest_raw]
        done_next_cards = [self._next_card(i, 'done', matter_by_id, matter_by_legacy) for i in done_next]
        done = sorted(done_md + done_next_cards, key=lambda c: -c['completed_at'])[:DONE_MAX]
        columns = {'suggest': suggest, 'suggested': suggest, 'todo': todo, 'doing': doing, 'done': done}
        all_cards = suggest + todo + doing + done
        now = self.clock()
        return {'version': self._version(all_cards), 'updated_at': now, 'snoozed': snoozed, 'columns': columns}

    def _parse_card(self, card_id):
        if not isinstance(card_id, str):
            raise BoardBadRequest('未知 card')
        if card_id.startswith('mtr-'):
            return 'matter', card_id
        if card_id.startswith('next:'):
            return 'next', card_id[5:]
        if card_id.startswith('todo:'):
            return 'todo', card_id[5:]
        raise BoardBadRequest('未知 card')

    def _stored_op(self, op_id, matter_id=None):
        db = self.db()
        try:
            row = db.execute('SELECT result FROM board_ops WHERE op_id=?', (op_id,)).fetchone()
            if not row:
                return None
            res = json.loads(row['result'])
            if matter_id and isinstance(matter_id, str) and matter_id.startswith('mtr-') and isinstance(res, dict):
                cached_mid = (res.get('matter') or {}).get('id') or (res.get('matter') or {}).get('matter_id') or (res.get('card') or {}).get('matter_id')
                if cached_mid and cached_mid != matter_id:
                    return None
            return res
        finally:
            db.close()

    def _save_op(self, op_id, result):
        db = self.db()
        try:
            db.execute('INSERT OR REPLACE INTO board_ops VALUES (?,?,?)', (op_id, json.dumps(result, ensure_ascii=False), self.clock()))
            db.commit()
        finally:
            db.close()

    def _check_rev_todo(self, com_id, rev, force_latest=False):
        path = self.today.resolve_com_id(com_id)
        current = str(path.stat().st_mtime_ns)
        if not force_latest and str(rev) != current:
            raise BoardConflict()
        return int(current)

    @property
    def _lock(self):
        if not hasattr(self, '_board_lock') or self._board_lock is None:
            self._board_lock = CrossEventLoopAsyncLock()
        return self._board_lock

    def _check_rev_next(self, ident, rev, force_latest=False):
        with self.next_steps.db() as db:
            row = db.execute('SELECT updated_at FROM items WHERE id=?', (ident,)).fetchone()
        if not row:
            raise BoardBadRequest('建议不存在')
        if not force_latest and str(rev) != str(row['updated_at']):
            raise BoardConflict('卡片版本已失效')

    def _act_next(self, ident, rev, action, force_latest=False, **extra):
        if action not in ('discuss', 'delegate', 'dismiss', 'done', 'todo', 'snooze', 'drafted'):
            raise BoardBadRequest('不支持的操作')
        with self.next_steps.db() as db:
            row = db.execute('SELECT * FROM items WHERE id=?', (ident,)).fetchone()
            if not row:
                raise BoardBadRequest('建议不存在')
            if not force_latest and str(rev) != str(row['updated_at']):
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

    def _sync_matter_after_board_move(self, body, card, to, ident, kind):
        to_status_map = {
            'suggest': 'suggested',
            'suggested': 'suggested',
            'todo': 'todo',
            'doing': 'doing',
            'done': 'done',
        }
        if to == 'out':
            reason = body.get('reason')
            target_status = 'cancelled' if reason == 'cancelled' else ('snoozed' if reason == 'snooze' else 'dismissed')
        else:
            target_status = to_status_map.get(to, to)
        if target_status not in FSM_STATES:
            target_status = 'todo'

        raw_mid = body.get('matter_id')
        card_mid = card.get('matter_id') if isinstance(card, dict) else None
        legacy_id = (card.get('id') if isinstance(card, dict) else None) or f'{kind}:{ident}'
        matter = None
        for candidate in (raw_mid, card_mid, legacy_id, f'{kind}:{ident}'):
            if candidate and isinstance(candidate, str):
                try:
                    matter = self.matter_store.get_by_id(candidate)
                except ValueError:
                    matter = None
                if matter:
                    break

        obsidian_binding = None
        if isinstance(card, dict) and isinstance(card.get('todo'), dict) and card['todo'].get('path'):
            cid = card['id'][5:] if str(card.get('id', '')).startswith('todo:') else ident
            obsidian_binding = {'path': card['todo']['path'], 'com_id': cid}

        try:
            if matter:
                if matter.status != target_status and target_status in VALID_TRANSITIONS.get(matter.status, set()):
                    matter = self.matter_store.transition_status(
                        matter.matter_id,
                        target_status,
                        expected_rev=None,
                        waiting_reason=body.get('reason'),
                        obsidian_binding=obsidian_binding or matter.obsidian_binding,
                    )
                elif matter.status != target_status:
                    matter = self.matter_store.create_matter(
                        title=(card.get('title') if isinstance(card, dict) else None) or matter.title,
                        source_type=matter.source_type,
                        status=target_status,
                        matter_id=matter.matter_id,
                        legacy_id=legacy_id or matter.legacy_id,
                        rev=matter.rev + 1,
                        why=(card.get('progress') if isinstance(card, dict) else None) or matter.why,
                        obsidian_binding=obsidian_binding or matter.obsidian_binding,
                    )
            else:
                safe_mid = _safe_matter_id(
                    legacy_id,
                    self.clock(),
                    card_mid if isinstance(card_mid, str) else (raw_mid if isinstance(raw_mid, str) else None),
                )
                title = (card.get('title') if isinstance(card, dict) else None) or ident
                source_type = (card.get('kind') if isinstance(card, dict) else None) or kind
                if source_type not in ('next', 'todo', 'manual', 'step', 'wechat', 'mail', 'calendar'):
                    source_type = 'manual'
                matter = self.matter_store.create_matter(
                    title=title,
                    source_type=source_type,
                    status=target_status,
                    matter_id=safe_mid,
                    legacy_id=legacy_id,
                    rev=1,
                    why=(card.get('progress') if isinstance(card, dict) else '') or '',
                    obsidian_binding=obsidian_binding,
                )
            if isinstance(card, dict) and matter:
                card['matter_id'] = matter.matter_id
                card['matter_rev'] = matter.rev
            return matter.to_dict() if matter else None
        except Exception:
            return card if isinstance(card, dict) else None

    async def _move_unified_matter(self, matter_id, to, body, op_id, next_to_todo=None):
        to_status_map = {
            'suggest': 'suggested',
            'suggested': 'suggested',
            'todo': 'todo',
            'doing': 'doing',
            'done': 'done',
        }
        if to == 'out':
            reason = body.get('reason')
            if reason == 'cancelled':
                target_status = 'cancelled'
            elif reason == 'snooze':
                target_status = 'snoozed'
            else:
                target_status = 'dismissed'
        else:
            target_status = to_status_map.get(to, to)

        try:
            matter = self.matter_store.get_by_id(matter_id)
        except ValueError:
            matter = None
        if not matter:
            snap = self.snapshot()
            card = self._find_card(snap, matter_id)
            if card:
                safe_mid = _safe_matter_id(card['id'], self.clock(), matter_id)
                obs_bind = None
                if card.get('kind') == 'todo' and isinstance(card.get('todo'), dict):
                    obs_bind = {'path': card['todo'].get('path'), 'com_id': card['id'][5:]}
                matter = self.matter_store.create_matter(
                    title=card['title'],
                    source_type=card['kind'],
                    status=card['status'],
                    matter_id=safe_mid,
                    legacy_id=card['id'],
                    rev=int(card.get('matter_rev', 1)),
                    why=card.get('why', card.get('progress', '')),
                    obsidian_binding=obs_bind,
                )
            else:
                raise BoardBadRequest(f'事项不存在: {matter_id}')

        force_latest = bool(body.get('force_latest'))
        if force_latest:
            expected_rev = None
        else:
            rev = body.get('matter_rev') if body.get('matter_rev') is not None else body.get('rev')
            # Avoid treating 10-digit Unix timestamps, 19-digit mtime_ns, or floats as 1-based matter_rev
            if rev is not None and str(rev).isdigit() and len(str(rev)) < 9:
                expected_rev = int(rev)
            else:
                expected_rev = None

        if force_latest and matter.status == target_status:
            updated = matter
        else:
            try:
                updated = self.matter_store.transition_status(
                    matter.matter_id,
                    target_status,
                    expected_rev=expected_rev,
                    waiting_reason=body.get('reason'),
                )
            except MatterConflict as exc:
                raise BoardConflict(
                    str(exc),
                    latest=exc.latest,
                    requested_rev=exc.requested_rev,
                    current_rev=exc.current_rev,
                    diff=exc.diff,
                ) from exc
            except MatterIllegalTransition as exc:
                raise BoardBadRequest(str(exc)) from exc
            except MatterNotFound as exc:
                raise BoardBadRequest(str(exc)) from exc

        legacy_id = matter.legacy_id or ''

        # Handle projection to Obsidian / next_steps (strictly non-destructive)
        if target_status in ('todo', 'doing'):
            state_label = '进行中' if target_status == 'doing' else '待处理'
            if legacy_id.startswith('todo:'):
                cid = legacy_id[5:]
                self._clear_demoted_todo(com_id=cid)
                if self.today.vault:
                    try:
                        p = self.today.resolve_com_id(cid)
                        if p.is_file() and _front(p).get('状态') != state_label:
                            self._vault(self.today.todo_set_state, '', state_label, None, com_id=cid)
                    except Exception as exc:
                        self.matter_store.create_outbox_event(
                            matter.matter_id,
                            "obsidian_projection",
                            {"target_status": target_status, "day": body.get("day"), "error": str(exc)},
                        )
            elif next_to_todo:
                try:
                    next_ident = legacy_id[5:] if legacy_id.startswith('next:') else (legacy_id or matter.title)
                    res = await self._vault_async(next_to_todo, next_ident, body.get('day'), body.get('remind_at'), state_label)
                    if legacy_id.startswith('next:'):
                        self._clear_demoted_todo(next_id=next_ident)
                    if res and isinstance(res, dict) and 'todo' in res:
                        todo_info = res['todo']
                        cid = todo_info.get('com_id') or (com_id_derive(todo_info['path']) if todo_info.get('path') else '')
                        if cid:
                            self._clear_demoted_todo(com_id=cid)
                        if todo_info.get('path') and self.today.vault:
                            p = self.today.vault / todo_info['path']
                            if p.is_file() and _front(p).get('状态') != state_label:
                                self._vault(self.today.todo_set_state, todo_info['path'], state_label)
                        updated = self.matter_store.update_matter(
                            matter.matter_id,
                            obsidian_binding={'path': todo_info.get('path'), 'com_id': cid or todo_info.get('com_id')}
                        )
                except Exception as exc:
                    self.matter_store.create_outbox_event(
                        matter.matter_id,
                        "obsidian_projection",
                        {"target_status": target_status, "day": body.get("day"), "error": str(exc)},
                    )
        elif target_status == 'suggested':
            # P08 Fix: Do NOT overwrite Markdown file with '已取消'!
            if legacy_id.startswith('todo:') and self.today.vault:
                try:
                    self._demote_todo_to_suggest(legacy_id[5:])
                except Exception:
                    pass
            elif legacy_id.startswith('next:'):
                try:
                    ident = legacy_id[5:]
                    with self.next_steps.db() as db:
                        row = db.execute('SELECT data, updated_at FROM items WHERE id=?', (ident,)).fetchone()
                        if row:
                            item_data = json.loads(row['data'])
                            for k in ('done_via', 'dismiss_reason', 'resolved', 'completed_at', 'todo'):
                                item_data.pop(k, None)
                            now = max(self.clock(), float(row['updated_at']) + 0.001)
                            db.execute("UPDATE items SET state='open', data=?, updated_at=? WHERE id=?",
                                       (json.dumps(item_data, ensure_ascii=False), now, ident))
                            db.commit()
                except Exception:
                    pass
        elif target_status == 'done':
            if legacy_id.startswith('next:'):
                try:
                    self._act_next(legacy_id[5:], None, 'done', force_latest=True)
                except Exception:
                    pass
            obs_path = (matter.obsidian_binding or {}).get('path')
            if not obs_path and legacy_id.startswith('todo:') and self.today.vault:
                try:
                    p = self.today.resolve_com_id(legacy_id[5:])
                    obs_path = str(p.relative_to(self.today.vault))
                except Exception:
                    obs_path = None
            if obs_path and self.today.vault:
                if legacy_id.startswith('todo:'):
                    self._clear_demoted_todo(com_id=legacy_id[5:])
                try:
                    self._vault(self.today.todo_done, obs_path, from_board=True)
                except Exception as exc:
                    self.matter_store.create_outbox_event(
                        matter.matter_id,
                        "obsidian_projection",
                        {"target_status": target_status, "path": obs_path, "error": str(exc)},
                    )
        elif target_status in ('dismissed', 'snoozed', 'cancelled'):
            if legacy_id.startswith('next:'):
                try:
                    self._act_next(
                        legacy_id[5:],
                        None,
                        'snooze' if target_status == 'snoozed' else 'dismiss',
                        force_latest=True,
                        reason=body.get('reason'),
                    )
                except Exception:
                    pass

        snap = self.snapshot()
        card = self._find_card(snap, matter.matter_id) or (self._find_card(snap, legacy_id) if legacy_id else None) or updated.to_dict()
        out = {
            'ok': True,
            'card': card,
            'matter': updated.to_dict(),
            'version': snap['version'],
            'new_version': snap['version'],
        }
        self._save_op(op_id, out)
        return out

    async def move(self, body, next_to_todo=None, threads=None):
        op_id = body.get('request_id') or body.get('op_id')
        if not isinstance(op_id, str) or not op_id.strip():
            raise BoardBadRequest('缺少 request_id')
        cached = self._stored_op(op_id, body.get('matter_id'))
        if cached is not None:
            return cached
        raw_card = body.get('card')
        if isinstance(raw_card, str) and raw_card.startswith(('todo:', 'next:')):
            card_id = raw_card
        else:
            card_id = body.get('matter_id') or raw_card
        if not card_id or not isinstance(card_id, str):
            raise BoardBadRequest('未知 card')
        to = body.get('to') or body.get('to_status')
        if not to or not isinstance(to, str) or (to not in FSM_STATES and to not in ('suggest', 'suggested', 'out')):
            raise BoardBadRequest('非法移动')

        async with self._lock:
            # Double check inside lock
            cached = self._stored_op(op_id, body.get('matter_id'))
            if cached is not None:
                return cached

            if card_id.startswith('mtr-') or (body.get('matter_id') and not card_id.startswith(('todo:', 'next:'))):
                matter_id = body.get('matter_id') or card_id
                return await self._move_unified_matter(matter_id, to, body, op_id, next_to_todo)

            kind, ident = self._parse_card(card_id)
            if kind == 'matter':
                return await self._move_unified_matter(ident, to, body, op_id, next_to_todo)

            force_latest = bool(body.get('force_latest'))
            rev = body.get('matter_rev') if body.get('rev') is None else body.get('rev')
            reason = body.get('reason')
            if to == 'suggested':
                to = 'suggest'
            if to not in ('suggest', 'todo', 'doing', 'done', 'out'):
                raise BoardBadRequest('非法移动')
            if to == 'todo' and kind == 'todo':
                # 只允许从 doing/done 回到 todo，已在 todo 则幂等
                pass
            try:
                if kind == 'next':
                    if to == 'todo' or to == 'doing':
                        if not next_to_todo:
                            raise BoardError('next_to_todo 未接入')
                        self._check_rev_next(ident, rev, force_latest=force_latest)
                        state = '进行中' if to == 'doing' else '待处理'
                        result = await self._vault_async(next_to_todo, ident, body.get('day'), body.get('remind_at'), state)
                        com_id = result.get('todo', {}).get('com_id') or ''
                        if not com_id:
                            path = result.get('todo', {}).get('path', '')
                            com_id = com_id_derive(path) if path else ''
                        self._clear_demoted_todo(com_id=com_id, next_id=ident)
                        if result.get('todo', {}).get('path') and self.today.vault:
                            todo_path = result['todo']['path']
                            path = self.today.vault / todo_path
                            if path.is_file() and _front(path).get('状态') != state:
                                self._vault(self.today.todo_set_state, todo_path, state)
                        snap = self.snapshot()
                        card = self._find_card(snap, 'todo:' + com_id)
                        matter_dict = self._sync_matter_after_board_move(body, card, to, com_id or ident, 'todo')
                        out = {'ok': True, 'card': card, 'matter': matter_dict, 'version': snap['version'], 'new_version': snap['version']}
                        self._save_op(op_id, out)
                        return out
                    demoted_cid = None
                    if to == 'done':
                        acted_item = self._act_next(ident, rev, 'done', force_latest=force_latest)
                        demoted_cid = acted_item.get('demoted_com_id') if isinstance(acted_item, dict) else None
                        if demoted_cid:
                            self._clear_demoted_todo(com_id=demoted_cid, next_id=ident)
                            if self.today.vault:
                                try:
                                    p = self.today.resolve_com_id(demoted_cid)
                                    rel = str(p.relative_to(self.today.vault))
                                    self._vault(self.today.todo_done, rel, from_board=True)
                                except Exception:
                                    pass
                    elif to == 'suggest':
                        with self.next_steps.db() as db:
                            row = db.execute('SELECT data, updated_at FROM items WHERE id=?', (ident,)).fetchone()
                            if not row:
                                raise BoardBadRequest('建议不存在')
                            if not force_latest and str(rev) != str(row['updated_at']):
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
                        self._act_next(ident, rev, 'dismiss', force_latest=force_latest, reason=reason)
                    else:
                        raise BoardBadRequest('非法移动')
                    snap = self.snapshot()
                    card = (self._find_card(snap, 'todo:' + demoted_cid) if demoted_cid else None) or (self._find_card(snap, card_id) if to != 'out' else None)
                    if not card and to != 'out':
                        with self.next_steps.db() as db:
                            r = db.execute("SELECT data, updated_at FROM items WHERE id=?", (ident,)).fetchone()
                            if r:
                                card = self._next_card({**json.loads(r['data']), 'id': ident, 'updated_at': r['updated_at']}, to)
                    matter_dict = self._sync_matter_after_board_move(body, card, to, ident, 'next')
                    out = {'ok': True, 'card': card, 'matter': matter_dict, 'version': snap['version'], 'new_version': snap['version']}
                    self._save_op(op_id, out)
                    return out
                # todo card
                if to == 'todo':
                    live_rev = self._check_rev_todo(ident, rev, force_latest=force_latest)
                    self._clear_demoted_todo(com_id=ident)
                    self._vault(self.today.todo_set_state, '', '待处理', live_rev if force_latest else int(rev), com_id=ident)
                elif to == 'doing':
                    live_rev = self._check_rev_todo(ident, rev, force_latest=force_latest)
                    self._clear_demoted_todo(com_id=ident)
                    self._vault(self.today.todo_set_state, '', '进行中', live_rev if force_latest else int(rev), com_id=ident)
                elif to == 'done':
                    self._check_rev_todo(ident, rev, force_latest=force_latest)
                    self._clear_demoted_todo(com_id=ident)
                    path = self.today.resolve_com_id(ident)
                    rel = str(path.relative_to(self.today.vault))
                    self._vault(self.today.todo_done, rel, from_board=True)
                elif to == 'suggest':
                    live_rev = self._check_rev_todo(ident, rev, force_latest=force_latest)
                    target_id, _ = self._demote_todo_to_suggest(ident, live_rev=live_rev)
                    if body.get('destructive_cancel') and not (body.get('preserve_markdown') or body.get('non_destructive')):
                        self._vault(self.today.todo_set_state, '', '已取消', live_rev if force_latest else int(rev), com_id=ident)
                    snap = self.snapshot()
                    card = self._find_card(snap, 'next:' + target_id)
                    if not card:
                        with self.next_steps.db() as db:
                            r = db.execute("SELECT data, updated_at FROM items WHERE id=?", (target_id,)).fetchone()
                            if r:
                                card = self._next_card({**json.loads(r['data']), 'id': target_id, 'updated_at': r['updated_at']}, 'suggest')
                    matter_dict = self._sync_matter_after_board_move(body, card, to, ident, 'todo')
                    out = {'ok': True, 'card': card, 'matter': matter_dict, 'version': snap['version'], 'new_version': snap['version']}
                    self._save_op(op_id, out)
                    return out
                elif to == 'out':
                    live_rev = self._check_rev_todo(ident, rev, force_latest=force_latest)
                    self._clear_demoted_todo(com_id=ident)
                    self._vault(self.today.todo_set_state, '', '已取消', live_rev if force_latest else int(rev), com_id=ident)
                snap = self.snapshot()
                card = self._find_card(snap, 'todo:' + ident) if to != 'out' else None
                matter_dict = self._sync_matter_after_board_move(body, card, to, ident, 'todo')
                out = {'ok': True, 'card': card, 'matter': matter_dict, 'version': snap['version'], 'new_version': snap['version']}
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
                if c['id'] == card_id or c.get('matter_id') == card_id:
                    return c
        return None
