import importlib
import sys
from pathlib import Path

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setenv('WORKBENCH_HOME', str(tmp_path))
    monkeypatch.setenv('WORKBENCH_STATE', str(tmp_path / 'state'))
    import app
    app = importlib.reload(app)
    with TestClient(app.app) as client:
        yield app, client


def test_voice_requires_auth_limits_audio_and_never_launches_agent(api, monkeypatch):
    app, client = api
    async def forbidden(*args, **kwargs):
        raise AssertionError('transcription must not launch or send')
    monkeypatch.setattr(app.runtime, 'create', forbidden)
    monkeypatch.setattr(app.runtime, 'input', forbidden)
    import voice
    calls = []
    async def asr(audio):
        calls.append(audio)
        return '保留在草稿中的测试内容'
    monkeypatch.setattr(voice, 'transcribe_local', asr)
    url = '/voice/transcribe/01234567-89ab-cdef-0123-456789abcdef'
    headers = {'Authorization': 'Bearer ' + app.TOKEN, 'Content-Type': 'audio/mp4'}
    assert client.post(url, content=b'x' * 200).status_code == 401
    assert client.post(url, headers={**headers, 'Content-Type': 'text/plain'}, content=b'x' * 200).status_code == 415
    assert client.post(url, headers=headers, content=b'x').status_code == 422
    monkeypatch.setattr(voice, 'MAX_AUDIO_BYTES', 1024)
    assert client.post(url, headers=headers, content=b'x' * 1025).status_code == 413
    first = client.post(url, headers=headers, content=b'x' * 200)
    assert first.status_code == 200
    assert first.json()['text'] == '保留在草稿中的测试内容'
    assert client.post(url, headers=headers, content=b'x' * 200).json() == first.json()
    assert len(calls) == 1
    assert client.post(url, headers=headers, content=b'y' * 200).status_code == 409


def test_failed_transcription_can_retry_same_capture(api, monkeypatch):
    app, client = api
    import voice
    async def unavailable(audio):
        raise HTTPException(503, 'retry')
    monkeypatch.setattr(voice, 'transcribe_local', unavailable)
    url = '/voice/transcribe/01234567-89ab-cdef-0123-456789abcdef'
    headers = {'Authorization': 'Bearer ' + app.TOKEN, 'Content-Type': 'audio/mp4'}
    assert client.post(url, headers=headers, content=b'x' * 200).status_code == 503
    async def available(audio):
        return '恢复后的文字'
    monkeypatch.setattr(voice, 'transcribe_local', available)
    assert client.post(url, headers=headers, content=b'x' * 200).json()['text'] == '恢复后的文字'
