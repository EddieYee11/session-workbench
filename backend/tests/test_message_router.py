import asyncio
import json
import sqlite3
import sys
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
from unittest.mock import AsyncMock
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from message_router import classify,MessageRouter,receipt
from context_builder import build
from context_working_set import MARKER
from hermes_runtime import HermesRuntime

@pytest.mark.parametrize('text',[
 '不要查最近账单','假设请查最近账单','请查最近账单，再提醒我明天开会',
 '引用：收藏 https://example.com','不要在2027-10-07 14:00提醒我开会',
 '请在2027-99-99 29:99提醒我开会','我朋友午饭30元，记账'])
def test_ambiguous_and_quoted_requests_do_not_bypass_the_agent(text):
    assert classify(text).level!='L0'


def test_routes_cover_existing_business_services_and_keep_richer_work_in_hermes(tmp_path):
    now=datetime(2026,10,7,12,tzinfo=ZoneInfo('Asia/Shanghai'))
    assert classify('查最近账单').args=={'action':'recent','count':5}
    assert classify('查看明天的日程',now).args['start_date']=='2026-10-08'
    assert classify('请在2026-10-08 14:00提醒我开会',now).args['text']=='开会'
    assert classify('收藏链接 https://example.com').tool=='collect'
    assert classify('收藏链接 https://example.com/?q=?').args['url']=='https://example.com/?q=?'
    assert classify('收藏 https://user:password@example.com').level!='L0'
    assert classify('你好').level=='L1'
    assert classify('帮我修复项目代码').level=='L3'
    router=MessageRouter(tmp_path)
    first=router.decide('r1','你好')
    assert router.decide('r1','之后的状态不会修改本轮路由')==first
    with sqlite3.connect(router.path) as db:assert db.execute('SELECT classify_ms FROM decisions').fetchone()[0]<500


def test_context_is_system_side_and_optional_state_is_bounded(tmp_path):
    raw='我的当前原话'+('原文'*10000)
    state={'origin_request_id':'r1','associated_matter':{'id':'matter','title':'题目','huge':'x'*100000},
           'tasks':[{'id':str(i),'title':'任务','status':'running','result':'x'*20000} for i in range(30)]}
    working=build(tmp_path,MARKER+json.dumps(state)+'\n用户消息：\n'+raw)
    assert working.user==raw
    assert working.sizes['context_chars']<2000
    assert 'origin_request_id' not in working.instructions and 'huge' not in working.instructions
    assert json.loads(working.source)['source']['origin_request_id']=='r1'
    assert all('origin_request_id' not in t['content'] for t in working.history)


def test_native_request_contains_raw_user_and_ephemeral_context_without_memory(tmp_path,monkeypatch):
    import httpx
    posted=[]
    class Response:
        status_code=200
        def json(self):return {'run_id':'run_fixture'}
    class HTTP:
        async def __aenter__(self):return self
        async def __aexit__(self,*_):pass
        async def post(self,*_,**kwargs):posted.append(kwargs['json']);return Response()
    monkeypatch.setattr(httpx,'AsyncClient',lambda **_:HTTP())
    async def run():
        client=HermesRuntime(tmp_path);client.create_session=AsyncMock();client.key=lambda:'fixture'
        client.request=AsyncMock(return_value={'status':'completed','output':'你好'})
        async def events(_):yield 'run.completed',{'status':'completed','output':'你好'}
        client._events=events
        text=MARKER+json.dumps({'origin_request_id':'r1','origin_message_id':'m1'})+'\n用户消息：\n你好'
        list_events=[x async for x in client.stream_chat('main',text)]
        assert list_events
    asyncio.run(run())
    body=posted[0]
    assert body['input']=='你好'
    assert 'origin_message_id' not in body['instructions']
    with sqlite3.connect(tmp_path/'hermes-runs.sqlite') as db:
        source=json.loads(db.execute('SELECT context FROM tool_sources WHERE request_id=?',('r1',)).fetchone()[0])
    assert source=={'origin_message_id':'m1','origin_request_id':'r1'}
    assert body['model_options']['reasoning']['effort']=='none'
    # 契约含地址簿（10-10 为免全盘搜文件加入）；摘要为空时仍须远小于旧的 30KB 级上下文。
    assert len(body['instructions'])<2200


