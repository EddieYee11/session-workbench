"""2026-10-17 案例 + 下一步/待办闭环 + 明天建议。"""
import asyncio, json, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cases import Cases
from next_steps import NextSteps
from tasks import TaskStore
from today import Today
from tomorrow_plan import TomorrowPlan

NOW = time.mktime((2026, 10, 17, 21, 40, 0, 0, 0, -1))


class Chat:
    def __init__(self):
        self.submitted, self.receipts = [], []

    def submit(self, request_id, text):
        self.submitted.append(text)
        return {'request_id': request_id, 'state': 'accepted'}

    def task_receipt(self, ident, text, parent_id=None):
        self.receipts.append((ident, text))


class Controller:
    def __init__(self):
        self.commands = []

    async def command(self, tid, text, request_id, cancel=False):
        self.commands.append((tid, text, cancel))
        return {'task_id': tid, 'delivery': 'queued'}


def vault(tmp_path):
    root = tmp_path / 'vault'
    (root / '任务' / '待处理').mkdir(parents=True)
    return root


def engine(tmp_path, items):
    async def model(digest):
        return {'items': items}
    hub = type('Hub', (), {'matters': lambda self: [{'id': 'm1', 'source': 'work_mail', 'title': 'Q4 排期', 'facts': {}, 'source_updated_at': NOW, 'changed_at': NOW, 'feedback': {}}]})()
    return NextSteps(tmp_path, hub, model=model, clock=lambda: NOW, vault=vault(tmp_path))


ITEM = {'title': '回复王总的排期邮件', 'why': '对方在等', 'refs': ['mail:m1'], 'prompt': '起草回复给我确认', 'urgency': 'now', 'score': 90}


def setup(tmp_path, brief=None):
    steps = engine(tmp_path, [ITEM])
    asyncio.run(steps.refresh(force=True))
    store, chat = TaskStore(tmp_path), Chat()
    (tmp_path / 'ws').mkdir()
    today = Today(vault=steps.vault, clock=lambda: NOW)
    cases = Cases(tmp_path, store, Controller(), chat, tmp_path / 'ws', today=today, next_steps=steps, brief=brief, clock=lambda: NOW)
    return steps, store, chat, today, cases


def test_delegate_creates_pi_case_and_finish_links_back(tmp_path):
    async def brief(data):
        assert data['title'] == '回复王总的排期邮件' and data['evidence']
        return {'route': 'case', 'title': '起草排期回复', 'goal': '给王总一份排期回复草稿', 'steps': ['读邮件', '起草', '给他确认'], 'completion': '草稿可直接发', 'prompt': '读 Q4 排期邮件并起草回复'}
    steps, store, chat, today, cases = setup(tmp_path, brief)
    item = steps.snapshot()['items'][0]
    result = asyncio.run(cases.delegate('next', item['id'], item['title'], item['prompt'], 'req-delegate-0001', ['工作邮箱 · Q4 排期']))
    assert result['mode'] == 'case'
    task = store.list()[0]
    assert task['agent'] == 'pi' and task['interactive'] and task['status'] == 'queued' and task['case_source'] == 'next'
    assert '[Com 案例规则]' in task['prompt'] and task['authorization']['entry'] == 'case_button'
    # 同一条再点一次：不重复建
    again = asyncio.run(cases.delegate('next', item['id'], item['title'], item['prompt'], 'req-delegate-0002'))
    assert again['task_id'] == result['task_id'] and len(store.list()) == 1
    listing = cases.list()
    assert listing['active'] == 1 and listing['items'][0]['progress'] == {'done': 0, 'total': 3}
    # Pi 汇报
    cases.progress(task['id'], {'steps': [{'title': '读邮件', 'status': 'done'}, {'title': '起草', 'status': 'doing'}], 'now': '在写回复', 'assumption': '按周五交付写'})
    detail = cases.detail(task['id'])
    assert detail['now'] == '在写回复' and detail['assumptions'][0]['text'] == '按周五交付写'
    assert any(t['kind'] == 'step_done' for t in detail['timeline'])
    # 跑完：下一步自动标完成
    store.change(task['id'], 'started:' + task['id'], 'started', status='running', session_id='pi:x', run_id='r1')
    store.finish(task['id'], 'execution_finished', '草稿已写好')
    assert cases.sync() == 1
    with steps.db() as db:
        assert db.execute('SELECT state FROM items WHERE id=?', (item['id'],)).fetchone()['state'] == 'done'
    assert cases.list()['items'][0]['state'] == 'done'


