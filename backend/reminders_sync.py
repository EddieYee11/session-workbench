"""待办 → 苹果提醒事项（Eddie 设定，2026-10-22）：Com 行动台里的待办同步进 iCloud 提醒事项的「Com 待办」列表，
iPhone / iPad / Mac / Watch 都能看到。

约定（改这里之前先读完整段）：
- 单向：行动台 `任务/待处理/` → 提醒事项。提醒事项里改的内容不回写行动台。
- 对账式：每轮把「待处理里的待办」和「列表里的提醒」按标题（= 文件名，唯一）比一遍，缺的建、日期变了改、
  待办已进 `任务/已完成/` 的把提醒勾掉。这样 app、Obsidian、日程、明天建议等所有写入口都不用各自挂钩。
- 日程来源的待办（`com_event_id`）不同步：它们本来就在日历里，再进提醒事项只是重复。
- 永不删提醒：待办被挪走/改名只是不再更新，不会动 Eddie 在提醒事项里留的东西。
- 日期用「全天到期日」（`allday due date`）；没有计划结束的待办不设日期。
- 只在 macOS 上有意义（osascript）；读不到提醒事项（权限/iCloud 卡住）就整轮放弃，下一轮再来，不抛异常。
"""
import subprocess
import threading
import time

from today import _day, _front

LIST_NAME = 'Com 待办'
ACCOUNT = 'iCloud'
DEFAULT_INTERVAL = 60
OSASCRIPT_TIMEOUT = 60


def _q(text):
    """AppleScript 字符串字面量。"""
    return '"' + str(text).replace('\\', '\\\\').replace('"', '\\"') + '"'


def _date_expr(day):
    """与区域设置无关的日期：先把日置 1 再设年月日，避免 31 日溢出。"""
    return ('(my do_date('+ str(day.year) + ', ' + str(day.month) + ', ' + str(day.day) + '))')


PRELUDE = '''
on do_date(y, m, d)
    set t to current date
    set day of t to 1
    set year of t to y
    set month of t to m
    set day of t to d
    set time of t to 0
    return t
end do_date
'''

LIST_SCRIPT = PRELUDE + '''
tell application "Reminders"
    if not (exists list %(list)s) then make new list at account %(account)s with properties {name:%(list)s}
    set out to ""
    repeat with r in (reminders of list %(list)s)
        set d to ""
        set a to allday due date of r
        if a is not missing value then set d to ((year of a) as string) & "-" & text -2 thru -1 of ("0" & ((month of a) as integer)) & "-" & text -2 thru -1 of ("0" & (day of a))
        set out to out & (name of r) & tab & (completed of r) & tab & d & linefeed
    end repeat
    return out
end tell
'''


class RemindersSync:
    """行动台待办 → 提醒事项「Com 待办」列表。"""

    def __init__(self, today, clock=time.time, interval=DEFAULT_INTERVAL, run=None):
        self.today, self.clock, self.interval = today, clock, interval
        self._run = run or self._osascript
        self._last = 0.0
        self._lock = threading.Lock()

    def due(self):
        return self.clock() - self._last >= self.interval

    @staticmethod
    def _osascript(script):
        done = subprocess.run(['/usr/bin/osascript', '-e', script], capture_output=True, text=True, timeout=OSASCRIPT_TIMEOUT)
        if done.returncode:
            raise RuntimeError((done.stderr or done.stdout).strip()[:300] or 'osascript 失败')
        return done.stdout

    def _listing(self):
        """列表里现有的提醒：{标题: (是否完成, 到期日或 None)}。"""
        raw = self._run(LIST_SCRIPT % {'list': _q(LIST_NAME), 'account': _q(ACCOUNT)})
        rows = {}
        for line in raw.splitlines():
            name, _, rest = line.partition('\t')
            done, _, due = rest.partition('\t')
            if name:
                rows[name] = (done.strip() == 'true', _day(due) if due.strip() else None)
        return rows

    def _pending(self):
        """要同步的待办：待处理、非日程来源。标题 = 文件名，备注 = 下一步 / 备注。"""
        rows = []
        for row in self.today.todo_index():
            if row.get('event_id'):
                continue
            front = _front(self.today.vault / row['path'])
            note = ' · '.join(x for x in (front.get('下一步', ''), front.get('备注', '')) if x)
            rows.append({'name': row['name'], 'due': _day(row['due']) if row.get('due') else None, 'note': note,
                         'path': row['path']})
        return rows

    def _finished(self, name):
        """待办已经进了 `任务/已完成/`（做完才会在那里；被挪去别处不算）。"""
        return bool(self.today.vault) and (self.today.vault / '任务' / '已完成' / (name + '.md')).is_file()

    def sync(self):
        """对账一轮。返回 {'status','created','updated','completed','skipped'}，失败只记 status，不抛。"""
        with self._lock:
            self._last = self.clock()
        report = {'status': 'completed', 'created': [], 'updated': [], 'completed': [], 'skipped': []}
        if not self.today or not self.today.vault:
            report.update(status='skipped', skipped=['行动台没接上'])
            return report
        try:
            have = self._listing()
        except Exception as error:   # 权限 / iCloud 卡住 / 超时：整轮放弃，下一轮再来
            report.update(status='failed', skipped=[str(error)[:200]])
            return report
        pending = self._pending()
        names = {row['name'] for row in pending}
        ops = []
        for row in pending:
            name, due = row['name'], row['due']
            if name not in have:
                ops.append(self._create(row))
                report['created'].append(name)
                continue
            done, current = have[name]
            if done:
                continue   # 他在提醒事项里勾掉了：不重新打开（单向，也不替他决定）
            if due != current:
                ops.append(self._set_due(name, due))
                report['updated'].append(name)
        for name, (done, _) in have.items():
            if not done and name not in names and self._finished(name):
                ops.append('set completed of (first reminder of list %s whose name is %s) to true' % (_q(LIST_NAME), _q(name)))
                report['completed'].append(name)
        if ops:
            try:
                self._run(PRELUDE + 'tell application "Reminders"\n' + '\n'.join(ops) + '\nend tell\n')
            except Exception as error:
                report.update(status='failed', skipped=[str(error)[:200]])
        return report

    @staticmethod
    def _create(row):
        props = ['name:' + _q(row['name'])]
        if row['note']:
            props.append('body:' + _q(row['note'][:500]))
        text = 'make new reminder at list %s with properties {%s}' % (_q(LIST_NAME), ', '.join(props))
        if row['due']:
            text = ('set r to ' + text + '\nset allday due date of r to ' + _date_expr(row['due']))
        return text

    @staticmethod
    def _set_due(name, due):
        target = 'first reminder of list %s whose name is %s' % (_q(LIST_NAME), _q(name))
        if due:
            return 'set allday due date of (%s) to %s' % (target, _date_expr(due))
        return 'set allday due date of (%s) to missing value' % target

    @staticmethod
    def summary(report):
        if report.get('status') != 'completed':
            return '提醒事项同步未完成：' + '；'.join(report.get('skipped') or ['未知原因'])
        return ('待办 → 提醒事项：新建 %d，改期 %d，勾掉 %d' % (len(report['created']), len(report['updated']), len(report['completed'])))
