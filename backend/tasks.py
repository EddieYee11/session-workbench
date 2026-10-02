"""Durable task ledger. No worker command is replayed after an uncertain delivery."""
import json
import sqlite3
import time
from pathlib import Path
from contextlib import contextmanager


class TaskStore:
    def __init__(self, state: Path):
        self.path = state / 'tasks.sqlite'
        with self.db() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL, request_id TEXT UNIQUE NOT NULL, kind TEXT NOT NULL,
                    text TEXT NOT NULL, at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS outbox(task_id TEXT PRIMARY KEY, text TEXT NOT NULL,
                    delivered INTEGER NOT NULL DEFAULT 0);
            ''')
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

    def _save(self, db, task):
        db.execute('INSERT OR REPLACE INTO tasks VALUES (?,?)', (task['id'], json.dumps(task)))

    def _event(self, db, tid, key, kind, text=''):
        db.execute('INSERT INTO events(task_id,request_id,kind,text,at) VALUES (?,?,?,?,?)',
                   (tid, key, kind, text, time.time()))

    def ensure(self, proposal):
        with self.db() as db:
            row = db.execute('SELECT data FROM tasks WHERE id=?', (proposal['id'],)).fetchone()
            if row:
                return json.loads(row[0])
            task = {**proposal, 'message_id': proposal['origin_message_id'],
                    'parent_message_id': proposal['origin_message_id'], 'status': 'unknown' if proposal.get('status') in ('accepted','dispatching','unknown') else proposal.get('status') if proposal.get('status') in ('rejected','expired') else 'approval_required',
                    'constraints': [], 'completion_condition': 'Worker result requires review',
                    'authorization': None, 'run_id': None, 'session_id': '', 'result': ''}
            self._save(db, task)
            self._event(db, task['id'], 'created:' + task['id'], 'created', task['title'])
            return task

    def list(self):
        with self.db() as db:
            tasks = [json.loads(r[0]) for r in db.execute('SELECT data FROM tasks')]
            for task in tasks:
                task['events'] = [dict(r) for r in db.execute('SELECT * FROM events WHERE task_id=? ORDER BY seq', (task['id'],))]
            return tasks

    def change(self, tid, key, kind, text='', **fields):
        if not isinstance(key, str) or not 10 <= len(key) <= 240:
            raise ValueError('Invalid request_id')
        with self.db() as db:
            row = db.execute('SELECT data FROM tasks WHERE id=?', (tid,)).fetchone()
            if not row:
                raise ValueError('Task not found')
            task = json.loads(row[0])
            old = db.execute('SELECT * FROM events WHERE request_id=?', (key,)).fetchone()
            if old:
                if (old['task_id'], old['kind'], old['text']) != (tid, kind, text):
                    raise ValueError('Request conflicts with another command')
                return task, False
            if kind in ('input_accepted', 'cancel_requested') and task['status'] not in ('running', 'waiting', 'unknown'):
                raise ValueError('Task is not active')
            if kind == 'input_accepted':
                task['constraints'].append(text)
            task.update(fields, updated_at=time.time())
            self._save(db, task)
            self._event(db, tid, key, kind, text)
            return task, True

    def finish(self, tid, status, result):
        with self.db() as db:
            task = json.loads(db.execute('SELECT data FROM tasks WHERE id=?', (tid,)).fetchone()[0])
            if task['status'] in ('execution_finished', 'failed', 'cancelled'):
                return
            task.update(status=status, result=result, updated_at=time.time())
            self._save(db, task)
            self._event(db, tid, 'terminal:' + tid, status, result)
            text = f"任务「{task['title']}」：{status}。{result}（执行结束不代表验收通过）"
            db.execute('INSERT OR IGNORE INTO outbox(task_id,text) VALUES (?,?)', (tid, text))

    def deliver(self, conversation):
        with self.db() as db:
            for row in db.execute('SELECT * FROM outbox WHERE delivered=0').fetchall():
                conversation.task_receipt(row['task_id'], row['text'])
                db.execute('UPDATE outbox SET delivered=1 WHERE task_id=?', (row['task_id'],))

    def recover(self):
        for task in self.list():
            if task['status'] in ('running', 'waiting', 'dispatching', 'cancel_requested'):
                self.change(task['id'], 'restart:' + task['id'][:60] + ':' + str(time.time_ns()),
                            'execution_unknown', status='unknown')


class TaskController:
    def __init__(self, store, runtime, conversation):
        self.store, self.runtime, self.conversation = store, runtime, conversation

    async def poll(self):
        for task in self.store.list():
            if task['status'] not in ('running', 'waiting', 'cancel_requested'):
                continue
            status = await self.runtime.status(task['session_id'])
            if status in ('completed', 'failed', 'interrupted'):
                events = self.runtime.events(task['session_id'])
                # Preserve actual worker output; do not synthesize an acceptance verdict.
                output = '\n'.join(str(e.get('text', '')) for e in events if e.get('text') and e.get('role') == 'assistant' and e.get('kind') != 'delta')[-12000:]
                terminal = 'cancelled' if status == 'interrupted' else 'execution_finished' if status == 'completed' else 'failed'
                self.store.finish(task['id'], terminal, output or '工作器未提供结果正文，请查看执行会话。')
        self.store.deliver(self.conversation)

    async def command(self, tid, text, request_id, cancel=False):
        if not cancel and (not isinstance(text, str) or not text.strip() or len(text)>6000):
            raise ValueError('Invalid task input')
        kind = 'cancel_requested' if cancel else 'input_accepted'
        task, fresh = self.store.change(tid, request_id, kind, text,
                                       **({'status': 'cancel_requested'} if cancel else {}))
        if fresh:
            try:
                if cancel:
                    await self.runtime.stop(task['session_id'])
                else:
                    # Existing Pi transport cannot safely steer a running turn.
                    if task['agent'] != 'codex':
                        return {**task, 'delivery': 'accepted_pending'}
                    await self.runtime.steer_task(task['session_id'], task['run_id'], text)
                    self.store.change(tid, 'applied:' + request_id, 'input_applied', text)
                    return {**task, 'delivery': 'applied'}
            except Exception:
                self.store.change(tid, 'delivery-unknown:' + request_id,
                                  'cancel_delivery_unknown' if cancel else 'input_delivery_unknown', text)
                return {**task, 'delivery': 'unknown'}
        return {**task, 'delivery': 'accepted'}