def test_fast_query_uses_domain_service_and_records_zero_prompt(tmp_path,monkeypatch):
    from conversation import PersonalConversation
    import business_tools
    calls=[]
    class Service:
        def __init__(self,*_):pass
        async def call(self,tool,args,context):
            calls.append((tool,args,context));return {'items':[{'id':'ledger-1','sourceAmount':5922,'comment':'午饭'}]}
    monkeypatch.setattr(business_tools,'BusinessTools',Service)
    chat=PersonalConversation(tmp_path)
    chat.submit('request-fast-001','查看最近账单')
    asyncio.run(chat.process_one())
    snapshot=chat.snapshot()
    assert calls[0][0]=='bookkeeping'
    assert calls[0][2]['origin_request_id']=='request-fast-001'
    assert any('59.22 元' in m['text'] for m in snapshot['messages'] if m['role']=='assistant')
    with sqlite3.connect(tmp_path/'message-routing.sqlite') as db:assert db.execute('SELECT prompt_chars FROM decisions').fetchone()[0]==0


def test_retry_identity_excludes_changed_task_snapshots_but_binds_real_source(tmp_path):
    context={'origin_request_id':'r1','origin_message_id':'m1','tasks':[{'id':'t1','title':'任务','status':'running'}]}
    def turn(c):return build(tmp_path,MARKER+json.dumps(c)+'\n用户消息：\n原话')
    first=turn(context)
    next_turn=turn({**context,'tasks':[{'id':'t1','status':'completed'}]})
    assert first.source==next_turn.source and first.instructions!=next_turn.instructions
    assert first.source!=turn({**context,'origin_message_id':'m2'}).source


def test_general_turns_use_low_reasoning_and_short_replies_none(tmp_path,monkeypatch):
    import httpx
    posted=[]
    class Response:
        status_code=200
        def json(self):return {'run_id':'run_fixture'}
    class HTTP:
        async def __aenter__(self):return self
        async def __aexit__(self,*_):pass
        async def post(self,*_,**kwargs):posted.append(kwargs['json']);return Response()
    monkeypatch.setattr(httpx,'AsyncClient',lambda **_:HTTP())
    async def run(text,rid):
        client=HermesRuntime(tmp_path);client.create_session=AsyncMock();client.key=lambda:'fixture'
        client.request=AsyncMock(return_value={'status':'completed','output':'好'})
        async def events(_):yield 'run.completed',{'status':'completed','output':'好'}
        client._events=events
        wrapped=MARKER+json.dumps({'origin_request_id':rid,'origin_message_id':'m'+rid})+'\n用户消息：\n'+text
        assert [x async for x in client.stream_chat('main',wrapped)]
    asyncio.run(run('帮我看看 Steam VR 为什么掉帧','r-general'))
    asyncio.run(run('嗯。','r-short'))
    assert posted[0]['model_options']['reasoning']['effort']=='low'
    assert posted[1]['model_options']['reasoning']['effort']=='none'


def test_voice_double_send_books_once_and_odd_amounts_ask_first(tmp_path,monkeypatch):
    """10-18：两分钟内一字不差的记账只记一次；午饭 260 这类离谱金额先问；「晚饭话费」按花费记。"""
    from conversation import PersonalConversation
    import business_tools
    calls=[]
    class Service:
        def __init__(self,*_):pass
        async def call(self,tool,args,context):
            calls.append(args);return {'verified':True,**args}
    monkeypatch.setattr(business_tools,'BusinessTools',Service)
    chat=PersonalConversation(tmp_path)
    for i in range(2):
        chat.submit('request-dup-00%d'%i,'晚饭话费65块9')
        asyncio.run(chat.process_one())
    assert len(calls)==1 and calls[0]['category']=='餐饮外卖' and calls[0]['amount']==65.9
    assert any('已经记过了' in m['text'] for m in chat.snapshot()['messages'] if m['role']=='assistant')
    route=classify('午餐消费二六零。')
    assert route.args['action']=='confirm' and route.args['plan']['suspect']==26
    assert classify('午饭花费 26 元').args['action']=='add' and classify('充话费50').args['plan']['category']=='通讯话费'
