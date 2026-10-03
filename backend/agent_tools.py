"""Single model-facing service for Pi HTTP extension and Hermes MCP aliases."""
import hashlib
import json
import sqlite3
import shutil
import os
import re
from pathlib import Path

from policy import assignment, deletion_risk, source, READ_ACTIONS,recoverable_remove
from task_tools import authorized_assignment, record_constraint


class AgentTools:
    def __init__(self, state, conversation, proposals, store, controller, capabilities, goals):
        self.conversation,self.proposals,self.store,self.controller=conversation,proposals,store,controller
        self.capabilities,self.goals=capabilities,goals
        self.path=Path(state)/'tool-effects.sqlite'
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE IF NOT EXISTS effects(key TEXT PRIMARY KEY,call_id TEXT,state TEXT NOT NULL,data TEXT NOT NULL)')
        self.path.chmod(0o600)
        from archives import Archives
        self.archives=Archives(state,proposals.workspace)

    def task_target(self,ident,row):
        tasks=self.store.list()
        task=next((t for t in tasks if t['id']==ident),None)
        if not task or task.get('owner_conversation_id','personal-main')!='personal-main':
            raise ValueError('任务不属于当前负责人')
        active=[t for t in tasks if t['status'] in ('queued','running','waiting','unknown','dispatching','cancel_requested')]
        reference=json.loads(row['reference']) if row.get('reference') else {}
        linked=task.get('origin_message_id')==row['id'] or reference.get('session_id')==task.get('session_id')
        named=task['id'] in row['text'] or task.get('title','\0') in row['text']
        if not linked and not named and len(active)>1:
            raise ValueError('有多个事项，无法唯一定位任务；只形成候选，请先确认对象')
        return task

    async def call(self, name, args, context):
        aliases={'create_task':'task_submit','get_task_status':'task_status','cancel_task':'task_cancel',
                 'update_task_constraints':'task_send'}
        name=aliases.get(name,name)
        if name=='loaded':
            for tool in args.get('tools',[]):
                self.capabilities.observe(tool,state='loaded')
            return {'status':'loaded'}
        if name=='capability_search':
            return {'items':self.capabilities.search(args.get('query',''),args.get('runtime'))}
        if name=='task_status':
            tasks=self.store.list()
            if args.get('task_id'):
                tasks=[t for t in tasks if t['id']==args['task_id']]
            return {'items':tasks}
        if name=='goal_status':
            return {'items':[g for g in self.goals.list() if not args.get('goal_id') or g['id']==args['goal_id']],
                    'scheduler_enabled':self.goals.enabled()}
        if name=='tool_result':
            return self.tool_result(args,context)
        if name=='authorize_tool':
            return self.authorize_tool(args,context)
        row=source(self.conversation,context)
        if name=='react_to_user_message':
            return self.conversation.reactions.react(args['message_id'],args['reaction_token'],args['emoji'])
        if name=='archive_path':
            if not assignment(row['text'],row['text']) or '归档' not in row['text']:
                raise ValueError('没有明确归档交办')
            target=Path(args['relative_path']).name
            if target not in row['text']:
                raise ValueError('归档对象未关联真实交办，请先定位具体对象')
            return self.archives.archive(args['relative_path'],args['request_id'],row['id'])
        if name=='task_submit':
            data={**args,**{k:context.get(k) for k in ('origin_session_id','origin_message_id','origin_request_id')}}
            draft,authorization,request_id=authorized_assignment(self.conversation,self.proposals,data)
            goal_id=args.get('goal_id') or context.get('goal_id')
            if goal_id:
                goal=next((g for g in self.goals.list() if g['id']==goal_id),None)
                if not goal or goal['authorization']['origin_message_id']!=row['id']:
                    raise ValueError('目标没有该用户交办的授权关联')
                if goal['status']!='active':raise ValueError('目标没有活动下一步，不创建新任务')
                expected_id='task_'+hashlib.sha256(request_id.encode()).hexdigest()[:24]
                if any(t['id'] in goal['task_ids'] and t['id']!=expected_id and
                       (t['status'] in ('queued','dispatching','running','waiting','unknown','cancel_requested') or
                        (t['status']=='execution_finished' and (t.get('verification_status')!='passed' or
                         (t.get('workspace_copy') and t.get('merged_run_id')!=t.get('run_id')))))
                       for t in self.store.list()):
                    raise ValueError('目标已有正在执行或待验收的任务；先查询原任务')
                draft['goal_id']=goal_id
            task=self.store.create_authorized(draft,authorization,request_id)
            if goal_id:
                self.goals.link(goal_id,task['id'])
            return {'task_id':task['id'],'status':task['status'],'work_started':False,'owner_conversation_id':'personal-main'}
        if name=='task_verify':
            task=next((t for t in self.store.list() if t['id']==args['task_id']),None)
            if not task or task.get('origin_message_id')!=row['id']:
                raise ValueError('验收必须关联原交办')
            from verification import verify
            evidence=await verify(task,args.get('checks'),self.path.parent)
            return self.store.verify(task['id'],evidence)
        if name=='task_merge':
            task=next((t for t in self.store.list() if t['id']==args['task_id']),None)
            if not task or task.get('origin_message_id')!=row['id']:
                raise ValueError('合入必须关联原交办')
            if task.get('merged_run_id')==task.get('run_id') and task.get('merge_result'):return task['merge_result']
            async with self.controller.runtime.action_lock:
                result=await self.controller.runtime.workers.copies.merge(task)
                self.store.change(task['id'],'merged:'+task['id']+':'+str(task.get('run_id')),'workspace.merged',json.dumps(result),merge_result=result,merged_run_id=task.get('run_id'))
            return result
        if name=='task_send':
            self.task_target(args['task_id'],dict(row))
            if not assignment(row['text'],row['text']) and not any(w in row['text'] for w in ('不要','保持','限制')):
                raise ValueError('这不是对任务的明确补充')
            if args.get('constraint_type','note')=='note' and args.get('text') in row['text'] and assignment(row['text'],row['text']):
                task=next((t for t in self.store.list() if t['id']==args['task_id']),None)
                if not task or task.get('owner_conversation_id','personal-main')!='personal-main' or not task.get('authorization'):
                    raise ValueError('原任务没有同一负责人的授权关联')
                command=self.store.enqueue(task['id'],row['text'],args['request_id'],source='user',policy='explicit')
                return {'task_id':task['id'],'request_id':args['request_id'],'delivery':command['state']}
            return record_constraint(self.store,args['task_id'],args.get('text',''),args['request_id'],args.get('constraint_type','note'))
        if name=='task_cancel':
            self.task_target(args['task_id'],dict(row))
            if not assignment(row['text'],row['text']) or not any(w in row['text'] for w in ('停止','取消','暂停','先别管','停下')) or any(w in row['text'] for w in ('别取消','不要取消','别停止','不要停止')):
                raise ValueError('用户没有明确要求停止')
            async with self.controller.runtime.action_lock:
                return await self.controller.command(args['task_id'],'',args['request_id'],cancel=True)
        if name=='goal_update':
            goal=next((g for g in self.goals.list() if g['id']==args['goal_id']),None)
            if not goal or goal['authorization']['origin_message_id']!=row['id']:
                raise ValueError('目标授权来源不匹配')
            if args['status']=='completed':
                tasks=[t for t in self.store.list() if t['id'] in goal['task_ids']]
                if not tasks or any(t.get('verification_status')!='passed' for t in tasks):
                    raise ValueError('目标任务未验收，先设 waiting_acceptance')
            return self.goals.update(goal['id'],args['status'],args.get('next_step',''),args.get('evidence'))
        if name=='goal_upsert':
            if not assignment(row['text'],args.get('source_quote')):
                raise ValueError('目标需要真实明确交办；愿望仅作为候选')
            authorization={**context,'source_quote':args['source_quote'],'scope':row['text']}
            return self.goals.upsert(args,authorization)
        if name=='propose_work':
            if not assignment(row['text'],row['text']):
                raise ValueError('没有可审批的明确交办')
            card=self.proposals.propose(agent=args['agent'],relative_cwd=args['relative_cwd'],title=args['title'],
                 prompt=args['prompt'],sandbox=args['sandbox'],reason='不可逆动作需具体批准',
                 origin_session_id=context['origin_session_id'],origin_message_id=row['id'],
                 origin_request_id=row['request_id'],idempotency_key=args['request_id'],actual_action=args.get('actual_action'))
            self.store.ensure(card)
            return card
        raise ValueError('Unknown agent tool')

    def authorize_tool(self,args,context):
        tool=args['tool'];params=args.get('args') or {}
        task_id=context.get('task_id')
        task=next((t for t in self.store.list() if t['id']==task_id),None) if task_id else None
        if task_id:
            if not task or not task.get('authorization') or task['status'] not in ('dispatching','running','waiting'):
                raise ValueError('工作器没有活动授权')
        else:
            row=source(self.conversation,context)
            with self.conversation.db() as db:
                voice=db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='voice_requests'").fetchone()
                purpose=db.execute('SELECT purpose FROM voice_requests WHERE request_id=?',(row['request_id'],)).fetchone() if voice else None
            expense=bool(purpose and purpose[0]=='expense')
            readonly=params.get('action','') in READ_ACTIONS or tool in ('read','grep','find','ls')
            query=bool(re.search(r'查|看|多少|几笔|有哪些|什么提醒|什么日程',row['text']))
            if not assignment(row['text'],row['text']) and not (expense and tool=='bookkeeping') and not (readonly and query):
                raise ValueError('这条消息只形成候选，不授权工具操作')
            if tool=='bookkeeping' and params.get('action')=='add':
                if not expense and not re.search(r'^记账|(?:帮我|请|给我|把).{0,6}记账|记一|记下|记录|花了|到账',row['text']):
                    raise ValueError('没有明确记账意图；查询不授权添加')
                amount=params.get('amount')
                numbers=re.findall(r'\d+(?:\.\d+)?',row['text'])
                if not isinstance(amount,(int,float)) or not any(abs(float(n)-float(amount))<.001 for n in numbers):
                    raise ValueError('金额不在真实用户消息中，先补齐金额')
            if tool=='remind' and params.get('action')=='add' and not re.search(r'提醒我|叫我|定提醒|设.{0,8}提醒|新增|添加|提醒一下|到期.{0,15}提醒',row['text']):
                raise ValueError('没有明确新增提醒意图')
        path=params.get('path') or params.get('file_path')
        if tool=='read' and path and any(v in str(Path(path).expanduser()) for v in ('/.pi/agent/auth.json','/.session-workbench/token','/.claude/.credentials','/.hermes/.env')):
            raise ValueError('运行时凭据由工具内部读取，不进入模型上下文')
        if deletion_risk(tool,params):
            # Editing a copied project is recoverable; native shared paths never pass this exception.
            copy=task.get('workspace_copy') if task else None
            path=params.get('path') or params.get('file_path')
            approved=task.get('authorization',{}).get('actual_action') if task else None
            exact=approved and approved.get('tool')==tool and approved.get('args')==params
            recovered = not task and tool in ('write','edit') and self.backup_main_write(path, context)
            if not exact and not recovered and not recoverable_remove(tool,params,copy) and not (copy and tool in ('write','edit','Write','Edit') and path and
                    (Path(copy)/path).resolve().is_relative_to(Path(copy).resolve())):
                raise ValueError('实际动作有不可逆删除/覆盖风险，请提交具体批准；未执行')
        if tool in ('bash','powershell'):
            if task and task['sandbox']=='read-only':
                raise ValueError('只读任务不允许任意 shell；使用 read/grep/find/ls')
        if task and task['sandbox']=='read-only' and params.get('action','read') not in READ_ACTIONS:
            raise ValueError('只读任务不能执行写动作')
        mutating=params.get('action','') not in READ_ACTIONS and tool not in ('read','grep','find','ls')
        if mutating:
            ident=context.get('origin_request_id',task_id)
            key=hashlib.sha256(json.dumps([ident,tool,params],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
            with sqlite3.connect(self.path) as db:
                prior=db.execute('SELECT state FROM effects WHERE key=?',(key,)).fetchone()
                if prior:
                    raise ValueError('此操作已有执行记录或结果待核实，先回查，禁止重复写入')
                db.execute('INSERT INTO effects VALUES (?,?,?,?)',(key,args.get('tool_call_id'),'uncertain',json.dumps(context)))
        return {'authorized':True}

    def backup_main_write(self, path, context):
        """Permit ordinary native edits only with a durable recovery record."""
        if not path: return False
        root = Path(self.proposals.workspace).resolve()
        target = (root / Path(path).expanduser()).resolve()
        if not target.is_relative_to(root) or target == root or target.is_dir(): return False
        if any(part in ('.git', '.syncthing', '.stfolder') for part in target.relative_to(root).parts): return False
        if target.exists() and (not target.is_file() or target.stat().st_size > 16*1024*1024): return False
        recovery = self.path.parent / 'main-write-recovery'
        recovery.mkdir(mode=0o700, exist_ok=True)
        key = hashlib.sha256(json.dumps([context.get('origin_request_id'),str(target)],ensure_ascii=False).encode()).hexdigest()
        record = recovery / (key+'.json')
        if not record.exists():
            backup = recovery / (key+'.before')
            if target.exists():
                with target.open('rb') as original, backup.open('xb') as saved:
                    os.chmod(backup,0o600)
                    shutil.copyfileobj(original,saved)
                    saved.flush();os.fsync(saved.fileno())
            data={'path':str(target),'existed':target.exists(),'backup':str(backup) if target.exists() else None,
                  'origin_message_id':context.get('origin_message_id'),'origin_request_id':context.get('origin_request_id')}
            with record.open('x') as saved:
                os.chmod(record,0o600);json.dump(data,saved,ensure_ascii=False)
                saved.flush();os.fsync(saved.fileno())
        return True

    def tool_result(self,args,context):
        with sqlite3.connect(self.path) as db:
            db.execute('UPDATE effects SET state=? WHERE call_id=?',('failed' if args.get('is_error') else 'completed',args.get('tool_call_id')))
        if args.get('is_error'):
            self.capabilities.observe(args['tool'],state='unavailable',evidence={'tool_call_id':args.get('tool_call_id')})
        else:
            self.capabilities.observe(args['tool'],state='verified',evidence={'tool_call_id':args.get('tool_call_id'),'origin_request_id':context.get('origin_request_id')},fixture=bool(context.get('fixture')))
        return {'recorded':True}
