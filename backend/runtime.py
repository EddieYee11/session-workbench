import asyncio, base64, json, os, shlex, time, uuid, contextlib, fcntl
from pathlib import Path
import websockets
from history import text_content,codex_item
from operation_policy import effective_sandbox

class Runtime:
    def __init__(self,history,token):
        self.h=history;self.state=history.state;self.token=token
        self.tmux=os.environ.get('WORKBENCH_TMUX','/opt/homebrew/bin/tmux')
        self.codex=os.environ.get('WORKBENCH_CODEX','/usr/local/bin/codex')
        self.pi=os.environ.get('WORKBENCH_PI','/usr/local/bin/pi')
        self.sock='session-workbench';self.rpc=None;self.pending={};self.counter=0;self.connect_lock=asyncio.Lock();self.action_lock=asyncio.Lock()
        self.live={};self.approvals={};self.reader_task=None;self.rpc_errors=''
        self.model_cache={}
        from worker_runtime import WorkerRuntime
        self.workers=WorkerRuntime(self)
    async def cmd(self,*args,input=None,check=True):
        p=await asyncio.create_subprocess_exec(*map(str,args),stdin=asyncio.subprocess.PIPE if input is not None else asyncio.subprocess.DEVNULL,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
        out,err=await p.communicate(input)
        if check and p.returncode:raise RuntimeError(err.decode(errors='replace')[:500] or '进程操作失败')
        return out.decode(errors='replace').strip()
    async def tm(self,*args,**kw):return await self.cmd(self.tmux,'-L',self.sock,*args,**kw)
    async def alive(self,name):
        r=await self.tm('display-message','-p','-t',name,'#{pane_dead}',check=False)
        return r=='0'
    async def ensure_rpc(self):
        async with self.connect_lock:
            if self.rpc is not None:return
            if not await self.alive('server'):
                await self.tm('new-session','-d','-s','server','-x','100','-y','30',shlex.join([self.codex,'app-server','--listen','ws://127.0.0.1:18942','--ws-auth','capability-token','--ws-token-file',str(self.state/'token')]))
            for n in range(30):
                try:
                    self.rpc=await websockets.connect('ws://127.0.0.1:18942',additional_headers={'Authorization':'Bearer '+self.token},max_size=32*1024*1024);break
                except Exception:
                    await asyncio.sleep(.3)
            if self.rpc is None:raise RuntimeError('Codex 会话服务未就绪')
            self.reader_task=asyncio.create_task(self.reader())
            await self.call('initialize',{'clientInfo':{'name':'mini_sessions','title':'会话工作台','version':'1.0.0'},'capabilities':{'experimentalApi':True}},connect=False)
            await self.rpc.send(json.dumps({'method':'initialized'}))
            self.rpc_errors=''
            for sid,m in self.h.managed().items():
                if m['agent']=='codex' and not m.get('ended'):
                    params={'threadId':m['native_id'],'excludeTurns':True,'cwd':m.get('original_cwd') or m.get('cwd')}
                    if m.get('sandbox'):
                        params.update(approvalPolicy='never',sandbox=effective_sandbox(m['sandbox']))
                    with contextlib.suppress(Exception):await self.call('thread/resume',params,connect=False)
    async def call(self,method,params=None,connect=True):
        if connect:await self.ensure_rpc()
        self.counter+=1;i=self.counter;f=asyncio.get_running_loop().create_future();self.pending[i]=f
        await self.rpc.send(json.dumps({'id':i,'method':method,'params':params or {}}))
        try:return await asyncio.wait_for(f,45)
        finally:self.pending.pop(i,None)
    async def models(self,agent):
        if agent=='hermes':
            return [{'id':'deepseek-v4-flash','label':'DeepSeek','provider':'deepseek','efforts':[],'default_effort':'','is_default':True}]
        if agent=='claude':
            from claude_worker import third_party_config
            _,model=third_party_config(self.state)
            return [{'id':model,'label':model,'provider':'third-party','efforts':[],'default_effort':'','is_default':True}]
        if agent not in ('pi','codex'):raise ValueError('不支持的 Agent')
        cached=self.model_cache.get(agent)
        if cached and time.monotonic()-cached[0]<300:return cached[1]
        if agent=='pi':
            rows=[]
            for line in (await self.cmd(self.pi,'--list-models')).splitlines()[1:]:
                fields=line.split()
                if len(fields)<5:continue
                provider,model=fields[:2]
                if not provider or not model:continue
                thinking=fields[4].lower()=='yes'
                rows.append({'id':provider+'/'+model,'label':model,'provider':provider,'efforts':['off','minimal','low','medium','high','xhigh','max'] if thinking else ['off'],'default_effort':'' if thinking else 'off'})
        else:
            rows=[];cursor=None;seen=set()
            for _ in range(20):
                params={'includeHidden':False,'limit':100}
                if cursor:params['cursor']=cursor
                page=await self.call('model/list',params)
                for item in page.get('data',[]):
                    if item.get('hidden'):continue
                    model=item.get('model','')
                    if not model or model in seen:continue
                    seen.add(model)
                    levels=[x.get('reasoningEffort') or x.get('effort') for x in item.get('supportedReasoningEfforts',[]) if isinstance(x,dict) and (x.get('reasoningEffort') or x.get('effort'))]
                    rows.append({'id':model,'label':item.get('displayName') or model,'provider':'OpenAI','efforts':levels,'default_effort':item.get('defaultReasoningEffort') or '', 'is_default':bool(item.get('isDefault'))})
                following=page.get('nextCursor')
                if not following:break
                if following==cursor:raise RuntimeError('模型列表分页异常')
                cursor=following
            else:raise RuntimeError('模型列表超过分页上限')
        if not rows:raise RuntimeError('Mac mini 暂无可选模型')
        self.model_cache[agent]=(time.monotonic(),rows)
        return rows
    async def validate_model(self,agent,model,effort):
        if not isinstance(model,str) or not isinstance(effort,str) or len(model)>200:raise ValueError('无效的模型设置')
        allowed={'off','minimal','low','medium','high','xhigh','max'} if agent=='pi' else {'none','minimal','low','medium','high','xhigh','max','ultra'}
        if effort and effort not in allowed:raise ValueError('不支持的推理强度')
        if not model and not effort:return ''
        if agent=='codex' and not model:raise ValueError('请先选择 Codex 模型，再选择推理强度')
        choices=await self.models(agent)
        picked=next((x for x in choices if x['id']==model),None) if model else None
        if model and not picked:raise ValueError('所选模型不在 Mac mini 的模型列表中')
        if picked and effort and effort not in picked['efforts']:raise ValueError('当前模型不支持这个推理强度')
        return effort or (picked['default_effort'] if agent=='codex' and picked else '')
    def event_file(self,sid):return self.state/(sid.replace(':','-')+'.events.jsonl')
    def emit(self,sid,event):
        event.setdefault('time',time.time())
        with self.event_file(sid).open('a') as f:f.write(json.dumps(event,ensure_ascii=False)+'\n')
        self.live.setdefault(sid,[]).append(event)
        if len(self.live[sid])>1000:self.live[sid]=self.live[sid][-1000:]
    async def reader(self):
        try:
            async for raw in self.rpc:
                msg=json.loads(raw)
                if 'method' not in msg:
                    f=self.pending.get(msg.get('id'))
                    if f and not f.done():
                        if 'error' in msg:f.set_exception(RuntimeError(str(msg['error'].get('message','RPC error'))))
                        else:f.set_result(msg.get('result',{}))
                    continue
                method=msg['method'];p=msg.get('params',{});nid=p.get('threadId') or p.get('thread',{}).get('id')
                if not nid:continue
                sid='codex:'+nid
                if sid not in self.h.managed():continue
                if 'id' in msg:
                    key=str(msg['id']);self.approvals[key]={'id':key,'rpc_id':msg['id'],'sid':sid,'method':method,'params':p}
                    self.emit(sid,{'kind':'approval','id':key,'title':'需要你回应','text':p.get('command',p.get('reason',method))})
                elif method in ('item/agentMessage/delta','item/commandExecution/outputDelta','item/reasoning/summaryTextDelta'):
                    self.emit(sid,{'kind':'delta','id':p.get('itemId',''),'text':p.get('delta',''),'role':'assistant' if 'agentMessage' in method else 'tool','turn_id':p.get('turnId')})
                elif method in ('item/started','item/completed'):
                    item=p.get('item',{});e=codex_item(item,item.get('id',''),time.time())
                    if e:self.emit(sid,dict(e,kind='item',state='running' if method.endswith('started') else 'completed',turn_id=p.get('turnId')))
                elif method=='turn/started':self.emit(sid,{'kind':'status','status':'running','turn_id':p.get('turn',{}).get('id')})
                elif method=='turn/completed':self.emit(sid,{'kind':'status','status':{'completed':'completed','interrupted':'interrupted'}.get(p.get('turn',{}).get('status'),'failed'),'turn_id':p.get('turn',{}).get('id'),'error':p.get('turn',{}).get('error')})
                elif method=='serverRequest/resolved':self.approvals.pop(str(p.get('requestId')),None)
        except Exception as e:self.rpc_errors=type(e).__name__
        finally:
            self.rpc=None
            for f in self.pending.values():
                if not f.done():f.set_exception(RuntimeError('Codex 连接中断，请先核实发送状态'))
    async def create(self,agent,cwd,model='',effort='',sandbox='danger-full-access',resume=None):
        sandbox=effective_sandbox(sandbox)
        cwd=str(Path(cwd).expanduser().resolve())
        if not Path(cwd).is_dir() or not Path(cwd).is_relative_to(self.h.home):raise ValueError('请选择 Mac mini 用户目录中的有效目录')
        if agent in ('claude','hermes'):
            if resume:return await self.workers.restore(resume['id'])
            return await self.workers.create({'id':'manual_'+uuid.uuid4().hex,'agent':agent,'cwd':cwd,
                'sandbox':sandbox,'automatic':False,'title':'Claude Code 工作会话'})
        if agent not in ('pi','codex'):raise ValueError('不支持的 Agent')
        if sandbox not in ('danger-full-access','workspace-write','read-only'):raise ValueError('无效的权限模式')
        if not resume:effort=await self.validate_model(agent,model,effort)
        policy='never'
        if resume:
            if not await self.resumable(resume):raise ValueError('会话正在使用或状态无法确认，暂不能恢复输入')
            nid=resume['native_id']
        elif agent=='pi':nid=str(uuid.uuid4())
        else:
            params={'cwd':cwd,'approvalPolicy':policy,'sandbox':sandbox}
            if model:params['model']=model
            response=await self.call('thread/start',params);nid=response['thread']['id']
        sid=agent+':'+nid;name='s-'+uuid.uuid4().hex[:12]
        if agent=='codex':
            if resume:await self.call('thread/resume',{'threadId':nid,'excludeTurns':True,'cwd':cwd,'approvalPolicy':policy,'sandbox':sandbox})
            args=[self.codex]
            if sandbox=='danger-full-access':args+=['--dangerously-bypass-approvals-and-sandbox']
            args+=['-c','check_for_update_on_startup=false','--remote','ws://127.0.0.1:18942','--remote-auth-token-env','WORKBENCH_RPC_TOKEN','resume',nid,'--no-alt-screen']
        else:
            args=[self.pi,'--approve','--extension',str(Path(__file__).with_name('pi-events.ts')),'--extension',str(Path(__file__).with_name('pi-yolo.ts'))]
            args+=['--session',resume['path']] if resume else ['--session-id',nid]
            if model:args+=['--model',model]
            if effort:args+=['--thinking',effort]
        script=self.state/(name+'.sh')
        prefix='#!/bin/zsh\nexport PATH=/opt/homebrew/bin:/usr/local/bin:$PATH\nexport TERM=xterm-256color\n'
        prefix+='export WORKBENCH_RPC_TOKEN="$(cat '+shlex.quote(str(self.state/'token'))+')"\n'
        prefix+='export SESSION_WORKBENCH_EVENTS='+shlex.quote(str(self.state/(name+'.pi.jsonl')))+'\n'
        if agent=='pi':prefix+='export SESSION_WORKBENCH_YOLO=1\n'
        script.write_text(prefix+'cd '+shlex.quote(cwd)+'\nexec '+shlex.join(args)+'\n');script.chmod(0o700)
        prior=self.h.managed().get(sid,{}) if resume else {}
        m={'sid':sid,'native_id':nid,'agent':agent,'cwd':cwd,'tmux':name,'created':time.time(),'source':'手机发起' if not resume else '从历史继续','pi_file':str(self.state/(name+'.pi.jsonl')),'script':str(script),'sandbox':sandbox,'approval_policy':policy,'model':model or prior.get('model',''),'effort':effort or prior.get('effort',''),'ended':False}
        for key in ('task_id','workspace_copy','original_cwd','automatic'):
            if key in prior:m[key]=prior[key]
        # Save before start so notifications cannot be lost.
        self.h.save_managed(sid,m)
        if agent=='pi':await self.ensure_terminal(sid)
        if not self.h.get(sid):
            with self.h.db() as d:d.execute('INSERT OR IGNORE INTO sessions VALUES(?,?,?,?,?,?,?,?,?)',(sid,agent,nid,'',cwd,'新会话',time.time(),'','只展示实际捕获的输出'))
        return sid
    async def preflight_task(self,task):
        from execution_boundary import require_host
        require_host(self.state)
        registry=getattr(self,'capabilities',None)
        try:
            import runtime_health
            if task['agent']=='claude':
                evidence=await runtime_health.claude(self.state)
                self.workers.budget.claim(task['id'],automatic=task.get('automatic',True))
            elif task['agent']=='pi':evidence=await runtime_health.pi(self.state)
            elif task['agent']=='hermes':
                from hermes_runtime import HermesRuntime
                evidence=await HermesRuntime(self.state).request('GET','/v1/capabilities')
                if not evidence.get('features',{}).get('run_submission'):raise ValueError('Hermes Runs unavailable')
            else:
                await self.ensure_rpc()
                if not await self.models('codex'):raise ValueError('Codex 未提供可用模型')
                evidence={'probe':'native-app-server-model-list','model_turns':0}
            if registry:registry.observe('runtime:'+task['agent'],runtime=task['agent'],state='verified',evidence=evidence)
        except (ValueError,RuntimeError) as error:
            if registry:registry.observe('runtime:'+task['agent'],runtime=task['agent'],state='unavailable',evidence={'reason':str(error)})
            raise ValueError(str(error)) from None
    async def create_task_worker(self,task):
        """Use the native account's advertised default rather than a stale config alias."""
        return await self.workers.create(task)
    async def resumable(self,s):
        m=self.h.managed().get(s['id'])
        if s['agent'] in ('claude','hermes'):
            return bool(m and m.get('transport') in ('claude-agent-sdk','hermes-runs') and not m.get('ended') and s['id'] not in self.workers.workers)
        if m and not m.get('ended') and (m['agent']=='codex' or await self.alive(m['tmux'])):return False
        if not Path(s['cwd']).is_dir():return False
        if s['agent']=='codex':
            # The native writer lock is authoritative across app-server instances.
            lockdir=self.h.home/'.codex/thread-writer-locks'
            for p in lockdir.glob('*'+s['native_id']+'*'):
                try:
                    with p.open('r+') as f:
                        fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);fcntl.flock(f,fcntl.LOCK_UN)
                except BlockingIOError:
                    # Our own app-server can retain a writer after the UI detaches.
                    # Only reopen a known ended session if the lock is held by that server.
                    if not (m and m.get('ended')):return False
                    holders=await self.cmd('/usr/sbin/lsof','-t',str(p),check=False)
                    if not holders.strip():return False
                    for pid in holders.splitlines():
                        command=await self.cmd('/bin/ps','-p',pid,'-o','command=',check=False)
                        if 'app-server --listen ws://127.0.0.1:18942' not in command:return False
                except OSError:return False
        else:
            # Pi does not expose cross-process ownership. Conservatively block while any
            # other interactive Pi may own this historical file.
            ps=await self.cmd('/bin/ps','-axo','pid=,comm=',check=False)
            known=set()
            for owned in self.h.managed().values():
                if owned['agent']=='pi' and not owned.get('ended'):
                    pid=await self.tm('display-message','-p','-t',owned['tmux'],'#{pane_pid}',check=False)
                    if pid.isdigit():known.add(pid)
            for line in ps.splitlines():
                parts=line.strip().split(None,1)
                if len(parts)==2 and (Path(parts[1]).name=='pi' or 'pi-coding-agent' in parts[1]) and parts[0] not in known:
                    return False
        return True
    async def input(self,sid,text,request_id,model=None,effort=None):
        if self.h.managed().get(sid,{}).get('transport'):
            return await self.workers.input(sid,text,request_id)
        m=self.h.managed().get(sid)
        if not m or m.get('ended') or (m['agent']=='pi' and not await self.alive(m['tmux'])):raise ValueError('请先继续会话')
        explicit=model is not None or effort is not None
        model='' if model is None else model
        effort='' if effort is None else effort
        if explicit and not model and not effort and (m.get('model') or m.get('effort')):
            raise ValueError('已有会话不能直接恢复 Mac 默认；请选一个具体模型，或开启新会话')
        if m['agent']=='codex' and not explicit and m.get('model'):
            # An empty Codex thread has not run a first turn yet. Keep the
            # launch selection effective even if an older phone omits fields.
            model=m['model'];effort=m.get('effort','')
        if model or effort:effort=await self.validate_model(m['agent'],model,effort)
        changing=bool(model or effort) and bool((model and model!=m.get('model','')) or (effort and effort!=m.get('effort','')))
        if changing:
            if await self.status(sid) not in ('ready','completed','failed','interrupted'):
                raise ValueError('会话正在处理消息，请稍后切换模型')
        if m['agent']=='codex':
            params={'threadId':m['native_id'],'input':[{'type':'text','text':text}]}
            if model:params['model']=model
            if effort:params['effort']=effort
            result=await self.call('turn/start',params)
            if model or effort:self._save_model(m,model,effort)
            return result.get('turn',{}).get('id')
        if changing:
            await self._set_pi_model(sid,m,model,effort)
        if self.stable_input(sid):
            await self.check_input_identity(sid)
            payload=base64.urlsafe_b64encode(json.dumps({'requestId':request_id,'text':text},ensure_ascii=False).encode()).decode().rstrip('=')
            command='/com-input '+payload
            await self.tm('load-buffer','-b',request_id,'-',input=command.encode())
            await self.tm('paste-buffer','-d','-p','-b',request_id,'-t',m['tmux'])
            await asyncio.sleep(.08);await self.tm('send-keys','-t',m['tmux'],'Enter')
            deadline=asyncio.get_running_loop().time()+8
            while asyncio.get_running_loop().time()<deadline:
                for event in reversed(self.events(sid)):
                    data=event.get('data',{})
                    if event.get('type')=='com_input_result' and data.get('requestId')==request_id:
                        if not data.get('ok'):raise ValueError(data.get('error') or 'Pi 未确认消息')
                        return request_id  # Preserve existing Pi task run_id semantics.
                if not await self.alive(m['tmux']):raise RuntimeError('Pi 会话已退出，请核实发送状态')
                await asyncio.sleep(.1)
            raise RuntimeError('Pi 未确认实际消息，请核实发送状态；不要重复提交')
        # Bracketed paste sends literal text; shell metacharacters never become host commands.
        await self.tm('load-buffer','-b',request_id,'-',input=text.encode())
        await self.tm('paste-buffer','-d','-p','-b',request_id,'-t',m['tmux'])
        await asyncio.sleep(.08);await self.tm('send-keys','-t',m['tmux'],'Enter')
        return request_id
    def stable_input(self,sid):
        m=self.h.managed().get(sid)
        if m and m.get('transport'):return sid in self.workers.workers
        return bool(m and (m.get('agent')=='codex' or m.get('agent')=='pi' and any(
            e.get('type')=='com_input_capabilities' and e.get('data',{}).get('stable_message_identity_v1') is True
            for e in self.events(sid))))
    async def check_input_identity(self,sid):
        m=self.h.managed().get(sid)
        if not m or m.get('ended'):raise ValueError('请先继续会话')
        if not self.stable_input(sid):
            raise ValueError('这个旧 Pi 会话尚未加载可靠消息身份；请结束后从历史恢复，或重新开启会话')
        if m['agent']=='pi' and not m.get('transport') and await self.status(sid) not in ('ready','completed','failed','interrupted'):
            raise ValueError('Pi 正在处理上一条消息，请完成后再发送')
    async def legacy_pi_idle(self,sid):
        """Only the managed native lifecycle can authorize a legacy restart."""
        m=self.h.managed().get(sid)
        if (not m or m.get('agent')!='pi' or m.get('ended') or self.stable_input(sid)
                or not m.get('tmux') or not await self.alive(m['tmux'])):return False
        source=self.h.get(sid)
        path=Path(source.get('path','')) if source else None
        if not path or not path.is_file():return False
        try:
            with path.open() as stream:meta=json.loads(stream.readline())
            if meta.get('type')!='session' or meta.get('id')!=m.get('native_id'):return False
        except (OSError,ValueError):return False
        idle=False
        for event in self.events(sid):
            typ=event.get('type')
            if typ in ('session_start','agent_settled'):idle=True
            elif typ in ('agent_start','agent_end'):idle=False
            elif typ=='queue_update' and (event.get('data',{}).get('steering') or event.get('data',{}).get('followUp')):idle=False
        return idle
    def _save_model(self,m,model,effort):
        if model:
            m['model']=model
            m['effort']=effort
        elif effort:m['effort']=effort
        self.h.save_managed(m['sid'],m)
    async def _set_pi_model(self,sid,m,model,effort):
        if not model and not effort:return
        request_id=str(uuid.uuid4())
        payload=base64.urlsafe_b64encode(json.dumps({'requestId':request_id,'model':model,'effort':effort}).encode()).decode().rstrip('=')
        command='/com-set-model '+payload
        buffer_name='config-'+request_id
        await self.tm('load-buffer','-b',buffer_name,'-',input=command.encode())
        await self.tm('paste-buffer','-d','-p','-b',buffer_name,'-t',m['tmux'])
        await asyncio.sleep(.08);await self.tm('send-keys','-t',m['tmux'],'Enter')
        deadline=asyncio.get_running_loop().time()+8
        while asyncio.get_running_loop().time()<deadline:
            for event in reversed(self.events(sid)):
                if event.get('type')=='config_result' and event.get('data',{}).get('requestId')==request_id:
                    data=event['data']
                    if not data.get('ok'):raise ValueError(data.get('error') or 'Pi 模型切换失败')
                    # A blank requested effort means "keep Pi's current level".
                    # Do not persist the observed level as an explicit choice.
                    self._save_model(m,data.get('model') or model,effort)
                    return
            if not await self.alive(m['tmux']):raise RuntimeError('Pi 会话已退出，消息未发送')
            await asyncio.sleep(.15)
        raise RuntimeError('Pi 模型切换未确认，消息未发送；请检查终端状态')
    async def ensure_terminal(self,sid):
        m=self.h.managed()[sid];name=m['tmux']
        if await self.alive(name):return
        script=m.get('script',str(self.state/(name+'.sh')))
        await self.tm('kill-session','-t',name,check=False)
        await self.tm('new-session','-d','-s',name,'-x','100','-y','32','/bin/zsh -l '+shlex.quote(script))
        await self.tm('set-option','-t',name,'remain-on-exit','on')
        await self.tm('set-option','-t',name,'history-limit','50000')

    async def capture(self,sid,lines=100,ansi=False):
        m=self.h.managed().get(sid)
        if not m:return ''
        return await self.tm('capture-pane','-p','-J',*(['-e'] if ansi else []),'-S',str(-max(1,min(int(lines),20000))),'-t',m['tmux'],check=False)
    def events(self,sid):
        m=self.h.managed().get(sid)
        if not m:return []
        p=Path(m['pi_file']) if m['agent']=='pi' and not m.get('transport') else self.event_file(sid)
        if not p.exists():return []
        out=[]
        with p.open() as f:
            for i,line in enumerate(f):
                try:e=json.loads(line);e['seq']=i;out.append(e)
                except json.JSONDecodeError:pass
        return out
    async def status(self,sid):
        m=self.h.managed().get(sid)
        if m and m.get('transport'):return await self.workers.status(sid)
        if not m:return 'history'
        if m.get('ended') or (m['agent']=='pi' and not await self.alive(m['tmux'])):return 'ended'
        if any(a['sid']==sid for a in self.approvals.values()):return 'waiting'
        status='ready'
        for e in self.events(sid):
            if e.get('kind')=='status':status=e['status']
            if e.get('type')=='agent_start':status='running'
            if e.get('type')=='agent_end':status='completed'
        return status
    def can_reconcile_task(self,task):
        if self.h.managed().get(task.get('session_id'),{}).get('transport')=='hermes-runs':
            import sqlite3
            try:
                with sqlite3.connect(self.state/'hermes-runs.sqlite') as db:
                    row=db.execute('SELECT run_id FROM runs WHERE request_id=?',(task.get('run_id'),)).fetchone()
                return bool(row and row[0])
            except sqlite3.Error:return False
        # Recovery needs evidence for this exact run, never a session's stale status.
        return bool(task.get('run_id') and any(e.get('turn_id')==task['run_id'] and
            (e.get('kind')=='status' or e.get('type')=='agent_settled')
            for e in self.events(task.get('session_id',''))))

    async def task_execution_active(self,task):
        # Unknown business results remain unknown. A dead legacy executor is
        # separately proven inactive and must not occupy a worker slot forever.
        meta=self.h.managed().get(task.get('session_id'),{})
        if meta.get('agent')=='pi' and not meta.get('transport'):
            if meta.get('ended') or meta.get('tmux') and not await self.alive(meta['tmux']):return False
            active=None
            for event in self.events(task.get('session_id','')):
                if event.get('type') in ('session_start','agent_settled'):active=False
                elif event.get('type')=='agent_start':active=True
                elif event.get('type')=='queue_update' and any(event.get('data',{}).get(k) for k in ('steering','followUp')):active=True
            return active
        return None

    async def task_status(self,task):
        if self.h.managed().get(task['session_id'],{}).get('transport')=='hermes-runs' and task['session_id'] not in self.workers.workers:
            await self.workers.restore(task['session_id'])
        if self.h.managed().get(task['session_id'],{}).get('transport'):
            if task['session_id'] in self.workers.workers:
                return await self.workers.status(task['session_id'])
            events=[e for e in self.events(task['session_id']) if e.get('turn_id')==task.get('run_id')]
            status=next((e.get('status') for e in reversed(events) if e.get('kind')=='status'),None)
            if status in ('completed','failed','interrupted'):return status
            if any(e.get('type')=='agent_settled' for e in events):
                reason=next((e.get('data',{}).get('message',{}).get('stopReason') for e in reversed(events) if e.get('type')=='message_end' and e.get('data',{}).get('message',{}).get('role')=='assistant'),None)
                return 'interrupted' if reason=='aborted' else 'failed' if reason=='error' else 'completed'
            return 'unknown'
        status=await self.status(task['session_id'])
        if task['agent']!='pi':
            if status=='waiting' and any(a['sid']==task['session_id'] and
                                         a.get('params',{}).get('turnId',task.get('run_id'))==task.get('run_id')
                                         for a in self.approvals.values()):
                return 'waiting'
            matches=[e for e in self.events(task['session_id']) if e.get('kind')=='status' and e.get('turn_id')==task.get('run_id')]
            if matches:
                observed=matches[-1]['status']
                return 'unknown' if self.rpc_errors and observed in ('running','waiting') else observed
            return 'unknown' if status in ('ended','history') else 'running'
        events=self.events(task['session_id'])
        # agent_end is a low-level run, not final settled state.
        last_start=max((i for i,e in enumerate(events) if e.get('type')=='agent_start'),default=-1)
        settled=next((e for e in reversed(events[last_start+1:]) if e.get('type')=='agent_settled'),None)
        if settled:
            messages=[e.get('data',{}).get('message',{}) for e in events[last_start+1:] if e.get('type')=='message_end']
            reason=next((m.get('stopReason') for m in reversed(messages) if m.get('role')=='assistant'),None)
            return 'interrupted' if reason=='aborted' else 'failed' if reason=='error' else 'completed'
        return 'unknown' if status=='ended' else 'running' if status=='completed' else status
    def task_capabilities(self,task):
        m=self.h.managed().get(task.get('session_id'),{})
        if m.get('transport'):
            return {'steer':m['agent'] in ('pi','claude','hermes'),'transport':m['transport']}
        # Legacy TUI has no reliable native steer; explicit resume upgrades its transport.
        return {'steer':task['agent']=='codex','transport':'codex-app-server' if task['agent']=='codex' else 'pi-tmux'}
    def task_input_state(self,task,request_id):
        worker=self.workers.workers.get(task['session_id'])
        if worker and request_id in getattr(worker,'delivered',set()):return 'delivered'
        if worker and request_id in getattr(worker,'failed_inputs',set()):return 'failed'
        return None
    async def deliver_task_input(self,task,command):
        worker=self.workers.workers.get(task['session_id'])
        if worker and task['agent'] in ('pi','claude','hermes'):
            return await worker.steer(command['text'],command['request_id'])
        if not self.task_capabilities(task)['steer']:
            return {'state':'unsupported'}
        text=('Com operates with full access in the authorized project. Application-imposed read-only '
              'restrictions have been revoked by the owner. Execute the actual user request and report evidence. '
              'Do not invent actions or repeat uncertain operations. New instruction: '
              + command['text'])
        result=await self.steer_task(task['session_id'],task['run_id'],text)
        if not isinstance(result,dict) or result.get('turnId')!=task['run_id']:
            return {'state':'unknown','error':'工作器未确认目标 turn ID；不宣告送达'}
        return {'state':'delivered'}
    async def steer_task(self,sid,turn_id,text):
        m=self.h.managed().get(sid)
        if not m or m['agent']!='codex' or not turn_id:
            raise ValueError('Native running turn is unavailable')
        return await self.call('turn/steer',{'threadId':m['native_id'],
            'expectedTurnId':turn_id,'input':[{'type':'text','text':text}]})
    async def stop(self,sid):
        m=self.h.managed()[sid]
        if m.get('transport'):return await self.workers.stop(sid)
        if m['agent']=='pi':await self.tm('send-keys','-t',m['tmux'],'Escape')
        else:
            events=self.events(sid);tid=next((e['turn_id'] for e in reversed(events) if e.get('turn_id')),None)
            if tid:await self.call('turn/interrupt',{'threadId':m['native_id'],'turnId':tid})
            else:await self.tm('send-keys','-t',m['tmux'],'Escape')
    async def cancel_task(self,task):
        if self.h.managed().get(task['session_id'],{}).get('transport'):
            return await self.workers.stop(task['session_id'])
        m=self.h.managed().get(task['session_id'])
        if not m or not task.get('run_id'):
            raise ValueError('Task worker identity is unavailable')
        if m['agent']=='codex':
            await self.call('turn/interrupt',{'threadId':m['native_id'],'turnId':task['run_id']})
        else:
            if m.get('ended') or not await self.alive(m['tmux']):
                raise ValueError('Pi worker is unavailable')
            await self.tm('send-keys','-t',m['tmux'],'Escape')
    async def decision(self,key,answer):
        a=self.approvals.get(key)
        if not a:raise ValueError('该请求已结束')
        method=a['method'];p=a['params']
        if method.endswith('requestUserInput'):
            result={'answers':{k:{'answers':[v]} for k,v in answer.get('answers',{}).items()}}
            if any(q['id'] not in result['answers'] for q in p.get('questions',[])):raise ValueError('请回答所有问题')
        else:
            choice=answer.get('decision','decline');allowed=p.get('availableDecisions',['accept','decline','cancel'])
            if choice not in allowed:raise ValueError('不支持的选择')
            result={'decision':choice}
        await self.rpc.send(json.dumps({'id':a['rpc_id'],'result':result}));self.approvals.pop(key,None)
