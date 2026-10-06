"""Native business operations for Hermes; shared accounts, durable receipts, no Pi model."""
import asyncio
import hashlib
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timedelta
from decimal import Decimal
from pathlib import Path
from zoneinfo import ZoneInfo
import httpx

TZ = ZoneInfo('Asia/Shanghai')


def operation_receipts(state, request_id):
    path = Path(state) / 'business-operations.sqlite'
    if not path.exists(): return []
    with sqlite3.connect(path) as db:
        rows = db.execute('SELECT tool,status,result FROM operations WHERE origin_request=?', (request_id,)).fetchall()
    return [{'tool': tool, 'status': status, **json.loads(result or '{}')} for tool, status, result in rows]


class BusinessTools:
    def __init__(self, state, authorizer=None, home=None):
        self.state, self.home = Path(state), Path(home or Path.home())
        self.authorizer = authorizer
        self.path = self.state / 'business-operations.sqlite'
        self.lock = asyncio.Lock()
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,origin_request TEXT,tool TEXT,fingerprint TEXT,status TEXT,result TEXT)')
        self.path.chmod(0o600)

    async def call(self, tool, args, context):
        if tool not in ('bookkeeping', 'bookkeeping_search', 'calendar_event', 'remind', 'collect'): raise ValueError('Unknown business tool')
        args = dict(args)
        action = args.get('action', 'search' if tool == 'bookkeeping_search' else '')
        read = action in ('search', 'recent', 'summary', 'list', 'list_calendars', 'get')
        if read:
            if self.authorizer:self.authorizer({'tool':tool,'args':args},context)
            return await self.execute(tool,args)
        origin = context.get('origin_request_id')
        if not origin: raise ValueError('Missing real operation source')
        fingerprint = hashlib.sha256(json.dumps([tool, args], sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        ident = hashlib.sha256((origin + ':' + fingerprint).encode()).hexdigest()
        async with self.lock:
            with sqlite3.connect(self.path) as db:
                old = db.execute('SELECT status,result FROM operations WHERE id=?', (ident,)).fetchone()
                if old:
                    if old[0] != 'verified': raise ValueError('Operation outcome uncertain; read the original record before retrying')
                    return {**json.loads(old[1]), 'operation_id':ident, 'duplicate': True}
                if self.authorizer:self.authorizer({'tool':tool,'args':args,'tool_call_id':ident},context)
                db.execute('INSERT INTO operations VALUES(?,?,?,?,?,?)', (ident, origin, tool, fingerprint, 'uncertain', '{}'))
            result = await self.execute(tool, {**args, '_operation_id': ident})
            with sqlite3.connect(self.path) as db:
                db.execute('UPDATE operations SET status=?,result=? WHERE id=?',
                           ('verified' if result.get('verified') else 'uncertain', json.dumps(result, ensure_ascii=False), ident))
            return {**result,'operation_id':ident}

    async def execute(self, tool, args):
        if tool == 'bookkeeping_search':
            from bookkeeping_search import search
            return await search(args, self.state)
        if tool == 'bookkeeping': return await self.bookkeeping(args)
        if tool == 'remind': return await self.remind(args)
        if tool == 'collect':return await asyncio.to_thread(self.collect,args)
        return await self.calendar(args)

    async def book_api(self, route, body=None):
        cfg = json.loads((self.home / '.hermes/skills/productivity/cent-accounting/config.json').read_text())
        async with httpx.AsyncClient(timeout=20, trust_env=False) as client:
            response = await client.request('GET' if body is None else 'POST', cfg['ezBookkeepingUrl'].rstrip('/') + route,
                json=body, headers={'Authorization': 'Bearer ' + cfg['ezBookkeepingToken'], 'X-Timezone-Name': 'Asia/Shanghai', 'X-Timezone-Offset': '480'})
        data = response.json()
        if response.status_code != 200 or data.get('success') is False: raise RuntimeError('Accounting service operation failed')
        return data.get('result')

    async def bookkeeping(self, args):
        action = args.get('action')
        if action == 'recent':
            data = await self.book_api('/api/v1/transactions/list.json?count=' + str(min(30, max(1, int(args.get('count',args.get('limit',5)))))) + '&page=1')
            return {'items': data.get('items', []), 'source': 'ezBookkeeping'}
        if action == 'summary':
            month = args.get('month') or datetime.now(TZ).strftime('%Y-%m')
            first = datetime.strptime(month, '%Y-%m').replace(tzinfo=TZ)
            last = (first.replace(day=28) + timedelta(days=4)).replace(day=1)
            items = await self.book_api('/api/v1/transactions/list/all.json')
            selected = [t for t in items if first.timestamp() <= float(t['time']) / (1000 if float(t['time']) > 1e12 else 1) < last.timestamp()]
            return {'month': month, 'income_minor': sum(int(t['sourceAmount']) for t in selected if t['type'] == 2),
                'expense_minor': sum(int(t['sourceAmount']) for t in selected if t['type'] == 3), 'count': len(selected), 'source': 'ezBookkeeping'}
        if action != 'add': raise ValueError('For deletion use the existing exact-action approval flow')
        amount = Decimal(str(args.get('amount', 0)))
        if not amount.is_finite() or amount <= 0 or amount != amount.quantize(Decimal('.01')): raise ValueError('Amount must be positive and accurate to cents')
        category, account = args.get('category'), args.get('account', '招商银行储蓄卡')
        tree = await self.book_api('/api/v1/transaction/categories/list.json')
        categories = {}
        for group in tree.values():
            for primary in group:
                subs = primary.get('subCategories', [])
                sub = next((s for s in subs if s['name'] == primary['name']), subs[0] if subs else primary)
                categories[primary['name']] = str(sub['id'])
        accounts = {a['name']: str(a['id']) for a in await self.book_api('/api/v1/accounts/list.json')}
        # 报出真实可用的分类与账户：模型猜错名字时能当轮改对，不必去翻文件系统再重试。
        if category not in categories or account not in accounts:
            missing = ([f'分类「{category}」'] if category not in categories else []) + \
                      ([f'账户「{account}」'] if account not in accounts else [])
            raise ValueError('记账分类或账户不存在：' + '、'.join(missing)
                             + '；可用分类：' + '、'.join(sorted(categories))
                             + '；可用账户：' + '、'.join(sorted(accounts)))
        when = args.get('time')
        at = datetime.fromisoformat(when).replace(tzinfo=TZ) if when else datetime.now(TZ)
        body = {'type': 2 if category in ('工资','奖金','报销','其他收入') else 3, 'categoryId': categories[category],
                'sourceAccountId': accounts[account], 'sourceAmount': int(amount * 100), 'time': int(at.timestamp() * 1000),
                'utcOffset': 480, 'comment': args.get('comment', '')}
        created = await self.book_api('/api/v1/transactions/add.json', body)
        ident = str(created.get('id', ''))
        if not ident: raise RuntimeError('Accounting write returned no record ID')
        items = await self.book_api('/api/v1/transactions/list/all.json')
        found = next((t for t in items if str(t['id']) == ident), None)
        verified = bool(found and int(found['sourceAmount']) == body['sourceAmount'] and str(found.get('comment', '')) == body['comment'])
        return {'verified': verified, 'id': ident, 'amount': float(amount), 'category': category, 'account': account,
                'comment': body['comment'], 'source': 'ezBookkeeping'}

    async def remind(self, args):
        path = self.home / '.pi-gateway/state/reminders.json'
        rows = json.loads(path.read_text()) if path.exists() else []
        action = args.get('action')
        if action == 'list': return {'items': [r for r in rows if r.get('status') == 'pending'], 'source': 'existing_reminders'}
        if action == 'add':
            text = str(args.get('text', '')).strip()
            if not text: raise ValueError('Reminder text required')
            if args.get('at'): due = datetime.strptime(args['at'], '%Y-%m-%d %H:%M').replace(tzinfo=TZ)
            else:
                minutes = float(args.get('in_minutes', 0))
                if minutes <= 0: raise ValueError('Reminder time required')
                due = datetime.now(TZ) + timedelta(minutes=minutes)
            if due <= datetime.now(TZ): raise ValueError('Reminder time is in the past')
            repeat = args.get('repeat', 'once')
            if repeat not in ('once', 'daily', 'weekdays', 'weekly'): raise ValueError('Invalid reminder recurrence')
            ident = 'rm' + args['_operation_id'][:16]
            new = {'id': ident, 'text': text, 'due': due.strftime('%Y-%m-%d %H:%M'), 'repeat': repeat,
                   'mode': 'direct', 'status': 'pending', 'created': datetime.now(TZ).strftime('%Y-%m-%d %H:%M'), 'owner': 'com-hermes'}
            changes = [{'id': ident, 'new': new}]
        elif action == 'cancel':
            ident = args.get('id')
            old = next((r for r in rows if r['id'] == ident), None)
            if not old: raise ValueError('Reminder not found')
            changes = [{'id': ident, 'expected': {'status': old['status'], 'due': old['due']}, 'fields': {'status': 'cancelled'}}]
        else: raise ValueError('Invalid reminder action')
        script = self.home / '.pi-gateway/pi_gateway/reminder_store.py'
        proc = await asyncio.create_subprocess_exec(sys.executable, str(script), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        await asyncio.wait_for(proc.communicate(json.dumps({'path': str(path), 'changes': changes}).encode()), 10)
        if proc.returncode: raise RuntimeError('Reminder store write failed')
        saved = next((r for r in json.loads(path.read_text()) if r['id'] == ident), None)
        return {'verified': saved is not None and saved['status'] == ('pending' if action == 'add' else 'cancelled'), 'id': ident, 'item': saved}

    async def calendar(self, args):
        script = self.home / '.hermes/skills/apple/macos-calendar/scripts/calendar.sh'
        action = args.get('action')
        if action == 'list_calendars': command, body = 'list-calendars', b''
        elif action == 'create':
            if not args.get('summary') or not args.get('date'): raise ValueError('Calendar title and date required')
            datetime.strptime(args['date'], '%Y-%m-%d')
            job = {'summary': args['summary'], 'calendar': args.get('calendar', '日历'), 'iso_date': args['date'],
                   'hour': int(args.get('hour', 9)), 'minute': int(args.get('minute', 0)),
                   'duration_minutes': int(args.get('duration_minutes', 60)), 'alarm_minutes': int(args.get('alarm_minutes', 15)),
                   'all_day': bool(args.get('all_day', False)), 'description': args.get('description', '') + '\nCom operation: ' + args['_operation_id']}
            if args.get('recurrence'): job['recurrence'] = args['recurrence']
            command, body = 'create-event', json.dumps(job, ensure_ascii=False).encode()
        else: raise ValueError('Use calendar_read or calendar_adjust for query/update')
        env = {**os.environ, 'PATH': str(Path(sys.executable).parent) + ':/opt/homebrew/bin:/usr/bin:/bin', 'SKILL_DIR': str(script.parent.parent)}
        proc = await asyncio.create_subprocess_exec(str(script), command, env=env, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, _ = await asyncio.wait_for(proc.communicate(body), 45)
        if proc.returncode: raise RuntimeError('Calendar worker operation failed; verify before retrying')
        if action == 'create':
            from calendar_bridge import CalendarBridge
            found = await CalendarBridge(self.home).read(args['date'], args['date'])
            item = next((r for r in found if args['_operation_id'] in r.get('description', '')), None)
            return {'verified': bool(item), 'id': item.get('id') if item else None, 'item': item, 'source': 'Apple Calendar'}
        return {'text': out.decode(), 'source': 'Apple Calendar'}

    def collect(self,args):
        import re,fcntl
        from urllib.parse import urlsplit
        url=args.get('url','');parts=urlsplit(url)
        if parts.scheme not in ('http','https') or not parts.hostname or parts.username:raise ValueError('需要有效收藏链接')
        bucket=args.get('bucket','AI与科技')
        if bucket not in ('AI与科技','视频与创作','户外与旅行','生活与娱乐'):raise ValueError('Unknown collection bucket')
        title=re.sub(r'[/\\:?*<>|\n\r]','-',args.get('title','收藏链接')).strip()[:120] or '收藏链接'
        tags=args.get('tags',['收藏'])
        if not isinstance(tags,list) or not tags or len(tags)>20:raise ValueError('Collection tags required')
        root=self.home/'Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian/收藏库'
        if not root.exists():raise ValueError('原 Obsidian 收藏库不可用')
        folder=root/bucket;folder.mkdir(exist_ok=True)
        ident=args['_operation_id'];path=folder/(title+' - '+ident[:8]+'.md');index=root/'00-收藏索引.md'
        text='---\nurl: '+json.dumps(url,ensure_ascii=False)+'\ncollected: '+datetime.now(TZ).date().isoformat()+'\ntags: '+json.dumps(tags,ensure_ascii=False)+'\ncom_operation: '+ident+'\n---\n\n# '+title+'\n\n'+str(args.get('content','仅保存链接，正文尚未抓取'))+'\n\n来源：'+url+'\n'
        tmp=path.with_suffix('.tmp');tmp.write_text(text);tmp.replace(path)
        link='- [[收藏库/'+bucket+'/'+path.stem+'|'+title+']]'
        with (root/'.com-collection.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            old=index.read_text() if index.exists() else '# 收藏索引\n'
            if link not in old:
                marker='## '+bucket
                heading=re.search(r'(?m)^## '+re.escape(bucket)+r'[^\n]*',old)
                new=old[:heading.end()]+'\n'+link+old[heading.end():] if heading else old+'\n'+marker+'\n'+link+'\n'
                temp=index.with_suffix('.com.tmp');temp.write_text(new);temp.replace(index)
        return {'verified':ident in path.read_text() and url in path.read_text() and link in index.read_text(),'path':str(path),'index':str(index),'source':'existing Obsidian 收藏库','content_status':args.get('content_status','summary_or_link_only')}
