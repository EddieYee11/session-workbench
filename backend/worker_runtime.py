"""Com-managed RPC workers, independent from interactive native histories."""
import asyncio
import json
import time
import uuid
from pathlib import Path

from claude_worker import ClaudeWorker,ClaudeBudget
from pi_rpc import PiRPC
from policy import deletion_risk,recoverable_remove
from workspace_copies import WorkspaceCopies
from tasks import WorkerStartupFailure,WorkerInputRejected
from operation_policy import effective_sandbox


def startup_failure(error,phase='worker_create',session_id=''):
    code='native_startup_failed' if phase=='native_startup' else 'worker_create_failed'
    if isinstance(error,FileNotFoundError):code='missing_runtime_path'
    elif isinstance(error,PermissionError):code='startup_permission_denied'
    elif isinstance(error,TimeoutError):code='startup_timeout'
    elif isinstance(error,(TypeError,ValueError)):code='invalid_startup_configuration'
    return WorkerStartupFailure(type(error).__name__,code,phase,session_id)


def business_read_prompt(text):
    from datetime import datetime
    from zoneinfo import ZoneInfo
    now=datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(timespec='seconds')
    return ('[Com 业务查询]\n当前时间：'+now+'；时区：Asia/Shanghai。\n'
            '直接调用 bookkeeping_search 按 date（YYYY-MM-DD）、amount（元）查历史账目；'
            '可用 start_date/end_date、keyword、limit。年份未给且原任务未指定时按当前年份解释。'
            '该工具覆盖全量真实账本，recent 只含最近30笔，不能据此断言历史记录不存在。'
            '查询有匹配即依据真实返回的日期、金额、分类和备注回答；没有匹配再按原授权范围查。'
            '用户已取消只读限制，按本次真实查询要求完成工作；不得无依据新增账目。\n\n'+text)


def interactive_full_access(task):
    return (task.get('interactive') is True and task.get('sandbox')=='danger-full-access' and
            bool((task.get('authorization') or {}).get('source_message_id')))


