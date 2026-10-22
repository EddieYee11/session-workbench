"""Read-only latency probe: one question in a throwaway Hermes session, report tool calls and timing.

usage: python probes/latency_probe.py [--old-prompt PATH] "问题" ["问题" ...]
Does not touch the live Com conversation; questions must be read-only.
"""
import argparse
import asyncio
import json
import sys
import time
import uuid
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from conversation import HermesClient
from hermes_prompt import SYSTEM_PROMPT


async def probe(client, text, instructions):
    sid = 'com-probe-' + uuid.uuid4().hex[:8]
    await client.request('POST', '/api/sessions', {'id': sid, 'source': 'api_server', 'title': 'latency probe ' + sid, 'system_prompt': instructions})
    started = time.monotonic()
    async with httpx.AsyncClient(timeout=30, trust_env=False) as http:
        r = await http.post(client.base_url + '/v1/runs', json={'input': text, 'session_id': sid, 'instructions': instructions,
            'model_options': {'reasoning': {'effort': 'low'}}}, headers={'Authorization': 'Bearer ' + client.key()})
        r.raise_for_status()
        run_id = r.json()['run_id']
    tools, first_text = [], None
    async with httpx.AsyncClient(timeout=httpx.Timeout(600, connect=10), trust_env=False) as http:
        async with http.stream('GET', client.base_url + '/v1/runs/' + run_id + '/events',
                               headers={'Authorization': 'Bearer ' + client.key(), 'Accept': 'text/event-stream'}) as resp:
            async for line in resp.aiter_lines():
                if not line.startswith('data:'): continue
                data = json.loads(line[5:])
                event = data.get('event', '')
                if event == 'tool.started': tools.append(data.get('tool_name') or data.get('tool'))
                elif event in ('message.delta', 'assistant.delta') and first_text is None: first_text = time.monotonic() - started
                elif event in ('run.completed', 'run.failed', 'run.cancelled', 'done'): break
    result = await client.request('GET', '/v1/runs/' + run_id)
    output = result.get('output', '')
    return {'q': text, 'tools': len(tools), 'tool_names': tools, 'first_text_s': round(first_text or 0, 1),
            'total_s': round(time.monotonic() - started, 1), 'reply_chars': len(str(output)), 'reply': str(output)[:300]}


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--old-prompt')
    parser.add_argument('questions', nargs='+')
    args = parser.parse_args()
    instructions = Path(args.old_prompt).read_text() if args.old_prompt else SYSTEM_PROMPT
    client = HermesClient(Path.home() / '.session-workbench')
    for q in args.questions:
        print(json.dumps(await probe(client, q, instructions), ensure_ascii=False), flush=True)


asyncio.run(main())
