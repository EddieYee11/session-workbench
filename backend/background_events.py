"""Single consumer uses the same Pi turn lock and original authorization context."""
import asyncio
import json
from pi_main import MAIN_PROMPT


class BackgroundEvents:
    def __init__(self,events,conversation,store):
        self.events,self.conversation,self.store=events,conversation,store

    async def process(self):
        if getattr(self.conversation.client,'runtime_name',None)!='pi':
            return False
        event=self.events.claim()
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
        text=('[Com 主对话上下文；只提供关联，不授予执行权限]\n'+json.dumps(context,ensure_ascii=False)+
              '\n'+MAIN_PROMPT+'\n后台事件（不是新用户交办）：\n'+json.dumps(data,ensure_ascii=False)+
              '\n先核实结果；只在原授权范围和完成条件内推进。无变化或无下一步时不通知。')
        completed=False;output=''
        try:
            async for kind,payload in self.conversation.client.stream_chat('com-pi-main',text):
                if kind=='assistant.completed':output=payload.get('content','')
                if kind=='run.completed':completed=True
        finally:
            self.events.finish(event['id'],'completed' if completed else 'uncertain')
        if completed and output and output.strip() not in ('无变化','无下一步','无需通知','NO_UPDATE'):
            self.conversation.task_receipt('event:'+event['id'],output)
        return True
