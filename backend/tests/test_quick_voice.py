import asyncio
import importlib
import sys
import time
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from quick_voice import QuickVoice, observed_progress, voice_prompt
from history import History


class FakePi:
    def __init__(self, state):
        self.action_lock = asyncio.Lock()
        self.created = []
        self.inputs = []
        self.records = {}
        self.state = 'running'
        self.fail_input = False
        self.h = History(state, state / 'history')
        self.attached = '0'
        self.killed = []

    async def create(self, agent, cwd, **kwargs):
        sid = f'pi:voice-{len(self.created) + 1}'
        self.created.append((agent, cwd, kwargs))
        self.records[sid] = [{'type': 'session_start', 'data': {}}]
        self.h.save_managed(sid, {'sid': sid, 'agent': 'pi', 'tmux': sid, 'source': '手机发起'})
        return sid

    def events(self, sid):
        return self.records.get(sid, [])

    async def input(self, sid, text, request_id):
        self.inputs.append((sid, text, request_id))
        if self.fail_input:
            raise RuntimeError('transport lost after paste')
        self.records[sid].append({'type': 'agent_start', 'data': {}})
        return request_id

    async def task_status(self, task):
        return self.state

    async def tm(self, *args, **kwargs):
        if args[0] == 'display-message':
            return self.attached
        if args[0] == 'kill-session':
            self.killed.append(args[-1])
        return ''


def test_persistent_acceptance_dispatches_pi_once_and_preserves_real_progress(tmp_path):
    async def scenario():
        pi = FakePi(tmp_path)
        voice = QuickVoice(tmp_path, pi, tmp_path / 'workspace')
        first = voice.submit('quickvoice-request-01', '收藏这个链接 https://example.com')
        assert first['status'] == 'accepted' and first['received_at'] is None
        assert not pi.created and not pi.inputs
        assert voice.submit(first['request_id'], first['text']) == first
        with pytest.raises(ValueError, match='冲突'):
            voice.submit(first['request_id'], '换成另一条消息')
        with pytest.raises(ValueError, match='冲突'):
            voice.submit(first['request_id'], first['text'], 'expense')
        await voice.poll()
        accepted = voice.receipt(first['request_id'])
        assert accepted['agent'] == 'pi' and accepted['status'] == 'submitted'
        sid = accepted['session_id']
        assert pi.created == [('pi', str(tmp_path / 'workspace'), {'sandbox': 'danger-full-access'})]
        assert pi.inputs[0][2] == first['request_id']
        assert 'collect skill' in pi.inputs[0][1]
        assert pi.inputs[0][1].endswith(first['text'])
        assert pi.h.managed()[sid]['source'] == 'Com! 快捷语音'
        with pi.h.db() as db:
            assert db.execute('SELECT title FROM labels WHERE sid=?', (sid,)).fetchone()[0] == first['text']
        await voice.poll()
        assert voice.receipt(first['request_id'])['received_at'] is not None
        pi.records[sid].append({'type': 'tool_execution_start', 'data': {'toolName': 'read', 'toolCallId': 'read-1'}})
        await voice.poll()
        assert voice.receipt(first['request_id'])['phase'] == 'executing'
        assert voice.receipt(first['request_id'])['active_tool'] == 'read'
        pi.records[sid].append({'type': 'message_update', 'data': {'message': {'role': 'assistant', 'timestamp': 10, 'content': [{'type': 'text', 'text': '实际回读结果'}]}}})
        await voice.poll()
        assert voice.receipt(first['request_id'])['phase'] == 'responding'
        assert voice.receipt(first['request_id'])['result'] == '实际回读结果'
        pi.records[sid].append({'type': 'agent_settled', 'data': {}})
        pi.state = 'completed'
        await voice.poll()
        reopened = QuickVoice(tmp_path, pi, tmp_path / 'workspace')
        reopened.recover()
        assert reopened.receipt(first['request_id'])['status'] == 'completed'
        assert reopened.receipt(first['request_id'])['result'] == '实际回读结果'
        assert len(pi.inputs) == 1
    asyncio.run(scenario())


