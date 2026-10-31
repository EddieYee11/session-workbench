"""已排程治理：汇总、暂停后不再触发、只读项 409、Hermes 失败不拖垮。"""
import asyncio
import importlib
import sqlite3
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastapi import HTTPException
from proactive import Proactive
from routines import NotControllable, Routines, UnknownRoutine

TZ = ZoneInfo('Asia/Shanghai')


def at(hour, minute, day=7):
    return datetime(2026, 10, day, hour, minute, tzinfo=TZ).timestamp()


class FakeHermes:
    def __init__(self, fail=False):
        self.fail, self.calls = fail, []
        self.jobs = [{'id': 'j1', 'name': 'Com · 健康同步', 'schedule_display': '*/30 * * * *', 'enabled': True, 'state': 'scheduled',
                      'next_run_at': '2026-10-07T21:30:00+08:00', 'last_run_at': '2026-10-07T21:00:00+08:00', 'last_status': 'ok'},
                     {'id': 'x9', 'name': '别的任务', 'enabled': True}]

    async def request(self, method, path, body=None, timeout=20):
        self.calls.append((method, path))
        if self.fail:
            raise RuntimeError('hermes_api_500')
        if path == '/api/jobs':
            return {'jobs': self.jobs}
        return {'job': {}}


def make(tmp_path, hermes=None, now=at(20, 0)):
    scheduler = Proactive(tmp_path, clock=lambda: now)
    return scheduler, Routines(tmp_path, scheduler, hermes=hermes, next_steps_path=tmp_path / 'next-steps.sqlite', clock=lambda: now)


def run(coro):
    return asyncio.run(coro)


def test_list_covers_sources_and_flags(tmp_path):
    db = sqlite3.connect(tmp_path / 'next-steps.sqlite')
    db.execute('CREATE TABLE runs(id INTEGER PRIMARY KEY, at REAL, source TEXT, count INTEGER, error TEXT)')
    db.execute("INSERT INTO runs(at,source,count,error) VALUES (?,?,?,?)", (at(19, 0), 'rules', 0, 'boom'))
    db.commit(); db.close()
    _, routines = make(tmp_path, FakeHermes())
    data = run(routines.list())
    rows = {r['id']: r for r in data['items']}
    assert data['paused'] is False
    assert rows['proactive:evening-review']['controllable'] and rows['proactive:evening-review']['next_run_at'].startswith('2026-10-07T21:00')
    assert not rows['nudges']['controllable'] and rows['nudges']['note'] == '跟随全部暂停'
    assert rows['next-steps']['last_status'].startswith('失败：boom') and not rows['next-steps']['controllable']
    assert rows['tomorrow-plan']['trigger'].endswith('21:30') and not rows['tomorrow-plan']['controllable']
    assert rows['weekly-report']['next_run_at'].startswith('2026-10-08T13:30')  # 2026-10-07 是周三
    assert rows['cron:j1']['controllable'] and rows['cron:j1']['title'] == '健康同步' and rows['cron:j1']['last_status'] == 'ok'
    assert 'cron:x9' not in rows


def test_pause_item_stops_proactive_firing_and_resume_restores(tmp_path):
    scheduler, routines = make(tmp_path, FakeHermes(), now=at(21, 0))
    assert [r['id'] for r in scheduler.due()] == ['evening-review']
    result = run(routines.act('proactive:evening-review', 'pause'))
    row = next(r for r in result['items'] if r['id'] == 'proactive:evening-review')
    assert row['enabled'] is False and row['next_run_at'] is None
    assert scheduler.due() == []
    assert scheduler.settings()['items'][0]['at'] == '09:00'  # 其他字段不动
    run(routines.act('proactive:evening-review', 'resume'))
    assert [r['id'] for r in scheduler.due()] == ['evening-review']


def test_pause_all_blocks_every_proactive_tick(tmp_path):
    scheduler, routines = make(tmp_path, FakeHermes(), now=at(21, 0))
    assert run(routines.act('_all', 'pause'))['paused'] is True
    assert scheduler.due() == []
    assert run(routines.act('_all', 'resume'))['paused'] is False
    assert scheduler.due()


def test_read_only_items_409_and_unknown_404(tmp_path):
    _, routines = make(tmp_path, FakeHermes())
    for ident in ('nudges', 'next-steps', 'tomorrow-plan', 'weekly-report'):
        with pytest.raises(NotControllable):
            run(routines.act(ident, 'pause'))
    with pytest.raises(UnknownRoutine):
        run(routines.act('proactive:nope', 'pause'))
    with pytest.raises(UnknownRoutine):
        run(routines.act('cron:x9', 'pause'))  # 非「Com ·」任务不碰


def test_cron_pause_calls_hermes_routes(tmp_path):
    hermes = FakeHermes()
    _, routines = make(tmp_path, hermes)
    run(routines.act('cron:j1', 'pause'))
    run(routines.act('cron:j1', 'resume'))
    assert ('POST', '/api/jobs/j1/pause') in hermes.calls and ('POST', '/api/jobs/j1/resume') in hermes.calls


def test_hermes_failure_does_not_break_listing(tmp_path):
    _, routines = make(tmp_path, FakeHermes(fail=True))
    rows = {r['id']: r for r in run(routines.list())['items']}
    assert rows['cron:_unavailable']['controllable'] is False and '读不到' in rows['cron:_unavailable']['note']
    assert 'proactive:morning-briefing' in rows


def test_api_maps_errors(tmp_path, monkeypatch):
    monkeypatch.setenv('WORKBENCH_HOME', str(tmp_path))
    monkeypatch.setenv('WORKBENCH_STATE', str(tmp_path / 'state'))
    import app as app_module
    app_module = importlib.reload(app_module)  # 状态目录指向 tmp，不碰真实 ~/.session-workbench
    _, routines = make(tmp_path, FakeHermes())
    monkeypatch.setattr(app_module, 'routines', routines)

    class Req:
        def __init__(self, body): self.body = body
        async def json(self): return self.body
    with pytest.raises(HTTPException) as e:
        run(app_module.routines_act('nudges', Req({'action': 'pause'})))
    assert e.value.status_code == 409
    with pytest.raises(HTTPException) as e:
        run(app_module.routines_act('proactive:evening-review', Req({'action': 'x'})))
    assert e.value.status_code == 400


def test_cron_label_is_readable():
    from routines import cron_label
    assert cron_label('10,25,40,55 * * * *') == '每 15 分钟'
    assert cron_label('5,35 * * * *') == '每 30 分钟'
    assert cron_label('0 9 * * *') == '每天 09:00'
    assert cron_label('0 9 * * 1') == '0 9 * * 1'
