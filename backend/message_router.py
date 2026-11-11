"""Conservative routing for the deployed Hermes main; optional <500ms pre-turn fast classifier when gated on."""
from __future__ import annotations

import json
import os
import re
import sqlite3
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from fast_bookkeeping import parse, parse_candidate
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

@dataclass(frozen=True)
class Route:
    level: str
    group: str
    label: str
    tool: str = ''
    args: dict | None = None
    prebound_tools: list[str] | None = None


def classify(text, now=None):
    now=now or datetime.now(ZoneInfo("Asia/Shanghai"))
    text = str(text).strip()
    if text.startswith('Eddie 已确认：'):
        return Route('L2','general','处理中')
    # Third-person reports need semantic interpretation even with a bookkeeping word.
    plan = None if re.search(r"我(?:的)?(?:朋友|同事|家人)|(?:他|她|他们|她们)(?:买|花|消费|支出|付)",text) else parse(text)
    if plan:
        from fast_bookkeeping import suspect
        alt = suspect(plan, text)
        if alt: return Route('L0','ledger','待确认记账','bookkeeping',{'action':'confirm','plan':{**plan,'suspect':alt}})
        return Route('L0','ledger','记账中','bookkeeping',{'action':'add',**plan})
    if not re.search(r"我(?:的)?(?:朋友|同事|家人)|(?:他|她|他们|她们)(?:买|花|消费|支出|付)",text):
        candidate = parse_candidate(text)
        if candidate:
            return Route('L0','ledger','待确认记账','bookkeeping',
                         {'action':'confirm','plan':candidate})
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
    # 「嗯」「好的」「不用了」这类极短应答没有可执行内容，不值得让模型先推理再查工具。
    if len(clean)<=4 and not re.search(r'[0-9A-Za-z]|查|看|记|提醒|删|改|发|找|定',clean):
        return Route('L1','chat','回复中')
    if re.search(r'交给(?:Pi|Claude|Codex)|(?:修复|开发|构建|部署|修改).{0,30}(?:代码|项目|后端|APP|App|应用)',clean,re.I):
        return Route('L3','tasks','处理交办')
    for group, pattern in [('ledger',r'记账|账单|消费|收支'),('calendar',r'日程|日历|会议'),('reminder',r'提醒'),('collect',r'收藏|保存链接')]:
        if re.search(pattern,clean):return Route('L1',group,'处理中')
    return Route('L2','general','处理中')


DEFAULT_CASUAL_MODEL = "vertex-948/gemini-3.5-flash-lite"
_CASUAL_DEGRADED_MODELS: set[str] = set()


# 11-02 Eddie 拍板：日常对话和查询走 flash；要深度判断、带附件、交办开发的留给网关默认模型（grok）。
# 模型和判据在 event_rules.json 的 conversation 段；「最该先做什么」这类排优先级算判断：
# 11-02 同题对比里 flash 把退指力板排在给人打款的劳务单前面。
def fast_model():
    from event_rules import rules
    return rules.conversation().get('fast_model') or {}


def casual_fast_model() -> dict:
    """纯寒暄/短句闲聊（L1/chat）极速模型，支持 COM_CASUAL_MODEL 覆盖，异常/降级时回退 fast_model()。"""
    try:
        fallback = dict(fast_model() or {})
    except Exception:
        fallback = {}
    provider = str(fallback.get("provider") or "magpie").strip() or "magpie"
    candidate = os.environ.get("COM_CASUAL_MODEL", "").strip() or DEFAULT_CASUAL_MODEL
    if not candidate or candidate in _CASUAL_DEGRADED_MODELS:
        if fallback.get("model"):
            return fallback
        return {"model": DEFAULT_CASUAL_MODEL, "provider": provider}
    return {"model": candidate, "provider": provider}


def mark_casual_model_degraded(model_name: str | None = None) -> dict:
    """标记当前闲聊快模型不可用并返回回退的 fast_model()。"""
    target = (model_name or os.environ.get("COM_CASUAL_MODEL", "").strip() or DEFAULT_CASUAL_MODEL).strip()
    if target:
        _CASUAL_DEGRADED_MODELS.add(target)
    return dict(fast_model() or {"model": DEFAULT_CASUAL_MODEL, "provider": "magpie"})


def reset_casual_model_state() -> None:
    _CASUAL_DEGRADED_MODELS.clear()


def use_fast_model(level,text,has_attachments=False):
    from event_rules import rules
    if has_attachments:return False
    if level=='L1':return True
    deep=rules.conversation().get('deep_work')
    return level=='L2' and len(text or '')<=200 and not (deep and re.search(deep,text or '',re.I))


