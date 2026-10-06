import asyncio
import json
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from rayneo import RayneoIngress, final_reply
from conversation import PersonalConversation
from unified_voice import UnifiedVoice
from test_api import service
from test_pi_safety import tool_service


@pytest.fixture
def ingress(tmp_path):
    chat=PersonalConversation(tmp_path)
    voice=UnifiedVoice(chat,SimpleNamespace(receipt=lambda _:None,snapshot=lambda:{'requests':[]}))
    ray=RayneoIngress(tmp_path,chat,voice,wait_seconds=.02,poll_seconds=.001)
    app=FastAPI();app.include_router(ray.router)
    return ray,chat,TestClient(app)


def body(ident='rayneo-test-request-0001',text='请回复本轮验证码'):
    return {'model':'com-personal','stream':True,'request_id':ident,
            'messages':[{'role':'user','content':'午饭30元记一下，这是旧消息'},
                        {'role':'assistant','content':'旧回复'}, {'role':'user','content':text}]}


def test_latest_only_dedupe_and_distinct_identical_utterances(ingress):
    ray,chat,c=ingress
    for _ in range(2):
        result=c.post('/rayneo/v1/chat/completions',json=body())
        assert result.status_code==200 and ': keepalive' in result.text and 'data: [DONE]' in result.text
    with chat.db() as db:
        rows=db.execute("SELECT text FROM messages WHERE role='user'").fetchall()
    assert [r[0] for r in rows]==['请回复本轮验证码']
    assert c.post('/rayneo/v1/chat/completions',json=body(text='不同文字')).status_code==409
    assert c.post('/rayneo/v1/chat/completions',json=body(ident='rayneo-test-request-0002')).status_code==200
    with chat.db() as db:assert db.execute("SELECT count(*) FROM messages WHERE role='user'").fetchone()[0]==2
    assert c.get('/rayneo/v1/receipts/unrelated-request').status_code==404


def test_invalid_requests_and_pending_receipt(ingress):
    ray,_,c=ingress
    for value in ({**body(),'request_id':'invalid'}, {**body(),'model':'other'}, {**body(),'stream':False},
                  {**body(),'messages':[{'role':'assistant','content':'fake'}]}):
        assert c.post('/rayneo/v1/chat/completions',json=value).status_code==422
    assert c.post('/rayneo/v1/chat/completions',json=body(),headers={'X-Com-Request-Id':'different'}).status_code==409
    c.post('/rayneo/v1/chat/completions',json=body())
    receipt=c.get('/rayneo/v1/receipts/rayneo-test-request-0001').json()
    assert receipt['status']=='accepted' and receipt['display_text']=='已受理，处理中'


def test_real_write_and_readback_required_for_success():
    from quick_voice import observed_progress
    events=[{'type':'tool_execution_start','data':{'toolCallId':'write','args':{'action':'add','comment':'午饭'}}},
            {'type':'tool_execution_end','data':{'toolCallId':'write','toolName':'bookkeeping','result':{'details':{'id':'314','amount':32.5,'category':'餐饮'},'content':[]}}}]
    receipt={'status':'completed','result':'已记账','action_receipts':observed_progress(events)['action_receipts']}
    assert '待核实' in final_reply(receipt)
    events += [{'type':'tool_execution_start','data':{'toolCallId':'read','args':{'action':'recent'}}},
               {'type':'tool_execution_end','data':{'toolCallId':'read','toolName':'bookkeeping','result':{'content':[{'type':'text','text':'#314 -¥32.50 餐饮 · 午饭'}]}}}]
    receipt['action_receipts']=observed_progress(events)['action_receipts']
    assert final_reply(receipt)=='已记 ¥32.50 · 午饭 · #314'
    assert '待核实' in final_reply({'status':'completed','result':'已记账','action_receipts':[]})
    assert '待核实' in final_reply({'status':'unknown','result':'已记账'})
    assert final_reply({'status':'completed','result':'你是说十五还是五十元？'})=='你是说十五还是五十元？'


def test_sse_returns_final_evidence_and_retry_does_not_write(ingress,monkeypatch):
    ray,chat,c=ingress
    receipt={'status':'completed','result':'服务随机码 7F90B1','action_receipts':[]}
    monkeypatch.setattr(ray.voice,'receipt',lambda _:receipt)
    a=c.post('/rayneo/v1/chat/completions',json=body())
    b=c.post('/rayneo/v1/chat/completions',json=body())
    assert a.text==b.text and '7F90B1' in a.text and '"finish_reason": "stop"' in a.text
    with chat.db() as db:assert db.execute('SELECT count(*) FROM messages').fetchone()[0]==1


