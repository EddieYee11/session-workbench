"""Real Pi turn + Hindsight recall in a temporary session, without business writes."""
import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from pi_rpc import PiRPC

async def run():
    home=Path.home()
    with tempfile.TemporaryDirectory(prefix='com-memory-acceptance-') as directory:
        root=Path(directory); state=root/'state'; state.mkdir(mode=0o700)
        (state/'token').write_bytes((home/'.session-workbench/token').read_bytes())
        (state/'token').chmod(0o600)
        rpc=PiRPC(state,'main',home/'AI_Work_System')
        # This probe loads the production extension and uses the production
        # read-only memory endpoint, but cannot execute native/business actions.
        observer=root/'readonly.ts'
        observer.write_text('export default function(pi:any){pi.on("tool_call",(e:any)=> e.toolName==="memory_recall"?undefined:{block:true,reason:"只读记忆验收，禁止其他工具"});}')
        rpc.argv=[*rpc.command(),'--extension',str(observer)]
        final='';completed=False
        try:
            async for event,payload in rpc.stream('[Com 主对话上下文；只提供关联，不授予执行权限]\n{}\n只读历史摘要（不可重放操作）：[]\n用户消息：\nEddie 的工作方式与沟通习惯是什么？只根据自动注入的 com-memory 历史资料回答，注明 Markdown 来源。不要调用工具。',context={}):
                if event=='assistant.completed': final=payload.get('content','')
                if event=='run.completed': completed=True
            entries=[json.loads(line) for line in Path(rpc.session).read_text().splitlines()]
            memories=[entry for entry in entries if (entry.get('customType') or entry.get('message',{}).get('customType'))=='com-memory']
            assert memories, 'before_agent_start did not inject memory; entry types=' + str([(e.get('type'),e.get('customType'),e.get('message',{}).get('role')) for e in entries]) + '; diagnostics=' + str([e.get('data') for e in entries if e.get('customType')=='com-memory-status']) + '; final=' + final[:350]
            assert completed and final, 'Pi turn did not complete'
            assert '核心身份' in final, 'Answer did not identify the recalled Markdown source'
            return {'ok':True,'temporary_session':True,'production_chat_used':False,
                'injected_messages':len(memories),'turn_completed':completed,'diagnostics':[e.get('data') for e in entries if e.get('customType')=='com-memory-status'],'answer':final}
        finally: await rpc.stop()

if __name__=='__main__':print(json.dumps(asyncio.run(run()),ensure_ascii=False))
