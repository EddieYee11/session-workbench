import asyncio,contextlib,hashlib,hmac,json,os,secrets,time,fcntl,termios,struct,pty,signal
from pathlib import Path
from contextlib import asynccontextmanager
from fastapi import FastAPI,Request,HTTPException,WebSocket,WebSocketDisconnect
from fastapi.responses import JSONResponse,StreamingResponse
from history import History,text_content
from runtime import Runtime
from voice import voice_router
from personal import PersonalBridge
from conversation import PersonalConversation
from signals import PersonalSignals
from signal_inspector import HermesSignalReviewer,SignalInspector
from work_dispatch import WorkProposalStore
from tasks import TaskStore,TaskController

HOME=Path(os.environ.get('WORKBENCH_HOME',str(Path.home())))
STATE=Path(os.environ.get('WORKBENCH_STATE',str(Path.home()/'.session-workbench')))
STATE.mkdir(parents=True,exist_ok=True);STATE.chmod(0o700)
TOKEN_FILE=STATE/'token'
if not TOKEN_FILE.exists():TOKEN_FILE.write_text(secrets.token_urlsafe(40));TOKEN_FILE.chmod(0o600)
TOKEN=TOKEN_FILE.read_text().strip()
history=History(HOME,STATE);runtime=Runtime(history,TOKEN)
personal=PersonalBridge(STATE)
conversation=PersonalConversation(STATE)
signals=PersonalSignals(STATE)
inspector=SignalInspector(signals,HermesSignalReviewer(STATE))
work_proposals=WorkProposalStore(STATE,HOME/'AI_Work_System')
task_store=TaskStore(STATE)
task_controller=TaskController(task_store,runtime,conversation)
conversation.task_context=lambda: [{k:t.get(k) for k in ('id','title','message_id','status','constraints','inputs','result')} for t in task_store.list()][-30:]
rate={}

@asynccontextmanager
async def lifespan(app):
    async def scan_loop():
        while True:
            await asyncio.to_thread(history.scan)
            if any(m['agent']=='codex' and not m.get('ended') for m in history.managed().values()):
                with contextlib.suppress(Exception):await runtime.ensure_rpc()
            await asyncio.sleep(4)
    task=asyncio.create_task(scan_loop())
    work_proposals.recover_inflight()
    task_store.recover()
    async def task_loop():
        while True:
            with contextlib.suppress(Exception):
                async with runtime.action_lock:await task_controller.poll()
            await asyncio.sleep(1)
    ledger_loop=asyncio.create_task(task_loop())
    conversation.start()
    inspector.start()
    yield
    task.cancel()
    ledger_loop.cancel()
    with contextlib.suppress(asyncio.CancelledError):await ledger_loop
    await inspector.stop()
    await conversation.stop()
    if runtime.rpc:await runtime.rpc.close()

app=FastAPI(lifespan=lifespan,docs_url=None,redoc_url=None,openapi_url=None)
app.include_router(voice_router(STATE))
@app.middleware('http')
async def auth(request,call_next):
    if request.url.path not in ('/health','/pair'):
        supplied=request.headers.get('authorization','')
        if not hmac.compare_digest(supplied,'Bearer '+TOKEN):return JSONResponse({'detail':'连接凭据无效，请重新配对'},401)
    response=await call_next(request);response.headers['Cache-Control']='no-store';return response
@app.exception_handler(ValueError)
@app.exception_handler(RuntimeError)
async def failure(request,exc):return JSONResponse({'detail':str(exc)},409)
@app.get('/health')
async def health():return {'service':'mini-sessions','version':'1.0.0'}
@app.post('/pair')
async def pair(request:Request):
    ip=request.client.host;now=time.time();attempts=[x for x in rate.get(ip,[]) if now-x<300]
    if len(attempts)>=5:raise HTTPException(429,'尝试过多，请稍后重试')
    rate[ip]=attempts+[now];body=await request.json();p=STATE/'pairing.json'
    if not p.exists():raise HTTPException(403,'请在 Mac mini 生成配对码')
    data=json.loads(p.read_text())
    if data['expires']<now or not hmac.compare_digest(str(body.get('code','')),data['code']):raise HTTPException(403,'配对码无效或已过期')
    p.unlink();return {'token':TOKEN}
