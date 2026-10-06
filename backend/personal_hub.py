"""Source-grounded personal matters and briefing; isolated connector failures."""
import asyncio,email,hashlib,imaplib,json,os,sqlite3,time
from datetime import datetime,timedelta
from email.header import decode_header,make_header
from pathlib import Path
from zoneinfo import ZoneInfo
from calendar_bridge import CalendarBridge
TZ=ZoneInfo('Asia/Shanghai')
SOURCES={'gmail':900,'work_mail':900,'github':900,'apple_calendar':900,'google_calendar':900,'accounting':900,'garmin':1800,'phone_calendar':900,'phone_health':1800}
class PersonalHub:
    def __init__(self,state,home=None):
        self.state=Path(state);self.home=Path(home or Path.home());self.path=self.state/'personal-hub.sqlite';self.lock=asyncio.Lock()
        with self.db() as d:
            d.executescript('''CREATE TABLE IF NOT EXISTS sources(name TEXT PRIMARY KEY,data TEXT);CREATE TABLE IF NOT EXISTS matters(id TEXT PRIMARY KEY,source TEXT,source_id TEXT,data TEXT);CREATE TABLE IF NOT EXISTS feedback(id TEXT PRIMARY KEY,data TEXT);CREATE TABLE IF NOT EXISTS briefings(day TEXT PRIMARY KEY,data TEXT);CREATE TABLE IF NOT EXISTS connector_config(name TEXT PRIMARY KEY,data TEXT);''')
            d.execute('CREATE TABLE IF NOT EXISTS source_seen(source TEXT,identity TEXT,PRIMARY KEY(source,identity))')
            d.execute('CREATE TABLE IF NOT EXISTS briefing_annotations(id TEXT PRIMARY KEY,data TEXT)')
            d.execute('CREATE TABLE IF NOT EXISTS matter_links(id TEXT PRIMARY KEY,root TEXT,reason TEXT,kind TEXT,updated_at REAL)')
        self.path.chmod(0o600)
    def db(self):return sqlite3.connect(self.path)
    def config(self,name):
        with self.db() as d:r=d.execute('SELECT data FROM connector_config WHERE name=?',(name,)).fetchone()
        return json.loads(r[0]) if r else {}
    def configure(self,name,data):
        if name not in ('work_mail','garmin'):raise ValueError('Unsupported connector settings')
        allowed={'work_mail':('host','username','password','port'),'garmin':('domain','username','password')}[name]
        cfg={k:v for k,v in data.items() if k in allowed}
        if name=='work_mail':
            if not all(isinstance(cfg.get(k),str) and cfg[k] for k in ('host','username','password')):raise ValueError('需要邮箱服务器、账号和专用密码')
            if '/' in cfg['host'] or len(cfg['host'])>253:raise ValueError('Invalid mail hostname')
        if name=='garmin' and cfg.get('domain') not in ('garmin.cn','garmin.com'):raise ValueError('Unsupported Garmin region')
        with self.db() as d:d.execute('INSERT OR REPLACE INTO connector_config VALUES (?,?)',(name,json.dumps(cfg)))
        return {'saved':True,'name':name}
    def matter(self,source,source_id,title,facts,**extra):
        ident='matter_'+hashlib.sha256((source+':'+source_id).encode()).hexdigest()[:24]
        with self.db() as d:
            old=d.execute('SELECT data FROM matters WHERE id=?',(ident,)).fetchone()
            old=json.loads(old[0]) if old else {}
            source_time=extra.pop('source_updated_at',time.time())
            if source in ('gmail','work_mail') and old.get('source_updated_at',0)>source_time:return old
            content_hash=hashlib.sha256(json.dumps([title,facts,extra],sort_keys=True).encode()).hexdigest()
            row=dict(id=ident,source=source,source_id=source_id,title=title,facts=facts,source_updated_at=source_time,
                     updated_at=time.time(),changed_at=old.get('changed_at',time.time()) if old.get('content_hash')==content_hash else time.time(),content_hash=content_hash,**extra)
            d.execute('INSERT OR REPLACE INTO matters VALUES(?,?,?,?)',(ident,source,source_id,json.dumps(row,ensure_ascii=False)))
        return row
    def matters(self):
        with self.db() as d:
            rows=[json.loads(r[0]) for r in d.execute('SELECT data FROM matters')]
            feedback={k:json.loads(v) for k,v in d.execute('SELECT id,data FROM feedback')}
        return [{**r,'feedback':feedback.get(r['id'],{})} for r in sorted(rows,key=lambda r:r['changed_at'],reverse=True)]
    def link(self,root,ids,reason,kind='assistant_inference'):
        known={r['id'] for r in self.matters()}
        if root not in known or not isinstance(ids,list) or not ids or len(ids)>20 or any(i not in known for i in ids):raise ValueError('关联必须引用实际事项')
        if not isinstance(reason,str) or not reason.strip():raise ValueError('需要关联依据')
        if kind not in ('assistant_inference','user_link'):raise ValueError('Invalid grouping kind')
        with self.db() as d:
            # Canonical root prevents cycles. Facts and source identities remain independent.
            previous=d.execute('SELECT root FROM matter_links WHERE id=?',(root,)).fetchone()
            root=previous[0] if previous else root
            for ident in ids:
                if ident==root:continue
                d.execute('UPDATE matter_links SET root=? WHERE root=?',(root,ident))
                d.execute('INSERT OR REPLACE INTO matter_links VALUES(?,?,?,?,?)',(ident,root,reason[:2000],kind,time.time()))
        return {'root':root,'linked':ids,'reason':reason,'kind':kind,'facts_changed':False}
    def unlink(self,ident):
        with self.db() as d:d.execute('DELETE FROM matter_links WHERE id=? OR root=?',(ident,ident))
        return {'unlinked':ident,'facts_changed':False}
    def annotate(self,ident,source_version,what,why,next_step):
        card=next((r for r in self.briefing()['cards'] if r['id']==ident),None)
        if not card or card['source_version']!=source_version:raise ValueError('事项已变化，请读取最新事实后再生成建议')
        if any(not isinstance(v,str) or not v.strip() or len(v)>1000 for v in (what,why,next_step)):raise ValueError('建议需要完整的发生事项、相关理由和下一步')
        row={'source_version':source_version,'what':what,'why':why,'next_step':next_step,'kind':'assistant_suggestion','updated_at':time.time()}
        with self.db() as d:d.execute('INSERT OR REPLACE INTO briefing_annotations VALUES(?,?)',(ident,json.dumps(row,ensure_ascii=False)))
        return {'id':ident,'saved':True,'source_version':source_version,'facts_changed':False}

    def feedback(self,ident,action,request_id,text=''):
        if action not in ('follow','later','handled','correct','mute'):raise ValueError('Invalid action')
        if action=='correct' and not text.strip():raise ValueError('请填写纠正内容')
        if not any(r['id']==ident for r in self.matters()):raise ValueError('Matter not found')
        with self.db() as d:
            prev=d.execute('SELECT data FROM feedback WHERE id=?',(ident,)).fetchone();old=json.loads(prev[0]) if prev else {}
            if old.get('request_id')==request_id:return old
            row={'action':action,'request_id':request_id,'text':text[:3000],'updated_at':time.time(),'history':old.get('history',[])+[{k:v for k,v in old.items() if k!='history'}] if old else []}
            if action=='correct':row['correction']={'text':text[:3000],'updated_at':row['updated_at'],'source':'authenticated_user_edit'}
            elif old.get('correction'):row['correction']=old['correction']
            if action=='later':row['until']=time.time()+86400
            d.execute('INSERT OR REPLACE INTO feedback VALUES(?,?)',(ident,json.dumps(row,ensure_ascii=False)))
        return row
    async def command(self,args,timeout=25):
        env={**os.environ,'PATH':'/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin'}
        proc=await asyncio.create_subprocess_exec(*map(str,args),stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,env=env)
        try:out,err=await asyncio.wait_for(proc.communicate(),timeout)
        except asyncio.TimeoutError:
            proc.kill();await proc.wait();raise RuntimeError('Connector timed out') from None
        if proc.returncode:raise RuntimeError('Connector authorization or service unavailable')
        data=json.loads(out)
        if data.get('error'):raise RuntimeError('Connector authorization required')
        return data
    async def gws(self,service,*path,params):
        return await self.command(['gws',service,*path,'--params',json.dumps(params)])
    def seen(self,source,ident):
        with self.db() as d:return bool(d.execute('SELECT 1 FROM source_seen WHERE source=? AND identity=?',(source,ident)).fetchone())
    def mark_seen(self,source,ident):
        with self.db() as d:d.execute('INSERT OR IGNORE INTO source_seen VALUES(?,?)',(source,ident))
    async def sync_source(self,name):
        now=datetime.now(TZ)
        if name=='gmail':
            token=None;count=updated=0
            while True:
                params={'userId':'me','maxResults':500,'q':'newer_than:30d'}
                if token:params['pageToken']=token
                data=await self.gws('gmail','users','messages','list',params=params)
                for item in data.get('messages',[]):
                    count+=1
                    if self.seen(name,item['id']):continue
                    m=await self.gws('gmail','users','messages','get',params={'userId':'me','id':item['id'],'format':'metadata','metadataHeaders':['Subject','From','Date']})
                    heads={h['name'].lower():h['value'] for h in m.get('payload',{}).get('headers',[])}
                    self.matter(name,m.get('threadId',m['id']),heads.get('subject','邮件'),{'from':heads.get('from',''),'snippet':m.get('snippet',''),'message_id':m['id']},source_updated_at=int(m.get('internalDate',0))/1000,link='https://mail.google.com/mail/u/0/#all/'+m.get('threadId',m['id']),deadline=None)
                    self.mark_seen(name,item['id']);updated+=1
                token=data.get('nextPageToken')
                if not token:break
            return {'count':count,'updated_count':updated,'coverage':'最近30天分页读取；按原消息 ID 增量同步'}
        if name=='work_mail':return await asyncio.to_thread(self.imap_sync)
        if name=='github':
            data=await self.command(['gh','api','/notifications?all=true&since='+(now-timedelta(days=30)).isoformat(),'--jq','{items: .}'])
            for n in data.get('items',[]):self.matter(name,n['id'],n['subject']['title'],{'reason':n.get('reason'),'repository':n['repository']['full_name']},link=n['repository']['html_url'],source_updated_at=datetime.fromisoformat(n['updated_at'].replace('Z','+00:00')).timestamp(),deadline=None)
            return {'count':len(data.get('items',[])),'coverage':'最近30天项目通知'}
        if name=='apple_calendar':
            first=(now-timedelta(days=7)).date().isoformat();last=(now+timedelta(days=30)).date().isoformat()
            rows=await CalendarBridge(self.home).read(first,last)
            for e in rows:self.matter(name,e.get('occurrence_id',e['id']),e['title'],e,deadline=e['start'],deadline_type='calendar_event')
            ids={e.get('occurrence_id',e['id']) for e in rows}
            with self.db() as d:
                for ident,sid in d.execute('SELECT id,source_id FROM matters WHERE source=?',(name,)).fetchall():
                    if sid not in ids:d.execute('DELETE FROM matters WHERE id=?',(ident,))
            return {'count':len(rows),'coverage':'过去7天至未来30天'}
        if name=='google_calendar':
            data=await self.google_calendar(now)
            for e in data.get('items',[]):self.matter(name,e['id'],e.get('summary','日历事项'),e,deadline=e.get('start',{}).get('dateTime',e.get('start',{}).get('date')),deadline_type='calendar_event',link=e.get('htmlLink',''))
            return {'count':len(data.get('items',[])),'coverage':'过去7天至未来30天；Google 独立来源，仅同步读取'}
        if name=='accounting':
            from business_tools import BusinessTools
            result=await BusinessTools(self.state,home=self.home).execute('bookkeeping',{'action':'summary'})
            self.matter(name,result['month'],'本月账本',result,deadline=None)
            return {'count':result['count'],'coverage':result['month']}
        if name=='garmin':
            data=await self.command([self.home/'.session-workbench/connectors-venv/bin/python',Path(__file__).parent/'garmin_source.py',self.config('garmin').get('domain','garmin.cn')],timeout=50)
            self.matter(name,data['date'],'佳明健康记录',data,deadline=None)
            return {'count':1,'coverage':data['date']}
        if name in ('phone_calendar','phone_health'):
            nodes=getattr(self,'device_nodes',None)
            device=next((d for d in nodes.list() if d['online']),None) if nodes else None
            if not device:raise RuntimeError('手机节点离线；启用常驻连接后同步')
            tool='health.summary' if name=='phone_health' else 'calendar.list'
            args={'days':7} if name=='phone_health' else {'days':30}
            row=await nodes.call(device['id'],tool,args,'sync-'+name+'-'+str(int(time.time()*1000)))
            if row['status']!='succeeded':raise RuntimeError('手机数据不可读：'+row['status'])
            return self.ingest_phone(row)
        raise ValueError('Unknown connector')
    async def google_calendar(self,now):
        try:return await self.gws('calendar','events','list',params={'calendarId':'primary','timeMin':(now-timedelta(days=7)).isoformat(),'timeMax':(now+timedelta(days=30)).isoformat(),'singleEvents':True,'maxResults':250})
        except Exception:
            # Reuse the already authorized calendar account separately from Gmail.
            from google.oauth2.credentials import Credentials
            from google.auth.transport.requests import Request
            root=self.home/'.pi-dashboard';token=root/'google-token.secret'
            if not token.exists():raise RuntimeError('Google Calendar 需要重新授权') from None
            def auth():
                cred=Credentials.from_authorized_user_file(str(token),['https://www.googleapis.com/auth/calendar'])
                if not cred.valid:
                    cred.refresh(Request());token.write_text(cred.to_json());token.chmod(0o600)
                return cred.token
            key=await asyncio.to_thread(auth)
            settings=json.loads((root/'google-calendar.secret').read_text())
            from urllib.parse import quote
            import httpx
            async with httpx.AsyncClient(timeout=25,trust_env=False) as client:
                response=await client.get('https://www.googleapis.com/calendar/v3/calendars/'+quote(settings['id'],safe='')+'/events',headers={'Authorization':'Bearer '+key},params={'timeMin':(now-timedelta(days=7)).isoformat(),'timeMax':(now+timedelta(days=30)).isoformat(),'singleEvents':'true','maxResults':250})
                response.raise_for_status();return response.json()
    def ingest_phone(self,row):
        data=row.get('result') or {};name='phone_health' if row['tool']=='health.summary' else 'phone_calendar'
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS phone_observations(id TEXT PRIMARY KEY,source TEXT,node TEXT,data TEXT)')
            db.execute('INSERT OR REPLACE INTO phone_observations VALUES(?,?,?,?)',(row['id'],name,row['node'],json.dumps(data,ensure_ascii=False)))
        if name=='phone_health':
            # Time series stays outside the stable personal memory catalog.
            self.matter(name,row['node']+':'+str(data.get('end',''))[:10],'手机健康记录',data,deadline=None)
        else:
            for e in data.get('items',[]):
                start=datetime.fromtimestamp(int(e['begin'])/1000,TZ).isoformat(timespec='minutes');end=datetime.fromtimestamp(int(e['end'])/1000,TZ).isoformat(timespec='minutes')
                facts={**e,'start':start,'end':end,'source':'手机 CalendarProvider','node':row['node']}
                self.matter(name,row['node']+':'+str(e['event_id'])+':'+start,e.get('title','手机日程'),facts,deadline_type='calendar_event',deadline=start)
        return {'count':1 if name=='phone_health' else len(data.get('items',[])),'coverage':str(data.get('start',''))+' 至 '+str(data.get('end','')),'node':row['node']}
    def imap_sync(self):
        cfg=self.config('work_mail')
        if not cfg:raise RuntimeError('工作邮箱未连接：需要 IMAP 服务器、账号与专用密码')
        since=(datetime.now(TZ)-timedelta(days=30)).strftime('%d-%b-%Y')
        with imaplib.IMAP4_SSL(cfg['host'],int(cfg.get('port',993)),timeout=20) as client:
            client.login(cfg['username'],cfg['password']);client.select('INBOX',readonly=True)
            typ,data=client.uid('search',None,'SINCE',since)
            if typ!='OK':raise RuntimeError('IMAP search failed')
            validity=(client.response('UIDVALIDITY')[1] or [b''])[0]
            namespace='work_mail:'+hashlib.sha256((cfg['host']+':'+cfg['username']+':'+str(validity)).encode()).hexdigest()
            uids=data[0].split();updated=0
            for uid in uids:
                if self.seen(namespace,uid.decode()):continue
                typ,raw=client.uid('fetch',uid,'(INTERNALDATE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM DATE MESSAGE-ID REFERENCES IN-REPLY-TO)])')
                if typ!='OK':continue
                msg=email.message_from_bytes(next(r[1] for r in raw if isinstance(r,tuple)))
                title=str(make_header(decode_header(msg.get('Subject','邮件'))))
                thread=(msg.get('References','').split() or [msg.get('In-Reply-To') or msg.get('Message-ID') or uid.decode()])[0]
                header=next(r[0] for r in raw if isinstance(r,tuple));arrived=imaplib.Internaldate2tuple(header)
                if arrived:stamp=time.mktime(arrived)
                else:
                    try:stamp=email.utils.parsedate_to_datetime(msg.get('Date','')).timestamp()
                    except (ValueError,TypeError,AttributeError):stamp=0
                self.matter('work_mail',thread,title,{'from':msg.get('From',''),'date':msg.get('Date',''),'uid':uid.decode()},source_updated_at=stamp,deadline=None)
                self.mark_seen(namespace,uid.decode());updated+=1
            return {'count':len(uids),'updated_count':updated,'coverage':'最近30天；按邮箱 UID 增量，仅邮件头，不改变已读状态'}
    async def sync(self,group='all',force=False):
        async with self.lock:
            old={r['name']:r for r in self.status()['sources']}
            names=['garmin','phone_health'] if group=='health' else [n for n in SOURCES if n not in ('garmin','phone_health')] if group=='mail' else list(SOURCES)
            async def one(name):
                previous=old.get(name,{})
                if not force and time.time()-previous.get('attempted_at',0)<SOURCES[name]:return
                row={**previous,'name':name,'attempted_at':time.time(),'interval_seconds':SOURCES[name]}
                try:row.update(await self.sync_source(name),status='connected',updated_at=time.time(),error='')
                except Exception as e:row.update(status='needs_connection' if name in ('gmail','google_calendar','work_mail','garmin') else 'unavailable',error=str(e)[:170],error_type=type(e).__name__)
                with self.db() as d:d.execute('INSERT OR REPLACE INTO sources VALUES(?,?)',(name,json.dumps(row,ensure_ascii=False)))
            await asyncio.gather(*(one(n) for n in names))
            self.briefing()
            return self.status()
    def status(self):
        with self.db() as d:rows={k:json.loads(v) for k,v in d.execute('SELECT name,data FROM sources')}
        return {'sources':[rows.get(n,{'name':n,'status':'not_synced','interval_seconds':interval}) for n,interval in SOURCES.items()],
                'connections':{'gmail':{'action':'Google OAuth','required':'在 mini 的既有 gws 授权入口重新授权 Gmail/Calendar'},'work_mail':{'action':'IMAP','fields':['host','username','password','port']},'garmin':{'action':'existing_session','regions':['garmin.cn','garmin.com']}},'timezone':'Asia/Shanghai','morning_at':'09:00'}
    def briefing(self):
        rows=self.matters();now=time.time();cards=[]
        for r in rows:
            f=r['feedback'];action=f.get('action')
            if action in ('handled','mute') or action=='later' and f.get('until',0)>now:continue
            if r['source'] in ('apple_calendar','google_calendar','phone_calendar') and r.get('deadline'):
                try:
                    end=r.get('facts',{}).get('end')
                    if isinstance(end,dict):end=end.get('dateTime',end.get('date'))
                    if datetime.fromisoformat(end or r['deadline']).replace(tzinfo=TZ).timestamp()<now:continue
                except ValueError:pass
            cards.append({**r,'what':r['title'],'why':{'gmail':'与你的个人邮件往来有关','work_mail':'来自工作邮箱的事项','github':'你关注的项目有新动态','apple_calendar':'来自苹果日历的个人安排','google_calendar':'来自 Google 日历的安排','accounting':'本月真实账目汇总','garmin':'已同步的身体与运动数据'}.get(r['source'],'你正在处理的事项'),
                'next_step':'结合资料分析并提出下一步','suggested_at':now,'suggested_time_is_deadline':False,'user_correction':f.get('correction'),'action_context':{'matter_id':r['id'],'goal':'分析这件事并给出下一步','facts':r['facts'],'source':r['source'],'feedback':f}})
        def order(r):
            try:due=datetime.fromisoformat(r.get('deadline') or '').replace(tzinfo=TZ).timestamp()
            except ValueError:due=float('inf')
            facts=r.get('facts',{});calendar=r['source'] in ('apple_calendar','google_calendar','phone_calendar')
            informational=calendar and (facts.get('availability')==1 or any(k in facts.get('calendar','') for k in ('节假日','中国大陆','中国节日')))
            focus=4 if informational else 0 if r['source']=='com_task' else 1 if due<now+86400 else 2 if r['source'] in ('gmail','work_mail','github','accounting') else 3
            return (0 if r['feedback'].get('action')=='follow' else 1,focus,due,-r['changed_at'])
        cards.sort(key=order)
        # Multiple subscribed calendars may mirror one event. Keep individual facts
        # and feedback IDs, but show one card with all proven source identities.
        unique={};merged=[]
        for card in cards:
            facts=card['facts'];start=facts.get('start');end=facts.get('end')
            def instant(value):
                if isinstance(value,dict):value=value.get('dateTime',value.get('date'))
                try:
                    d=datetime.fromisoformat(value)
                    return d.replace(tzinfo=TZ).timestamp() if d.tzinfo is None else d.timestamp()
                except (TypeError,ValueError):return value
            key=json.dumps([card['title'],instant(start),instant(end)],sort_keys=True) if card['source'] in ('apple_calendar','google_calendar','phone_calendar') else card['id']
            if key in unique:
                unique[key].setdefault('related_matters',[]).append({'id':card['id'],'source':card['source']})
            else:unique[key]=card;merged.append(card)
        cards=merged
        with self.db() as d:links={r[0]:{'root':r[1],'reason':r[2],'kind':r[3]} for r in d.execute('SELECT id,root,reason,kind FROM matter_links')}
        all_rows={r['id']:r for r in rows};grouped=[];by_id={r['id']:r for r in cards}
        for card in cards:
            relation=links.get(card['id']);root=relation['root'] if relation else card['id']
            root_feedback=all_rows.get(root,{}).get('feedback',{})
            if relation and (root_feedback.get('action') in ('handled','mute') or root_feedback.get('action')=='later' and root_feedback.get('until',0)>now):continue
            owner=by_id.get(root)
            if relation and owner and owner is not card:
                owner.setdefault('related_matters',[]).append({'id':card['id'],'source':card['source'],'title':card['title']})
                owner['action_context'].setdefault('related_facts',[]).append({'id':card['id'],'facts':card['facts'],'source':card['source'],'feedback':card['feedback']})
                owner['grouping']={'reason':relation['reason'],'kind':relation['kind']}
            else:grouped.append(card)
        cards=grouped
        with self.db() as d:annotations={r[0]:json.loads(r[1]) for r in d.execute('SELECT id,data FROM briefing_annotations')}
        for card in cards:
            version=hashlib.sha256(json.dumps([card['facts'],card['feedback'],card.get('grouping'),card['action_context'].get('related_facts',[])],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
            card['source_version']=version
            suggestion=annotations.get(card['id'],{})
            if suggestion.get('source_version')==version:
                card.update({k:suggestion[k] for k in ('what','why','next_step')})
                card['assistant_suggestion']={'kind':suggestion['kind'],'updated_at':suggestion['updated_at']}
        data={'date':datetime.now(TZ).date().isoformat(),'generated_at':now,'cards':cards[:5],'matter_count':len(rows),'source_status':self.status(),'max_cards':5}
        with self.db() as d:d.execute('INSERT OR REPLACE INTO briefings VALUES(?,?)',(data['date'],json.dumps(data,ensure_ascii=False)))
        return data
