import json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from history import History

def write(p,rows):p.parent.mkdir(parents=True,exist_ok=True);p.write_text('\n'.join(json.dumps(x,ensure_ascii=False) for x in rows)+'\n')
def test_pi_search_and_source_untouched(tmp_path):
 p=tmp_path/'.pi/agent/sessions/project/a.jsonl'
 rows=[{'type':'session','id':'pi-a','cwd':str(tmp_path),'timestamp':'2026-09-30T00:00:00Z'}, {'type':'message','id':'u','message':{'role':'user','content':[{'type':'text','text':'排查网络'}]}}, {'type':'message','id':'a','message':{'role':'assistant','content':[{'type':'text','text':'Clash 路由检查成功'}]}}]
 write(p,rows);original=p.read_bytes();h=History(tmp_path,tmp_path/'state');h.scan();h.scan()
 result=h.list('Clash 路由');assert len(result)==1;assert result[0]['hit_count']==1;assert result[0]['matches']==['a']
 assert not h.list('Clash','', 'user');assert p.read_bytes()==original
 h.label('pi:pi-a',{'archived':1,'title':'自定义'})
 assert not h.list();assert h.list(archived=True)[0]['display_title']=='自定义';assert p.read_bytes()==original
 rows.append({'type':'message','id':'b','message':{'role':'user','content':'增量唯一词'}});write(p,rows);h.scan()
 assert len(h.messages('pi:pi-a'))==3
 assert h.list('增量唯一词',archived=True)[0]['matches']==['b']

def test_codex_dedup_projection_and_partial(tmp_path):
 import sqlite3
 p=tmp_path/'.codex/sessions/a.jsonl';write(p,[{'type':'session_meta','payload':{'id':'c','cwd':str(tmp_path)}},{'type':'response_item','payload':{'type':'message','role':'assistant','content':[{'text':'旧投影'}]}}])
 db=sqlite3.connect(tmp_path/'.codex/thread_history_1.sqlite');db.execute('CREATE TABLE thread_items(thread_id,item_id,item_json,created_at_ms,rollout_ordinal)');db.execute('INSERT INTO thread_items VALUES(?,?,?,?,?)',('c','i',json.dumps({'type':'agentMessage','text':'投影正文唯一命中'}),10,1));db.commit();db.close()
 with p.open('a') as f:f.write('{"type":')
 h=History(tmp_path,tmp_path/'state');h.scan();h.scan()
 assert len(h.list())==1;assert len(h.messages('codex:c'))==1;assert h.list('正文')[0]['matches']==['i']
 assert h.progress['unreadable']==0

def test_unicode_search_literal_sql_and_filters(tmp_path):
 p=tmp_path/'.pi/agent/sessions/a.jsonl';write(p,[{'type':'session','id':'x','cwd':'/demo'},{'type':'message','id':'u','message':{'role':'user','content':'100% _ \' SQL 中文测试'}}])
 h=History(tmp_path,tmp_path/'state');h.scan()
 assert len(h.list("%'"))==0;assert len(h.list("% _"))==1;assert len(h.list("中文",agent='pi',cwd='/demo'))==1
 assert not h.list('中文',agent='codex')