def test_small_things_go_back_to_hermes_chat(tmp_path):
    async def brief(data):
        return {'route': 'chat'}
    steps, store, chat, today, cases = setup(tmp_path, brief)
    item = steps.snapshot()['items'][0]
    result = asyncio.run(cases.delegate('next', item['id'], item['title'], item['prompt'], 'req-delegate-0003'))
    assert result['mode'] == 'chat' and chat.submitted and not store.list()


def test_waiting_for_deletion_is_not_done_and_pushes(tmp_path):
    steps, store, chat, today, cases = setup(tmp_path)
    item = steps.snapshot()['items'][0]
    tid = asyncio.run(cases.delegate('next', item['id'], item['title'], item['prompt'], 'req-delegate-0004'))['task_id']
    cases.progress(tid, {'status': 'waiting', 'question': '删掉旧的 3 份草稿？'})
    assert chat.receipts and chat.receipts[0][0].startswith('case-wait:')
    store.change(tid, 'started:' + tid, 'started', status='running', session_id='pi:x', run_id='r1')
    store.finish(tid, 'execution_finished', '等你批准删除')
    assert cases.sync() == 0 and cases.list()['items'][0]['state'] == 'waiting'
    cases.resolve(tid)
    assert cases.list()['items'][0]['state'] == 'done'


def test_add_to_todo_dedups_next_round(tmp_path):
    steps, store, chat, today, cases = setup(tmp_path)
    item = steps.snapshot()['items'][0]
    from next_steps import _sig
    made = today.todo_create(item['title'], '2026-10-18', item['prompt'], item['why'], item['prompt'], item['id'], [_sig(e['ref'], e) for e in item['evidence']])
    assert made['status'] == 'created'
    text = (steps.vault / made['path']).read_text(encoding='utf-8')
    assert 'flow: 任务' in text and '计划结束: 2026-10-18' in text and 'com_next_id: ' + item['id'] in text
    assert today.todo_create(item['title'], '2026-10-19')['status'] == 'exists'  # 不覆盖
    # 下一轮模型换个说法再提同一封邮件：按依据签名去重，不再出现
    steps.model = lambda d: asyncio.sleep(0, {'items': [{**ITEM, 'title': '推进王总排期回复'}]})
    asyncio.run(steps.refresh(force=True))
    assert steps.snapshot()['items'] == []


def test_manual_todo_with_same_name_is_badged(tmp_path):
    steps, store, chat, today, cases = setup(tmp_path)
    (steps.vault / '任务' / '待处理' / '回复王总的排期邮件.md').write_text('---\nflow: 任务\n状态: 待处理\n计划结束: 2026-10-18\n---\n', encoding='utf-8')
    asyncio.run(steps.refresh(force=True))
    items = steps.snapshot()['items']
    assert items and items[0]['in_todo']['due'] == '2026-10-18'


def test_snooze_hides_until_tomorrow(tmp_path):
    steps = engine(tmp_path, [ITEM])
    asyncio.run(steps.refresh(force=True))
    ident = steps.snapshot()['items'][0]['id']
    steps.act(ident, 'snooze')
    asyncio.run(steps.refresh(force=True))
    assert steps.snapshot()['items'] == []
    steps.clock = lambda: NOW + 86400
    asyncio.run(steps.refresh(force=True))
    assert [i['id'] for i in steps.snapshot()['items']] == [ident]


