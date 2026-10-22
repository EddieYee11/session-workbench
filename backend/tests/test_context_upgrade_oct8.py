import asyncio
import json
import sqlite3
import time
import pytest
from hermes_metrics.source_binding import bind_source
from event_copy import display_event
from context_builder import build
from context_working_set import MARKER


def test_binding_is_session_scoped_and_rejects_ambiguity(tmp_path):
    with sqlite3.connect(tmp_path/'personal-conversation.sqlite') as db:
        db.executescript('CREATE TABLE reaction_turns(session_id,message_id,request_id,expires_at); CREATE TABLE messages(id,role,status,request_id);')
        for s in ('main','other'):
            db.execute('INSERT INTO reaction_turns VALUES(?,?,?,?)',(s,s,'r-'+s,time.time()+60))
            db.execute('INSERT INTO messages VALUES(?,?,?,?)',(s,'user','running','r-'+s))
    kwargs=dict(tool_name='mcp__com_workbench__business_operation',state=tmp_path)
    result=bind_source(session_id='main',args={'origin_message_id':'other'},**kwargs)
    assert result['args']['origin_message_id']=='main'
    assert bind_source(session_id='background',**kwargs)['action']=='block'
    with sqlite3.connect(tmp_path/'personal-conversation.sqlite') as db:
        db.execute('INSERT INTO reaction_turns VALUES(?,?,?,?)',('main','another','another',time.time()+60))
        db.execute('INSERT INTO messages VALUES(?,?,?,?)',('another','user','running','another'))
    assert bind_source(session_id='main',**kwargs)['action']=='block'
    assert bind_source(tool_name='mcp__com_workbench__memory_recall',state=tmp_path) is None


def test_schema_thin_but_execution_requires_injected_source(monkeypatch):
    import hermes_mcp as m
    tool=m.mcp._tool_manager.get_tool('business_operation')
    assert not any(x.startswith('origin_') for x in tool.parameters['properties'])
    calls=[]
    monkeypatch.setattr(m,'_shared',lambda *args:calls.append(args) or {'ok':True})
    async def run():
        args={'tool':'remind','args':{'action':'list'}}
        with pytest.raises(Exception):await tool.run(args)
        assert not calls
        await tool.run({**args,'origin_session_id':'s','origin_message_id':'m','origin_request_id':'r'})
        assert calls[0][2]['origin_message_id']=='m'
    asyncio.run(run())


def test_stable_context_key_order_and_no_automatic_memory(tmp_path):
    a={'origin_request_id':'same','tasks':[],'environment':{'timezone':'Asia/Shanghai'}}
    b=dict(reversed(list(a.items())))
    wa=build(tmp_path,MARKER+json.dumps(a)+'\n用户消息：\n你好')
    wb=build(tmp_path,MARKER+json.dumps(b)+'\n用户消息：\n你好')
    assert wa.instructions==wb.instructions
    assert 'origin_request_id' not in wa.instructions and 'same' in wa.source
    assert wa.sizes['memory_chars']==0 and wa.sizes['system_bytes']>0


def test_ui_copy_does_not_promote_tool_completion_to_success():
    assert display_event({'kind':'tool.completed','tool':'task_submit'})=='任务安排已有回执'
    assert display_event({'kind':'tool.failed','tool':'gmail_send'})=='这一步遇到了问题，查看详情'
    text=display_event({'kind':'tool.started','tool':'new_private_implementation_name'})
    assert 'private' not in text
    assert display_event({'status':'unknown'})=='结果还在核实，暂不重复操作'


