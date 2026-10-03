"""Real third-party Claude SDK read/resume/write/interrupt probes, only temporary files."""
import asyncio
import json
import tempfile
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'backend'))
from claude_worker import ClaudeWorker,ClaudeBudget
from worker_runtime import WorkerRuntime

async def main():
    state=Path(tempfile.mkdtemp(prefix='com-claude-acceptance-'))
    (state/'agent-config.json').write_text(json.dumps({'claude_model':'deepseek-v4.1-flash'}))
    project=state/'project';project.mkdir();(project/'hello.txt').write_text('SDK_SESSION_READ_OK')
    budget=ClaudeBudget(state);events=[];results=[]
    task={'id':'native-read','cwd':str(project),'agent':'claude','sandbox':'read-only','automatic':False}
    def worker(task):
        return ClaudeWorker(state,task,events.append,budget,lambda tool,args:WorkerRuntime.guard(None,task,tool,args))
    first=worker(task)
    try:
        await first.start('请用 Read 读取 hello.txt，只回复其内容，保持只读。','read-001')
        await asyncio.wait_for(first.runner,150)
        assert first.status=='completed' and 'SDK_SESSION_READ_OK' in first.result,(first.status,first.result)
        assert any(e.get('tool_name')=='Read' for e in events)
        results.append({'case':'sdk-native-read','status':'passed'})
        session=first.native_session
        second=worker(task)
        await second.start('刚才读取的标记是什么？沿用当前会话，只回复标记。','resume-001')
        await asyncio.wait_for(second.runner,150)
        assert second.status=='completed' and 'SDK_SESSION_READ_OK' in second.result,(second.status,second.result)
        assert second.native_session==session
        results.append({'case':'sdk-session-resume-same-task-budget','status':'passed'})
        follow=worker({'id':'native-follow','cwd':str(project),'agent':'claude','sandbox':'read-only','automatic':False})
        await follow.start('请读取 hello.txt，回复标记。','follow-start-001')
        ack=await follow.steer('接下来回复标记 FOLLOWUP_DELIVERED_OK。','follow-more-001')
        assert ack['state']=='worker_queued' and 'follow-more-001' not in follow.delivered
        async def settle():
            while follow.status=='running':await asyncio.sleep(.1)
        await asyncio.wait_for(settle(),180)
        assert follow.status=='completed' and 'FOLLOWUP_DELIVERED_OK' in follow.result,(follow.status,follow.result)
        assert 'follow-more-001' in follow.delivered,events
        results.append({'case':'sdk-queued-input-confirmed-in-native-context','status':'passed'})
        copy=state/'copy';copy.mkdir()
        writable={'id':'native-write','cwd':str(project),'workspace_copy':str(copy),'agent':'claude','sandbox':'workspace-write','automatic':False}
        writer=worker(writable)
        await writer.start('请用 Write 在当前工作目录创建 result.txt，内容仅 SDK_WRITE_OK。不要执行命令。','write-001')
        await asyncio.wait_for(writer.runner,150)
        assert writer.status=='completed' and (copy/'result.txt').read_text().strip()=='SDK_WRITE_OK'
        assert not (project/'result.txt').exists()
        results.append({'case':'sdk-write-stays-in-isolated-copy','status':'passed'})
        stopper=worker({'id':'native-stop','cwd':str(project),'agent':'claude','sandbox':'read-only','automatic':False})
        await stopper.start('请详细解释 hello.txt 标记的每一个字符，并给出两百行只读分析。','stop-001')
        await asyncio.sleep(.2)
        await stopper.abort()
        await asyncio.wait_for(stopper.runner,40)
        assert stopper.status=='interrupted',stopper.status
        results.append({'case':'sdk-interrupt-confirmed-terminal','status':'passed'})
        report={'root':str(state),'cases':results,'usage_available':bool(first.usage and 'input_tokens' in first.usage and 'output_tokens' in first.usage),'amount_status':'unknown','production_side_effects':0}
        (state/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
        print(json.dumps(report,ensure_ascii=False,indent=2))
    finally:
        for name in ('first','second','writer','stopper','follow'):
            if name in locals():await locals()[name].stop()

if __name__=='__main__':asyncio.run(main())
