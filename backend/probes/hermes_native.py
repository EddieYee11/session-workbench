import asyncio,json,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from hermes_runtime import HermesRuntime
async def main():
    state=Path.home()/'.session-workbench'
    sid='com-verification-'+str(int(time.time()))
    client=HermesRuntime(state,sid)
    result=[]
    async for event,data in client.stream('这是隔离验收。使用 terminal 工具执行 printf COM_HERMES_TOOL_OK，并回复执行结果。不要调用业务工具，不读取个人文件，不创建任务。','verification-'+sid):
        if event.startswith('tool.') or event in ('error','assistant.completed','run.completed'):result.append({'event':event,'data':data})
    print(json.dumps({'session_id':sid,'events':result},ensure_ascii=False))
asyncio.run(main())
