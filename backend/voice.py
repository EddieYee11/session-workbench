"""Com! transcription only. Audio never creates an agent turn here."""
import asyncio
import hashlib
import json
import re
from pathlib import Path

import httpx
from fastapi import APIRouter, HTTPException, Request

MAX_AUDIO_BYTES = 5 * 1024 * 1024
VOICE_ID = re.compile(r'^[a-f0-9-]{36}$')

async def transcribe_local(audio: bytes) -> str:
    try:
        async with httpx.AsyncClient(timeout=90, trust_env=False) as client:
            response = await client.post('http://127.0.0.1:8647/transcribe',
                                         content=audio, headers={'Content-Type': 'audio/mp4'})
            response.raise_for_status()
            text = str(response.json().get('text', '')).strip()
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(503, '语音识别暂时不可用，录音已保留，请稍后重试') from exc
    if not text:
        raise HTTPException(422, '没有听清语音。录音已保留，可以重录或直接输入')
    return text


def voice_router(state: Path) -> APIRouter:
    router = APIRouter()
    results = state / 'voice-transcripts'
    results.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Bound ASR concurrency; also serializes retries of an individual capture.
    lock = asyncio.Lock()

    @router.post('/voice/transcribe/{capture_id}')
    async def transcribe(capture_id: str, request: Request):
        if not VOICE_ID.fullmatch(capture_id):
            raise HTTPException(400, '录音标识无效')
        if request.headers.get('content-type', '').split(';')[0] != 'audio/mp4':
            raise HTTPException(415, '请上传 M4A 录音')
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
            text = await transcribe_local(bytes(audio))
            result = {'sha256': digest, 'text': text}
            temporary = result_file.with_suffix('.tmp')
            temporary.touch(mode=0o600, exist_ok=True)
            temporary.write_text(json.dumps(result, ensure_ascii=False))
            temporary.replace(result_file)
            return {'capture_id': capture_id, 'text': text}

    return router
