"""Model-facing constrained input schema, independent of credentials and transport."""
from pathlib import Path
import re


def authorized_assignment(conversation, proposals, data):
    """Validate a direct human assignment, not a model-supplied permission flag.

    This is a narrow first release: isolated Codex readers or scoped code edits.
    Full-access Pi and consequential actions continue through explicit proposal approval.
    """
    origin = data.get('origin_message_id')
    with conversation.db() as db:
        row = db.execute("SELECT * FROM messages WHERE id=? AND role='user'", (origin,)).fetchone()
    if not row or row['request_id'] != data.get('origin_request_id'):
        raise ValueError('Task must reference a real user message and its request ID')
    if data.get('origin_session_id') != conversation._session_id():
        raise ValueError('Task must originate in the current main conversation')
    quote = proposals._text(data.get('source_quote'), 'source_quote', 2000)
    if len(quote) < 4 or quote not in row['text']:
        raise ValueError('Task authorization quote must be copied exactly from the user message')
    directive = re.sub(r'^(?:(?:对了|另外|顺便)[，,\s]*|先|再)+', '', quote)
    if not re.match(r'^(?:请|帮我|给我|替我|把|检查|排查|诊断|修复|修好|修改|优化|实现|添加|增加|编写|整理)', directive):
        raise ValueError('This message is not an explicit assignment; keep it in the main conversation')
    if re.search(r'删除|清空|外发|发消息|发给|发布|购买|付款|支付|转账|部署|凭据|密钥|认证配置', quote):
        raise ValueError('This action requires a concrete approval proposal')
    agent, sandbox = data.get('agent'), data.get('sandbox')
    if agent != 'codex' or sandbox not in ('read-only','workspace-write'):
        raise ValueError('Automatic tasks support scoped Codex only; propose full-access Pi for approval')
    if sandbox == 'workspace-write' and not re.search(r'修复|修好|修改|优化|实现|添加|增加|编写|改|做好', quote):
        raise ValueError('The user message did not authorize code changes; use read-only')
    request_id = proposals._text(data.get('request_id'), 'request_id', 120)
    if len(request_id) < 10:
        raise ValueError('Invalid task request ID')
    cwd = proposals._cwd(data.get('relative_cwd'))
    task = {
        'agent':agent, 'cwd':cwd, 'title':proposals._text(data.get('title'),'title',120),
        'prompt':proposals._text(data.get('prompt'),'prompt',6000), 'sandbox':sandbox,
        'origin_session_id':data['origin_session_id'], 'origin_message_id':origin,
        'origin_request_id':row['request_id'],
        'completion_condition':proposals._text(data.get('completion_condition'),'completion_condition',1000),
    }
    authorization = {'request_id':request_id, 'cwd':cwd, 'sandbox':sandbox,
                     'source_message_id':origin, 'source_request_id':row['request_id'], 'source_quote':quote,
                     'scope':'原始明确交办范围；不扩展权限，不删除、发布、外发或修改认证配置'}
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
