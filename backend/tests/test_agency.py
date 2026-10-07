import asyncio
from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo
import pytest
from agency import Agency
from personal_hub import PersonalHub
from goals import GoalEvents
from tasks import TaskStore
from proactive import Proactive
from conversation import PersonalConversation


def setup(tmp_path):
    now=[datetime(2026,10,7,12,tzinfo=ZoneInfo('Asia/Shanghai')).timestamp()]
    hub=PersonalHub(tmp_path,tmp_path)
    goals=GoalEvents(tmp_path,clock=lambda:now[0])
    scheduler=Proactive(tmp_path,clock=lambda:now[0])
    conversation=PersonalConversation(tmp_path,SimpleNamespace())
    agency=Agency(tmp_path,hub,goals,TaskStore(tmp_path),scheduler,conversation,clock=lambda:now[0])
    hub.matter('gmail','test-mail','确认本周交付',{'snippet':'对方需要确认稿件范围'},source_updated_at=now[0])
    return agency,now


def test_prepare_preserves_source_and_is_idempotent(tmp_path):
    agency,_=setup(tmp_path);card=agency.cards()[0]
    data={'request_id':'prepare-001','action':'prepare','version':card['version']}
    first=agency.action(card['id'],data)
    assert agency.action(card['id'],data)==first
    assert first['result']['source_version']==card['version']
    assert first['result']['evidence'][0]['value']=='对方需要确认稿件范围'
    assert agency.hub.matters()[0]['facts']=={'snippet':'对方需要确认稿件范围'}
    assert agency.cards()[0]['preparation']['source_id']==card['id']
    agency.hub.matter('gmail','test-mail','确认本周交付',{'snippet':'范围已有变更'})
    assert 'preparation' not in agency.cards()[0]
    with pytest.raises(ValueError):agency.action(card['id'],{**data,'request_id':'prepare-002'})


def test_invalid_postpone_does_not_mutate_and_handled_stays_hidden(tmp_path):
    agency,_=setup(tmp_path);card=agency.cards()[0]
    with pytest.raises(ValueError):agency.action(card['id'],{'action':'later','hours':-1,'request_id':'later-bad'})
    assert not agency.hub.matters()[0]['feedback']
    data={'action':'handled','request_id':'handled-01'}
    receipt=agency.action(card['id'],data)
    assert agency.cards()==[]
    assert agency.action(card['id'],data)==receipt
    assert Agency(agency.state,agency.hub,agency.goals,agency.tasks,agency.proactive,agency.conversation).cards()==[]
    agency.action(card['id'],{'action':'follow','request_id':'restore-01'})
    assert len(agency.cards())==1


def test_goal_creation_pause_resume_and_human_completion(tmp_path):
    agency,_=setup(tmp_path)
    data={'title':'完成一期作品','completion_condition':'交付可看的成片','next_step':'整理素材','request_id':'goal-create-001'}
    goal=agency.create_goal(data)
    assert agency.create_goal(data)['id']==goal['id']
    assert goal['authorization']['origin_source']=='authenticated_app'
    agency.action(goal['id'],{'action':'pause','request_id':'goal-pause-001'})
    assert all(c['id']!=goal['id'] for c in agency.cards())
    agency.action(goal['id'],{'action':'resume','request_id':'goal-resume-001'})
    assert any(c['id']==goal['id'] for c in agency.cards())
    result=agency.action(goal['id'],{'action':'complete','request_id':'goal-complete-001'})
    assert result['result']['evidence'][0]['kind']=='user_confirmation'
    assert not agency.goals.enabled()  # No blanket authorization to execute goals.


def test_observation_budget_dedup_pause_and_fixed_report_independence(tmp_path):
    agency,_=setup(tmp_path)
    assert agency.publish_observation('change-1','有一项变化') is True
    assert agency.publish_observation('change-1','重复变化') is False
    assert agency.publish_observation('change-2','另一项变化') is True
    assert agency.publish_observation('change-3','超过预算') is False
    agency.proactive.configure({'paused':True})
    assert agency.publish_observation('change-4','暂停期间') is False


def test_independent_report_writes_once_and_does_not_claim_goal_execution(tmp_path):
    agency,_=setup(tmp_path)
    agency.goals.enqueue('goal-execution','goal_due',{})
    agency.proactive.fire(agency.goals,'morning-briefing')
    calls=[]
    async def model(data):
        calls.append(data)
        return {'text':'先确认本周交付范围，已整理现有材料。','source_ids':[data['cards'][0]['id']]}
    assert asyncio.run(agency.process(model))
    assert not asyncio.run(agency.process(model))
    assert len(calls)==1
    with agency.goals.db() as db:
        assert db.execute("select state from events where id='goal-execution'").fetchone()[0]=='queued'
    reports=agency.snapshot()['reports']
    assert len(reports)==1 and reports[0]['text'].startswith('先确认')
    assert agency.cards()[0].get('preparation')


@pytest.mark.parametrize('change',['pause','handled','changed','disabled'])
def test_late_model_cannot_publish_after_user_paused_or_handled(tmp_path,change):
    agency,_=setup(tmp_path)
    agency.proactive.fire(agency.goals,'morning-briefing')
    async def model(data):
        if change=='pause':agency.proactive.configure({'paused':True})
        elif change=='handled':agency.action(data['cards'][0]['id'],{'action':'handled','request_id':'during-model'})
        elif change=='changed':agency.hub.matter('gmail','test-mail','确认本周交付',{'snippet':'范围改变'})
        else:
            items=agency.proactive.settings()['items'];items[0]['enabled']=False
            agency.proactive.configure({'items':items})
        return {'text':'旧建议','source_ids':[data['cards'][0]['id']]}
    assert asyncio.run(agency.process(model))
    assert agency.snapshot()['reports']==[]
    assert agency.snapshot()['runs'][0]['status']=='skipped'


def test_bad_model_reference_gets_honest_fallback(tmp_path):
    agency,_=setup(tmp_path);agency.proactive.fire(agency.goals,'morning-briefing')
    async def model(_):return {'text':'编造的事','source_ids':['unknown']}
    asyncio.run(agency.process(model))
    assert '暂时没生成好' in agency.snapshot()['reports'][0]['text']
    assert agency.snapshot()['runs'][0]['status']=='failed'


def test_settings_weekly_replaces_sunday_evening_and_rejects_bad_config(tmp_path):
    agency,now=setup(tmp_path)
    for changes in [{'intensity':'spam'},{'quiet_start':30},{'items':[{'id':'a','at':'25:90'}]},{'items':[]}]:
        with pytest.raises(ValueError):agency.proactive.configure(changes)
    items=agency.proactive.settings()['items']+[{'id':'weekly-review','at':'20:30','enabled':True,'days':[6],'title':'周复盘'}]
    agency.proactive.configure({'items':items})
    now[0]=datetime(2026,10,11,20,30,tzinfo=ZoneInfo('Asia/Shanghai')).timestamp()
    assert [r['id'] for r in agency.proactive.due()]==['weekly-review']
    now[0]+=30*60
    assert agency.proactive.due()==[]
