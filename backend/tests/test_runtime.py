import asyncio,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from runtime import Runtime
from history import History

def test_pi_process_title_without_arguments_keeps_unknown_history_readonly(tmp_path):
 h=History(tmp_path,tmp_path/'state');r=Runtime(h,'test')
 async def command(*args,**kwargs):return '123 pi\n456 /bin/zsh'
 r.cmd=command
 assert not asyncio.run(r.resumable({'id':'pi:old','agent':'pi','native_id':'old','cwd':str(tmp_path)}))
 async def empty(*args,**kwargs):return '456 /bin/zsh'
 r.cmd=empty
 assert asyncio.run(r.resumable({'id':'pi:old','agent':'pi','native_id':'old','cwd':str(tmp_path)}))

def test_model_catalog_uses_host_catalogs_and_codex_supported_efforts(tmp_path):
 h=History(tmp_path,tmp_path/'state');r=Runtime(h,'test')
 async def command(*args,**kwargs):
  assert args==(r.pi,'--list-models')
  return 'provider model context max-out thinking images\nopenai-codex gpt-6-astra 272K 128K yes yes\nlocal plain 32K 8K no no'
 async def rpc(method,params):
  assert method=='model/list'
  if 'cursor' not in params:return {'data':[{'model':'gpt-6-astra','displayName':'Astra','hidden':False,'supportedReasoningEfforts':[{'effort':'low'},{'effort':'high'}],'defaultReasoningEffort':'low'},{'model':'hidden','hidden':True}], 'nextCursor':'page-2'}
  assert params['cursor']=='page-2'
  return {'data':[{'model':'gpt-6-sol','displayName':'Sol','hidden':False,'supportedReasoningEfforts':[{'effort':'medium'}],'defaultReasoningEffort':'medium'}], 'nextCursor':None}
 r.cmd=command;r.call=rpc
 pi=asyncio.run(r.models('pi'));codex=asyncio.run(r.models('codex'))
 assert [(x['id'],x['efforts']) for x in pi]==[('openai-codex/gpt-6-astra',['off','minimal','low','medium','high','xhigh','max']),('local/plain',['off'])]
 assert [(x['id'],x['efforts']) for x in codex]==[('gpt-6-astra',['low','high']),('gpt-6-sol',['medium'])]
 assert asyncio.run(r.validate_model('codex','gpt-6-astra',''))=='low'

def test_codex_turn_applies_choice_to_real_rpc_and_rejects_invalid_pair(tmp_path):
 h=History(tmp_path,tmp_path/'state');r=Runtime(h,'test')
 sid='codex:abc';h.save_managed(sid,{'sid':sid,'native_id':'abc','agent':'codex','ended':False,'model':'','effort':''})
 r.model_cache['codex']=(__import__('time').monotonic(),[{'id':'gpt-6-astra','efforts':['low','high'],'default_effort':'low'}])
 calls=[]
 async def rpc(method,params):calls.append((method,params));return {'turn':{'id':'turn-1'}}
 r.call=rpc
 assert asyncio.run(r.input(sid,'检查项目','request-123','gpt-6-astra','high'))=='turn-1'
 assert calls==[('turn/start',{'threadId':'abc','input':[{'type':'text','text':'检查项目'}],'model':'gpt-6-astra','effort':'high'})]
 assert h.managed()[sid]['model']=='gpt-6-astra' and h.managed()[sid]['effort']=='high'
 try:asyncio.run(r.input(sid,'消息','request-456','gpt-6-astra','ultra'))
 except ValueError as error:assert '不支持' in str(error)
 else:assert False,'unsupported effort must not reach turn/start'
 assert len(calls)==1

