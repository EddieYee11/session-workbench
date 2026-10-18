"""Durable push outbox: APNs when a provider key exists, else Bark (self-hostable iOS push relay).

Bark 是个人 Apple 账号发不了 APNs 时的替代：mini 把通知 POST 到 Bark 服务器，手机上的 Bark App
负责显示，点开后通过 com-eddie:// 深链回到 Com。配置文件 bark-config.json：
{"device_key": "<Bark App 里的 Key>", "server": "https://api.day.app", "preview": false}
preview=false 时推送正文不含消息内容，只提示「已为你整理好」。
Provider acceptance is never described as device delivery."""
import hashlib
import json
import re
import sqlite3
import time
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
import httpx


class PushNotifications:
    def __init__(self,state,conversation,settings,clock=time.time):
        self.state=Path(state);self.path=self.state/'notifications.sqlite'
        self.conversation=conversation;self.settings=settings;self.clock=clock
        self._jwt='';self._jwt_at=0
        with self.db() as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,token TEXT,environment TEXT,enabled INTEGER,registered REAL);
              CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY,message_id TEXT,device_id TEXT,state TEXT,attempts INTEGER,next_at REAL,created REAL,reason TEXT);
              CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT);''')
            if not db.execute("SELECT 1 FROM meta WHERE key='cursor'").fetchone():
                with self.conversation.db() as chat:revision=chat.execute('SELECT COALESCE(MAX(revision),0) FROM messages').fetchone()[0]
                db.execute("INSERT INTO meta VALUES ('cursor',?)",(str(revision),))
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db=sqlite3.connect(self.path,timeout=20);db.row_factory=sqlite3.Row
        try:
            with db:yield db
        finally:db.close()

    def config(self):
        try:cfg=json.loads((self.state/'apns-config.json').read_text())
        except (OSError,ValueError):return None
        if not isinstance(cfg,dict):return None
        if any(not isinstance(cfg.get(k),str) or not cfg[k] for k in ('team_id','key_id','key_path')):return None
        if cfg.get('topic','work.eddie.com')!='work.eddie.com':return None
        if not Path(cfg['key_path']).expanduser().is_file():return None
        return cfg

    def bark(self):
        try:cfg=json.loads((self.state/'bark-config.json').read_text())
        except (OSError,ValueError):return None
        if not isinstance(cfg,dict):return None
        key=cfg.get('device_key')
        if not isinstance(key,str) or not re.fullmatch('[0-9A-Za-z]{8,64}',key):return None
        server=str(cfg.get('server') or 'https://api.day.app').rstrip('/')
        if not server.startswith('https://'):return None
        return {'server':server,'device_key':key,'preview':bool(cfg.get('preview',False))}

    def status(self):
        with self.db() as db:
            counts={r[0]:r[1] for r in db.execute('SELECT state,count(*) FROM outbox GROUP BY state')}
            devices=db.execute('SELECT count(*) FROM devices WHERE enabled=1').fetchone()[0]
        delivery='apns' if self.config() and devices else 'bark' if self.bark() else 'background_refresh'
        return {'configured':bool(self.config()),'bark':bool(self.bark()),'registered_devices':devices,'outbox':counts,
                'delivery':delivery,
                'note':'系统通知受权限、网络和专注模式影响；服务受理不等于已显示。'}

    def register(self,data):
        ident=data.get('id');token=data.get('token');env=data.get('environment','sandbox')
        if not isinstance(ident,str) or not 8<=len(ident)<=100:raise ValueError('无效设备标识')
        if not isinstance(token,str) or not re.fullmatch('[0-9a-fA-F]{32,512}',token):raise ValueError('无效通知标识')
        if env not in ('sandbox','production'):raise ValueError('无效推送环境')
        with self.db() as db:
            prior=db.execute('SELECT registered FROM devices WHERE id=?',(ident,)).fetchone()
            # Token changes should not leave a second receiver for the same installation.
            db.execute('INSERT OR REPLACE INTO devices VALUES (?,?,?,?,?)',(ident,token.lower(),env,1,prior[0] if prior else self.clock()))
        return {'status':'completed',**self.status()}

    def disable(self,ident):
        with self.db() as db:
            db.execute('UPDATE devices SET enabled=0 WHERE id=?',(ident,))
            db.execute("UPDATE outbox SET state='cancelled',reason='设备已停用' WHERE device_id=? AND state='queued'",(ident,))
        return {'status':'completed'}

    def enqueue(self):
        with self.db() as db:
            cursor=int(db.execute("SELECT value FROM meta WHERE key='cursor'").fetchone()[0])
            devices=[dict(r) for r in db.execute('SELECT * FROM devices WHERE enabled=1').fetchall()]
            if self.bark():
                # Bark 没有注册流程：第一次发现配置时记下时间，之前的旧消息不补推。
                since=db.execute("SELECT value FROM meta WHERE key='bark_registered'").fetchone()
                if not since:
                    db.execute("INSERT INTO meta VALUES ('bark_registered',?)",(str(self.clock()),));since=(str(self.clock()),)
                devices.append({'id':'bark','registered':float(since[0])})
            with self.conversation.db() as chat:
                messages=[dict(r) for r in chat.execute("SELECT id,request_id,revision,created_at FROM messages WHERE revision>? AND role='assistant' AND status='completed' ORDER BY revision LIMIT 100",(cursor,))]
            for message in messages:
                for device in devices:
                    if message['created_at']<device['registered']:continue
                    # Bark 不知道 App 是否在前台：只推主动消息（简报、提醒、任务回执），不推当面对话的回复。
                    if device['id']=='bark' and not str(message['request_id'] or '').startswith('task-result:'):continue
                    ident=str(uuid.uuid5(uuid.NAMESPACE_URL,device['id']+':'+message['id']))
                    db.execute('INSERT OR IGNORE INTO outbox VALUES (?,?,?,?,?,?,?,?)',
                        (ident,message['id'],device['id'],'queued',0,self.clock(),self.clock(),''))
            if messages:db.execute("UPDATE meta SET value=? WHERE key='cursor'",(str(messages[-1]['revision']),))
        return len(messages)

    def token(self,cfg):
        if self._jwt and self.clock()-self._jwt_at<3000:return self._jwt
        import jwt
        self._jwt=jwt.encode({'iss':cfg['team_id'],'iat':int(self.clock())},Path(cfg['key_path']).expanduser().read_bytes(),algorithm='ES256',headers={'kid':cfg['key_id']})
        self._jwt_at=self.clock();return self._jwt

    async def send_bark(self,row):
        cfg=self.bark()
        body='已为你整理好，点开查看。'
        if cfg['preview']:
            with self.conversation.db() as chat:
                found=chat.execute('SELECT text FROM messages WHERE id=?',(row['message_id'],)).fetchone()
            if found and found[0]:body=str(found[0]).strip().replace('\n',' ')[:80]
        # 10-17：明天建议点开到下一步页的建议卡，航程回执/等你点开到航程列表；其余照旧回对话
        mid=str(row['message_id'])
        url='com-eddie://plan' if mid.startswith('task-result:plan:') else 'com-eddie://cases' if mid.startswith(('task-result:case-wait:','task-result:task_')) else 'com-eddie://today'
        payload={'device_key':cfg['device_key'],'title':'Com','body':body,'group':'com','url':url,'isArchive':'1'}
        async with httpx.AsyncClient(timeout=20,trust_env=False) as client:
            response=await client.post(cfg['server']+'/push',json=payload)
        reason=''
        if response.status_code!=200:
            try:reason=str(response.json().get('message',''))
            except ValueError:reason='invalid_response'
        return response.status_code,reason

    async def send(self,device,row):
        if device.get('id')=='bark':return await self.send_bark(row)
        cfg=self.config()
        host='api.sandbox.push.apple.com' if device['environment']=='sandbox' else 'api.push.apple.com'
        payload={'aps':{'alert':{'title':'Com 有新消息','body':'已为你整理好，点开查看。'},'sound':'default','thread-id':'com-personal'},'comMessageID':row['message_id']}
        headers={'authorization':'bearer '+self.token(cfg),'apns-topic':'work.eddie.com','apns-push-type':'alert',
                 'apns-priority':'10','apns-id':row['id'],'apns-collapse-id':hashlib.sha256(row['message_id'].encode()).hexdigest(),
                 'apns-expiration':str(int(row['created']+86400))}
        async with httpx.AsyncClient(http2=True,timeout=20,trust_env=False) as client:
            response=await client.post('https://'+host+'/3/device/'+device['token'],json=payload,headers=headers)
        reason=''
        if response.status_code!=200:
            try:reason=response.json().get('reason','')
            except ValueError:reason='invalid_response'
        return response.status_code,reason

    async def process(self,sender=None):
        self.enqueue()
        if not (self.config() or self.bark()) and sender is None:return False
        cfg=self.settings();hour=datetime.fromtimestamp(self.clock(),ZoneInfo('Asia/Shanghai')).hour
        start,end=cfg.get('quiet_start',23),cfg.get('quiet_end',8)
        quiet=(hour>=start or hour<end) if start>end else start<=hour<end
        if quiet:return False
        with self.db() as db:
            db.execute("UPDATE outbox SET state='expired',reason='超过24小时' WHERE state='queued' AND created<?",(self.clock()-86400,))
            row=db.execute("SELECT * FROM outbox WHERE state='queued' AND next_at<=? ORDER BY created LIMIT 1",(self.clock(),)).fetchone()
            if not row:return False
            row=dict(row)
            if row['device_id']=='bark':device={'id':'bark','token':'','environment':'bark','enabled':1} if self.bark() else None
            else:device=db.execute('SELECT * FROM devices WHERE id=? AND enabled=1',(row['device_id'],)).fetchone()
            if not device:
                db.execute("UPDATE outbox SET state='cancelled' WHERE id=?",(row['id'],));return True
        try:code,reason=await (sender or self.send)(dict(device),row)
        except Exception as exc:code,reason=0,type(exc).__name__
        attempts=row['attempts']+1
        state='accepted' if code==200 else 'failed' if code in (400,403,404,405,410,413) or attempts>=6 else 'queued'
        with self.db() as db:
            db.execute('UPDATE outbox SET state=?,attempts=?,next_at=?,reason=? WHERE id=?',(state,attempts,self.clock()+min(3600,30*2**attempts),reason[:120],row['id']))
            if device['id']!='bark' and (code==410 or reason in ('BadDeviceToken','DeviceTokenNotForTopic')):db.execute('UPDATE devices SET enabled=0 WHERE id=?',(device['id'],))
        return True
