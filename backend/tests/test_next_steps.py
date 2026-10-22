import asyncio,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from next_steps import NextSteps

NOW=time.mktime((2026,10,10,9,0,0,0,0,-1))

class Hub:
    def matters(self):
        return [
            {'id':'m1','source':'work_mail','title':'Q4 排期确认','facts':{'from':'王总 <wang@sohu-inc.com>'},'source_updated_at':NOW-3600,'changed_at':NOW-3600,'feedback':{}},
            {'id':'m2','source':'gmail','title':'您的验证码是 1234','facts':{'from':'no-reply'},'source_updated_at':NOW-60,'changed_at':NOW-60,'feedback':{}},
            {'id':'m3','source':'apple_calendar','title':'周会','facts':{'start':'2026-10-10T11:00:00+08:00'},'deadline':'2026-10-10T11:00+08:00','changed_at':NOW,'feedback':{}},
            {'id':'m4','source':'work_mail','title':'已处理的','facts':{},'source_updated_at':NOW,'changed_at':NOW,'feedback':{'action':'handled'}},
        ]

def run(engine):return asyncio.run(engine.refresh(force=True))

def test_model_items_must_cite_real_evidence(tmp_path):
    async def model(digest):
        assert [m['ref'] for m in digest['mail']]==['mail:m1'], '验证码和已处理的邮件不进摘要'
        return {'items':[
            {'title':'回复王总的排期邮件','why':'对方在等','refs':['mail:m1'],'prompt':'起草回复给我确认','urgency':'now','score':90},
            {'title':'编一个没有依据的','why':'x','refs':['mail:nope'],'prompt':'x','urgency':'today','score':99},
        ]}
    engine=NextSteps(tmp_path,Hub(),model=model,clock=lambda:NOW)
    assert run(engine)['source']=='model'
    snap=engine.snapshot()
    assert [i['title'] for i in snap['items']]==['回复王总的排期邮件']
    assert snap['items'][0]['evidence'][0]['label'].startswith('工作邮箱')

def test_falls_back_to_rules_and_dismiss_suppresses_for_a_week(tmp_path):
    async def broken(digest):raise TimeoutError('model down')
    engine=NextSteps(tmp_path,Hub(),model=broken,clock=lambda:NOW)
    result=run(engine)
    assert result['source']=='rule' and 'model down' in result['error']
    titles=[i['title'] for i in engine.snapshot()['items']]
    assert '准备「周会」' in titles and any('Q4 排期确认' in t for t in titles)
    first=engine.snapshot()['items'][0]
    engine.act(first['id'],'dismiss')
    run(engine)
    assert first['id'] not in [i['id'] for i in engine.snapshot()['items']]
    assert engine.snapshot()['week']['dismissed']==1

def test_due_only_in_daytime_and_hourly(tmp_path):
    night=time.mktime((2026,10,10,2,0,0,0,0,-1))
    assert not NextSteps(tmp_path,Hub(),clock=lambda:night).due()
    engine=NextSteps(tmp_path,Hub(),clock=lambda:NOW)
    assert engine.due()
    run(engine)
    assert not engine.due()

def test_duplicate_calendar_evidence_is_shown_once(tmp_path):
    class Two(Hub):
        def matters(self):
            rows=super().matters()
            return rows+[{**rows[2],'id':'m5','source':'phone_calendar'}]
    async def model(digest):
        refs=[e['ref'] for e in digest['calendar']]
        return {'items':[{'title':'准备周会','why':'x','refs':refs,'prompt':'准备','urgency':'today','score':60}]}
    engine=NextSteps(tmp_path,Two(),model=model,clock=lambda:NOW)
    run(engine)
    assert [e['label'] for e in engine.snapshot()['items'][0]['evidence']]==['日程 · 周会']

def test_progress_reports_real_stage_and_counts_while_model_thinks(tmp_path):
    seen={}
    engine=None
    async def model(digest):
        seen.update(engine.snapshot()['progress'])
        return {'items':[]}
    engine=NextSteps(tmp_path,Hub(),model=model,clock=lambda:NOW)
    assert engine.snapshot()['progress'] is None
    run(engine)
    assert seen['stage']=='think'
    assert seen['counts']['mail']==1 and seen['counts']['calendar']==1
    assert engine.snapshot()['progress'] is None and not engine.snapshot()['running']

