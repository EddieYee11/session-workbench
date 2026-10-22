"""日程即当天待办（Eddie 设定）：当天日程同步成行动台待办 —— 幂等、改期、不覆盖、取消保留。

风格同 test_today_todos.py：临时 vault + 可控时钟；日历链路用 Today 的既有 hub.matters() 假数据。
"""
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from calendar_todos import CalendarTodos
from today import Today

NOW = time.mktime((2026, 10, 10, 9, 30, 0, 0, 0, -1))


class Hub:
    """最小日程 hub：matters() 的形状与 personal_hub 一致（facts.start/end、feedback）。"""

    def __init__(self, rows=()):
        self.rows = list(rows)

    def matters(self):
        return list(self.rows)


def event(ident='e1', title='周会', start='2026-10-10T11:00:00+08:00', end='2026-10-10T12:00:00+08:00',
          source='apple_calendar', calendar='', **facts):
    return {'id': ident, 'source': source, 'title': title, 'feedback': {},
            'facts': {'start': start, 'end': end, 'calendar': calendar, **facts}}


def make(tmp_path, rows):
    vault = tmp_path / 'vault'
    (vault / '任务' / '待处理').mkdir(parents=True)
    (vault / '任务' / '已完成').mkdir(parents=True)
    today = Today(Hub(rows), None, vault, clock=lambda: NOW)
    return CalendarTodos(today, clock=lambda: NOW), today, vault, vault / '任务' / '待处理'


def front(path):
    """读属性头 key → value（去掉两边空白），只看第一段 `---`。"""
    head = path.read_text(encoding='utf-8').split('---')[1]
    return {k.strip(): v.strip().strip('"') for k, v in (line.split(':', 1) for line in head.splitlines() if ':' in line)}


def test_today_events_become_todos_with_source(tmp_path):
    sync, today, vault, folder = make(tmp_path, [event(), event('e2', '去机场', '2026-10-10T15:00:00+08:00', '2026-10-10T16:00:00+08:00', calendar='Pi')])
    report = sync.sync()
    assert report['status'] == 'completed' and report['events'] == 2
    assert sorted(report['created']) == ['去机场', '周会'] and report['updated'] == []
    assert sorted(p.stem for p in folder.glob('*.md')) == ['去机场', '周会']
    f = front(folder / '周会.md')
    assert f['flow'] == '任务' and f['状态'] == '待处理'
    assert f['计划结束'] == '2026-10-10' and f['计划开始'] == ''
    assert f['com_event_id'] == 'e1'
    assert f['备注'].startswith('来源：日程') and '日程 id：e1' in f['备注'] and '开始：2026-10-10 11:00' in f['备注']
    机场 = front(folder / '去机场.md')
    assert 机场['com_event_id'] == 'e2' and '日历：Pi' in 机场['备注']
    # 当天就出现在「今天」页的待办里
    assert sorted(t['title'] for t in today.snapshot()['todos']) == ['去机场', '周会']


def test_all_day_event_is_included_and_note_says_all_day(tmp_path):
    sync, _, _, folder = make(tmp_path, [event('e9', '装修验收', {'date': '2026-10-10'}, {'date': '2026-10-11'})])
    assert sync.sync()['created'] == ['装修验收']
    assert '开始：全天' in front(folder / '装修验收.md')['备注']


def test_holidays_are_not_todos(tmp_path):
    sync, _, _, folder = make(tmp_path, [
        event('h1', '国庆节', '2026-10-10', '2026-10-11', calendar='中国大陆节假日'),
        event('h2', '春节', '2026-10-10T00:00:00+08:00', '2026-10-10T23:00:00+08:00'),
    ])
    report = sync.sync()
    assert report['events'] == 0 and report['created'] == [] and list(folder.glob('*.md')) == []


