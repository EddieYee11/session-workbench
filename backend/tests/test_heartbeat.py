import asyncio
from datetime import datetime
from zoneinfo import ZoneInfo
import pytest
from heartbeat import Heartbeat, normalize
from tasks import TaskStore
from work_dispatch import WorkProposalStore

@pytest.mark.parametrize('value',[{}, {'action':'execute','reason':'x','text':'x'}, {'action':'speak','reason':'x','text':''}])
def test_bad_decisions_fail(value):
 with pytest.raises(ValueError):normalize(value)

def engine(tmp_path,action='escalate'):
 now=[datetime(2026,10,3,12,tzinfo=ZoneInfo('Asia/Shanghai')).timestamp()]
 async def model(_):return {'action':action,'reason':'任务出现新阻塞','text':'请检查阻塞'}
 tasks=TaskStore(tmp_path);proposals=WorkProposalStore(tmp_path,tmp_path)
 return Heartbeat(tmp_path,tmp_path,tasks,proposals,model,clock=lambda:now[0]),now

def test_shadow_has_no_task_proposal_or_notification(tmp_path):
 hb,now=engine(tmp_path)
 row=asyncio.run(hb.tick(force=True))
 assert row['effect']=='none' and hb.tasks.list()==[] and hb.proposals.list()==[]
 assert hb.recent()[0]['decision']['action']=='escalate'

def test_pause_quiet_budget_and_dedup(tmp_path):
 hb,now=engine(tmp_path)
 hb.configure({'paused':True});assert asyncio.run(hb.tick(force=True))['skipped']=='paused'
 hb.configure({'paused':False});now[0]+=12*3600
 assert asyncio.run(hb.tick(force=True))['skipped']=='quiet_hours'
 now[0]-=12*3600
 asyncio.run(hb.tick(force=True));row=asyncio.run(hb.tick(force=True));assert row['decision']['action']=='nothing'
 for _ in range(22):asyncio.run(hb.tick(force=True))
 assert asyncio.run(hb.tick(force=True))['skipped']=='daily_budget'

def test_enabled_escalate_creates_only_approval_proposal(tmp_path):
 hb,now=engine(tmp_path)
 asyncio.run(hb.tick(force=True));now[0]+=7*3600;asyncio.run(hb.tick(force=True));now[0]+=17*3600
 hb.configure({'shadow':False})
 row=asyncio.run(hb.tick(force=True));assert row['effect']=='proposal'
 assert hb.tasks.list()==[] and hb.proposals.list()[0]['status']=='proposed'

def test_guard_failures_quietly_degrade(tmp_path):
 hb,_=engine(tmp_path)
 async def model(_):raise RuntimeError('fixture secret must not enter log')
 hb.model=model
 row=asyncio.run(hb.tick(force=True));assert row['effect']=='none'
 assert 'fixture secret' not in hb.path.read_text()


def test_enable_requires_two_successful_shadow_observations(tmp_path):
 hb,_=engine(tmp_path)
 with pytest.raises(ValueError):hb.configure({'shadow':False})
 asyncio.run(hb.tick(force=True))
 with pytest.raises(ValueError):hb.configure({'shadow':False})
 asyncio.run(hb.tick(force=True));assert hb.configure({'shadow':False})['shadow'] is False

def test_pause_during_model_discards_decision(tmp_path):
 hb,_=engine(tmp_path)
 async def model(_):
  hb.configure({'paused':True});return {'action':'escalate','reason':'x','text':'x'}
 hb.model=model
 row=asyncio.run(hb.tick(force=True));assert row['effect']=='none' and hb.proposals.list()==[]

def test_restart_respects_persisted_interval(tmp_path):
 hb,now=engine(tmp_path);asyncio.run(hb.tick())
 restored,_=engine(tmp_path);assert asyncio.run(restored.tick())['skipped']=='interval'
