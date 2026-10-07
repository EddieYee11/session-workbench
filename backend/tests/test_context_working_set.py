import asyncio
import json
import sqlite3
import sys
from pathlib import Path
from unittest.mock import AsyncMock

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from context_working_set import MARKER,compact_context,parse_input,history,read_history,HISTORY_BYTES
from conversation import PersonalConversation
from hermes_runtime import HermesRuntime


def test_working_set_keeps_raw_user_and_identity_not_full_snapshots():
    context={'origin_request_id':'r1','reaction':{'token':'fixture'},'environment':{'current_date':'2026-10-07','huge':'x'*10000},
             'tasks':[{'id':str(i),'status':'running','title':'任务','result':'x'*20000} for i in range(30)]}
    original='一段原文\n用户消息：\n这仍属于原文'
    text=MARKER+json.dumps(context)+'\n能力清单'+('x'*10000)+'\n用户消息：\n'+original
    output,source=parse_input(text)
    assert output.endswith(original) and len(output)<1600
    assert source==context
    compact=compact_context(context)
    assert len(compact['tasks'])==5 and compact['task_count']==30
    assert compact['reaction']['token']=='fixture' and compact['environment']['current_date']=='2026-10-07'


def test_history_is_bounded_and_older_records_remain_addressable(tmp_path):
    chat=PersonalConversation(tmp_path)
    with chat.db() as db:
        for i in range(20):
            db.execute('INSERT INTO messages(id,request_id,role,text,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?)',
                (str(i),'r'+str(i),'user' if i%2==0 else 'assistant','之前的决定 '+('原文'*8000),'completed',i,i))
    rows=history(tmp_path,'r19')
    assert sum(len(x['content'].encode()) for x in rows)<=HISTORY_BYTES
    assert all('[消息ID:19 ' not in x['content'] for x in rows)
    exact=read_history(tmp_path,reference='0')['items'][0]
    assert exact['id']=='0' and exact['truncated']
    reconstructed=exact['text']
    while exact['next_offset'] is not None:
        exact=read_history(tmp_path,reference='0',offset=exact['next_offset'])['items'][0]
        reconstructed+=exact['text']
    assert reconstructed=='之前的决定 '+('原文'*8000)
    assert read_history(tmp_path,query='不存在')['items']==[]
    assert read_history(tmp_path,query='%')['items']==[]
    ids=[];cursor=''
    while True:
        page=read_history(tmp_path,query='之前的决定',before=cursor)
        ids.extend(item['id'] for item in page['items'])
        if not page['has_more']:break
        cursor=page['next_before']
    assert len(ids)==20 and len(set(ids))==20
    with chat.db() as db:assert db.execute('select count(*) from messages').fetchone()[0]==20


def test_main_turn_does_not_automatically_read_memory(tmp_path,monkeypatch):
    import memory
    monkeypatch.setattr(memory,'recall',AsyncMock(side_effect=AssertionError('automatic memory request')))
    async def run():
        client=HermesRuntime(tmp_path);captured=[]
        async def stream(text,request_id,**kwargs):
            captured.append((text,client.turn_history));yield 'assistant.completed',{'content':'你好'}
        client.stream=stream
        text=MARKER+json.dumps({'origin_request_id':'hello'})+'\n用户消息：\n你好'
        events=[x async for x in client.stream_chat('main',text)]
        assert events and captured[0][0].endswith('你好') and captured[0][1]
        with sqlite3.connect(client.path) as db:
            metrics=json.loads(db.execute('select data from context_metrics').fetchone()[0])
            assert metrics['automatic_memory_calls']==0 and metrics['history_rows']==1
    asyncio.run(run())


def test_frozen_context_retry_keeps_original_payload(tmp_path,monkeypatch):
    import httpx
    from contextlib import asynccontextmanager
    class Response:
        status_code=200
        def json(self):return {'run_id':'run_fixture'}
    class HTTP:
        async def __aenter__(self):return self
        async def __aexit__(self,*_):pass
        async def post(self,*_,**kwargs):return Response()
    monkeypatch.setattr(httpx,'AsyncClient',lambda **_:HTTP())
    async def run():
        client=HermesRuntime(tmp_path);client.create_session=AsyncMock();client.key=lambda:'fixture'
        client.turn_history=[{'role':'user','content':'old'}]
        assert await client.submit_run('hello','request')=='run_fixture'
        client.turn_history=[{'role':'user','content':'changed history'}]
        assert await client.submit_run('hello','request')=='run_fixture'
        import pytest
        with pytest.raises(ValueError):await client.submit_run('changed user message','request')
    asyncio.run(run())


def test_current_memory_works_when_index_is_unavailable(tmp_path,monkeypatch):
    import memory,memory_catalog
    monkeypatch.setattr(memory,'ROOT',tmp_path)
    original=memory_catalog.MemoryCatalog
    monkeypatch.setattr(memory_catalog,'MemoryCatalog',lambda:original(tmp_path))
    cat=original(tmp_path)
    first=cat.save('喜欢蓝色','兴趣',{'message_id':'user','quote':'喜欢蓝色'})
    current=cat.save('现在喜欢绿色','兴趣',{'message_id':'correction','quote':'现在喜欢绿色'},first['id'],expected_version=1)
    monkeypatch.setattr(memory,'recall',AsyncMock(return_value={'status':'unavailable','items':[]}))
    result=asyncio.run(memory.recall_on_demand('喜欢什么颜色'))
    assert result['status']=='partial' and result['items'][0]['version']==2
    assert result['items'][0]['text']=='现在喜欢绿色'


def test_semantic_outage_falls_back_to_current_sanitized_markdown(tmp_path,monkeypatch):
    import memory,memory_catalog
    monkeypatch.setattr(memory,'ROOT',tmp_path)
    original=memory_catalog.MemoryCatalog
    monkeypatch.setattr(memory_catalog,'MemoryCatalog',lambda:original(tmp_path))
    p=tmp_path/'_global/本体画像/00-核心身份.md';p.parent.mkdir(parents=True)
    p.write_text('长期偏好：喜欢绿色。\n密码: fixture-secret')
    monkeypatch.setattr(memory,'recall',AsyncMock(return_value={'status':'unavailable','items':[]}))
    result=asyncio.run(memory.recall_on_demand('喜欢绿色'))
    assert result['status']=='partial'
    assert result['items'][0]['sha256']==memory.digest(p.read_bytes())
    assert 'fixture-secret' not in result['items'][0]['text']
    p.write_text('长期偏好：喜欢红色。')
    result=asyncio.run(memory.recall_on_demand('喜欢红色'))
    assert result['items'][0]['text']=='长期偏好：喜欢红色。'
