import asyncio
import pytest
from project_board import ProjectBoard,clean

def snapshot(host='macbook',version='one',now=10000):
    text='这次已经完成分类图，但真机测试还没有完成，需要继续验收。'+version
    return {'host':host,'collected_at':now,'agents':{'codex':1},'sessions':[{'id':host+':codex:test','native_id':'codex:test','host':host,'agent':'codex','cwd':'/Users/a/AI_Work_System/projects/com','title':'Com 升级','updated_at':now,'messages':[{'id':'m1','role':'assistant','text':text,'time':now}]}]}

def review(s):
    return {'project':'Com','title':'分类图真机验收','status':'pending','summary':'分类图已完成，真机待验收','next_step':'在真机检查分类明细','evidence_id':'m1','evidence_quote':s['messages'][0]['text'][:30]}

async def model(s):return review(s)

def test_hosts_distinct_evidence_grouping_and_actions(tmp_path):
    b=ProjectBoard(tmp_path,clock=lambda:10000)
    b.ingest(snapshot());b.ingest(snapshot('mini'))
    assert asyncio.run(b.review(model))==2
    data=b.snapshot();assert len(data['projects'])==1 and data['counts']['pending']==2
    assert len(data['actions'])==2
    assert {i['host'] for i in data['projects'][0]['items']}=={'mini','macbook'}
    assert asyncio.run(b.review(model))==0

def test_no_completion_from_missing_evidence_or_old_version(tmp_path):
    b=ProjectBoard(tmp_path,clock=lambda:10000);b.ingest(snapshot())
    async def bad(s):return {**review(s),'status':'completed','evidence_quote':'不属于原始会话的完成描述'}
    asyncio.run(b.review(bad));assert b.snapshot()['counts']['uncertain']==1
    b.ingest(snapshot(version='two'));asyncio.run(b.review(model))
    assert b.snapshot()['counts']['pending']==1
    b.ingest(snapshot(version='three'));assert b.snapshot()['counts']['uncertain']==1 and not b.snapshot()['actions']

def test_snooze_expiry_handled_and_host_staleness(tmp_path):
    now=[10000];b=ProjectBoard(tmp_path,clock=lambda:now[0]);b.ingest(snapshot());asyncio.run(b.review(model))
    action=b.snapshot()['actions'][0]
    b.feedback(action['id'],{'action':'later','version':action['version']});assert not b.snapshot()['actions']
    now[0]+=3*3600+1;fresh=snapshot();fresh['collected_at']=now[0];b.ingest(fresh);assert b.snapshot()['actions']
    b.feedback(action['id'],{'action':'handled','version':action['version']});assert not b.snapshot()['actions']
    b.ingest(snapshot(version='two',now=now[0]));asyncio.run(b.review(model));assert b.snapshot()['actions']
    now[0]+=1801;assert not b.snapshot()['actions'] and b.snapshot()['hosts'][0]['stale']

def test_host_validation_and_redaction(tmp_path):
    b=ProjectBoard(tmp_path)
    with pytest.raises(ValueError):b.ingest({'host':'other','sessions':[]})
    assert 'super-secret' not in clean('token=super-secret')
