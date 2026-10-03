import asyncio
import sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from conversation import PersonalConversation
from artifacts import ArtifactAccess

class NoAgent:
    async def create_session(self):
        raise AssertionError('History must never start an executor')

def populate(tmp_path):
    c=PersonalConversation(tmp_path,NoAgent())
    with c.db() as db:
        db.executemany('INSERT INTO messages(id,role,text,status,created_at,updated_at,revision) VALUES(?,?,?,?,?,?,?)',
                       [(f'm{i:04d}','assistant',f'第{i}条合同记录 100%','completed',i//3,i//3,i+1) for i in range(620)])
        db.execute("UPDATE meta SET value='620' WHERE key='revision'")
    return c

def test_keyset_history_finds_older_than_500_without_duplicates(tmp_path):
    c=populate(tmp_path)
    snapshot=c.snapshot()['messages'];assert len(snapshot)==500
    page=c.history(before=snapshot[0]['id'],limit=60)
    assert page['has_more']
    second=c.history(before=page['next_before'],limit=60)
    ids=[m['id'] for m in second['messages']+page['messages']+snapshot]
    assert len(ids)==620 and len(set(ids))==620
    assert ids==sorted(ids)
    assert not second['has_more']
    assert c.search('第5条')['items'][0]['id']=='m0005'
    assert len(c.search('100%')['items'])==40
    assert c.search('_')['items']==[]
    around=c.history(around='m0005')['messages']
    assert 'm0005' in [r['id'] for r in around]
    with pytest.raises(ValueError):c.history(before='missing')
    with pytest.raises(ValueError):c.search(date='not-a-date')

def test_resume_and_future_cursor_fallback(tmp_path):
    c=populate(tmp_path)
    async def frame(cursor):
        stream=c.stream(cursor)
        result=await anext(stream);await stream.aclose();return result
    delta=asyncio.run(frame(615))
    assert delta['event']=='update' and len(delta['data']['messages'])==5
    assert asyncio.run(frame(620))['data']['messages']==[]
    assert asyncio.run(frame(700))['event']=='snapshot'

class Tasks:
    def __init__(self,records):self.records=records
    def list(self):return self.records

def test_registered_artifact_access_rejects_traversal_symlinks_hidden_and_missing(tmp_path):
    workspace=tmp_path/'workspace';workspace.mkdir()
    good=workspace/'result.md';good.write_text('真实成果')
    outside=tmp_path/'secret.txt';outside.write_text('private')
    link=workspace/'link.txt';link.symlink_to(outside)
    hidden=workspace/'.private.txt';hidden.write_text('private')
    tasks=Tasks([{'id':'t','cwd':str(workspace),'run_id':'r1','artifacts':[{'path':str(p)} for p in [good,outside,link,hidden,workspace/'missing.pdf']]}])
    access=ArtifactAccess(tasks,workspace);rows=access.index()
    assert [r['availability'] for r in rows]==['available','restricted','restricted','restricted','missing']
    assert access.resolve(rows[0]['id'])[1].read_text()=='真实成果'
    assert access.index()[0]['id']==rows[0]['id']
    with pytest.raises(PermissionError):access.resolve(rows[1]['id'])
    with pytest.raises(PermissionError):access.resolve(rows[2]['id'])
    with pytest.raises(FileNotFoundError):access.resolve(rows[-1]['id'])
    with pytest.raises(KeyError):access.resolve('arbitrary-path')
    good.unlink();good.symlink_to(outside)
    with pytest.raises(PermissionError):access.resolve(rows[0]['id'])

def test_protected_artifact_and_history_routes(tmp_path,monkeypatch):
    import importlib
    from fastapi.testclient import TestClient
    monkeypatch.setenv('WORKBENCH_HOME',str(tmp_path))
    monkeypatch.setenv('WORKBENCH_STATE',str(tmp_path/'state'))
    import app
    app=importlib.reload(app)
    workspace=tmp_path/'AI_Work_System';workspace.mkdir(exist_ok=True)
    report=workspace/'mobile.md';report.write_text('mini 的真实文件内容')
    app.artifact_access=ArtifactAccess(Tasks([{'id':'fixture','cwd':str(workspace),'artifacts':[{'path':str(report)}]}]),workspace)
    c=TestClient(app.app)
    aid=app.artifact_access.index()[0]['id'];headers={'Authorization':'Bearer '+app.TOKEN}
    assert c.get('/personal/artifacts/'+aid).status_code==401
    assert c.get('/personal/conversation/history').status_code==401
    assert c.get('/personal/artifacts/'+aid,headers=headers).text=='mini 的真实文件内容'
    assert c.get('/personal/artifacts/unknown',headers=headers).status_code==404
    assert c.get('/personal/conversation/history',headers=headers).json()['messages']==[]
    assert c.get('/personal/conversation/search?q=合同',headers=headers).json()['items']==[]

def test_main_deliverable_registration_is_durable_and_attached_once(tmp_path):
    workspace=tmp_path/'workspace';workspace.mkdir()
    report=workspace/'结果.md';report.write_text('实际结果')
    c=PersonalConversation(tmp_path,NoAgent())
    mid=c.submit('register-file-request','帮我导出结果')['message_id']
    a=ArtifactAccess(Tasks([]),workspace,tmp_path)
    artifact=a.register(mid,'结果.md');c.attach_artifact(mid,artifact)
    assert a.register(mid,'结果.md')['id']==artifact['id']
    c.attach_artifact(mid,artifact)
    messages=c.snapshot()['messages']
    assert messages[0]['artifacts']==[artifact]
    assert len(ArtifactAccess(Tasks([]),workspace,tmp_path).index())==1
    assert c.changes_since(0)['messages'][0]['artifacts'][0]['id']==artifact['id']
    record,file,size=a.open(artifact['id'])
    with file:assert file.read().decode()=='实际结果'
    assert size==report.stat().st_size
