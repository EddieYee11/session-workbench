import json,subprocess,shutil
from pathlib import Path

def test_each_request_has_unique_routing_session_without_loading_agent_tools(tmp_path):
 sdk=tmp_path/'sdk';(sdk/'dist').mkdir(parents=True)
 (sdk/'package.json').write_text('{"type":"module"}')
 (sdk/'dist/index.js').write_text('''export class ModelRuntime {
 static async create(){return new ModelRuntime()}
 getModel(){return {}}
 async completeSimple(model,context,options){
  if(context.tools.length!==1||context.tools[0].name!=='heartbeat_decide'||options.cacheRetention!=='none'||options.maxTokens!==512)throw Error('contract failed');
  const p=options.onPayload({reasoning_effort:'low'});
  if(p.thinking.type!=='disabled'||p.reasoning_effort||p.tool_choice!=='required')throw Error('thinking contract failed');
  return {stopReason:'toolUse',content:[{type:'toolCall',name:'heartbeat_decide',arguments:{action:'nothing',reason:options.sessionId,text:''}}],usage:{totalTokens:100}}
 }
}''')
 helper=Path(__file__).parents[1]/'heartbeat-model.mjs'
 results=[json.loads(subprocess.run([shutil.which('node'),str(helper)],input=json.dumps({'sdk':str(sdk),'digest':'{}'}),capture_output=True,text=True,check=True).stdout) for _ in range(2)]
 assert all(x['decision']['reason'].startswith('com-heartbeat-') for x in results)
 assert results[0]['decision']['reason']!=results[1]['decision']['reason']