def test_background_binding_uses_its_original_source_not_foreground(tmp_path):
    with sqlite3.connect(tmp_path/'hermes-runs.sqlite') as db:
        db.executescript('CREATE TABLE tool_sources(request_id,session_id,context); CREATE TABLE runs(request_id,session_id,status);')
        source={'origin_session_id':'main','origin_message_id':'original-user','origin_request_id':'original-request'}
        db.execute('INSERT INTO tool_sources VALUES(?,?,?)',('event','background',json.dumps(source)))
        db.execute('INSERT INTO runs VALUES(?,?,?)',('event','background','running'))
    result=bind_source(tool_name='mcp__com_workbench__task_verify',session_id='background',state=tmp_path)
    assert result=={'action':'modify','args':source}
    with sqlite3.connect(tmp_path/'hermes-runs.sqlite') as db:db.execute("UPDATE runs SET status='completed'")
    assert bind_source(tool_name='mcp__com_workbench__task_verify',session_id='background',state=tmp_path)['action']=='block'


def _seed_turn(root,session_id,message_id,request_id,status='running'):
    with sqlite3.connect(root/'personal-conversation.sqlite') as db:
        db.executescript('CREATE TABLE IF NOT EXISTS reaction_turns(session_id,message_id,request_id,expires_at);'
                         'CREATE TABLE IF NOT EXISTS messages(id,role,status,request_id);')
        db.execute('INSERT OR REPLACE INTO reaction_turns VALUES(?,?,?,?)',(session_id,message_id,request_id,time.time()+60))
        db.execute('INSERT OR REPLACE INTO messages VALUES(?,?,?,?)',(message_id,'user',status,request_id))


def test_superseded_run_binding_never_blocks_the_live_turn(tmp_path):
    stale={'origin_session_id':'main','origin_message_id':'stale-user','origin_request_id':'stale'}
    live={'origin_session_id':'main','origin_message_id':'live-user','origin_request_id':'live'}
    with sqlite3.connect(tmp_path/'hermes-runs.sqlite') as db:
        db.executescript('CREATE TABLE tool_sources(request_id,session_id,context); CREATE TABLE runs(request_id,session_id,status);')
        for source in (stale,live):
            db.execute('INSERT INTO tool_sources VALUES(?,?,?)',(source['origin_request_id'],'main',json.dumps(source)))
            db.execute('INSERT INTO runs VALUES(?,?,?)',(source['origin_request_id'],'main','running'))
    _seed_turn(tmp_path,'main','live-user','live')
    kwargs=dict(tool_name='mcp__com_workbench__business_operation',state=tmp_path)
    # The orphan of a killed worker shares the session but never the live turn.
    assert bind_source(session_id='main',**kwargs)=={'action':'modify','args':live}
    # With the live turn gone, competing durable bindings stay a hard stop, never a guess.
    with sqlite3.connect(tmp_path/'personal-conversation.sqlite') as db:db.execute("UPDATE messages SET status='unknown'")
    assert bind_source(session_id='main',**kwargs)['action']=='block'


def test_dead_worker_run_is_closed_before_the_next_turn(tmp_path):
    from hermes_runtime import HermesRuntime
    client=HermesRuntime(tmp_path,'main')
    with sqlite3.connect(client.path) as db:
        db.execute("INSERT INTO runs VALUES('stale','fp','run_dead','main','running')")
        db.execute("INSERT INTO runs VALUES('ghost','fp','run_ghost','main','running')")
        db.execute("INSERT INTO runs VALUES('live','fp','run_live','main','running')")
        db.execute("INSERT INTO runs VALUES('unadmitted','fp','','main','admitting')")
    seen=[]
    async def request(method,path,body=None,timeout=20):
        seen.append(path)
        return {'status':'completed' if path.endswith('run_dead') else 'unknown' if path.endswith('run_ghost') else 'running'}
    client.request=request
    asyncio.run(client.reconcile_superseded_runs('live'))
    with sqlite3.connect(client.path) as db:
        assert dict(db.execute('SELECT request_id,status FROM runs'))=={
            'stale':'completed','ghost':'unknown','live':'running','unadmitted':'admitting'}
    assert seen==['/v1/runs/run_dead','/v1/runs/run_ghost']
