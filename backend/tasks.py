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
    return next(reversed(messages.values()), '')[-12000:]


def worker_error(events, run_id=None):
    for event in reversed(events):
        if run_id and event.get('turn_id') != run_id:
            continue
        error=event.get('error')
        message=error.get('message') if isinstance(error,dict) else error
        if isinstance(message,str) and message:
            try:
                parsed=json.loads(message)
                message=parsed.get('error',{}).get('message',message)
            except (ValueError,AttributeError):
                pass
            return ('工作器执行失败：'+message)[:3000]
    return ''


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
        task.setdefault('owner_conversation_id','personal-main')
        result=task.setdefault('structured_result',{'summary':'','artifacts':[],'evidence':[]})
        result.update(execution_status=task['status'],verification_status=task.get('verification_status','pending'),
                      uncertain=task['status'] in ('unknown','uncertain'))
        db.execute('INSERT OR REPLACE INTO tasks VALUES (?,?)', (task['id'], json.dumps(task)))

    def _event(self, db, tid, key, kind, text=''):
        db.execute('INSERT INTO events(task_id,request_id,kind,text,at) VALUES (?,?,?,?,?)',
                   (tid, key, kind, text, time.time()))

    def ensure(self, proposal):
        with self.db() as db:
            row = db.execute('SELECT data FROM tasks WHERE id=?', (proposal['id'],)).fetchone()
            if row:
                task = json.loads(row[0])
                if task['status'] == 'approval_required' and proposal.get('status') in ('rejected', 'expired'):
                    task.update(status=proposal['status'], updated_at=time.time())
                    self._save(db, task)
                    self._event(db, task['id'], proposal['status']+':'+task['id'], proposal['status'])
                return task
            task = {**proposal, 'message_id': proposal['origin_message_id'],
                    'parent_message_id': proposal['origin_message_id'], 'owner_conversation_id':'personal-main', 'verification_status':'pending', 'status': 'unknown' if proposal.get('status') in ('accepted','dispatching','unknown') else proposal.get('status') if proposal.get('status') in ('rejected','expired') else 'approval_required',
                    'constraints': [], 'completion_condition': 'Worker result requires review',
                    'authorization': None, 'run_id': None, 'session_id': '', 'result': ''}
            self._save(db, task)
            self._event(db, task['id'], 'created:' + task['id'], 'created', task['title'])
            return task

    def create_authorized(self, proposal, authorization, request_id):
        """Save a human-source-authorized task before any worker is contacted."""
        payload = {**proposal, 'authorization': authorization}
        fingerprint = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        tid = 'task_' + hashlib.sha256(request_id.encode()).hexdigest()[:24]
        with self.db() as db:
            row = db.execute('SELECT data FROM tasks WHERE id=?', (tid,)).fetchone()
            if row:
                task = json.loads(row[0])
                if task.get('fingerprint') != fingerprint:
                    raise ValueError('Task request conflicts with another assignment')
                return task
            task = {**payload, 'id':tid, 'fingerprint':fingerprint,
                    'message_id':proposal['origin_message_id'], 'parent_message_id':proposal['origin_message_id'],
                    'owner_conversation_id':'personal-main','verification_status':'pending',
                    'status':'queued', 'created_at':time.time(), 'updated_at':time.time(),
                    'constraints':[], 'run_id':None, 'session_id':'', 'result':''}
            self._save(db, task)
            self._event(db, tid, 'created:'+tid, 'created', task['title'])
            self._event(db, tid, 'authorized:'+tid, 'authorized', authorization['source_quote'])
            return task

    def list(self):
        with self.db() as db:
            tasks = sorted((json.loads(r[0]) for r in db.execute('SELECT data FROM tasks')),
                           key=lambda t:(t.get('created_at',0),t['id']))
            for task in tasks:
                task['events'] = [dict(r) for r in db.execute('SELECT * FROM events WHERE task_id=? ORDER BY seq', (task['id'],))]
            for task in tasks:
                task['inputs'] = [dict(r) for r in db.execute('SELECT * FROM inputs WHERE task_id=? ORDER BY updated_at,request_id', (task['id'],))]
            return tasks

    def context(self):
        """Prioritize active work and bound context without losing the newest assignments."""
        tasks = sorted(self.list(), key=lambda t:(t['status'] in ('queued','dispatching','running','waiting','cancel_requested','unknown','approval_required'), t.get('updated_at', t.get('created_at',0))), reverse=True)[:30]
        return [{**{k:t.get(k) for k in ('id','title','message_id','status','agent','cwd','sandbox','completion_condition')},
                 'constraints':t.get('constraints', [])[-15:],
                 'inputs':[{k:c[k] for k in ('request_id','state','text','error')} for c in t.get('inputs',[])[-10:]],
                 'result':t.get('result','')[-3000:]} for t in tasks]

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
            if kind in ('input_accepted', 'cancel_requested') and task['status'] not in ('queued', 'running', 'waiting', 'unknown'):
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
            if task['status'] not in ('queued', 'approval_required', 'running', 'waiting', 'unknown'):
                raise ValueError('Task is not active')
            state = ('blocked_authorization' if policy == 'unreviewed' else
                     'pending_start' if task['status'] in ('queued','approval_required') else 'queued')
            if policy != 'unreviewed':
                task['constraints'].append(text)
            task['updated_at'] = time.time()
            self._save(db, task)
            db.execute('INSERT INTO inputs VALUES (?,?,?,?,?,?,?,?)',
                       (request_id,tid,text,source,policy,state,'',time.time()))
            self._event(db, tid, self.command_key(request_id,'accepted'), 'input_accepted', text)
            if state == 'blocked_authorization':
                self._event(db, tid, self.command_key(request_id,state), 'input_'+state,
                            '未授权的新动作不能自动投递；请在任务详情明确提交指令。')
            return dict(db.execute('SELECT * FROM inputs WHERE request_id=?', (request_id,)).fetchone())

    def pending_start_inputs(self, tid):
        with self.db() as db:
            return [dict(r) for r in db.execute("SELECT * FROM inputs WHERE task_id=? AND state='pending_start' ORDER BY updated_at,request_id", (tid,))]

    def execution_prompt(self, task):
        instructions = self.pending_start_inputs(task['id'])
        return task['prompt'] + (('\n\n用户后续约束（同一任务，不扩展授权）：\n' + '\n'.join('[Com input:'+c['request_id']+'] '+c['text'] for c in instructions)) if instructions else '')

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
            structured={'execution_status':status,'verification_status':'pending',
                        'summary':result,'artifacts':task.get('artifacts',[]),
                        'evidence':[{'event_seq':r[0]} for r in db.execute('SELECT seq FROM events WHERE task_id=?',(tid,))],
                        'uncertain':status in ('unknown','uncertain')}
            task.update(status=status, result=result, structured_result=structured,
                        verification_status='pending',updated_at=time.time())
            previous=task.get('result_round',0)
            task['result_round']=previous+1
            self._save(db,task)
            self._event(db, tid, 'terminal:' + tid + (':'+str(task.get('run_id')) if previous else ''), status, result)
            label = {'execution_finished':'执行结束，待验收','failed':'执行失败','cancelled':'已取消'}.get(status,'执行状态待核实')
            text = f"任务「{task['title']}」：{label}。\n{result}"
            db.execute('INSERT OR REPLACE INTO outbox(task_id,text) VALUES (?,?)', (tid, text))
            for row in db.execute("SELECT request_id FROM inputs WHERE task_id=? AND state IN ('pending_start','queued')",(tid,)).fetchall():
                db.execute("UPDATE inputs SET state='blocked_state',error=?,updated_at=? WHERE request_id=?",
                           ('任务已结束；指令未投递',time.time(),row['request_id']))
                self._event(db,tid,self.command_key(row['request_id'],'blocked_state'),'input_blocked_state','任务已结束；指令未投递')

    def deliver(self, conversation):
        with self.db() as db:
            for row in db.execute('SELECT * FROM outbox WHERE delivered=0').fetchall():
                task=json.loads(db.execute('SELECT data FROM tasks WHERE id=?',(row['task_id'],)).fetchone()[0])
                receipt_id=row['task_id']+(':'+str(task.get('run_id')) if task.get('result_round',0)>1 else '')
                conversation.task_receipt(receipt_id, row['text'])
                if (task.get('origin_request_id') or '').startswith('work:'):
                    conversation._finish(task['origin_message_id'],'completed')
                if hasattr(conversation,'process_background'):
                    owner=getattr(conversation.process_background,'__self__',None)
                    if owner:
                        task=json.loads(db.execute('SELECT data FROM tasks WHERE id=?',(row['task_id'],)).fetchone()[0])
                        owner.events.enqueue('task-result:'+receipt_id,'task_result',
                            {'task':task,'authorization':{k:task.get(k) for k in ('origin_session_id','origin_message_id','origin_request_id')}})
                        conversation.wake.set()
                db.execute('UPDATE outbox SET delivered=1 WHERE task_id=?', (row['task_id'],))

    def observe_events(self, task, events):
        for i,event in enumerate(events):
            if event.get('turn_id') and event.get('turn_id')!=task.get('run_id'):
                continue
            typ=event.get('type');kind=event.get('kind');data=event.get('data',{})
            name=data.get('toolName') or event.get('tool_name') or event.get('title','')
            if typ=='tool_execution_start':kind='tool.started'
            elif typ=='tool_execution_end':kind='tool.failed' if data.get('isError') else 'tool.completed'
            elif kind=='item' and event.get('role')=='tool':kind='tool.started' if event.get('state')=='running' else 'tool.completed'
            if kind not in ('tool.started','tool.completed','tool.failed','usage','input.delivered'):
                continue
            summary=json.dumps({'tool':name,'call_id':data.get('toolCallId') or event.get('id'),
                                'source_seq':event.get('seq',i),'time':event.get('time'),
                                **({'usage':event.get('usage'),'amount_status':'unknown'} if kind=='usage' else {})},ensure_ascii=False)
            self.change(task['id'],'native:'+task['id']+':'+str(event.get('seq',i)),kind,summary)

    def verify(self,tid,evidence,artifacts=None):
        if not isinstance(evidence,list) or not evidence or any(not isinstance(e,dict) or not e.get('reference') for e in evidence):
            raise ValueError('验收必须提供可定位的证据引用')
        task=next((t for t in self.list() if t['id']==tid),None)
        if not task or task['status']!='execution_finished':
            raise ValueError('只能验收已结束任务')
        result={**task.get('structured_result',{}),'verification_status':'passed','evidence':evidence,
                'artifacts':artifacts or task.get('artifacts',[])}
        return self.change(tid,'verified:'+tid+':'+str(task.get('run_id')),'verification.passed','验收通过，已记录真实检查证据',
                           verification_status='passed',structured_result=result,artifacts=result['artifacts'])[0]

    def recover(self):
        with self.db() as db:
            sending = [r[0] for r in db.execute("SELECT request_id FROM inputs WHERE state IN ('sending','worker_queued')")]
        for request_id in sending:
            self.transition_input(request_id, ('sending','worker_queued'), 'unknown', '服务重启，送达待核实；不会重发')
        for task in self.list():
            if task['status'] in ('running', 'waiting', 'dispatching', 'cancel_requested'):
                self.change(task['id'], 'restart:' + task['id'][:60] + ':' + str(time.time_ns()),
                            'execution_unknown', status='unknown',verification_status='uncertain')


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
            if task['status'] not in ('running', 'waiting', 'cancel_requested','unknown'):
                continue
            if task['status']=='unknown' and not getattr(self.runtime,'can_reconcile_task',lambda _:False)(task):
                continue
            inspect = getattr(self.runtime, 'task_status', None)
            try:
                status = await inspect(task) if inspect else await self.runtime.status(task['session_id'])
            except Exception:
                status = 'unknown'
            self.store.observe_events(task,self.runtime.events(task['session_id']))
            if status == 'unknown' and task['status']!='unknown':
                self.store.change(task['id'],'unavailable:'+task['id'],'execution_unknown',status='unknown',verification_status='uncertain')
            if status in ('running','waiting') and task['status'] != status and task['status'] != 'cancel_requested':
                self.store.change(task['id'],'observed:'+task['id']+':'+str(time.time_ns()),status,status=status)
            if status in ('completed', 'failed', 'interrupted'):
                events = self.runtime.events(task['session_id'])
                output = worker_result(events,task.get('run_id')) or worker_error(events,task.get('run_id'))
                terminal = 'cancelled' if status == 'interrupted' else 'execution_finished' if status == 'completed' else 'failed'
                current=next(t for t in self.store.list() if t['id']==task['id'])
                if current.get('workspace_copy'):
                    copies=getattr(getattr(self.runtime,'workers',None),'copies',None)
                    if copies:
                        _,patch=copies.changes(current)
                        self.store.change(task['id'],'patch:'+task['id']+':'+str(task.get('run_id')),'artifact.created',patch,artifacts=[{'path':patch,'kind':'patch'}])
                self.store.finish(task['id'], terminal, output or '工作器未提供结果正文，请查看执行会话。')
        await self.drain_inputs()
        self.store.deliver(self.conversation)
        await self.start_queued()

    async def start_queued(self):
        """Dispatch separately from the main conversation, at most one new job per tick."""
        tasks = self.store.list()
        active = [t for t in tasks if t['status'] in ('running','waiting','unknown','dispatching','cancel_requested')]
        if len(active) >= 2:
            return
        for task in tasks:
            if task['status'] != 'queued':
                continue
            if task['agent']=='claude' and any(t['agent']=='claude' for t in active):
                continue
            # Context isolation is not file isolation. Readers may run together; writers serialize.
            if any((Path(t['cwd']).is_relative_to(Path(task['cwd'])) or Path(task['cwd']).is_relative_to(Path(t['cwd']))) and
                   (task['sandbox'] != 'read-only' or t['sandbox'] != 'read-only' or t['status']=='unknown') for t in active):
                continue
            preflight=getattr(self.runtime,'preflight_task',None)
            if preflight:
                try:
                    await preflight(task)
                except ValueError as error:
                    self.store.change(task['id'],'blocked:'+task['id'],'waiting',str(error),status='paused',block_reason=str(error))
                    continue
            key = 'dispatch:'+task['id']
            task, fresh = self.store.change(task['id'], key, 'dispatching', status='dispatching')
            if not fresh:
                return
            inputs = self.store.pending_start_inputs(task['id'])
            prompt = self.store.execution_prompt(task)
            for command in inputs:
                self.store.transition_input(command['request_id'], ('pending_start',), 'sending')
            sid = ''
            try:
                create = getattr(self.runtime,'create_task_worker',None)
                sid = await create(task) if create else await self.runtime.create(task['agent'], task['cwd'], sandbox=task['sandbox'])
                run_id = await self.runtime.input(sid, prompt, task['authorization']['request_id'])
                if not run_id:
                    raise RuntimeError('Worker did not confirm a run ID')
                self.store.change(task['id'], 'started:'+task['id'], 'started', status='running', session_id=sid, run_id=run_id)
                for command in inputs:
                    state='delivered'
                    meta=getattr(getattr(self.runtime,'h',None),'managed',lambda:{})().get(sid,{})
                    if meta.get('transport') in ('com-pi-rpc','claude-agent-sdk'):state='worker_queued'
                    self.store.transition_input(command['request_id'], ('sending',), state)
            except Exception:
                self.store.change(task['id'], 'start-unknown:'+task['id'], 'execution_unknown',
                                  '派发结果待核实；不会自动重发', status='unknown', session_id=sid)
                for command in inputs:
                    self.store.transition_input(command['request_id'], ('sending',), 'unknown', '初始任务送达待核实；不会重发')
            return

    async def command(self, tid, text, request_id, cancel=False):
        if not cancel:
            command = self.store.enqueue(tid,text,request_id)
            await self.drain_inputs()
            command = next(c for t in self.store.list() for c in t['inputs'] if c['request_id']==request_id)
            return {'task_id':tid,'request_id':request_id,'delivery':command['state']}
        current = next((t for t in self.store.list() if t['id']==tid), None)
        if current and current['status']=='queued':
            task, fresh = self.store.change(tid, request_id, 'cancel_requested', '', status='cancel_requested')
            self.store.finish(tid, 'cancelled', '任务在启动前取消；未联系工作器。')
            return {**task, 'status':'cancelled', 'delivery':'accepted'}
        task, fresh = self.store.change(tid, request_id, 'cancel_requested', '', status='cancel_requested')
        if fresh:
            try:
                stop = getattr(self.runtime, 'cancel_task', None)
                if stop:
                    await stop(task)
                else:
                    await self.runtime.stop(task['session_id'])
            except Exception:
                task, _ = self.store.change(tid, 'cancel-unknown:' + request_id,
                                  'cancel_delivery_unknown', '终止结果待核实；不会重发', cancel_delivery='unknown')
                return {**task, 'delivery':'unknown'}
        return {**task, 'delivery':task.get('cancel_delivery','accepted')}