def test_uncertain_input_is_durable_and_never_replayed(tmp_path):
    async def scenario():
        pi = FakePi(tmp_path)
        pi.fail_input = True
        voice = QuickVoice(tmp_path, pi, tmp_path)
        first = voice.submit('expense-request-0001', '午饭35元', 'expense')
        await voice.poll()
        assert voice.receipt(first['request_id'])['status'] == 'unknown'
        assert len(pi.inputs) == 1
        reopened = QuickVoice(tmp_path, pi, tmp_path)
        reopened.recover()
        assert reopened.submit(first['request_id'], first['text'], 'expense')['status'] == 'unknown'
        await reopened.poll()
        assert len(pi.inputs) == 1 and len(pi.created) == 1
    asyncio.run(scenario())


def test_recovery_only_runs_accepted_requests_and_keeps_submitted_session(tmp_path):
    async def scenario():
        pi = FakePi(tmp_path)
        voice = QuickVoice(tmp_path, pi, tmp_path)
        uncertain = voice.submit('request-starting-01', '已经可能开始发送')
        voice.update(uncertain, status='sending', session_id='pi:uncertain')
        queued = voice.submit('request-queued-0001', '新消息可以继续处理')
        voice.recover()
        assert voice.receipt(uncertain['request_id'])['status'] == 'unknown'
        assert voice.receipt(queued['request_id'])['status'] == 'accepted'
        await voice.poll()
        reopened = QuickVoice(tmp_path, pi, tmp_path)
        reopened.recover()
        await reopened.poll()
        assert len(pi.inputs) == 1
        assert reopened.receipt(queued['request_id'])['status'] == 'running'
    asyncio.run(scenario())


def test_queue_serializes_pi_and_cancelled_send_is_not_replayed(tmp_path):
    async def scenario():
        pi = FakePi(tmp_path)
        voice = QuickVoice(tmp_path, pi, tmp_path)
        a = voice.submit('queued-request-0001', '先处理第一条')
        b = voice.submit('queued-request-0002', '然后第二条')
        await voice.poll()
        await voice.poll()
        assert len(pi.inputs) == 1
        assert voice.receipt(b['request_id'])['status'] == 'accepted'
        pi.state = 'completed'
        await voice.poll()
        assert len(pi.inputs) == 2
        assert voice.receipt(a['request_id'])['status'] == 'completed'
        c = voice.submit('queued-request-0003', '取消时不能重放')
        async def interrupted(*args):
            raise asyncio.CancelledError()
        pi.input = interrupted
        with pytest.raises(asyncio.CancelledError):
            await voice.poll()
        assert voice.receipt(c['request_id'])['status'] == 'unknown'
    asyncio.run(scenario())


def test_bookkeeping_write_requires_later_readback_and_matching_amount():
    events = [
        {'type': 'tool_execution_start', 'data': {'toolName': 'bookkeeping', 'toolCallId': 'add', 'args': {'action': 'add'}}},
        {'type': 'tool_execution_end', 'data': {'toolName': 'bookkeeping', 'toolCallId': 'add', 'result': {'details': {'id': 123, 'amount': 35}, 'content': [{'type': 'text', 'text': '已记账 #123'}]}}},
    ]
    assert not observed_progress(events)['action_receipts'][0]['readback_verified']
    events += [
        {'type': 'tool_execution_start', 'data': {'toolName': 'bookkeeping', 'toolCallId': 'recent', 'args': {'action': 'recent'}}},
        {'type': 'tool_execution_end', 'data': {'toolName': 'bookkeeping', 'toolCallId': 'recent', 'result': {'content': [{'type': 'text', 'text': '#1234 -¥35.00 午饭\n#123 -¥36.00 午饭'}]}}},
    ]
    assert not observed_progress(events)['action_receipts'][0]['readback_verified']
    events[-1]['data']['result']['content'][0]['text'] = '#123 -¥35.00 餐饮 · 午饭'
    result = observed_progress(events)
    assert result['action_receipts'][0]['readback_verified']
    assert result['action_receipts'][0]['details']['id'] == 123
    events[0]['data']['args']['comment'] = '午饭'
    events[1]['data']['result']['details']['category'] = '餐饮'
    assert observed_progress(events)['action_receipts'][0]['readback_verified']
    events[-1]['data']['result']['content'][0]['text'] = '#123 -¥35.00 餐饮 · 晚饭'
    assert not observed_progress(events)['action_receipts'][0]['readback_verified']
    assert 'recent 回查' in voice_prompt('午饭35', 'expense')


