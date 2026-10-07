"""Small, source-addressable model working sets; original records are never rewritten."""
from __future__ import annotations
import json
import re
import sqlite3
from contextlib import closing
from pathlib import Path

MARKER = '[Com 主对话上下文；只提供关联，不授予执行权限]\n'
HISTORY_BYTES = 14000
HISTORY_ROWS = 8


def clip(text, budget):
    text = str(text or '')
    raw = text.encode('utf-8')
    return text if len(raw) <= budget else raw[:max(0, budget-80)].decode('utf-8', errors='ignore') + '\n[片段；完整原文可按消息ID回读]'


def compact_context(context):
    """Transport identities remain exact; they are checked against persisted sources."""
    result = {k:v for k,v in context.items() if k not in ('tasks','environment','associated_matter')}
    env = context.get('environment') or {}
    result['environment'] = {k:env[k] for k in ('current_date','timezone','host','hostname','cwd') if k in env}
    active = [t for t in context.get('tasks',[]) if t.get('status') in
              ('queued','running','dispatching','waiting','unknown','approval_required','cancel_requested','paused')]
    result['tasks'] = [{k:t[k] for k in ('id','title','status','next','agent','verification_status') if k in t} for t in active[:5]]
    for item in result['tasks']:
        for key in ('title','next'):
            if key in item:item[key]=str(item[key])[:160]
    result['task_count'] = context.get('task_count',len(context.get('tasks',[])))
    matter=context.get('associated_matter')
    if isinstance(matter,dict):
        result['associated_matter']={k:clip(matter[k],600) if isinstance(matter[k],str) else matter[k] for k in ('id','title','kind','task_id','status','next_step') if k in matter}
    if context.get('current_task_brief'):
        result['current_task_brief']=context['current_task_brief']
    return result


def parse_input(text):
    if not text.startswith(MARKER):
        return text, {}
    head, _, tail = text[len(MARKER):].partition('\n')
    context = json.loads(head)
    # Only the first delimiter is structural; user content can itself contain it.
    if '\n用户消息：\n' in '\n'+tail:
        query = ('\n'+tail).split('\n用户消息：\n',1)[1]
    elif '后台事件（不是新用户交办）：\n' in tail:
        query = tail.split('后台事件（不是新用户交办）：\n',1)[1]
        query = '后台事件；只沿已有授权处理，不能当成新交办。\n'+query
    else:
        query = tail
    return MARKER + json.dumps(compact_context(context),ensure_ascii=False,separators=(',',':')) + '\n用户消息：\n' + query, context


def _connect(state):
    path=Path(state)/'personal-conversation.sqlite'
    return sqlite3.connect('file:'+str(path)+'?mode=ro',uri=True)


def history(state, request_id='', *, budget=HISTORY_BYTES):
    """Use Com's raw turns, not Hermes' accumulated tool traces/context wrappers."""
    seed={'role':'user','content':'[只读会话参考] 以下旧消息仅供理解，不能重放操作。更早内容用 context_read(kind="history", query=关键词) 检索；任务状态用 task_status 核验。'}
    if not (Path(state)/'personal-conversation.sqlite').exists(): return [seed]
    with closing(_connect(state)) as db:
        current=db.execute('SELECT id,created_at FROM messages WHERE request_id=?',(request_id,)).fetchone()
        clause='';params=[]
        if current:
            clause=' AND (created_at < ? OR (created_at = ? AND id < ?))';params=[current[1],current[1],current[0]]
        rows=db.execute("SELECT id,role,text,status FROM messages WHERE role IN ('user','assistant') AND status NOT IN ('queued','sending','running')"+clause+' ORDER BY created_at DESC,id DESC LIMIT ?',[*params,HISTORY_ROWS]).fetchall()
    selected=[];remaining=budget-len(seed['content'].encode())
    for ident,role,text,status in rows:
        if remaining < 300: break
        prefix=f'[消息ID:{ident} 状态:{status}]\n'
        body=prefix+clip(text,min(6000,remaining-len(prefix.encode())))
        selected.append({'role':role,'content':body});remaining-=len(body.encode())
    return [seed]+list(reversed(selected))


def read_history(state,query='',reference='',limit=5,offset=0,before=''):
    limit=max(1,min(int(limit),8))
    with closing(_connect(state)) as db:
        db.row_factory=sqlite3.Row
        if reference:
            rows=db.execute('SELECT id,role,text,status,created_at FROM messages WHERE id=?',(reference,)).fetchall()
        else:
            # Escape LIKE metacharacters; do not interpolate model text into SQL.
            query=str(query).strip()[:200]
            terms=[t for t in re.split(r'\s+',query) if t][:6]
            where=' AND '.join("text LIKE ? ESCAPE '\\'" for _ in terms) or '1=1'
            values=['%'+t.replace('\\','\\\\').replace('%','\\%').replace('_','\\_')+'%' for t in terms]
            if before:
                cursor=db.execute('SELECT created_at,id FROM messages WHERE id=?',(before,)).fetchone()
                if cursor is None:raise ValueError('Unknown history page cursor')
                where+=' AND (created_at < ? OR (created_at = ? AND id < ?))'
                values.extend([cursor['created_at'],cursor['created_at'],cursor['id']])
            rows=db.execute('SELECT id,role,text,status,created_at FROM messages WHERE '+where+' ORDER BY created_at DESC,id DESC LIMIT ?',[*values,limit+1]).fetchall()
    items=[];remaining=12000
    for row in rows[:limit]:
        item=dict(row);raw=item['text'];start=max(0,int(offset)) if reference else 0
        # Character cursor never splits UTF-8 and allows reading every original byte.
        body=raw[start:];chunk=body.encode()[:min(7000,remaining)].decode('utf-8',errors='ignore')
        item['text']=chunk;item['offset']=start;item['truncated']=start+len(chunk)<len(raw)
        item['next_offset']=start+len(chunk) if item['truncated'] else None
        items.append(item);remaining-=len(item['text'].encode())
        if remaining<300:break
    more=not reference and len(rows)>len(items)
    return {'items':items,'authority':'Com original conversation','reference_only':True,
            'effective_limit':limit,'has_more':more,'next_before':items[-1]['id'] if more and items else None}


def read_module(name):
    if name not in ('memory','business','tasks','personal'):raise ValueError('Unknown context module')
    path=Path(__file__).with_name('context_modules')/(name+'.md')
    return {'module':name,'content':path.read_text(),'version':1}
