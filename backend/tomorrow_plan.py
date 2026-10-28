"""明天建议（2026-10-17）：每晚 21:30 把「还没处理的下一步 + 明天到期/已过期的待办 + 明天日程 + 进行中的航程」收成一张清单，推送给 Eddie。

他勾选后一键落到行动台：下一步 → 新建明天的待办（带 com_next_id，下一步那边随即去重）；过期待办 → 改期到明天；
明天到期的待办本来就在，不动。日程和航程只做参考，不可勾选。规则排序，不调模型：下一步本身已经是模型整理过的。
"""
import hashlib, json, re, sqlite3, time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo('Asia/Shanghai')
AT = (21, 30)
MAX_OVERDUE_DAYS = 3   # 过期超过三天的待办不再往明天带：滚了这么久没做，要么早已作废、要么他不想做，放进清单只会让建议失准
CARRY_LIMIT = 2        # 同一条在之前两份没被落地的明天建议里都出现过，说明他看过两次都没理，不再提
CASE_FRESH = 2 * 86400  # 航程两天没动静就不算「进行中」
HOLIDAY_TODO = re.compile(r'.{1,4}[节節]|.*[补補]假|.*放假')


class TomorrowPlan:
    def __init__(self, state, next_steps, today, cases=None, conversation=None, clock=time.time):
        self.path = Path(state) / 'tomorrow-plan.sqlite'
        self.next_steps, self.today, self.cases, self.conversation, self.clock = next_steps, today, cases, conversation, clock
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS plans(day TEXT PRIMARY KEY, data TEXT NOT NULL, state TEXT NOT NULL, created_at REAL, updated_at REAL)')
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def _days(self):
        now = datetime.fromtimestamp(self.clock(), TZ)
        start = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
        return now, start, start + timedelta(days=1)

    def due(self):
        now, start, _ = self._days()
        if (now.hour, now.minute) < AT:
            return False
        with self.db() as db:
            return not db.execute('SELECT 1 FROM plans WHERE day=?', (start.date().isoformat(),)).fetchone()

    def _carried(self, day):
        """之前（早于 day）每份没落地的明天建议里出现过的条目 id → 次数。"""
        count = {}
        with self.db() as db:
            rows = db.execute('SELECT data FROM plans WHERE day<?', (day.isoformat(),)).fetchall()
        for row in rows:
            plan = json.loads(row['data'])
            applied = {r.get('id') for r in plan.get('applied', [])}
            for item in plan.get('items', []):
                if item.get('checkable') and item['id'] not in applied:
                    count[item['id']] = count.get(item['id'], 0) + 1
        return count

    def build(self):
        now, start, end = self._days()
        day = start.date()
        items = []
        carried = self._carried(day)
        for t in self.today.todo_index() if self.today else []:
            try:
                due = datetime.strptime(t['due'][:10], '%Y-%m-%d').date() if t['due'] else None
            except ValueError:
                due = None
            if due and due <= day:
                overdue = due < now.date()
                if HOLIDAY_TODO.fullmatch(t['name']) or (overdue and ((now.date() - due).days > MAX_OVERDUE_DAYS or carried.get('todo:' + t['path'], 0) >= CARRY_LIMIT)):
                    continue
                items.append({'id': 'todo:' + t['path'], 'kind': 'todo', 'title': t['name'], 'checked': not overdue, 'checkable': overdue,
                              'why': ('已过期（' + t['due'] + '），勾上改到明天' if overdue else '明天到期' if due == day else '今天到期，还没做'),
                              'path': t['path'], 'overdue': overdue})
        order = {'now': 0, 'today': 1, 'week': 2}
        pending = sorted(self.next_steps.pending() if self.next_steps else [], key=lambda i: (order.get(i.get('urgency'), 1), -i.get('score', 0)))
        for n in pending[:6]:
            if n.get('in_todo') or carried.get('next:' + n['id'], 0) >= CARRY_LIMIT:
                continue  # 已经在待办里，上面那组会带出来；提过两次都没理的不再提
            items.append({'id': 'next:' + n['id'], 'kind': 'next', 'title': n['title'], 'why': n.get('why', ''), 'checked': n.get('urgency') in ('now', 'today'),
                          'checkable': True, 'next_id': n['id']})
        events = []
        if self.today and getattr(self.today, 'hub', None):
            try:
                events = self.today.events(start, end)
            except Exception:
                events = []
        seen = set()  # 手机日历同一日程常有多份、节日（重阳节/重陽節）来自多个节假日历且不带日历名
        events = [e for e in events if not e.get('informational') and not re.fullmatch(r'.{1,4}[节節]', e.get('title', ''))
                  and not (e.get('title') in seen or seen.add(e.get('title')))]
        for e in events[:8]:
            at = datetime.fromtimestamp(e['start'], TZ).strftime('%H:%M') if isinstance(e.get('start'), (int, float)) and not e.get('all_day') else '全天'
            items.append({'id': 'event:' + str(e.get('id', e.get('title'))), 'kind': 'event', 'title': e.get('title', '日程'), 'why': at, 'checked': False, 'checkable': False})
        if self.cases:
            for c in self.cases.list()['items']:
                if c['state'] in ('running', 'queued', 'waiting', 'attention') and self.clock() - c.get('updated_at', 0) < CASE_FRESH:
                    items.append({'id': 'case:' + c['id'], 'kind': 'case', 'title': c['title'], 'why': c['state_label'] + (' · ' + c['now'] if c['now'] else ''),
                                  'checked': False, 'checkable': False, 'case_id': c['id']})
        todo_n = sum(1 for i in items if i['kind'] in ('todo', 'next') and i['checked'])
        event_n = sum(1 for i in items if i['kind'] == 'event')
        headline = f"明天 {event_n} 个日程，建议做 {todo_n} 件事" if items else '明天没什么要紧的，早点休息'
        return {'day': day.isoformat(), 'weekday': '一二三四五六日'[day.weekday()], 'headline': headline, 'items': items, 'generated_at': self.clock()}

    def generate(self, push=True):
        plan = self.build()
        with self.db() as db:
            old = db.execute('SELECT state FROM plans WHERE day=?', (plan['day'],)).fetchone()
            if old and old['state'] == 'applied':
                return self.latest()
            db.execute('INSERT OR REPLACE INTO plans VALUES (?,?,?,?,?)', (plan['day'], json.dumps(plan, ensure_ascii=False), 'open', self.clock(), self.clock()))
        if push and self.conversation and plan['items']:
            # 推送载体同任务回执（Bark 只推 task-result: 主动消息）；点开跳到明天建议卡片
            self.conversation.task_receipt('plan:' + plan['day'], '🗓️ 明天建议：' + plan['headline'] + '。点开勾一下，一键放进待办。')
        return {**plan, 'state': 'open'}

    def latest(self):
        with self.db() as db:
            row = db.execute('SELECT * FROM plans ORDER BY day DESC LIMIT 1').fetchone()
        if not row:
            return None
        plan = json.loads(row['data'])
        if row['state'] == 'open':
            plan = self._alive(plan)
        return {**plan, 'state': row['state'], 'applied': plan.get('applied', [])}

    def _alive(self, plan):
        """21:30 生成的清单是快照：之后做完、划掉、改期的，读的时候就不再露出来。"""
        todos = {t['path'] for t in self.today.todo_index()} if self.today else None
        pending = {n['id'] for n in self.next_steps.pending()} if self.next_steps else None
        def alive(i):
            if i['kind'] == 'todo' and todos is not None:
                return i['path'] in todos
            if i['kind'] == 'next' and pending is not None:
                return i['next_id'] in pending
            return True
        items = [{**i, 'checked': False} if i['kind'] == 'todo' and i.get('overdue') else i for i in plan['items'] if alive(i)]  # 过期的默认不勾
        todo_n = sum(1 for i in items if i['kind'] in ('todo', 'next') and i['checked'])
        event_n = sum(1 for i in items if i['kind'] == 'event')
        return {**plan, 'items': items, 'headline': f'明天 {event_n} 个日程，建议做 {todo_n} 件事' if items else '明天没什么要紧的，早点休息'}

    def apply(self, day, selected):
        """勾选的落到行动台；返回每条的结果。同一天只落一次（再点返回上次结果）。"""
        with self.db() as db:
            row = db.execute('SELECT * FROM plans WHERE day=?', (day,)).fetchone()
        if not row:
            raise ValueError('这份明天建议已经不在了')
        plan = json.loads(row['data'])
        if row['state'] == 'applied':
            return {'status': 'completed', 'day': day, 'results': plan.get('applied', []), 'repeat': True}
        chosen = set(selected or [])
        results = []
        for item in plan['items']:
            if item['id'] not in chosen or not item.get('checkable'):
                continue
            try:
                if item['kind'] == 'next':
                    n = self.next_steps.get(item['next_id'])
                    sigs = [s for e in n.get('evidence', []) if (s := self._sig(e))]
                    made = self.today.todo_create(n['title'], day, next_step=n.get('prompt', '')[:200], note=n.get('why', ''),
                                                  body=n.get('prompt', ''), next_id=n['id'], sigs=sigs)
                    self.next_steps.act(n['id'], 'todo', todo={'path': made['path'], 'due': day})
                    results.append({'id': item['id'], 'status': made['status'], 'path': made['path']})
                elif item['kind'] == 'todo' and item.get('overdue'):
                    moved = self.today.todo_postpone(item['path'], day)
                    results.append({'id': item['id'], 'status': 'postponed', 'path': item['path'], 'due': moved['due']})
            except ValueError as error:
                results.append({'id': item['id'], 'status': 'failed', 'error': str(error)})
        plan['applied'] = results
        with self.db() as db:
            db.execute("UPDATE plans SET data=?, state='applied', updated_at=? WHERE day=?", (json.dumps(plan, ensure_ascii=False), self.clock(), day))
        return {'status': 'completed', 'day': day, 'results': results}

    @staticmethod
    def _sig(e):
        from next_steps import _sig
        return _sig(e.get('ref', ''), e)
