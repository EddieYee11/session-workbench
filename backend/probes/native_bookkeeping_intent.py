"""Real Pi + real Com authorizer; mock bookkeeping touches only temporary memory."""
import argparse
import asyncio
import json
import os
import re
import sys
import tempfile
import uuid
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_tools import AgentTools
from conversation import PersonalConversation
from goals import GoalEvents
from pi_main import MAIN_PROMPT, PiMainClient
from tasks import TaskStore
from unified_voice import UnifiedVoice
from work_dispatch import WorkProposalStore


MOCK_EXTENSION = r'''
import { Type } from "typebox";
import { readFileSync } from "node:fs";
import { join } from "node:path";
export default function(pi:any) {
 pi.registerTool({name:"bookkeeping",label:"bookkeeping",
  description:"记账。add记录本条用户真实已发生开销，amount单位元，comment保留用途（兼容note别名）；成功后recent回查新增ID、金额和备注。recent只读返回最近记录。此隔离验收工具仅操作临时内存。",
  parameters:Type.Object({action:Type.Union([Type.Literal("add"),Type.Literal("recent")]),
   amount:Type.Optional(Type.Number()),comment:Type.Optional(Type.String()),note:Type.Optional(Type.String()),
   category:Type.Optional(Type.String()),currency:Type.Optional(Type.String()),limit:Type.Optional(Type.Number())}),
  async execute(id:string,args:any) {
   const token=readFileSync(join(process.env.COM_STATE!,"token"),"utf8").trim();
   const response=await fetch(process.env.COM_INTERNAL_URL+"/mock/bookkeeping",{
    method:"POST",headers:{Authorization:"Bearer "+token,"Content-Type":"application/json"},
    body:JSON.stringify({tool_call_id:id,args})});
   const result:any=await response.json();
   if(!response.ok) throw new Error(result.detail||"Mock bookkeeping rejected");
   return {content:[{type:"text",text:result.text}],details:result.details};
  }});
}
'''


