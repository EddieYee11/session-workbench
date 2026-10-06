"""Controlled native reminder/calendar validation; removes only the created test objects."""
import asyncio,json,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from business_tools import BusinessTools
from personal_hub import PersonalHub
from autonomy import PersonalAutonomy
async def main():
 state=Path.home()/'.session-workbench';hub=PersonalHub(state);a=PersonalAutonomy(state,hub);key='verification-'+str(int(time.time()));out=[]
 reminder=await a.call('remind',{'action':'add','text':'Com Hermes 升级验收（待撤销）','in_minutes':300},'验证原提醒库写入与撤销',key+'-reminder')
 duplicate=await a.call('remind',{'action':'add','text':'Com Hermes 升级验收（待撤销）','in_minutes':300},'验证原提醒库写入与撤销',key+'-reminder')
 undone=await a.undo(reminder['operation_id'],key+'-reminder-undo')
 out.append({'tool':'remind','verified':reminder['verified'],'duplicate':duplicate.get('duplicate'),'undo_verified':undone['verified'],'operation_id':reminder['operation_id']})
 from calendar_bridge import CalendarBridge
 from datetime import datetime,timedelta
 from zoneinfo import ZoneInfo
 first=datetime.now(ZoneInfo('Asia/Shanghai'))+timedelta(days=10)
 args=None
 for days in range(15):
  date=(first+timedelta(days=days)).date().isoformat()
  candidate={'summary':'【验收】Com Hermes 可撤销日程','date':date,'hour':14,'minute':22,'duration_minutes':5,'alarm_minutes':0,'calendar':'日历'}
  try:await a.check_calendar_slot(candidate);args=candidate;break
  except ValueError:continue
 if not args:out.append({'tool':'calendar','status':'no_free_validation_slot'})
 else:
  try:
   event=await a.call('calendar_create',args,'验证苹果日历原 worker 写入与撤销',key+'-calendar')
   out.append({'tool':'calendar','verified':event.get('verified'),'operation_id':event['operation_id'],'event_id':event.get('id')})
   if event.get('verified'):
    duplicate=await a.call('calendar_create',args,'验证苹果日历原 worker 写入与撤销',key+'-calendar')
    current=event['item'];new_start=(datetime.fromisoformat(current['start'])+timedelta(minutes=10)).isoformat();new_end=(datetime.fromisoformat(current['end'])+timedelta(minutes=10)).isoformat()
    adjusted=await a.call('calendar_adjust',{'event':current,'start':new_start,'end':new_end},'验证已有个人日程调整与撤销',key+'-adjust')
    out[-1]['adjust_verified']=adjusted.get('verified')
    if adjusted.get('verified'):
     reverted=await a.undo(adjusted['operation_id'],key+'-adjust-undo');out[-1]['adjust_undo_verified']=reverted.get('verified')
    undo=await a.undo(event['operation_id'],key+'-calendar-undo');out[-1].update(duplicate=duplicate.get('duplicate'),undo_verified=undo.get('verified'))
  except Exception as e:out.append({'tool':'calendar','status':'requires_readback','error_type':type(e).__name__})
 print(json.dumps({'request_id':key,'results':out},ensure_ascii=False))
asyncio.run(main())