@app.get('/status')
async def status():return {'index':history.progress,'managed':len(history.managed()),'host':'Mac mini','default_cwd':str(HOME/'AI_Work_System')}
@app.get('/personal/overview')
async def personal_overview():return await personal.overview()
@app.get('/personal/conversation')
async def personal_conversation():
    return conversation.snapshot()
@app.get('/personal/conversation/stream')
async def personal_conversation_stream(request:Request):
    raw=request.headers.get('last-event-id','')
    after=int(raw) if raw.isdecimal() and len(raw)<19 else None
    async def events():
        async for frame in conversation.stream(after):
            if frame['event']=='keepalive':
                yield ': keepalive\n\n'
            else:
                payload=json.dumps(frame['data'],ensure_ascii=False,separators=(',',':'))
                yield f"id: {frame['id']}\nevent: {frame['event']}\ndata: {payload}\n\n"
    return StreamingResponse(events(),media_type='text/event-stream',headers={'Cache-Control':'no-store','X-Accel-Buffering':'no'})
@app.post('/personal/conversation/messages')
async def personal_message(request:Request):
    data=await request.json()
    if not isinstance(data,dict) or not isinstance(data.get('request_id'),str) or not isinstance(data.get('text'),str):raise ValueError('消息格式无效')
    return conversation.submit(data['request_id'],data['text'])
@app.post('/personal/signals')
async def personal_signal_batch(request:Request):
    data=await request.json()
    if not isinstance(data,dict):raise ValueError('通知批次无效')
    result=signals.ingest(data.get('events'))
    if result['accepted_ids']:inspector.wake()
    return result
@app.get('/personal/signals')
async def personal_signal_list(limit:int=50):
    return signals.recent(limit)
@app.get('/personal/signals/health')
async def personal_signal_health():
    return signals.health()
@app.get('/personal/work/proposals')
async def personal_work_proposals(limit:int=20):
    items=work_proposals.list(limit)
    for item in items:
        item['parent_message_id']=item['origin_message_id']
        task_store.ensure(item)
    return {'items':items}
@app.post('/personal/work/proposals/{proposal_id}/approve')
async def approve_personal_work(proposal_id:str,request:Request):
    data=await request.json()
    if not isinstance(data,dict) or not isinstance(data.get('request_id'),str):raise ValueError('缺少有效请求标识')
    request_id=data['request_id']
    if data.get('explicit_authorization') is not True:raise ValueError('需要明确批准此任务的目录、提示与权限；刷新不能授权')
    async with runtime.action_lock:
        existing=work_proposals.get(proposal_id)
        if not existing:raise ValueError('工作建议不存在')
        if existing['approval_request_id']:
            if existing['approval_request_id']!=request_id:raise ValueError('工作建议已由另一次审批处理')
            return existing
        task_store.ensure(existing)
        # Serialize tasks in the same directory until isolated workspaces are available.
        if any(t['cwd']==existing['cwd'] and t['id']!=proposal_id and t['status'] in ('running','waiting','unknown','dispatching','cancel_requested') for t in task_store.list()):raise ValueError('该项目已有未结束任务，请先串行完成')
        proposal=work_proposals.claim_approval(proposal_id,request_id)
        task_store.change(proposal_id,'dispatch:'+request_id,'authorized',status='dispatching',authorization={'request_id':request_id,'cwd':proposal['cwd'],'sandbox':proposal['sandbox'],'prompt':proposal['prompt']})
        try:
            sid=await runtime.create(proposal['agent'],proposal['cwd'],sandbox=proposal['sandbox'])
            if proposal['agent']=='pi':
                for _ in range(80):
                    if any(e.get('type')=='session_start' for e in runtime.events(sid)):break
                    await asyncio.sleep(.25)
                else:raise RuntimeError('Pi 启动状态待核实')
                await asyncio.sleep(1)
            turn_id=await runtime.input(sid,proposal['prompt'],request_id)
            task_store.change(proposal_id,'started:'+request_id,'started',status='running',session_id=sid,run_id=turn_id)
            return work_proposals.mark_accepted(proposal_id,request_id,sid)
        except Exception as exc:
            task_store.change(proposal_id,'unknown:'+request_id,'execution_unknown',status='unknown',session_id=locals().get('sid',''))
            work_proposals.mark_unknown(proposal_id,request_id,type(exc).__name__[:80],locals().get('sid'))
            raise RuntimeError('派发状态待核实，请先查看工作会话；不会自动重发') from None
