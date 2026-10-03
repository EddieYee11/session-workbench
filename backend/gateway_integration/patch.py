"""Patch only the verified existing gateway writers, never settings or other files."""
from pathlib import Path
import shutil,hashlib
root=Path.home()/'pi-hermes'
expected={'pi_gateway/reminders.py':'94e16a7582de91c91e3a7118fadb969208c7c66b3612e6fc7a9ef841367cef92','extensions/remind.ts':'c86c397693ed196bbe2ebb573f4fe7911159b7dbd9525e7917293afa0b1d69da'}
for name,sha in expected.items():
 p=root/name
 if hashlib.sha256(p.read_bytes()).hexdigest()!=sha:raise SystemExit('Gateway baseline changed: '+name)
for name in expected:shutil.copy2(root/name,root/(name+'.before-com-b3'))
p=root/'pi_gateway/reminders.py';s=p.read_text().replace('import os','import os\nfrom .reminder_store import update')
s=s.replace('        changed = False','        changes = []')
s=s.replace('            stale = now - due', "            latest=next((r for r in self._load() if r.get('id')==item.get('id')),None)\n            if not latest or latest.get('status')!='pending' or latest.get('due')!=item.get('due'):continue\n            expected={'status':item['status'],'due':item['due']}\n            stale = now - due")
s=s.replace('            changed = True', "            changes.append({'id':item['id'],'expected':expected,'fields':{k:item[k] for k in ('status','due','fired_at')}})")
s=s.replace('        if changed:\n            self._save(items)', "        for change in changes:\n            try:update(self.path,[change])\n            except ValueError:logger.info('Reminder changed during delivery; preserve newest record')")
p.write_text(s)
p=root/'extensions/remind.ts';s=p.read_text().replace('import type { ExtensionAPI }', 'import { execFileSync } from "node:child_process";\nimport type { ExtensionAPI }')
a=s.index('function save(list: Reminder[]): void {');b=s.index('\n/** 把',a)
s=s[:a]+'''function save(list: Reminder[], baseline: Reminder[]): void {
 const changes = list.flatMap(item => {
  const old=baseline.find(r=>r.id===item.id);
  if(!old)return [{id:item.id,new:item}];
  if(JSON.stringify(old)===JSON.stringify(item))return [];
  return [{id:item.id,expected:{status:old.status,due:old.due},fields:{status:item.status,due:item.due}}];
 });
 execFileSync("/usr/bin/python3",[join(HOME,"pi_gateway/reminder_store.py")],{input:JSON.stringify({path:STORE,changes}),encoding:"utf8",timeout:5000});
}
''' + s[b:]
s=s.replace('const list = load();','const list = load();\n            const baseline: Reminder[] = JSON.parse(JSON.stringify(list));').replace('save(list);','save(list, baseline);')
p.write_text(s)
shutil.copy2(Path(__file__).with_name('reminder_store.py'),root/'pi_gateway/reminder_store.py')
print('Patched source only; deployment/restart is a separate gated step')
