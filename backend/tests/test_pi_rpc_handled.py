import asyncio, json, sys
from pi_rpc import PiRPC

def test_handled_prompt_does_not_wait_for_nonexistent_settled(tmp_path):
 script=tmp_path/'native.py'
 script.write_text('''import sys,json
for line in sys.stdin:
 c=json.loads(line)
 print(json.dumps({'type':'response','id':c['id'],'command':c['type'],'success':True,'data':{'disposition':'handled'} if c['type']=='prompt' else {}}),flush=True)
''')
 async def scenario():
  rpc=PiRPC(tmp_path,'handled',tmp_path,argv=[sys.executable,'-u',str(script)])
  try:
   async with asyncio.timeout(.5):
    events=[(k,v) async for k,v in rpc.stream('fixture','handled-request-001')]
   assert any(k=='input.accepted' and v.get('disposition')=='handled' for k,v in events)
   assert not any(k=='run.completed' for k,v in events)
   assert any(k=='done' for k,v in events)
  finally:await rpc.stop()
 asyncio.run(scenario())
