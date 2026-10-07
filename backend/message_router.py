"""Conservative routing for the deployed Hermes main; no classifier model or hidden writes."""
import json
import re
import sqlite3
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from fast_bookkeeping import parse
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

@dataclass(frozen=True)
class Route:
    level: str
    group: str
    label: str
    tool: str = ''
    args: dict | None = None


def classify(text, now=None):
    now=now or datetime.now(ZoneInfo("Asia/Shanghai"))
    text = str(text).strip()
    # Third-person reports need semantic interpretation even with a bookkeeping word.
    plan = None if re.search(r"我(?:的)?(?:朋友|同事|家人)|(?:他|她|他们|她们)(?:买|花|消费|支出|付)",text) else parse(text)
    if plan: return Route('L0','ledger','记账中','bookkeeping',{'action':'add',**plan})
    clean = text.rstrip('。？！?!')
    # Full sentence matches deliberately leave mixed requests, quotes, negation and dates to Hermes.
    if re.fullmatch(r'(?:帮我|请)?(?:查一下|查看|查|看看)?(?:最近|最新)(?:的)?(?:账单|账目|消费|记账)(?:记录)?', clean):
        return Route('L0','ledger','查账中','bookkeeping',{'action':'recent','count':5})
    if re.fullmatch(r'(?:帮我|请)?(?:查一下|查看|查|看看|列出)(?:我的|当前|待办|未完成)?提醒(?:事项)?', clean):
        return Route('L0','reminder','读取提醒','remind',{'action':'list'})
    calendar=re.fullmatch(r'(?:帮我|请)?(?:查一下|查看|查|看看|列出)(今天|明天)(?:的)?(?:日程|安排|日历)',clean)
    if calendar:
        day=(now+timedelta(days=calendar[1]=='明天')).date().isoformat()
        return Route('L0','calendar','读取日程','calendar_event',{'action':'list','start_date':day,'end_date':day})
    reminder=re.fullmatch(r'(?:帮我|请)?(?:在)?([0-9]{4}-[0-9]{2}-[0-9]{2})[ T]([0-9]{2}:[0-9]{2})(?:提醒我|提醒)([^\n]{1,100})',clean)
    if reminder:
        try:
            due=datetime.strptime(reminder[1]+' '+reminder[2],'%Y-%m-%d %H:%M').replace(tzinfo=ZoneInfo('Asia/Shanghai'))
            if due>now:return Route('L0','reminder','创建提醒','remind',{'action':'add','at':due.strftime('%Y-%m-%d %H:%M'),'text':reminder[3]})
        except ValueError:pass
    collect=re.fullmatch(r'(?:帮我|请)?收藏(?:链接)?\s*(https?://[^\s<>]+)',text)
    if collect:
        from urllib.parse import urlsplit
        parts=urlsplit(collect[1])
        if parts.hostname and not parts.username and not collect[1].endswith(('。','！','？')):
            return Route('L0','collect','收藏链接','collect',{'action':'add','url':collect[1],'title':'收藏链接','bucket':'AI与科技','tags':['收藏']})
    if re.fullmatch(r'你好|嗨|hi|hello|早上好|早安|晚上好|晚安|谢谢|谢谢你',clean,re.I):
        return Route('L1','chat','回复中')
    if re.search(r'交给(?:Pi|Claude|Codex)|(?:修复|开发|构建|部署|修改).{0,30}(?:代码|项目|后端|APP|App|应用)',clean,re.I):
        return Route('L3','tasks','处理交办')
    for group, pattern in [('ledger',r'记账|账单|消费|收支'),('calendar',r'日程|日历|会议'),('reminder',r'提醒'),('collect',r'收藏|保存链接')]:
        if re.search(pattern,clean):return Route('L1',group,'处理中')
    return Route('L2','general','处理中')


class MessageRouter:
    def __init__(self,state):
        self.path=Path(state)/'message-routing.sqlite'
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE IF NOT EXISTS decisions(request_id TEXT PRIMARY KEY,route TEXT NOT NULL,classify_ms REAL NOT NULL,first_text_ms REAL,elapsed_ms REAL,prompt_chars INTEGER)')
        self.path.chmod(0o600)

    def decide(self,request_id,text):
        with sqlite3.connect(self.path) as db:
            row=db.execute('SELECT route FROM decisions WHERE request_id=?',(request_id,)).fetchone()
            if row:return Route(**json.loads(row[0]))
            start=time.monotonic();route=classify(text)
            db.execute('INSERT INTO decisions(request_id,route,classify_ms) VALUES(?,?,?)',(request_id,json.dumps(asdict(route),ensure_ascii=False),(time.monotonic()-start)*1000))
        return route

    def complete(self,request_id,*,elapsed_ms,first_text_ms=None,prompt_chars=None):
        with sqlite3.connect(self.path) as db:
            db.execute('UPDATE decisions SET elapsed_ms=?,first_text_ms=?,prompt_chars=? WHERE request_id=?',(elapsed_ms,first_text_ms,prompt_chars,request_id))

    async def execute(self,route,context,service):
        if route.level!='L0':return None
        return await service.call(route.tool,route.args,context)


def receipt(route,result):
    if route.tool=='bookkeeping' and route.args.get('action')=='add':
        from fast_bookkeeping import receipt as booked
        return booked(result)
    if route.tool=='collect':return '已收藏链接：'+route.args['url']
    if route.tool=='remind' and route.args.get('action')=='add':
        item=result.get('item',{})
        return f"已设置提醒：{item.get('due','')} · {item.get('text','')}"
    rows=result.get('items',[])
    if not rows:return {'ledger':'没有查到记录。','calendar':'这一天没有日程。','reminder':'目前没有待办提醒。'}.get(route.group,'没有查到记录。')
    if route.group=='calendar':return '\n'.join(f"{r.get('start','')} · {r.get('title','')}" for r in rows[:20])
    if route.group=='reminder':
        return '\n'.join(f"{r.get('due','')} · {r.get('text','')}" for r in rows[:20])
    from decimal import Decimal
    def amount(r):
        # ezBookkeeping returns integer cents; avoid binary float rounding.
        return format(Decimal(str(r.get('sourceAmount',r.get('amount',0))))/100,'f')
    return '\n'.join(f"{r.get('id','')} · {amount(r)} 元 · {r.get('comment','')}" for r in rows[:5])
