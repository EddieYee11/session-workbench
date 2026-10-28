import json, sqlite3
from types import SimpleNamespace
from activity import Activity, summarize
from conversation import PersonalConversation


class Tasks:
    def list(self):
        return [{'id': 't1', 'title': '整理报销单', 'updated_at': 900}]


def test_activity_lists_recent_effects_and_uncertain_ones_get_verdicts(tmp_path):
    path = tmp_path / 'tool-effects.sqlite'
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE effects(key TEXT PRIMARY KEY,call_id TEXT,state TEXT NOT NULL,data TEXT NOT NULL)')
        db.execute('INSERT INTO effects VALUES (?,?,?,?)', ('old', 'c0', 'completed', json.dumps({'task_id': 't1'})))
        db.execute('INSERT INTO effects VALUES (?,?,?,?)', ('k1', 'c1', 'uncertain', json.dumps({'tool': 'bookkeeping', 'summary': summarize('bookkeeping', {'action': 'add', 'amount': 38, 'category': '餐饮', 'note': '午饭'}), 'at': 1000})))
        db.execute('INSERT INTO effects VALUES (?,?,?,?)', ('k2', 'c2', 'uncertain', json.dumps({'tool': 'remind', 'summary': '提醒', 'at': 9990})))
    act = Activity(path, PersonalConversation(tmp_path, SimpleNamespace()), Tasks(), clock=lambda: 10000)
    items = act.items()
    assert [i['key'] for i in items] == ['k2', 'k1', 'old']
    assert items[1]['summary'] == '记账 ¥38 餐饮 午饭' and items[1]['tool'] == 'bookkeeping' and items[2]['summary'] == '航程 · 整理报销单' and items[2]['at'] == 900
    assert [i['key'] for i in act.uncertain()] == ['k1'], '刚开始执行的（10 分钟内）不算不确定'
    assert act.verdict('k1', 'not_done')['state'] == 'not_done'
    assert act.uncertain() == [] and act.items()[1]['verdict'] == 'not_done'


def test_summaries_are_short_and_readable():
    assert summarize('calendar_event', {'action': 'add', 'title': '周会', 'start': '2026-10-27 10:00'}) == '日程新建「周会」2026-10-27 10:00'
    assert summarize('Write', {'path': '/a/b/报告.md'}) == '改文件 报告.md'
    assert summarize('collect', {'action': 'add'}) == 'collect 新建'


def test_feed_fields_type_since_and_detail(tmp_path):
    from activity import detail, kind
    path = tmp_path / 'tool-effects.sqlite'
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE effects(key TEXT PRIMARY KEY,call_id TEXT,state TEXT NOT NULL,data TEXT NOT NULL)')
        rows = [('a', {'tool': 'bookkeeping', 'detail': detail('bookkeeping', {'action': 'add', 'amount': 38, 'api_key': 'x', 'note': '午饭'}), 'at': 1}),
                ('b', {'tool': 'calendar_event', 'at': 2}), ('c', {'tool': 'bash', 'task_id': 't1', 'at': 3}), ('d', {'tool': 'wechat_send', 'at': 4})]
        for key, data in rows:
            db.execute('INSERT INTO effects VALUES (?,?,?,?)', (key, key, 'completed', json.dumps(data)))
    act = Activity(path, PersonalConversation(tmp_path, SimpleNamespace()), Tasks())
    items = act.items()
    assert [i['type'] for i in items] == ['outbound', 'work', 'schedule', 'ledger']
    assert items[-1]['detail'] == {'action': 'add', 'amount': '38', 'note': '午饭'}, '像凭据的字段不进详情'
    assert [i['key'] for i in act.items(since=items[1]['seq'])] == ['d'], 'since 只要更新的'
    assert kind('', 'task_x') == 'work' and kind('collect') == 'other'
