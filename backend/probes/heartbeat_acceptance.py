import asyncio,json,urllib.request,sqlite3
from pathlib import Path
from heartbeat import Heartbeat
from tasks import TaskStore
from work_dispatch import WorkProposalStore
async def main():
 h=Path.home();s=h/'.session-workbench';tasks=TaskStore(s);proposals=WorkProposalStore(s,h/'AI_Work_System');hb=Heartbeat(s,h/'AI_Work_System',tasks,proposals)
 before=(len(tasks.list()),len(proposals.list()))
 assert hb.settings()['shadow']
 reports=[]
 for i in range(2):
  r=await hb.tick(reason='B2 live-model shadow acceptance '+str(i+1),force=True)
  assert not r.get('error') and r['shadow'] and r['effect']=='none'
  reports.append({'shadow':r['shadow'],'effect':r['effect'],'action':r['decision']['action'],'trigger':r['trigger'],'digest_bytes':len(r['digest'].encode())})
 assert before==(len(tasks.list()),len(proposals.list()))
 assert hb.shadow_verified()
 token=(s/'token').read_text().strip()
 def settings(changes):
  req=urllib.request.Request('http://127.0.0.1:8650/personal/heartbeat/settings',data=json.dumps(changes).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
  return json.load(urllib.request.urlopen(req))
 try:
  assert settings({'paused':True})['settings']['paused']
  assert (await hb.tick(force=True))['skipped']=='paused'
 finally:settings({'paused':False})
 assert hb.settings()['shadow']
 print(json.dumps({'ticks':reports,'task_proposal_counts_unchanged':before,'system_notifications':'no notification code path','pause_immediate':True,'shadow_verified':True,'limited_mode':'still OFF'},ensure_ascii=False,indent=2))
asyncio.run(main())
