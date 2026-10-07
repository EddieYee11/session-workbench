"""Durable Hermes Runs transport shared by the main chat and Com task workers."""
import asyncio
import hashlib
import json
import sqlite3
import time
from pathlib import Path
import httpx
from conversation import HermesClient


# 这些块每轮都注入，所以按条数与字符数封顶；完整原文留在 Markdown 里按 source 回读。
MEMORY_FACT_ITEMS = 12
MEMORY_FACT_CHARS = 500
MEMORY_RECALL_ITEMS = 5
MEMORY_RECALL_CHARS = 300


def _clip(value, limit: int):
    if not isinstance(value, str):
        return value
    text = " ".join(value.split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + '…'


def slim_facts(items) -> list[dict]:
    """当前有效事实：留身份、正文和最小来源，去掉旧版本与被取代来源的全文。"""
    slim = []
    for item in (items or [])[:MEMORY_FACT_ITEMS]:
        if not isinstance(item, dict):
            continue
        entry = {key: item[key] for key in ('id', 'category', 'kind') if key in item}
        entry['content'] = _clip(item.get('content'), MEMORY_FACT_CHARS)
        source = item.get('source')
        if isinstance(source, dict):
            entry['source'] = {key: _clip(source[key], 120) for key in ('message_id', 'quote') if source.get(key)}
        elif source:
            entry['source'] = _clip(str(source), 140)
        slim.append(entry)
    return slim


def slim_memories(items) -> list[dict]:
    """召回片段：只留正文与来源路径，完整原文按 source 回读。"""
    slim = []
    for item in (items or [])[:MEMORY_RECALL_ITEMS]:
        if not isinstance(item, dict):
            continue
        entry = {}
        body = item.get('text') or item.get('content')
        if body:
            entry['text'] = _clip(body, MEMORY_RECALL_CHARS)
        source = item.get('source')
        if isinstance(source, dict):
            entry['source'] = _clip(source.get('path') or source.get('file') or json.dumps(source, ensure_ascii=False), 140)
        elif source:
            entry['source'] = _clip(str(source), 140)
        if item.get('relevance') is not None:
            entry['relevance'] = item['relevance']
        slim.append(entry)
    return slim


class HermesRuntime(HermesClient):
    runtime_name = 'hermes'
    session_key = 'hermes_v2_session_id'
    operation_mode = 'full-access'
    has_native_history = True

    def __init__(self, state, session_id='com-hermes-main', emit=None, context=None, instructions=None):
        super().__init__(Path(state))
        self.state = Path(state)
        self.session_id = session_id
        self.emit = emit or (lambda event: None)
        self.context = context or {}
        self.instructions = instructions
        self.turn_history = None
        self.turn_instructions = None
        self.turn_source = None
        self.turn_route = None
        self.run_id = ''
        self.delivered, self.failed_inputs = set(), set()
        self.path = self.state / 'hermes-runs.sqlite'
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE IF NOT EXISTS runs(request_id TEXT PRIMARY KEY,fingerprint TEXT,run_id TEXT,session_id TEXT,status TEXT)')
            db.execute('CREATE TABLE IF NOT EXISTS run_events(run_id TEXT,event_hash TEXT,event TEXT,data TEXT,PRIMARY KEY(run_id,event_hash))')
            db.execute('CREATE TABLE IF NOT EXISTS steering(request_id TEXT PRIMARY KEY,run_id TEXT,text TEXT,state TEXT)')
            db.execute('CREATE TABLE IF NOT EXISTS context_requests(request_id TEXT PRIMARY KEY,source_hash TEXT NOT NULL,body TEXT NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS context_metrics(request_id TEXT PRIMARY KEY,data TEXT NOT NULL)')
        self.path.chmod(0o600)

    async def create_session(self):
        from hermes_prompt import SYSTEM_PROMPT
        try:
            await self.request('POST', '/api/sessions', {'id': self.session_id, 'source': 'api_server', 'title': 'Com! ' + self.session_id, 'system_prompt': self.instructions or SYSTEM_PROMPT})
        except RuntimeError as e:
            if str(e) != 'hermes_api_409': raise
            await self.request('GET', '/api/sessions/' + self.session_id)
        return self.session_id

    async def start(self):
        await self.create_session()

    def bind(self, context):
        self.context = context

    async def submit_run(self, text, request_id):
        from hermes_prompt import SYSTEM_PROMPT
        await self.create_session()
        body = {'input': text, 'session_id': self.session_id, 'instructions': self.turn_instructions or self.instructions or SYSTEM_PROMPT}
        if self.turn_route and self.turn_route.get('level') == 'L1':
            body['model_options'] = {'reasoning': {'effort': 'none'}}
        if self.turn_history is not None:
            body['conversation_history'] = self.turn_history
            # Freeze the admitted working set. A retry must not acquire newer history
            # or change the idempotency fingerprint after another user message arrives.
            source_hash = hashlib.sha256((self.session_id+'\0'+(self.turn_source or text)).encode()).hexdigest()
            with sqlite3.connect(self.path) as db:
                frozen = db.execute('SELECT source_hash,body FROM context_requests WHERE request_id=?',(request_id,)).fetchone()
                if frozen:
                    if frozen[0] != source_hash: raise ValueError('Hermes request ID conflicts with original input')
                    body = json.loads(frozen[1])
                else:
                    db.execute('INSERT INTO context_requests VALUES(?,?,?)',(request_id,source_hash,json.dumps(body,ensure_ascii=False)))
        fp = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
        with sqlite3.connect(self.path) as db:
            row = db.execute('SELECT fingerprint,run_id FROM runs WHERE request_id=?', (request_id,)).fetchone()
            if row:
                if row[0] != fp: raise ValueError('Hermes request ID conflicts with original input')
                if row[1]: return row[1]
                raise RuntimeError('Hermes admission uncertain; reconcile before retrying')
            db.execute('INSERT INTO runs VALUES (?,?,?,?,?)', (request_id, fp, '', self.session_id, 'admitting'))
        async with httpx.AsyncClient(timeout=30, trust_env=False) as client:
            response = await client.post(self.base_url + '/v1/runs', json=body,
                headers={'Authorization': 'Bearer ' + self.key(), 'Idempotency-Key': request_id})
        if response.status_code >= 400:
            raise RuntimeError('hermes_admission_' + str(response.status_code))
        run_id = response.json().get('run_id')
        if not isinstance(run_id, str) or not run_id.startswith('run_'): raise RuntimeError('Hermes missing run ID')
        with sqlite3.connect(self.path) as db:
            db.execute('UPDATE runs SET run_id=?,status=? WHERE request_id=?', (run_id, 'running', request_id))
        return run_id

    async def _events(self, run_id):
        async with httpx.AsyncClient(timeout=httpx.Timeout(60, connect=10), trust_env=False) as client:
            async with client.stream('GET', self.base_url + '/v1/runs/' + run_id + '/events',
                headers={'Authorization': 'Bearer ' + self.key(), 'Accept': 'text/event-stream'}) as response:
                response.raise_for_status()
                event, lines = 'message', []
                async for line in response.aiter_lines():
                    if not line:
                        if lines:
                            payload = json.loads('\n'.join(lines))
                            with sqlite3.connect(self.path) as db:
                                raw=json.dumps(payload,sort_keys=True,ensure_ascii=False)
                                db.execute('INSERT OR IGNORE INTO run_events VALUES(?,?,?,?)',(run_id,hashlib.sha256(raw.encode()).hexdigest(),payload.get('event',event),raw))
                            yield payload.get('event', event), payload
                        event, lines = 'message', []
                    elif line.startswith('event:'): event = line[6:].strip()
                    elif line.startswith('data:'):
                        lines.append(line[5:].lstrip())
                        if sum(map(len, lines)) > 4_000_000: raise RuntimeError('Hermes event too large')

    async def stream(self, text, request_id=None, *, context=None):
        context = context or self.context
        request_id = request_id or context.get('origin_request_id')
        if not request_id: raise ValueError('A durable request ID is required')
        self.run_id = await self.submit_run(text, request_id)
        self.delivered.add(request_id)
        yield 'run.started', {'run_id': self.run_id}
        yield 'input.accepted', {'request_id': request_id}
        yield 'input.delivered', {'request_id': request_id, 'run_id': self.run_id}
        self.emit({'type': 'agent_start', 'data': {}, 'turn_id': request_id})
        execution_started = False
        try:
            async for event, data in self._events(self.run_id):
                if event.startswith('tool.'):
                    execution_started = True
                    self.emit({'type': 'tool_execution_' + ('start' if event == 'tool.started' else 'end'),
                        'data': {'toolName': data.get('tool_name', data.get('tool')), 'toolCallId': data.get('tool_call_id'),
                                 'args': data.get('args', {}), 'result': data.get('result', {}), 'isError': event == 'tool.failed'}, 'turn_id': request_id})
                    yield event, {**data, 'tool_name': data.get('tool_name', data.get('tool'))}
                elif event == 'message.delta':
                    execution_started = True
                    yield 'assistant.delta', data
                elif event in ('assistant.delta', 'assistant.completed'):
                    execution_started = True
                    yield event, data
                elif event in ('run.completed', 'run.failed', 'run.cancelled', 'error', 'done'):
                    break
        except (httpx.HTTPError, ValueError, RuntimeError):
            # SSE is a view. Poll the exact admitted run; never submit its input again.
            pass
        while True:
            await self.reconcile_steering()
            result = await self.request('GET', '/v1/runs/' + self.run_id)
            status = result.get('status')
            if status in ('completed', 'failed', 'cancelled', 'interrupted', 'unknown'): break
            await asyncio.sleep(1)
        output = result.get('output', '')
        if isinstance(output, list): output = '\n'.join(str(item.get('text', item.get('content', ''))) for item in output if isinstance(item, dict))
        output = output if isinstance(output, str) else ''
        with sqlite3.connect(self.path) as db:
            db.execute('UPDATE runs SET status=? WHERE request_id=?', (status, request_id))
        reason = 'stop' if status == 'completed' else 'aborted' if status in ('cancelled', 'interrupted') else 'error'
        self.emit({'type': 'message_end', 'turn_id': request_id, 'data': {'message': {'role': 'assistant', 'stopReason': reason,
            'content': [{'type': 'text', 'text': output}]}}})
        self.emit({'kind': 'status', 'turn_id': request_id, 'status': 'completed' if status == 'completed' else 'interrupted' if reason == 'aborted' else 'unknown'})
        if status == 'completed':
            yield 'assistant.completed', {'content': output}
            yield 'run.completed', {'run_id': self.run_id}
        else:
            # Provider resolution/authentication happens before any model/tool
            # execution. This is a confirmed failure, not an uncertain action.
            error = str(result.get('error', ''))
            # A disabled gateway route rejects the model before execution. Do not
            # treat later failures after tool/output events as safe to replay.
            with sqlite3.connect(self.path) as db:
                prior_execution = db.execute("SELECT 1 FROM run_events WHERE run_id=? AND (event LIKE 'tool.%' OR event IN ('message.delta','assistant.delta','assistant.completed')) LIMIT 1", (self.run_id,)).fetchone()
            provider_disabled = 'is switched off in Magpie' in error
            provider_quota = '429' in error and any(marker in error for marker in ('本周额度已用完', 'weekly quota', 'weekly limit'))
            provider_failed = status == 'failed' and not execution_started and not prior_execution and not output and (error.startswith('⚠️ Provider authentication failed:') or provider_disabled or provider_quota)
            yield 'error', {'run_id': self.run_id, 'status': status, 'uncertain': reason != 'aborted' and not provider_failed,
                            'failure_code': 'provider_unavailable' if provider_failed else '',
                            'provider_disabled': provider_failed and provider_disabled,
                            'provider_quota': provider_failed and provider_quota}
        yield 'done', {}

    async def stream_chat(self, session_id, text):
        self.session_id = session_id
        from context_builder import build
        from context_working_set import parse_input
        from message_router import MessageRouter
        started = time.monotonic()
        _,context=parse_input(text)
        request_id=context.get('event_id') or context.get('origin_request_id')
        working=build(self.state,text,self.instructions)
        self.turn_history=working.history
        self.turn_instructions=working.instructions
        self.turn_source=working.source
        route=MessageRouter(self.state).decide(request_id,working.user)
        from dataclasses import asdict
        self.turn_route=asdict(route)
        text=working.user
        metrics = {'version':3,'at':time.time(),'input_chars':len(text),**working.sizes,
                   'automatic_memory_calls':0,'route':route.level,'tool_group':route.group,
                   'assembly_ms':round((time.monotonic()-started)*1000,2)}
        try:
            async for event, payload in self.stream(text, request_id, context=context):
                if event in ('assistant.delta','assistant.completed') and 'first_text_ms' not in metrics:
                    if payload.get('content') or payload.get('text') or payload.get('delta'):
                        metrics['first_text_ms']=round((time.monotonic()-started)*1000,2)
                yield event, payload
        finally:
            self.turn_history = None
            self.turn_instructions = None
            self.turn_source = None
            self.turn_route = None
            metrics['elapsed_ms']=round((time.monotonic()-started)*1000,2)
            MessageRouter(self.state).complete(request_id,elapsed_ms=metrics['elapsed_ms'],first_text_ms=metrics.get('first_text_ms'),prompt_chars=metrics['input_chars']+metrics['instructions_chars']+metrics['history_chars'])
            with sqlite3.connect(self.path) as db:
                db.execute('INSERT OR REPLACE INTO context_metrics VALUES(?,?)',(request_id,json.dumps(metrics)))

    async def steer(self, text, request_id, *, context=None):
        if not self.run_id: return {'state': 'not_sent'}
        marker='[Com supplement '+request_id+']\n'
        text=marker+text
        with sqlite3.connect(self.path) as db:
            old=db.execute('SELECT run_id,text,state FROM steering WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[:2]!=(self.run_id,text):raise ValueError('Supplement ID conflicts with original input')
                return {'state':'delivered' if old[2]=='delivered' else 'worker_queued','run_id':self.run_id}
            # Reserve before admission. An interrupted POST must never replay a supplement.
            db.execute('INSERT INTO steering VALUES(?,?,?,?)',(request_id,self.run_id,text,'uncertain'))
        try:
            result = await self.request('POST', '/v1/runs/' + self.run_id + '/steer', {'input': text})
        except RuntimeError as exc:
            if str(exc) == 'hermes_api_409': return {'state': 'not_sent'}
            raise
        status = result.get('status', '')
        if status in ('not_running', 'completed'): return {'state': 'not_sent'}
        # Queue admission is not proof of model consumption.
        return {'state': 'worker_queued', 'run_id': self.run_id}

    async def reconcile_steering(self):
        with sqlite3.connect(self.path) as db:
            rows=db.execute("SELECT request_id,text FROM steering WHERE run_id=? AND state!='delivered'",(self.run_id,)).fetchall()
        if not rows:return
        try:
            messages=await self.request('GET','/api/sessions/'+self.session_id+'/messages?limit=500&order=latest')
        except Exception:return
        for request_id,text in rows:
            # Hermes persists consumed steer as a standalone user row after tool results.
            if any(m.get('role')=='user' and text in str(m.get('content','')) for m in messages.get('data',[])):
                with sqlite3.connect(self.path) as db:db.execute("UPDATE steering SET state='delivered' WHERE request_id=?",(request_id,))
                self.delivered.add(request_id)
                self.emit({'kind':'input.delivered','request_id':request_id,'turn_id':request_id,'run_id':self.run_id})

    async def steer_chat(self, session_id, text, request_id, context):
        return await self.steer(text, request_id, context=context)

    async def restore_request(self,request_id):
        with sqlite3.connect(self.path) as db:
            row=db.execute('SELECT run_id,session_id FROM runs WHERE request_id=?',(request_id,)).fetchone()
        if not row or not row[0]:return None
        self.run_id,self.session_id=row
        await self.reconcile_steering()
        return await self.request('GET','/v1/runs/'+self.run_id)

    async def abort(self):
        if self.run_id: await self.request('POST', '/v1/runs/' + self.run_id + '/stop', {})

    async def stop(self):
        # Closing a UI transport must not cancel admitted remote work.
        pass
