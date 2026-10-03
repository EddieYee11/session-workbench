import json,subprocess,re
from pathlib import Path
root=Path(__file__).parents[1]
r=subprocess.run(['node',str(root/'heartbeat-model.mjs')],input=json.dumps({'sdk':'/usr/local/lib/node_modules/@earendil-works/pi-coding-agent','digest':'{"tasks":[],"recent":[],"checklist":"无新事项保持静默"}'}),capture_output=True,text=True,timeout=60)
print('exit',r.returncode)
print(re.findall(r'heartbeat_stage=[a-z]+(?: stop=[a-z]+)?',r.stderr))
print(re.findall(r'heartbeat_error_labels=\[[^\n]*\]',r.stderr))
print(re.findall(r'heartbeat_payload=\{[^\n]*\}',r.stderr))
if r.returncode==0:
 d=json.loads(r.stdout);print('decision',d['decision']['action'],'tokens',d.get('usage',{}).get('totalTokens'))
