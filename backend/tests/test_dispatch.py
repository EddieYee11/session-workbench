"""工作页「任何会话都能发一句」：/sessions/{sid}/dispatch 的四条路。"""
import sys,importlib,json
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

def fixture_session(app,monkeypatch,agent='codex',caps=None,pane=(False,'')):
 sid=agent+':native-1';cwd=app.HOME/'proj';cwd.mkdir(exist_ok=True)
 session={'id':sid,'agent':agent,'native_id':'native-1','cwd':str(cwd),'title':'修登录页','path':'unused'}
 monkeypatch.setattr(app.history,'get',lambda value:dict(session) if value==sid else None)
 monkeypatch.setattr(app.history,'messages',lambda value:[{'role':'user','text':'先看登录页'},{'role':'assistant','text':'登录页的按钮错位了'}])
 async def session_caps(s_id,s):return {'input':False,'resume':False,**(caps or {})}
 monkeypatch.setattr(app,'session_caps',session_caps)
 async def find_pane(s):return pane
 monkeypatch.setattr(app.runtime,'find_pane',find_pane)
 return sid

def post(app,c,sid,text='接着改',rid='dispatch-request-001'):
 return c.post('/sessions/'+sid+'/dispatch',headers={'Authorization':'Bearer '+app.TOKEN},json={'text':text,'request_id':rid})

def test_running_in_terminal_types_into_that_pane(service,monkeypatch):
 app,c=service;sid=fixture_session(app,monkeypatch,pane=(True,'%3'))
 typed=[]
 async def inject(pane,text,rid):typed.append((pane,text))
 monkeypatch.setattr(app.runtime,'inject',inject)
 async def never(*a,**k):raise AssertionError('不能另开会话')
 monkeypatch.setattr(app.runtime,'create',never)
 r=post(app,c,sid);assert r.status_code==200,r.text
 assert r.json()['mode']=='injected' and typed==[('%3','接着改')]
 assert post(app,c,sid).json()['mode']=='injected' and len(typed)==1,'同一请求标识重发不再打一次'

def test_running_but_ambiguous_forks_with_context(service,monkeypatch):
 app,c=service;sid=fixture_session(app,monkeypatch,pane=(True,''));monkeypatch.setattr(app,'MAIN_AGENT','hermes')
 started=[]
 async def create(agent,cwd,*a,**k):started.append((agent,cwd));return 'codex:new'
 async def send_input(new,text,rid,*a):started.append(text);return 'turn-1'
 monkeypatch.setattr(app.runtime,'create',create);monkeypatch.setattr(app.runtime,'input',send_input)
 async def never(*a,**k):raise AssertionError('多个候选时不能乱打字')
 monkeypatch.setattr(app.runtime,'inject',never)
 r=post(app,c,sid);assert r.status_code==200,r.text
 body=r.json();assert body['mode']=='forked' and body['sid']=='codex:new' and body['from']==sid
 assert started[0]==('codex',str(app.HOME/'proj'))
 assert '修登录页' in started[1] and '登录页的按钮错位了' in started[1] and '接着改' in started[1]

def test_resumable_session_resumes_then_sends(service,monkeypatch):
 app,c=service;sid=fixture_session(app,monkeypatch,caps={'resume':True})
 calls=[]
 async def resume(s_id,body):calls.append(('resume',(await body.json())['request_id']));return {'status':'accepted','sid':sid}
 async def send(s_id,body):calls.append(('send',(await body.json())['text']));return {'status':'accepted','sid':s_id}
 monkeypatch.setattr(app,'resume',resume);monkeypatch.setattr(app,'send',send)
 r=post(app,c,sid);assert r.status_code==200,r.text
 assert r.json()['mode']=='resumed' and calls==[('resume','dispatch-request-001-resume'),('send','接着改')]

def test_idle_claude_code_session_is_adopted_not_forked(service,monkeypatch):
 app,c=service;sid=fixture_session(app,monkeypatch,agent='claude')
 async def adopt(s):return 'claude:com-adopted'
 sent=[]
 async def send(s_id,body):sent.append(s_id);return {'status':'accepted','sid':s_id}
 monkeypatch.setattr(app.runtime,'adopt_claude',adopt);monkeypatch.setattr(app,'send',send)
 r=post(app,c,sid);assert r.status_code==200,r.text
 assert r.json()['mode']=='adopted' and sent==['claude:com-adopted']

def test_live_input_uses_existing_path(service,monkeypatch):
 app,c=service;sid=fixture_session(app,monkeypatch,caps={'input':True})
 async def send(s_id,body):return {'status':'accepted','sid':s_id}
 monkeypatch.setattr(app,'send',send)
 assert post(app,c,sid).json()['mode']=='input'

def test_adopt_claude_seeds_native_session(tmp_path,monkeypatch):
 from runtime import Runtime
 class H:state=tmp_path
 rt=Runtime.__new__(Runtime);rt.h=H();rt.state=tmp_path
 created=[]
 class W:
  async def create(self,task):created.append(task);return 'claude:com-x'
 rt.workers=W()
 import asyncio
 sid=asyncio.run(rt.adopt_claude({'agent':'claude','native_id':'abc-123','cwd':str(tmp_path),'title':'旧会话'}))
 assert sid=='claude:com-x'
 saved=json.loads((tmp_path/'claude-runtime'/(created[0]['id']+'.json')).read_text())
 assert saved['native_session']=='abc-123' and created[0]['cwd']==str(tmp_path)