def test_pi_model_change_requires_ack_before_message(tmp_path):
 h=History(tmp_path,tmp_path/'state');r=Runtime(h,'test')
 sid='pi:abc';h.save_managed(sid,{'sid':sid,'native_id':'abc','agent':'pi','tmux':'pi-pane','pi_file':str(tmp_path/'missing.jsonl'),'ended':False})
 sent=[]
 async def tm(*args,**kwargs):sent.append(args);return ''
 async def alive(_name):return True
 r.tm=tm;r.alive=alive
 async def status(_sid):return 'ready'
 r.status=status
 r.model_cache['pi']=(__import__('time').monotonic(),[{'id':'openai-codex/gpt-6-astra','efforts':['off','low','high'],'default_effort':''}])
 async def missing_ack(_sid,_m,_model,_effort):raise RuntimeError('Pi 模型切换未确认，消息未发送')
 r._set_pi_model=missing_ack
 try:asyncio.run(r.input(sid,'private user text','request-123','openai-codex/gpt-6-astra','high'))
 except RuntimeError as error:assert '未发送' in str(error)
 else:assert False,'missing configuration ACK must stop the send'
 assert not sent

def test_same_pi_choice_sends_while_running_without_reconfiguring(tmp_path):
 h=History(tmp_path,tmp_path/'state');r=Runtime(h,'test')
 sid='pi:abc';h.save_managed(sid,{'sid':sid,'native_id':'abc','agent':'pi','tmux':'pi-pane','pi_file':str(tmp_path/'missing.jsonl'),'model':'openai-codex/gpt-6-astra','effort':'high','ended':False})
 r.model_cache['pi']=(__import__('time').monotonic(),[{'id':'openai-codex/gpt-6-astra','efforts':['low','high'],'default_effort':''}])
 calls=[]
 async def tm(*args,**kwargs):calls.append((args,kwargs));return ''
 async def alive(_name):return True
 async def status(_sid):return 'running'
 async def forbidden(*args):raise AssertionError('same model must not reconfigure active Pi')
 r.tm=tm;r.alive=alive;r.status=status;r._set_pi_model=forbidden
 assert asyncio.run(r.input(sid,'continue','request-123','openai-codex/gpt-6-astra','high'))=='request-123'
 assert calls[0][0][:3]==('load-buffer','-b','request-123')
 assert calls[0][1]['input']==b'continue'

def test_explicit_default_reset_is_not_silently_ignored(tmp_path):
 h=History(tmp_path,tmp_path/'state');r=Runtime(h,'test')
 sid='codex:abc';h.save_managed(sid,{'sid':sid,'native_id':'abc','agent':'codex','model':'gpt-6-astra','effort':'high','ended':False})
 try:asyncio.run(r.input(sid,'next','request-123','',''))
 except ValueError as error:assert '不能直接恢复' in str(error)
 else:assert False,'resetting to default requires a real backend operation'

def test_pi_model_without_effort_keeps_follow_current_semantics(tmp_path):
 h=History(tmp_path,tmp_path/'state');r=Runtime(h,'test')
 sid='pi:abc';h.save_managed(sid,{'sid':sid,'native_id':'abc','agent':'pi','tmux':'pi-pane','pi_file':str(tmp_path/'missing.jsonl'),'model':'','effort':'','ended':False})
 r.model_cache['pi']=(__import__('time').monotonic(),[{'id':'openai-codex/gpt-6-astra','efforts':['off','high'],'default_effort':''}])
 async def tm(*args,**kwargs):return ''
 async def alive(_name):return True
 async def status(_sid):return 'ready'
 changes=[]
 async def config(_sid,m,model,effort):
  changes.append((model,effort));r._save_model(m,model,effort)
 r.tm=tm;r.alive=alive;r.status=status;r._set_pi_model=config
 asyncio.run(r.input(sid,'first','request-1','openai-codex/gpt-6-astra',''))
 assert h.managed()[sid]['effort']==''
 asyncio.run(r.input(sid,'second','request-2','openai-codex/gpt-6-astra',''))
 assert changes==[('openai-codex/gpt-6-astra','')]
