import json
from datetime import datetime
from zoneinfo import ZoneInfo
import pytest
from reminder_cards import ReminderCards

def fixture(tmp_path):
 p=tmp_path/'reminders.json';p.write_text(json.dumps([{'id':'rmfixture','text':'隔离测试','due':'2026-10-03 14:00','status':'pending','repeat':'once'}]))
 return ReminderCards(p,clock=lambda:datetime(2026,10,3,12,tzinfo=ZoneInfo('Asia/Shanghai')))

@pytest.mark.parametrize('action,status,due',[('confirm','done','2026-10-03 14:00'),('snooze10','pending','2026-10-03 14:10'),('snooze60','pending','2026-10-03 15:00'),('cancel','cancelled','2026-10-03 14:00')])
def test_four_actions_read_back_same_true_record(tmp_path,action,status,due):
 c=fixture(tmp_path);old=c.list()[0];rid='fixture-request-001'
 result=c.act('rmfixture',action,rid,old)
 assert result['confirmed'] and result['item']['status']==status and result['item']['due']==due
 assert c.act('rmfixture',action,rid,old)['duplicate']
 assert len(c.read())==1

def test_stale_record_fails_and_keeps_original(tmp_path):
 c=fixture(tmp_path)
 with pytest.raises(ValueError,match='已变化'):c.act('rmfixture','cancel','fixture-request-001',{'due':'stale','status':'pending'})
 assert c.list()[0]['status']=='pending'

def test_invalid_real_store_never_becomes_empty_success(tmp_path):
 c=ReminderCards(tmp_path/'missing.json')
 with pytest.raises(ValueError):c.list()
