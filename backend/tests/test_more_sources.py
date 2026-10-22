"""10-15 新信源：iPhone 提醒事项、天气、短信 / 录音推送、此刻状态，以及它们进「下一步」的摘要。"""
import asyncio,json,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from personal_hub import PersonalHub
from next_steps import NextSteps

def test_reminders_replace_completed_and_stay_out_of_briefing(tmp_path):
 hub=PersonalHub(tmp_path,home=tmp_path)
 hub.ingest_reminders({'node':'n','result':{'items':[{'id':'a','title':'交物业费','due':'2026-10-16T10:00:00Z'},{'id':'b','title':'旧的','completed':True}]}})
 assert [r['title'] for r in hub.matters() if r['source']=='phone_reminders']==['交物业费']
 hub.ingest_reminders({'node':'n','result':{'items':[]}})
 assert not [r for r in hub.matters() if r['source']=='phone_reminders'],'手机上完成了这里就删'
 hub.context('place','公司')
 assert not [c for c in hub.briefing()['cards'] if c['source'] in ('context','phone_reminders')]

def test_pushed_source_goes_stale(tmp_path):
 hub=PersonalHub(tmp_path,home=tmp_path)
 try:asyncio.run(hub.sync_source('sms'));assert False
 except RuntimeError as e:assert 'MBP' in str(e)
 hub.matter('sms','latest','短信',{'messages':[]},deadline=None)
 assert asyncio.run(hub.sync_source('sms'))['count']==1

def test_new_sources_reach_the_digest(tmp_path):
 now=time.time()
 hub=PersonalHub(tmp_path,home=tmp_path)
 hub.ingest_reminders({'node':'n','result':{'items':[{'id':'a','title':'交物业费','due':None}]}})
 hub.matter('sms','latest','短信',{'messages':[{'id':'g1','from':'+86100','text':'【顺丰】快递已放家门口','at':now-600}]},deadline=None)
 hub.matter('plaud','f1','10-15 会议：合作洽谈',{'actions':'| 在海报加 YY Logo | 搜狐方 | 尽快 |'},source_updated_at=now-3600,deadline=None)
 hub.matter('weather','2099-01-01','北京 01-01 中雨',{'date':'2099-01-01','text':'中雨','high':10,'low':3,'rain_chance':90,'wind_max':20},deadline=None)
 hub.context('focus','工作')
 vault=tmp_path/'v';(vault/'任务'/'待处理').mkdir(parents=True);(vault/'Inbox').mkdir()
 (vault/'任务'/'待处理'/'交报销.md').write_text('---\nflow: 任务\n状态: 待处理\n计划结束: 2026-10-10\n下一步: 跑对账\n---\n',encoding='utf-8')
 (vault/'Inbox'/'速记.md').write_text('问一下摩托保养',encoding='utf-8')
 seen={}
 async def model(digest):
  seen.update(digest);return {'headline':'x','items':[{'title':'在海报加 YY Logo','why':'会上答应的','refs':['plaud:f1'],'prompt':'p','urgency':'today','score':70}]}
 engine=NextSteps(tmp_path/'n',hub,model=model,vault=vault,clock=lambda:now)
 asyncio.run(engine.refresh(force=True))
 assert [t['title'] for t in seen['board']]==['交报销'] and seen['inbox'][0]['text']=='问一下摩托保养'
 assert seen['reminders'][0]['title']=='交物业费' and seen['sms'][0]['text'].startswith('【顺丰】')
 assert seen['commitments'][0]['meeting'].startswith('10-15') and seen['weather'][0]['text']=='中雨'
 assert seen['context']=={'focus':'工作'}
 assert engine.snapshot()['items'][0]['evidence'][0]['kind']=='plaud'