class WorkerRuntime:
    def __init__(self,runtime):
        self.runtime=runtime
        self.workers={}
        self.runners={}
        self.statuses={}
        self.budget=ClaudeBudget(runtime.state)
        self.copies=WorkspaceCopies(runtime.state)

    def guard(self,task,tool,args):
        store=getattr(getattr(self,'runtime',None),'task_store',None)
        if store:
            task=next((current for current in store.list() if current['id']==task.get('id')),task)
            if task.get('status') not in ('dispatching','running','waiting'):
                raise ValueError('任务已暂停、取消或状态未知，不能继续调用工具')
        kind=tool.lower()
        path=args.get('file_path') or args.get('path')
        root=Path(task['cwd']).resolve()
        if path and not (root/path).resolve().is_relative_to(root):
            raise ValueError('工具路径超出任务目录')
        explicit_destructive=str(args.get('action',args.get('operation',''))).lower() in ('delete','remove','clear','destroy','overwrite','truncate','purge')
        if (kind not in ('write','edit','multiedit') or explicit_destructive) and deletion_risk(kind,args):
            approved=task.get('authorization',{}).get('actual_action') or {}
            exact=approved.get('tool','').lower()==kind and approved.get('args')==args
            if not exact and not recoverable_remove(kind,args,task.get('workspace_copy')):
                raise ValueError('不可逆/未归类破坏动作需具体批准')

    async def create(self,task):
        try:
            return await self._create(task)
        except WorkerStartupFailure:
            raise
        except Exception as error:
            raise startup_failure(error) from None

    async def _create(self,task):
        task=dict(task)
        task['sandbox']=effective_sandbox(task.get('sandbox'),task)
        store=getattr(self.runtime,'task_store',None)
        if task.get('workspace_copy') and store and any(current['id']==task['id'] for current in store.list()):
            store.change(task['id'],'full-cwd:'+task['id']+':'+str(task.get('dispatch_attempt',0)),
                         'permissions.original_cwd','新工作轮在原目录执行；历史副本只留审计',workspace_copy=None)
        task['workspace_copy']=None
        from execution_boundary import require_host
        require_host(self.runtime.state)
        if task['agent']=='claude' and any(w.status=='running' for w in self.workers.values() if isinstance(w,ClaudeWorker)):
            raise ValueError('Claude 并发上限一项')
        if task['agent']=='hermes':
            from hermes_runtime import HermesRuntime
            sid='hermes:com-'+uuid.uuid4().hex
            worker=HermesRuntime(self.runtime.state,sid.split(':',1)[1],emit=lambda e:self.runtime.emit(sid,e),
                context={k:task.get(k) for k in ('id','origin_session_id','origin_message_id','origin_request_id')})
            await worker.start()
            meta={'sid':sid,'native_id':worker.session_id,'agent':'hermes','cwd':task['cwd'],'created':time.time(),
                  'source':'Com 后台任务','sandbox':task['sandbox'],'transport':'hermes-runs','ended':False,'tmux':'',
                  'model':'deepseek-v4-flash','effort':'','task_id':task['id'],'automatic':task.get('automatic',True)}
            self.runtime.h.save_managed(sid,meta)
            with self.runtime.h.db() as db:
                db.execute('INSERT OR IGNORE INTO sessions VALUES(?,?,?,?,?,?,?,?,?)',
                           (sid,'hermes',worker.session_id,'',task['cwd'],task.get('title','后台任务'),time.time(),'','Hermes Runs'))
            self.workers[sid]=worker;self.statuses[sid]='ready'
            return sid
        if task['agent']=='codex':
            models=await self.runtime.models('codex')
            default=next((m for m in models if m.get('is_default')),None)
            if not default:
                raise ValueError('Codex 未提供可用默认模型')
            sid=await self.runtime.create('codex',task['cwd'],
                model=task.get('selected_model') or default['id'],effort=task.get('selected_effort') or default.get('default_effort',''),
                sandbox=effective_sandbox())
            meta=self.runtime.h.managed()[sid]
            meta.update(task_id=task['id'],workspace_copy=task.get('workspace_copy'),original_cwd=task['cwd'])
            self.runtime.h.save_managed(sid,meta)
            return sid
        sid=task['agent']+':com-'+uuid.uuid4().hex
        from claude_worker import third_party_config
        model='deepseek-v4.1-flash' if task['agent']=='pi' else third_party_config(self.runtime.state)[1]
        meta={'sid':sid,'native_id':sid.split(':',1)[1],'agent':task['agent'],'cwd':task['cwd'],
              'created':time.time(),'source':'Com 后台任务','sandbox':task['sandbox'],
              'transport':'com-pi-rpc' if task['agent']=='pi' else 'claude-agent-sdk',
              'ended':False,'tmux':'','model':model,
              'effort':'','task_id':task['id'],'workspace_copy':task.get('workspace_copy'),'automatic':task.get('automatic',True),
              'execution_scope':task.get('execution_scope')}
        self.runtime.h.save_managed(sid,meta)
        with self.runtime.h.db() as db:
            db.execute('INSERT OR IGNORE INTO sessions VALUES(?,?,?,?,?,?,?,?,?)',
                       (sid,task['agent'],meta['native_id'],'',task['cwd'],task.get('title','工作会话'),time.time(),'','真实 RPC 事件'))
        def emit(event):
            self.runtime.emit(sid,event)
        if task['agent']=='pi':
            worker=PiRPC(self.runtime.state,meta['native_id'],task['cwd'],emit=emit,
                         isolated=False,readonly=False)
            worker.bind({'task_id':task['id'],'origin_session_id':task.get('origin_session_id'),
                         'origin_message_id':task.get('origin_message_id'),'origin_request_id':task.get('origin_request_id')})
            try:
                await worker.start()
            except Exception as error:
                failure=startup_failure(error,'native_startup',sid)
                meta.update(ended=True,startup_failure=failure.details)
                self.runtime.h.save_managed(sid,meta)
                raise failure from None
        else:
            worker=ClaudeWorker(self.runtime.state,task,emit,self.budget,lambda tool,args:self.guard(task,tool,args))
        self.workers[sid]=worker
        self.statuses[sid]='ready'
        return sid

    async def restore(self,sid):
        if sid in self.workers:
            return sid
        meta=self.runtime.h.managed().get(sid)
        if meta and meta.get('transport')=='hermes-runs' and not meta.get('ended'):
            from hermes_runtime import HermesRuntime
            worker=HermesRuntime(self.runtime.state,meta['native_id'],emit=lambda e:self.runtime.emit(sid,e))
            import sqlite3
            with sqlite3.connect(worker.path) as db:
                row=db.execute('SELECT request_id,run_id,status FROM runs WHERE session_id=? ORDER BY rowid DESC LIMIT 1',(worker.session_id,)).fetchone()
            self.workers[sid]=worker;self.statuses[sid]='unknown' if row else 'ready'
            if row and row[1]:
                worker.run_id=row[1]
                worker.delivered.add(row[0])
                meta['restored_turn_id']=row[0];self.runtime.h.save_managed(sid,meta)
            return sid
        if not meta or meta.get('transport')!='claude-agent-sdk' or meta.get('ended'):
            raise ValueError('缺少 Com 自有原生会话映射，暂不能恢复；请在工作页新建会话并引用原记录')
        task=next((t for t in getattr(self.runtime,'task_store',object()).list() if t['id']==meta['task_id']),None) if hasattr(self.runtime,'task_store') else None
        task=task or {'id':meta['task_id'],'agent':'claude','cwd':meta.get('original_cwd') or meta['cwd'],'sandbox':effective_sandbox(),
                      'workspace_copy':meta.get('workspace_copy'),'automatic':meta.get('automatic',False)}
        task={**task,'sandbox':effective_sandbox(),'workspace_copy':None}
        worker=ClaudeWorker(self.runtime.state,task,lambda event:self.runtime.emit(sid,event),self.budget,
                            lambda tool,args:self.guard(task,tool,args))
        if not worker.native_session:
            raise ValueError('没有已保存的原生会话映射；不自动重放旧指令')
        self.workers[sid]=worker;self.statuses[sid]='ready'
        return sid

    async def input(self,sid,text,request_id):
        worker=self.workers.get(sid)
        if not worker:
            raise ValueError('工作器重启后状态 uncertain，不自动续跑')
        if self.statuses.get(sid)=='running':
            raise ValueError('工作器正在运行，使用补充指令入口')
        meta=self.runtime.h.managed().get(sid,{})
        if meta.get('execution_scope') in ('business-read','business-query'):text=business_read_prompt(text)
        if isinstance(worker,ClaudeWorker):
            return await worker.start(text,request_id)
        self.statuses[sid]='running'
        accepted=asyncio.get_running_loop().create_future()
        async def consume():
            terminal='unknown'
            rejection=None
            async for event,payload in worker.stream(text,request_id):
                if event=='input.accepted' and not accepted.done():accepted.set_result(True)
                if event=='error' and not accepted.done():
                    if (payload.get('native_rejection') is True and payload.get('uncertain') is False and
                            payload.get('delivery')=='not_sent' and payload.get('native_started') is False):
                        rejection=WorkerInputRejected(payload.get('reason_code'),sid)
                        accepted.set_exception(rejection)
                    else:accepted.set_exception(RuntimeError('Pi prompt 接收结果未知'))
                if event=='run.completed':
                    terminal='completed'
                elif event=='error':
                    # Aborted is a observed terminal condition, not transport ACK.
                    if rejection:terminal='failed'
                    else:
                        events=self.runtime.events(sid)
                        stopped=any(e.get('data',{}).get('message',{}).get('stopReason')=='aborted' for e in events if e.get('turn_id')==request_id)
                        terminal='interrupted' if stopped else 'unknown'
            if rejection:
                await worker.stop()
                meta=self.runtime.h.managed().get(sid,{})
                meta.update(ended=True,input_rejection=rejection.details)
                self.runtime.h.save_managed(sid,meta)
            self.statuses[sid]=terminal
            self.runtime.emit(sid,{'kind':'status','status':terminal,'turn_id':request_id})
        self.runners[sid]=asyncio.create_task(consume())
        await asyncio.wait_for(accepted,25)
        return request_id

    async def status(self,sid):
        worker=self.workers.get(sid)
        if not worker:
            return 'unknown'
        if getattr(worker,'runtime_name','')=='hermes' and worker.run_id:
            try:
                await worker.reconcile_steering()
                run=await worker.request('GET','/v1/runs/'+worker.run_id)
                status=run.get('status','unknown')
                status={'cancelled':'interrupted','queued':'running','interrupted':'interrupted'}.get(status,status)
                if status in ('completed','failed','interrupted') and self.statuses[sid] not in ('completed','failed','interrupted'):
                    meta=self.runtime.h.managed().get(sid,{})
                    turn=meta.get('restored_turn_id')
                    if turn:
                        self.runtime.emit(sid,{'type':'message_end','turn_id':turn,'data':{'message':{'role':'assistant','stopReason':'stop' if status=='completed' else 'aborted' if status=='interrupted' else 'error','content':[{'type':'text','text':run.get('output','')}]}}})
                self.statuses[sid]=status
            except Exception:self.statuses[sid]='unknown'
        return worker.status if isinstance(worker,ClaudeWorker) else self.statuses[sid]

    async def stop(self,sid):
        worker=self.workers.get(sid)
        if not worker:
            raise ValueError('工作器不可用')
        await worker.abort()

    async def close(self):
        for worker in self.workers.values():
            await worker.stop()
        for runner in self.runners.values():
            runner.cancel()
