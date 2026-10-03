"""Shared CAS writer for existing remind extension and gateway runner."""
import fcntl,json,os,sys
from pathlib import Path

def update(path,changes):
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
 with path.with_suffix('.com-lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX);os.chmod(lock.name,0o600)
  try:rows=json.loads(path.read_text())
  except FileNotFoundError:rows=[]
  if not isinstance(rows,list):raise ValueError('reminder store malformed')
  for change in changes:
   old=next((r for r in rows if r.get('id')==change['id']),None)
   if change.get('new'):
    if old:raise ValueError('reminder id already exists')
    rows.append(change['new']);continue
   if not old or any(old.get(k)!=v for k,v in change['expected'].items()):raise ValueError('reminder changed; refresh before retry')
   old.update(change['fields'])
  tmp=path.with_suffix('.json.tmp.'+str(os.getpid()))
  tmp.write_text(json.dumps(rows,ensure_ascii=False,indent=1));tmp.chmod(0o600);tmp.replace(path)
  return rows
if __name__=='__main__':
 data=json.load(sys.stdin);update(data['path'],data['changes'])
