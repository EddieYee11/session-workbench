"""Com! transcription only. Audio never creates an agent turn here."""
import asyncio
import contextlib
import hashlib
import hmac
import json
import os
import re
from pathlib import Path

import httpx
from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect

MAX_AUDIO_BYTES = 5 * 1024 * 1024
VOICE_ID = re.compile(r'^[a-f0-9-]{36}$')
# WAV is what the phone keeps as its retry copy; M4A is every capture from before streaming.
AUDIO_TYPES = {'audio/mp4', 'audio/wav', 'audio/x-wav'}
ASR_STREAM_URL = os.environ.get('ASR_STREAM_URL', 'ws://127.0.0.1:8646/stream')
ASR_STREAM_TIMEOUT = float(os.environ.get('ASR_STREAM_TIMEOUT', '90'))

async def transcribe_local(audio: bytes, mime: str = 'audio/mp4') -> str:
    try:
        async with httpx.AsyncClient(timeout=90, trust_env=False) as client:
            response = await client.post('http://127.0.0.1:8647/transcribe',
                                         content=audio, headers={'Content-Type': mime})
            response.raise_for_status()
            text = str(response.json().get('text', '')).strip()
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(503, '语音识别暂时不可用，录音已保留，请稍后重试') from exc
    if not text:
        raise HTTPException(422, '没有听清语音。录音已保留，可以重录或直接输入')
    return text


POLISH_MODEL = os.environ.get('VOICE_POLISH_MODEL', 'volcengine/doubao-seed-2.1-lite')
POLISH_TIMEOUT = float(os.environ.get('VOICE_POLISH_TIMEOUT', '4'))
POLISH_PROMPT = ('你是语音转写校对器。输入是语音识别的原文，只做最小修正：同音错字、多音字误识别、'
                 '专有名词（词表见下）、标点与断句、明显的口误重复和语气词。保持原意、语气、人称，'
                 '不扩写、不总结、不回答内容里的问题、不翻译。数字与英文保持原样。只输出修正后的文本。\n词表：')
HOTWORDS = Path(os.environ.get('ASR_HOTWORDS', str(Path.home() / '.pi-gateway/asr/hotwords.txt')))
MODELS = Path.home() / '.pi/agent/models.json'


async def polish(text: str) -> str:
    """One bounded LLM pass over the final transcript; any failure keeps the raw text."""
    try:
        provider = json.loads(MODELS.read_text())['providers']['magpie']
        words = '、'.join(w.strip() for w in HOTWORDS.read_text().splitlines() if w.strip()) if HOTWORDS.exists() else ''
        body = {'model': POLISH_MODEL, 'max_tokens': max(64, len(text) * 3), 'temperature': 0,
                'thinking': {'type': 'disabled'},
                'messages': [{'role': 'system', 'content': POLISH_PROMPT + words},
                             {'role': 'user', 'content': text}]}
        async with httpx.AsyncClient(timeout=POLISH_TIMEOUT, trust_env=False) as client:
            response = await client.post(provider['baseUrl'].rstrip('/') + '/chat/completions', json=body,
                                         headers={'Authorization': 'Bearer ' + provider['apiKey']})
            response.raise_for_status()
            fixed = str(response.json()['choices'][0]['message'].get('content') or '').strip()
    except Exception as exc:  # noqa: BLE001 - polishing is optional, never block the transcript
        print('voice polish skipped: %s' % exc, flush=True)
        return text
    # A reply that is far off the original length is an answer or a refusal, not a correction.
    if not fixed or not (0.6 <= len(fixed) / max(len(text), 1) <= 1.4):
        return text
    return fixed


