"""Natural Com history query, real read-only service, disposable Com session."""
import argparse
import asyncio
import hashlib
import json
import os
import sys
import tempfile
import time
import uuid
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_tools import AgentTools
from conversation import PersonalConversation
from goals import GoalEvents
from pi_main import PiMainClient
from tasks import TaskStore
from unified_voice import UnifiedVoice
from work_dispatch import WorkProposalStore


async def run(isolated=False):
    def protected_config():
        return {name: hashlib.sha256(path.read_bytes()).digest() if path.is_file() else None
                for name in ('auth.json', 'settings.json', 'models.json')
                for path in [Path.home() / '.pi/agent' / name]}
    protected_before = protected_config() if isolated else None
    with tempfile.TemporaryDirectory(prefix='com-bookkeeping-history-') as directory:
        root = Path(directory)
        state, workspace = root / 'state', root / 'workspace'
        state.mkdir(mode=0o700)
        workspace.mkdir()
        token = uuid.uuid4().hex
        (state / 'token').write_text(token)
        (state / 'token').chmod(0o600)
        trace, denied, loaded = [], [], []
        holder = {}
        registry = SimpleNamespace(observe=lambda name, **kw: loaded.append(name), search=lambda *a, **k: [])

        async def serve(reader, writer):
            status, result, name = 200, {}, ''
            try:
                header = (await reader.readuntil(b'\r\n\r\n')).decode()
                if ('Authorization: Bearer ' + token).lower() not in header.lower():
                    raise ValueError('Invalid disposable Com token')
                length = next(int(line.split(':', 1)[1]) for line in header.split('\r\n') if line.lower().startswith('content-length:'))
                payload = json.loads(await reader.readexactly(length))
                name = header.split(' ', 2)[1].rsplit('/', 1)[-1]
                args, context = payload['args'], payload['context']
                # Production tools are loaded, but this acceptance run can never
                # write a ledger, send a message, execute shell, or create work.
                if name not in {'loaded', 'bookkeeping_search', 'react_to_user_message'}:
                    raise ValueError('This disposable acceptance permits only historical bookkeeping search')
                started = time.monotonic()
                result = await holder['service'].call(name, args, context)
                if name == 'bookkeeping_search':
                    trace.append({'tool': name, 'args': args,
                                  'source_message_id': context.get('origin_message_id'),
                                  'source_request_id': context.get('origin_request_id'),
                                  'duration_ms': round((time.monotonic() - started) * 1000),
                                  'result': result})
            except Exception as exc:
                status = 400
                result = {'detail': str(exc)[:300]}
                denied.append({'tool': name, 'error': str(exc)[:300]})
            try:
                body = json.dumps(result, ensure_ascii=False).encode()
                writer.write(f'HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {len(body)}\r\n\r\n'.encode() + body)
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        server = await asyncio.start_server(serve, '127.0.0.1', 0)
        port = server.sockets[0].getsockname()[1]
        native = PiMainClient(state, workspace, isolated=isolated, readonly=isolated,
                              env={**os.environ, 'COM_INTERNAL_URL': f'http://127.0.0.1:{port}'})
        conversation = PersonalConversation(state, native)
        today = datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat()
        conversation.task_environment = lambda: {'current_date': today, 'timezone': 'Asia/Shanghai',
                                                  'main_operation_mode': native.operation_mode}
        store = TaskStore(state)
        holder['service'] = AgentTools(state, conversation, WorkProposalStore(state, workspace), store,
                                       SimpleNamespace(), registry, GoalEvents(state))
        voice = UnifiedVoice(conversation, SimpleNamespace(receipt=lambda request_id: None))
        request_id = 'native-history-' + uuid.uuid4().hex
        receipt = voice.submit(request_id, '帮我找一下，我的九月五号消费了一千三百二十五，这是什么消费？', 'conversation')
        mid = receipt['message_id']
        started = time.monotonic()
        try:
            await asyncio.wait_for(conversation.process_one(), 180)
            elapsed = round((time.monotonic() - started) * 1000)
            messages = conversation.snapshot()['messages']
            row = next(m for m in messages if m['id'] == mid)
            if row['status'] != 'completed':
                events = [json.loads(line) for line in native.rpc.events.read_text().splitlines()] if native.rpc.events.exists() else []
                return {'ok': False, 'temporary_com_state': True, 'isolated': isolated,
                        'prompt_delivered': bool(row['received_at']), 'search_call_count': len(trace),
                        'elapsed_ms': elapsed, 'shared_auth_copied': False,
                        'safe_rpc_rejections': [{key: event[key] for key in ('command', 'error_labels')}
                                                for event in events if event.get('kind') == 'rpc.rejected']}
            reply = next(m['text'] for m in messages if m.get('parent_id') == mid)
            assert row['status'] == 'completed' and row['received_at'], 'Native turn was not actually delivered/completed'
            assert not [error for error in denied if error['tool'] != 'bookkeeping_search'], 'Native model attempted an unexpected operation: ' + str(denied)
            assert store.list() == [], 'Simple account query incorrectly delegated'
            assert trace, 'Native model did not call the historical search'
            assert all(t['source_message_id'] == mid and t['source_request_id'] == request_id for t in trace), 'Authentic native input source mismatch'
            first_result = trace[0]['result']
            assert first_result['read_only'] and first_result['criteria']['start_date'] == '2026-09-05' and first_result['criteria']['end_date'] == '2026-09-05', 'First search did not use the natural date'
            assert first_result['criteria']['amount'] == 1325, 'First search did not use the exact spoken amount'
            result = first_result
            assert len(result['items']) == 1, 'Target did not uniquely match the actual ledger'
            item = result['items'][0]
            assert item['id'] == '3843404382045470720' and item['amount'] == 1325, 'Actual record ID or units changed'
            assert all(str(item[key]) in reply for key in ('id', 'comment', 'account')), 'Final reply omitted actual record evidence'
            assert '1325' in reply.replace(',', '').replace('，', ''), 'Final reply omitted amount'
            assert 'bookkeeping' in loaded and 'bash' in loaded and 'bookkeeping_search' in loaded, 'Normal native operation tools were not loaded'
            assert 'lane_tools' not in loaded, 'A WeChat lane was loaded'
            if isolated:
                assert protected_config() == protected_before, 'Shared auth/config changed during isolated read'
            return {'ok': True, 'production_api_read_only': True, 'production_ledger_written': False,
                    'temporary_com_state': True, 'production_com_session_reused': False,
                    'probe_write_guard': True, 'operation_mode': native.operation_mode,
                    'isolated': isolated, 'readonly': isolated, 'shared_auth_copied': False,
                    'global_auth_config_unchanged': protected_config() == protected_before if isolated else None,
                    'clock_context': {'current_date': today, 'timezone': 'Asia/Shanghai'},
                    'voice_purpose': 'conversation', 'source_message_id': mid,
                    'source_request_id': request_id, 'native_delivery': row['delivery_state'],
                    'elapsed_ms': elapsed,
                    'search_calls': [{key: value for key, value in call.items() if key != 'result'} |
                                     {'criteria': call['result']['criteria'], 'coverage': call['result']['coverage'],
                                      'matching_target_records': [record for record in call['result']['items']
                                                                  if record['id'] == item['id']]}
                                     for call in trace], 'delegated_tasks': 0,
                    'final_reply_record_evidence_verified': True, 'reply': reply,
                    'loaded_tools': sorted(set(loaded)), 'authorization_rejections': denied}
        except AssertionError as error:
            # Preserve the exact failure without persisting unrelated finance
            # records if the model made a broader follow-up read.
            return {'ok': False, 'assertion': str(error)[:300], 'isolated': isolated,
                    'temporary_com_state': True, 'production_ledger_written': False,
                    'operation_mode': native.operation_mode, 'elapsed_ms': round((time.monotonic()-started)*1000),
                    'native_delivery': row['delivery_state'] if 'row' in locals() else None,
                    'delegated_tasks': len(store.list()),
                    'search_calls': [{key: value for key, value in call.items() if key != 'result'} |
                                     {'criteria': call['result']['criteria'],
                                      'matching_target_records': [record for record in call['result']['items']
                                                                  if record['id'] == '3843404382045470720'],
                                      'matched_record_count': len(call['result']['items'])} for call in trace],
                    'authorization_rejections': denied}
        finally:
            await native.stop()
            server.close()
            await server.wait_closed()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output')
    parser.add_argument('--isolated', action='store_true')
    args = parser.parse_args()
    result = asyncio.run(run(args.isolated))
    if args.output:
        target = Path(args.output)
        target.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        target.chmod(0o600)
    print(json.dumps(result, ensure_ascii=False))
