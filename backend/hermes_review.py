"""Structured background reviews: a direct fast-model call first, Hermes only as the fallback.

10-28 起整理「下一步」走 Hermes 主对话 profile（带工具、grok），整份摘要 150 秒内跑不完，连续三天全部超时退回规则版。
这类评审不需要工具，直连 Magpie 约 2 秒。
"""
import asyncio,json,time
from pathlib import Path
import httpx
from hermes_runtime import HermesRuntime

MODELS=Path.home()/'.pi/agent/models.json'
DIRECT_MODEL='opencode-go/deepseek-v4.1-flash'
NO_TOOLS='\n只做本轮数据判断，不调用工具，不派发任务，不写入记忆或业务对象。'

def _json_object(text):
 return json.loads(text[text.index('{'):text.rindex('}')+1])

async def direct_json(instructions,data,timeout,model=None):
 """Raises when Magpie is unavailable, so the caller can fall back."""
 provider=json.loads(MODELS.read_text())['providers']['magpie']
 body={'model':model or DIRECT_MODEL,'temperature':0.3,'max_tokens':8000,'thinking':{'type':'disabled'},'response_format':{'type':'json_object'},
       'messages':[{'role':'system','content':instructions+NO_TOOLS+'只输出一个 JSON 对象。'},{'role':'user','content':json.dumps(data,ensure_ascii=False)}]}
 async with httpx.AsyncClient(timeout=timeout,trust_env=False) as client:
  r=await client.post(provider['baseUrl'].rstrip('/')+'/chat/completions',json=body,headers={'Authorization':'Bearer '+provider.get('apiKey','')})
  r.raise_for_status()
  return _json_object(r.json()['choices'][0]['message'].get('content') or '')

async def hermes_json(state,request_id,instructions,data,timeout):
 client=HermesRuntime(state,'com-review-'+request_id,instructions=instructions+NO_TOOLS)
 output='';completed=False
 try:
  async with asyncio.timeout(timeout):
   async for kind,payload in client.stream(json.dumps(data,ensure_ascii=False),request_id):
    if kind=='assistant.completed':output=payload.get('content','')
    if kind=='run.completed':completed=True
  if not completed:raise ValueError('Hermes 评审未正常结束')
  return json.loads(output)
 finally:
  if not completed and client.run_id:
   try:await client.abort()
   except Exception:pass

async def review_json(state,request_id,instructions,data,timeout=120):
 started=time.monotonic()
 try:
  return await asyncio.wait_for(direct_json(instructions,data,timeout),timeout)
 except Exception:
  remaining=timeout-(time.monotonic()-started)
  if remaining<5:raise
  return await hermes_json(state,request_id,instructions,data,remaining)
