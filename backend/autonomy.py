"""Explicit approved personal mandate, scoped durable operations and undo."""
import hashlib,json,sqlite3,time
from pathlib import Path
from business_tools import BusinessTools
from calendar_bridge import CalendarBridge
MANDATE='com-hermes-personal-20261005'
class PersonalAutonomy:
 def __init__(self,state,hub):
  self.state,self.hub=Path(state),hub
 def enabled(self):
  try:return json.loads((self.state/'agent-config.json').read_text()).get('personal_autonomy',{}).get('mandate_id')==MANDATE
  except (OSError,ValueError):return False
 async def call(self,tool,args,reason,request_id):
  if not self.enabled():raise ValueError('Personal autonomy is disabled')
  if not reason.strip() or len(reason)>2000:raise ValueError('A contextual reason is required')
  if not 10<=len(request_id)<=100:raise ValueError('A durable action ID is required')
  if tool not in ('remind','calendar_create','calendar_adjust'):raise ValueError('Outside the approved personal mandate')
  if tool=='remind' and args.get('action') not in ('add','cancel'):raise ValueError('Unsupported personal reminder action')
  b=BusinessTools(self.state)
  if tool=='calendar_adjust':
   b.execute=lambda _tool,params:CalendarBridge().adjust(params['event'],params['start'],params['end'])
   params={'action':'adjust',**args}
  elif tool=='calendar_create':
   original=b.execute
   async def checked_create(_tool,_params):
    await self.check_calendar_slot(args)
    return await original(_tool,_params)
   b.execute=checked_create
   params={'action':'create',**args}
  else:params=args
  # A schedule occurrence / matter revision identifies each action, not model prose.
  result=await b.call('remind' if tool=='remind' else 'calendar_event',params,{'origin_request_id':MANDATE+':'+request_id})
  ident=result.get('operation_id') or hashlib.sha256((MANDATE+':'+request_id+':'+json.dumps(['remind' if tool=='remind' else 'calendar_event',params],sort_keys=True,ensure_ascii=False)).encode()).hexdigest()
  with self.hub.db() as db:
   db.execute('CREATE TABLE IF NOT EXISTS personal_actions(id TEXT PRIMARY KEY,data TEXT)')
   db.execute('INSERT OR IGNORE INTO personal_actions VALUES(?,?)',(ident,json.dumps({'id':ident,'tool':tool,'reason':reason,'args':args,'result':result,'mandate':MANDATE,'created_at':time.time()},ensure_ascii=False)))
  return {**result,'operation_id':ident,'reason':reason}
 async def check_calendar_slot(self,args):
   from datetime import datetime,timedelta
   from zoneinfo import ZoneInfo
   start=datetime.fromisoformat(args['date']).replace(hour=int(args.get('hour',9)),minute=int(args.get('minute',0)),tzinfo=ZoneInfo('Asia/Shanghai'))
   end=start+timedelta(minutes=int(args.get('duration_minutes',60)))
   if args.get('all_day'):start=start.replace(hour=0,minute=0);end=start+timedelta(days=1)
   events=await CalendarBridge().read(start.date().isoformat(),end.date().isoformat())
   if any(e.get('availability')!=1 and datetime.fromisoformat(e['start'])<end and datetime.fromisoformat(e['end'])>start for e in events):raise ValueError('个人安排时间冲突；保留原安排并选择空闲时间')
 def list(self):
  with self.hub.db() as db:
   db.execute('CREATE TABLE IF NOT EXISTS personal_actions(id TEXT PRIMARY KEY,data TEXT)')
   return [json.loads(r[0]) for r in db.execute('SELECT data FROM personal_actions ORDER BY rowid DESC LIMIT 100')]
 async def undo(self,ident,request_id):
  row=next((r for r in self.list() if r['id']==ident),None)
  if not row:raise ValueError('Action not found')
  undo=row['result'].get('undo')
  if row['tool']=='calendar_create':
   b=BusinessTools(self.state)
   b.execute=lambda _tool,_params:CalendarBridge().undo_created(row['result'].get('item'),ident)
   result=await b.call('calendar_event',{'action':'undo_created','creation_operation_id':ident},{'origin_request_id':MANDATE+':undo:'+request_id})
   with self.hub.db() as db:
    row['undone']=result.get('verified',False);row['undo_result']=result
    db.execute('UPDATE personal_actions SET data=? WHERE id=?',(json.dumps(row,ensure_ascii=False),ident))
   return result
  if row['tool']=='calendar_adjust' and undo:
   result=await self.call('calendar_adjust',undo,'撤销个人安排调整',request_id);return self.mark_undo(row,result)
  if row['tool']=='remind' and row['args'].get('action')=='add':
   result=await self.call('remind',{'action':'cancel','id':row['result'].get('id')},'撤销个人提醒',request_id);return self.mark_undo(row,result)
  raise ValueError('此操作没有可验证的自动撤销入口；请引用回执明确交办')

 def mark_undo(self,row,result):
  row["undone"]=result.get("verified",False);row["undo_result"]=result
  with self.hub.db() as db:db.execute("UPDATE personal_actions SET data=? WHERE id=?",(json.dumps(row,ensure_ascii=False),row["id"]))
  return result
