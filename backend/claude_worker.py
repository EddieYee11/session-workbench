"""Existing third-party Claude Code via Agent SDK; no provider or model fallback."""
import asyncio
import contextlib
import json
import os
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from policy import deletion_risk


class ClaudeBudget:
    def __init__(self,state,clock=time.time):
        self.path=Path(state)/'claude-budget.sqlite'
        self.clock=clock
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS usage(task_id TEXT PRIMARY KEY,day TEXT NOT NULL,rounds INTEGER NOT NULL,tokens INTEGER NOT NULL,token_known INTEGER NOT NULL,automatic INTEGER NOT NULL DEFAULT 1)')

        with self.db() as db:
            if 'automatic' not in {row[1] for row in db.execute('PRAGMA table_info(usage)')}:
                db.execute('ALTER TABLE usage ADD COLUMN automatic INTEGER NOT NULL DEFAULT 1')

    @contextmanager
    def db(self):
        db=sqlite3.connect(self.path,timeout=20)
        try:
            with db:
                db.execute('BEGIN IMMEDIATE')
                yield db
        finally:
            db.close()

    def claim(self,task_id,automatic=True):
        day=datetime.fromtimestamp(self.clock(),ZoneInfo('Asia/Shanghai')).date().isoformat()
        with self.db() as db:
            old=db.execute('SELECT rounds,tokens,token_known FROM usage WHERE task_id=?',(task_id,)).fetchone()
            if not old:
                if automatic and db.execute('SELECT COUNT(*) FROM usage WHERE day=? AND automatic=1',(day,)).fetchone()[0]>=3:
                    raise ValueError('Claude 今日自动任务达到三次，已暂停')
                db.execute('INSERT INTO usage VALUES (?,?,0,0,0,?)',(task_id,day,int(automatic)))
                return 12
            if old[0]>=12:
                raise ValueError('Claude 此任务已达十二轮，已暂停')
            ceiling=int(os.environ.get('COM_CLAUDE_TOKEN_LIMIT','200000'))
            if old[1]>=ceiling:
                raise ValueError('Claude 此任务达到已核验 Token 阈值，已暂停')
            return 12-old[0]

    def record(self,task_id,rounds,usage=None):
        total=0
        known=bool(usage and 'input_tokens' in usage and 'output_tokens' in usage)
        if known:
            total=sum(int(usage.get(k,0)) for k in ('input_tokens','output_tokens','cache_creation_input_tokens','cache_read_input_tokens'))
        with self.db() as db:
            db.execute('UPDATE usage SET rounds=rounds+?,tokens=tokens+?,token_known=? WHERE task_id=?',(rounds,total,int(known),task_id))


def third_party_config(state=None):
    settings=Path.home()/'.claude/settings.json'
    cfg=json.loads(settings.read_text()) if settings.exists() else {}
    env={**cfg.get('env',{})}
    for key in ('ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL'):
        if os.environ.get(key):
            env[key]=os.environ[key]
    base=env.get('ANTHROPIC_BASE_URL','')
    if not base.startswith('https://') or 'api.anthropic.com' in base or not (env.get('ANTHROPIC_AUTH_TOKEN') or env.get('ANTHROPIC_API_KEY')):
        raise ValueError('Claude 第三方 endpoint/凭据未配置，不回退官方 API')
    override=Path(state)/'agent-config.json' if state else None
    if override and override.exists():
        model=json.loads(override.read_text()).get('claude_model')
        if model:
            env['ANTHROPIC_MODEL']=model
            for alias in ('SONNET','OPUS','HAIKU'):
                env['ANTHROPIC_DEFAULT_'+alias+'_MODEL']=model
    env['TZ']='Asia/Shanghai'
    return env,env.get('ANTHROPIC_MODEL') or env.get('ANTHROPIC_DEFAULT_SONNET_MODEL') or 'sonnet'