def test_done_item_does_not_come_back_under_a_new_title(tmp_path):
    titles=iter(['回复王总的排期邮件','推进 Q4 排期确认','回王总排期'])
    async def model(digest):
        return {'items':[{'title':next(titles),'why':'对方在等','refs':['mail:m1'],'prompt':'起草回复','urgency':'today','score':80}]}
    engine=NextSteps(tmp_path,Hub(),model=model,clock=lambda:NOW)
    run(engine)
    first=engine.snapshot()['items'][0]
    engine.act(first['id'],'done')
    run(engine)
    assert engine.snapshot()['items']==[], '同一封邮件换个说法也不再出现'

def test_handed_over_item_is_told_to_model_and_new_evidence_still_shows(tmp_path):
    seen={}
    calls=iter([
        [{'title':'回复王总的排期邮件','why':'x','refs':['mail:m1'],'prompt':'起草','urgency':'today','score':80}],
        [{'title':'回王总并准备周会','why':'x','refs':['mail:m1','event:m3'],'prompt':'起草','urgency':'today','score':80}],
    ])
    async def model(digest):
        seen['handled']=digest['recent_handled']
        return {'items':next(calls)}
    engine=NextSteps(tmp_path,Hub(),model=model,clock=lambda:NOW)
    run(engine)
    engine.act(engine.snapshot()['items'][0]['id'],'discuss')
    run(engine)
    assert seen['handled']==['回复王总的排期邮件']
    assert [i['title'] for i in engine.snapshot()['items']]==['回王总并准备周会'], '带了新依据的照常出现'

def test_project_step_blocks_until_progress_changes(tmp_path):
    step={'v':'跑一遍真机验收'}
    class Board:
        def snapshot(self):
            return {'actions':[{'id':h+':claude:s1','project':'Com iOS','status':'active','summary':'改版','next_step':step['v'],'host':h,'agent':'claude'} for h in ('mini','macbook')]}
    n=iter(range(9))
    async def model(digest):
        return {'items':[{'title':f'验收{next(n)} '+step['v'],'why':'x','refs':[p['ref'] for p in digest['projects']],'prompt':'p','urgency':'today','score':60}]}
    engine=NextSteps(tmp_path,projects=Board(),model=model,clock=lambda:NOW)
    run(engine)
    engine.act(engine.snapshot()['items'][0]['id'],'done')
    run(engine)
    assert engine.snapshot()['items']==[], '同一步进展（mini 和 MBP 各一份）不再提'
    step['v']='发 TestFlight'
    run(engine)
    assert [i['title'] for i in engine.snapshot()['items']]==['验收2 发 TestFlight']

def test_evidence_carries_source_detail_for_drilldown(tmp_path):
    async def model(digest):
        return {'items':[{'title':'回王总并准备周会','why':'x','refs':['mail:m1','event:m3'],'prompt':'起草','urgency':'today','score':80}]}
    engine=NextSteps(tmp_path,Hub(),model=model,clock=lambda:NOW)
    run(engine)
    mail,event=engine.snapshot()['items'][0]['evidence']
    assert mail['detail']['title']=='Q4 排期确认' and mail['detail']['source_label']=='工作邮箱'
    assert mail['detail']['sender'].startswith('王总') and mail['detail']['at']==NOW-3600
    assert event['detail']['title']=='周会' and event['detail']['source_label']=='Apple 日历' and event['detail']['at']>0

def test_old_items_without_detail_are_backfilled_from_matters(tmp_path):
    async def model(digest):
        return {'items':[{'title':'回复王总的排期邮件','why':'x','refs':['mail:m1'],'prompt':'起草','urgency':'today','score':80}]}
    engine=NextSteps(tmp_path,Hub(),model=model,clock=lambda:NOW)
    run(engine)
    import json
    with engine.db() as db:
        row=db.execute('SELECT id,data FROM items').fetchone()
        data=json.loads(row['data']);data['evidence'][0].pop('detail')
        db.execute('UPDATE items SET data=? WHERE id=?',(json.dumps(data,ensure_ascii=False),row['id']))
    assert engine.snapshot()['items'][0]['evidence'][0]['detail']['title']=='Q4 排期确认'

