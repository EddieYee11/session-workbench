"""Verify real Hermes tool-written, source-versioned briefing advice."""
import asyncio,json,time
from pathlib import Path
import httpx
async def main():
 state=Path.home()/'.session-workbench';key='com-briefing-'+str(int(time.time()))
 async with httpx.AsyncClient(base_url='http://127.0.0.1:8650',headers={'Authorization':'Bearer '+(state/'token').read_text().strip()},timeout=30,trust_env=False) as c:
  for _ in range(30):
   try:
    if (await c.get('/health')).status_code==200:break
   except httpx.TransportError:pass
   await asyncio.sleep(1)
  cards=(await c.get('/personal/briefing')).json()['cards'];assert cards
  target=cards[0]
  text='简报工具验收：先调用 personal_briefing，找到事项 '+target['id']+'，再通过 briefing_annotate 用准确 source_version 为它保存“发生了什么、为何相关、下一步”。仅依据已有事实和用户纠正；未知执行结果建议核实回执与原对象，禁止重放写入。只改这张卡片的建议，不执行业务操作，不派任务，不保存个人记忆。'
  r=await c.post('/personal/conversation/messages',json={'request_id':key,'text':text});r.raise_for_status();mid=r.json()['message_id']
  for _ in range(120):
   data=(await c.get('/personal/conversation')).json();row=next(r for r in data['messages'] if r['id']==mid)
   if row['status'] in ('completed','failed','unknown'):break
   await asyncio.sleep(1)
  assert row['status']=='completed'
  cards=(await c.get('/personal/briefing')).json()['cards'];updated=next(r for r in cards if r['id']==target['id'])
  assert updated.get('assistant_suggestion') and updated['facts']==target['facts']
  print(json.dumps({'request_id':key,'message_id':mid,'status':row['status'],'hermes_suggestion_saved':True,'source_facts_preserved':True,'card_count':len(cards),'source_version':updated['source_version']},ensure_ascii=False))
asyncio.run(main())
