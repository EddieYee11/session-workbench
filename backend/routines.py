"""「已排程」：把 Com 所有主动行为列成一张表，并能逐项或整体暂停。

只做汇总与转发：主动消息走 Proactive.configure，Hermes 定时任务走其 /pause /resume；
读不到或没有暂停入口的项一律 controllable=false，不假装可控。
"""
import sqlite3
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from proactive import Proactive
from tomorrow_plan import AT as TOMORROW_AT

TZ = ZoneInfo('Asia/Shanghai')
WEEKDAYS = '一二三四五六日'
GROUP_PROACTIVE, GROUP_NUDGE, GROUP_STEPS, GROUP_FIXED, GROUP_CRON = '主动消息', '临近提醒', '下一步整理', '固定任务', 'Hermes 定时'


class NotControllable(Exception):
    pass


class UnknownRoutine(Exception):
    pass


def _iso(moment):
    return moment.isoformat() if moment else None


def next_at(item, now_ts):
    """item 的下一个触发时间（本地时区），最多向后找 8 天。"""
    try:
        hour, minute = (int(p) for p in str(item.get('at', '')).split(':'))
    except ValueError:
        return None
    now = datetime.fromtimestamp(now_ts, TZ)
    for offset in range(8):
        planned = (now + timedelta(days=offset)).replace(hour=hour, minute=minute, second=0, microsecond=0)
        if planned < now:
            continue
        if item.get('days') and planned.weekday() not in item['days']:
            continue
        return planned
    return None


def _days_text(days):
    return '每周' + '、'.join(WEEKDAYS[d] for d in days) if days else '每天'