def test_brief_points_cite_news_and_dismissed_news_drops_out(tmp_path):
    from news import News
    calls=[]
    async def search(query,time_range):
        calls.append(query)
        return [{'Title':'Claude 新版发布|新浪','Url':'https://x/'+str(len(calls)),'SiteName':'新浪','PublishTime':'2026-10-10T08:00:00+08:00','Summary':'摘要'}]*3
    news=News(tmp_path,search=search,clock=lambda:NOW)
    async def model(digest):
        ref=digest['news'][0]['ref']
        assert 'interests' in digest and digest['interests']['topics']
        return {'headline':'今天松','brief':[{'text':'上午一个周会','refs':['event:m3']},{'text':'Claude 出了新版，测评可用','refs':[ref]},{'text':''}],'items':[]}
    engine=NextSteps(tmp_path,Hub(),model=model,clock=lambda:NOW,news=news)
    run(engine)
    first=len(calls)
    asyncio.run(engine.refresh())
    assert len(calls)==first  # 每小时的整理同一天不重抓，只有手动刷新才重抓
    brief=engine.snapshot()['brief']
    assert [p['kind'] for p in brief]==['event','news'] and brief[1]['title']=='Claude 新版发布' and brief[1]['url'].startswith('https://x/')
    news.feedback(brief[1]['news_id'],'dismiss')
    assert [p['kind'] for p in engine.snapshot()['brief']]==['event']
    assert news.interests()['disliked']==['Claude 新版发布']


def test_focus_project_chats_reach_model_with_full_thread_and_become_a_brief_card(tmp_path):
    chat={'name':'活动群','username':'1@chatroom','is_group':True,'project':'生活节','mention':False,'keyword':False,'priority':False,'anchor':'9','sender':'小倩','summary':'好的',
          'messages':[{'sender':'小倩','at':NOW-7200+i,'text':f'第{i}条：展车进场时间待定'} for i in range(20)]}
    class WxHub:
        def matters(self):
            return [{'id':'w1','source':'wechat','title':'微信','facts':{'chats':[chat],'projects':[{'name':'生活节','venue':'北顶','date':'2026-10-14'}]},
                     'source_updated_at':NOW-3600*30,'changed_at':NOW-3600*30,'feedback':{}}]
    seen={}
    async def model(data):
        seen.update(data)
        ref=data['wechat'][0]['ref']
        return {'items':[],'focus':[{'project':'生活节','status':'展车进场时间还没定','open':['小倩确认展车进场时间'],'risks':['物料未出图'],'refs':[ref]},
                                    {'project':'不存在','status':'x','refs':[ref]}]}
    engine=NextSteps(tmp_path,WxHub(),model=model,clock=lambda:NOW)
    asyncio.run(engine.refresh(True))
    # 30 小时前的摘要：普通聊天会被丢弃，焦点项目的聊天仍在，并带整段对话而不只是最后一句
    assert seen['wechat'][0]['project']=='生活节' and len(seen['wechat'][0]['recent'])==14
    assert seen['focus']==[{'project':'生活节','venue':'北顶','date':'2026-10-14','days_left':4}]
    card=engine.snapshot()['brief'][0]
    assert card['kind']=='project' and card['days_left']==4 and card['open']==['小倩确认展车进场时间'] and len(engine.snapshot()['brief'])==1


def test_open_items_are_kept_instead_of_rewritten_and_decay_after_four_rounds(tmp_path):
    t=[NOW]
    seen={}
    async def model(data):
        seen['current']=data['current']
        if not data['current']:
            return {'items':[{'title':'回复王总的排期邮件','why':'他在等','refs':['mail:m1'],'prompt':'起草回复','urgency':'today','score':70}]}
        return {'items':[{'keep':data['current'][0]['id']}]}
    engine=NextSteps(tmp_path,Hub(),model=model,clock=lambda:t[0])
    for _ in range(4):
        asyncio.run(engine.refresh(True)); t[0]+=3600
    items=engine.snapshot()['items']
    assert len(items)==1 and items[0]['title']=='回复王总的排期邮件' and items[0]['shown']==4
    assert items[0]['urgency']=='week' and items[0]['score']==50
    assert seen['current'][0]['shown']==3
