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


class WorkerRuntime:
    def __init__(self,runtime):
        self.runtime=runtime
        self.workers={}
        self.runners={}
        self.statuses={}
        self.budget=ClaudeBudget(runtime.state)
        self.copies=WorkspaceCopies(runtime.state)

    def guard(self,task,tool,args):
        readonly=task['sandbox']=='read-only'
        kind=tool.lower()
        path=args.get('file_path') or args.get('path')
        root=Path(task.get('workspace_copy',task['cwd'])).resolve()
        if path and not (root/path).resolve().is_relative_to(root):
            raise ValueError('工具路径超出任务目录')
        if kind in ('write','edit','multiedit'):
            if readonly or not task.get('workspace_copy'):
                raise ValueError('修改必须在已授权的独立副本中')
        elif deletion_risk(kind,args):
            approved=task.get('authorization',{}).get('actual_action') or {}
            exact=approved.get('tool','').lower()==kind and approved.get('args')==args
            if not exact and not recoverable_remove(kind,args,task.get('workspace_copy')):
                raise ValueError('不可逆/未归类破坏动作需具体批准')
        if kind=='bash':
            if readonly:
                raise ValueError('只读任务不能执行任意命令')
            command=args.get('command','')
            # Native Claude sandbox enforces filesystem writes; also block attempts to disable it.
            if args.get('dangerouslyDisableSandbox') or any(v in command for v in ('cd ..','sudo ','/Users/','launchctl ','osascript ','ssh ','scp ')):
                raise ValueError('命令越过独立副本或主机写边界')

    async def create(self,task):
        task=dict(task)
        from execution_boundary import require_host
        require_host(self.runtime.state)
        if task['agent']=='claude' and any(w.status=='running' for w in self.workers.values() if isinstance(w,ClaudeWorker)):
            raise ValueError('Claude 并发上限一项')
        if task['sandbox']!='read-only':
            task['workspace_copy']=await asyncio.to_thread(self.copies.prepare,task)
            store=getattr(self.runtime,'task_store',None)
            if store and any(t['id']==task['id'] for t in store.list()):
                store.change(task['id'],'copy:'+task['id'],'workspace.isolated',
                             '含当前未提交修改的独立副本',workspace_copy=task['workspace_copy'])
        if task['agent']=='codex':
            models=await self.runtime.models('codex')
            default=next((m for m in models if m.get('is_default')),None)
            if not default:
                raise ValueError('Codex 未提供可用默认模型')
            sid=await self.runtime.create('codex',task.get('workspace_copy',task['cwd']),
                model=task.get('selected_model') or default['id'],effort=task.get('selected_effort') or default.get('default_effort',''),
                sandbox='read-only' if task['sandbox']=='read-only' else 'workspace-write')
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
              'effort':'','task_id':task['id'],'workspace_copy':task.get('workspace_copy'),'automatic':task.get('automatic',True)}
        self.runtime.h.save_managed(sid,meta)
        with self.runtime.h.db() as db:
            db.execute('INSERT OR IGNORE INTO sessions VALUES(?,?,?,?,?,?,?,?,?)',
                       (sid,task['agent'],meta['native_id'],'',task['cwd'],task.get('title','工作会话'),time.time(),'','真实 RPC 事件'))
        def emit(event):
            self.runtime.emit(sid,event)
        if task['agent']=='pi':
            worker=PiRPC(self.runtime.state,meta['native_id'],task.get('workspace_copy',task['cwd']),emit=emit,
                         isolated=True,readonly=task['sandbox']=='read-only')
            worker.bind({'task_id':task['id'],'origin_session_id':task.get('origin_session_id'),
                         'origin_message_id':task.get('origin_message_id'),'origin_request_id':task.get('origin_request_id')})
            await worker.start()
        else:
            worker=ClaudeWorker(self.runtime.state,task,emit,self.budget,lambda tool,args:self.guard(task,tool,args))
        self.workers[sid]=worker
        self.statuses[sid]='ready'
        return sid

    async def restore(self,sid):
        if sid in self.workers:
            return sid
        meta=self.runtime.h.managed().get(sid)
        if not meta or meta.get('transport')!='claude-agent-sdk' or meta.get('ended'):
            raise ValueError('只有 Com 自有 Claude 会话可恢复；旧原生历史保持只读')
        task=next((t for t in getattr(self.runtime,'task_store',object()).list() if t['id']==meta['task_id']),None) if hasattr(self.runtime,'task_store') else None
        task=task or {'id':meta['task_id'],'agent':'claude','cwd':meta['cwd'],'sandbox':meta['sandbox'],
                      'workspace_copy':meta.get('workspace_copy'),'automatic':meta.get('automatic',False)}
        if not task.get('workspace_copy'):task.pop('workspace_copy',None)
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
        if isinstance(worker,ClaudeWorker):
            return await worker.start(text,request_id)
        self.statuses[sid]='running'
        accepted=asyncio.get_running_loop().create_future()
        async def consume():
            terminal='unknown'
            async for event,payload in worker.stream(text,request_id):
                if event=='input.accepted' and not accepted.done():accepted.set_result(True)
                if event=='error' and not accepted.done():accepted.set_exception(RuntimeError('Pi prompt 接收结果未知'))
                if event=='run.completed':
                    terminal='completed'
                elif event=='error':
                    # Aborted is a observed terminal condition, not transport ACK.
                    events=self.runtime.events(sid)
                    stopped=any(e.get('data',{}).get('message',{}).get('stopReason')=='aborted' for e in events if e.get('turn_id')==request_id)
                    terminal='interrupted' if stopped else 'unknown'
            self.statuses[sid]=terminal
            self.runtime.emit(sid,{'kind':'status','status':terminal,'turn_id':request_id})
        self.runners[sid]=asyncio.create_task(consume())
        await asyncio.wait_for(accepted,25)
        return request_id

    async def status(self,sid):
        worker=self.workers.get(sid)
        if not worker:
            return 'unknown'
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