async def run():
    with tempfile.TemporaryDirectory(prefix='com-bookkeeping-intent-') as directory:
        root = Path(directory)
        state = root / 'state'
        state.mkdir(mode=0o700)
        workspace = root / 'workspace'
        workspace.mkdir()
        token = uuid.uuid4().hex
        (state / 'token').write_text(token)
        (state / 'token').chmod(0o600)
        extension = root / 'mock-bookkeeping.ts'
        extension.write_text(MOCK_EXTENSION)
        ledger = []
        authorizations = {}
        trace = []
        denied = []
        registry = SimpleNamespace(observe=lambda *a, **k: None, search=lambda *a, **k: [])
        holder = {}

        async def serve(reader, writer):
            status = 200
            result = {}
            try:
                header = (await reader.readuntil(b'\r\n\r\n')).decode()
                if ('Authorization: Bearer ' + token).lower() not in header.lower():
                    raise ValueError('Invalid fixture token')
                length = next(int(line.split(':', 1)[1]) for line in header.split('\r\n') if line.lower().startswith('content-length:'))
                payload = json.loads(await reader.readexactly(length))
                route = header.split(' ', 2)[1]
                if route == '/mock/bookkeeping':
                    call_id, args = payload['tool_call_id'], payload['args']
                    authorization = authorizations.get(call_id)
                    if not authorization or authorization['args'] != args:
                        raise ValueError('Fixture tool has no genuine Com authorization')
                    action = args['action']
                    if action == 'add':
                        record = {'id': 9001 + len(ledger), 'amount': args['amount'],
                                  'comment': args.get('comment') or args.get('note') or '',
                                  'category': args.get('category') or '其他',
                                  'source_message_id': authorization['source_message_id']}
                        ledger.append(record)
                        result = {'text': f"已记账 #{record['id']} -¥{record['amount']:.2f} {record['category']} · {record['comment']}",
                                  'details': {key: record[key] for key in ('id', 'amount', 'category', 'comment')},
                                  'records': [record]}
                    else:
                        recent = ledger[-5:]
                        result = {'text': '\n'.join(f"#{record['id']} -¥{record['amount']:.2f} {record['category']} · {record['comment']}" for record in recent),
                                  'details': {}, 'records': recent}
                    trace.append({'action': action, 'call_id': call_id,
                                  'source_message_id': authorization['source_message_id'],
                                  'amount': args.get('amount'),
                                  'returned_ids': [r['id'] for r in result.get('records', [result.get('record')]) if r]})
                else:
                    name = route.rsplit('/', 1)[-1]
                    context, args = payload['context'], payload['args']
                    result = await holder['service'].call(name, args, context)
                    if name == 'authorize_tool':
                        authorizations[args['tool_call_id']] = {'source_message_id': context['origin_message_id'],
                                                               'args': args['args']}
            except Exception as exc:
                status = 400
                result = {'detail': str(exc)[:600]}
                denied.append({'route': route if 'route' in locals() else '', 'error': str(exc)[:600]})
            try:
                body = json.dumps(result, ensure_ascii=False).encode()
                writer.write(f'HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {len(body)}\r\n\r\n'.encode() + body)
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        server = await asyncio.start_server(serve, '127.0.0.1', 0)
        port = server.sockets[0].getsockname()[1]
        env = {**os.environ, 'COM_INTERNAL_URL': f'http://127.0.0.1:{port}'}
        argv = ['/usr/local/bin/pi', '--mode', 'rpc', '--provider', 'opencode-go',
                '--model', 'deepseek-v4.1-flash', '--no-context-files', '--no-extensions',
                '--no-skills', '--no-builtin-tools', '--extension', str(Path(__file__).resolve().parents[1] / 'com-pi.ts'),
                '--extension', str(extension), '--system-prompt', MAIN_PROMPT,
                '--session-dir', str(state / 'sessions')]
        native = PiMainClient(state, workspace, tools=False, argv=argv, env=env)
        conversation = PersonalConversation(state, native)
        store = TaskStore(state)
        holder['service'] = AgentTools(state, conversation, WorkProposalStore(state, workspace), store,
                                       SimpleNamespace(), registry, GoalEvents(state))
        legacy = SimpleNamespace(receipt=lambda request_id: None)
        voice = UnifiedVoice(conversation, legacy)
        cases = [
            ('original_spoken_expense', '买零食花费五十九块二毛二。', 59.22),
            ('explicit_spoken_amount_after_purpose', '记个账，午饭吃面花费三十二块五毛。', 32.50),
            ('capability_question', '你能记账吗？', None),
            ('quoted_expense', '朋友说“买零食花费五十九块二毛二”。解释这句话。', None),
        ]
        report = []
        try:
            for index, (label, utterance, expected) in enumerate(cases):
                request_id = 'native-intent-' + str(index) + '-' + uuid.uuid4().hex[:12]
                receipt = voice.submit(request_id, utterance, 'conversation')
                mid = receipt['message_id']
                before_ledger, before_trace = len(ledger), len(trace)
                await asyncio.wait_for(conversation.process_one(), 180)
                row = next(m for m in conversation.snapshot()['messages'] if m['id'] == mid)
                assert row['status'] == 'completed', label + ': native main turn did not complete'
                calls = trace[before_trace:]
                adds = [call for call in calls if call['action'] == 'add']
                reads = [call for call in calls if call['action'] == 'recent']
                if expected is None:
                    assert len(ledger) == before_ledger and not adds, label + ': added an unauthorized historical amount'
                else:
                    assert len(ledger) == before_ledger + 1 and len(adds) == 1, label + ': did not add exactly one fixture expense'
                    assert abs(ledger[-1]['amount'] - expected) < .000001, label + ': spoken amount was not exact'
                    assert ledger[-1]['comment'], label + ': missing expense purpose'
                    assert adds[0]['source_message_id'] == mid, label + ': tool source changed'
                    assert reads and ledger[-1]['id'] in reads[-1]['returned_ids'], label + ': no actual recent readback'
                    assert reads[-1]['source_message_id'] == mid, label + ': readback source changed'
                    receipts = voice.receipt(request_id)['action_receipts']
                    assert len(receipts) == 1 and receipts[0]['readback_verified'], label + ': UnifiedVoice receipt lacks actual verified readback'
                    assert receipts[0]['details']['id'] == ledger[-1]['id'], label + ': receipt ID changed'
                    reply = next(m for m in conversation.snapshot()['messages'] if m.get('parent_id') == mid)['text']
                    assert str(ledger[-1]['id']) in reply, label + ': final reply omitted actual record ID'
                    assert re.search(re.escape(str(expected).rstrip('0').rstrip('.')) + r'(?:0)?(?:元|\s|[，,。]|$)', reply), label + ': final reply omitted exact amount'
                    purpose_words = ('零食',) if label == 'original_spoken_expense' else ('午饭', '面')
                    assert all(word in ledger[-1]['comment'] and word in reply for word in purpose_words), label + ': final reply or record omitted actual purpose'
                assert store.list() == [], label + ': main expense incorrectly delegated'
                report.append({'case': label, 'voice_purpose': 'conversation', 'source_message_id': mid,
                               'native_delivery': row['delivery_state'], 'turn_completed': True,
                               'add_count': len(adds), 'recent_count': len(reads),
                               'exact_amount': expected, 'recent_id_verified': expected is not None,
                               'action_receipt_readback_verified': expected is not None,
                               'final_reply_id_amount_purpose_verified': expected is not None,
                               'source_ids_verified': all(call['source_message_id'] == mid for call in calls)})
            return {'ok': True, 'production_api_used': False, 'production_bookkeeping_loaded': False,
                    'builtin_tools': False, 'real_com_authorizer': True,
                    'ledger_storage': 'temporary memory fixture', 'same_native_session': True,
                    'cases': report, 'authorization_rejections': denied}
        finally:
            await native.stop()
            server.close()
            await server.wait_closed()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output')
    args = parser.parse_args()
    result = asyncio.run(run())
    if args.output:
        target = Path(args.output)
        target.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        target.chmod(0o600)
    print(json.dumps(result, ensure_ascii=False))
