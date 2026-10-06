"""Real authenticated Com ingress checks; no fabricated ledger transactions."""
import asyncio,json,time
from pathlib import Path
import httpx
async def main():
 state=Path.home()/'.session-workbench';headers={'Authorization':'Bearer '+(state/'token').read_text().strip()}
 async with httpx.AsyncClient(base_url='http://127.0.0.1:8650',headers=headers,timeout=30,trust_env=False) as c:
  rid='com-hermes-check-'+str(int(time.time()))
  body={'request_id':rid,'text':'系统验收：请用直接业务工具查询最近1笔账目，回复找到的记录ID。只读，不要新增账目，不要创建后台任务，不保存个人记忆。'}
  a=await c.post('/personal/conversation/messages',json=body);a.raise_for_status();mid=a.json()['message_id']
  b=await c.post('/personal/conversation/messages',json=body);assert b.json()['message_id']==mid
  for _ in range(120):
   state=(await c.get('/personal/conversation')).json();row=next(r for r in state['messages'] if r['id']==mid)
   if row['status'] in ('completed','unknown','failed'):break
   await asyncio.sleep(1)
  replies=[r for r in state['messages'] if r.get('parent_id')==mid]
  # Return only verification metadata, not private expense detail.
  print(json.dumps({'request_id':rid,'message_id':mid,'status':row['status'],'run_id':row.get('run_id'),'tools':row.get('tasks',[]),'reply_received':bool(replies),'error':row.get('error')},ensure_ascii=False))
asyncio.run(main())
