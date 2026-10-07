import asyncio
import sqlite3
from types import SimpleNamespace
from datetime import datetime
from zoneinfo import ZoneInfo
from conversation import PersonalConversation
from push_notifications import PushNotifications


def setup(tmp_path):
    now=[datetime(2026,10,7,12,tzinfo=ZoneInfo('Asia/Shanghai')).timestamp()]
    c=PersonalConversation(tmp_path,SimpleNamespace())
    p=PushNotifications(tmp_path,c,lambda:{'quiet_start':23,'quiet_end':8},clock=lambda:now[0])
    p.register({'id':'iphone-test','token':'a'*64,'environment':'sandbox'})
    return p,c,now


def message(c,text='有新消息'):
    c.task_receipt('new',text)
    # Test clock is before wall clock, so the receipt remains after registration.


def test_no_config_reports_fallback_and_keeps_durable_message(tmp_path):
    p,c,_=setup(tmp_path);message(c)
    assert asyncio.run(p.process()) is False
    assert p.status()['configured'] is False
    assert p.status()['outbox']['queued']==1
    assert p.status()['delivery']=='background_refresh'


def test_success_is_accepted_not_delivered_and_deduplicates(tmp_path):
    p,c,_=setup(tmp_path);message(c)
    calls=[]
    async def send(device,row):calls.append(row);return 200,''
    assert asyncio.run(p.process(send))
    assert not asyncio.run(p.process(send))
    assert len(calls)==1
    assert p.status()['outbox']=={'accepted':1}
    assert 'token' not in str(p.status())


def test_transient_failure_retries_same_id_and_invalid_token_disables(tmp_path):
    p,c,now=setup(tmp_path);message(c);ids=[]
    async def fail(device,row):ids.append(row['id']);return 503,'ServiceUnavailable'
    asyncio.run(p.process(fail));assert not asyncio.run(p.process(fail))
    now[0]+=65
    async def invalid(device,row):ids.append(row['id']);return 410,'Unregistered'
    asyncio.run(p.process(invalid))
    assert ids[0]==ids[1] and p.status()['registered_devices']==0
    assert p.status()['outbox']['failed']==1


def test_quiet_hours_defer_and_disable_cancels(tmp_path):
    p,c,now=setup(tmp_path);message(c);now[0]+=12*3600
    async def send(*_):raise AssertionError('must not call')
    assert not asyncio.run(p.process(send))
    p.disable('iphone-test')
    assert p.status()['outbox']['cancelled']==1


def test_register_does_not_replay_old_chat_and_token_rotation_keeps_one_device(tmp_path):
    c=PersonalConversation(tmp_path,SimpleNamespace());message(c)
    p=PushNotifications(tmp_path,c,lambda:{})
    p.register({'id':'iphone-test','token':'a'*64});p.register({'id':'iphone-test','token':'b'*64})
    p.enqueue()
    assert p.status()['registered_devices']==1 and not p.status()['outbox']