@app.post('/personal/work/proposals/{proposal_id}/reject')
async def reject_personal_work(proposal_id:str):
    proposal=work_proposals.reject(proposal_id)
    task_store.ensure(proposal)
    task_store.change(proposal_id,'rejected:'+proposal_id,'rejected',status='rejected')
    return proposal
@app.get('/personal/tasks')
async def personal_tasks():
    for proposal in work_proposals.list(100):task_store.ensure(proposal)
    return {'items':task_store.list()}
@app.post('/personal/tasks/{task_id}/input')
async def personal_task_input(task_id:str,request:Request):
    data=await request.json()
    if not isinstance(data,dict):raise ValueError('Invalid command')
    async with runtime.action_lock:
        return await task_controller.command(task_id,data.get('text'),data.get('request_id'))
@app.post('/personal/tasks/{task_id}/cancel')
async def personal_task_cancel(task_id:str,request:Request):
    data=await request.json()
    if not isinstance(data,dict):raise ValueError('Invalid command')
    async with runtime.action_lock:
        return await task_controller.command(task_id,'',data.get('request_id'),cancel=True)
@app.get('/models')
async def models(agent:str='pi'):
    return {'models':await runtime.models(agent)}
@app.post('/refresh')
async def refresh():asyncio.create_task(asyncio.to_thread(history.scan));return {'ok':True}
@app.get('/sessions')
async def sessions(q:str='',agent:str='',role:str='',cwd:str='',after:float=0,sort:str='recent',archived:bool=False):
    rows=await asyncio.to_thread(history.list,q,agent,role,cwd,after,sort,archived)
    managed=history.managed()
    for s in rows:
        s['source']=managed.get(s['id'],{}).get('source','Mac mini 历史')
        s['managed']=s['id'] in managed;s['status']=await runtime.status(s['id'])
        if s['managed']:
            s['model']=managed[s['id']].get('model','');s['effort']=managed[s['id']].get('effort','')
        s.pop('signature',None);s.pop('path',None)
    return {'sessions':rows,'index':history.progress,'coverage':'Mac mini 已发现的本机历史'}
@app.get('/directories')
async def directories(path:str=''):
    p=Path(path).expanduser().resolve() if path else HOME/'AI_Work_System'
    if not p.is_relative_to(HOME) or not p.is_dir():raise HTTPException(400,'无效目录')
    with history.db() as d:recent=[r[0] for r in d.execute('SELECT DISTINCT cwd FROM sessions ORDER BY updated DESC LIMIT 12') if Path(r[0]).is_dir()]
    return {'path':str(p),'parent':str(p.parent) if p!=HOME else None,'directories':[str(x) for x in sorted(p.iterdir()) if x.is_dir() and not x.name.startswith('.')],'recent':recent}
@app.get('/sessions/{sid}')
async def detail(sid:str):
    s=history.get(sid)
    if not s:raise HTTPException(404,'会话不存在')
    m=history.managed().get(sid);s['status']=await runtime.status(sid);alive=bool(m and not m.get('ended') and (m['agent']=='codex' or await runtime.alive(m['tmux'])))
    s['capabilities']={'history':True,'input':alive,'terminal':alive and (s['agent']=='pi' or bool(history.messages(sid))),'resume':False if alive else await runtime.resumable(s),'queue':False,'steer':False}
    s['managed']=bool(m);s['source']=(m or {}).get('source','Mac mini 历史')
    if m:s['model']=m.get('model','');s['effort']=m.get('effort','')
    s.pop('signature',None);s.pop('path',None)
    return {'session':s,'messages':await asyncio.to_thread(history.messages,sid)}
