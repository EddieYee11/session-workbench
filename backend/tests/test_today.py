import json,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from today import Today
from reminder_cards import ReminderCards

NOW=time.mktime((2026,10,10,9,30,0,0,0,-1))

class Hub:
    def matters(self):
        return [
            {'id':'e1','source':'apple_calendar','title':'周会','facts':{'start':'2026-10-10T11:00:00+08:00','end':'2026-10-10T12:00:00+08:00','location':'3F'},'feedback':{}},
            {'id':'e2','source':'phone_calendar','title':'周会','facts':{'start':'2026-10-10T11:00+08:00','end':'2026-10-10T12:00+08:00'},'feedback':{}},
            {'id':'e3','source':'google_calendar','title':'明天的会','facts':{'start':{'dateTime':'2026-10-11T10:00:00+08:00'},'end':{'dateTime':'2026-10-11T11:00:00+08:00'}},'feedback':{}},
            {'id':'e4','source':'apple_calendar','title':'国庆调休','facts':{'start':{'date':'2026-10-10'},'end':{'date':'2026-10-11'},'calendar':'中国大陆节假日'},'feedback':{}},
            {'id':'m1','source':'work_mail','title':'邮件不算日程','facts':{},'feedback':{}},
        ]

def vault(tmp_path):
    folder=tmp_path/'任务'/'待处理';folder.mkdir(parents=True)
    def task(name,end='',start='',state='待处理'):
        (folder/f'{name}.md').write_text(f'---\nflow: 任务\n状态: {state}\n关联项目: "[[报销]]"\n计划开始: {start}\n计划结束: {end}\n下一步: 提交\n---\n\n# {name}\n',encoding='utf-8')
    task('今天交报销',end='2026-10-10');task('上周的',end='2026-10-03');task('下周的',end='2026-10-17')
    task('没日期的');task('进行中的',start='2026-10-08',end='2026-10-12');task('已完成的',end='2026-10-10',state='已完成')
    return tmp_path

def test_today_merges_calendar_reminders_and_vault_todos(tmp_path):
    rem=tmp_path/'reminders.json'
    rem.write_text(json.dumps([{'id':'r1','text':'吃药','due':'2026-10-10 14:00','status':'pending'},
                               {'id':'r2','text':'昨天没处理','due':'2026-10-09 20:00','status':'pending'},
                               {'id':'r3','text':'明天','due':'2026-10-11 09:00','status':'pending'},
                               {'id':'r4','text':'取消了','due':'2026-10-10 15:00','status':'cancelled'}]))
    snap=Today(Hub(),ReminderCards(rem),vault(tmp_path),clock=lambda:NOW).snapshot()
    assert snap['date']=='2026-10-10' and snap['errors']=={}
    assert [e['title'] for e in snap['events']]==['国庆调休','周会'], '同一日程只算一次，明天的不算'
    assert snap['events'][0]['all_day'] and snap['events'][0]['informational']
    assert snap['events'][1]['location']=='3F'
    assert [(r['title'],r['overdue']) for r in snap['reminders']]==[('昨天没处理',True),('吃药',False)]
    assert [t['title'] for t in snap['todos']]==['上周的','今天交报销','进行中的']
    assert snap['todos'][0]['overdue'] and snap['todos'][1]['project']=='报销'

def test_broken_source_reports_error_without_hiding_others(tmp_path):
    snap=Today(Hub(),ReminderCards(tmp_path/'missing.json'),None,clock=lambda:NOW).snapshot()
    assert 'reminders' in snap['errors'] and len(snap['events'])==2 and snap['todos']==[]

def test_today_endpoint_is_wired_and_reports_missing_sources(tmp_path,monkeypatch):
    import importlib
    from fastapi.testclient import TestClient
    monkeypatch.setenv('WORKBENCH_HOME',str(tmp_path));monkeypatch.setenv('WORKBENCH_STATE',str(tmp_path/'state'))
    import app
    app=importlib.reload(app)
    with TestClient(app.app) as c:
        r=c.get('/personal/today',headers={'Authorization':'Bearer '+app.TOKEN})
    assert r.status_code==200
    body=r.json()
    assert set(body)>={'date','events','reminders','todos','errors'} and 'reminders' in body['errors'] and body['todos']==[]