def test_completed_owned_session_closes_but_preserves_native_records(tmp_path):
    async def scenario():
        pi = FakePi(tmp_path)
        voice = QuickVoice(tmp_path, pi, tmp_path)
        receipt = voice.submit('close-owned-request-001', '正常完成这条请求')
        await voice.poll()
        sid = voice.receipt(receipt['request_id'])['session_id']
        pi.records[sid].append({'type': 'agent_settled', 'data': {}})
        pi.state = 'completed'
        await voice.poll()
        saved = voice.receipt(receipt['request_id'])
        voice.update(saved, completed_at=time.time() - 3)
        history = tmp_path / 'native-history.jsonl'
        history.write_text('native history must survive cleanup')
        await voice.poll()
        assert pi.killed == [sid]
        assert pi.h.managed()[sid]['ended']
        assert voice.receipt(receipt['request_id'])['session_closed']
        assert history.read_text() == 'native history must survive cleanup'
        assert pi.records[sid][-1]['type'] == 'agent_settled'
        await voice.poll()
        assert pi.killed == [sid]
    asyncio.run(scenario())


@pytest.mark.parametrize('handoff', ['input', 'attached', 'native_new_turn'])
def test_session_with_new_owner_or_native_activity_is_never_closed(tmp_path, handoff):
    async def scenario():
        pi = FakePi(tmp_path)
        voice = QuickVoice(tmp_path, pi, tmp_path)
        receipt = voice.submit('preserve-owner-request-001', '给工作页继续的请求')
        await voice.poll()
        sid = voice.receipt(receipt['request_id'])['session_id']
        pi.records[sid].append({'type': 'agent_settled', 'data': {}})
        pi.state = 'completed'
        await voice.poll()
        saved = voice.receipt(receipt['request_id'])
        voice.update(saved, completed_at=time.time() - 3)
        if handoff == 'input':
            async with pi.action_lock:
                voice.revoke(sid)
        elif handoff == 'attached':
            pi.attached = '1'
        else:
            pi.records[sid].append({'type': 'agent_start', 'data': {}})
        await voice.poll()
        assert not pi.killed
        assert not pi.h.managed()[sid].get('ended')
        assert voice.receipt(receipt['request_id'])['session_preserved']
    asyncio.run(scenario())


def test_upgrade_with_lost_hermes_ack_does_not_replay_old_capture(tmp_path):
    old_path = tmp_path / 'personal-conversation.sqlite'
    with sqlite3.connect(old_path) as db:
        db.execute('CREATE TABLE messages(request_id TEXT, status TEXT)')
        db.execute('INSERT INTO messages VALUES (?,?)', ('expense-old-capture-0001', 'unknown'))
    pi = FakePi(tmp_path)
    voice = QuickVoice(tmp_path, pi, tmp_path)
    with pytest.raises(ValueError, match='旧版 Hermes 已接收'):
        voice.submit('expense-old-capture-0001', '午饭35元', 'expense')
    assert voice.receipt('expense-old-capture-0001') is None
    assert not pi.created and not pi.inputs


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setenv('WORKBENCH_HOME', str(tmp_path))
    monkeypatch.setenv('WORKBENCH_STATE', str(tmp_path / 'state'))
    import app
    app = importlib.reload(app)
    monkeypatch.setattr(app.quick_voice, 'start', lambda: None)
    monkeypatch.setattr(app.conversation, 'start', lambda: None)
    with TestClient(app.app) as client:
        yield app, client