def test_tomorrow_plan_applies_selected(tmp_path):
    steps, store, chat, today, cases = setup(tmp_path)
    folder = steps.vault / '任务' / '待处理'
    (folder / '交报销单.md').write_text('---\nflow: 任务\n状态: 待处理\n计划结束: 2026-10-15\n---\n', encoding='utf-8')
    (folder / '明天的事.md').write_text('---\nflow: 任务\n状态: 待处理\n计划结束: 2026-10-18\n---\n', encoding='utf-8')
    plan = TomorrowPlan(tmp_path, steps, today, cases, chat, clock=lambda: NOW)
    assert plan.due()
    made = plan.generate()
    kinds = {i['title']: i for i in made['items']}
    assert kinds['交报销单']['overdue'] and kinds['交报销单']['checkable']
    assert not kinds['明天的事']['checkable'] and kinds['回复王总的排期邮件']['kind'] == 'next'
    assert chat.receipts[-1][0] == 'plan:2026-10-18' and not plan.due()
    result = plan.apply('2026-10-18', [kinds['交报销单']['id'], kinds['回复王总的排期邮件']['id']])
    assert {r['status'] for r in result['results']} == {'postponed', 'created'}
    assert '计划结束: 2026-10-18' in (folder / '交报销单.md').read_text(encoding='utf-8')
    assert (folder / '回复王总的排期邮件.md').exists()
    assert plan.apply('2026-10-18', [])['repeat']


def test_failed_outcome_does_not_tick_next_step(tmp_path):
    steps, store, chat, today, cases = setup(tmp_path)
    item = steps.snapshot()['items'][0]
    tid = asyncio.run(cases.delegate('next', item['id'], item['title'], item['prompt'], 'req-delegate-0005'))['task_id']
    cases.progress(tid, {'status': 'failed', 'question': '读不到邮件'})
    store.change(tid, 'started:' + tid, 'started', status='running', session_id='pi:x', run_id='r1')
    store.finish(tid, 'execution_finished', '没做成')
    cases.sync()
    assert cases.list()['items'][0]['state'] == 'failed'
    with steps.db() as db:
        assert db.execute('SELECT state FROM items WHERE id=?', (item['id'],)).fetchone()['state'] == 'open'


def test_turn_plan_is_thinking_process_and_complex_turns_become_cases(tmp_path):
    from conversation import PersonalConversation
    from cases import merge_plan
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from test_conversation import FakeHermes
    convo = PersonalConversation(tmp_path, FakeHermes())
    mid = convo.submit('turn-plan-msg-0001', '帮我把下周三的拍摄排一下')['message_id']
    with convo.db() as db:
        db.execute("UPDATE messages SET status='running' WHERE id=?", (mid,))
    store = TaskStore(tmp_path)
    (tmp_path / 'ws').mkdir()
    cases = Cases(tmp_path, store, Controller(), convo, tmp_path / 'ws', clock=lambda: NOW)
    out = cases.turn_plan({'title': '排下周三拍摄', 'todos': [
        {'content': '查下周三日程', 'activeForm': '正在查日程', 'status': 'in_progress'},
        {'content': '找空档', 'activeForm': '正在找空档'}, {'content': '建日程', 'activeForm': '正在建日程'}]})
    assert out['progress'] == '0/3'
    # 工具事件整份写 tasks 时不能把清单冲掉
    convo._record_tasks(mid, [{'id': 'tool-1', 'kind': 'tool', 'tool': 'calendar', 'status': 'running'}])
    plan = convo.plan_of(mid)
    assert plan['title'] == '排下周三拍摄' and plan['todos'][0]['active'] == '正在查日程'
    cases.turn_plan({'updates': [{'id': '1', 'status': 'completed'}, {'id': '2', 'status': 'in_progress'}]})
    listing = cases.list()['items']
    assert listing[0]['id'] == 'turn:' + mid and listing[0]['state'] == 'running' and listing[0]['now'] == '正在找空档'
    with convo.db() as db:
        db.execute("UPDATE messages SET status='completed' WHERE id=?", (mid,))
    detail = cases.detail('turn:' + mid)
    assert detail['state'] == 'done' and [s['status'] for s in detail['steps']] == ['done', 'doing', 'todo']
    # 两步以内的简单轮次不进列表
    assert len(merge_plan(None, {'todos': [{'content': '查天气'}]})['todos']) == 1


