"""Durable voice handoff to the user's native Pi account and installed skills."""
import asyncio
import contextlib
import hashlib
import json
import re
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from history import text_content

FINAL = {'completed', 'failed', 'interrupted', 'unknown'}
IN_FLIGHT = {'submitted', 'running', 'executing', 'responding'}


def voice_prompt(text, purpose):
    # This wrapper preserves the original utterance and makes native tool receipts
    # explicit. In particular, a queue ACK is never a financial transaction ACK.
    return (
        '这是 Eddie 从 Com! 快捷语音小窗交办的' + ('已确认金额的记账请求' if purpose == 'expense' else '请求') + '。\n'
        '按当前 Pi 的身份、技能和权限执行用户原话，不扩大用户授权。'
        '记账沿用 bookkeeping 工具：金额和用途完整则按已有默认值添加，'
        '随后用 bookkeeping recent 回查新增 ID、金额和备注；添加结果不确定时先核实，禁止重复添加。'
        '收藏链接沿用 collect skill，保存后回读笔记并核实收藏索引，返回实际文件路径。'
        '回复必须区分已受理、执行中和实际完成；缺少信息或执行失败时如实说明。\n\n'
        '用户原话：\n' + text
    )


def observed_progress(events):
    """Read native Pi records; do not infer completion from assistant prose."""
    phase, active_tool = 'submitted', ''
    messages, calls, operations = {}, {}, []
    received = False
    for i, event in enumerate(events):
        typ, data = event.get('type'), event.get('data', {})
        if typ == 'agent_start':
            phase, received = 'running', True
        elif typ in ('tool_execution_start', 'tool_execution_update'):
            phase, active_tool = 'executing', data.get('toolName', '工具')
            if typ == 'tool_execution_start':
                calls[data.get('toolCallId')] = data.get('args', {})
        elif typ == 'tool_execution_end':
            phase, active_tool = 'running', ''
            result = data.get('result', {})
            args = calls.get(data.get('toolCallId'), {})
            if data.get('toolName') == 'bookkeeping':
                details = result.get('details', {}) if isinstance(result, dict) else {}
                operations.append({'tool': 'bookkeeping', 'action': args.get('action', ''),
                    'success': not bool(data.get('isError')), 'text': text_content(result.get('content', []))[:2000],
                    'details': {**{k: details[k] for k in ('id', 'amount', 'category', 'account', 'time') if k in details},
                                **({'comment': args['comment']} if isinstance(args.get('comment'), str) else {})}})
        elif typ in ('message_update', 'message_end'):
            message = data.get('message', {})
            if message.get('role') == 'assistant':
                text = '\n'.join(c.get('text', '') for c in message.get('content', [])
                                 if isinstance(c, dict) and c.get('type') == 'text')
                if text:
                    phase = 'responding'
                    messages[str(message.get('timestamp', i))] = text
        elif typ == 'agent_settled':
            phase, active_tool = 'completed', ''
    # A native write receipt and a later native readback are both required.
    receipts = []
    for i, operation in enumerate(operations):
        if operation['action'] != 'add' or not operation['success']:
            continue
        ident = operation['details'].get('id')
        amount = operation['details'].get('amount')
        expected_details = operation['details']
        line = re.compile(r'#' + re.escape(str(ident)) + r'(?!\d)[^\n]*') if ident is not None else None
        def matches_readback(operation):
            match = line.search(operation['text']) if line else None
            return bool(match and isinstance(amount, (int, float)) and
                        re.search(r'¥' + re.escape(f'{amount:.2f}') + r'(?!\d)', match[0]) and
                        all(str(operation_value) in match[0] for operation_value in
                            (expected_details.get('category', ''), expected_details.get('comment', ''))))
        readback = next((o for o in operations[i + 1:] if o['action'] == 'recent' and o['success']
                         and matches_readback(o)), None)
        receipts.append({**operation, 'readback_verified': bool(readback),
                         'readback': readback['text'] if readback else ''})
    return {'phase': phase, 'active_tool': active_tool, 'received': received,
            'result': '\n\n'.join(messages.values())[-12000:], 'action_receipts': receipts}


