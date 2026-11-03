import asyncio, json, sqlite3
from task_audit import TaskAudit, found_paths, rework_message, ticket_for

NOW = 2_000_000_000.0


class Store:
    """真实 verify 的语义由 test_tasks 覆盖；这里只看核对把任务推到哪个状态。"""

    def __init__(self, tmp, tasks):
        self.path = tmp / 'tasks.sqlite'
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, data TEXT NOT NULL)')
            for task in tasks:
                db.execute('INSERT INTO tasks VALUES(?,?)', (task['id'], json.dumps(task)))
        self.verified = []

    def db(self):
        return sqlite3.connect(self.path)

    def get(self, ident):
        with self.db() as db:
            return json.loads(db.execute('SELECT data FROM tasks WHERE id=?', (ident,)).fetchone()[0])

    def change(self, ident, key, kind, summary='', **fields):
        task = {**self.get(ident), **fields}
        with self.db() as db:
            db.execute('UPDATE tasks SET data=? WHERE id=?', (json.dumps(task), ident))

    def verify(self, ident, evidence):
        self.verified.append((ident, evidence))
        self.change(ident, 'v', 'verified', verification_status='passed')


def task(tmp, **kw):
    return {'id': 't1', 'title': '写报告', 'cwd': str(tmp), 'status': 'execution_finished', 'verification_status': 'pending', 'updated_at': NOW - 600,
            'result': '写好了', 'completion_condition': '给出结论', 'result_round': 1, 'authorization': {'source_quote': '帮我写报告'}, **kw}


def run(tmp, tasks, answer, **kw):
    store = Store(tmp, tasks)

    async def judge(data):
        if isinstance(answer, Exception):
            raise answer
        judge.seen = data
        return answer
    audit = TaskAudit(store, tmp, tmp, judge=judge, clock=lambda: NOW, **kw)
    asyncio.run(audit.run_once())
    return store, audit, judge


PASS = {'verdict': 'pass', 'reason': '都有', 'evidence_gaps': [], 'next_steps': []}
REVISE = {'verdict': 'revise', 'reason': '缺附件', 'evidence_gaps': [{'criterion_id': 'original_goal', 'missing_evidence': '报告文件'}], 'next_steps': ['把报告写到文件']}
UNKNOWN = {'verdict': 'unknown', 'reason': '没有回读证据', 'evidence_gaps': [{'criterion_id': 'original_goal', 'missing_evidence': '回读'}], 'next_steps': []}


def test_pass_with_real_file_is_passed_with_file_evidence(tmp_path):
    report = tmp_path / 'report.md'
    report.write_text('结论')
    store, audit, _ = run(tmp_path, [task(tmp_path, result=f'写在 {report}')], PASS)
    assert store.get('t1')['verification_status'] == 'passed'
    assert store.verified[0][1][0]['reference'] == str(report)


def test_pass_without_any_file_is_only_reviewed(tmp_path):
    store, audit, _ = run(tmp_path, [task(tmp_path)], PASS)
    assert store.get('t1')['verification_status'] == 'reviewed' and not store.verified
    assert not audit.waiting()


def test_revise_and_unknown_go_to_waiting_with_a_ticket(tmp_path):
    store, audit, _ = run(tmp_path, [task(tmp_path)], REVISE)
    assert store.get('t1')['verification_status'] == 'needs_work'
    card = ticket_for(audit.waiting()[0])
    assert card['recommend'] == '把报告写到文件' and '报告文件' in card['basis'] and card['on_yes'] and card['on_no']


def test_unknown_is_uncertain(tmp_path):
    store, audit, _ = run(tmp_path, [task(tmp_path)], UNKNOWN)
    assert store.get('t1')['verification_status'] == 'uncertain' and audit.waiting()


def test_model_outage_stays_pending_stays_out_of_waiting_and_stops_after_three(tmp_path):
    store = Store(tmp_path, [task(tmp_path)])

    async def judge(data):
        raise RuntimeError('magpie down')
    audit = TaskAudit(store, tmp_path, tmp_path, judge=judge, clock=lambda: NOW)
    for _ in range(5):
        asyncio.run(audit.run_once())
    current = store.get('t1')
    assert current['verification_status'] == 'pending' and current['audit']['failures'] == 3
    assert not audit.waiting() and not audit.due()


