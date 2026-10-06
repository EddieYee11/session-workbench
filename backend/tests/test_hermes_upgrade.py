import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import asyncio,json
import pytest
from memory_catalog import MemoryCatalog
from business_tools import BusinessTools
from device_nodes import DeviceNodes
from personal_hub import PersonalHub

def test_memory_correction_removes_old_active_context_and_preserves_history(tmp_path):
 c=MemoryCatalog(tmp_path);source={'message_id':'human-1','quote':'我喜欢白色'}
 a=c.save('喜欢白色','兴趣',source)
 b=c.save('喜欢灰色','兴趣',{'message_id':'human-2','quote':'改成灰色'},a['id'],expected_version=1)
 assert b['version']==2 and b['history'][0]['content']=='喜欢白色'
 assert c.context()[0]['content']=='喜欢灰色' and len(c.list())==1
 with pytest.raises(ValueError):c.save('喜欢黑色','兴趣',source,a['id'],expected_version=1)
 c.save('喜欢灰色','兴趣',source,a['id'],expected_version=2,archived=True)
 assert c.context()==[]

def test_business_write_deduplicates_and_uncertainty_never_replays(tmp_path):
 async def run():
  b=BusinessTools(tmp_path);calls=[]
  async def execute(tool,args):calls.append(args);return {'verified':True,'operation_id':args['_operation_id'],'id':'fixture'}
  b.execute=execute
  a=await b.call('remind',{'action':'add','title':'测试'},{'origin_request_id':'real-user'})
  duplicate=await b.call('remind',{'action':'add','title':'测试'},{'origin_request_id':'real-user'})
  assert len(calls)==1 and duplicate['duplicate'] and a['operation_id']==duplicate['operation_id']
  async def uncertain(*args):raise TimeoutError()
  b.execute=uncertain
  with pytest.raises(TimeoutError):await b.call('remind',{'action':'add','title':'另一个'},{'origin_request_id':'real-user'})
  with pytest.raises(ValueError,match='uncertain'):await b.call('remind',{'action':'add','title':'另一个'},{'origin_request_id':'real-user'})
 asyncio.run(run())

def test_device_permission_offline_duplicate_and_late_result(tmp_path):
 async def run():
  nodes=DeviceNodes(tmp_path);node='node_'+'a'*32
  nodes.register({'id':node,'capabilities':[{'tool':'device.status','permission':True},{'tool':'health.summary','permission':False}]})
  a=await nodes.call(node,'device.status',{},'invocation-offline-001')
  assert a['status']=='offline'
  class Socket:
   async def send_json(self,row):await nodes.result(node,{'id':row['id'],'type':'ack'});await nodes.result(node,{'id':row['id'],'type':'result','status':'succeeded','result':{'battery':60}})
  nodes.sockets[node]=Socket()
  denied=await nodes.call(node,'health.summary',{},'invocation-denied-001');assert denied['status']=='permission_denied'
  a=await nodes.call(node,'device.status',{},'invocation-online-001');assert a['result']['battery']==60
  b=await nodes.call(node,'device.status',{},'invocation-online-001');assert b['duplicate']
  with pytest.raises(ValueError):await nodes.call(node,'device.status',{'changed':True},'invocation-online-001')
 asyncio.run(run())

def test_matter_feedback_survives_restart_and_same_thread_is_updated(tmp_path):
 hub=PersonalHub(tmp_path,home=tmp_path)
 a=hub.matter('gmail','thread1','会议邮件',{'message':'m1'})
 hub.feedback(a['id'],'handled','feedback001')
 b=hub.matter('gmail','thread1','会议回复',{'message':'m2'})
 hub=PersonalHub(tmp_path,home=tmp_path)
 assert len(hub.matters())==1 and b['id']==a['id'] and hub.matters()[0]['facts']['message']=='m2'
 assert hub.briefing()['cards']==[]

def test_matter_correction_persists_through_source_sync_and_other_feedback(tmp_path):
 h=PersonalHub(tmp_path,home=tmp_path);r=h.matter('gmail','t','事项',{'snippet':'来源原话'})
 h.feedback(r['id'],'correct','correction-001','以我的新说明为准')
 h.feedback(r['id'],'follow','follow-001')
 h.matter('gmail','t','新回复',{'snippet':'新来源'})
 card=PersonalHub(tmp_path,home=tmp_path).briefing()['cards'][0]
 assert card['user_correction']['text']=='以我的新说明为准'
 assert card['facts']['snippet']=='新来源'