def voice_router(state: Path) -> APIRouter:
    router = APIRouter()
    results = state / 'voice-transcripts'
    results.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Bound ASR concurrency; also serializes retries of an individual capture.
    lock = asyncio.Lock()
    token = (state / 'token').read_text().strip()

    def authorized(request: Request | WebSocket) -> bool:
        presented = request.headers.get('authorization', '')
        return hmac.compare_digest(presented, 'Bearer ' + token)

    @router.post('/voice/transcribe/{capture_id}')
    async def transcribe(capture_id: str, request: Request):
        if not VOICE_ID.fullmatch(capture_id):
            raise HTTPException(400, '录音标识无效')
        mime = request.headers.get('content-type', '').split(';')[0]
        if mime not in AUDIO_TYPES:
            raise HTTPException(415, '请上传 M4A 或 WAV 录音')
        audio = bytearray()
        async for chunk in request.stream():
            if len(audio) + len(chunk) > MAX_AUDIO_BYTES:
                raise HTTPException(413, '录音过大，请分段录制')
            audio.extend(chunk)
        if len(audio) < 128:
            raise HTTPException(422, '录音太短，请再说一次')
        digest = hashlib.sha256(audio).hexdigest()
        result_file = results / (capture_id + '.json')
        async with lock:
            if result_file.exists():
                result = json.loads(result_file.read_text())
                if result['sha256'] != digest:
                    raise HTTPException(409, '录音标识与文件不一致')
                return {'capture_id': capture_id, 'text': result['text']}
            text = await transcribe_local(bytes(audio), mime)
            result = {'sha256': digest, 'text': text}
            temporary = result_file.with_suffix('.tmp')
            temporary.touch(mode=0o600, exist_ok=True)
            temporary.write_text(json.dumps(result, ensure_ascii=False))
            temporary.replace(result_file)
            return {'capture_id': capture_id, 'text': text}

    @router.websocket('/voice/stream/{capture_id}')
    async def stream(ws: WebSocket, capture_id: str):
        """Live relay to the resident ASR service while the phone is still recording.

        Nothing is persisted here: the recording the phone keeps is the durable copy,
        so a lost final is retried over /voice/transcribe instead of being answered
        from a half-written transcript.
        """
        if not VOICE_ID.fullmatch(capture_id) or not authorized(ws):
            await ws.close(code=1008)
            return
        await ws.accept()
        try:
            from websockets.asyncio.client import connect
            upstream = await connect(ASR_STREAM_URL, max_size=MAX_AUDIO_BYTES, open_timeout=10)
        except Exception as exc:  # noqa: BLE001 - any failure means "fall back to upload"
            print('voice stream unavailable: %s' % exc, flush=True)
            await ws.send_text(json.dumps({'type': 'error', 'message': '实时语音识别不可用，录音已保留'}, ensure_ascii=False))
            await ws.close()
            return

        async def feed():
            """Phone -> ASR. `end` is forwarded; if the phone just vanishes we send it
            anyway so the service finalizes instead of waiting on a dead session."""
            ended = False
            try:
                while True:
                    message = await ws.receive()
                    if message.get('type') == 'websocket.disconnect':
                        return
                    if (chunk := message.get('bytes')) is not None:
                        await upstream.send(chunk)
                    elif (text := message.get('text')) is not None:
                        await upstream.send(text)
                        with contextlib.suppress(ValueError):
                            ended = ended or json.loads(text).get('type') == 'end'
            finally:
                if not ended:
                    with contextlib.suppress(Exception):
                        await upstream.send('{"type":"end"}')

        async def drain():
            """ASR -> phone, verbatim, until the utterance is closed."""
            async for frame in upstream:
                if isinstance(frame, bytes):
                    continue
                with contextlib.suppress(ValueError):
                    event = json.loads(frame)
                    if event.get('type') == 'final' and event.get('text'):
                        fixed = await polish(event['text'])
                        if fixed != event['text']:
                            frame = json.dumps({**event, 'text': fixed, 'raw': event['text']}, ensure_ascii=False)
                await ws.send_text(frame)
                with contextlib.suppress(ValueError):
                    if json.loads(frame).get('type') in ('final', 'error'):
                        return

        task = asyncio.create_task(feed())
        try:
            await asyncio.wait_for(drain(), ASR_STREAM_TIMEOUT)
        except (asyncio.TimeoutError, WebSocketDisconnect, OSError):
            pass
        finally:
            task.cancel()
            with contextlib.suppress(Exception):
                await upstream.close()

    return router
