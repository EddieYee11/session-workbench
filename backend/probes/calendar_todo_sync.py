"""日程 → 当天待办（Eddie 设定）：可控时钟真实演示 + 真实日历链路只读预览。

跑法（用生产 venv，但不碰生产状态）：
  /Users/eddiegao/.session-workbench/venv/bin/python backend/probes/calendar_todo_sync.py

演示 1：固定时钟 2026-10-10 08:50 + 临时 vault，真实写文件：首跑建、重复跑不动、改期只改「计划结束」、取消保留。
演示 2：真实 personal_hub 的日历数据 + 真实 vault，只读预览今天会同步出什么（不写一个字节）。
"""
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from calendar_todos import CalendarTodos
from today import TZ, Today

CLOCK = datetime(2026, 10, 10, 8, 50, tzinfo=TZ).timestamp()   # 可控日期源：2026-10-10 早上


class Hub:
    def __init__(self, rows=()):
        self.rows = list(rows)

    def matters(self):
        return list(self.rows)


def event(ident, title, start, end, calendar='', location=''):
    return {'id': ident, 'source': 'apple_calendar', 'title': title, 'feedback': {},
            'facts': {'start': start, 'end': end, 'calendar': calendar, 'location': location}}


def shown(path, vault):
    print('   文件 ' + str(path.relative_to(vault)) + '：')
    for line in path.read_text(encoding='utf-8').split('## 进展')[0].strip().splitlines():
        print('     ' + line)


def demo_controlled():
    print('== 演示 1：可控时钟 2026-10-10 08:50，当天日程 → 行动台待办（临时 vault，真实写文件）')
    import tempfile
    vault = Path(tempfile.mkdtemp(prefix='calendar-todos-demo-')) / 'obsidian'
    (vault / '任务' / '待处理').mkdir(parents=True)
    (vault / '任务' / '已完成').mkdir(parents=True)
    hub = Hub([event('apple_calendar:ev-1', '周会', '2026-10-10T11:00:00+08:00', '2026-10-10T12:00:00+08:00', 'Pi', '3F 会议室'),
               event('apple_calendar:ev-2', '去机场接 Judy', '2026-10-10T15:00:00+08:00', '2026-10-10T16:00:00+08:00'),
               event('apple_calendar:ev-3', '国庆节', '2026-10-10', '2026-10-11', '中国大陆节假日')])
    today = Today(hub, None, vault, clock=lambda: CLOCK)
    sync = CalendarTodos(today, clock=lambda: CLOCK)
    print('   vault(临时): ' + str(vault))

    first = sync.sync()
    print('  1) 首跑  ' + sync.summary(first))
    for name in first['created']:
        shown(vault / '任务' / '待处理' / (name + '.md'), vault)
    snap = today.snapshot()
    print('  今天页 todos: ' + str([t['title'] for t in snap['todos']]))

    before = {p.name: p.stat().st_mtime_ns for p in (vault / '任务' / '待处理').glob('*.md')}
    again = sync.sync()
    after = {p.name: p.stat().st_mtime_ns for p in (vault / '任务' / '待处理').glob('*.md')}
    print('  2) 重复跑 ' + sync.summary(again) + '，文件数 ' + str(len(after))
          + '，mtime 全未变: ' + str(before == after) + '，新建 ' + str(again['created']))

    hub.rows = [event('apple_calendar:ev-1', '周会', '2026-10-11T17:30:00+08:00', '2026-10-11T18:30:00+08:00', 'Pi'),
                event('apple_calendar:ev-2', '去机场接 Judy', '2026-10-10T15:00:00+08:00', '2026-10-10T16:00:00+08:00')]
    moved = sync.sync(day='2026-10-11')
    print('  3) 日程改到 10-11 17:30，同步 10-11 那天：' + sync.summary(moved) + '，新建 ' + str(moved['created']))
    shown(vault / '任务' / '待处理' / '周会.md', vault)
    print('   待处理文件数（应仍为 2）: ' + str(len(list((vault / '任务' / '待处理').glob('*.md')))))

    hub.rows = []
    kept = sync.sync()
    print('  4) 日程全部取消后：' + sync.summary(kept) + '，文件仍在: '
          + str(sorted(p.stem for p in (vault / '任务' / '待处理').glob('*.md'))))
    print()
    return vault


def demo_real_readonly():
    print('== 演示 2：真实日历链路 + 真实 vault，只读预览（不写任何文件）')
    from personal_hub import PersonalHub
    state = Path.home() / '.session-workbench'
    vault = Path.home() / 'Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian'
    real = CalendarTodos(Today(PersonalHub(state, Path.home()), None, vault, clock=time.time), clock=time.time)
    target, start, end = real.window()
    print('  真实日期: ' + target.isoformat() + '，真实 vault: ' + str(vault))
    events = real.events(start, end)
    print('  今天真实日程 ' + str(len(events)) + ' 条（已排除节假日/节日）：')
    for e in events:
        print('   - ' + str(e['title']) + ' · ' + ('全天' if e['all_day'] else datetime.fromtimestamp(e['start'], TZ).strftime('%H:%M'))
              + ' · id ' + str(e['id']))
    index = real.today.todo_index()
    synced = {row['event_id'] for row in index if row['event_id']}
    names = {row['name'] for row in index}
    from today import todo_name
    print('  行动台待处理 ' + str(len(index)) + ' 条（状态就是待处理的），其中来自日程 ' + str(len(synced)) + ' 条')
    for e in events:
        name = todo_name(e['title'])
        # 与 sync 一致：先看 com_event_id，再看同名文件（不管它是待处理还是已完成），都没有才会新建
        if str(e['id']) in synced:
            state_ = '已同步'
        elif name in names or (vault / '任务' / '待处理' / (name + '.md')).is_file() or (vault / '任务' / '已完成' / (name + '.md')).is_file():
            state_ = '同名文件已在(会跳过)'
        else:
            state_ = '会新建'
            names.add(name)      # 同一轮里第二条同名日程同样只建一条
        print('   → ' + name + '：' + state_)
    print('  以上只读，vault 未改动。')


if __name__ == '__main__':
    real_vault = demo_controlled()
    demo_real_readonly()
    print('\n演示用临时 vault（可删）: ' + str(real_vault))
