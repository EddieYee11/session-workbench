"""Present recorded work without turning an agent's answer into acceptance proof."""
import json
from datetime import datetime
from zoneinfo import ZoneInfo


ACTIVE = {'queued', 'dispatching', 'running', 'waiting', 'cancel_requested', 'approval_required', 'paused'}
UNCERTAIN = {'unknown', 'uncertain'}
LABELS = {
    'queued': '等待执行', 'dispatching': '正在启动', 'running': '正在执行',
    'waiting': '等待补充', 'paused': '启动前暂停', 'cancel_requested': '正在停止',
    'execution_finished': '执行结束，待验收', 'unknown': '执行状态待核实',
    'uncertain': '执行状态待核实', 'failed': '执行失败', 'cancelled': '已取消',
    'approval_required': '等待批准', 'rejected': '未执行', 'expired': '未执行',
}


def task_kind(task):
    """Read-time classification: no database rewrite or second source of truth."""
    return 'chat' if (task.get('authorization') or {}).get('entry') == 'work_page_human_chat' else 'job'


def accepted(task):
    if task.get('status') != 'execution_finished' or task.get('verification_status') != 'passed':
        return False
    review = task.get('quality_review') or {}
    if review.get('verdict') in {'revise', 'unknown'}:
        return False
    # A copied writing task is not delivered until that exact run was merged.
    copy = task.get('workspace_copy') or task.get('work_copy') or task.get('copy')
    return not (copy and (not task.get('run_id') or task.get('merged_run_id') != task['run_id']))


def card_task(task):
    status = task['status']
    label = '验收通过' if accepted(task) else LABELS.get(status, status)
    if not accepted(task) and task.get('verification_status') == 'passed':
        label = '验收通过 · 待合入'
    review = task.get('quality_review') or {}
    if not accepted(task) and review.get('verdict') in {'revise', 'unknown'}:
        label = '验收需补齐' if review['verdict'] == 'revise' else '评审待核实'
    inputs = task.get('inputs', [])[-10:]
    return {
        'id': task['id'], 'kind': task_kind(task), 'title': task['title'], 'status': status,
        'verification_status': task.get('verification_status', 'pending'),
        'acceptance_passed': accepted(task),
        'stage': label, 'session_id': task.get('session_id', ''),
        'revision': task.get('context_revision', task.get('task_revision', 1)),
        'completion_condition': task.get('completion_condition', ''),
        'constraints': task.get('constraints', []), 'inputs': inputs, 'quality_review': review,
        'latest_step': next((e['text'] for e in reversed(task.get('events', []))
                             if e.get('text')), '')[:500],
    }


def event_rows(task):
    rows = []
    for event in task.get('events', [])[-40:]:
        kind = event['kind']
        text = event.get('text', '')
        if kind.startswith('tool.'):
            try:
                payload = json.loads(text)
                text = f"{payload.get('tool') or '工具'}：" + {
                    'tool.started': '开始调用', 'tool.completed': '调用结束',
                    'tool.failed': '调用失败',
                }.get(kind, kind)
            except (ValueError, TypeError):
                pass
        elif not text:
            text = LABELS.get(kind, kind)
        rows.append({'id': f"{task['id']}:{event['seq']}", 'kind': kind,
                     'text': str(text)[:1000], 'at': event['at']})
    return rows


def linked_card(tasks):
    tasks = [t for t in tasks if task_kind(t) != 'chat']
    return {'linked_tasks': [card_task(t) for t in tasks],
            'work_events': [e for t in tasks for e in event_rows(t)][-80:],
            'results': [{k: t.get(k) for k in ('id', 'title', 'status', 'verification_status',
                        'result', 'artifacts', 'structured_result', 'quality_review', 'created_at', 'updated_at',
                        'run_id', 'merged_run_id', 'sandbox', 'workspace_copy', 'work_copy', 'copy')}
                        for t in tasks]}


def summarize(message, tool_tasks, card):
    linked = card.get('results', [])
    if not tool_tasks and not linked:
        return None
    if message['status'] in {'queued', 'sending', 'running', 'delegated'} or any(t['status'] in ACTIVE for t in linked):
        return None
    if (message['status'] in UNCERTAIN or any(t['status'] in UNCERTAIN for t in linked)
            or any(t.get('status') in UNCERTAIN | {'running'} for t in tool_tasks)):
        status = 'unknown'
    elif any(t['status'] == 'failed' for t in linked) or any(t.get('status') == 'failed' for t in tool_tasks):
        status = 'partial' if any(t.get('status') == 'done' for t in tool_tasks) else 'failed'
    elif message['status'] == 'failed':
        status = 'failed'
    elif linked and all(t['status'] == 'cancelled' for t in linked):
        status = 'cancelled'
    elif linked and all(accepted(t) for t in linked):
        status = 'done'
    else:
        status = 'execution_finished'
    finished = max([message['updated_at']] + [t.get('updated_at') or 0 for t in linked])
    steps = [{**t, 'duration_ms': t.get('duration_ms', 0),
              'tool': t.get('tool', ''), 'detail': t.get('detail', '')} for t in tool_tasks]
    steps += [{'id': t['id'], 'title': t['title'],
               'status': 'done' if accepted(t) else t['status'], 'duration_ms': 0,
               'tool': '', 'detail': LABELS.get(t['status'], t['status'])} for t in linked]
    artifacts = []
    for task in linked:
        for item in task.get('artifacts') or (task.get('structured_result') or {}).get('artifacts', []):
            value = item.get('path') or item.get('reference') if isinstance(item, dict) else item
            if value and str(value) not in artifacts:
                artifacts.append(str(value))
    outcomes = [str(t.get('result'))[-3000:] for t in linked if t.get('result')]
    for task in linked:
        review = task.get('quality_review') or {}
        if review.get('reason'):
            outcomes.append('验收评审：' + review['reason'])
        outcomes.extend('证据缺口：' + str(g.get('missing_evidence', ''))
                        for g in review.get('evidence_gaps', []))
    return {
        'task_id': linked[0]['id'] if len(linked) == 1 else '',
        'title': linked[0]['title'] if len(linked) == 1 else '本条交办的执行记录',
        'status': status, 'verification_status': 'passed' if status == 'done' else 'pending' if linked else 'unverified',
        'duration_ms': max(0, int((finished - message['created_at']) * 1000)),
        'finished_at': datetime.fromtimestamp(finished, ZoneInfo('Asia/Shanghai')).strftime('%m-%d %H:%M'),
        'steps': steps, 'outcomes': outcomes,
        'files': artifacts,
    }


def project_work(message):
    card = json.loads(message.pop('work_card', None) or '{}')
    tools = message['tasks']
    # Plain conversation phases are not a work assignment awaiting acceptance.
    if not any(t.get('kind') == 'tool' or str(t.get('id', '')).startswith('tool-') for t in tools):
        tools = []
    message['linked_tasks'] = card.get('linked_tasks', [])
    message['tasks'] = tools + message['linked_tasks']
    message['work_events'] = [
        {'id': t['id'], 'kind': t.get('kind', 'tool'), 'text': t['title'],
         'at': t.get('started_at', message['created_at']), 'status': t.get('status')}
        for t in tools
    ] + card.get('work_events', [])
    message['summary'] = summarize(message, tools, card) if message['role'] == 'user' else None
    return message
