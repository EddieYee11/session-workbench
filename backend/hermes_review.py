"""Native Hermes structured reviews with durable run mapping, no Pi model relay."""
import asyncio,json
from hermes_runtime import HermesRuntime

async def review_json(state,request_id,instructions,data,timeout=120):
 client=HermesRuntime(state,'com-review-'+request_id,instructions=instructions+'\n只做本轮数据判断，不调用工具，不派发任务，不写入记忆或业务对象。')
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
