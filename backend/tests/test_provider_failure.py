import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conversation import PersonalConversation
from hermes_runtime import HermesRuntime


def test_provider_failure_is_definite_but_execution_failure_stays_uncertain(tmp_path):
    async def run(error, executed=False):
        client = HermesRuntime(tmp_path)
        async def submit(*args): return 'run_fixture'
        async def events(*args):
            if executed: yield 'tool.started', {'tool': 'example'}
            yield 'run.failed', {}
        async def request(*args): return {'status': 'failed', 'error': error}
        client.submit_run, client._events, client.request = submit, events, request
        return [payload async for event, payload in client.stream('hello', error) if event == 'error'][0]
    definite = asyncio.run(run('⚠️ Provider authentication failed: Unknown provider magpie'))
    assert definite['uncertain'] is False and definite['failure_code'] == 'provider_unavailable'
    uncertain = asyncio.run(run('tool execution interrupted'))
    assert uncertain['uncertain'] is True and not uncertain['failure_code']
    disabled = asyncio.run(run('HTTP 404: Volcengine Ark is switched off in Magpie'))
    assert disabled['uncertain'] is False and disabled['provider_disabled'] is True
    after_tool = asyncio.run(run('HTTP 404: Volcengine Ark is switched off in Magpie', executed=True))
    assert after_tool['uncertain'] is True and not after_tool['failure_code']
    quota = asyncio.run(run('HTTP 429: 本周额度已用完'))
    assert quota['uncertain'] is False and quota['provider_quota'] is True
    quota_after_tool = asyncio.run(run('HTTP 429: 本周额度已用完', executed=True))
    assert quota_after_tool['uncertain'] is True and not quota_after_tool['failure_code']


def test_conversation_marks_provider_failure_failed_and_does_not_replay(tmp_path):
    class Client:
        calls = 0
        def key(self): return 'fixture'
        async def create_session(self): return 'fixture'
        async def stream_chat(self, *args):
            self.calls += 1
            yield 'run.started', {'run_id': 'run_fixture'}
            yield 'error', {'failure_code': 'provider_unavailable', 'uncertain': False}
            yield 'done', {}
    client = Client()
    chat = PersonalConversation(tmp_path, client)
    mid = chat.submit('provider-failure-request', '你好')['message_id']
    asyncio.run(chat.process_one())
    row = next(row for row in chat.snapshot()['messages'] if row['id'] == mid)
    assert row['status'] == 'failed' and '本轮未执行' in row['error']
    assert asyncio.run(chat.process_one()) is False and client.calls == 1
