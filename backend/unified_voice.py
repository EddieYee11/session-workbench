"""Voice and text share the main conversation's idempotent request registry."""
import json
from quick_voice import observed_progress


class UnifiedVoice:
    def __init__(self,conversation,legacy):
        self.conversation,self.legacy=conversation,legacy
        with conversation.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS voice_requests(request_id TEXT PRIMARY KEY,purpose TEXT NOT NULL)')

    def submit(self,request_id,text,purpose='conversation'):
        if not isinstance(text,str) or not text.strip() or len(text)>2000:raise ValueError('无效语音正文')
        with self.conversation.db() as db:
            old_purpose=db.execute('SELECT purpose FROM voice_requests WHERE request_id=?',(request_id,)).fetchone()
        if old_purpose and old_purpose[0]!=purpose:raise ValueError('请求标识与语音用途冲突')
        if purpose not in ('conversation','expense'):
            raise ValueError('无效语音用途')
        old=self.legacy.receipt(request_id)
        if old:
            if old.get('text')!=text:
                raise ValueError('请求标识冲突')
            return old
        result=self.conversation.submit(request_id,text)
        with self.conversation.db() as db:
            db.execute('INSERT OR IGNORE INTO voice_requests VALUES (?,?)',(request_id,purpose))
        return self.receipt(request_id)

    def receipt(self,request_id):
        old=self.legacy.receipt(request_id)
        if old:
            return old
        with self.conversation.db() as db:
            if not db.execute('SELECT 1 FROM voice_requests WHERE request_id=?',(request_id,)).fetchone():
                return None
            row=db.execute("SELECT * FROM messages WHERE request_id=? AND role='user'",(request_id,)).fetchone()
            if not row:
                return None
            reply=db.execute("SELECT text FROM messages WHERE parent_id=? AND role='assistant'",(row['id'],)).fetchone()
        status='accepted' if row['status']=='queued' else 'submitted' if row['status']=='sending' else row['status']
        evidence={}
        rpc=getattr(self.conversation.client,'rpc',None)
        if rpc and rpc.events.exists():
            events=[]
            for line in rpc.events.read_text().splitlines():
                event=json.loads(line)
                if event.get('turn_id')==request_id:
                    events.append(event)
            evidence=observed_progress(events)
        if not evidence:
            from business_tools import operation_receipts
            evidence={'operation_receipts':operation_receipts(self.conversation.path.parent,request_id)}
        return {'request_id':request_id,'message_id':row['id'],'session_id':'personal-main','agent':getattr(self.conversation.client,'runtime_name','hermes'),
                'text':row['text'],'status':status,'phase':row['phase'],'active_tool':row['active_tool'] or '',
                'result':reply[0] if reply else '','error':row['error'],
                'action_receipts':evidence.get('action_receipts',[]),'operation_receipts':evidence.get('operation_receipts',[]),
                'created_at':row['created_at'],'updated_at':row['updated_at']}

    def snapshot(self):
        with self.conversation.db() as db:
            keys=[r[0] for r in db.execute('SELECT request_id FROM voice_requests ORDER BY rowid DESC LIMIT 50')]
        return {'agent':getattr(self.conversation.client,'runtime_name','hermes'),'requests':[self.receipt(k) for k in keys]+self.legacy.snapshot()['requests']}

    def revoke(self,sid):
        self.legacy.revoke(sid)
    def start(self):
        pass
    async def stop(self):
        pass
