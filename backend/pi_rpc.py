"""Com-owned Pi RPC supervisor. Native ACK never means execution or delivery."""
import asyncio
import contextlib
import json
import os
import re
import time
import uuid
from pathlib import Path


def assistant_text(message):
    content = message.get('content', [])
    if isinstance(content, str):
        return content
    return '\n'.join(b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text')


class PiRPC:
    def __init__(self, state, name, cwd, *, argv=None, emit=None, env=None, tools=True,isolated=False,readonly=False):
        self.root = Path(state) / 'pi-rpc' / name
        self.root.mkdir(parents=True, exist_ok=True)
        self.root.chmod(0o700)
        self.cwd = str(cwd)
        self.name = name
        self.argv = argv
        self.emit = emit or (lambda event: None)
        self.env = dict(os.environ if env is None else env)
        self.env.pop('PI_GATEWAY_LANE', None)
        self.env['PATH'] = os.pathsep.join(dict.fromkeys([str(Path.home()/'bin'), '/usr/local/bin', '/opt/homebrew/bin', *self.env.get('PATH',os.defpath).split(os.pathsep)]))
        self.env.update(COM_PI_CONTEXT=str(self.root / 'context.json'),
                        COM_STATE=str(state), TZ='Asia/Shanghai', PI_OFFLINE='1')
        self.tools = tools
        self.isolated,self.readonly=isolated,readonly
        self.state=Path(state)
        self.proc = None
        self.pending = {}
        self.queue = None
        self.spawn_lock = asyncio.Lock()
        self.turn_lock = asyncio.Lock()
        self.reader = None
        self.stderr_reader = None
        self.failures = 0
        self.busy = False
        self.run_id = None
        self.failure = None
        self.delivered = set()
        self.session = None
        self.events = self.root / 'events.jsonl'
        saved = self.root / 'session.json'
        if saved.exists():
            self.session = json.loads(saved.read_text()).get('sessionFile')
        self.context = {}

    @property
    def alive(self):
        return self.proc is not None and self.proc.returncode is None

    def record(self, event):
        event = {**event, 'time': time.time(), 'turn_id': self.run_id}
        with self.events.open('a') as f:
            f.write(json.dumps(event, ensure_ascii=False) + '\n')
        self.emit(event)

    def bind(self, context):
        self.context = context
        target = self.root / 'context.json'
        temp = target.with_suffix('.tmp')
        temp.write_text(json.dumps(context, ensure_ascii=False))
        temp.chmod(0o600)
        temp.replace(target)

    def command(self):
        if self.argv:
            return self.argv
        args = [self.env.get('WORKBENCH_PI', '/usr/local/bin/pi'), '--mode', 'rpc',
                '--provider', 'opencode-go', '--model', 'deepseek-v4.1-flash',
                '--session-dir', str(self.root / 'sessions'), '--no-context-files', '--no-extensions',
                '--extension', str(Path(__file__).with_name('com-pi.ts'))]
        if self.name == 'main':
            from pi_main import MAIN_PROMPT
            args += ['--system-prompt',MAIN_PROMPT]
        settings = Path.home() / '.pi/agent/settings.json'
        if self.tools and settings.exists():
            cfg = json.loads(settings.read_text())
            # Reuse native capabilities, never the gateway's lane or its session.
            excluded = {'lane-tools', 'model-fallback', 'cost-ledger', 'bash-guard'}
            for source in cfg.get('extensions', []):
                if Path(source).stem not in excluded:
                    args += ['--extension', source]
        if not self.tools:
            args += ['--no-builtin-tools', '--no-skills']
        if self.session and Path(self.session).is_file():
            args += ['--session', self.session]
        return args

    async def start(self):
        async with self.spawn_lock:
            if self.alive and not self.failure:
                return
            if self.alive:
                await self.stop()
            if self.failures:
                await asyncio.sleep(min(2 ** self.failures, 30))
            self.failure = None
            command=self.command()
            if self.isolated:
                from execution_boundary import sandbox
                command=sandbox(command,self.state,self.cwd,self.readonly)
            self.proc = await asyncio.create_subprocess_exec(
                *command, cwd=self.cwd, env=self.env,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, limit=32 * 1024 * 1024)
            proc = self.proc
            self.reader = asyncio.create_task(self.read_events(proc))
            self.stderr_reader = asyncio.create_task(self.drain_stderr(proc))
            try:
                response = await self.request({'type': 'get_state'}, 20)
                data = response.get('data', {})
                if data.get('sessionFile'):
                    self.session = data['sessionFile']
                    (self.root / 'session.json').write_text(json.dumps({'sessionFile': self.session}))
                self.failures = 0
            except Exception:
                self.failures += 1
                await self.stop()
                raise

    async def drain_stderr(self, proc):
        # No raw stderr persisted: native plugins may include credentials in errors.
        while await proc.stderr.readline():
            pass

    async def request(self, command, timeout=20):
        if not self.alive:
            raise RuntimeError('Pi RPC 不可用')
        rid = command.setdefault('id', uuid.uuid4().hex)
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        try:
            self.proc.stdin.write((json.dumps(command, ensure_ascii=False) + '\n').encode())
            await self.proc.stdin.drain()
            return await asyncio.wait_for(future, timeout)
        finally:
            self.pending.pop(rid, None)

    async def read_events(self, proc):
        try:
            while raw := await proc.stdout.readline():
                try:
                    event = json.loads(raw)
                except ValueError:
                    continue
                typ = event.get('type')
                if typ == 'response':
                    future = self.pending.get(event.get('id'))
                    if future and not future.done():
                        if event.get('success', True):
                            future.set_result(event)
                        else:
                            future.set_exception(ValueError('Pi RPC 拒绝 ' + str(event.get('command', 'command'))))
                    continue
                if typ == 'extension_ui_request':
                    # RPC has no human UI; confirmations fail closed, notifications get no reply.
                    if event.get('method') in ('confirm', 'select', 'input'):
                        self.proc.stdin.write((json.dumps({'type':'extension_ui_response','id':event.get('id'),'cancelled':True})+'\n').encode())
                        await self.proc.stdin.drain()
                    continue
                if typ == 'message_start' and event.get('message', {}).get('role') == 'user':
                    text = assistant_text(event['message'])
                    marker = '[Com input:'
                    if marker in text:
                        for ident in re.findall(r'\[Com input:([^\]]+)\]',text):
                            self.delivered.add(ident)
                            self.record({'kind': 'input.delivered', 'request_id': ident})
                saved=event
                if typ=='message_update':
                    msg=event.get('message',{})
                    delta=event.get('assistantMessageEvent',{})
                    saved={'type':typ,'message':{k:msg.get(k) for k in ('role','timestamp')},
                           'assistantMessageEvent':{k:delta.get(k) for k in ('type','delta','contentIndex')}}
                self.record({'type': typ, 'data': saved})
                if self.queue is not None:
                    await self.queue.put(event)
                # agent_end may precede queued follow-ups; only settled closes a turn.
                if typ == 'agent_settled':
                    self.busy = False
        except asyncio.CancelledError:
            return
        finally:
            if self.proc is proc:
                self.failure = 'Pi RPC 连接中断；执行结果 uncertain，不重放'
                self.failures += 1
                self.busy = False
                for future in list(self.pending.values()):
                    if not future.done():
                        future.set_exception(RuntimeError(self.failure))
                if self.queue is not None:
                    await self.queue.put({'type': 'com_disconnected'})

    async def stream(self, text, request_id=None):
        async with self.turn_lock:
            await self.start()
            self.run_id = request_id or uuid.uuid4().hex
            self.queue = asyncio.Queue()
            self.busy = True
            try:
                yield 'run.started', {'run_id': self.run_id}
                await self.request({'type': 'prompt', 'message': f'[Com input:{self.run_id}]\n{text}'})
                yield 'input.accepted', {'request_id':self.run_id}
                final = ''
                error = False
                deadline = time.monotonic() + 1200
                while True:
                    event = await asyncio.wait_for(self.queue.get(), max(.01, deadline - time.monotonic()))
                    typ = event.get('type')
                    if typ == 'message_update':
                        delta = event.get('assistantMessageEvent', {})
                        if delta.get('type') == 'text_delta':
                            yield 'assistant.delta', {'delta': delta.get('delta', '')}
                    elif typ == 'message_end' and event.get('message', {}).get('role') == 'assistant':
                        msg = event['message']
                        error = msg.get('stopReason') in ('error', 'aborted')
                        content = assistant_text(msg)
                        if content:
                            final = content
                            yield 'assistant.completed', {'content': content}
                    elif typ in ('tool_execution_start', 'tool_execution_end'):
                        yield ('tool.started' if typ.endswith('start') else 'tool.failed' if event.get('isError') else 'tool.completed'), {
                            'tool_name': event.get('toolName'), 'tool_call_id': event.get('toolCallId'),
                            'args': event.get('args'), 'result': event.get('result')}
                    elif typ == 'com_disconnected':
                        yield 'error', {'uncertain': True}
                        break
                    elif typ == 'agent_settled':
                        yield ('error' if error else 'run.completed'), {'run_id': self.run_id, 'uncertain': error}
                        break
                yield 'done', {}
            except (asyncio.TimeoutError, RuntimeError, ValueError):
                with contextlib.suppress(Exception):
                    await self.abort()
                yield 'error', {'uncertain': True}
                yield 'done', {}
            finally:
                self.queue = None

    async def steer(self, text, request_id):
        if not self.alive or not self.busy:
            raise ValueError('Pi 没有活动 turn')
        await self.request({'type': 'steer', 'message': f'[Com input:{request_id}]\n{text}'})
        return {'state': 'delivered' if request_id in self.delivered else 'worker_queued'}

    async def abort(self):
        await self.request({'type': 'abort'})

    async def stop(self):
        proc, self.proc = self.proc, None
        if proc and proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), 5)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
        for task in (self.reader, self.stderr_reader):
            if task and task is not asyncio.current_task():
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
        self.busy = False