def test_pairing_is_one_time_expiring_and_rate_limited(ingress):
    ray,_,c=ingress
    pair=ray.state/'rayneo-pairing.json'
    pair.write_text(json.dumps({'code':'once-code','expires':time.time()+60}))
    response=c.post('/rayneo/v1/pair',json={'code':'once-code'})
    assert response.status_code==200 and response.json()['token']==ray.token
    assert c.post('/rayneo/v1/pair',json={'code':'once-code'}).status_code==403
    pair.write_text(json.dumps({'code':'expired','expires':time.time()-1}))
    for _ in range(3):assert c.post('/rayneo/v1/pair',json={'code':'expired'}).status_code==403
    assert c.post('/rayneo/v1/pair',json={'code':'expired'}).status_code==429


def test_scoped_token_cannot_reach_other_com_routes(service):
    app,c=service
    header={'Authorization':'Bearer '+app.rayneo.token}
    assert c.get('/rayneo/v1/health',headers=header).status_code==200
    assert c.get('/personal/conversation',headers=header).status_code==401
    assert c.get('/rayneo/v1/health',headers={'Authorization':'Bearer '+app.TOKEN}).status_code==401


def test_full_access_glasses_executes_shell_and_preserves_source_and_dedupe(tmp_path):
    tools,context=tool_service(tmp_path,'午饭30元，记一下')
    ray=RayneoIngress(tmp_path,tools.conversation,SimpleNamespace(submit=lambda *a:None))
    with tools.conversation.db() as db:
        db.execute('INSERT INTO rayneo_requests VALUES (?,?,?,?)',(context['origin_request_id'],'fixture','午饭30元，记一下',time.time()))
    assert tools.authorize_tool({'tool':'bash','args':{'command':'pwd'}},context)['authorized']
    assert tools.authorize_tool({'tool':'write','args':{'path':str(tmp_path/'new.txt'),'content':'fixture'}},context)['authorized']
    assert tools.check_glasses_scope('task_submit',{},context)
    assert tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':30,'comment':'午饭'},'tool_call_id':'first'},context)['authorized']
    with pytest.raises(ValueError,match='禁止重复'):
        tools.authorize_tool({'tool':'bookkeeping','args':{'action':'add','amount':30,'comment':'午饭'},'tool_call_id':'second'},context)
    assert tools.authorize_tool({'tool':'bookkeeping','args':{'action':'recent'}},context)['authorized']
    # Transport labels do not replace the persisted actual user source.
    assert tools.authorize_tool({'tool':'bash','args':{'command':'pwd'}},{**context,'input_source':'phone'})['authorized']
    with pytest.raises(ValueError):tools.authorize_tool({'tool':'bash','args':{'command':'pwd'}},{**context,'origin_request_id':'forged'})


def test_reminder_calendar_scope_intent_and_creation_dedupe(tmp_path):
    tools,context=tool_service(tmp_path,'明天9点提醒我喝水，也加到我的日历')
    ray=RayneoIngress(tmp_path,tools.conversation,SimpleNamespace(submit=lambda *a:None))
    with tools.conversation.db() as db:
        db.execute('INSERT INTO rayneo_requests VALUES (?,?,?,?)',(context['origin_request_id'],'fixture','提醒和日历',time.time()))
    first={'tool':'remind','args':{'action':'add','text':'喝水','in_minutes':1},'tool_call_id':'r1'}
    assert tools.authorize_tool(first,context)['authorized']
    with pytest.raises(ValueError,match='禁止重复'):
        tools.authorize_tool({**first,'tool_call_id':'r2'},context)
    assert tools.authorize_tool({'tool':'remind','args':{'action':'list'}},context)['authorized']
    assert tools.authorize_tool({'tool':'calendar_event','args':{'action':'create','summary':'喝水','date':'2026-10-05'}},context)['authorized']
    assert tools.authorize_tool({'tool':'bash','args':{'command':'pwd'}},context)['authorized']


def test_reminder_needs_native_creation_and_readback():
    from quick_voice import observed_progress
    events=[{'type':'tool_execution_start','data':{'toolCallId':'r','args':{'action':'add','text':'喝水','in_minutes':1}}},
            {'type':'tool_execution_end','data':{'toolCallId':'r','toolName':'remind','result':{'details':{'id':'rmfixture','due':'2026-10-04 02:00'},'content':[]}}}]
    receipt={'status':'completed','result':'已设提醒','operation_receipts':observed_progress(events)['operation_receipts']}
    assert '待核实' in final_reply(receipt)
    events += [{'type':'tool_execution_start','data':{'toolCallId':'list','args':{'action':'list'}}},
               {'type':'tool_execution_end','data':{'toolCallId':'list','toolName':'remind','result':{'details':{'ids':['rmfixture']},'content':[]}}}]
    receipt['operation_receipts']=observed_progress(events)['operation_receipts']
    assert final_reply(receipt)=='已设微信提醒 · 2026-10-04 02:00 · 喝水 · #rmfixture'
    assert '待核实' in final_reply({'status':'completed','result':'已设微信提醒'})
