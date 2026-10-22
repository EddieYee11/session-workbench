"""日程即当天待办（Eddie 设定，2026-10-19）：把「当天」的日历日程逐条同步成行动台待办。

设定原文：所有日程上的事情都是当天的待办 —— Com 需要把当天的日程同步到他的待办里。

落地约定（改这里之前先读完整段）：
- 标题沿用日程标题；`计划结束` = 当天；`备注` 写明来源（`来源：日程 · 日程 id：… · 开始：…`，全角冒号，
  否则 Obsidian 按 YAML 读属性头会报错）；属性头记 `com_event_id`（来源日程 id），这就是幂等账本。
- 幂等：同一条日程（同一个 com_event_id）重复跑不新建；同名待办已经在就跳过，不覆盖、不重复；
  今天刚做完（`任务/已完成/` 里同名同 id）也不再重建。
- 改期：日程换了日期（含跨天改期），只更新对应待办的 `计划结束` 和 Com 自己写的来源备注行，不产生重复文件。
- 取消：日程从日历里消失时待办保留、不删除；Eddie 没明确要求，这里永不删文件，也不改标题/文件名。
- 只复用 Today 已经接好的日历链路（hub.matters → Today.events），不另起一套日历访问；读不到就不动。
"""
import re
import threading
import time
from datetime import datetime, timedelta

from today import SOURCE_MARK, TZ, _day, _front, todo_name

HOLIDAY_TITLE = re.compile(r'.{1,4}[节節]')   # 节日/节气标题不是待办（与 tomorrow_plan 一致）
DEFAULT_INTERVAL = 120


class CalendarTodos:
    """把当天的日程同步成行动台待办。同步是幂等的，可以在一天里反复跑（新加的日程会被补上）。"""

    def __init__(self, today, clock=time.time, interval=DEFAULT_INTERVAL):
        self.today, self.clock, self.interval = today, clock, interval
        self._last = 0.0
        self._lock = threading.Lock()

    def due(self):
        """距离上次同步超过 interval 秒才再跑，避免 15 秒的调度循环反复读 vault。"""
        return self.clock() - self._last >= self.interval

    def window(self, day=None):
        now = datetime.fromtimestamp(self.clock(), TZ)
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        target = _day(day) if day else None
        if target:
            start = start.replace(year=target.year, month=target.month, day=target.day)
        else:
            target = start.date()
        return target, start, start + timedelta(days=1)

    def events(self, start, end):
        """当天要处理的日程：排除节假日历（informational）和纯节日标题，其余全天日程也算。"""
        rows = []
        for event in (self.today.events(start, end) if self.today else []):
            title = str(event.get('title') or '').strip()
            if event.get('informational') or not title or HOLIDAY_TITLE.fullmatch(title):
                continue
            rows.append(event)
        return rows

    @staticmethod
    def source_note(event):
        """备注一律用全角「：」（ASCII 的 `: ` 会把 Obsidian 的属性头 YAML 读坏）。"""
        when = ('全天' if event.get('all_day')
                else datetime.fromtimestamp(float(event['start']), TZ).strftime('%Y-%m-%d %H:%M'))
        parts = ['日程 id：' + str(event.get('id') or ''), '开始：' + when]
        if event.get('calendar'):
            parts.append('日历：' + str(event['calendar']))
        if event.get('location'):
            parts.append('地点：' + str(event['location']))
        return SOURCE_MARK + ' · ' + ' · '.join(parts)

    def sync(self, day=None):
        """同步 `day`（默认今天）的日程 → 行动台待办。返回逐条结果，不抛异常给调度循环。"""
        with self._lock:
            self._last = self.clock()
        target, start, end = self.window(day)
        report = {'status': 'completed', 'day': target.isoformat(), 'events': 0,
                  'created': [], 'updated': [], 'unchanged': [], 'skipped': []}
        if not self.today or not self.today.vault:
            report['status'] = 'skipped'
            report['skipped'].append('行动台没接上')
            return report
        vault = self.today.vault
        index = self.today.todo_index()
        by_name = {row['name']: row for row in index}
        by_event = {row['event_id']: row for row in index if row['event_id']}
        events = self.events(start, end)
        report['events'] = len(events)
        for event in events:
            ident, title = str(event.get('id') or ''), str(event.get('title') or '').strip()
            name = todo_name(title)
            if not ident or not name:
                report['skipped'].append(name or '无名日程')
                continue
            note = self.source_note(event)
            found = by_event.get(ident)
            if found and found['name'] != name:
                # 日程改名：不自动改文件名（Obsidian 里已有反向链接），只更新原待办、绝不新建第二个。
                self._resync(report, found, target, note, name, suffix='（日程改名，保留原待办）')
                continue
            if found:
                self._resync(report, found, target, note, name)
                continue
            if name in by_name:
                report['skipped'].append(name + '（同名待办已在，不覆盖）')
                continue
            done = vault / '任务' / '已完成' / (name + '.md')
            if done.is_file() and _front(done).get('com_event_id') == ident:
                report['skipped'].append(name + '（已经做完，不再重建）')
                continue
            body = ['由 Com 从日程同步而来（设定：日程上的事情就是当天的待办）。', note]
            if event.get('notes'):
                body.append(str(event['notes']))
            made = self.today.todo_create(name, target, note=note, body='\n\n'.join(body), event_id=ident,
                                          progress='由 Com 从日程同步（日程 id: ' + ident + '）')
            if made['status'] == 'exists':   # 建之前刚好有人手建了同名文件：那就不动它
                report['skipped'].append(name + '（同名待办已在，不覆盖）')
            else:
                report['created'].append(name)
                by_name[name] = {'name': name, 'event_id': ident}
                by_event[ident] = by_name[name]
        return report

    def _resync(self, report, found, target, note, name, suffix=''):
        try:
            row = self.today.todo_sync_event(found['path'], target, note)
        except ValueError as error:          # 已经不在待处理（被勾掉 / 挪走）：不追，下次按同名跳过
            report['skipped'].append(name + '（' + str(error) + '）')
            return
        (report['updated'] if row['changed'] else report['unchanged']).append(name + suffix)

    @staticmethod
    def summary(report):
        """一句话概括，给晨报/日志用。"""
        if report.get('status') != 'completed':
            return '日程同步跳过：' + '；'.join(report.get('skipped') or ['没有行动台'])
        return ('当天日程 ' + str(report['events']) + ' 条 → 新建 ' + str(len(report['created']))
                + '，更新 ' + str(len(report['updated'])) + '，保持 ' + str(len(report['unchanged']))
                + '，跳过 ' + str(len(report['skipped'])))
