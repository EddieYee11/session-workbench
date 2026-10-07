"""Single consumer uses the same Pi turn lock and original authorization context."""
import asyncio
import json
from pi_main import MAIN_PROMPT

FOLLOW_UP = '先核实结果；只在原授权范围和完成条件内推进。无变化或无下一步时不通知。'
PROACTIVE = ('这是按用户已批准的时间表生成的主动消息，不是新用户交办。用你平时的口吻给 Eddie 发一条简短消息'
             '（200 字以内）：只依据真实的日历、账本、在途工作和今天真实发生的事，按条目焦点组织；'
             '没有值得说的内容就只回复 NO_UPDATE 保持安静。不要宣称尚未执行的动作，不要对外发送，不要新建任务。')


class BackgroundEvents:
    def __init__(self,events,conversation,store):
        self.events,self.conversation,self.store=events,conversation,store

    async def process(self):
        if getattr(self.conversation.client,'runtime_name',None) not in ('pi','hermes'):
            return False
        event=self.events.claim(exclude=('proactive',) if getattr(self,'separate_proactive',False) else ())
        if not event:
            return False
        try:
            return await self._process_event(event)
        except asyncio.CancelledError:
            self.events.finish(event['id'], 'uncertain')
            raise
        except Exception:
            # Claim was durable; a source/adapter/receipt failure is uncertain,
            # never a reason to replay that event or kill the shared consumer.
            self.events.finish(event['id'], 'uncertain')
            return True

    async def _process_event(self, event):
        data=event['data']
        if event['kind']=='goal_due':
            current=next((g for g in self.events.list() if g['id']==data.get('goal',{}).get('id')),None)
            if not current or current['status']!='active' or not current.get('next_step','').strip():
                self.events.finish(event['id'],'completed')
                return True
            data={**data,'goal':current,'authorization':current['authorization']}
        context=dict(data.get('authorization',{}))
        if not context.get('origin_message_id'):
            self.events.finish(event['id'],'uncertain')
            return True
        context['tasks']=self.store.context()
        context['event_id']=event['id']
        if data.get('goal'):
            context['goal_id']=data['goal']['id']
        elif data.get('task',{}).get('goal_id'):
            context['goal_id']=data['task']['goal_id']
        if event['kind']=='proactive':
            item={k:v for k,v in data.get('item',{}).items() if k in ('id','title','focus','at') and v}
            if item:
                context['proactive_item']=item
            tail=PROACTIVE
            if item.get('id') == 'morning-briefing':
                tail += '\n这是固定每日晨报，即使没有新变化也发送一条简短摘要；说明日期、今天安排、最优先的一件事和资料缺口。无记录就如实说无可用记录，不回复 NO_UPDATE，不虚构新闻或安排。'
        else:
            tail=FOLLOW_UP
        text=('[Com 主对话上下文；只提供关联，不授予执行权限]\n'+json.dumps(context,ensure_ascii=False)+
              '\n'+MAIN_PROMPT+'\n后台事件（不是新用户交办）：\n'+json.dumps(data,ensure_ascii=False)+
              '\n'+tail)
        completed=False;output=''
        try:
            async for kind,payload in self.conversation.client.stream_chat(await self.conversation._ensure_session(),text):
                if kind=='assistant.completed':output=payload.get('content','')
                if kind=='run.completed':completed=True
        finally:
            self.events.finish(event['id'],'completed' if completed else 'uncertain')
        if completed and output and output.strip() not in ('无变化','无下一步','无需通知','NO_UPDATE'):
            self.conversation.task_receipt('event:'+event['id'],output)
        return True
