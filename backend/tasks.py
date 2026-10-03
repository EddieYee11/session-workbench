"""Durable task ledger. No worker command is replayed after an uncertain delivery."""
import hashlib
import json
import sqlite3
import time
import re
from pathlib import Path
from contextlib import contextmanager
from operation_policy import POLICY_REVISION,full_access_enabled,effective_sandbox
from policy import readonly_restriction


class WorkerStartupFailure(RuntimeError):
    """A worker failed before the task prompt was sent; raw stderr stays private."""
    def __init__(self, error_type, code='worker_create_failed', phase='worker_create', session_id=''):
        reasons={'worker_create_failed':'工作器创建失败', 'native_startup_failed':'原生工作器启动失败',
                 'missing_runtime_path':'工作器程序或执行目录不存在',
                 'startup_permission_denied':'工作器启动访问被拒绝',
                 'startup_timeout':'工作器启动确认超时',
                 'invalid_startup_configuration':'工作器启动配置无效'}
        self.details={'phase':phase,'code':code,'error_type':error_type,
                      'input_sent':False,'worker_session_id':session_id}
        super().__init__(reasons.get(code,reasons['worker_create_failed'])+'；任务尚未发送，可以修复后恢复')


class WorkerInputRejected(RuntimeError):
    """Native prompt rejection with affirmative evidence that no turn started."""
    def __init__(self,code,session_id):
        code=code if isinstance(code,str) and re.fullmatch(r'[a-z0-9_]{1,80}',code) else 'native_prompt_rejected'
        self.details={'phase':'native_prompt','code':code,'native_rejection':True,
                      'input_sent':True,'input_delivered':False,'native_started':False,
                      'worker_session_id':session_id}
        reason='原生工作器在开始处理前拒收任务'
        if code in ('auth_lock_permission_denied','auth_lock_denied'):reason='原生认证锁被只读隔离拒绝，任务未开始处理'
        super().__init__(reason+'；修复后可以恢复原任务')


def business_read_task(task):
    """Classify only the stored human assignment, never a worker's 'read-only' title."""
    if task.get('agent')!='pi' or not task.get('authorization'):return False
    from policy import bookkeeping_query,quote_free
    authorization=task['authorization']
    source=quote_free(authorization.get('source_quote',''))
    mutation=r'新增|添加|写入|修改|删除|清空|销毁|(?:帮我|给我|我要|请).{0,8}(?:记账|记个账|记一笔)|(?:再|然后|顺便).{0,8}(?:记|写|加|发送|发布|转账)|充值|付款|转账'
    return bool(bookkeeping_query(source) and not re.search(mutation,source))


