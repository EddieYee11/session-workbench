"""Durable task ledger. No worker command is replayed after an uncertain delivery."""
import hashlib
import json
import sqlite3
import time
from pathlib import Path
from contextlib import contextmanager


def worker_result(events, run_id=None):
    """Use final assistant records, never reasoning/tool deltas as a result."""
    messages = {}
    for i,event in enumerate(events):
        if run_id and event.get('turn_id') and event['turn_id'] != run_id:
            continue
        if event.get('role') == 'assistant' and event.get('kind') != 'delta' and event.get('text'):
            messages[event.get('id') or str(i)] = str(event['text'])
        if event.get('type') == 'message_end':
            message = event.get('data',{}).get('message',{})
            if message.get('role') == 'assistant':
                text = '\n'.join(c.get('text','') for c in message.get('content',[]) if isinstance(c,dict) and c.get('type')=='text')
                if text:
                    messages[str(i)] = text
    return '\n'.join(messages.values())[-12000:]


class TaskStore:
    def __init__(self, state: Path):
        self.path = state / 'tasks.sqlite'
        with self.db() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL, request_id TEXT UNIQUE NOT NULL, kind TEXT NOT NULL,
                    text TEXT NOT NULL, at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS inputs(request_id TEXT PRIMARY KEY, task_id TEXT NOT NULL,
                    text TEXT NOT NULL, source TEXT NOT NULL, policy TEXT NOT NULL,
                    state TEXT NOT NULL, error TEXT NOT NULL DEFAULT '', updated_at REAL NOT NULL);
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
            for task in tasks:
                task['inputs'] = [dict(r) for r in db.execute('SELECT * FROM inputs WHERE task_id=? ORDER BY updated_at,request_id', (task['id'],))]
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

    @staticmethod
    def command_key(request_id, state):
        return 'input:' + hashlib.sha256(request_id.encode()).hexdigest() + ':' + state

    def enqueue(self, tid, text, request_id, source='user', policy='explicit'):
        if not isinstance(request_id, str) or not 10 <= len(request_id) <= 120:
            raise ValueError('Invalid request_id')
        if not isinstance(text, str) or not text.strip() or len(text) > 6000:
            raise ValueError('Invalid task input')
        if source not in ('user', 'mcp') or policy not in ('explicit', 'restriction', 'unreviewed'):
            raise ValueError('Invalid input policy')
        if source == 'mcp' and policy == 'explicit':
            raise ValueError('Model cannot authorize instructions')
        with self.db() as db:
            old = db.execute('SELECT * FROM inputs WHERE request_id=?', (request_id,)).fetchone()
            if old:
                if (old['task_id'], old['text'], old['source'], old['policy']) != (tid,text,source,policy):
                    raise ValueError('Input request conflicts')
                return dict(old)
            row = db.execute('SELECT data FROM tasks WHERE id=?', (tid,)).fetchone()
            if not row:
                raise ValueError('Task not found')
            task = json.loads(row[0])
            if task['status'] not in ('running', 'waiting', 'unknown'):
                raise ValueError('Task is not active')
            state = 'blocked_authorization' if policy == 'unreviewed' else 'queued'
            task['constraints'].append(text)
            task['updated_at'] = time.time()
            self._save(db, task)
            db.execute('INSERT INTO inputs VALUES (?,?,?,?,?,?,?,?)',
                       (request_id,tid,text,source,policy,state,'',time.time()))
            self._event(db, tid, self.command_key(request_id,'accepted'), 'input_accepted', text)
            if state != 'queued':
                self._event(db, tid, self.command_key(request_id,state), 'input_'+state,
                            '未授权的新动作不能自动投递；请在任务详情明确提交指令。')
            return dict(db.execute('SELECT * FROM inputs WHERE request_id=?', (request_id,)).fetchone())

    def transition_input(self, request_id, expected, state, error=''):
        with self.db() as db:
            row = db.execute('SELECT * FROM inputs WHERE request_id=?', (request_id,)).fetchone()
            if not row or row['state'] not in expected:
                return False
            db.execute('UPDATE inputs SET state=?,error=?,updated_at=? WHERE request_id=?',
                       (state,error,time.time(),request_id))
            self._event(db,row['task_id'],self.command_key(request_id,state),'input_'+state,
                        error or row['text'])
            return True

    def pending_inputs(self):
        with self.db() as db:
            return [dict(r) for r in db.execute("SELECT * FROM inputs WHERE state IN ('queued','worker_queued') ORDER BY updated_at,request_id")]

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
        with self.db() as db:
            sending = [r[0] for r in db.execute("SELECT request_id FROM inputs WHERE state IN ('sending','worker_queued')")]
        for request_id in sending:
            self.transition_input(request_id, ('sending','worker_queued'), 'unknown', '服务重启，送达待核实；不会重发')
        for task in self.list():
            if task['status'] in ('running', 'waiting', 'dispatching', 'cancel_requested'):
                self.change(task['id'], 'restart:' + task['id'][:60] + ':' + str(time.time_ns()),
                            'execution_unknown', status='unknown')