def test_not_audited_twice_for_one_result_and_new_result_round_reaudits(tmp_path):
    store, audit, _ = run(tmp_path, [task(tmp_path)], PASS)
    store.change('t1', 'x', 'x', verification_status='pending')
    assert not audit.due()
    store.change('t1', 'x', 'x', result_round=2)
    assert [t['id'] for t in audit.due()] == ['t1']


def test_round_limit_stops_after_three(tmp_path):
    t = task(tmp_path, audit={'rounds': 3, 'result_round': 1}, result_round=2)
    store = Store(tmp_path, [t])
    assert not TaskAudit(store, tmp_path, tmp_path, clock=lambda: NOW).due()


def test_old_fresh_chat_and_waiting_cases_are_skipped(tmp_path):
    tasks = [task(tmp_path, id='old', updated_at=NOW - 8 * 86400), task(tmp_path, id='fresh', updated_at=NOW - 30),
             task(tmp_path, id='chat', authorization={'entry': 'work_page_human_chat'}), task(tmp_path, id='case'), task(tmp_path, id='ok')]
    store = Store(tmp_path, tasks)
    audit = TaskAudit(store, tmp_path, tmp_path, clock=lambda: NOW, skip=lambda t: t['id'] == 'case')
    assert [t['id'] for t in audit.due()] == ['ok']


def test_missing_path_is_reported_to_the_judge_and_sensitive_lines_stripped(tmp_path):
    report = tmp_path / 'a.md'
    report.write_text('正常内容\n密码是 123\n')
    _, _, judge = run(tmp_path, [task(tmp_path, result=f'写到 {report} 和 ~/nope/missing.md')], PASS)
    assert any('missing.md' in p for p in judge.seen['missing_paths'])
    excerpt = judge.seen['actual_checks'][0]['excerpt']
    assert '正常内容' in excerpt and '123' not in excerpt


def test_found_paths_ignores_empty_files(tmp_path):
    empty = tmp_path / 'empty.md'
    empty.write_text('')
    existing, missing = found_paths({'result': f'见 {empty}', 'cwd': str(tmp_path)}, tmp_path)
    assert not existing and str(empty) in missing


# ---- 写操作回读 ----
class Business:
    def __init__(self, **rows):
        self.rows = rows

    async def execute(self, tool, args):
        return {'items': self.rows.get(tool, [])}


def effects(tmp, *rows):
    path = tmp / 'tool-effects.sqlite'
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE effects(key TEXT PRIMARY KEY,call_id TEXT,state TEXT NOT NULL,data TEXT NOT NULL)')
        for i, (state, data) in enumerate(rows):
            db.execute('INSERT INTO effects(key,state,data) VALUES(?,?,?)', (f'k{i}', state, json.dumps({'at': NOW - 1000, **data})))
    return path


def states(path):
    with sqlite3.connect(path) as db:
        return {k: (s, json.loads(d).get('audit')) for k, s, d in db.execute('SELECT key,state,data FROM effects')}


def check(tmp, path, business):
    store = Store(tmp, [])
    return asyncio.run(TaskAudit(store, tmp, tmp, effects=path, business=business, clock=lambda: NOW).check_effects())


BOOK = {'tool': 'bookkeeping', 'detail': {'action': 'add', 'amount': '41.8', 'comment': '下午甜点'}}


def test_bookkeeping_found_stays_completed_and_missing_becomes_uncertain(tmp_path):
    path = effects(tmp_path, ('completed', BOOK))
    assert check(tmp_path, path, Business(bookkeeping=[{'sourceAmount': 4180, 'comment': '下午甜点'}])) == 1
    assert states(path)['k0'] == ('completed', {'found': True, 'at': NOW})
    path.unlink()
    path = effects(tmp_path, ('completed', BOOK))
    check(tmp_path, path, Business(bookkeeping=[{'sourceAmount': 999, 'comment': '午饭'}]))
    assert states(path)['k0'][0] == 'uncertain'


def test_calendar_missing_becomes_uncertain_but_later_edit_is_not_blamed(tmp_path):
    event = {'tool': 'calendar_event', 'detail': {'action': 'create', 'summary': '【工作】更新数据'}}
    path = effects(tmp_path, ('completed', event))
    check(tmp_path, path, Business(calendar_event=[]))
    assert states(path)['k0'][0] == 'uncertain'
    path.unlink()
    path = effects(tmp_path, ('completed', event), ('completed', {'tool': 'calendar_event', 'at': NOW - 500, 'detail': {'action': 'delete'}}))
    check(tmp_path, path, Business(calendar_event=[]))
    assert states(path)['k0'][0] == 'completed' and states(path)['k0'][1]['changed_later']


