import asyncio,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from health_insight import HealthInsight

NOW=time.mktime((2026,10,17,9,0,0,0,0,-1))

class Hub:
    def __init__(self):self.hrv=46
    def health(self,days):
        day=lambda d,h:{'date':d,'measurements':{'sleep_seconds':20700,'hrv_last_night':h,'readiness_score':78,'avg_stress':22,'hrv_baseline':[40,60]},'activities':[]}
        return {'today':day('2026-10-17',self.hrv),'days':[day('2026-10-16',50),{**day('2026-10-13',52),'activities':[{'name':'抱石','minutes':209}]},day('2026-10-17',self.hrv)]}
    def matters(self):
        return [{'source':'apple_calendar','title':'奥森拍照','facts':{'start':'2026-10-17T14:00:00+08:00'}}]

def test_model_output_is_cleaned_and_cached_by_fingerprint(tmp_path):
    calls=[]
    async def model(data):
        calls.append(data)
        assert data['calendar_today']==['14:00 奥森拍照'] and data['avg_14d']['hrv_last_night']==51.0
        assert data['activities'][0]['name']=='抱石'
        return {'headline':'睡得少但恢复还行','summary':'x','dimensions':[{'key':'sleep','level':'low','note':'5.8h'},{'key':'bogus','level':'good'}],
                'actions':[{'title':'今晚 23:30 前睡','detail':'d','when':'今晚','kind':'nap'}]}
    hub=Hub();engine=HealthInsight(tmp_path,hub,model=model,clock=lambda:NOW)
    asyncio.run(engine.generate())
    snap=engine.snapshot(kick=False)
    assert snap['score']==78 and snap['level']=='high' and snap['source']=='model'
    assert [d['key'] for d in snap['dimensions']]==['sleep'] and snap['actions'][0]['kind']=='move'
    asyncio.run(engine.generate())
    assert len(calls)==1  # 数据没变不重算
    hub.hrv=38
    asyncio.run(engine.generate())
    assert len(calls)==2

def test_rules_when_model_fails(tmp_path):
    async def model(data):raise RuntimeError('down')
    engine=HealthInsight(tmp_path,Hub(),model=model,clock=lambda:NOW)
    asyncio.run(engine.generate())
    snap=engine.snapshot(kick=False)
    assert snap['source']=='rule' and snap['error'].startswith('RuntimeError') and snap['actions']
    assert any(a['kind']=='sleep' for a in snap['actions']), '睡了 5.8 小时要提醒早睡'
