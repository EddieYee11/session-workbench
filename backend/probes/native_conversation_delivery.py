"""Isolated real Pi delivery; one read-only tool uses a temporary local stub."""
import argparse
import asyncio
import json
import os
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conversation import PersonalConversation
from pi_main import PiMainClient


def message(conversation, mid):
    return next(row for row in conversation.snapshot()['messages'] if row['id'] == mid)


async def until(predicate, seconds=90):
    async with asyncio.timeout(seconds):
        while not predicate():
            await asyncio.sleep(.03)


async def probe():
    with tempfile.TemporaryDirectory(prefix='com-native-delivery-') as directory:
        state = Path(directory)
        (state / 'token').write_text(uuid.uuid4().hex)
        (state / 'token').chmod(0o600)
        nonce = 'DELIVERY_' + uuid.uuid4().hex[:10]
        calls = []
        hold = False
        tool_waiting = asyncio.Event()
        release_tool = asyncio.Event()

        async def stub(reader, writer):
            try:
                header = (await reader.readuntil(b'\r\n\r\n')).decode()
                length = next(int(line.split(':', 1)[1]) for line in header.split('\r\n') if line.lower().startswith('content-length:'))
                request = json.loads(await reader.readexactly(length))
                route = header.split(' ', 2)[1].rsplit('/', 1)[-1]
                if route == 'task_status':
                    calls.append(request['context'])
                    if hold and not tool_waiting.is_set():
                        tool_waiting.set()
                        await release_tool.wait()
                elif route != 'loaded':
                    raise AssertionError('Unexpected probe tool: ' + route)
                body = json.dumps({'tasks': [], 'probe': 'isolated read-only tool'}).encode()
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        server = await asyncio.start_server(stub, '127.0.0.1', 0)
        address = server.sockets[0].getsockname()
        env = {**os.environ, 'COM_INTERNAL_URL': f'http://127.0.0.1:{address[1]}'}
        native = PiMainClient(state, state, tools=False, env=env)
        restored = None
        try:
            conversation = PersonalConversation(state, native)
            first = conversation.submit('native-first-' + nonce, '隔离协议验收：不要调用工具，只做文字对话。记住测试代号 ' + nonce + '；这次仅回复“已记住”。')['message_id']
            await asyncio.wait_for(conversation.process_one(), 180)
            assert message(conversation, first)['status'] == 'completed', message(conversation, first)
            assert native.has_native_history
            first_session = native.rpc.session
            hold = True
            second = conversation.submit('native-second-' + nonce, '本轮是隔离协议验收。请调用一次 task_status 查看空任务清单，工具返回后仅回复“第二轮原始内容”。只允许 task_status，不调用其他工具。')['message_id']
            runner = asyncio.create_task(conversation.process_one())
            await asyncio.wait_for(tool_waiting.wait(), 90)
            assert calls[-1]['origin_message_id'] == second
            supplement = conversation.submit('native-steer-' + nonce, '补充：在刚才工具返回之后，再调用一次 task_status，最终回复请改为仅输出 ' + nonce + '。只允许 task_status，不调用其他工具。', {'mode': 'reply', 'id': second})['message_id']
            await until(lambda: message(conversation, supplement)['delivery_state'] == 'worker_queued')
            ack = message(conversation, supplement)
            assert ack['received_at'] is None
            assert native.rpc.context['origin_message_id'] == second
            release_tool.set()
            await asyncio.wait_for(runner, 180)
            primary_saved = message(conversation, second)
            supplement_saved = message(conversation, supplement)
            assert primary_saved['status'] == 'completed', primary_saved
            assert supplement_saved['status'] == 'completed', supplement_saved
            assert supplement_saved['received_at'] is not None
            assert supplement_saved['delivery_state'] == 'delivered'
            assert len(calls) == 2, calls
            assert calls[-1]['origin_message_id'] == supplement
            assert calls[-1]['supplement_to_message_id'] == second
            reply = next(row for row in conversation.snapshot()['messages'] if row.get('parent_id') == second)
            assert nonce in reply['text'], reply['text']
            paired = [item for item in primary_saved['tasks'] if item.get('kind') == 'tool']
            assert len(paired) == 2 and all(item['status'] == 'done' and item.get('finished_at') for item in paired)
            await native.stop()
            restored = PiMainClient(state, state, tools=False, env=env)
            assert restored.rpc.session == first_session
            assert restored.has_native_history
            reopened = PersonalConversation(state, restored)
            assert message(reopened, second)['id'] == second
            assert message(reopened, supplement)['delivery_state'] == 'delivered'
            third = reopened.submit('native-resumed-' + nonce, '隔离协议验收续轮：不要调用工具。仅回复我们上一轮最终测试代号。')['message_id']
            await asyncio.wait_for(reopened.process_one(), 180)
            assert message(reopened, third)['status'] == 'completed', message(reopened, third)
            resumed_reply = next(row for row in reopened.snapshot()['messages'] if row.get('parent_id') == third)
            assert nonce in resumed_reply['text'], resumed_reply['text']
            return {'ok': True, 'isolated_state': True, 'builtin_tools': False,
                    'production_api_used': False, 'safe_tool': 'temporary local task_status stub',
                    'native_history': True, 'same_native_session_after_restart': True,
                    'stable_com_message_ids': True, 'supplement_ack_state': ack['delivery_state'],
                    'received_at_on_ack': ack['received_at'], 'supplement_delivery': supplement_saved['delivery_state'],
                    'supplement_completed': True, 'tool_source_before_supplement': calls[0]['origin_message_id'],
                    'tool_source_after_delivery': calls[1]['origin_message_id'],
                    'supplement_parent_verified': calls[1]['supplement_to_message_id'] == second,
                    'native_context_hook': True, 'paired_native_tool_events': len(paired)}
        finally:
            release_tool.set()
            await native.stop()
            if restored:
                await restored.stop()
            server.close()
            await server.wait_closed()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output')
    arguments = parser.parse_args()
    report = asyncio.run(probe())
    if arguments.output:
        target = Path(arguments.output)
        target.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        target.chmod(0o600)
    print(json.dumps(report, ensure_ascii=False))