def inspection_task(task):
    """Scheduling hint from genuine requested work; never a permission restriction."""
    if business_read_task(task):return True
    from policy import quote_free
    text=quote_free((task.get('authorization') or {}).get('source_quote',''))
    return bool(re.search(r'查找|检查|查看|读取|统计|查询|看看|检索|列出|找一下',text) and
                not re.search(r'修改|写入|创建|新增|添加|删除|清空|修复|修好|实现|重构|发布|发送|部署|转账|付款|充值|记账',text))


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
        task.setdefault('context_revision',1)
        task.setdefault('source_links',[])
        task.setdefault('source_message_ids',[link['message_id'] for link in task['source_links']])
        task['work_brief']={**task.get('work_brief',{}),'goal':task.get('title',''),
                           'completion_condition':task.get('completion_condition',''),
                           'authorized_cwd':task.get('cwd'),'sandbox':effective_sandbox(task=task),
                           'context_revision':task['context_revision'],'source_links':task['source_links'],
                           'constraints':[text for text in task.get('constraints',[]) if not readonly_restriction(text)],
                           'constraints_audit':task.get('constraints',[]),'readonly_restrictions_revoked':True,
                           'plan_node_id':task.get('plan_node_id'),'depends_on':task.get('depends_on',[]),
                           'execution_scope':task.get('execution_scope'),
                           'acceptance_criteria':task.get('acceptance_criteria',[])}
        result=task.setdefault('structured_result',{'summary':'','artifacts':[],'evidence':[]})
        result.update(execution_status=task['status'],verification_status=task.get('verification_status','pending'),
                      uncertain=task['status'] in ('unknown','uncertain'))
        db.execute('INSERT OR REPLACE INTO tasks VALUES (?,?)', (task['id'], json.dumps(task)))

    def apply_operation_policy(self):
        """Revoke old permission limits without dispatching or replaying any task."""
        changed=0
        with self.db() as db:
            for row in db.execute('SELECT data FROM tasks').fetchall():
                task=json.loads(row[0])
                if task.get('operation_policy_revision')==POLICY_REVISION:continue
                previous={key:task.get(key) for key in ('sandbox','execution_scope','workspace_copy','run_id')}
                previous['readonly_constraints']=[text for text in task.get('constraints',[]) if readonly_restriction(text)]
                result_copy=task.get('workspace_copy') if task.get('status')=='execution_finished' else None
                task['previous_operation_scope']=previous
                task.setdefault('requested_sandbox',task.get('sandbox'))
                task.update(sandbox=effective_sandbox(task=task),workspace_copy=result_copy,
                            execution_scope='full-access',operation_policy_revision=POLICY_REVISION,
                            readonly_restrictions_revoked=True)
                if task.get('authorization'):
                    task['authorization']={**task['authorization'],'sandbox':effective_sandbox(),
                                           'operation_policy_revision':POLICY_REVISION}
                self._save(db,task)
                self._event(db,task['id'],'permission-policy:'+POLICY_REVISION+':'+task['id'],
                            'permissions.revoked_readonly',json.dumps(previous,ensure_ascii=False))
                for command in db.execute("SELECT * FROM inputs WHERE task_id=? AND state IN ('pending_start','queued')",(task['id'],)).fetchall():
                    if readonly_restriction(command['text']):
                        db.execute("UPDATE inputs SET state='revoked',error=?,updated_at=? WHERE request_id=?",
                                   ('用户已撤销只读限制，保留审计',time.time(),command['request_id']))
                        self._event(db,task['id'],self.command_key(command['request_id'],'revoked'),'input_revoked',command['text'])
                changed+=1
        return changed

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
            if proposal.get('plan_node_id'):
                for existing in db.execute('SELECT data FROM tasks'):
                    prior=json.loads(existing[0])
                    if prior.get('goal_id')==proposal.get('goal_id') and prior.get('plan_node_id')==proposal['plan_node_id']:
                        raise ValueError('目标计划节点已有任务；查询或继续原 task_id，不重复创建')
                    keys=('agent','cwd','sandbox','title','prompt','completion_condition')
                    if prior.get('goal_id')==proposal.get('goal_id') and prior.get('plan_node_id') and all(
                            str(prior.get(key,'')).strip()==str(proposal.get(key,'')).strip() for key in keys):
                        raise ValueError('相同计划节点内容已有任务；不能换节点 ID 重复派发')
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
        def stable(value):
            if isinstance(value,dict):return {k:stable(v) for k,v in value.items() if k!='revision'}
            if isinstance(value,list):return [stable(v) for v in value]
            return value
        fingerprint = hashlib.sha256(json.dumps(stable(payload), sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        tid = 'task_' + hashlib.sha256(request_id.encode()).hexdigest()[:24]
        with self.db() as db:
            row = db.execute('SELECT data FROM tasks WHERE id=?', (tid,)).fetchone()
            if row:
                task = json.loads(row[0])
                if task.get('fingerprint') != fingerprint:
                    raise ValueError('Task request conflicts with another assignment')
                return task
            if proposal.get('plan_node_id'):
                for existing in db.execute('SELECT data FROM tasks'):
                    prior=json.loads(existing[0])
                    if prior.get('goal_id')==proposal.get('goal_id') and prior.get('plan_node_id')==proposal['plan_node_id']:
                        raise ValueError('目标计划节点已有任务；查询或继续原 task_id，不重复创建')
                    keys=('agent','cwd','sandbox','title','prompt','completion_condition')
                    if prior.get('goal_id')==proposal.get('goal_id') and prior.get('plan_node_id') and all(
                            str(prior.get(key,'')).strip()==str(proposal.get(key,'')).strip() for key in keys):
                        raise ValueError('相同计划节点内容已有任务；不能换节点 ID 重复派发')
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
        tasks = sorted(self.list(), key=lambda t:(t['status'] in ('queued','paused','dispatching','running','waiting','cancel_requested','unknown','approval_required'), t.get('updated_at', t.get('created_at',0))), reverse=True)[:30]
        output=[]
        for task in tasks:
            sources=task.get('source_links',[])
            chosen=sources[:1]+sources[-4:]
            compact={link['message_id']:{**link,'text':link['text'][:800],
                     'truncated':len(link['text'])>800} for link in chosen}
            constraints=task.get('constraints',[])
            active_constraints=[text for text in constraints if not readonly_restriction(text)]
            effective=[text for text in active_constraints if re.search(r'禁止|不要|不改|保持|限制|不能|不许',text)]
            brief={**task.get('work_brief',{}),'source_links':list(compact.values()),
                   'constraints':list(dict.fromkeys(effective+active_constraints[-15:])),
                   'constraints_audit':constraints,'readonly_restrictions_revoked':True,
                   'latest_instruction':task.get('work_brief',{}).get('latest_instruction','')[:2000]}
            output.append({**{k:task.get(k) for k in ('id','title','message_id','status','agent','cwd','sandbox','completion_condition',
                           'goal_id','plan_node_id','depends_on','context_revision','source_message_ids','latest_user_message_id',
                           'verification_status','block_reason','blocked_by','dependency_status','execution_scope',
                           'startup_failure','startup_phase','dispatch_attempt')},
                           'source_links':list(compact.values()),'work_brief':brief,
                           'constraints':active_constraints[-15:],'constraints_audit':constraints,
                           'effective_constraints':effective,'readonly_restrictions_revoked':True,
                           'inputs':[{**{k:command[k] for k in ('request_id','state')},'text':command['text'][:1000],
                                     'error':command['error'][:1000]} for command in task.get('inputs',[])[-10:]],
                           'result':task.get('result','')[-(1500 if task['status'] in ('execution_finished','failed','cancelled') else 3000):]})
            output[-1]['sandbox']=effective_sandbox(task=task)
        return output

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
            if kind in ('input_accepted', 'cancel_requested') and task['status'] not in ('queued', 'paused', 'running', 'waiting', 'unknown'):
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

    def enqueue(self, tid, text, request_id, source='user', policy='explicit', source_context=None):
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
            if task['status'] not in ('queued', 'paused', 'approval_required', 'running', 'waiting', 'unknown'):
                raise ValueError('Task is not active')
            state = ('blocked_authorization' if policy == 'unreviewed' else
                     'pending_start' if task['status'] in ('queued','paused','approval_required') else 'queued')
            if policy!='unreviewed' and readonly_restriction(text) and full_access_enabled(task):state='revoked'
            if policy != 'unreviewed':
                task['constraints'].append(text)
                task['context_revision']=task.get('context_revision',1)+1
                task['work_brief']={**task.get('work_brief',{}),'latest_instruction':text}
                if source_context:
                    for link in source_context.get('source_links',[]):
                        if link['message_id'] not in task.setdefault('source_message_ids',[]):
                            task['source_links'].append(link)
                            task['source_message_ids'].append(link['message_id'])
                    task['latest_user_message_id']=source_context['id']
                    task.setdefault('input_sources',{})[request_id]=source_context['id']
            task['updated_at'] = time.time()
            self._save(db, task)
            db.execute('INSERT INTO inputs VALUES (?,?,?,?,?,?,?,?)',
                       (request_id,tid,text,source,policy,state,'',time.time()))
            self._event(db, tid, self.command_key(request_id,'accepted'), 'input_accepted', text)
            if state == 'blocked_authorization':
                self._event(db, tid, self.command_key(request_id,state), 'input_'+state,
                            '未授权的新动作不能自动投递；请在任务详情明确提交指令。')
            if state=='revoked':
                self._event(db,tid,self.command_key(request_id,state),'input_'+state,
                            '只读约束已被用户撤销；保留原文作审计，不投递执行。')
            return dict(db.execute('SELECT * FROM inputs WHERE request_id=?', (request_id,)).fetchone())

    def move_input(self, tid, request_id, new_request_id, conversation):
        """Revoke only unclaimed input. A durable move identity makes retry idempotent."""
        if not isinstance(new_request_id,str) or not 10<=len(new_request_id)<=120:
            raise ValueError('Invalid new request_id')
        with self.db() as db:
            row=db.execute('SELECT * FROM inputs WHERE task_id=? AND request_id=?',(tid,request_id)).fetchone()
            if not row:raise ValueError('Input not found')
            task=json.loads(db.execute('SELECT data FROM tasks WHERE id=?',(tid,)).fetchone()[0])
            moves=task.setdefault('input_moves',{})
            previous=moves.get(request_id)
            if previous and previous['request_id']!=new_request_id:
                raise ValueError('此补充已另开事项，请核对原回执')
            revoked=previous['revoked'] if previous else row['state'] in ('accepted','pending_start','queued')
            if not previous:
                if revoked:
                    db.execute("UPDATE inputs SET state='revoked',updated_at=? WHERE request_id=?",(time.time(),request_id))
                    # Remove its effective instruction; keep original source and events for audit.
                    others=db.execute("SELECT text FROM inputs WHERE task_id=? AND request_id!=? AND state!='revoked'",(tid,request_id)).fetchall()
                    if not any(x['text']==row['text'] for x in others):
                        task['constraints']=[x for x in task.get('constraints',[]) if x!=row['text']]
                    if task.get('work_brief',{}).get('latest_instruction')==row['text']:
                        task['work_brief']['latest_instruction']=''
                    self._event(db,tid,self.command_key(request_id,'revoked'),'input_revoked','用户改为新事项；未投递补充已撤销')
                moves[request_id]={'request_id':new_request_id,'revoked':revoked}
                self._save(db,task)
            text=row['text']
        # Separate durable outbox, same identity on any retry; unknown inputs are never replayed to worker.
        receipt=conversation.submit(new_request_id,text,new_item={'task_id':tid,'input_request_id':request_id})
        return {**receipt,'revoked':revoked,'note':'未送达补充已撤销，已另开新事项' if revoked else '原任务可能已收到这条补充，无法撤回；已另开新事项'}

    def pending_start_inputs(self, tid):
        with self.db() as db:
            return [dict(r) for r in db.execute("SELECT * FROM inputs WHERE task_id=? AND state='pending_start' ORDER BY updated_at,request_id", (tid,))]

    def execution_prompt(self, task):
        task=next((t for t in self.list() if t['id']==task['id']),task)
        instructions = self.pending_start_inputs(task['id'])
        brief='\n\n[Com 当前任务交接；只沿原授权执行]\n'+json.dumps(task.get('work_brief',{}),ensure_ascii=False)
        instructions=[command for command in instructions if not readonly_restriction(command['text'])]
        policy='[Com 当前有效操作权限]\n用户已取消 Com 的全部只读约束，当前为 danger-full-access，在原工作目录直接执行。原文及审计中的只读要求已撤销，不再限制操作；真实来源、去重和严重不可逆动作保护仍生效。\n\n'
        return policy+task['prompt'] + brief + (('\n\n用户后续要求：\n' + '\n'.join('[Com input:'+c['request_id']+'] '+c['text'] for c in instructions)) if instructions else '')

    def transition_input(self, request_id, expected, state, error='', event_suffix=''):
        with self.db() as db:
            row = db.execute('SELECT * FROM inputs WHERE request_id=?', (request_id,)).fetchone()
            if not row or row['state'] not in expected:
                return False
            db.execute('UPDATE inputs SET state=?,error=?,updated_at=? WHERE request_id=?',
                       (state,error,time.time(),request_id))
            self._event(db,row['task_id'],self.command_key(request_id,state)+event_suffix,'input_'+state,
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
                        verification_status='pending',quality_review=None,verification_checks_fingerprint=None,updated_at=time.time())
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
                linked=getattr(conversation,'task_receipt_for_message',None)
                parent=None
                if linked and task.get('origin_session_id') in ('personal-main','com-personal-main','com-pi-main') and hasattr(conversation,'db'):
                    with conversation.db() as source_db:
                        human=source_db.execute("SELECT id FROM messages WHERE id=? AND role='user'",(task.get('origin_message_id'),)).fetchone()
                    if human:parent=human['id']
                if linked and parent:linked(receipt_id,row['text'],parent)
                else:conversation.task_receipt(receipt_id, row['text'])
                if (task.get('origin_request_id') or '').startswith('work:'):
                    conversation._finish(task['origin_message_id'],'completed')
                if not task.get('interactive') and hasattr(conversation,'process_background'):
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
        if not isinstance(evidence,list) or not evidence or any(not isinstance(e,dict) or not e.get('reference') or e.get('passed') is False for e in evidence):
            raise ValueError('验收必须提供可定位的证据引用')
        task=next((t for t in self.list() if t['id']==tid),None)
        if not task or task['status']!='execution_finished':
            raise ValueError('只能验收已结束任务')
        if (task.get('authorization') or {}).get('entry') == 'work_page_human_chat':
            raise ValueError('工作页自然聊天不走任务验收')
        criteria=task.get('acceptance_criteria',[])
        covered={e.get('criterion_id') for e in evidence if e.get('passed') is True}
        missing=[c['id'] for c in criteria if c['id'] not in covered]
        if missing:raise ValueError('验收证据未覆盖完成条件：'+', '.join(missing))
        coverage={'mode':'declared_criteria' if criteria else 'human_or_legacy_checks',
                  'required':[c['id'] for c in criteria],'covered':sorted(v for v in covered if v),
                  'semantic_assessment':(task.get('quality_review') or {}).get('verdict','not_run')}
        result={**task.get('structured_result',{}),'verification_status':'passed','evidence':evidence,
                'artifacts':artifacts or task.get('artifacts',[]),'coverage':coverage}
        evidence_key=hashlib.sha256(json.dumps(evidence,sort_keys=True,ensure_ascii=False).encode()).hexdigest()[:16]
        return self.change(tid,'verified:'+tid+':'+str(task.get('run_id'))+':'+evidence_key,'verification.passed','验收通过，已记录真实检查证据',
                           verification_status='passed',structured_result=result,artifacts=result['artifacts'])[0]

    def recover(self):
        with self.db() as db:
            sending = [r[0] for r in db.execute("SELECT request_id FROM inputs WHERE state IN ('sending','worker_queued')")]
        for request_id in sending:
            self.transition_input(request_id, ('sending','worker_queued'), 'unknown', '服务重启，送达待核实；不会重发')
        for task in self.list():
            if task['status'] in ('running', 'waiting', 'dispatching', 'cancel_requested') or (task['status']=='paused' and (task.get('run_id') or task.get('session_id'))):
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
            if command['state']=='queued' and readonly_restriction(command['text']) and full_access_enabled(task):
                self.store.transition_input(key,('queued',),'revoked','只读限制已撤销，不投递旧约束')
                continue
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
                command={**command,'text':'[Com 当前任务上下文；不扩展原授权]\n'+
                         json.dumps(task.get('work_brief',{}),ensure_ascii=False)+'\n用户本次补充：\n'+command['text']}
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
            for task in tasks:
                if task['status']=='queued':self.queue_blocked(task,'并发已满，等待现有任务结束或核实状态',[item['id'] for item in active])
            return
        for task in tasks:
            if task['status'] != 'queued':
                continue
            if business_read_task(task) and not task.get('execution_scope'):
                task,_=self.store.change(task['id'],'scope:'+task['id'],'execution.scope',
                                        '真实用户要求为业务查询；仍使用最高操作权限',execution_scope='business-query')
            dependencies=[next((t for t in tasks if t['id']==ident),None) for ident in task.get('depends_on') or []]
            blocked=[t for t in dependencies if not t or t['status']!='execution_finished' or
                     t.get('verification_status')!='passed' or
                     (t.get('workspace_copy') and (not t.get('run_id') or t.get('merged_run_id')!=t.get('run_id')))]
            if blocked:
                if task.get('dependency_status')!='blocked':
                    self.store.change(task['id'],'dependency-blocked:'+task['id'],'dependency.waiting',
                                      '前置任务需执行结束、验收通过；写入副本还需合入。',
                                      dependency_status='blocked',block_reason='等待前置任务验收及合入')
                continue
            if task['agent']=='claude' and any(t['agent']=='claude' for t in active):
                self.queue_blocked(task,'Claude 并发上限为一项',[item['id'] for item in active if item['agent']=='claude'])
                continue
            # Context isolation is not file isolation. Readers may run together; writers serialize.
            writers=[t for t in active if (Path(t['cwd']).is_relative_to(Path(task['cwd'])) or Path(task['cwd']).is_relative_to(Path(t['cwd']))) and
                     (not inspection_task(t) or t['status']=='unknown')]
            if writers and not inspection_task(task):
                self.queue_blocked(task,'同目录任务仍在执行或状态待核实，暂不启动可能写入的任务',[item['id'] for item in writers])
                continue
            preflight=getattr(self.runtime,'preflight_task',None)
            if preflight:
                try:
                    await preflight(task)
                except ValueError as error:
                    self.store.change(task['id'],'blocked:'+task['id']+':'+str(time.time_ns()),'waiting',str(error),
                                      status='paused',pause_phase='pre_start',block_reason=str(error))
                    continue
            attempt=task.get('dispatch_attempt',0)
            suffix=(':'+str(attempt)) if attempt else ''
            key = 'dispatch:'+task['id']+suffix
            task, fresh = self.store.change(task['id'], key, 'dispatching', status='dispatching',dependency_status='ready',block_reason='',blocked_by=[],
                                           startup_phase='worker_create',dispatch_attempt=attempt)
            if not fresh:
                return
            inputs = self.store.pending_start_inputs(task['id'])
            prompt = self.store.execution_prompt(task)
            for command in inputs:
                self.store.transition_input(command['request_id'], ('pending_start',), 'sending',event_suffix=suffix)
            sid = ''
            try:
                create = getattr(self.runtime,'create_task_worker',None)
                sid = await create(task) if create else await self.runtime.create(task['agent'], task['cwd'], sandbox=task['sandbox'])
                self.store.change(task['id'],'worker-ready:'+task['id']+suffix,'worker.ready',
                                  '工作器已启动；即将发送任务',session_id=sid,startup_phase='input_sending')
                run_id = await self.runtime.input(sid, prompt, task['authorization']['request_id'])
                if not run_id:
                    raise RuntimeError('Worker did not confirm a run ID')
                self.store.change(task['id'], 'started:'+task['id']+suffix, 'started', status='running', session_id=sid, run_id=run_id,
                                  startup_phase='input_accepted',startup_failure=None)
                for command in inputs:
                    state='delivered'
                    meta=getattr(getattr(self.runtime,'h',None),'managed',lambda:{})().get(sid,{})
                    if meta.get('transport') in ('com-pi-rpc','claude-agent-sdk'):state='worker_queued'
                    self.store.transition_input(command['request_id'], ('sending',), state,event_suffix=suffix)
            except Exception as error:
                safe_startup=isinstance(error,WorkerStartupFailure) and not sid
                safe_rejection=isinstance(error,WorkerInputRejected) and bool(sid)
                if safe_startup or safe_rejection:
                    kind='worker.input_rejected' if safe_rejection else 'worker.startup_failed'
                    phase='native_prompt_rejected' if safe_rejection else 'failed_before_input'
                    self.store.change(task['id'],'start-failed:'+task['id']+suffix,kind,str(error),
                                      status='paused',pause_phase='pre_start',startup_phase=phase,
                                      session_id='',startup_failure=error.details,block_reason=str(error))
                    for command in inputs:
                        self.store.transition_input(command['request_id'], ('sending',), 'pending_start',
                                                    '工作器未开始处理任务；保持原指令等待恢复',event_suffix=suffix)
                else:
                    reason='任务发送结果待核实（'+type(error).__name__+'）；不会自动重发'
                    self.store.change(task['id'], 'start-unknown:'+task['id']+suffix, 'execution_unknown',
                                      reason, status='unknown', session_id=sid,block_reason=reason,
                                      startup_phase='delivery_unknown')
                    for command in inputs:
                        self.store.transition_input(command['request_id'], ('sending',), 'unknown',
                                                    '初始任务送达待核实；不会重发',event_suffix=suffix)
            return

    def queue_blocked(self,task,reason,blocked_by):
        if task.get('block_reason')==reason and task.get('blocked_by')==blocked_by:return
        key=hashlib.sha256(json.dumps([reason,blocked_by],sort_keys=True).encode()).hexdigest()[:16]
        self.store.change(task['id'],'queue-blocked:'+task['id']+':'+key,'queue.blocked',reason,
                          block_reason=reason,blocked_by=blocked_by)

    async def resume(self, tid, request_id):
        """A preflight pause is safe to recheck; an uncertain dispatch is never replayed."""
        current=next((t for t in self.store.list() if t['id']==tid),None)
        if not current:raise ValueError('Task not found')
        old=next((e for e in current.get('events',[]) if e['request_id']==request_id),None)
        if old:
            if old['kind']!='resumed':raise ValueError('Request conflicts with another command')
            return current
        if current['status']!='paused' or current.get('session_id') or current.get('run_id'):
            raise ValueError('只能恢复启动前暂停的任务；送达未知必须先核实，不能重放')
        attempted=any(event['kind']=='dispatching' for event in current.get('events',[]))
        attempt=current.get('dispatch_attempt',0)+(1 if attempted else 0)
        return self.store.change(tid,request_id,'resumed','已恢复排队，将重新检查环境',
                                 status='queued',pause_phase='',block_reason='',startup_phase='queued',
                                 dispatch_attempt=attempt)[0]

    async def command(self, tid, text, request_id, cancel=False):
        if not cancel:
            command = self.store.enqueue(tid,text,request_id)
            await self.drain_inputs()
            command = next(c for t in self.store.list() for c in t['inputs'] if c['request_id']==request_id)
            return {'task_id':tid,'request_id':request_id,'delivery':command['state']}
        current = next((t for t in self.store.list() if t['id']==tid), None)
        if current and current['status'] in ('queued','paused') and not current.get('session_id') and not current.get('run_id'):
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
