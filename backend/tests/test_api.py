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
