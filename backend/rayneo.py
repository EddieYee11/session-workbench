"""Scoped glasses ingress; durable Com requests remain the system of record."""
import asyncio
import fcntl
import hashlib
import hmac
import json
import re
import secrets
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse

TERMINAL = {'completed', 'failed', 'unknown', 'interrupted', 'cancelled', 'approval_required'}
ID = re.compile(r'rayneo-[A-Za-z0-9_-]{10,80}')


def glasses_tool_policy(tool, args):
    # Eddie explicitly granted the same Full access as the Com! main dialogue.
    # Native source verification and idempotent side effects still apply there.
    return


def final_reply(receipt):
    actions = receipt.get('action_receipts') or []
    operations = receipt.get('operation_receipts') or []
    verified = []
    if actions:
        if not all(a.get('readback_verified') for a in actions):
            return '记账结果待核实，请勿重复记账。请在 Com! 查看本次记录。'
        for action in actions:
            details = action['details']
            verified.append(f"已记 ¥{details['amount']:.2f} · {details.get('comment') or details.get('category', '')} · #{details['id']}")
    for operation in operations:
        if not operation.get('execution_verified') or (operation['tool']=='remind' and not operation.get('readback_verified')):
            return '操作结果待核实，请勿重复创建。请在 Com! 查看本次请求。'
        details=operation['details']
        if operation['tool']=='remind':
            verified.append(f"已设微信提醒 · {details['due']} · {operation['args'].get('text','')} · #{details['id']}")
        elif operation['tool']=='calendar_event':
            job=details['job']
            verified.append(f"已建日历 · {job['iso_date']} {job.get('hour',9):02d}:{job.get('minute',0):02d} · {job['summary']}")
    if verified:
        return '\n'.join(verified)
    if receipt.get('status') != 'completed':
        return '本次结果待核实，请勿重复提交。请在 Com! 查看本次请求。'
    result = (receipt.get('result') or '').strip()
    if re.search(r'已(?:经)?(?:成功)?(?:设.{0,4}提醒|定提醒|建.{0,6}日历|添加.{0,6}日历)|提醒.{0,4}已(?:设置|创建)',result):
        return '未取得提醒或日历的执行凭据，结果待核实，请勿重复创建。'
    from policy import bookkeeping_intent
    if bookkeeping_intent(receipt.get('text','')) or re.search(r'已(?:经)?(?:成功)?(?:记账|记好|记录|记下|入账|撤销|删除)|记账成功|记录成功|记好了|已.{0,8}记过', result):
        return '未取得账本写入及回读凭据，结果待核实，请勿重复记账。'
    return result[:6000] or '本次没有取得完整回答，请在 Com! 查看。'


