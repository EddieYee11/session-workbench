"""Operate only IDs created by reminder_card_acceptance; clean them after read-back."""
import fcntl,json,uuid,urllib.request,urllib.error
from pathlib import Path
h=Path.home();s=h/'.session-workbench';token=(s/'token').read_text().strip()
def req(path,body=None,public=False):
 base='https://pi.eddiegao.work:8443/sessions' if public else 'http://127.0.0.1:8650'
 r=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
 with urllib.request.urlopen(r,timeout=20) as reply:return json.load(reply)
ids=json.loads(Path('/tmp/com-b3-reminder-ids.json').read_text());all_ids={x['id'] for x in ids};reports=[]
try:
 for item in ids:
  old=next(x for x in req('/personal/reminders')['items'] if x['id']==item['id'])
  body={'action':item['action'],'request_id':str(uuid.uuid4()),'expected':{k:old[k] for k in ('due','status')}}
  result=req('/personal/reminders/'+item['id']+'/action',body)
  saved=next(x for x in req('/personal/reminders',public=True)['items'] if x['id']==item['id'])
  assert result['confirmed'] and saved==result['item']
  assert req('/personal/reminders/'+item['id']+'/action',body)['duplicate']
  if item['action']=='confirm':assert saved['status']=='done'
  elif item['action']=='cancel':assert saved['status']=='cancelled'
  else:assert saved['due']==('2099-01-01 12:10' if item['action']=='snooze10' else '2099-01-01 13:00')
  reports.append({'action':item['action'],'due':saved['due'],'status':saved['status'],'local_public_readback':True,'duplicate_safe':True})
 row=ids[1]
 try:req('/personal/reminders/'+row['id']+'/action',{'action':'snooze10','request_id':str(uuid.uuid4()),'expected':{'status':'pending','due':'2099-01-01 12:00'}})
 except urllib.error.HTTPError as e:
  detail=json.load(e)['detail'];assert e.code==409 and '提醒已变化' in detail
  reports.append({'stale_error':detail,'status':e.code})
 else:raise AssertionError('stale action accepted')
 print(json.dumps(reports,ensure_ascii=False,indent=2))
finally:
 path=h/'.pi-gateway/state/reminders.json'
 with path.with_suffix('.com-lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX);rows=json.loads(path.read_text())
  selected=[r for r in rows if r.get('id') in all_ids]
  assert all(r['text'].startswith('Com B3 验收临时提醒') for r in selected)
  tmp=path.with_suffix('.com-probe-cleanup');tmp.write_text(json.dumps([r for r in rows if r.get('id') not in all_ids],ensure_ascii=False,indent=1));tmp.chmod(0o600);tmp.replace(path)
 print('Cleaned only four explicitly labelled acceptance records')
