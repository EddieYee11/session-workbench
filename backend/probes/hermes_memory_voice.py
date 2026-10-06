"""Actual approved Com UI preferences, memory correction and voice receipt routing."""
import asyncio,json,time
from pathlib import Path
import httpx
async def main():
 state=Path.home()/'.session-workbench';key='com-memory-voice-'+str(int(time.time()))
 async with httpx.AsyncClient(base_url='http://127.0.0.1:8650',headers={'Authorization':'Bearer '+(state/'token').read_text().strip()},timeout=30,trust_env=False) as c:
  for _ in range(30):
   try:
    if (await c.get('/health')).status_code==200:break
   except httpx.TransportError:pass
   await asyncio.sleep(1)
  async def post(path,data):
   r=await c.post(path,json=data);r.raise_for_status();return r.json()
  async def wait(mid):
   for _ in range(100):
    data=(await c.get('/personal/conversation')).json();row=next(m for m in data['messages'] if m['id']==mid)
    if row['status'] in ('completed','unknown','failed'):break
    await asyncio.sleep(1)
   assert row['status']=='completed',row['status']
   return '\n'.join(m['text'] for m in data['messages'] if m.get('parent_id')==mid)
  first=await post('/personal/conversation/messages',{'request_id':key+'-save','text':'请记住我的 Com 产品偏好：工作页保持原来的布局，全应用保持白灰配色，参考 Today 的图标和按钮形态，主聊天使用 Hermes。保存为项目记忆；不要改代码，不创建任务。'})
  await wait(first['message_id'])
  memories=(await c.get('/personal/memory')).json()['items'];r=next(m for m in memories if 'Com' in m['content'] and '布局' in m['content'])
  content='Com 产品偏好：工作页保持原来的页面布局；聊天、今天、任务、记忆及设置统一使用现代线条图标和圆角按钮；维持白灰配色，参考 Today 的按钮形态；主聊天名称及执行器为 Hermes，工作页保留 Pi、Codex、Claude 选择。'
  corrected=await post('/personal/memory/'+r['id'],{'request_id':key+'-correct','expected_version':r['version'],'content':content})
  query=await post('/personal/conversation/messages',{'request_id':key+'-recall','text':'我对 Com 的 UI 和主聊天执行器有哪些已保存的偏好？只回答记忆，不调用其他工具，不改文件。'})
  answer=await wait(query['message_id'])
  body={'request_id':key+'-voice','text':'系统语音回执验收：只回复“语音已到 Hermes”，不调用工具，不创建任务，不保存记忆。','purpose':'conversation'}
  voice=await post('/personal/quick-voice/messages',body);duplicate=await post('/personal/quick-voice/messages',body)
  assert voice['message_id']==duplicate['message_id'];await wait(voice['message_id'])
  receipt=(await c.get('/personal/quick-voice/receipts/'+key+'-voice')).json()
  latest=(await c.get('/personal/memory/'+r['id'])).json()
  print(json.dumps({'memory_id':r['id'],'version':latest.get('version'),'history_preserved':bool(latest.get('history')),'corrected_context_used':all(k in answer for k in ('Hermes','白灰','工作')),'voice_agent':receipt.get('agent'),'voice_status':receipt.get('status'),'voice_duplicate_same_message':True,'physical_microphone_tested':False},ensure_ascii=False))
  assert receipt['agent']=='hermes' and receipt['status']=='completed'
asyncio.run(main())