def test_authenticated_voice_contract_uses_main_hermes_and_preserves_idempotency(api, monkeypatch):
    app, client = api
    def forbidden(*args, **kwargs):
        raise AssertionError('unified voice must not start the legacy Pi lane')
    monkeypatch.setattr(app.legacy_voice, 'submit', forbidden)
    path = '/personal/quick-voice/messages'
    payload = {'request_id': 'quickvoice-api-0001', 'text': '午饭35元', 'purpose': 'expense'}
    assert client.post(path, json=payload).status_code == 401
    headers = {'Authorization': 'Bearer ' + app.TOKEN}
    receipt = client.post(path, json=payload, headers=headers)
    assert receipt.status_code == 200
    assert receipt.json()['agent'] == 'hermes' and receipt.json()['status'] == 'accepted'
    assert client.post(path, json=payload, headers=headers).json() == receipt.json()
    assert client.post(path, json={**payload, 'purpose': 'conversation'}, headers=headers).status_code == 409
    rid = payload['request_id']
    assert client.get(f'/personal/quick-voice/receipts/{rid}', headers=headers).json() == receipt.json()
    assert client.get('/personal/quick-voice/receipts/not-found', headers=headers).status_code == 404
    assert client.get('/personal/quick-voice', headers=headers).json()['requests'] == [receipt.json()]
    assert client.post('/personal/conversation/messages', json=payload, headers=headers).status_code == 409
    for invalid in ({}, {'request_id': rid, 'text': ''}, {'request_id': rid, 'text': 'x' * 2001}):
        assert client.post(path, json=invalid, headers=headers).status_code == 409


def test_work_page_input_revokes_auto_close_before_native_input(api, monkeypatch):
    app, client = api
    sid = 'pi:work-page-voice'
    app.history.save_managed(sid, {'sid': sid, 'voice_owned': True, 'voice_request_id': 'quickvoice-owned-001'})
    async def received(*args):
        assert app.history.managed()[sid]['voice_owned'] is False
        assert app.runtime.action_lock.locked()
        return 'new-user-turn'
    monkeypatch.setattr(app.runtime, 'input', received)
    async def identity_ready(_sid):
        pass  # This test isolates ownership revocation; identity has separate contract tests.
    monkeypatch.setattr(app.runtime, 'check_input_identity', identity_ready)
    monkeypatch.setattr(app.runtime, 'events', lambda _sid: [])
    headers = {'Authorization': 'Bearer ' + app.TOKEN}
    response = client.post(f'/sessions/{sid}/input', headers=headers,
                           json={'request_id': 'new-work-page-request-001', 'text': '工作页继续这个对话'})
    assert response.status_code == 200
    assert response.json()['turn_id'] == 'new-user-turn'


def test_terminal_attachment_revokes_auto_close_before_using_pane(api, monkeypatch):
    app, client = api
    sid = 'pi:terminal-voice'
    app.history.save_managed(sid, {'sid': sid, 'agent': 'pi', 'tmux': 'test-pane', 'voice_owned': True})
    async def unavailable(_name):
        assert app.history.managed()[sid]['voice_owned'] is False
        return False
    monkeypatch.setattr(app.runtime, 'alive', unavailable)
    from starlette.websockets import WebSocketDisconnect
    with client.websocket_connect(f'/terminal/{sid}') as ws:
        ws.send_json({'token': app.TOKEN})
        with pytest.raises(WebSocketDisconnect):
            ws.receive_text()