def test_dead_executor_unknown_result_releases_slot_without_replay(tmp_path):
 from tasks import TaskStore,TaskController
 async def run():
  store=TaskStore(tmp_path)
  task={'id':'dead','agent':'pi','cwd':str(tmp_path),'title':'旧账目','status':'unknown','session_id':'pi:dead','run_id':'old-run','constraints':[]}
  with store.db() as d:d.execute('INSERT INTO tasks VALUES(?,?)',('dead',json.dumps(task)))
  class Runtime:
   async def task_execution_active(self,task):return False
   def can_reconcile_task(self,task):return False
  class Conversation:
   def task_receipt(self,*_):pass
  await TaskController(store,Runtime(),Conversation()).poll()
  assert store.list()[0]['status']=='unknown' and store.list()[0]['execution_active'] is False
 asyncio.run(run())

def test_gmail_pages_incremental_ids_and_new_reply_updates_original_thread(tmp_path):
 async def run():
  h=PersonalHub(tmp_path,home=tmp_path);calls=[]
  async def gws(service,*path,params):
   calls.append((path,params))
   if path[-1]=='list':return {'messages':[{'id':'m1' if params.get('pageToken') else 'm2'}],**({} if params.get('pageToken') else {'nextPageToken':'page2'})}
   mid=params['id'];return {'id':mid,'threadId':'thread','internalDate':'2000' if mid=='m2' else '1000','payload':{'headers':[{'name':'Subject','value':'reply-'+mid}]},'snippet':mid}
  h.gws=gws
  first=await h.sync_source('gmail');second=await h.sync_source('gmail')
  assert first['count']==2 and first['updated_count']==2 and second['updated_count']==0
  assert len(h.matters())==1 and h.matters()[0]['facts']['message_id']=='m2'
  assert len([c for c in calls if c[0][-1]=='get'])==2
 asyncio.run(run())


def test_native_hermes_reaction_keeps_real_turn_binding(tmp_path):
 from conversation import PersonalConversation
 from reactions import ReactionStore
 c=PersonalConversation(tmp_path)
 m=c.submit('native-hermes-reaction-test','测试本轮来源')
 with c.db() as db:
  db.execute("INSERT INTO meta VALUES('hermes_v2_session_id','com-hermes-main')")
  db.execute("UPDATE messages SET status='sending' WHERE id=?",(m['message_id'],))
 token=ReactionStore(tmp_path).open_turn(m['message_id'],'com-hermes-main')
 assert ReactionStore(tmp_path).react(m['message_id'],token,'👍')['reaction']['emoji']=='👍'


def test_consumed_steer_is_proven_by_native_transcript_not_queue_ack(tmp_path):
 from hermes_runtime import HermesRuntime
 async def run():
  w=HermesRuntime(tmp_path,'isolated');w.run_id='run_fixture';calls=[]
  async def request(method,path,body=None):
   calls.append((method,path,body))
   return {'accepted':True} if method=='POST' else {'data':[]}
  w.request=request
  result=await w.steer('新约束','supplement-001')
  assert result['state']=='worker_queued' and 'supplement-001' not in w.delivered
  await w.steer('新约束','supplement-001');assert sum(c[0]=='POST' for c in calls)==1
  async def consumed(*_):return {'data':[{'role':'user','content':'[Com supplement supplement-001]\n新约束'}]}
  w.request=consumed;await w.reconcile_steering()
  assert 'supplement-001' in w.delivered
 asyncio.run(run())


