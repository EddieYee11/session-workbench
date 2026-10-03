import os,sys,importlib,asyncio,json
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))

@pytest.fixture
def service(tmp_path,monkeypatch):
 monkeypatch.setenv('WORKBENCH_HOME',str(tmp_path));monkeypatch.setenv('WORKBENCH_STATE',str(tmp_path/'state'))
 import app
 app=importlib.reload(app)
 with TestClient(app.app) as client:yield app,client

def test_auth_pair_and_read_never_starts_agent(service,monkeypatch):
 app,c=service
 assert c.get('/sessions').status_code==401
 assert c.get('/health').status_code==200
 app.STATE.joinpath('pairing.json').write_text(json.dumps({'code':'sample-once','expires':9999999999}))
 assert c.post('/pair',json={'code':'wrong'}).status_code==403
 assert c.post('/pair',json={'code':'sample-once'}).status_code==200
 assert c.post('/pair',json={'code':'sample-once'}).status_code==403
 async def forbidden(*a,**k):raise AssertionError('read opened agent')
 monkeypatch.setattr(app.runtime,'create',forbidden)
 r=c.get('/sessions',headers={'Authorization':'Bearer '+app.TOKEN});assert r.status_code==200

def test_duplicate_delivery_and_unknown_never_replayed(service,monkeypatch):
 app,c=service;count=0
 async def create(*a,**k):
  nonlocal count
  count+=1;return 'pi:fixture'
 monkeypatch.setattr(app.runtime,'create',create)
 h={'Authorization':'Bearer '+app.TOKEN};data={'request_id':'test-request-001','agent':'pi','cwd':'/fixture'}
 a=c.post('/sessions',headers=h,json=data);b=c.post('/sessions',headers=h,json=data)
 assert a.json()==b.json();assert count==1
 assert c.post('/sessions',headers=h,json={**data,'cwd':'/different'}).status_code==409
 async def uncertain(*a,**k):
  nonlocal count
  count+=1;raise RuntimeError('transport lost')
 monkeypatch.setattr(app.runtime,'create',uncertain)
 data['request_id']='test-request-002'
 assert c.post('/sessions',headers=h,json=data).status_code==409
 r=c.post('/sessions',headers=h,json=data)
 assert r.json()['status']=='unknown';assert count==2
 assert c.get('/receipts/test-request-002',headers=h).json()['status']=='unknown'

def test_live_updates_have_same_identity(service):
 app,_=service
 events=[{'kind':'delta','id':'a','role':'assistant','text':'开始','time':1},{'kind':'delta','id':'a','role':'assistant','text':'检查','time':2},{'kind':'item','id':'a','role':'assistant','text':'开始检查','time':3}]
 assert app.live_items(events)==[{'id':'a','role':'assistant','title':'实时输出','text':'开始检查','time':3,'kind':'item'}]
 events=[{'type':'message_update','time':1,'data':{'message':{'role':'assistant','timestamp':123,'content':[{'type':'text','text':'流式内容'}]}}}]
 assert app.live_items(events)[0]['id']=='pi:123'


def test_manual_create_candidate_refusal_is_definite_not_unknown(service,monkeypatch):
 app,c=service
 monkeypatch.setattr(app,'MAIN_AGENT','pi')
 async def forbidden(*a,**k):raise AssertionError('Rejected request cannot start a worker')
 monkeypatch.setattr(app.runtime,'create_task_worker',forbidden)
 h={'Authorization':'Bearer '+app.TOKEN}
 data={'request_id':'manual-candidate-001','agent':'claude','cwd':str(app.HOME/'AI_Work_System'),'prompt':'最近不想折腾手机'}
 first=c.post('/sessions',headers=h,json=data).json()
 assert first['status']=='rejected' and first['submission_state']=='not_submitted'
 assert c.post('/sessions',headers=h,json=data).json()==first
 assert c.get('/receipts/manual-candidate-001',headers=h).json()==first
 assert app.task_store.list()==[]


def test_legacy_source_refusal_can_be_resolved_without_replaying(service):
 app,c=service
 rid='legacy-source-refusal-001'
 human=app.conversation.submit('work:'+rid,'旧交办')['message_id']
 app.conversation._finish(human,'failed',error='工作器未启动')
 result={'status':'unknown','request_id':rid,'error':'This message is not an explicit assignment; keep it as a candidate'}
 with app.history.db() as d:d.execute('INSERT INTO receipts VALUES(?,?,?)',(rid,'fixture',json.dumps(result)))
 r=c.get('/receipts/'+rid,headers={'Authorization':'Bearer '+app.TOKEN}).json()
 assert r['status']=='rejected' and r['submission_state']=='not_submitted'
 assert app.task_store.list()==[]
 assert c.get('/receipts/'+rid,headers={'Authorization':'Bearer '+app.TOKEN}).json()==r


def test_manual_preflight_failure_is_not_submitted(service,monkeypatch):
 app,c=service
 monkeypatch.setattr(app,'MAIN_AGENT','pi')
 async def session():return 'com-pi-main'
 monkeypatch.setattr(app.conversation,'_ensure_session',session)
 with app.conversation.db() as d:
  d.execute("INSERT OR REPLACE INTO meta VALUES ('pi_session_id','com-pi-main')")
  d.execute("INSERT OR REPLACE INTO meta VALUES ('hermes_session_id','com-pi-main')")
 project=app.HOME/'AI_Work_System'/'demo';project.mkdir(parents=True)
 async def unavailable(task):raise RuntimeError('executor unavailable')
 async def forbidden(task):raise AssertionError('preflight failure cannot create worker')
 monkeypatch.setattr(app.runtime,'preflight_task',unavailable)
 monkeypatch.setattr(app.runtime,'create_task_worker',forbidden)
 rid='manual-unavailable-001'
 r=c.post('/sessions',headers={'Authorization':'Bearer '+app.TOKEN},json={'request_id':rid,'agent':'claude','cwd':str(project),'prompt':'帮我修好项目配置','sandbox':'workspace-write'}).json()
 assert r['status']=='rejected' and r['submission_state']=='not_submitted'
 assert app.task_store.list()[0]['status']=='failed'
