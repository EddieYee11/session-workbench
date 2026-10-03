"""Real native Pi routing in temporary Com stores; dispatch is deliberately not started."""
import asyncio,json,os,secrets,tempfile,time,uuid,sys
from pathlib import Path
import uvicorn
from fastapi import FastAPI,Request
from fastapi.responses import JSONResponse
from pi_main import PiMainClient,MAIN_PROMPT
from conversation import PersonalConversation
from tasks import TaskStore
from work_dispatch import WorkProposalStore
from capabilities import CapabilityRegistry
from goals import GoalEvents
from agent_tools import AgentTools
from policy import source
from work_cards import linked_card

async def main():
 root=Path(tempfile.mkdtemp(prefix='com-m7-routing-'));root.chmod(0o700)
 state=root/'state';state.mkdir();workspace=root/'workspace';workspace.mkdir()
 for name in ('A','B','C'):(workspace/name).mkdir()
 token=secrets.token_urlsafe(40);(state/'token').write_text(token);(state/'token').chmod(0o600)
 extension=Path(__file__).parents[1]/'com-pi.ts'
 argv=['/usr/local/bin/pi','--mode','rpc','--provider','opencode-go','--model','deepseek-v4.1-flash','--session-dir',str(state/'native'),'--no-context-files','--no-extensions','--no-skills','--no-builtin-tools','--extension',str(extension),'--system-prompt',MAIN_PROMPT]
 client=PiMainClient(state,workspace,argv=argv,env={**os.environ,'COM_INTERNAL_URL':'http://127.0.0.1:18659'},tools=True,isolated=True)
 chat=PersonalConversation(state,client);tasks=TaskStore(state);proposals=WorkProposalStore(state,workspace)
 with chat.db() as db:db.execute("INSERT OR REPLACE INTO meta VALUES ('pi_session_id','com-pi-main')")
 chat.task_context=tasks.context
 chat.task_environment=lambda:{'workspace_root':str(workspace),'automatic_executor':'pi','current_date':'2026-10-03','timezone':'Asia/Shanghai'}
 service=AgentTools(state,chat,proposals,tasks,None,CapabilityRegistry(state),GoalEvents(state))
 app=FastAPI();observed=[]
 @app.post('/internal/agent/{name}')
 async def call(name:str,request:Request):
  if request.headers.get('authorization')!='Bearer '+token:return JSONResponse({'detail':'unauthorized'},401)
  data=await request.json();observed.append(name)
  try:
   if name=='bookkeeping_search':
    source(chat,data['context']);return {'items':[],'truncated':False,'source':'isolated empty acceptance dataset'}
   return await service.call(name,data['args'],data['context'])
  except Exception:return JSONResponse({'detail':'isolated tool rejected'},409)
 server=uvicorn.Server(uvicorn.Config(app,host='127.0.0.1',port=18659,log_level='critical',lifespan='off'))
 server_task=asyncio.create_task(server.serve())
 while not server.started:await asyncio.sleep(.05)
 cases=[('greeting','你好',0),('quick_query','这个月餐饮花了多少',0),('long_job','帮我修改临时项目A的README，把标题改为验收示例并运行检查，交给Pi后台处理。',1),('two_jobs','这是两个新的独立事项：帮我修改临时项目B的README并检查；另一个事项，修改临时项目C的README并检查，各交给Pi后台处理。',2)]
 if '--only-two' in sys.argv:cases=[case for case in cases if case[0]=='two_jobs']
 reports=[]
 try:
  for name,text,wanted in cases:
   before={t['id'] for t in tasks.list()};rid='acceptance-'+uuid.uuid4().hex;receipt=chat.submit(rid,text)
   with chat.db() as db:row=dict(db.execute('SELECT * FROM messages WHERE id=?',(receipt['message_id'],)).fetchone())
   prompt,context=chat._pi_input(row,'com-pi-main','unused-acceptance-reaction')
   async def run():
    completed=False
    async for event,payload in client.rpc.stream(prompt,rid,context=context):
     if event=='run.completed':completed=True
     if event=='error':raise AssertionError('native routing returned error')
    assert completed
   start=time.monotonic();await asyncio.wait_for(run(),90)
   created=[t for t in tasks.list() if t['id'] not in before]
   assert len(created)==wanted,(name,len(created),wanted)
   assert all(t['origin_message_id']==receipt['message_id'] and len(t['title'])<=12 and t['status']=='queued' for t in created)
   assert len(linked_card(created)['linked_tasks'])==wanted
   reports.append({'case':name,'native_finished':True,'new_jobs':len(created),'source_ids_match':True,'short_titles':True,'dispatch_started':False,'seconds':round(time.monotonic()-start,2)})
   print(json.dumps(reports[-1],ensure_ascii=False),flush=True)
  print('Temporary native routing evidence:',root,'; production ledger/chat untouched')
 finally:
  await client.stop();server.should_exit=True;await server_task
asyncio.run(main())