class QuickVoice:
    def __init__(self, state, runtime, cwd):
        self.path = Path(state) / 'quick-voice.sqlite'
        self.legacy_path = Path(state) / 'personal-conversation.sqlite'
        self.runtime, self.cwd = runtime, str(cwd)
        self.loop_task = None
        self.lock = asyncio.Lock()
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS requests(request_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, data TEXT NOT NULL)')
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                db.execute('BEGIN IMMEDIATE')
                yield db
        finally:
            db.close()

    def _save(self, db, receipt):
        receipt['updated_at'] = time.time()
        db.execute('UPDATE requests SET data=? WHERE request_id=?',
                   (json.dumps(receipt, ensure_ascii=False), receipt['request_id']))

    def submit(self, request_id, text, purpose='conversation'):
        if not isinstance(request_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]{10,100}', request_id):
            raise ValueError('缺少有效请求标识')
        if not isinstance(text, str) or not text.strip() or len(text) > 2000:
            raise ValueError('语音内容无效或过长')
        if purpose not in ('conversation', 'expense'):
            raise ValueError('无效的语音用途')
        text = text.strip()
        fingerprint = hashlib.sha256(json.dumps({'text': text, 'purpose': purpose}, sort_keys=True).encode()).hexdigest()
        with self.db() as db:
            old = db.execute('SELECT * FROM requests WHERE request_id=?', (request_id,)).fetchone()
            if old:
                if old['fingerprint'] != fingerprint:
                    raise ValueError('请求标识冲突')
                return json.loads(old['data'])
            # A lost ACK from the pre-Pi app must not become a second action
            # after an upgrade. Read the original durable Hermes receipt first.
            if self._legacy_received(request_id):
                raise ValueError('旧版 Hermes 已接收这条语音，请先核实结果；不会再次交给派。')
            now = time.time()
            receipt = {'request_id': request_id, 'message_id': 'voice_' + hashlib.sha256(request_id.encode()).hexdigest()[:24],
                       'agent': 'pi', 'purpose': purpose, 'text': text, 'status': 'accepted', 'phase': 'queued',
                       'session_id': '', 'run_id': '', 'received_at': None, 'result': '', 'error': '',
                       'active_tool': '', 'action_receipts': [], 'created_at': now, 'updated_at': now}
            db.execute('INSERT INTO requests VALUES(?,?,?)', (request_id, fingerprint, json.dumps(receipt, ensure_ascii=False)))
            return receipt

    def _legacy_received(self, request_id):
        if not self.legacy_path.exists():
            return False
        try:
            with contextlib.closing(sqlite3.connect(f'file:{self.legacy_path}?mode=ro', uri=True, timeout=20)) as db:
                return db.execute('SELECT 1 FROM messages WHERE request_id=? LIMIT 1', (request_id,)).fetchone() is not None
        except sqlite3.Error:
            raise ValueError('旧版语音回执暂无法核实，未交给派；请先核实原消息。') from None

    def receipt(self, request_id):
        with self.db() as db:
            row = db.execute('SELECT data FROM requests WHERE request_id=?', (request_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def _requests(self, limit=None):
        with self.db() as db:
            rows = db.execute('SELECT data FROM requests ORDER BY rowid DESC' + (' LIMIT ?' if limit else ''),
                              (limit,) if limit else ()).fetchall()
        return [json.loads(row[0]) for row in rows]

    def snapshot(self):
        return {'agent': 'pi', 'requests': self._requests(50)}

    def update(self, receipt, **changes):
        receipt.update(changes)
        with self.db() as db:
            self._save(db, receipt)

    def recover(self):
        with self.db() as db:
            rows = db.execute('SELECT data FROM requests').fetchall()
            for row in rows:
                receipt = json.loads(row[0])
                if receipt['status'] in ('starting', 'sending'):
                    receipt.update(status='unknown', phase='unknown', error='Pi 投递状态待核实；不会自动重发，请查看工作会话。')
                    self._save(db, receipt)

    async def poll(self):
        async with self.lock:
            for receipt in reversed(self._requests()):
                if receipt['status'] not in IN_FLIGHT:
                    continue
                events = self.runtime.events(receipt['session_id'])
                observed = observed_progress(events)
                state = await self.runtime.task_status({'agent': 'pi', 'session_id': receipt['session_id'], 'run_id': receipt['run_id']})
                phase = state if state in FINAL else observed['phase']
                if state == 'ready' and time.time() - receipt['updated_at'] > 45:
                    phase = 'unknown'
                received_at = receipt['received_at'] or (time.time() if observed['received'] else None)
                changes = {'status': phase, 'phase': phase, 'active_tool': observed['active_tool'],
                           'received_at': received_at, 'result': observed['result'], 'action_receipts': observed['action_receipts']}
                if phase == 'unknown':
                    changes['error'] = 'Pi 执行状态待核实；不会自动重发，请查看工作会话。'
                elif phase == 'failed':
                    changes['error'] = 'Pi 执行失败，请查看工作会话中的实际错误。'
                if any(receipt.get(k) != v for k, v in changes.items()):
                    if phase == 'completed':
                        changes.update(completed_at=time.time(), terminal_cursor=self._cursor(events))
                    self.update(receipt, **changes)
            for receipt in self._requests():
                if receipt['status'] == 'completed' and not receipt.get('session_closed') and not receipt.get('session_preserved'):
                    await self._close_owned_session(receipt)
            if any(r['status'] in IN_FLIGHT for r in self._requests()):
                return
            queued = next((r for r in reversed(self._requests()) if r['status'] == 'accepted'), None)
            if queued:
                await self._dispatch(queued)

    async def _dispatch(self, receipt):
        # Persist before every external side effect. Any interrupted interval is
        # uncertain and is never automatically replayed on a later process.
        self.update(receipt, status='starting', phase='starting')
        try:
            async with self.runtime.action_lock:
                sid = await self.runtime.create('pi', self.cwd, sandbox='danger-full-access')
                self.update(receipt, session_id=sid)
                self.runtime.h.label(sid, {'title': receipt['text'][:80]})
                managed = self.runtime.h.managed().get(sid)
                if managed:
                    self.runtime.h.save_managed(sid, {**managed, 'source': 'Com! 快捷语音',
                                                    'voice_request_id': receipt['request_id'], 'voice_owned': True})
                for _ in range(80):
                    if any(e.get('type') == 'session_start' for e in self.runtime.events(sid)):
                        break
                    await asyncio.sleep(.25)
                else:
                    raise RuntimeError('Pi 启动状态待核实，请查看工作会话')
                await asyncio.sleep(1)
                self.update(receipt, status='sending', phase='sending')
                run = await self.runtime.input(sid, voice_prompt(receipt['text'], receipt['purpose']), receipt['request_id'])
                if not run:
                    raise RuntimeError('Pi 未确认输入结果')
                self.update(receipt, status='submitted', phase='submitted', run_id=run)
        except asyncio.CancelledError:
            self.update(receipt, status='unknown', phase='unknown', error='Pi 投递中断，状态待核实；不会自动重发。')
            raise
        except Exception as error:
            self.update(receipt, status='unknown', phase='unknown', error=(str(error) + '；不会自动重发，请查看工作会话。')[:500])

    @staticmethod
    def _cursor(events):
        return events[-1].get('seq', len(events) - 1) if events else -1

    async def _close_owned_session(self, receipt):
        if time.time() - receipt.get('completed_at', time.time()) < 2:
            return
        sid = receipt['session_id']
        async with self.runtime.action_lock:
            managed = self.runtime.h.managed().get(sid, {})
            if not managed.get('voice_owned') or managed.get('voice_request_id') != receipt['request_id']:
                self.update(receipt, session_preserved=True)
                return
            if managed.get('ended'):
                self.update(receipt, session_closed=True)
                return
            events = self.runtime.events(sid)
            last_start = max((i for i, e in enumerate(events) if e.get('type') == 'agent_start'), default=-1)
            settled = any(e.get('type') == 'agent_settled' for e in events[last_start + 1:])
            if last_start < 0 or not settled or self._cursor(events) != receipt.get('terminal_cursor'):
                self.revoke(sid)
                self.update(receipt, session_preserved=True)
                return
            if await self.runtime.task_status({'agent': 'pi', 'session_id': sid, 'run_id': receipt['run_id']}) != 'completed':
                return
            attached = await self.runtime.tm('display-message', '-p', '-t', managed['tmux'], '#{session_attached}', check=False)
            if attached != '0':
                if attached.isdecimal() and int(attached) > 0:
                    self.revoke(sid)
                    self.update(receipt, session_preserved=True)
                return
            # Native activity can change while querying tmux; recheck immediately
            # before killing only this explicitly-owned dedicated pane.
            if self._cursor(self.runtime.events(sid)) != receipt['terminal_cursor']:
                self.revoke(sid)
                self.update(receipt, session_preserved=True)
                return
            await self.runtime.tm('kill-session', '-t', managed['tmux'])
            self.runtime.h.save_managed(sid, {**managed, 'ended': True})
            self.update(receipt, session_closed=True)

    def revoke(self, sid):
        """Caller holds runtime.action_lock before any user input or attachment."""
        managed = self.runtime.h.managed().get(sid)
        if managed and managed.get('voice_owned'):
            self.runtime.h.save_managed(sid, {**managed, 'voice_owned': False})

    def start(self):
        self.recover()
        async def loop():
            while True:
                with contextlib.suppress(Exception):
                    await self.poll()
                await asyncio.sleep(.5)
        self.loop_task = asyncio.create_task(loop())

    async def stop(self):
        if self.loop_task:
            self.loop_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.loop_task
