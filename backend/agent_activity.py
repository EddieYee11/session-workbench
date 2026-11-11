"""Compact presentation events derived from the durable conversation, never fake progress."""
from __future__ import annotations

import time
from event_copy import current_step


def tool_activity(tool):
    tool=str(tool or '').lower()
    for words,kind in ((('web_search','web_extract','browser'),'searching'),
                       (('memory_recall','memory_save'),'remembering'),
                       (('calendar','remind'),'calendar'),
                       (('task_submit','create_task'),'handoff'),
                       (('write_file','patch','file_write'),'writing'),
                       (('read_file','context_read','search_files'),'searching')):
        if any(word in tool for word in words):return kind
    # Pi 原生工具名是短词，按整词匹配，免得 'read' 命中 'thread' 之类。
    name=tool.split('__')[-1]
    if name in ('read','grep','find','ls','glob'):return 'searching'
    if name in ('edit','write','multiedit'):return 'writing'
    return 'working'


def _iter_message_tool_tasks(message: dict) -> list[dict]:
    raw = message.get('work_tasks') if isinstance(message.get('work_tasks'), list) else (message.get('tasks') or [])
    if not isinstance(raw, list):
        return []
    return [t for t in raw if isinstance(t, dict) and t.get('kind') == 'tool' and t.get('id')]


def _tool_duration_ms(task: dict) -> int:
    raw = task.get('duration_ms')
    if isinstance(raw, (int, float)) and not isinstance(raw, bool):
        return max(0, int(round(raw)))
    started = task.get('started_at')
    finished = task.get('finished_at')
    if isinstance(started, (int, float)) and isinstance(finished, (int, float)):
        return max(0, int(round((finished - started) * 1000)))
    return 0


class AgentEventProjector:
    def __init__(self):
        self.tasks={};self.seen={};self.seen_tools={};self.ready=False;self.last_message={}

    def _project_tool_events(self, messages: list[dict], *, is_snapshot: bool) -> list[dict]:
        emitted: list[dict] = []
        now = time.time()
        suppress = is_snapshot or not self.ready
        for message in messages:
            if not isinstance(message, dict):
                continue
            mid = str(message.get('id') or '')
            if not mid:
                continue
            msg_status = str(message.get('status') or '')
            for task in _iter_message_tool_tasks(message):
                tool_id = str(task.get('id') or '')
                status = str(task.get('status') or '')
                key = (mid, tool_id)
                prev = self.seen_tools.get(key)
                if suppress:
                    if status:
                        self.seen_tools[key] = status
                    continue
                tool_name = str(task.get('tool') or '')
                if status == 'running' and prev != 'running':
                    if prev not in ('done', 'failed'):
                        emitted.append({
                            'event': 'tool.started',
                            'data': {
                                'message_id': mid,
                                'tool_id': tool_id,
                                'call_id': task.get('call_id') or '',
                                'tool': tool_name,
                                'title': task.get('title') or '',
                                'kind': tool_activity(tool_name),
                                'status': 'running',
                                'started_at': task.get('started_at'),
                            },
                        })
                        self.seen_tools[key] = 'running'
                elif status in ('done', 'failed') and prev not in ('done', 'failed'):
                    finished_at = task.get('finished_at')
                    is_live = (
                        prev == 'running'
                        or msg_status in ('queued', 'sending', 'running', 'streaming', 'delegated')
                        or (isinstance(finished_at, (int, float)) and (now - finished_at) < 30.0)
                    )
                    if is_live:
                        emitted.append({
                            'event': 'tool.completed',
                            'data': {
                                'message_id': mid,
                                'tool_id': tool_id,
                                'call_id': task.get('call_id') or '',
                                'tool': tool_name,
                                'title': task.get('title') or '',
                                'kind': tool_activity(tool_name),
                                'status': status,
                                'started_at': task.get('started_at'),
                                'finished_at': finished_at,
                                'duration_ms': _tool_duration_ms(task),
                            },
                        })
                    self.seen_tools[key] = status
                elif status and prev is None:
                    self.seen_tools[key] = status
        if len(self.seen_tools) > 2000:
            self.seen_tools = dict(list(self.seen_tools.items())[-1000:])
        return emitted

    def project(self, frame):
        is_snapshot = frame.get('event') == 'snapshot'
        data=frame.get('data') or {};events=[]
        for task in data.get('tasks',[])+data.get('changed_tasks',[]):
            self.tasks[task['id']]=task
        active=[t for t in self.tasks.values() if t.get('status') in ('queued','running','dispatching','waiting','approval_required','awaiting_review','unknown')]
        self.tasks={t['id']:t for t in active}  # Terminal history is already in the durable source.
        runs=data.get('runs') or []
        messages=data.get('messages') or []
        for message in messages:
            if (message.get('updated_at') or message.get('created_at',0)) >= (self.last_message.get('updated_at') or self.last_message.get('created_at',0)):self.last_message=message
        review=next((r for r in runs+active if r.get('status') in ('approval_required','awaiting_review')),None)
        run=next((r for r in runs if r.get('status') in ('queued','sending','running')),None)
        task=next((t for t in active if t.get('status') in ('running','dispatching')),None)
        source=review or run or task or {}
        phase=source.get('phase','')
        kind='review' if review else tool_activity(source.get('active_tool')) if source.get('active_tool') else (
            'writing' if phase in ('responding','speaking') else 'thinking' if run else 'working' if task else 'idle')
        uncertain=next((r for r in runs if r.get('status')=='unknown' and (not self.last_message or r.get('message_id') in (self.last_message.get('id'),self.last_message.get('parent_id')))),None)
        if not source and uncertain:kind='waiting';source=uncertain
        if not source and self.last_message.get('status')=='failed':
            kind='failed';source=self.last_message
        activity={'kind':kind,'source_id':source.get('message_id') or source.get('id',''),
                  'tool':source.get('active_tool') or '', 'at':time.time()}
        # 「当前步骤」一句话（与 iOS 工作过程同一张文案表）；只在主对话真的在跑时给。
        if run and kind!='review':
            message=next((m for m in messages if m.get('id')==run.get('message_id')),None)
            if message:activity['label']=current_step(message)
        if source.get('retry_count') is not None:activity['retry_count']=source['retry_count']
        events.extend(self._project_tool_events(messages, is_snapshot=is_snapshot))
        # Receipt identity—not text similarity—prevents replay on reconnects.
        for message in messages:
            if message.get('role')!='assistant' or message.get('status')!='completed':continue
            ident=message['id']
            if self.ready and not is_snapshot and ident not in self.seen:
                events.append({'event':'agent.push','data':{'id':'message:'+ident,'message_id':ident,
                    'preview':message.get('text','')[:100],'kind':'delivered','at':time.time()}})
            self.seen[ident]=None
        self.ready=True
        if len(self.seen)>1000:self.seen=dict(list(self.seen.items())[-500:])
        events.insert(0,{'event':'task.review' if kind=='review' else 'task.progress','data':activity})
        return activity,events