class RayneoIngress:
    def __init__(self, state, conversation, voice, *, wait_seconds=80, poll_seconds=1):
        self.conversation, self.voice = conversation, voice
        self.wait_seconds, self.poll_seconds = wait_seconds, poll_seconds
        path = Path(state) / 'rayneo-token'
        if not path.exists():
            with path.open('x') as f:
                path.chmod(0o600)
                f.write(secrets.token_urlsafe(40))
        self.token = path.read_text().strip()
        self.state = Path(state)
        self.pair_attempts = {}
        with conversation.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS rayneo_requests(request_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, text TEXT NOT NULL, created_at REAL NOT NULL)')
        self.router = APIRouter(prefix='/rayneo/v1')
        self.router.add_api_route('/chat/completions', self.chat, methods=['POST'])
        self.router.add_api_route('/receipts/{request_id}', self.get_receipt, methods=['GET'])
        self.router.add_api_route('/health', self.health, methods=['GET'])
        self.router.add_api_route('/pair', self.pair, methods=['POST'])

    def authorized(self, header):
        return hmac.compare_digest(header, 'Bearer ' + self.token)

    def owns(self, request_id):
        with self.conversation.db() as db:
            return db.execute('SELECT 1 FROM rayneo_requests WHERE request_id=?', (request_id,)).fetchone() is not None

    def submit(self, request_id, text):
        if not isinstance(request_id, str) or not ID.fullmatch(request_id):
            raise HTTPException(422, '缺少稳定眼镜请求标识；请更新插件')
        if not isinstance(text, str) or not text.strip() or len(text) > 2000:
            raise HTTPException(422, '眼镜消息无效或过长')
        text = text.strip()
        fingerprint = hashlib.sha256(text.encode()).hexdigest()
        with self.conversation.db() as db:
            old = db.execute('SELECT fingerprint FROM rayneo_requests WHERE request_id=?', (request_id,)).fetchone()
            existing = db.execute('SELECT 1 FROM messages WHERE request_id=?', (request_id,)).fetchone()
            if old and old[0] != fingerprint:
                raise HTTPException(409, '请求标识冲突；未重新执行')
            if existing and not old:
                raise HTTPException(409, '请求标识已用于其他入口')
            db.execute('INSERT OR IGNORE INTO rayneo_requests VALUES (?,?,?,?)', (request_id, fingerprint, text, time.time()))
        # Registered source exists before the main scheduler can dispatch.
        return self.voice.submit(request_id, text, 'conversation')

    async def health(self):
        return {'ok': True, 'service': 'com-rayneo', 'model': 'com-personal', 'operation_mode':'full-access', 'scope': ['full_access']}

    async def pair(self, request: Request):
        peer = request.client.host if request.client else 'local'
        now = time.time()
        attempts = [t for t in self.pair_attempts.get(peer, []) if now-t < 600]
        if len(attempts) >= 5:
            raise HTTPException(429, '尝试过多，请稍后再试')
        self.pair_attempts[peer] = attempts + [now]
        body = await request.json()
        code = body.get('code', '') if isinstance(body, dict) else ''
        path = self.state/'rayneo-pairing.json'
        with (self.state/'rayneo-pairing.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                data = json.loads(path.read_text())
                valid = isinstance(code, str) and hmac.compare_digest(code, data['code']) and data['expires'] > now
            except (OSError, KeyError, ValueError, TypeError):
                valid = False
            if not valid:
                raise HTTPException(403, '配对码无效或过期')
            path.unlink()
        return {'token': self.token, 'model': 'com-personal', 'operation_mode':'full-access', 'scope': ['full_access']}

    async def get_receipt(self, request_id: str):
        if not self.owns(request_id):
            raise HTTPException(404, '没有本入口的请求')
        value = self.voice.receipt(request_id)
        if not value:
            raise HTTPException(404, '尚未取得受理回执')
        return {**value, 'display_text': final_reply(value) if value['status'] in TERMINAL else '已受理，处理中', 'input_source': 'rayneo'}

    async def chat(self, request: Request):
        body = await request.json()
        if not isinstance(body, dict) or body.get('model') != 'com-personal' or body.get('stream') is not True:
            raise HTTPException(422, '请使用 com-personal 与流式请求')
        messages = body.get('messages')
        if not isinstance(messages, list) or not messages or len(messages) > 60:
            raise HTTPException(422, '消息格式无效')
        # Only the newest utterance goes into Com; plugin history is never replayed.
        latest = messages[-1]
        if not isinstance(latest, dict) or latest.get('role') != 'user':
            raise HTTPException(422, '最后一条必须是本次用户话语')
        request_id = body.get('request_id')
        if request.headers.get('x-com-request-id', request_id) != request_id:
            raise HTTPException(409, '请求标识不一致')
        self.submit(request_id, latest.get('content'))

        def frame(text='', reason=None):
            return 'data: ' + json.dumps({'id': request_id, 'object': 'chat.completion.chunk', 'model': 'com-personal',
                'choices': [{'index': 0, 'delta': {'content': text} if text else {}, 'finish_reason': reason}]}, ensure_ascii=False) + '\n\n'

        async def stream():
            yield frame('已受理，处理中…\n')
            deadline = time.monotonic() + self.wait_seconds
            while time.monotonic() < deadline:
                if await request.is_disconnected():
                    return  # A dropped display transport does not cancel or replay business.
                receipt = self.voice.receipt(request_id)
                if receipt and receipt['status'] in TERMINAL:
                    yield frame(final_reply(receipt))
                    yield frame(reason='stop')
                    yield 'data: [DONE]\n\n'
                    return
                yield ': keepalive\n\n'
                await asyncio.sleep(self.poll_seconds)
            yield frame('仍在处理，请回查本次请求，不要重复提交。')
            yield frame(reason='stop')
            yield 'data: [DONE]\n\n'

        return StreamingResponse(stream(), media_type='text/event-stream', headers={'X-Com-Request-Id': request_id, 'X-Accel-Buffering': 'no', 'Cache-Control': 'no-store'})
