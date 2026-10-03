"""Com SQLite goals and durable wake-ups; scheduler registers events, never runs models."""
import hashlib
import json
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo('Asia/Shanghai')


class GoalEvents:
    def __init__(self, state, clock=time.time):
        self.path = Path(state) / 'goals.sqlite'
        self.clock = clock
        with self.db() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS goals(id TEXT PRIMARY KEY,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,kind TEXT NOT NULL,data TEXT NOT NULL,
              priority INTEGER NOT NULL,state TEXT NOT NULL,created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            ''')
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path,timeout=20)
        db.row_factory=sqlite3.Row
        try:
            with db:
                db.execute('BEGIN IMMEDIATE')
                yield db
        finally:
            db.close()

    def enqueue(self, ident, kind, data, priority=10):
        with self.db() as db:
            changed=db.execute('INSERT OR IGNORE INTO events VALUES (?,?,?,?,?,?)',
                       (ident,kind,json.dumps(data,ensure_ascii=False),priority,'queued',self.clock()))
            return bool(changed.rowcount)

    def upsert(self, data, authorization):
        ident = data.get('goal_id') or 'goal_'+hashlib.sha256(data['request_id'].encode()).hexdigest()[:24]
        with self.db() as db:
            old = db.execute('SELECT data FROM goals WHERE id=?',(ident,)).fetchone()
            prior=json.loads(old[0]) if old else {}
            fingerprint=hashlib.sha256(json.dumps(data,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
            if prior.get('request_id')==data['request_id']:
                if prior.get('fingerprint')!=fingerprint:raise ValueError('目标请求标识冲突')
                return prior
            if prior and prior['authorization']['origin_message_id']!=authorization['origin_message_id']:
                # New explicit user message supplies a new scope, rather than inheriting silently.
                prior['previous_authorization']=prior['authorization']
            goal={**prior,'id':ident,'owner_conversation_id':'personal-main','status':'active',
                  'title':data['title'],'completion_condition':data['completion_condition'],
                  'next_step':data['next_step'],'authorization':authorization,
                  'due_at':data.get('due_at'),
                  'request_id':data['request_id'],'fingerprint':fingerprint,
                  'task_ids':prior.get('task_ids',[]),'updated_at':self.clock()}
            db.execute('INSERT OR REPLACE INTO goals VALUES (?,?)',(ident,json.dumps(goal,ensure_ascii=False)))
        return goal

    def update(self,ident,status,next_step='',evidence=None):
        if status not in ('active','waiting_acceptance','blocked','completed','cancelled'):
            raise ValueError('Invalid goal status')
        if status=='completed' and not evidence:
            raise ValueError('目标完成需证据，不能仅凭自由文本')
        with self.db() as db:
            row=db.execute('SELECT data FROM goals WHERE id=?',(ident,)).fetchone()
            if not row:raise ValueError('目标不存在')
            goal=json.loads(row[0]);goal.update(status=status,next_step=next_step,evidence=evidence or [],updated_at=self.clock())
            db.execute('UPDATE goals SET data=? WHERE id=?',(json.dumps(goal,ensure_ascii=False),ident))
        return goal

    def list(self):
        with self.db() as db:
            return [json.loads(r[0]) for r in db.execute('SELECT data FROM goals')]

    def link(self, goal_id, task_id, node_id='', depends_on=None):
        with self.db() as db:
            row=db.execute('SELECT data FROM goals WHERE id=?',(goal_id,)).fetchone()
            if not row:
                raise ValueError('目标不存在')
            goal=json.loads(row[0])
            if task_id not in goal['task_ids']:
                goal['task_ids'].append(task_id)
            if node_id:
                nodes=goal.setdefault('plan_nodes',[])
                prior=next((node for node in nodes if node['id']==node_id),None)
                if prior and prior['task_id']!=task_id:raise ValueError('计划节点已有任务')
                if not prior:nodes.append({'id':node_id,'task_id':task_id,'depends_on':depends_on or []})
            db.execute('UPDATE goals SET data=? WHERE id=?',(json.dumps(goal,ensure_ascii=False),goal_id))

    def enabled(self):
        with self.db() as db:
            row=db.execute("SELECT value FROM settings WHERE key='scheduler_enabled'").fetchone()
        return bool(row and row[0]=='true')

    def set_enabled(self, enabled, *, acceptance=False):
        if enabled and not acceptance:
            raise ValueError('目标调度需真机验收记录')
        with self.db() as db:
            db.execute("INSERT OR REPLACE INTO settings VALUES ('scheduler_enabled',?)",('true' if enabled else 'false',))

    def tick(self):
        if not self.enabled():
            return 0
        now=datetime.fromtimestamp(self.clock(),TZ)
        count=0
        for goal in self.list():
            if goal['status']=='active' and goal['next_step'].strip():
                if goal.get('due_at') and goal['due_at']<=self.clock():
                    count+=int(self.enqueue('due:'+goal['id']+':'+str(goal['due_at']),'goal_due',
                         {'goal':goal,'authorization':goal['authorization']}))
                if (now.hour,now.minute)<(9,30):continue
                count+=int(self.enqueue('daily:'+now.date().isoformat()+':'+goal['id'],'goal_due',
                             {'goal':goal,'authorization':goal['authorization']}))
        return count

    def claim(self):
        with self.db() as db:
            row=db.execute("SELECT * FROM events WHERE state='queued' AND kind<>'user' ORDER BY priority,created,id LIMIT 1").fetchone()
            if not row:
                return None
            db.execute("UPDATE events SET state='sending' WHERE id=?",(row['id'],))
            return {**dict(row),'data':json.loads(row['data'])}

    def finish(self, ident, state):
        if state not in ('completed','uncertain'):
            raise ValueError('Invalid event result')
        with self.db() as db:
            db.execute('UPDATE events SET state=? WHERE id=?',(state,ident))

    def recover(self):
        with self.db() as db:
            db.execute("UPDATE events SET state='uncertain' WHERE state='sending'")
