"""Read-only source discovery; derived SQLite index never edits agent history."""
import json, sqlite3, time, hashlib, threading
from contextlib import contextmanager
from pathlib import Path
from datetime import datetime


def text_content(value):
    if isinstance(value,str): return value
    if isinstance(value,list):
        return '\n'.join(text_content(x) for x in value if isinstance(x,(dict,str)))
    if isinstance(value,dict):
        if value.get('type') in ('image','input_image','image_url'): return '[图片]'
        return str(value.get('text',value.get('output',value.get('content',''))))
    return ''


def timestamp(v):
    if isinstance(v,(float,int)): return v / 1000 if v > 1e11 else float(v)
    try: return datetime.fromisoformat(v.replace('Z','+00:00')).timestamp()
    except Exception: return 0


def codex_item(item, ident, ts=0):
    typ=item.get('type',''); role='tool'; title=typ; body=''
    if typ in ('userMessage','user_message'): role='user';body=text_content(item.get('content',[]))
    elif typ in ('agentMessage','agent_message'): role='assistant';body=item.get('text','')
    elif typ in ('commandExecution','command_execution'):
        title=item.get('command','命令');body=item.get('aggregatedOutput',item.get('aggregated_output','')) or ''
    elif typ in ('fileChange','file_change'): title='文件变更';body=json.dumps(item.get('changes',[]),ensure_ascii=False)
    elif typ in ('mcpToolCall','dynamicToolCall'): title=item.get('tool',item.get('toolName',typ));body=json.dumps(item,ensure_ascii=False)
    elif typ in ('reasoning','plan'):
        role='progress';title='进度';body=text_content(item.get('summary',item.get('text','')))
    else: body=text_content(item.get('text',item.get('content','')))
    return {'id':str(ident),'role':role,'title':title,'text':body,'time':ts} if body or title not in ('userMessage','agentMessage') else None


