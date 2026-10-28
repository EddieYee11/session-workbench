import asyncio
from datetime import datetime
from types import SimpleNamespace
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


def test_bark_config_enables_delivery_without_apns_devices(tmp_path):
    now=[datetime(2026,10,7,12,tzinfo=ZoneInfo('Asia/Shanghai')).timestamp()]
    c=PersonalConversation(tmp_path,SimpleNamespace())
    (tmp_path/'bark-config.json').write_text('{"device_key":"abcDEF123456"}')
    p=PushNotifications(tmp_path,c,lambda:{'quiet_start':23,'quiet_end':8},clock=lambda:now[0])
    assert p.status()['delivery']=='bark' and p.status()['registered_devices']==0
    message(c)
    calls=[]
    async def send(device,row):calls.append((device['id'],row['device_id']));return 200,''
    assert asyncio.run(p.process(send))
    assert not asyncio.run(p.process(send))
    assert calls==[('bark','bark')]
    assert p.status()['outbox']=={'accepted':1}
    assert 'abcDEF123456' not in str(p.status())


def test_bark_rows_are_not_created_without_config(tmp_path):
    p,c,_=setup(tmp_path);message(c)
    assert asyncio.run(p.process()) is False
    with p.db() as db:ids={r[0] for r in db.execute('SELECT device_id FROM outbox')}
    assert ids=={'iphone-test'}


def test_approval_becomes_actionable_notification_once(tmp_path):
    p,c,_=setup(tmp_path)
    approval={'id':'ap-1','sid':'codex:x','method':'item/commandExecution/requestApproval',
              'params':{'reason':'要删除两个文件','command':'rm -rf a b'}}
    assert p.enqueue_approvals([approval])==1
    assert p.enqueue_approvals([approval])==0
    calls=[]
    async def send(device,row):calls.append(row);return 200,''
    asyncio.run(p.process(send))
    assert calls[0]['message_id']=='approval:ap-1'
    assert p.status()['outbox']=={'accepted':1}


def test_approval_is_only_actionable_when_both_choices_exist(tmp_path):
    p, c, _ = setup(tmp_path)
    base = {'sid': 'codex:x', 'method': 'item/commandExecution/requestApproval', 'params': {'reason': '要删除两个文件'}}
    p.enqueue_approvals([{**base, 'id': 'ap-2', 'params': {**base['params'], 'availableDecisions': ['accept', 'decline']}}])
    p.enqueue_approvals([{**base, 'id': 'ap-3', 'params': {**base['params'], 'availableDecisions': ['accept', 'cancel']}}])
    with p.db() as db:
        rows = {r['id']: r['actionable'] for r in db.execute('SELECT id,actionable FROM approvals')}
        titles = [r['title'] for r in db.execute('SELECT title FROM approvals')]
    assert rows == {'ap-2': 1, 'ap-3': 0}
    assert all('rm -rf' not in title for title in titles)


def test_wechat_channel_caps_daily_pushes_but_not_approvals_and_respects_quiet_hours(tmp_path):
    import json
    p,c,now=setup(tmp_path)
    sent=[]
    async def sender(cfg,text):
        sent.append(text);return 200,''
    assert asyncio.run(p.push_wechat([{'key':'next:a','kind':'next','text':'x'}],sender)) is None, '没配置就不发'
    (tmp_path/'wechat-push.json').write_text(json.dumps({'enabled':True,'daily_max':2}))
    cands=[{'key':f'next:{i}','kind':'next','text':f'事{i}'} for i in range(4)]+[{'key':'approval:1','kind':'approval','text':'审批'}]
    for _ in range(6):
        asyncio.run(p.push_wechat(cands,sender))
    assert sent==['事0','事1','审批'], '每天两条额度，审批不占额度；同一个 key 只发一次'
    assert p.status()['delivery']=='apns' or p.status()['wechat']
    now[0]=datetime(2026,10,7,23,30,tzinfo=ZoneInfo('Asia/Shanghai')).timestamp()
    assert asyncio.run(p.push_wechat([{'key':'approval:2','kind':'approval','text':'夜里'}],sender)) is None and sent[-1]=='审批'
