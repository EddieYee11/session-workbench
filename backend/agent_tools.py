"""Single model-facing service for Pi HTTP extension and Hermes MCP aliases."""
import hashlib
import json
import sqlite3
import shutil
import os
import re
import time
from pathlib import Path

from policy import assignment, deletion_risk, source, READ_ACTIONS,recoverable_remove,CONTINUATION,readonly_shell,readonly_restriction,action_is_readonly,bookkeeping_details
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

    def task_target(self,ident,row,strict=False):
        tasks=self.store.list()
        task=next((t for t in tasks if t['id']==ident),None)
        if not task or task.get('owner_conversation_id','personal-main')!='personal-main':
            raise ValueError('任务不属于当前负责人')
        active=[t for t in tasks if t['status'] in ('queued','paused','running','waiting','unknown','dispatching','cancel_requested')]
        reference=json.loads(row['reference']) if row.get('reference') else {}
        reference_session=reference.get('source_session_id') or reference.get('session_id')
        ids={row['id'],*[link['message_id'] for link in row.get('source_links',[])]}
        if reference_session=='personal-main':
            ids.add(reference.get('id'))
            with self.conversation.db() as db:
                parent=db.execute('SELECT parent_id FROM messages WHERE id=?',(reference.get('id'),)).fetchone()
                if parent:ids.add(parent[0])
        def linked(t):
            return (t.get('origin_message_id') in ids or bool(set(t.get('source_message_ids',[]))&ids) or
                    bool(reference_session and reference_session==t.get('session_id')) or
                    str(reference.get('id','')).startswith('task-result:'+t['id']))
        def named(t):
            title=t.get('title','')
            return t['id'] in row['raw_text'] or bool(title and title in row['raw_text'] and
                    (len(title)>=2 or re.search(r'(?<![A-Za-z0-9])'+re.escape(title)+r'(?![A-Za-z0-9])',row['raw_text'])))
        candidates=[t for t in tasks if linked(t) or named(t)]
        exact=bool(named(task) or (reference_session and reference_session==task.get('session_id')) or
                   str(reference.get('id','')).startswith('task-result:'+task['id']))
        if (candidates and not any(t['id']==ident for t in candidates)) or (len(candidates)>1 and not exact):
            raise ValueError('有多个事项或引用指向其他任务，无法唯一定位；请关联具体任务')
        if not linked(task) and not named(task) and (strict or len(active)!=1 or active[0]['id']!=ident):
            raise ValueError('用户消息未关联该任务；请引用原交办、结果卡片或明确任务名称')
        return task

    async def call(self, name, args, context):
        if name not in ('loaded','tool_result','authorize_tool'):
            self.check_glasses_scope(name,args,context)
        aliases={'create_task':'task_submit','get_task_status':'task_status','cancel_task':'task_cancel',
                 'update_task_constraints':'task_send'}
        name=aliases.get(name,name)
        if name=='business_call':
            from business_tools import BusinessTools
            service=getattr(self,'business',None)
            if service is None:self.business=service=BusinessTools(self.path.parent,self.authorize_tool)
            return await service.call(args['tool'],args.get('args',{}),context)
        if name=='loaded':
            for tool in args.get('tools',[]):
                self.capabilities.observe(tool,state='loaded')
            return {'status':'loaded'}
        if name=='memory_recall':
            from memory import recall
            return await recall(args.get('query', ''), args.get('banks'))
        if name=='memory_save':
            row=source(self.conversation,context)
            quote=args.get('source_quote','')
            if not quote or quote not in row['raw_text']:raise ValueError('Memory quote must come from the user message')
            from memory_catalog import MemoryCatalog
            return MemoryCatalog().save(args['content'],args['category'],{'message_id':row['id'],'request_id':row['request_id'],'quote':quote},args.get('memory_id',''),args.get('kind','fact'),args.get('expected_version'))
        if name=='briefing_refresh':
            return await self.personal_hub.sync(args.get('group','all'),force=args.get('force',False))
        if name=='personal_briefing':
            return self.personal_hub.briefing()
        if name=='briefing_annotate':
            return self.personal_hub.annotate(args['matter_id'],args['source_version'],args['what'],args['why'],args['next_step'])
        if name=='matter_link':
            return self.personal_hub.link(args['root_id'],args['related_ids'],args['reason'])
        if name=='matter_unlink':return self.personal_hub.unlink(args['matter_id'])
        if name=='personal_observation':
            observation=await self.heartbeat.tick(reason='hermes_cron')
            self.inspector.wake()
            return {'observation':observation,'notifications_review_scheduled':True}
        if name=='personal_action_undo':
            return await self.autonomy.undo(args['operation_id'],args['request_id'])
        if name=='personal_autonomy':
            return await self.autonomy.call(args['tool'],args['args'],args['reason'],args['request_id'])
        if name=='device_call':
            row=source(self.conversation,context)
            if args['tool'].endswith('.delete'):raise ValueError('具体删除需要现有 exact-action 审批')
            ident='device_'+hashlib.sha256((row['request_id']+json.dumps(args,sort_keys=True)).encode()).hexdigest()[:32]
            return await self.device_nodes.call(args['node_id'],args['tool'],args.get('args',{}),ident,args.get('timeout',30))
        if name=='calendar_read':
            from calendar_bridge import CalendarBridge
            return {'items':await CalendarBridge().read(args['start_date'],args['end_date']),'source':'Apple Calendar'}
        if name=='calendar_adjust':
            source(self.conversation,context)
            from calendar_bridge import CalendarBridge
            from business_tools import BusinessTools
            service=BusinessTools(self.path.parent)
            service.execute=lambda tool,params:CalendarBridge().adjust(params['event'],params['start'],params['end'])
            return await service.call('calendar_event',{'action':'adjust',**args},context)
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
        if name=='artifact_register':
            artifact=self.artifact_access.register(row['id'],args['path'])
            self.conversation.attach_artifact(row['id'],artifact)
            return artifact
        if name=='bookkeeping_search':
            self.authorize_tool({'tool':'bookkeeping_search','args':{**args,'action':'search'}},context)
            from bookkeeping_search import search
            return await search(args,self.path.parent)
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
            if row.get('continuation') and any(set(t.get('source_message_ids',[]) or [t.get('origin_message_id')]) &
                    set(draft['source_message_ids']) and t['status'] in ('queued','paused','dispatching','running','waiting','unknown','cancel_requested','execution_finished','cancelled','failed')
                    for t in self.store.list()):
                raise ValueError('原事项已有任务；用 task_send/task_resume 或验收原 task_id，不重复派发')
            node_id=args.get('plan_node_id','')
            dependencies=args.get('depends_on') or []
            if not isinstance(node_id,str) or (node_id and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}',node_id)):
                raise ValueError('Invalid plan node ID')
            if not isinstance(dependencies,list) or len(dependencies)>12 or any(not isinstance(t,str) for t in dependencies) or len(set(dependencies))!=len(dependencies):
                raise ValueError('Invalid task dependencies')
            if (node_id or dependencies) and not goal_id:raise ValueError('计划节点和依赖必须属于同一目标')
            if dependencies and not node_id:raise ValueError('依赖需要明确 plan_node_id')
            if goal_id:
                goal=next((g for g in self.goals.list() if g['id']==goal_id),None)
                if not goal or goal['authorization']['origin_message_id'] not in draft['source_message_ids']:
                    raise ValueError('目标没有该用户交办的授权关联')
                if goal['status']!='active':raise ValueError('目标没有活动下一步，不创建新任务')
                expected_id='task_'+hashlib.sha256(request_id.encode()).hexdigest()[:24]
                if not node_id and any(t['id'] in goal['task_ids'] and t['id']!=expected_id and
                       (t['status'] in ('queued','dispatching','running','waiting','unknown','cancel_requested') or
                        (t['status']=='execution_finished' and (t.get('verification_status')!='passed' or
                         (t.get('workspace_copy') and t.get('merged_run_id')!=t.get('run_id')))))
                       for t in self.store.list()):
                    raise ValueError('目标已有正在执行或待验收的任务；先查询原任务')
                draft['goal_id']=goal_id
                if node_id:
                    draft.update(plan_node_id=node_id,depends_on=dependencies)
                    tasks={t['id']:t for t in self.store.list()}
                    if any(ident not in tasks or tasks[ident].get('goal_id')!=goal_id or ident==expected_id for ident in dependencies):
                        raise ValueError('依赖必须引用同一目标已有任务，不能自依赖或越过目标')
            task=self.store.create_authorized(draft,authorization,request_id)
            if goal_id:
                self.goals.link(goal_id,task['id'],node_id,dependencies)
            return {'task_id':task['id'],'status':task['status'],'work_started':False,'owner_conversation_id':'personal-main'}
        if name=='task_verify':
            task=self.task_target(args['task_id'],row,strict=True)
            if (task.get('authorization') or {}).get('entry')=='work_page_human_chat':raise ValueError('工作页自然聊天不走 Judge 或任务验收')
            if not task.get('authorization'):raise ValueError('原任务没有持久授权快照')
            if re.search(r'(?:不要|别|禁止).{0,8}验收',row['raw_text']):raise ValueError('用户要求暂不验收')
            if task.get('verification_status')=='passed':return task
            checks_fingerprint=hashlib.sha256(json.dumps(args.get('checks'),sort_keys=True,ensure_ascii=False).encode()).hexdigest()
            from verification import verify
            evidence=await verify(task,args.get('checks'),self.path.parent)
            current=next(t for t in self.store.list() if t['id']==task['id'])
            signature=lambda item:(item.get('run_id'),item.get('context_revision'),item['status'])
            if signature(current)!=signature(task):
                return self.store.change(task['id'],'verification-stale:'+task['id']+':'+str(time.time_ns()),
                        'verification.stale','验收期间结果或要求发生变化，需按最新版本重新检查',
                        verification_status='pending')[0]
            if args.get('quality_review') is True or len(task.get('acceptance_criteria',[]))>=2:
                from quality_judge import review
                reviews=task.get('quality_reviews',[])
                attempts=[r for r in reviews if r.get('run_id')==task.get('run_id')]
                if len(attempts)>=2:
                    return {**task,'verification_status':'pending','quality_review':attempts[-1]['review'],
                            'review_limit_reached':True}
                outcome=await review(task,evidence,self.path.parent)
                current=next(t for t in self.store.list() if t['id']==task['id'])
                stale=signature(current)!=signature(task)
                reviews=current.get('quality_reviews',[])
                reviews.append({'run_id':task.get('run_id'),'context_revision':task.get('context_revision'),
                                'attempt':len(attempts)+1,'review':outcome,'stale':stale})
                if stale:
                    return self.store.change(task['id'],'quality-stale:'+task['id']+':'+str(time.time_ns()),
                            'quality.stale','评审期间结果或要求发生变化，旧评审不构成验收通过',
                            quality_reviews=reviews,verification_status='pending')[0]
                task=self.store.change(task['id'],'quality:'+task['id']+':'+str(task.get('run_id'))+':'+str(len(attempts)+1),
                        'quality.reviewed',json.dumps(outcome,ensure_ascii=False),quality_reviews=reviews,
                        quality_review=outcome,verification_status='pending',
                        structured_result={**task.get('structured_result',{}),'evidence':evidence,'quality_review':outcome})[0]
                if outcome.get('verdict')!='pass':return task
            result=self.store.verify(task['id'],evidence)
            return self.store.change(task['id'],'checks:'+task['id']+':'+str(task.get('run_id'))+':'+checks_fingerprint[:16],
                                     'verification.checks','记录验收检查范围',verification_checks_fingerprint=checks_fingerprint)[0]
        if name=='task_merge':
            task=self.task_target(args['task_id'],row,strict=True)
            if not task.get('authorization') or not task.get('workspace_copy'):
                raise ValueError('原交办没有项目写入和副本合入范围')
            if re.search(r'(?:不要|别|禁止).{0,8}合入',row['raw_text']):
                raise ValueError('用户当前约束禁止合入项目')
            if task.get('merged_run_id')==task.get('run_id') and task.get('merge_result'):return task['merge_result']
            async with self.controller.runtime.action_lock:
                result=await self.controller.runtime.workers.copies.merge(task)
                self.store.change(task['id'],'merged:'+task['id']+':'+str(task.get('run_id')),'workspace.merged',json.dumps(result),merge_result=result,merged_run_id=task.get('run_id'))
            return result
        if name=='task_send':
            target=self.task_target(args['task_id'],dict(row))
            continuation=bool(CONTINUATION.fullmatch(row['raw_text']) and target.get('authorization'))
            if not assignment(row['text'],row['text']) and not continuation and not any(w in row['text'] for w in ('不要','保持','限制')):
                raise ValueError('这不是对任务的明确补充')
            if args.get('constraint_type','note')=='note' and args.get('text') in row['raw_text'] and (assignment(row['text'],row['text']) or continuation):
                task=next((t for t in self.store.list() if t['id']==args['task_id']),None)
                if not task or task.get('owner_conversation_id','personal-main')!='personal-main' or not task.get('authorization'):
                    raise ValueError('原任务没有同一负责人的授权关联')
                command=self.store.enqueue(task['id'],row['raw_text'],args['request_id'],source='user',policy='explicit',source_context=row)
                return {'task_id':task['id'],'request_id':args['request_id'],'delivery':command['state']}
            return record_constraint(self.store,args['task_id'],args.get('text',''),args['request_id'],args.get('constraint_type','note'),source_context=row)
        if name=='task_resume':
            self.task_target(args['task_id'],row)
            if not CONTINUATION.fullmatch(row['raw_text']) and not re.search(r'继续|恢复|接着做',row['raw_text']):
                raise ValueError('用户没有要求恢复这个任务')
            if any(w in row['raw_text'] for w in ('不要继续','别继续','不要恢复','别恢复')):
                raise ValueError('用户没有要求恢复这个任务')
            async with self.controller.runtime.action_lock:
                return await self.controller.resume(args['task_id'],args['request_id'])
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
                if not tasks or any(t.get('verification_status')!='passed' or
                        (t.get('workspace_copy') and (not t.get('run_id') or t.get('merged_run_id')!=t.get('run_id'))) for t in tasks):
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
        glasses=self.check_glasses_scope(tool,params,context)
        task_id=context.get('task_id')
        task=next((t for t in self.store.list() if t['id']==task_id),None) if task_id else None
        if task_id:
            if not task or not task.get('authorization') or task['status'] not in ('dispatching','running','waiting'):
                raise ValueError('工作器没有活动授权')
            actual=source(self.conversation,context)
            if actual['id'] not in (task.get('source_message_ids') or [task['authorization'].get('source_message_id')]):
                raise ValueError('工作器来源与任务真实用户消息不匹配')
            actual_sources=task.get('source_links') or task.get('authorization',{}).get('source_links',[])
            bookkeeping_source='\n'.join(link['text'] for link in actual_sources) if actual_sources else task.get('authorization',{}).get('source_quote','')
            source_request_id=task.get('authorization',{}).get('source_request_id') or task.get('origin_request_id')
            with self.conversation.db() as db:
                voice=db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='voice_requests'").fetchone()
                purpose=db.execute('SELECT purpose FROM voice_requests WHERE request_id=?',(source_request_id,)).fetchone() if voice else None
            expense=bool(purpose and purpose[0]=='expense')
        else:
            row=source(self.conversation,context)
            with self.conversation.db() as db:
                voice=db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='voice_requests'").fetchone()
                purpose=db.execute('SELECT purpose FROM voice_requests WHERE request_id=?',(row['request_id'],)).fetchone() if voice else None
            expense=bool(purpose and purpose[0]=='expense')
            bookkeeping_source=row.get('bookkeeping_source') or '\n'.join(link['text'] for link in row.get('source_links',[])) or row['raw_text']
            readonly=action_is_readonly(tool,params)
            from policy import quote_free,QUOTE
            if not readonly and (row.get('continuation_unresolved') or
                    (re.fullmatch(r'\s*[A-Ca-c](?:[、.：:\s]+.*)?\s*',row['raw_text'],re.S) and not row.get('authorization_parent_message_id')) or
                    not quote_free(row['raw_text']).strip() or
                    (QUOTE.search(row['raw_text']) and not assignment(quote_free(row['raw_text']),quote_free(row['raw_text'])))):
                raise ValueError('这条续答或引用没有关联真实用户操作来源')
            if tool=='remind' and params.get('action')=='add' and not re.search(r'提醒我|叫我|定提醒|设.{0,8}提醒|新增|添加|提醒一下|到期.{0,15}提醒',row['text']):
                raise ValueError('没有明确新增提醒意图')
        if tool=='bookkeeping' and params.get('action')=='add':
            clarification = row.get('bookkeeping_clarification') if not task_id else None
            if clarification:
                if params.get('amount') != clarification['amount']:
                    raise ValueError('请使用用户本次确认的金额')
                with sqlite3.connect(self.path) as db:
                    prior_effects = db.execute('SELECT data FROM effects').fetchall()
                if any(json.loads(effect[0]).get('origin_request_id') == clarification['parent_request_id']
                       for effect in prior_effects):
                    raise ValueError('原事项已有执行记录，先回查，禁止重复写入')
            permitted,error=bookkeeping_details(bookkeeping_source,params.get('amount'),expense_entry=expense)
            if not permitted:raise ValueError(error)
        path=params.get('path') or params.get('file_path')
        if tool=='read' and path and any(v in str(Path(path).expanduser()) for v in ('/.pi/agent/auth.json','/.session-workbench/token','/.claude/.credentials','/.hermes/.env')):
            raise ValueError('运行时凭据由工具内部读取，不进入模型上下文')
        if deletion_risk(tool,params):
            # Editing a copied project is recoverable; native shared paths never pass this exception.
            copy=task.get('workspace_copy') if task else None
            path=params.get('path') or params.get('file_path')
            approved=task.get('authorization',{}).get('actual_action') if task else None
            exact=approved and approved.get('tool')==tool and approved.get('args')==params
            recovered = tool.lower() in ('write','edit') and self.backup_main_write(path, context,task.get('cwd') if task else None)
            if not exact and not recovered and not recoverable_remove(tool,params,copy) and not (copy and tool in ('write','edit','Write','Edit') and path and
                    (Path(copy)/path).resolve().is_relative_to(Path(copy).resolve())):
                raise ValueError('实际动作有不可逆删除/覆盖风险，请提交具体批准；未执行')
        mutating=not action_is_readonly(tool,params)
        if mutating:
            ident=context.get('origin_request_id') or (task.get('origin_request_id') if task else None)
            cwd=task.get('cwd') if task else str(self.proposals.workspace)
            key=hashlib.sha256(json.dumps([task_id,ident,cwd,tool,params],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
            with sqlite3.connect(self.path) as db:
                db.execute('BEGIN IMMEDIATE')
                prior=db.execute('SELECT state FROM effects WHERE key=?',(key,)).fetchone()
                if prior:
                    raise ValueError('此操作已有执行记录或结果待核实，先回查，禁止重复写入')
                db.execute('INSERT INTO effects VALUES (?,?,?,?)',(key,args.get('tool_call_id'),'uncertain',json.dumps({**context,**({'rayneo_expense':True} if glasses and tool=='bookkeeping' and params.get('action')=='add' else {}),**({'rayneo_creation':tool} if glasses and tool in ('remind','calendar_event') and params.get('action') in ('add','create') else {})})))
        return {'authorized':True}

    def check_glasses_scope(self, tool, params, context):
        # Verify persisted source, never a model-controlled context label.
        with self.conversation.db() as db:
            table=db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='rayneo_requests'").fetchone()
            registered=db.execute('SELECT 1 FROM rayneo_requests WHERE request_id=?',(context.get('origin_request_id'),)).fetchone() if table else None
        if registered:
            from rayneo import glasses_tool_policy
            glasses_tool_policy(tool,params)
        return bool(registered)

    def backup_main_write(self, path, context,root=None):
        """Permit ordinary native edits only with a durable recovery record."""
        if not path: return False
        root = Path(root or self.proposals.workspace).resolve()
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
