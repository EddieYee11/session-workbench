import os,sys,importlib,asyncio,json,hashlib
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


def test_old_pi_manual_resume_and_send_are_not_forced_readonly(service,monkeypatch):
 app,c=service;monkeypatch.setattr(app,'MAIN_AGENT','pi')
 sid='pi:legacy-user-session';h={'Authorization':'Bearer '+app.TOKEN}
 session={'id':sid,'agent':'pi','native_id':'legacy-user-session','cwd':str(app.HOME),'path':'unused'}
 monkeypatch.setattr(app.history,'get',lambda value:dict(session) if value==sid else None)
 monkeypatch.setattr(app.history,'messages',lambda value:[])
 calls=[]
 async def resumable(value):return True
 async def create(agent,cwd,**options):
  calls.append(('create',options))
  app.history.save_managed(sid,{'agent':'pi','native_id':session['native_id'],'cwd':cwd,'ended':False,'tmux':'fixture','sandbox':options['sandbox']})
  return sid
 async def send(value,text,request_id,*args):calls.append(('input',text));return request_id
 async def identity(value):assert value==sid
 monkeypatch.setattr(app.runtime,'resumable',resumable)
 monkeypatch.setattr(app.runtime,'create',create)
 monkeypatch.setattr(app.runtime,'input',send)
 monkeypatch.setattr(app.runtime,'check_input_identity',identity)
 monkeypatch.setattr(app.runtime,'events',lambda value:[])
 result=c.post('/sessions/'+sid+'/resume',headers=h,json={'request_id':'resume-old-pi-user-001'})
 assert result.status_code==200,result.text
 assert calls[0][1]['sandbox']=='danger-full-access'
 result=c.post('/sessions/'+sid+'/input',headers=h,json={'request_id':'input-old-pi-user-001','text':'帮我继续处理这个项目'})
 assert result.status_code==200,result.text
 assert len(calls)==2 and calls[1][0]=='input'


def manual_native_contract(app,monkeypatch):
 """Only replace native transport; exercise real HTTP source and ledger checks."""
 monkeypatch.setattr(app,'MAIN_AGENT','pi')
 with app.conversation.db() as db:
  db.execute("INSERT OR REPLACE INTO meta VALUES ('pi_session_id','com-pi-main')")
  db.execute("INSERT OR REPLACE INTO meta VALUES ('hermes_session_id','com-pi-main')")
 async def session():return 'com-pi-main'
 monkeypatch.setattr(app.conversation,'_ensure_session',session)
 calls={'preflight':[],'create':[],'input':[],'identity':[]}
 async def preflight(task):calls['preflight'].append(task)
 async def create(task):
  calls['create'].append(task)
  sid=task['agent']+':manual-contract'
  app.history.save_managed(sid,{'agent':task['agent'],'native_id':'manual-contract',
   'task_id':task['id'],'transport':'claude-agent-sdk' if task['agent']=='claude' else 'codex-app-server',
   'cwd':task['cwd'],'sandbox':task['sandbox'],'ended':False})
  return sid
 async def send(sid,text,request_id,model=None,effort=None):
  calls['input'].append({'sid':sid,'text':text,'request_id':request_id,'model':model,'effort':effort})
  return 'turn-'+request_id
 async def identity(sid):
  assert sid in app.history.managed()
  calls['identity'].append(sid)
 async def status(task):return 'running'
 async def background_rpc():return None
 monkeypatch.setattr(app.runtime,'preflight_task',preflight)
 monkeypatch.setattr(app.runtime,'create_task_worker',create)
 monkeypatch.setattr(app.runtime,'input',send)
 monkeypatch.setattr(app.runtime,'check_input_identity',identity)
 monkeypatch.setattr(app.runtime,'task_status',status)
 monkeypatch.setattr(app.runtime,'events',lambda sid:[])
 monkeypatch.setattr(app.runtime,'ensure_rpc',background_rpc)
 return calls