class TaskController:
    def __init__(self, store, runtime, conversation):
        self.store, self.runtime, self.conversation = store, runtime, conversation

    async def drain_inputs(self):
        tasks = {t['id']: t for t in self.store.list()}
        for command in self.store.pending_inputs():
            task = tasks[command['task_id']]
            key = command['request_id']
            if command['state'] == 'worker_queued':
                # RPC acknowledgement means queued, not delivered. Correlate an explicit event.
                observation = getattr(self.runtime, 'task_input_state', lambda *_: None)(task, key)
                if observation in ('delivered','failed'):
                    self.store.transition_input(key, ('worker_queued',), observation)
                elif time.time()-command['updated_at'] > 120:
                    self.store.transition_input(key, ('worker_queued',), 'unknown', '工作器排队后超过确认期限，送达待核实；不会重发')
                elif task['status'] not in ('running','waiting'):
                    self.store.transition_input(key, ('worker_queued',), 'unknown', '任务停止或执行状态未知，未确认指令送达')
                continue
            if task['status'] not in ('running','waiting'):
                self.store.transition_input(key, ('queued',), 'blocked_state', '执行状态不允许安全投递；请先核实任务')
                continue
            if not task.get('authorization'):
                self.store.transition_input(key, ('queued',), 'blocked_authorization', '任务没有持久授权快照')
                continue
            capabilities = getattr(self.runtime, 'task_capabilities', lambda t: {'steer':t['agent']=='codex'})(task)
            if not capabilities.get('steer'):
                self.store.transition_input(key, ('queued',), 'unsupported', '当前 Pi tmux/TUI 适配器未连接 RPC steer；未投递。请明确取消或在执行会话处理。')
                continue
            if not self.store.transition_input(key, ('queued',), 'sending'):
                continue
            # Claim is durable before calling worker; a crash leaves unknown instead of replaying.
            try:
                deliver = getattr(self.runtime, 'deliver_task_input', None)
                if deliver:
                    result = await deliver(task, command)
                else:
                    await self.runtime.steer_task(task['session_id'], task['run_id'], command['text'])
                    result = {'state':'delivered'}
                state = result.get('state')
                if state not in ('delivered','worker_queued','failed','unsupported'):
                    state = 'unknown'
                self.store.transition_input(key, ('sending',), state, result.get('error',''))
            except ValueError:
                self.store.transition_input(key, ('sending',), 'failed', '工作器拒绝指令；未自动重试')
            except Exception:
                self.store.transition_input(key, ('sending',), 'unknown', '传输结果待核实；未自动重试')

    async def poll(self):
        # Inspect terminal state before draining, so a finished turn is never restarted by input.
        for task in self.store.list():
            if task['status'] not in ('running', 'waiting', 'cancel_requested'):
                continue
            inspect = getattr(self.runtime, 'task_status', None)
            try:
                status = await inspect(task) if inspect else await self.runtime.status(task['session_id'])
            except Exception:
                status = 'unknown'
            if status == 'unknown':
                self.store.change(task['id'],'unavailable:'+task['id'],'execution_unknown',status='unknown')
            if status in ('completed', 'failed', 'interrupted'):
                events = self.runtime.events(task['session_id'])
                output = worker_result(events,task.get('run_id'))
                terminal = 'cancelled' if status == 'interrupted' else 'execution_finished' if status == 'completed' else 'failed'
                self.store.finish(task['id'], terminal, output or '工作器未提供结果正文，请查看执行会话。')
        await self.drain_inputs()
        self.store.deliver(self.conversation)

    async def command(self, tid, text, request_id, cancel=False):
        if not cancel:
            command = self.store.enqueue(tid,text,request_id)
            await self.drain_inputs()
            command = next(c for t in self.store.list() for c in t['inputs'] if c['request_id']==request_id)
            return {'task_id':tid,'request_id':request_id,'delivery':command['state']}
        task, fresh = self.store.change(tid, request_id, 'cancel_requested', '', status='cancel_requested')
        if fresh:
            try:
                await self.runtime.stop(task['session_id'])
            except Exception:
                self.store.change(tid, 'cancel-unknown:' + request_id,
                                  'cancel_delivery_unknown', '终止结果待核实；不会重发')
                return {**task, 'delivery':'unknown'}
        return {**task, 'delivery':'accepted'}