@app.get('/sessions/{sid}/live')
async def live(sid:str,after:int=-1):
    events=runtime.events(sid)
    return {'status':await runtime.status(sid),'events':[], 'items':live_items(events), 'cursor':events[-1]['seq'] if events else -1,'approvals':[{k:v for k,v in a.items() if k!='rpc_id'} for a in runtime.approvals.values() if a['sid']==sid]}
def live_items(events):
    items={}
    for e in events:
        kind=e.get('kind');typ=e.get('type');data=e.get('data',{});ts=e.get('time',0)
        if kind=='item':
            key=e['id'];old=items.get(key,{})
            items[key]={**old,**e,'text':e.get('text') or old.get('text','')}
        elif kind=='delta':
            key=e['id'];old=items.setdefault(key,{'id':key,'role':e.get('role','assistant'),'title':'实时输出','text':'','time':ts})
            old['text']+=e.get('text','')
        elif typ in ('message_start','message_update','message_end'):
            m=data.get('message',{});role=m.get('role')
            if role not in ('user','assistant','toolResult'):continue
            key=m.get('toolCallId') or 'pi:'+str(m.get('timestamp',0))
            items[key]={'id':key,'role':'tool' if role=='toolResult' else role,'title':m.get('toolName',''),'text':text_content(m.get('content','')),'time':ts}
        elif typ in ('tool_execution_start','tool_execution_update','tool_execution_end'):
            key=data.get('toolCallId','tool');result=data.get('result',data.get('partialResult',{}))
            body=text_content(result.get('content','')) if isinstance(result,dict) else str(result)
            if not body:body=json.dumps(data.get('args',{}),ensure_ascii=False)
            items[key]={'id':key,'role':'tool','title':data.get('toolName','工具')+(' · 执行中' if typ!='tool_execution_end' else ' · 已结束'),'text':body,'time':ts}
    return [x for x in items.values() if x.get('text')]

@app.get('/sessions/{sid}/terminal-history')
async def terminal_history(sid:str):
    m=history.managed().get(sid)
    if not m or m.get('ended') or not await runtime.alive(m['tmux']):
        raise HTTPException(409,'当前会话没有可读取的终端输出')
    return {'text':await runtime.capture(sid,20000,ansi=True),'limit':20000,'format':'ansi'}

@app.post('/sessions/{sid}/labels')
async def labels(sid:str,request:Request):history.label(sid,await request.json());return {'ok':True}
@app.get('/receipts/{rid}')
async def receipt(rid:str):
    with history.db() as d:r=d.execute('SELECT data FROM receipts WHERE id=?',(rid,)).fetchone()
    if not r:raise HTTPException(404,'尚无发送记录')
    return json.loads(r[0])
async def once(data,action):
    rid=data.get('request_id','')
    if len(rid)<10 or len(rid)>100:raise ValueError('缺少有效请求标识')
    fingerprint=hashlib.sha256(json.dumps(data,sort_keys=True).encode()).hexdigest()
    async with runtime.action_lock:
        with history.db() as d:
            old=d.execute('SELECT fingerprint,data FROM receipts WHERE id=?',(rid,)).fetchone()
            if old:
                if old[0]!=fingerprint:raise ValueError('请求标识冲突')
                return json.loads(old[1])
            d.execute('INSERT INTO receipts VALUES(?,?,?)',(rid,fingerprint,json.dumps({'status':'unknown','request_id':rid})))
        try:result=await action()
        except Exception as e:
            # Unknown is deliberate: a process may have accepted before transport failed.
            with history.db() as d:d.execute('UPDATE receipts SET data=? WHERE id=?',(json.dumps({'status':'unknown','request_id':rid,'error':str(e)}),rid))
            raise
        result={'status':'accepted','request_id':rid,**result}
        with history.db() as d:d.execute('UPDATE receipts SET data=? WHERE id=?',(json.dumps(result),rid))
        return result
