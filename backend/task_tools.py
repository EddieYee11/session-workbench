"""Model-facing constrained input schema, independent of credentials and transport."""
from pathlib import Path


def record_constraint(store, task_id, text, request_id, constraint_type='note'):
    tasks = {t['id']:t for t in store.list()}
    if task_id not in tasks:
        raise ValueError('Unknown task ID; ask the user which task')
    task = tasks[task_id]
    if constraint_type == 'read_only':
        instruction = '只读约束：不要修改、删除、发布或外发任何内容。'
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
