"""待办 → 提醒事项：对账式单向同步（用假 osascript，不碰真提醒事项）。"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from reminders_sync import RemindersSync
from today import Today

NOW = time.mktime((2026, 10, 22, 9, 30, 0, 0, 0, -1))


class Fake:
    """假 osascript：第一次调用是读列表，之后的是写脚本。"""

    def __init__(self, listing=''):
        self.listing, self.writes = listing, []

    def __call__(self, script):
        if 'repeat with r in' in script:
            return self.listing
        self.writes.append(script)
        return ''


def make(tmp_path, listing=''):
    vault = tmp_path / 'vault'
    (vault / '任务' / '待处理').mkdir(parents=True)
    (vault / '任务' / '已完成').mkdir(parents=True)
    today = Today(None, None, vault, clock=lambda: NOW)
    fake = Fake(listing)
    return RemindersSync(today, clock=lambda: NOW, run=fake), today, vault, fake


def test_new_todo_created_with_all_day_due(tmp_path):
    sync, today, vault, fake = make(tmp_path)
    today.todo_create('交报销单', '2026-10-23', next_step='发票贴好')
    report = sync.sync()
    assert report['status'] == 'completed' and report['created'] == ['交报销单']
    script = fake.writes[0]
    assert 'name:"交报销单"' in script and 'body:"发票贴好' in script and 'my do_date(2026, 10, 23)' in script


def test_event_todos_skipped_and_existing_not_duplicated(tmp_path):
    sync, today, vault, fake = make(tmp_path, '交报销单\tfalse\t2026-10-23\n')
    today.todo_create('交报销单', '2026-10-23')
    today.todo_create('周会', '2026-10-22', event_id='e1')
    report = sync.sync()
    assert report['created'] == [] and report['updated'] == [] and fake.writes == []


def test_due_change_updates_and_done_ticks_reminder(tmp_path):
    sync, today, vault, fake = make(tmp_path, '交报销单\tfalse\t2026-10-23\n已做完\tfalse\t2026-10-21\n他勾掉的\ttrue\t\n')
    today.todo_create('交报销单', '2026-10-25')
    (vault / '任务' / '已完成' / '已做完.md').write_text('---\nflow: 任务\n---\n', encoding='utf-8')
    report = sync.sync()
    assert report['updated'] == ['交报销单'] and report['completed'] == ['已做完']
    script = fake.writes[0]
    assert 'my do_date(2026, 10, 25)' in script and 'set completed' in script and '他勾掉的' not in script


def test_failure_does_not_raise_and_quotes_escaped(tmp_path):
    sync, today, vault, fake = make(tmp_path)
    sync._run = lambda script: (_ for _ in ()).throw(RuntimeError('没有权限'))
    assert sync.sync()['status'] == 'failed'
    from reminders_sync import _q
    assert _q('说"你\\好') == '"说\\"你\\\\好"'
