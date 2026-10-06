"""Harmless real Com two-task continuity, steering, restart and cancellation check."""
import asyncio,json,time
from pathlib import Path
import httpx

async def main():
 state=Path.home()/'.session-workbench';headers={'Authorization':'Bearer '+(state/'token').read_text().strip()}
 key='hermes-task-check-'+str(int(time.time()))
 text='系统验收授权：帮我检查隔离验收 A，帮我检查隔离验收 B。两个受控任务由验收程序派发；主对话只回复“验收收到”，不要调用工具，不要再派发，不保存记忆。'
 async with httpx.AsyncClient(base_url='http://127.0.0.1:8650',headers=headers,timeout=30,trust_env=False) as c:
  for _ in range(30):
   try:
    if (await c.get('/health')).status_code==200:break
   except httpx.TransportError:pass
   await asyncio.sleep(1)
  async def post(path,body):
   r=await c.post(path,json=body)
   if r.is_error:print(json.dumps({'path':path,'error':r.json()}),flush=True)
   r.raise_for_status();return r.json()
  m=await post('/personal/conversation/messages',{'request_id':key+'-origin','text':text})
  tasks=[]
  for name in ('A','B'):
   body={'request_id':key+'-'+name,'agent':'hermes','sandbox':'danger-full-access','origin_session_id':'com-hermes-main','origin_message_id':m['message_id'],'origin_request_id':key+'-origin','source_quote':'帮我检查隔离验收 '+name,'relative_cwd':'work/工具与效率/会话工作台/verification','title':'隔离验收 '+name,
     'prompt':'只执行一次终端命令 python3 -c "import time; time.sleep(90); print(\'COM_TASK_'+name+'\')"，不用其他工具，不读写文件，不派发子任务。命令结束后检查待处理补充，用一句话返回本任务标记及最新补充标记。',
     'completion_condition':'实际命令完成并返回 COM_TASK_'+name+'；有新补充时明确返回新标记。'}
   tasks.append((await post('/personal/tasks/create',body))['task_id'])
  async def rows():return (await c.get('/personal/tasks')).json()['items']
  for _ in range(45):
   selected=[t for t in await rows() if t['id'] in tasks]
   if len(selected)==2 and all(t['status']=='running' for t in selected):break
   await asyncio.sleep(1)
  assert all(t['status']=='running' for t in selected),[(t['id'],t['status']) for t in selected]
  print(json.dumps({'stage':'two_running','tasks':tasks,'sessions':[t['session_id'] for t in selected]}),flush=True)
  await post('/personal/tasks/'+tasks[0]+'/input',{'request_id':key+'-steer','text':'补充条件：最终回复必须包含最新标记 COM_STEER_V2；无需读取或修改文件。'})
  chat=await post('/personal/conversation/messages',{'request_id':key+'-chat','text':'系统验收：后台继续运行，你只回复“主对话继续”，不要使用工具或记忆。'})
  for _ in range(50):
   messages=(await c.get('/personal/conversation')).json()['messages'];row=next(r for r in messages if r['id']==chat['message_id'])
   if row['status']=='completed':break
   await asyncio.sleep(1)
  assert row['status']=='completed',row['status']
  print(json.dumps({'stage':'main_continues','message_id':chat['message_id']}),flush=True)
  proc=await asyncio.create_subprocess_exec('launchctl','kickstart','-k','gui/'+str(__import__('os').getuid())+'/work.eddie.sessions');await proc.wait()
  for _ in range(30):
   try:
    if (await c.get('/health')).status_code==200:break
   except httpx.TransportError:pass
   await asyncio.sleep(1)
  await post('/personal/tasks/'+tasks[1]+'/cancel',{'request_id':key+'-cancel'})
  for _ in range(150):
   selected=[t for t in await rows() if t['id'] in tasks]
   if all(t['status'] in ('execution_finished','failed','cancelled') for t in selected):break
   await asyncio.sleep(1)
  final=[]
  for t in selected:
   final.append({'id':t['id'],'status':t['status'],'agent':t['agent'],'context_revision':t.get('context_revision'),'run_id':t.get('run_id'),'steer_consumed':any(i['state']=='delivered' for i in t.get('inputs',[])),'latest_marker_in_result':'COM_STEER_V2' in t.get('result','')})
  messages=(await c.get('/personal/conversation')).json()['messages']
  receipts=[r for r in messages if r.get('parent_id')==m['message_id'] and r.get('role')=='assistant']
  print(json.dumps({'stage':'finished','tasks':final,'original_message_receipts':len(receipts)},ensure_ascii=False),flush=True)
  assert next(t for t in final if t['id']==tasks[0])['steer_consumed']
  assert next(t for t in final if t['id']==tasks[0])['latest_marker_in_result']
  assert next(t for t in final if t['id']==tasks[1])['status']=='cancelled'
asyncio.run(main())