class ClaudeWorker:
    def __init__(self,state,task,emit,budget,guard=None):
        self.state=Path(state);self.task=task;self.emit=emit;self.budget=budget;self.guard=guard
        self.client=None;self.runner=None;self.status='ready';self.native_session=None
        self.disconnect_lock=asyncio.Lock()
        self.result='';self.rounds=0;self.usage=None;self.cancel_requested=False
        self.input_queue=[];self.delivered=set();self.failed_inputs=set();self.input_ids=set()
        saved=self.state/'claude-runtime'/(self.task['id']+'.json')
        if saved.exists():self.native_session=json.loads(saved.read_text()).get('native_session')

    def persist_session(self):
        saved=self.state/'claude-runtime'/(self.task['id']+'.json')
        saved.parent.mkdir(parents=True,exist_ok=True)
        saved.write_text(json.dumps({'native_session':self.native_session,'task_id':self.task['id']}))
        saved.chmod(0o600)

    async def start(self,text,request_id,*,input_request_id=None,echo_text=None):
        self.cancel_requested=False
        remaining=self.budget.claim(self.task['id'],automatic=self.task.get('automatic',True))
        env,model=third_party_config(self.state)
        config_dir=self.state/'claude-runtime'
        config_dir.mkdir(parents=True,exist_ok=True)
        env['CLAUDE_CONFIG_DIR']=str(config_dir)
        from claude_agent_sdk import ClaudeAgentOptions,ClaudeSDKClient,HookMatcher
        input_ident=input_request_id or request_id
        submitted='[Com input:'+input_ident+']\n'+text
        async def user_input(data,call_id,ctx):
            if data.get('prompt')==submitted:
                self.delivered.add(input_ident)
                self.emit({'kind':'input.delivered','request_id':input_ident,'turn_id':request_id})
                self.emit({'kind':'item','id':'input-'+input_ident,'role':'user','native_request_id':input_ident,
                           'text':text if echo_text is None else echo_text,'turn_id':request_id})
            return {}
        async def before(data,call_id,ctx):
            tool=data.get('tool_name','');args=data.get('tool_input',{})
            if self.guard:
                try:
                    self.guard(tool,args)
                except ValueError as error:
                    return {'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':str(error)}}
            elif deletion_risk(tool.lower(),args):
                return {'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':'不可逆动作需批准'}}
            self.emit({'kind':'tool.started','id':call_id,'tool_name':tool,'args':args,'turn_id':request_id})
            return {}
        async def after(data,call_id,ctx):
            self.emit({'kind':'tool.failed' if data.get('error') else 'tool.completed','id':call_id,
                       'tool_name':data.get('tool_name'),'turn_id':request_id})
            return {}
        options=ClaudeAgentOptions(cwd=self.task.get('workspace_copy',self.task['cwd']),
            cli_path=os.environ.get('WORKBENCH_CLAUDE','/usr/local/bin/claude'),
            env=env,model=model,fallback_model=None,setting_sources=[],
            permission_mode='acceptEdits',
            allowed_tools=['Read','Glob','Grep','Edit','Write','Bash'],
            sandbox={'enabled':True,'autoAllowBashIfSandboxed':True,'allowUnsandboxedCommands':False},
            disallowed_tools=['Agent','Task'],max_turns=remaining,
            resume=self.native_session,include_partial_messages=True,
            hooks={'UserPromptSubmit':[HookMatcher(hooks=[user_input])],'PreToolUse':[HookMatcher(hooks=[before])],
                   'PostToolUse':[HookMatcher(hooks=[after])],
                   'PostToolUseFailure':[HookMatcher(hooks=[after])]},
            system_prompt='你是 Com 的工作执行器。只在任务独立副本中执行原授权，汇报真实结果与证据；不可逆操作需批准，不能修改同步项目。')
        self.client=ClaudeSDKClient(options)
        await self.client.connect()
        self.input_ids.add(input_ident)
        await self.client.query(submitted)
        self.status='running'
        self.emit({'kind':'status','status':'running','turn_id':request_id})
        self.runner=asyncio.create_task(self.consume(request_id))
        return request_id

    async def consume(self,request_id):
        from claude_agent_sdk import AssistantMessage,ResultMessage,SystemMessage,TextBlock
        settled=False
        try:
            async for message in self.client.receive_response():
                if isinstance(message,SystemMessage) and message.subtype=='init':
                    self.native_session=message.data.get('session_id')
                    self.persist_session()
                    self.emit({'kind':'session','native_id':self.native_session,'turn_id':request_id})
                elif isinstance(message,AssistantMessage):
                    self.rounds+=1
                    self.budget.record(self.task['id'],1)
                    for block in message.content:
                        if isinstance(block,TextBlock):
                            self.result=block.text
                            self.emit({'kind':'item','id':'assistant-'+request_id+'-'+str(self.rounds),'role':'assistant','text':block.text,'turn_id':request_id})
                elif isinstance(message,ResultMessage):
                    self.usage=message.usage
                    self.budget.record(self.task['id'],0,self.usage)
                    self.native_session=message.session_id
                    self.persist_session()
                    self.status='interrupted' if self.cancel_requested else 'failed' if message.is_error else 'running' if self.input_queue else 'completed'
                    self.emit({'kind':'usage','usage':self.usage,'amount':None,'amount_status':'unknown',
                               'provider':'third-party','turn_id':request_id})
                    settled=True
                    break
        except Exception:
            self.status='unknown'
        finally:
            if not settled:
                self.status='unknown'
            self.emit({'kind':'status','status':self.status,'turn_id':request_id})
            await self.disconnect()
            if self.cancel_requested and self.status=='running':
                self.status='interrupted'
                self.failed_inputs.update(c['request_id'] for c in self.input_queue)
                self.input_queue.clear()
                self.emit({'kind':'status','status':'interrupted','turn_id':request_id})
            if settled and self.status=='running' and self.input_queue:
                queued=self.input_queue.pop(0)
                try:
                    await self.start('原授权内的补充：'+queued['text'],request_id,
                                     input_request_id=queued['request_id'],echo_text=queued['text'])
                except (ValueError,RuntimeError):
                    self.failed_inputs.add(queued['request_id'])
                    self.status='failed'
                    self.emit({'kind':'status','status':'failed','turn_id':request_id,'error':'后续输入预算/环境阻塞；未调用模型'})

    async def steer(self,text,request_id):
        if self.status!='running':raise ValueError('Claude 没有活动任务')
        self.budget.claim(self.task['id'],automatic=self.task.get('automatic',True))
        self.input_ids.add(request_id)
        self.input_queue.append({'text':text,'request_id':request_id})
        return {'state':'worker_queued'}

    async def abort(self):
        if self.status!='running':
            raise ValueError('Claude 没有活动执行')
        self.cancel_requested=True
        if self.client:await self.client.interrupt()
        # ACK is not termination; result stream will provide the actual terminal state.

    async def stop(self):
        self.cancel_requested=True
        self.failed_inputs.update(c['request_id'] for c in self.input_queue)
        self.input_queue.clear()
        if self.runner and self.runner is not asyncio.current_task() and not self.runner.done():
            self.runner.cancel()
            with contextlib.suppress(asyncio.CancelledError):await self.runner
        await self.disconnect()

    async def disconnect(self):
        # Result consumption and app shutdown can coincide. Close this native client once.
        async with self.disconnect_lock:
            client,self.client=self.client,None
            if client:await client.disconnect()