@pytest.mark.parametrize('agent',['claude','codex'])
@pytest.mark.parametrize('sandbox',['danger-full-access','workspace-write','read-only'])
def test_manual_work_normal_chat_uses_selected_agent_and_ui_permissions_once(service,monkeypatch,agent,sandbox):
 app,c=service;calls=manual_native_contract(app,monkeypatch)
 project=app.HOME/'AI_Work_System'/'demo';project.mkdir(parents=True)
 h={'Authorization':'Bearer '+app.TOKEN}
 data={'request_id':'manual-normal-chat-001','agent':agent,'cwd':str(project),
       'prompt':'最近不想折腾手机','sandbox':sandbox,'model':'ui-selected-model','effort':'high'}
 response=c.post('/sessions',headers=h,json=data)
 assert response.status_code==200,response.text
 first=response.json()
 assert first['status']=='accepted' and first['submission_state']=='submitted'
 assert first['sid'].startswith(agent+':')
 assert c.post('/sessions',headers=h,json=data).json()==first
 assert c.get('/receipts/'+data['request_id'],headers=h).json()==first
 assert len(calls['preflight'])==len(calls['create'])==len(calls['input'])==1
 task=app.task_store.list()[0]
 assert task['status']=='running' and task['interactive'] and not task['automatic']
 assert task['agent']==agent and task['sandbox']=='danger-full-access' and task['cwd']==str(project)
 assert task['requested_sandbox']==sandbox
 assert calls['create'][0]['sandbox']=='danger-full-access'
 assert task['selected_model']=='ui-selected-model' and task['selected_effort']=='high'
 assert task['authorization']['entry']=='work_page_human_chat'
 assert task['authorization']['source_quote']==data['prompt']
 with app.conversation.db() as db:
  source=db.execute("SELECT role,text,request_id FROM messages WHERE id=?",(task['origin_message_id'],)).fetchone()
 assert tuple(source)==('user',data['prompt'],'work:'+data['request_id'])
 assert task['authorization']['source_message_id']==task['origin_message_id']
 assert calls['input'][0]['request_id']==data['request_id'] and data['prompt'] in calls['input'][0]['text']
 assert calls['input'][0]['model']=='ui-selected-model' and calls['input'][0]['effort']=='high'
 assert c.post('/sessions',headers=h,json={**data,'prompt':'不同消息'}).status_code==409
 assert len(calls['create'])==len(calls['input'])==1


@pytest.mark.parametrize('agent',['claude','codex'])
@pytest.mark.parametrize('empty_ui_fields',[False,True])
def test_finished_interactive_chat_continues_same_worker_without_task_acceptance(service,monkeypatch,agent,empty_ui_fields):
 app,c=service;calls=manual_native_contract(app,monkeypatch)
 project=app.HOME/'AI_Work_System'/'demo';project.mkdir(parents=True)
 h={'Authorization':'Bearer '+app.TOKEN}
 defaults={'model':'','effort':''} if empty_ui_fields else {}
 first=c.post('/sessions',headers=h,json={'request_id':'manual-first-chat-001','agent':agent,
  'cwd':str(project),'prompt':'你好','sandbox':'danger-full-access',**defaults}).json()
 assert first['status']=='accepted',first
 task=app.task_store.list()[0]
 app.task_store.finish(task['id'],'execution_finished','你好，真实回合已结束。')
 ended=app.task_store.list()[0]
 assert ended['verification_status']!='passed'
 data={'request_id':'manual-followup-chat-001','text':'你能帮我查看项目吗？',**defaults}
 response=c.post('/sessions/'+first['sid']+'/input',headers=h,json=data)
 assert response.status_code==200,response.text
 second=response.json()
 assert second['status']=='accepted' and second['submission_state']=='submitted'
 assert second['sid']==first['sid'] and second['turn_id']!=first['turn_id']
 assert c.post('/sessions/'+first['sid']+'/input',headers=h,json=data).json()==second
 assert len(calls['create'])==1 and len(calls['input'])==2 and len(calls['identity'])==1
 assert all(call['model'] is None and call['effort'] is None for call in calls['input'])
 current=app.task_store.list()
 assert len(current)==1 and current[0]['id']==task['id'] and current[0]['status']=='running'
 assert current[0]['run_id']==second['turn_id']
 app.task_store.finish(task['id'],'execution_finished','第二个真实回合结束。')
 explicit={'request_id':'manual-model-change-001','text':'继续讨论这个项目。','model':'user-next-model','effort':'medium'}
 third=c.post('/sessions/'+first['sid']+'/input',headers=h,json=explicit).json()
 assert third['status']=='accepted' and third['sid']==first['sid']
 assert calls['input'][-1]['model']=='user-next-model' and calls['input'][-1]['effort']=='medium'
 assert len(calls['create'])==1 and len(calls['input'])==3


