import asyncio
import json
import time
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from pi_rpc import PiRPC
from rayneo import RayneoIngress
from test_pi_safety import tool_service


def test_glasses_prompt_excludes_historical_task_payload_without_losing_source(tmp_path):
    tools,ctx=tool_service(tmp_path,'查最近一笔账目')
    chat=tools.conversation
    chat.task_context=lambda:[{'id':'old-task','status':'execution_finished','prompt':'旧工程细节'*10000}]
    chat.task_environment=lambda:{'current_date':'2026-10-04','timezone':'Asia/Shanghai'}
    chat.client=SimpleNamespace(has_native_history=True)
    RayneoIngress(tmp_path,chat,SimpleNamespace())
    with chat.db() as db:
        db.execute('INSERT INTO rayneo_requests VALUES (?,?,?,?)',(ctx['origin_request_id'],'fixture','查账',time.time()))
        row=dict(db.execute('SELECT * FROM messages WHERE id=?',(ctx['origin_message_id'],)).fetchone())
    text,source=chat._pi_input(row,ctx['origin_session_id'],'reaction-fixture')
    assert len(text)<2000
    assert '旧工程细节' not in text and source['tasks']==[{'id':'old-task','status':'execution_finished'}]
    assert source['origin_request_id']==ctx['origin_request_id'] and source['origin_message_id']==ctx['origin_message_id']
    assert source['environment']['timezone']=='Asia/Shanghai'


def test_native_compaction_only_above_threshold_and_without_replaying_prompts(tmp_path):
    async def run():
        rpc=PiRPC(tmp_path,'fixture',tmp_path)
        commands=[]
        async def request(command,timeout=20):
            commands.append(command)
            return {'data':{'contextUsage':{'tokens':760000}}} if command['type']=='get_session_stats' else {'data':{'estimatedTokensAfter':18000}}
        rpc.request=request
        await rpc.compact_glasses_context()
        assert [c['type'] for c in commands]==['get_session_stats','compact']
        assert '不执行或重放' in commands[1]['customInstructions']
        records=[json.loads(l) for l in rpc.events.read_text().splitlines()]
        assert records[-1]['estimated_tokens_after']==18000
        commands.clear()
        async def small(command,timeout=20):
            commands.append(command);return {'data':{'contextUsage':{'tokens':18000}}}
        rpc.request=small
        await rpc.compact_glasses_context()
        assert [c['type'] for c in commands]==['get_session_stats']
    asyncio.run(run())
