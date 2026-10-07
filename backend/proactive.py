"""Scheduled proactive messages for the Com main conversation.

The scheduler only queues durable events; the model turn and the conversation
receipt stay in background_events/conversation. A source ID is the item version
plus the planned run time, so a restart never duplicates a sent message.
"""
import argparse
import json
import os
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo('Asia/Shanghai')
WINDOW_SECONDS = 1800

DEFAULT_ITEMS = [{'id':'morning-briefing','version':1,'at':'09:00','enabled':True,'title':'每日晨报','focus':'今天最重要的事、下一步和资料缺口。'}, {
    'id': 'evening-review',
    'version': 1,
    'at': '21:00',
    'enabled': True,
    'title': '晚间复盘',
    'focus': '回顾今天已经完成和仍未决的事、明天的第一件事；只讲真实来源，不确定就说不确定。',
}]


class Proactive:
    """Turns each due schedule item into one durable event per planned time."""

    def __init__(self, state, clock=time.time, items=None, window_seconds=WINDOW_SECONDS):
        self.path = Path(state) / 'proactive-config.json'
        self.clock = clock
        self.items = [dict(i) for i in (items if items else DEFAULT_ITEMS)]
        self.window_seconds = window_seconds

    def settings(self):
        try:
            saved = json.loads(self.path.read_text())
        except (OSError, ValueError):
            saved = {}
        if not isinstance(saved, dict):
            saved = {}
        items = saved.get('items')
        return {'paused': bool(saved.get('paused', False)), 'intensity':saved.get('intensity','balanced'),
                'quiet_start':saved.get('quiet_start',23),'quiet_end':saved.get('quiet_end',8),
                'items': items if isinstance(items, list) and items else [dict(i) for i in self.items]}

    def configure(self, changes):
        if set(changes) - {'paused', 'items','intensity','quiet_start','quiet_end'}:
            raise ValueError('不支持的主动性设置')
        if 'paused' in changes and type(changes['paused']) is not bool:
            raise ValueError('暂停状态必须是布尔值')
        if 'intensity' in changes and changes['intensity'] not in ('quiet','balanced','active'):raise ValueError('无效提醒强度')
        for key in ('quiet_start','quiet_end'):
            if key in changes and (type(changes[key]) is not int or not 0<=changes[key]<=23):raise ValueError('无效安静时间')
        if 'items' in changes:
            items=changes['items']
            if not isinstance(items,list) or not items or len(items)>12:raise ValueError('安排需要 1–12 个条目')
            seen=set()
            for item in items:
                if not isinstance(item,dict):raise ValueError('无效排期条目')
                ident=item.get('id')
                if not isinstance(ident,str) or not ident or len(ident)>80 or ident in seen:raise ValueError('排期标识必须唯一')
                seen.add(ident)
                try:h,m=map(int,item.get('at','').split(':'))
                except (ValueError,AttributeError):raise ValueError('时间格式应为 HH:MM')
                if not 0<=h<24 or not 0<=m<60:raise ValueError('无效排期时间')
                if type(item.get('enabled',True)) is not bool:raise ValueError('无效启用状态')
                if type(item.get('version',1)) is not int or item.get('version',1)<1:raise ValueError('无效安排版本')
                if 'days' in item and (not isinstance(item['days'],list) or not item['days'] or any(type(d) is not int or not 0<=d<=6 for d in item['days'])):raise ValueError('无效每周日期')
                for key in ('title','focus'):
                    if not isinstance(item.get(key,''),str) or len(item.get(key,''))>1000:raise ValueError('安排说明过长')
        config = self.settings()
        config.update(changes)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps(config, ensure_ascii=False, indent=2))
        tmp.chmod(0o600)
        tmp.replace(self.path)
        return config

    def due(self, now=None):
        config = self.settings()
        if config['paused']:
            return []
        moment = self.clock() if now is None else now
        local = datetime.fromtimestamp(moment, TZ)
        rows = []
        for item in config['items']:
            if not isinstance(item, dict) or not item.get('enabled', True):
                continue
            if item.get('days') and local.weekday() not in item['days']:continue
            if item.get('id')=='evening-review' and local.weekday()==6 and any(i.get('id')=='weekly-review' and i.get('enabled',True) for i in config['items']):continue
            at = str(item.get('at', '')).strip()
            try:
                hour, minute = (int(part) for part in at.split(':'))
            except ValueError:
                continue
            if not (0 <= hour < 24 and 0 <= minute < 60):
                continue
            planned = local.replace(hour=hour, minute=minute, second=0, microsecond=0)
            age = (local - planned).total_seconds()
            if not 0 <= age < self.window_seconds:
                continue
            rows.append({**item, 'at': at, 'planned_at': planned.isoformat(),
                         'source_id': 'cron:' + str(item.get('id')) + ':' + str(item.get('version', 1))
                                      + ':' + planned.strftime('%Y-%m-%dT%H:%M')})
        return rows

    def authorization(self, row):
        return {'origin_message_id': row['source_id'], 'origin_source': 'cron',
                'mandate': '用户已批准的长期个人安排权限',
                'item_id': row.get('id'), 'item_version': row.get('version', 1),
                'planned_at': row['planned_at']}

    def tick(self, events):
        count = 0
        for row in self.due():
            item = {k: v for k, v in row.items() if k not in ('source_id', 'planned_at')}
            count += int(events.enqueue('proactive:' + row['source_id'], 'proactive',
                                        {'item': item, 'authorization': self.authorization(row)}, priority=20))
        return count

    def fire(self, events, item_id, now=None):
        """Queue one item immediately; identity still carries version and planned time."""
        config = self.settings()
        item = next((i for i in config['items'] if isinstance(i, dict) and i.get('id') == item_id), None)
        if not item:
            raise ValueError('条目不存在')
        moment = self.clock() if now is None else now
        planned = datetime.fromtimestamp(moment, TZ).replace(second=0, microsecond=0)
        row = {**item, 'planned_at': planned.isoformat(),
               'source_id': 'cron:' + str(item.get('id')) + ':' + str(item.get('version', 1))
                            + ':' + planned.strftime('%Y-%m-%dT%H:%M')}
        payload = {'item': {k: v for k, v in row.items() if k not in ('source_id', 'planned_at')},
                   'authorization': self.authorization(row)}
        return int(events.enqueue('proactive:' + row['source_id'], 'proactive', payload, priority=20))


def main():
    parser = argparse.ArgumentParser(description='Com 主动消息排期')
    parser.add_argument('--status', action='store_true')
    parser.add_argument('--pause', action='store_true')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--at', metavar='HH:MM', help='设置 evening-review 的发送时间')
    parser.add_argument('--fire', metavar='ITEM_ID', help='立即排一条（用于验收）')
    args = parser.parse_args()
    state = Path(os.environ.get('WORKBENCH_STATE', str(Path.home() / '.session-workbench')))
    scheduler = Proactive(state)
    if args.pause or args.resume:
        scheduler.configure({'paused': args.pause})
    if args.at:
        config = scheduler.settings()
        for item in config['items']:
            if item.get('id') == 'evening-review':
                item['at'] = args.at
        scheduler.configure({'items': config['items']})
    if args.fire:
        from goals import GoalEvents
        print('queued:', scheduler.fire(GoalEvents(state), args.fire))
    print(json.dumps({'paused': scheduler.settings()['paused'],
                      'items': [{k: i.get(k) for k in ('id', 'at', 'enabled', 'title')}
                                for i in scheduler.settings()['items']]}, ensure_ascii=False))


if __name__ == '__main__':
    main()
