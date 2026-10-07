"""Authenticated phone nodes with durable invocation receipts and no replay after ACK."""
import asyncio,hashlib,json,re,sqlite3,time,uuid
from pathlib import Path
TOOLS={'calendar.list','calendar.create','calendar.update','calendar.delete','reminders.list','reminders.create','reminders.update','reminders.delete','contacts.search','contacts.create','contacts.update','contacts.delete','apps.list','apps.usage','apps.launch','notifications.list','notifications.dismiss','health.summary','alarm.set','alarm.show','location.last','media.list','device.status','device.vibrate','device.torch','device.volume'}
class DeviceNodes:
    def __init__(self,state):
        self.path=Path(state)/'devices.sqlite';self.sockets={};self.waiters={}
        with self.db() as d:d.executescript('CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,data TEXT);CREATE TABLE IF NOT EXISTS invocations(id TEXT PRIMARY KEY,node TEXT,fingerprint TEXT,data TEXT);CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,invocation_id TEXT,data TEXT);')
        self.path.chmod(0o600)
    def db(self):return sqlite3.connect(self.path)
    def register(self,data):
        ident=data.get('id','')
        if not re.fullmatch(r'node_[0-9a-f]{32}',ident):raise ValueError('Invalid node ID')
        caps=data.get('capabilities',[])
        if not isinstance(caps,list) or len(caps)>64 or any(c.get('tool') not in TOOLS or not isinstance(c.get('permission'),bool) for c in caps):raise ValueError('Unregistered phone capability')
        platform=data.get('platform','android')
        if platform not in ('android','ios'):raise ValueError('Invalid phone platform')
        with self.db() as d:
            old=d.execute('SELECT data FROM devices WHERE id=?',(ident,)).fetchone()
        registered=json.loads(old[0]).get('registered_at',time.time()) if old else time.time()
        row={'id':ident,'name':str(data.get('name','手机'))[:120],'capabilities':caps,'registered_at':registered,'last_seen':time.time(),'platform':platform,'os_version':str(data.get('os_version',''))[:60]}
        with self.db() as d:d.execute('INSERT OR REPLACE INTO devices VALUES(?,?)',(ident,json.dumps(row,ensure_ascii=False)))
        return row
    def list(self):
        with self.db() as d:rows=[json.loads(r[0]) for r in d.execute('SELECT data FROM devices')]
        return [{**r,'online':r['id'] in self.sockets,'capability_count':len(r['capabilities'])} for r in rows]
    def get(self,ident):
        with self.db() as d:r=d.execute('SELECT data FROM invocations WHERE id=?',(ident,)).fetchone()
        return json.loads(r[0]) if r else None
    def save(self,row,event):
        with self.db() as d:
            d.execute('UPDATE invocations SET data=? WHERE id=?',(json.dumps(row,ensure_ascii=False),row['id']))
            d.execute('INSERT INTO events(invocation_id,data) VALUES(?,?)',(row['id'],json.dumps({'event':event,'at':time.time(),'status':row['status']})))
    async def call(self,node,tool,args,ident,timeout=30):
        if not re.fullmatch(r'[A-Za-z0-9_-]{10,100}',ident):raise ValueError('Invalid invocation ID')
        if tool not in TOOLS or not isinstance(args,dict):raise ValueError('Unknown phone tool')
        fp=hashlib.sha256(json.dumps([node,tool,args],sort_keys=True).encode()).hexdigest()
        with self.db() as d:
            old=d.execute('SELECT fingerprint,data FROM invocations WHERE id=?',(ident,)).fetchone()
            if old:
                if old[0]!=fp:raise ValueError('Invocation ID conflicts')
                return {**json.loads(old[1]),'duplicate':True}
            device=next((r for r in self.list() if r['id']==node),None)
            capability=next((r for r in device['capabilities'] if r['tool']==tool),None) if device else None
            status='offline' if not device or not device['online'] else 'unregistered' if not capability else 'unavailable' if not capability.get('available',True) else 'permission_denied' if not capability['permission'] else 'pending'
            row={'id':ident,'node':node,'tool':tool,'args':args,'timeout':max(1,min(timeout,120)),'status':status,'created_at':time.time(),'result':None}
            d.execute('INSERT INTO invocations VALUES(?,?,?,?)',(ident,node,fp,json.dumps(row)))
        if status!='pending':return row
        future=asyncio.get_running_loop().create_future();self.waiters[ident]=future
        try:
            await self.sockets[node].send_json({'type':'invocation',**row})
            return await asyncio.wait_for(asyncio.shield(future),row['timeout'])
        except (TimeoutError,RuntimeError):
            saved=self.get(ident);saved.update(status='unknown',reason='设备执行回执尚未返回；不会重放');self.save(saved,'timeout');return saved
        finally:self.waiters.pop(ident,None)
    async def result(self,node,data):
        row=self.get(data.get('id'))
        if not row or row['node']!=node:raise ValueError('Invocation does not belong to this node')
        typ=data.get('type');status=data.get('status')
        if row['status'] in ('succeeded','failed','permission_denied'):return row
        if typ=='result':
            if status not in ('succeeded','failed','permission_denied','unknown'):raise ValueError('Invalid result status')
            row.update(status=status,result=data.get('result'),finished_at=time.time());self.save(row,typ)
            f=self.waiters.get(row['id'])
            if f and not f.done():f.set_result(row)
        elif typ in ('ack','progress'):
            row.update(status='executing',progress=str(data.get('progress',''))[:500]);self.save(row,typ)
        return row
    async def socket(self,ws,node):
        if not any(r['id']==node for r in self.list()):await ws.close(code=1008);return
        await ws.accept();old=self.sockets.get(node)
        if old:await old.close(code=1012)
        self.sockets[node]=ws
        try:
            # Snapshot contains ACKed work, never resend uncertain side effects.
            with self.db() as d:rows=[json.loads(r[0]) for r in d.execute('SELECT data FROM invocations WHERE node=?',(node,))]
            await ws.send_json({'type':'snapshot','invocations':rows[-100:]})
            while True:
                data=await asyncio.wait_for(ws.receive_json(),45)
                if data.get('type')=='heartbeat':await ws.send_json({'type':'heartbeat','time':time.time()})
                else:await self.result(node,data)
        finally:
            if self.sockets.get(node) is ws:self.sockets.pop(node,None)