def test_auto_turn_plan_advances_with_tools_and_finishes():
    from turn_planner import advance, clean_plan, finish, responding
    assert clean_plan({'title': '', 'todos': []}) is None  # 闲聊不出清单
    plan = clean_plan({'title': '明天日程和本周花销', 'todos': [
        {'content': '查明天日程', 'activeForm': '正在查日程', 'kind': 'calendar'},
        {'content': '算本周花销', 'activeForm': '正在翻账本', 'kind': 'ledger'},
        {'content': '一句话总结', 'activeForm': '正在写总结', 'kind': 'reply'}]})
    assert plan['todos'][0]['status'] == 'in_progress'
    assert not advance(plan, 'mcp__com_workbench__tool_describe')  # 工具发现这类内部调用不推进
    assert advance(plan, 'mcp__com_workbench__business_operation')  # 记账/查账同族
    assert [t['status'] for t in plan['todos']] == ['completed', 'in_progress', 'pending']
    assert responding(plan) and plan['todos'][2]['status'] == 'in_progress'
    finish(plan, True)
    assert all(t['status'] == 'completed' for t in plan['todos'])


def test_threads_walk_and_order(tmp_path):
    from threads import Threads
    t = Threads(tmp_path, clock=lambda: NOW)
    t.link('next:n1', 'todo:任务/待处理/a.md', '加到待办')
    t.link('todo:任务/待处理/a.md', 'case:task_1', '交给 Com')
    info = {'next:n1': {'title': '回复王总'}, 'todo:任务/待处理/a.md': {'title': 'a'}, 'case:task_1': {'title': '起草'}, 'project:合同': {'title': '合同'}}
    out = t.thread('case:task_1', resolve=info.get, implicit=lambda k: [('project:合同', '关联项目')] if k.startswith('todo:') else [])
    assert [n['kind'] for n in out['nodes']] == ['next', 'todo', 'case', 'project']
    assert next(n for n in out['nodes'] if n['current'])['key'] == 'case:task_1'
    gone = t.thread('case:task_1', resolve=lambda k: info.get(k) if k != 'next:n1' else None)
    assert 'next:n1' not in [n['key'] for n in gone['nodes']]  # 已经不存在的节点不显示


def test_case_conclusion_flows_back_to_todo_and_project(tmp_path):
    steps, store, chat, today, cases = setup(tmp_path)
    from threads import Threads
    cases.threads = Threads(tmp_path, clock=lambda: NOW)
    (steps.vault / '项目').mkdir()
    (steps.vault / '项目' / '合同与劳务结算.md').write_text('---\nflow: 项目\n---\n\n# 合同\n\n## 轻量待办\n\n- [ ] x\n\n## 笔记\n', encoding='utf-8')
    todo = steps.vault / '任务' / '待处理' / '交报销单.md'
    todo.write_text('---\nflow: 任务\n状态: 待处理\n关联项目: "[[合同与劳务结算]]"\n计划结束: 2026-10-15\n---\n\n# 交报销单\n\n## 进展\n- 2026-10-05 建立\n\n## 备注\n', encoding='utf-8')
    tid = asyncio.run(cases.delegate('todo', '任务/待处理/交报销单.md', '交报销单', '处理报销', 'req-delegate-0006', todo_path='任务/待处理/交报销单.md'))['task_id']
    store.change(tid, 'started:' + tid, 'started', status='running', session_id='pi:x', run_id='r1')
    store.finish(tid, 'execution_finished', '**已核对 12 张发票**，差 1 张\n其余已提交')
    cases.sync()
    text = todo.read_text(encoding='utf-8')
    assert '- 2026-10-05 建立\n- 2026-10-17 Com 案例「交报销单」完成：已核对 12 张发票，差 1 张\n\n## 备注' in text
    assert '状态: 已完成' in text  # 回流后再打勾
    project = (steps.vault / '项目' / '合同与劳务结算.md').read_text(encoding='utf-8')
    assert '## 进展\n\n- 2026-10-17 Com 案例「交报销单」完成' in project and project.index('## 进展') < project.index('## 笔记')
    links = cases.threads.thread('case:' + tid, resolve=lambda k: {'title': k})
    assert {n['key'] for n in links['nodes']} >= {'todo:任务/待处理/交报销单.md', 'project:合同与劳务结算'}
    assert any(t['text'].startswith('结论已写进') for t in cases.detail(tid)['timeline'])