@app.post('/sessions')
async def create(request:Request):
    data=await request.json()
    async def action():
        sid=await runtime.create(data.get('agent','pi'),data.get('cwd',str(HOME/'AI_Work_System')),data.get('model',''),data.get('effort',''),data.get('sandbox','danger-full-access'))
        if data.get('prompt'):
            # Wait for Pi TUI initialization before literal input. Codex uses structured RPC.
            if data.get('agent','pi')=='pi':
                for _ in range(80):
                    if any(e.get('type')=='session_start' for e in runtime.events(sid)):break
                    await asyncio.sleep(.25)
                else:raise RuntimeError('Pi 启动未就绪，请在会话中检查终端；不要重复提交')
                await asyncio.sleep(1)
            await runtime.input(sid,data['prompt'],data['request_id'],data.get('model','') if data.get('agent','pi')=='codex' else '',data.get('effort','') if data.get('agent','pi')=='codex' else '')
        return {'sid':sid}
    return await once(data,action)
@app.post('/sessions/{sid}/resume')
async def resume(sid:str,request:Request):
    data=await request.json();s=history.get(sid)
    if not s:raise HTTPException(404,'会话不存在')
    async def action():return {'sid':await runtime.create(s['agent'],s['cwd'],resume=s)}
    return await once(dict(data,sid=sid,action='resume'),action)
@app.post('/sessions/{sid}/input')
async def send(sid:str,request:Request):
    data=await request.json()
    if not data.get('text','').strip():raise ValueError('输入为空')
    async def action():return {'sid':sid,'turn_id':await runtime.input(sid,data['text'],data['request_id'],data.get('model'),data.get('effort'))}
    return await once(dict(data,sid=sid,action='input'),action)
@app.post('/sessions/{sid}/stop')
async def stop(sid:str):await runtime.stop(sid);return {'ok':True}
@app.post('/sessions/{sid}/end')
async def end(sid:str):
    m=history.managed().get(sid)
    if not m:raise ValueError('不是本应用管理的会话')
    if m['agent']=='codex':
        with contextlib.suppress(Exception):await runtime.stop(sid)
        with contextlib.suppress(Exception):await runtime.call('thread/unsubscribe',{'threadId':m['native_id']})
    await runtime.tm('kill-session','-t',m['tmux'],check=False)
    m['ended']=True;history.save_managed(sid,m);return {'ok':True}
@app.post('/approvals/{key}')
async def decision(key:str,request:Request):await runtime.decision(key,await request.json());return {'ok':True}
@app.websocket('/terminal/{sid}')
async def terminal(ws:WebSocket,sid:str):
    await ws.accept();master=None;proc=None
    try:
        hello=await asyncio.wait_for(ws.receive_json(),5)
        if not hmac.compare_digest(str(hello.get('token','')),TOKEN):await ws.close(1008);return
        m=history.managed().get(sid)
        if not m or m.get('ended'):await ws.close(1008);return
        if m['agent']=='codex':await runtime.ensure_terminal(sid)
        if not await runtime.alive(m['tmux']):await ws.close(1008);return
        master,slave=pty.openpty();os.set_blocking(master,False)
        fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',32,100,0,0))
        proc=await asyncio.create_subprocess_exec(runtime.tmux,'-L',runtime.sock,'attach-session','-t',m['tmux'],stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'},start_new_session=True)
        os.close(slave)
        async def output():
            while proc.returncode is None:
                try:
                    b=os.read(master,65536)
                    if b:await ws.send_bytes(b)
                except BlockingIOError:pass
                except OSError:break
                await asyncio.sleep(.025)
        task=asyncio.create_task(output())
        try:
            while True:
                data=await ws.receive_json()
                if data.get('type')=='resize':
                    fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',max(5,min(150,int(data['rows']))),max(20,min(400,int(data['cols']))),0,0))
                    # The detached attaching client has no controlling TTY; notify it explicitly.
                    if proc.returncode is None:proc.send_signal(signal.SIGWINCH)
                elif data.get('type')=='input':
                    payload=str(data.get('data','')).encode()
                    if len(payload)>65536:raise ValueError('终端输入过长')
                    os.write(master,payload)
        finally:task.cancel()
    except (WebSocketDisconnect,asyncio.TimeoutError,ValueError,OSError):pass
    finally:
        if proc and proc.returncode is None:proc.terminate();await proc.wait()
        if master is not None:os.close(master)
        # Only the attaching client exits; the tmux Agent session keeps running.