def test_phone_health_null_and_calendar_occurrences_stay_source_grounded(tmp_path):
 h=PersonalHub(tmp_path,home=tmp_path)
 h.ingest_phone({'id':'inv_1','node':'node_fixture','tool':'health.summary','result':{'start':'2026-10-01','end':'2026-10-05','steps':None,'missing_reason':'无可读数据'}})
 h.ingest_phone({'id':'inv_2','node':'node_fixture','tool':'health.summary','result':{'start':'2026-10-01','end':'2026-10-05','steps':12}})
 assert len(h.matters())==1 and h.matters()[0]['facts']['steps']==12
 h.ingest_phone({'id':'inv_3','node':'node_fixture','tool':'calendar.list','result':{'items':[{'event_id':'original-id','begin':1791244800000,'end':1791248400000,'title':'原始事件'}]}})
 assert len(h.matters())==2 and h.briefing()['max_cards']==5


def test_calendar_cache_uses_occurrence_start_not_decades_old_master(tmp_path):
 import sqlite3
 from datetime import datetime
 from zoneinfo import ZoneInfo
 from calendar_bridge import CalendarBridge
 p=tmp_path/'Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb';p.parent.mkdir(parents=True)
 epoch=978307200;tz=ZoneInfo('Asia/Shanghai')
 stamp=lambda x:datetime.fromisoformat(x).replace(tzinfo=tz).timestamp()-epoch
 with sqlite3.connect(p) as d:
  d.executescript('CREATE TABLE Calendar(title TEXT);INSERT INTO Calendar VALUES("日历");CREATE TABLE CalendarItem(UUID TEXT,summary TEXT,description TEXT,all_day INT,availability INT,has_attendees INT,has_recurrences INT,start_tz TEXT,calendar_id INT,start_date REAL,end_date REAL,hidden INT,status INT);CREATE TABLE Participant(owner_id INT);CREATE TABLE OccurrenceCache(event_id INT,occurrence_date REAL,occurrence_start_date REAL,occurrence_end_date REAL);')
  d.execute('INSERT INTO CalendarItem VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',('id-real','生日','',1,0,0,1,'_float',1,stamp('1994-08-27'),stamp('1994-08-28'),0,0))
  d.execute('INSERT INTO OccurrenceCache VALUES(?,?,?,?)',(1,stamp('2027-08-27'),None,stamp('2027-08-28')))
 assert CalendarBridge(tmp_path).cached('2026-10-01','2026-10-31')==[]
 rows=CalendarBridge(tmp_path).cached('2027-08-27','2027-08-27')
 assert len(rows)==1 and rows[0]['start']=='2027-08-27T00:00+08:00'

def test_linked_matters_keep_source_facts_corrections_and_handled_state(tmp_path):
 h=PersonalHub(tmp_path,home=tmp_path)
 a=h.matter('gmail','thread','会议邮件',{'snippet':'原始邮件'})
 b=h.matter('apple_calendar','event','会议安排',{'start':'2099-01-01T10:00:00+08:00'})
 h.feedback(b['id'],'correct','correct-grouped001','会议地点以新通知为准')
 h.link(a['id'],[b['id']],'邮件明确引用同一次会议')
 card=h.briefing()['cards'][0]
 assert len(h.briefing()['cards'])==1 and card['facts']['snippet']=='原始邮件'
 assert card['action_context']['related_facts'][0]['feedback']['correction']['text']=='会议地点以新通知为准'
 assert card['grouping']['kind']=='assistant_inference'
 h.feedback(a['id'],'handled','handled-grouped001')
 assert PersonalHub(tmp_path,home=tmp_path).briefing()['cards']==[]
 h.unlink(a['id'])
 assert h.briefing()['cards'][0]['id']==b['id']

def test_briefing_suggestion_expires_when_sources_or_corrections_change(tmp_path):
 h=PersonalHub(tmp_path,home=tmp_path);r=h.matter('gmail','thread','来源标题',{'snippet':'原始内容'})
 c=h.briefing()['cards'][0];h.annotate(r['id'],c['source_version'],'新回复到了','需要你确定时间','核对时间后安排日程')
 c=h.briefing()['cards'][0]
 assert c['what']=='新回复到了' and c['facts']['snippet']=='原始内容' and c['assistant_suggestion']['kind']=='assistant_suggestion'
 h.feedback(r['id'],'correct','correct-advice001','这件事已经改期')
 assert 'assistant_suggestion' not in h.briefing()['cards'][0]
 with pytest.raises(ValueError,match='事项已变化'):h.annotate(r['id'],c['source_version'],'旧分析','旧理由','旧建议')