def test_rerun_same_day_creates_nothing_and_writes_nothing(tmp_path):
    sync, _, _, folder = make(tmp_path, [event()])
    first = sync.sync()
    assert first['created'] == ['周会']
    stamp = (folder / '周会.md').stat().st_mtime_ns
    again = sync.sync()
    assert again['created'] == [] and again['updated'] == [] and again['unchanged'] == ['周会']
    assert (folder / '周会.md').stat().st_mtime_ns == stamp, '重复跑不该重写文件'
    assert len(list(folder.glob('*.md'))) == 1


def test_reschedule_updates_due_without_duplicate(tmp_path):
    sync, _, _, folder = make(tmp_path, [event('e1', '周会', '2026-10-10T11:00:00+08:00', '2026-10-10T12:00:00+08:00')])
    sync.sync()
    # Eddie 把这条日程挪到明天 17:30（记忆 mem_6aba33c1：当天没做完的统一往后挪）
    sync.today.hub.rows = [event('e1', '周会', '2026-10-11T17:30:00+08:00', '2026-10-11T18:30:00+08:00')]
    report = sync.sync(day='2026-10-11')
    assert report['updated'] == ['周会'] and report['created'] == []
    path = folder / '周会.md'
    assert [p.name for p in folder.glob('*.md')] == ['周会.md'], '改期不产生第二个文件'
    f = front(path)
    assert f['计划结束'] == '2026-10-11' and f['com_event_id'] == 'e1'
    assert '开始：2026-10-11 17:30' in f['备注'], '来源备注跟着日程改期刷新'
    assert path.read_text(encoding='utf-8').count('## 进展') == 1


def test_existing_same_name_todo_is_never_touched(tmp_path):
    sync, _, vault, folder = make(tmp_path, [event('e1', '周会')])
    mine = folder / '周会.md'
    mine.write_text('---\nflow: 任务\n状态: 待处理\n计划结束: 2026-10-01\n备注: 我自己写的\n---\n\n# 周会\n\n手写的正文\n', encoding='utf-8')
    before = mine.read_bytes()
    report = sync.sync()
    assert report['created'] == [] and report['skipped'] == ['周会（同名待办已在，不覆盖）']
    assert mine.read_bytes() == before, '同名文件一个字节都不动'


def test_completed_todo_is_not_recreated(tmp_path):
    sync, _, vault, folder = make(tmp_path, [event('e1', '周会')])
    sync.sync()
    (vault / '任务' / '已完成' / '周会.md').write_bytes((folder / '周会.md').read_bytes())  # auto-move 插件勾完挪走
    (folder / '周会.md').unlink()
    report = sync.sync()
    assert report['created'] == [] and report['skipped'] == ['周会（已经做完，不再重建）']
    assert list(folder.glob('*.md')) == []


def test_user_edited_note_is_not_overwritten_on_resync(tmp_path):
    sync, _, _, folder = make(tmp_path, [event('e1', '周会')])
    sync.sync()
    path = folder / '周会.md'
    path.write_text('\n'.join('备注: 要和 Judy 对物料' if line.startswith('备注:') else line
                             for line in path.read_text(encoding='utf-8').splitlines()) + '\n', encoding='utf-8')
    sync.today.hub.rows = [event('e1', '周会', '2026-10-11T17:30:00+08:00', '2026-10-11T18:30:00+08:00')]
    report = sync.sync(day='2026-10-11')
    assert report['updated'] == ['周会']
    f = front(path)
    assert f['计划结束'] == '2026-10-11' and f['备注'] == '要和 Judy 对物料', '用户改过的备注不覆盖'


def test_cancelled_event_keeps_todo(tmp_path):
    sync, _, _, folder = make(tmp_path, [event('e1', '周会')])
    sync.sync()
    before = (folder / '周会.md').read_bytes()
    sync.today.hub.rows = []          # 日程被取消／从日历里消失
    report = sync.sync()
    assert report['events'] == 0 and report['created'] == [] and report['skipped'] == []
    assert (folder / '周会.md').read_bytes() == before, '日程取消不改、不删已有待办'


