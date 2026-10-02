import importlib
import sys
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def test_approved_proposal_dispatches_once_and_keeps_user_auth(tmp_path, monkeypatch):
    root = tmp_path / "AI_Work_System"
    (root / "example").mkdir(parents=True)
    monkeypatch.setenv("WORKBENCH_HOME", str(tmp_path))
    monkeypatch.setenv("WORKBENCH_STATE", str(tmp_path / "state"))
    import app
    app = importlib.reload(app)
    proposal = app.work_proposals.propose(
        agent="codex", relative_cwd="example", title="整理示例项目",
        prompt="检查并整理示例项目", sandbox="workspace-write",
        reason="涉及多个文件，需要 Codex", idempotency_key="test-codex-approval-001",
    )
    calls = []

    async def create(agent, cwd, **options):
        calls.append(("create", agent, cwd, options))
        return "codex:verified-001"

    async def send(sid, prompt, request_id, *args):
        calls.append(("input", sid, prompt, request_id))
        return "turn-001"

    monkeypatch.setattr(app.runtime, "create", create)
    monkeypatch.setattr(app.runtime, "input", send)
    async def models(agent):
        return [{'id':'native-default','is_default':True,'default_effort':'low'}]
    monkeypatch.setattr(app.runtime, "models", models)
    route = "/personal/work/proposals/" + proposal["id"] + "/approve"
    body = {"request_id": "user-approved-001", "explicit_authorization": True}
    with TestClient(app.app) as client:
        assert client.post(route, json=body).status_code == 401
        headers = {"Authorization": "Bearer " + app.TOKEN}
        first = client.post(route, headers=headers, json=body)
        second = client.post(route, headers=headers, json=body)
        assert first.status_code == second.status_code == 200
        assert first.json()["status"] == second.json()["status"] == "accepted"
        assert first.json()["work_session_id"] == "codex:verified-001"
        assert client.post(route, headers=headers, json={"request_id": "another-approval-001"}).status_code == 409
    assert [call[0] for call in calls] == ["create", "input"]
    assert calls[0][3]["sandbox"] == "workspace-write"


def test_refresh_does_not_authorize_and_tasks_expose_source(tmp_path, monkeypatch):
    (tmp_path / 'AI_Work_System' / 'example').mkdir(parents=True)
    monkeypatch.setenv('WORKBENCH_HOME', str(tmp_path))
    monkeypatch.setenv('WORKBENCH_STATE', str(tmp_path / 'state'))
    import app
    app=importlib.reload(app)
    card=app.work_proposals.propose(agent='codex',relative_cwd='example',title='A',prompt='inspect',
        sandbox='read-only',reason='explicit request',origin_message_id='source-A',idempotency_key='proposal-A-0001')
    with TestClient(app.app) as client:
        headers={'Authorization':'Bearer '+app.TOKEN}
        route='/personal/work/proposals/'+card['id']+'/approve'
        assert client.post(route,headers=headers,json={'request_id':'automatic-0001'}).status_code==409
        items=client.get('/personal/tasks',headers=headers).json()['items']
        assert items[0]['message_id']=='source-A'
        assert items[0]['status']=='approval_required'
        assert items[0]['authorization'] is None
        assert client.get('/personal/tasks').status_code==401
