"""Model-facing constrained input schema, independent of credentials and transport."""
from pathlib import Path
import re
from operation_policy import full_access_enabled,effective_sandbox,POLICY_REVISION


def authorized_assignment(conversation, proposals, data):
    """Validate a direct human assignment, not a model-supplied permission flag.

    A model may delegate only actual requested work, never a greeting, wish or quotation.
    All agents execute with full access. Irreversible deletion still needs an exact
    approval proposal; source validity and action intent remain separate from permissions.
    """
    from policy import source, assignment, deletion_risk,readonly_restriction,RESTRICTION_ONLY
    row = source(conversation, data)
    if row.get('continuation_unresolved'):
        raise ValueError('这句补充尚未关联真实原交办；请引用具体任务')
    origin = row['id']
    quote = proposals._text(data.get('source_quote'), 'source_quote', 2000)
    if quote not in row['text']:
        raise ValueError('Task authorization quote must be copied exactly from the user message')
    if row.get('supplement'):
        parent_text=(row.get('source_links') or [{}])[0].get('text','')
        clauses=re.split(r'[,，。；;\n]',row['raw_text'])
        def actual_clause(clause):
            clause=clause.strip()
            if re.match(r'^(?:请|帮我|给我|先)?\s*(?:不要|别|禁止|不许|不改|不修改)',clause):return False
            if not readonly_restriction(clause) and not RESTRICTION_ONLY.match(clause):return True
            return bool(re.search(r'检查|查看|查询|读取|统计|查找|处理|排查|诊断',clause))
        current_action=' '.join(clause for clause in clauses if actual_clause(clause))
        if not assignment(parent_text,parent_text) and not assignment(current_action,current_action):
            raise ValueError('This message is not an explicit assignment; keep it as a candidate')
    if not assignment(row['text'], quote) and not (row.get('authorization_parent_message_id') and quote in row['raw_text'] and assignment(row['text'],row['text'])):
        raise ValueError('This message is not an explicit assignment; keep it as a candidate')
    effective_quote=row['text'] if row.get('authorization_parent_message_id') else quote
    action_quote=re.sub(r'(?:不要|禁止|别|不许).{0,5}(?:永久删除|清空|销毁|抹掉|删除|删掉)', '', effective_quote)
    if deletion_risk(data.get('action', 'task'), data.get('action_args', {})) or re.search(r'永久删除|清空|销毁|抹掉|删除|删掉', action_quote):
        raise ValueError('This action requires a concrete approval proposal')
    agent, requested = data.get('agent'), data.get('sandbox')
    if agent not in ('pi','codex','claude'):
        raise ValueError('Automatic tasks support pi or codex, and claude')
    sandbox=effective_sandbox(requested)
    request_id = proposals._text(data.get('request_id'), 'request_id', 120)
    if len(request_id) < 10:
        raise ValueError('Invalid task request ID')
    cwd = proposals._cwd(data.get('relative_cwd'))
    task = {
        'agent':agent, 'cwd':cwd, 'title':proposals._text(data.get('title'),'title',120),
        'prompt':proposals._text(data.get('prompt'),'prompt',6000), 'sandbox':sandbox,
        'requested_sandbox':requested,'operation_policy_revision':POLICY_REVISION,
        'origin_session_id':data['origin_session_id'], 'origin_message_id':origin,
        'origin_request_id':row['request_id'], 'owner_conversation_id':'personal-main',
        'completion_condition':proposals._text(data.get('completion_condition'),'completion_condition',1000),
    }
    authorization = {'request_id':request_id, 'cwd':cwd, 'sandbox':sandbox,
                     'source_message_id':origin, 'source_request_id':row['request_id'], 'source_quote':quote,
                     'scope':'原始明确交办范围；不扩展权限，不做严重不可逆删除；执行前按真实动作及可恢复性检查'}
    task['source_links']=row.get('source_links',[])
    task['source_message_ids']=[link['message_id'] for link in task['source_links']]
    task['context_revision']=1
    task['latest_user_message_id']=origin
    authorization['source_links']=task['source_links']
    task['work_brief']={'goal':task['title'],'completion_condition':task['completion_condition'],
                        'authorized_cwd':cwd,'sandbox':sandbox,'source_links':task['source_links'],
                        'latest_instruction':row['raw_text'],'constraints':[],'context_revision':1}
    criteria=data.get('acceptance_criteria') or []
    if not isinstance(criteria,list) or len(criteria)>8:
        raise ValueError('Invalid acceptance criteria')
    if criteria:
        cleaned=[]
        for item in criteria:
            if not isinstance(item,dict):raise ValueError('Invalid acceptance criterion')
            ident=proposals._text(item.get('id'),'criterion id',80)
            description=proposals._text(item.get('description'),'criterion description',1000)
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*',ident) or any(c['id']==ident for c in cleaned):
                raise ValueError('Acceptance criterion IDs must be distinct')
            cleaned.append({'id':ident,'description':description})
        task['acceptance_criteria']=cleaned
    if row.get('authorization_parent_message_id'):
        authorization['parent_message_id']=row['authorization_parent_message_id']
        authorization['resolved_instruction']=row['text']
        quote=row['text']
    # Worker receives the original clause and completion boundary, not only the model's paraphrase.
    task['prompt'] = ('用户明确交办原文：\n'+quote+'\n\n任务说明：\n'+task['prompt']+
                      '\n\n完成条件：\n'+task['completion_condition']+'\n\n授权范围：\n'+authorization['scope'])
    return task, authorization, request_id


def record_constraint(store, task_id, text, request_id, constraint_type='note',source_context=None):
    tasks = {t['id']:t for t in store.list()}
    if task_id not in tasks:
        raise ValueError('Unknown task ID; ask the user which task')
    task = tasks[task_id]
    if constraint_type == 'read_only':
        instruction = '只读约束：不要修改、删除、发布或外发任何内容。'
        policy = 'restriction'
    elif constraint_type == 'preserve_style':
        instruction = '保持现有界面样式、布局、颜色、图标和动效；只处理原任务已授权的功能，不改视觉设计。'
        policy = 'restriction'
    elif constraint_type == 'forbid_path':
        if not isinstance(text,str) or not text.strip() or len(text)>300 or any(c in text for c in '\n\r\x00'):
            raise ValueError('Invalid restricted path')
        raw = Path(text)
        path = (Path(task['cwd']) / raw).resolve()
        if raw.is_absolute() or not path.is_relative_to(Path(task['cwd']).resolve()):
            raise ValueError('Restricted path must be inside the authorized project')
        # Serialize data to prevent path contents becoming model instruction syntax.
        import json
        instruction = '禁止访问或修改以下项目内路径：' + json.dumps(str(path),ensure_ascii=False)
        policy = 'restriction'
    elif constraint_type == 'note':
        instruction, policy = text, 'unreviewed'
    else:
        raise ValueError('Unsupported constraint type')
    command = store.enqueue(task_id,instruction,request_id,source='mcp',policy=policy,source_context=source_context)
    if constraint_type=='read_only' and full_access_enabled(task):
        store.transition_input(request_id,('pending_start','queued'),'revoked','用户已撤销 Com 的全部只读限制；只保留审计，不投递执行')
        command={**command,'state':'revoked'}
    return {'task_id':task_id,'request_id':request_id,'delivery':command['state'],
            'work_started':False}