def test_reminder_past_due_cannot_be_read_back_and_verdicted_effects_are_left_alone(tmp_path):
    past = {'tool': 'remind', 'detail': {'action': 'add', 'text': '喝水', 'at': '2020-01-01 10:00'}}
    judged = {**BOOK, 'verdict': 'done'}
    path = effects(tmp_path, ('completed', past), ('confirmed', judged))
    check(tmp_path, path, Business())
    result = states(path)
    assert result['k0'][0] == 'completed' and result['k0'][1]['found'] is None
    assert result['k1'] == ('confirmed', None)


def test_too_fresh_and_too_old_effects_wait_or_are_skipped(tmp_path):
    path = effects(tmp_path, ('completed', {**BOOK, 'at': NOW - 10}), ('completed', {**BOOK, 'at': NOW - 2 * 86400}))
    assert check(tmp_path, path, Business()) == 0


def test_rework_message_never_authorizes_the_final_click():
    text = rework_message({'audit': {'gaps': [{'missing_evidence': '回执截图'}]}})
    assert '回执截图' in text and '不要对外发送、提交、付款或发布' in text


def test_judge_is_told_not_sending_is_not_a_gap():
    from task_audit import INSTRUCTIONS
    assert '不是缺口' in INSTRUCTIONS and 'Eddie 亲自点' in INSTRUCTIONS


def test_case_artifacts_count_as_real_files(tmp_path):
    page = tmp_path / 'page.html'
    page.write_text('草稿')
    store = Store(tmp_path, [task(tmp_path)])

    async def judge(data):
        return PASS
    audit = TaskAudit(store, tmp_path, tmp_path, judge=judge, clock=lambda: NOW, extra_paths=lambda t: [str(page)])
    asyncio.run(audit.run_once())
    assert store.get('t1')['verification_status'] == 'passed'


def test_earlier_rounds_reach_the_judge(tmp_path):
    store = Store(tmp_path, [task(tmp_path, result_round=2, result='提醒定好了')])
    with store.db() as db:
        db.execute('CREATE TABLE events(seq INTEGER, task_id TEXT, kind TEXT, text TEXT)')
        db.execute("INSERT INTO events VALUES(1,'t1','execution_finished','不用回复这封邮件')")
    seen = {}

    async def judge(data):
        seen.update(data)
        return PASS
    asyncio.run(TaskAudit(store, tmp_path, tmp_path, judge=judge, clock=lambda: NOW).run_once())
    assert seen['earlier_reports'] == ['不用回复这封邮件']


def test_found_paths_deduplicates_relative_and_absolute_and_resolves_vault_todos(tmp_path):
    report = tmp_path / 'work' / 'out.html'
    report.parent.mkdir(parents=True)
    log_json = tmp_path / 'work' / 'rollback.json'
    log_json.write_text('{"ok": true}')
    report.write_text('回滚日志在 <code>work/rollback.json</code>')
    vault = tmp_path / 'vault'
    done = vault / '任务' / '已完成' / '待办A.md'
    done.parent.mkdir(parents=True)
    done.write_text('状态: 已完成')
    kept = vault / '任务' / '待处理' / '待办B.md'
    kept.parent.mkdir(parents=True)
    kept.write_text('状态: 待处理')
    existing, missing = found_paths(
        {
            'result': '写了 work/out.html，并把 任务/待处理/待办A.md 标为完成',
            'prompt': '依据：\n- 行动台 · 待办B',
            'cwd': str(tmp_path),
        },
        tmp_path,
        extra=[str(report)],
        vault=vault,
    )
    assert existing == [str(report), str(done), str(kept), str(log_json)]
    assert not missing


def test_audit_includes_readback_checks_when_result_mentions_calendar_or_remind(tmp_path):
    store = Store(tmp_path, [task(tmp_path, result='已在日历创建事件并设置微信提醒')])
    seen = {}

    async def judge(data):
        seen.update(data)
        return PASS
    business = Business(remind=[{'text': '改密码'}], calendar_event=[{'title': '【工作】改密码'}])
    asyncio.run(TaskAudit(store, tmp_path, tmp_path, judge=judge, business=business, clock=lambda: NOW).run_once())
    refs = [c['reference'] for c in seen['actual_checks']]
    assert 'readback:remind' in refs and 'readback:calendar_event' in refs