class History:
    def __init__(self,home,state):
        self.home=Path(home);self.state=Path(state);self.state.mkdir(parents=True,exist_ok=True)
        self.dbpath=self.state/'index.sqlite';self.lock=threading.RLock()
        self.progress={'scanning':False,'done':0,'total':0,'unreadable':0,'updated':0}
        with self.db() as d:
            d.executescript('''PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,agent TEXT,native_id TEXT,path TEXT,cwd TEXT,title TEXT,updated REAL,signature TEXT,coverage TEXT);
            CREATE TABLE IF NOT EXISTS messages(sid TEXT,mid TEXT,position INTEGER,role TEXT,title TEXT,body TEXT,time REAL,PRIMARY KEY(sid,mid));
            CREATE TABLE IF NOT EXISTS message_turns(sid TEXT,mid TEXT,turn_id TEXT,PRIMARY KEY(sid,mid));
            CREATE INDEX IF NOT EXISTS message_sid ON messages(sid,position);
            CREATE TABLE IF NOT EXISTS labels(sid TEXT PRIMARY KEY,title TEXT,pinned INTEGER DEFAULT 0,archived INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS managed(sid TEXT PRIMARY KEY,data TEXT);
            CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY,fingerprint TEXT,data TEXT);
            ''')
    @contextmanager
    def db(self):
        d=sqlite3.connect(self.dbpath,timeout=20);d.row_factory=sqlite3.Row
        try:
            with d:yield d
        finally:
            d.close()
    def sources(self):
        result={}
        for agent,root in [('pi',self.home/'.pi/agent/sessions'),('codex',self.home/'.codex/sessions'),('codex',self.home/'.codex/archived_sessions')]:
            for p in root.rglob('*.jsonl'):
                if '.sync-conflict-' in p.name:continue
                try:
                    with p.open() as f:meta=json.loads(f.readline())
                    m=meta.get('payload',meta);nid=m.get('id',m.get('session_id'))
                    if not nid:continue
                    st=p.stat();s={'id':agent+':'+nid,'agent':agent,'native_id':nid,'path':str(p),'cwd':m.get('cwd',''),'title':'','updated':st.st_mtime,'signature':f'v2:{st.st_mtime_ns}:{st.st_size}','coverage':'仅展示原会话实际保存的内容；未保存的实时输出无法补齐。'}
                    if s['id'] not in result or result[s['id']]['updated']<s['updated']:result[s['id']]=s
                except Exception:self.progress['unreadable']+=1
        for p in (self.home/'.claude/projects').rglob('*.jsonl'):
            if '.sync-conflict-' in p.name or 'subagents' in p.parts:continue
            try:
                meta=None
                with p.open() as f:
                    for _ in range(12):
                        line=f.readline()
                        if not line:break
                        row=json.loads(line)
                        if row.get('sessionId') and row.get('cwd'):
                            meta=row;break
                if not meta:continue
                nid=meta['sessionId'];stat=p.stat()
                result['claude:'+nid]={'id':'claude:'+nid,'agent':'claude','native_id':nid,'path':str(p),
                    'cwd':meta['cwd'],'title':'','updated':stat.st_mtime,
                    'signature':f'claude:{stat.st_mtime_ns}:{stat.st_size}','coverage':'Claude 原生历史只读'}
            except (OSError,ValueError):self.progress['unreadable']+=1
        for p in (self.home/'.codex').glob('state_*.sqlite'):
            try:
                d=sqlite3.connect(f'file:{p}?mode=ro',uri=True);d.row_factory=sqlite3.Row
                for row in d.execute('SELECT * FROM threads'):
                    r=dict(row);sid='codex:'+r['id'];old=result.get(sid,{})
                    if not old:
                        old={'id':sid,'agent':'codex','native_id':r['id'],'path':r['rollout_path'],'coverage':'仅展示已保存内容；未保存的实时输出无法补齐。','signature':''}
                    old.update(cwd=r['cwd'],title=r.get('name') or r.get('title',''),updated=max(old.get('updated',0),r['updated_at']))
                    old['signature']+=f":{r['updated_at']}:{r.get('tokens_used',0)}:{r.get('title','')}"
                    result[sid]=old
                d.close()
            except Exception:self.progress['unreadable']+=1
        return result
    def parse(self,s):
        out=[];p=Path(s['path']);agent=s['agent'];name=s['title'];seq=0
        if p.is_file():
            with p.open() as f:
                for line in f:
                    seq+=1
                    try:r=json.loads(line)
                    except json.JSONDecodeError:continue # tolerate the currently written partial line
                    ts=timestamp(r.get('timestamp'));typ=r.get('type');v=r.get('payload',{});role=None;body='';title=''
                    mid=r.get('id',str(r.get('ordinal',seq)));calls=[]
                    if agent=='pi':
                        if typ=='session_info':name=r.get('name',name)
                        if typ!='message':continue
                        v=r.get('message',{});role=v.get('role')
                        if v.get('timestamp'):mid='pi:'+str(v['timestamp'])
                        if role=='user' and isinstance(v.get('com_request_id'),str):mid='pi:com:'+v['com_request_id']
                        if v.get('toolCallId'):mid=v['toolCallId']
                        if role not in ('user','assistant','toolResult','bashExecution'):continue
                        title=v.get('toolName','');body=text_content(v.get('content',v.get('output','')))
                        if role=='assistant':
                            for i,c in enumerate(v.get('content',[]) if isinstance(v.get('content'),list) else []):
                                if c.get('type')=='toolCall':calls.append({'id':f'{mid}:call:{i}','role':'tool','title':c.get('name','工具'),'text':json.dumps(c.get('arguments',{}),ensure_ascii=False),'time':ts})
                        if role in ('toolResult','bashExecution'):role='tool'
                    elif agent=='claude':
                        if typ not in ('user','assistant'):continue
                        v=r.get('message',{});role=typ
                        mid=r.get('uuid',str(seq));body=text_content(v.get('content',''))
                        if role=='assistant':
                            for i,c in enumerate(v.get('content',[]) if isinstance(v.get('content'),list) else []):
                                if c.get('type')=='tool_use':calls.append({'id':f'{mid}:call:{i}','role':'tool','title':c.get('name','工具'),'text':json.dumps(c.get('input',{}),ensure_ascii=False),'time':ts})
                    else:
                        if typ!='response_item':continue
                        role=v.get('role');pt=v.get('type','')
                        if pt=='message' and role in ('user','assistant'):body=text_content(v.get('content',[]))
                        elif pt in ('function_call','custom_tool_call'):role='tool';title=v.get('name','工具');body=v.get('arguments',v.get('input',''))
                        elif pt in ('function_call_output','custom_tool_call_output'):role='tool';title='工具输出';body=text_content(v.get('output',''))
                        else:continue
                    if body:
                        if role=='user' and (body.startswith('<environment_context>') or body.startswith('# AGENTS.md') or body.startswith('<permissions')):continue
                        out.append({'id':str(mid),'role':role,'title':title,'text':str(body),'time':ts})
                    out.extend(calls)
        if agent=='codex':
            hp=self.home/'.codex/thread_history_1.sqlite'
            if hp.exists():
                try:
                    d=sqlite3.connect(f'file:{hp}?mode=ro',uri=True)
                    has_turn=any(r[1]=='turn_id' for r in d.execute('PRAGMA table_info(thread_items)'))
                    rows=d.execute('SELECT item_id,item_json,created_at_ms,'+('turn_id' if has_turn else 'NULL')+' FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal',(s['native_id'],)).fetchall();d.close()
                    parsed=[]
                    for i,v,t,turn in rows:
                        item=codex_item(json.loads(v),i,t/1000)
                        if item and turn:item['turn_id']=turn
                        parsed.append(item)
                    # Projection contains the complete canonical transcript when present.
                    if rows:out=[x for x in parsed if x and (x['text'] or x['role']=='tool')]
                except sqlite3.Error:self.progress['unreadable']+=1
        if not name:name=next((m['text'].splitlines()[0][:90] for m in out if m['role']=='user'),'未命名会话')
        return name,out
    def scan(self):
        if not self.lock.acquire(blocking=False):return
        try:
            self.progress.update(scanning=True,done=0,total=0,unreadable=0)
            sources=self.sources();self.progress['total']=len(sources)
            with self.db() as d:
                # Publish metadata first, then index messages. Existing indexed signatures stay intact.
                for s in sources.values():
                    d.execute('INSERT OR IGNORE INTO sessions VALUES(?,?,?,?,?,?,?,?,?)',tuple(s[k] for k in ('id','agent','native_id','path','cwd','title','updated'))+('',s['coverage']))
            for s in sources.values():
                try:
                    with self.db() as d:
                        row=d.execute('SELECT signature FROM sessions WHERE id=?',(s['id'],)).fetchone()
                        if row and row[0]==s['signature']:continue
                        name,messages=self.parse(s);s['title']=name
                        d.execute('INSERT OR REPLACE INTO sessions VALUES(?,?,?,?,?,?,?,?,?)',tuple(s[k] for k in ('id','agent','native_id','path','cwd','title','updated','signature','coverage')))
                        d.execute('DELETE FROM messages WHERE sid=?',(s['id'],))
                        d.execute('DELETE FROM message_turns WHERE sid=?',(s['id'],))
                        d.executemany('INSERT OR REPLACE INTO messages VALUES(?,?,?,?,?,?,?)',[(s['id'],m['id'],i,m['role'],m['title'],m['text'],m['time']) for i,m in enumerate(messages)])
                        d.executemany('INSERT OR REPLACE INTO message_turns VALUES(?,?,?)',[(s['id'],m['id'],m['turn_id']) for m in messages if m.get('turn_id')])
                except Exception:self.progress['unreadable']+=1
                finally:self.progress['done']+=1
            self.progress['updated']=time.time()
        finally:self.progress['scanning']=False;self.lock.release()
    def get(self,sid):
        with self.db() as d:
            r=d.execute('SELECT s.*,coalesce(l.title,s.title) display_title,coalesce(l.pinned,0) pinned,coalesce(l.archived,0) archived FROM sessions s LEFT JOIN labels l ON s.id=l.sid WHERE s.id=?',(sid,)).fetchone()
            return dict(r) if r else None
    def list(self,q='',agent='',role='',cwd='',after=0,sort='recent',archived=False):
        with self.db() as d:
            rows=d.execute('SELECT s.*,coalesce(l.title,s.title) display_title,coalesce(l.pinned,0) pinned,coalesce(l.archived,0) archived FROM sessions s LEFT JOIN labels l ON s.id=l.sid ORDER BY s.updated DESC').fetchall()
            out=[]
            terms=q.casefold().split()
            for row in rows:
                s=dict(row)
                if (agent and s['agent']!=agent) or (cwd and s['cwd']!=cwd) or s['updated']<after or bool(s['archived'])!=archived:continue
                s['matches']=[];s['snippet']='';s['hit_count']=0
                if terms:
                    for m in d.execute('SELECT mid,role,title,body,position FROM messages WHERE sid=? ORDER BY position',(s['id'],)):
                        if role and m['role']!=role:continue
                        body=m['title']+'\n'+m['body'];low=body.casefold()
                        if all(t in low for t in terms):
                            s['matches'].append(m['mid']);s['hit_count']+=1
                            if not s['snippet']:
                                ix=low.find(terms[0]);s['snippet']=body[max(0,ix-50):ix+180]
                    if not s['hit_count'] and (role or not all(t in s['display_title'].casefold() for t in terms)):continue
                out.append(s)
            out.sort(key=lambda s:(s['pinned'],s['hit_count'] if q and sort=='relevance' else 0,s['updated']),reverse=True)
            return out
    def messages(self,sid):
        with self.db() as d:return [dict(id=r['mid'],role=r['role'],title=r['title'],text=r['body'],time=r['time'],**({'turn_id':r['turn_id']} if r['turn_id'] else {})) for r in d.execute('SELECT m.*,t.turn_id FROM messages m LEFT JOIN message_turns t ON m.sid=t.sid AND m.mid=t.mid WHERE m.sid=? ORDER BY m.position',(sid,))]
    def managed(self):
        with self.db() as d:return {r[0]:json.loads(r[1]) for r in d.execute('SELECT sid,data FROM managed')}
    def save_managed(self,sid,value):
        with self.db() as d:d.execute('INSERT OR REPLACE INTO managed VALUES(?,?)',(sid,json.dumps(value,ensure_ascii=False)))
    def label(self,sid,patch):
        with self.db() as d:
            d.execute('INSERT OR IGNORE INTO labels(sid) VALUES(?)',(sid,))
            for k in ('title','pinned','archived'):
                if k in patch:d.execute(f'UPDATE labels SET {k}=? WHERE sid=?',(patch[k],sid))
