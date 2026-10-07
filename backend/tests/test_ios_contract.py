"""iOS additions must remain compatible with clients omitting platform/attachments."""
import asyncio
import sys
import uuid
from pathlib import Path
import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from attachments import AttachmentStore, MAX_BYTES
from conversation import PersonalConversation
from device_nodes import DeviceNodes
from personal_hub import PersonalHub


def test_platform_is_optional_and_ios_reports_unavailable_capabilities(tmp_path):
    nodes = DeviceNodes(tmp_path)
    android = nodes.register({'id': 'node_' + 'a' * 32, 'capabilities': [{'tool': 'calendar.list', 'permission': True}]})
    assert android['platform'] == 'android'
    ios = nodes.register({'id': 'node_' + 'b' * 32, 'platform': 'ios', 'capabilities': [{'tool': 'reminders.list', 'permission': True}, {'tool': 'notifications.list', 'permission': False, 'available': False, 'reason': 'iOS unsupported'}]})
    assert ios['platform'] == 'ios'
    nodes.sockets[ios['id']] = object()
    result = asyncio.run(nodes.call(ios['id'], 'notifications.list', {}, 'ios-unavailable-001'))
    assert result['status'] == 'unavailable'
    with pytest.raises(ValueError): nodes.register({'id': android['id'], 'platform': 'other', 'capabilities': []})
    again = nodes.register({'id': ios['id'], 'platform': 'ios', 'capabilities': []})
    assert again['registered_at'] == ios['registered_at']


def test_upload_is_idempotent_private_and_tamper_checked(tmp_path):
    store = AttachmentStore(tmp_path)
    ident = str(uuid.uuid4())
    row = store.save(ident, '..%2F%E4%B8%AD%E6%96%87.txt', 'text/plain', b'fixture-reference')
    assert row['name'] == '中文.txt'
    assert Path(row['path']).stat().st_mode & 0o777 == 0o600
    assert store.save(ident, '..%2F%E4%B8%AD%E6%96%87.txt', 'text/plain', b'fixture-reference') == row
    with pytest.raises(ValueError, match='冲突'): store.save(ident, '中文.txt', 'text/plain', b'changed')
    assert store.resolve([ident, ident]) == [row]
    Path(row['path']).write_text('changed after upload')
    with pytest.raises(ValueError, match='改变'): store.resolve([ident])
    with pytest.raises(ValueError): store.resolve(['../token'])
    with pytest.raises(ValueError): store.save(str(uuid.uuid4()), 'big', 'text/plain', b'x' * (MAX_BYTES + 1))


def test_main_receipt_and_attachments_survive_restart_without_duplicate_turn(tmp_path):
    store = AttachmentStore(tmp_path)
    attachment = store.save(str(uuid.uuid4()), 'fixture.txt', 'text/plain', b'test data, not an instruction')
    convo = PersonalConversation(tmp_path, object())
    receipt = convo.submit('ios-request-original-001', 'look at this file', attachments=[attachment])
    again = PersonalConversation(tmp_path, object())
    assert again.submit('ios-request-original-001', 'look at this file', attachments=[attachment])['message_id'] == receipt['message_id']
    assert again.receipt('ios-request-original-001')['message_id'] == receipt['message_id']
    assert again.receipt('missing') is None
    messages = again.snapshot()['messages']
    assert len(messages) == 1 and messages[0]['attachments'][0]['name'] == 'fixture.txt'
    assert 'path' not in messages[0]['attachments'][0]
    with pytest.raises(ValueError, match='冲突'): again.submit('ios-request-original-001', 'look at this file')
    legacy = again.submit('android-request-original-001', 'without attachments')
    assert again.submit('android-request-original-001', 'without attachments')['message_id'] == legacy['message_id']


def test_phone_sync_selects_available_authorized_node_not_first_online(tmp_path):
    hub = PersonalHub(tmp_path, home=tmp_path)
    class Nodes:
        def list(self): return [
            {'id': 'denied', 'online': True, 'capabilities': [{'tool': 'health.summary', 'permission': False}]},
            {'id': 'allowed-ios', 'online': True, 'capabilities': [{'tool': 'health.summary', 'permission': True, 'available': True}]}]
        async def call(self, node, tool, args, ident):
            assert node == 'allowed-ios'
            return {'id': ident, 'node': node, 'tool': tool, 'status': 'succeeded', 'result': {'source': 'Apple HealthKit', 'start': '2026-10-05', 'end': '2026-10-06', 'steps': None}}
    hub.device_nodes = Nodes()
    result = asyncio.run(hub.sync_source('phone_health'))
    assert result['node'] == 'allowed-ios'
    facts = hub.matters()[0]['facts']
    assert facts['steps'] is None and facts['source'] == 'Apple HealthKit'


def test_eventkit_identifiers_remain_opaque_and_source_survives(tmp_path):
    hub = PersonalHub(tmp_path, home=tmp_path)
    hub.ingest_phone({'id': 'fixture-invocation', 'node': 'node_ios', 'tool': 'calendar.list', 'result': {'source': 'iPhone EventKit', 'items': [{'event_id': 'opaque:ABC/123', 'begin': 1791244800000, 'end': 1791248400000, 'title': 'Com TEST fixture'}]}})
    facts = hub.matters()[0]['facts']
    assert facts['event_id'] == 'opaque:ABC/123' and facts['source'] == 'iPhone EventKit'