class MessageRouter:
    def __init__(self,state):
        self.state=Path(state)
        self.path=self.state/'message-routing.sqlite'
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE IF NOT EXISTS decisions(request_id TEXT PRIMARY KEY,route TEXT NOT NULL,classify_ms REAL NOT NULL,first_text_ms REAL,elapsed_ms REAL,prompt_chars INTEGER,fast_classified INTEGER DEFAULT 0)')
            cols={r[1] for r in db.execute('PRAGMA table_info(decisions)').fetchall()}
            if 'fast_classified' not in cols:
                db.execute('ALTER TABLE decisions ADD COLUMN fast_classified INTEGER DEFAULT 0')
        self.path.chmod(0o600)

    def decide(self,request_id,text):
        with sqlite3.connect(self.path) as db:
            row=db.execute('SELECT route FROM decisions WHERE request_id=?',(request_id,)).fetchone()
            if row:return Route(**json.loads(row[0]))
            start=time.monotonic()
            route=self._match_pending(text) or classify(text)
            db.execute('INSERT INTO decisions(request_id,route,classify_ms,fast_classified) VALUES(?,?,?,0)',(request_id,json.dumps(asdict(route),ensure_ascii=False),(time.monotonic()-start)*1000))
        return route

    async def decide_async(self,request_id,text,*,timeout_s:float=0.72,caller=None,transport=None,models_path=None)->Route:
        base_route=self.decide(request_id,text)
        if base_route.level=='L0':
            return base_route
        from superagent_flags import SuperagentFlags
        if not SuperagentFlags(self.state).fast_classifier_on():
            return base_route
        with sqlite3.connect(self.path) as db:
            row=db.execute('SELECT route,COALESCE(fast_classified,0) FROM decisions WHERE request_id=?',(request_id,)).fetchone()
        if row and int(row[1]):
            return Route(**json.loads(row[0]))
        from fast_classifier import FastClassification, append_classifier_log, classify_fast
        if base_route.level=='L1' and base_route.group=='chat' and caller is None and transport is None:
            fast_res=FastClassification(intent='chat',confidence=1.0,tools=[],level='L1',accepted=True,fallback='',elapsed_ms=0.05)
            append_classifier_log(self.state,request_id=request_id,result=fast_res)
            upgraded=Route('L1','chat','回复中',prebound_tools=[])
            with sqlite3.connect(self.path) as db:
                db.execute('UPDATE decisions SET route=?,fast_classified=1 WHERE request_id=?',
                           (json.dumps(asdict(upgraded),ensure_ascii=False),request_id))
            return upgraded
        fc=await classify_fast(self.state,request_id,text,timeout_s=timeout_s,caller=caller,transport=transport,models_path=models_path)
        if not fc.accepted:
            with sqlite3.connect(self.path) as db:
                db.execute('UPDATE decisions SET classify_ms=classify_ms+?,fast_classified=1 WHERE request_id=?',
                           (fc.elapsed_ms,request_id))
            return base_route
        upgraded=self._merge_fast_route(base_route,text,fc)
        with sqlite3.connect(self.path) as db:
            db.execute('UPDATE decisions SET route=?,classify_ms=classify_ms+?,fast_classified=1 WHERE request_id=?',
                       (json.dumps(asdict(upgraded),ensure_ascii=False),fc.elapsed_ms,request_id))
        return upgraded

    @staticmethod
    def _merge_fast_route(base_route:Route,text:str,fc)->Route:
        from event_rules import rules
        level='L3' if base_route.level=='L3' else fc.level
        deep=rules.conversation().get('deep_work')
        if level=='L1' and deep and re.search(deep,str(text or ''),re.I):
            level='L2'
        tools=list(fc.tools)
        if fc.intent=='chat' and level!='L3' and not tools:
            return Route('L1','chat','回复中',prebound_tools=[])
        if fc.intent=='bookkeeping':
            if 'business_operation' not in tools:
                tools=['business_operation',*tools]
            return Route(level,'ledger','处理中',prebound_tools=tools)
        if level=='L3' or 'task_submit' in tools:
            return Route(level,'tasks','处理交办',prebound_tools=tools)
        if base_route.group in ('ledger','calendar','reminder','collect'):
            return Route(level,base_route.group,'处理中',prebound_tools=tools)
        return Route(level,fc.intent,'处理中',prebound_tools=tools)

    def _match_pending(self,text):
        if str(text or '').strip().startswith('Eddie 已确认：'):
            return None
        if not (self.state/'pending-actions.sqlite').exists():
            return None
        from pending_actions import PendingActions
        matched=PendingActions(self.state).match(text)
        if not matched:
            return None
        pending=matched['pending']
        if matched['decision']=='affirm':
            return Route('L0','pending','执行确认动作','pending_action',{'decision':'affirm','action_id':pending['id'],'description':pending['description']})
        return Route('L0','pending','取消待确认动作','pending_action',{'decision':'negate','action_id':pending['id'],'description':pending['description']})

    def complete(self,request_id,*,elapsed_ms,first_text_ms=None,prompt_chars=None):
        with sqlite3.connect(self.path) as db:
            db.execute('UPDATE decisions SET elapsed_ms=?,first_text_ms=?,prompt_chars=? WHERE request_id=?',(elapsed_ms,first_text_ms,prompt_chars,request_id))

    async def execute(self,route,context,service):
        if route.level!='L0':return None
        if route.tool=='pending_action':
            from pending_actions import PendingActions
            pa=PendingActions(self.state)
            action_id=(route.args or {}).get('action_id')
            if (route.args or {}).get('decision')=='negate':
                cancelled=pa.cancel(action_id)
                desc=(cancelled or {}).get('description') or (route.args or {}).get('description') or '该操作'
                return {'status':'cancelled','receipt':f'好的，已取消：{desc}。'}
            return await pa.execute(
                action_id,
                request_id=(context or {}).get('origin_request_id',''),
                message_id=(context or {}).get('origin_message_id',''),
                session_id=(context or {}).get('origin_session_id',''),
                conversation=(context or {}).get('conversation'),
                service=service,
            )
        return await service.call(route.tool,route.args,context)


def receipt(route,result):
    if route.tool=='pending_action':
        if isinstance(result,dict) and result.get('receipt'):
            return result['receipt']
        return '已处理确认动作。'
    # 模糊候选不由 route.execute 写入， receipts 需要单独转成确认卡。
    if route.tool == 'bookkeeping' and route.args.get('action') == 'confirm':
        from fast_bookkeeping import confirm_card
        plan = route.args['plan']
        if plan.get('suspect'):
            return {'text': confirm_card(plan), 'suggestions': ['改成 %g' % plan['suspect'], '就是 %g' % plan['amount'], '不记']}
        return {'text': confirm_card(plan), 'suggestions': ['是', '改一下', '不记']}
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