def cron_label(expr):
    """把常见 cron 写成人话；认不出的原样返回。"""
    parts = str(expr).split()
    if len(parts) != 5 or parts[2:] != ['*', '*', '*']:
        return expr
    minute, hour = parts[:2]
    if hour == '*' and minute[:2] == '*/':
        return '每 ' + minute[2:] + ' 分钟'
    if hour == '*':
        count = len(minute.split(','))
        return '每小时' if count == 1 else '每 ' + str(60 // count) + ' 分钟'
    if hour.isdigit() and minute.isdigit():
        return '每天 %02d:%02d' % (int(hour), int(minute))
    return expr


class Routines:
    def __init__(self, state, proactive, hermes=None, next_steps_path=None, clock=time.time):
        self.proactive, self.hermes, self.clock = proactive, hermes, clock
        self.next_steps_path = next_steps_path

    def _row(self, ident, group, title, trigger, controllable, enabled=True, note='', next_run_at=None, last_run_at=None, last_status=None):
        return {'id': ident, 'group': group, 'title': title, 'trigger': trigger, 'next_run_at': next_run_at,
                'last_run_at': last_run_at, 'last_status': last_status, 'enabled': enabled,
                'controllable': controllable, 'note': note}

    def _proactive_rows(self, config, now):
        rows = []
        for item in config['items']:
            if not isinstance(item, dict) or not item.get('id'):
                continue
            on = bool(item.get('enabled', True))
            when = next_at(item, now) if on and not config['paused'] else None
            note = '全部暂停中' if config['paused'] else ''
            rows.append(self._row('proactive:' + str(item['id']), GROUP_PROACTIVE, str(item.get('title') or item['id']),
                                  _days_text(item.get('days')) + ' ' + str(item.get('at', '')), True, on, note, _iso(when)))
        return rows

    def _steps_row(self, now):
        last_at = last_status = None
        note = '每小时一轮（08–23 点），无独立暂停入口'
        try:
            db = sqlite3.connect(str(self.next_steps_path), timeout=5)
            try:
                row = db.execute('SELECT at, source, error FROM runs ORDER BY id DESC LIMIT 1').fetchone()
            finally:
                db.close()
            if row:
                last_at = _iso(datetime.fromtimestamp(row[0], TZ))
                last_status = ('失败：' + str(row[2])[:120]) if row[2] else (row[1] or 'ok')
        except (sqlite3.Error, TypeError, ValueError):
            note += '；读不到上次运行记录'
        return self._row('next-steps', GROUP_STEPS, '下一步整理', '每小时（08–23 点）', False, True, note,
                         None, last_at, last_status)

    def _fixed_rows(self, now):
        hour, minute = TOMORROW_AT
        plan = next_at({'at': '%02d:%02d' % (hour, minute)}, now)
        weekly = None
        local = datetime.fromtimestamp(now, TZ)
        for offset in range(8):
            day = (local + timedelta(days=offset)).replace(hour=13, minute=30, second=0, microsecond=0)
            if day.weekday() == 3 and day >= local:
                weekly = day
                break
        return [
            self._row('tomorrow-plan', GROUP_FIXED, '明天计划', '每天 %02d:%02d' % (hour, minute), False, True, '只读，无暂停入口', _iso(plan)),
            self._row('weekly-report', GROUP_FIXED, '周报起草', '每周四 13:30', False, True, '只读，无暂停入口；一周只起草一次', _iso(weekly)),
        ]

    async def _jobs(self):
        data = await self.hermes.request('GET', '/api/jobs')
        jobs = data.get('jobs') if isinstance(data, dict) else None
        if not isinstance(jobs, list):
            raise RuntimeError('hermes_invalid_response')
        return [j for j in jobs if isinstance(j, dict) and str(j.get('name', '')).startswith('Com ·')]

    async def _cron_rows(self):
        if self.hermes is None:
            return [self._row('cron:_unavailable', GROUP_CRON, 'Hermes 定时任务', '', False, False, '未接入 Hermes，读不到')]
        try:
            jobs = await self._jobs()
        except Exception as error:
            return [self._row('cron:_unavailable', GROUP_CRON, 'Hermes 定时任务', '', False, False, '读不到 Hermes（' + str(error)[:60] + '）')]
        rows = []
        for job in jobs:
            schedule = cron_label(job.get('schedule_display') or (job.get('schedule') or {}).get('display') or '')
            status = job.get('last_status')
            if job.get('last_error'):
                status = '失败：' + str(job['last_error'])[:120]
            rows.append(self._row('cron:' + str(job.get('id')), GROUP_CRON, str(job['name']).split('·', 1)[1].strip() or job['name'],
                                  str(schedule), True, bool(job.get('enabled', True)) and job.get('state') != 'paused', '',
                                  job.get('next_run_at'), job.get('last_run_at'), status))
        return rows

    async def list(self):
        now = self.clock()
        config = self.proactive.settings()
        items = self._proactive_rows(config, now)
        items.append(self._row('nudges', GROUP_NUDGE, '日程前 15 分钟、提醒到期、订阅到期', '到点触发', False, not config['paused'], '跟随全部暂停'))
        items.append(self._steps_row(now))
        items.extend(self._fixed_rows(now))
        items.extend(await self._cron_rows())
        return {'items': items, 'paused': config['paused']}

    async def act(self, ident, action):
        if action not in ('pause', 'resume'):
            raise ValueError('action 只能是 pause 或 resume')
        pause = action == 'pause'
        if ident == '_all':
            self.proactive.configure({'paused': pause})
        elif ident.startswith('proactive:'):
            key = ident.split(':', 1)[1]
            items = self.proactive.settings()['items']
            hit = next((i for i in items if isinstance(i, dict) and i.get('id') == key), None)
            if hit is None:
                raise UnknownRoutine(ident)
            hit['enabled'] = not pause
            self.proactive.configure({'items': items})
        elif ident.startswith('cron:'):
            key = ident.split(':', 1)[1]
            if self.hermes is None:
                raise RuntimeError('hermes_unavailable')
            if key not in {str(j.get('id')) for j in await self._jobs()}:
                raise UnknownRoutine(ident)
            await self.hermes.request('POST', '/api/jobs/' + key + ('/pause' if pause else '/resume'))
        elif ident in ('nudges', 'next-steps', 'tomorrow-plan', 'weekly-report'):
            raise NotControllable(ident)
        else:
            raise UnknownRoutine(ident)
        return await self.list()