def test_two_events_same_title_create_one_file(tmp_path):
    sync, _, _, folder = make(tmp_path, [
        event('e1', '周会', '2026-10-10T11:00:00+08:00', '2026-10-10T12:00:00+08:00'),
        event('e2', '周会', '2026-10-10T16:00:00+08:00', '2026-10-10T17:00:00+08:00'),
    ])
    report = sync.sync()
    assert report['created'] == ['周会'] and report['skipped'] == ['周会（同名待办已在，不覆盖）']
    assert [p.name for p in folder.glob('*.md')] == ['周会.md']


def test_bracketed_event_title_matches_hand_written_todo(tmp_path):
    """日程「【AI德州扑克】预赛」与已经手建的「AI德州扑克预赛」算同名，不另建一份。"""
    sync, _, _, folder = make(tmp_path, [event('e1', '【AI德州扑克】预赛', '2026-10-10', '2026-10-11')])
    mine = folder / 'AI德州扑克预赛.md'
    mine.write_text('---\nflow: 任务\n状态: 待处理\n计划结束: 2026-10-21\n备注: 手建的\n---\n\n# AI德州扑克预赛\n', encoding='utf-8')
    before = mine.read_bytes()
    report = sync.sync()
    assert report['created'] == [] and report['skipped'] == ['AI德州扑克预赛（同名待办已在，不覆盖）']
    assert [p.name for p in folder.glob('*.md')] == ['AI德州扑克预赛.md'] and mine.read_bytes() == before


def test_no_vault_is_skipped(tmp_path):
    report = CalendarTodos(Today(None, None, None, clock=lambda: NOW), clock=lambda: NOW).sync()
    assert report['status'] == 'skipped' and report['created'] == []


def test_due_interval_gates_rerun(tmp_path):
    clock = {'now': NOW}
    sync = CalendarTodos(Today(Hub([event()]), None, tmp_path, clock=lambda: clock['now']), clock=lambda: clock['now'], interval=120)
    assert sync.due() is True
    sync.sync()
    assert sync.due() is False
    clock['now'] += 121
    assert sync.due() is True


def test_summary_is_one_line(tmp_path):
    sync, _, _, _ = make(tmp_path, [event()])
    report = sync.sync()
    assert sync.summary(report) == '当天日程 1 条 → 新建 1，更新 0，保持 0，跳过 0'
    blank = CalendarTodos(Today(None, None, None, clock=lambda: NOW), clock=lambda: NOW)
    assert blank.summary(blank.sync()) == '日程同步跳过：行动台没接上'


def test_frontmatter_stays_valid_yaml_even_with_colon_values(tmp_path):
    """Obsidian 按 YAML 读属性头：备注里出现 `: ` 必须加引号，否则整个属性头解析失败。"""
    import yaml
    sync, _, _, folder = make(tmp_path, [event('e1', '周会：复盘', '2026-10-10T11:00:00+08:00', '2026-10-10T12:00:00+08:00', calendar='Pi', location='3F: 大会议室')])
    assert sync.sync()['created'] == ['周会：复盘']
    path = folder / '周会：复盘.md'
    data = yaml.safe_load(path.read_text(encoding='utf-8').split('---')[1])
    assert data['flow'] == '任务' and data['状态'] == '待处理' and data['com_event_id'] == 'e1'
    assert str(data['计划结束']) == '2026-10-10'
    assert data['备注'].startswith('来源：日程') and '地点：3F: 大会议室' in data['备注']
    # 改期后再解析一次，仍然合法，而且引号不会让同步误判成用户改过的备注
    sync.today.hub.rows = [event('e1', '周会：复盘', '2026-10-11T17:30:00+08:00', '2026-10-11T18:30:00+08:00', calendar='Pi', location='3F: 大会议室')]
    assert sync.sync(day='2026-10-11')['updated'] == ['周会：复盘']
    data = yaml.safe_load(path.read_text(encoding='utf-8').split('---')[1])
    assert str(data['计划结束']) == '2026-10-11'
    assert data['备注'].startswith('来源：日程 · 日程 id：e1 · 开始：2026-10-11 17:30')