def test_work_task_source_navigation_requires_actual_native_echo(service,monkeypatch):
 app,c=service;calls=manual_native_contract(app,monkeypatch)
 project=app.HOME/'AI_Work_System'/'demo';project.mkdir(parents=True)
 h={'Authorization':'Bearer '+app.TOKEN}
 first=c.post('/sessions',headers=h,json={'request_id':'manual-source-link-001','agent':'codex',
  'cwd':str(project),'prompt':'你好'}).json()
 monkeypatch.setattr(app.history,'messages',lambda sid:[])
 unresolved=c.get('/personal/tasks',headers=h).json()['items'][0]
 assert 'source_message_id' not in unresolved and 'source_session_id' not in unresolved
 native={'id':'actual-native-user-id','role':'user','text':calls['input'][0]['text'],
         'turn_id':first['turn_id'],'time':1}
 monkeypatch.setattr(app.history,'messages',lambda sid:[native] if sid==first['sid'] else [])
 resolved=c.get('/personal/tasks',headers=h).json()['items'][0]
 assert resolved['source_session_id']==first['sid']
 assert resolved['source_message_id']==native['id']
 assert resolved['source_message_id']!=resolved['origin_message_id']
 assert c.get('/personal/tasks',headers=h).json()['items'][0]['source_message_id']==native['id']
 assert len(calls['input'])==1 and len(calls['create'])==1


def test_cached_candidate_gate_receipt_explains_removed_limit_without_replay(service,monkeypatch):
 app,c=service
 monkeypatch.setattr(app,'MAIN_AGENT','pi')
 async def forbidden(*a,**kw):raise AssertionError('Reading an old rejection cannot start or replay work')
 monkeypatch.setattr(app.runtime,'create_task_worker',forbidden)
 monkeypatch.setattr(app.runtime,'input',forbidden)
 monkeypatch.setattr(app.runtime,'preflight_task',forbidden)
 data={'request_id':'cached-candidate-gate-001','agent':'codex','cwd':str(app.HOME/'AI_Work_System'),
       'prompt':'最近不想折腾手机','sandbox':'danger-full-access'}
 fingerprint=hashlib.sha256(json.dumps(data,sort_keys=True).encode()).hexdigest()
 old={'status':'rejected','submission_state':'not_submitted','request_id':data['request_id'],
      'error':'尚未提交：这条消息只形成候选，请补充要完成的动作；草稿已保留'}
 with app.history.db() as db:
  db.execute('INSERT INTO receipts VALUES(?,?,?)',(data['request_id'],fingerprint,json.dumps(old)))
 h={'Authorization':'Bearer '+app.TOKEN}
 resolved=c.get('/receipts/'+data['request_id'],headers=h).json()
 assert resolved['status']=='rejected' and resolved['submission_state']=='not_submitted'
 assert resolved['resolution']=='legacy_work_chat_gate_removed'
 assert '可直接发送普通消息' in resolved['error'] and '补充要完成的动作' not in resolved['error']
 assert c.post('/sessions',headers=h,json=data).json()==resolved
 assert c.get('/receipts/'+data['request_id'],headers=h).json()==resolved
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
