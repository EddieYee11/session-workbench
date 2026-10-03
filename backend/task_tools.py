"""Model-facing constrained input schema, independent of credentials and transport."""
from pathlib import Path
import re


def authorized_assignment(conversation, proposals, data):
    """Validate a direct human assignment, not a model-supplied permission flag.

    Verifies the quote really came from a real user message in this session; that part is
    anti-hallucination, not permission. Permission-wise the only standing gate is
    irreversible deletion, which must go through a concrete approval proposal. Everything
    else the user explicitly asked for is authorized as stated (Eddie's decision, 2026-10-02).
    """
    from policy import source, assignment, deletion_risk
    row = source(conversation, data)
    origin = row['id']
    quote = proposals._text(data.get('source_quote'), 'source_quote', 2000)
    if quote not in row['text']:
        raise ValueError('Task authorization quote must be copied exactly from the user message')
    if not assignment(row['text'], quote) and not (row.get('authorization_parent_message_id') and quote in row['raw_text'] and assignment(row['text'],row['text'])):
        raise ValueError('This message is not an explicit assignment; keep it as a candidate')
    effective_quote=row['text'] if row.get('authorization_parent_message_id') else quote
    action_quote=re.sub(r'(?:不要|禁止|别|不许).{0,5}(?:永久删除|清空|销毁|抹掉|删除|删掉)', '', effective_quote)
    if deletion_risk(data.get('action', 'task'), data.get('action_args', {})) or re.search(r'永久删除|清空|销毁|抹掉|删除|删掉', action_quote):
        raise ValueError('This action requires a concrete approval proposal')
    agent, sandbox = data.get('agent'), data.get('sandbox')
    if agent == 'pi':
        if sandbox != 'danger-full-access':
            raise ValueError('Pi runs full-access; pass sandbox="danger-full-access"')
    elif agent in ('codex', 'claude'):
        if sandbox not in ('read-only','workspace-write'):
            raise ValueError('Codex tasks must be read-only or workspace-write')
        if sandbox == 'workspace-write' and not re.search(r'修复|修好|修改|优化|实现|添加|增加|编写|改|做好', effective_quote):
            raise ValueError('The user message did not authorize code changes; use read-only')
    else:
        raise ValueError('Automatic tasks support pi or codex, and claude')
    request_id = proposals._text(data.get('request_id'), 'request_id', 120)
    if len(request_id) < 10:
        raise ValueError('Invalid task request ID')
    cwd = proposals._cwd(data.get('relative_cwd'))
    task = {
        'agent':agent, 'cwd':cwd, 'title':proposals._text(data.get('title'),'title',120),
        'prompt':proposals._text(data.get('prompt'),'prompt',6000), 'sandbox':sandbox,
        'origin_session_id':data['origin_session_id'], 'origin_message_id':origin,
        'origin_request_id':row['request_id'], 'owner_conversation_id':'personal-main',
        'completion_condition':proposals._text(data.get('completion_condition'),'completion_condition',1000),
    }
    authorization = {'request_id':request_id, 'cwd':cwd, 'sandbox':sandbox,
                     'source_message_id':origin, 'source_request_id':row['request_id'], 'source_quote':quote,
                     'scope':'原始明确交办范围；不扩展权限，不做严重不可逆删除；执行前按真实动作及可恢复性检查'}
    if row.get('authorization_parent_message_id'):
        authorization['parent_message_id']=row['authorization_parent_message_id']
        authorization['resolved_instruction']=row['text']
        quote=row['text']
    # Worker receives the original clause and completion boundary, not only the model's paraphrase.
    task['prompt'] = ('用户明确交办原文：\n'+quote+'\n\n任务说明：\n'+task['prompt']+
                      '\n\n完成条件：\n'+task['completion_condition']+'\n\n授权范围：\n'+authorization['scope'])
    return task, authorization, request_id


def record_constraint(store, task_id, text, request_id, constraint_type='note'):
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
    command = store.enqueue(task_id,instruction,request_id,source='mcp',policy=policy)
    return {'task_id':task_id,'request_id':request_id,'delivery':command['state'],
            'work_started':False}
