"""Bounded shadow observations; never automatically execute proposed work."""
import asyncio,hashlib,json,os,time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
from work_cards import task_kind

DEFAULTS={'paused':False,'shadow':True,'interval_seconds':3600,'daily_max':24,'quiet_start':23,'quiet_end':8,'max_running':3,'dedup_seconds':21600}

def normalize(value):
    if not isinstance(value,dict) or set(value)-{'action','reason','text'} or value.get('action') not in ('nothing','note','speak','escalate'):
        raise ValueError('invalid decision')
    if not isinstance(value.get('reason'),str) or not value['reason'].strip() or len(value['reason'])>300:
        raise ValueError('invalid trigger reason')
    if not isinstance(value.get('text'),str) or len(value['text'])>160:
        raise ValueError('invalid text')
    if value['action']!='nothing' and not value['text'].strip():raise ValueError('missing decision text')
    return value

class Heartbeat:
    def __init__(self,state,workspace,tasks,proposals,model=None,clock=time.time):
        self.state=Path(state);self.workspace=Path(workspace);self.tasks=tasks;self.proposals=proposals
        self.clock=clock;self.model=model or self.decide;self.lock=asyncio.Lock()
        self.path=self.state/'heartbeat-events.jsonl';self.config=self.state/'heartbeat-config.json'
        self.checklist=self.workspace/'work/工具与效率/会话工作台/HEARTBEAT.md'
        self.last_attempt=0
    def settings(self):
        try:return {**DEFAULTS,**json.loads(self.config.read_text())}
        except (ValueError,OSError):return dict(DEFAULTS)
    def configure(self,changes):
        if set(changes)-{'paused','shadow'} or any(type(v) is not bool for v in changes.values()):raise ValueError('只支持暂停与影子模式开关')
        if changes.get('shadow') is False and not self.shadow_verified():raise ValueError('请先完成至少两次有效影子观察')
        cfg={**self.settings(),**changes};self.state.mkdir(parents=True,exist_ok=True);tmp=self.config.with_suffix('.tmp')
        tmp.write_text(json.dumps(cfg));tmp.chmod(0o600);tmp.replace(self.config)
        return cfg
    def shadow_verified(self):
        return sum(r.get('shadow') and not r.get('error') for r in self.recent(100))>=2
    def recent(self,n=20):
        try:lines=self.path.read_text().splitlines()
        except OSError:return []
        return [json.loads(x) for x in lines[-max(1,min(n,100)):]][::-1]
    def log(self,row):
        self.state.mkdir(parents=True,exist_ok=True)
        with self.path.open('a') as f:f.write(json.dumps(row,ensure_ascii=False)+'\n')
        self.path.chmod(0o600)
    async def decide(self,digest):
        candidates=[Path('/usr/local/lib/node_modules/@earendil-works/pi-coding-agent'),Path.home()/'.pi/runtime/node_modules/@earendil-works/pi-coding-agent']
        sdk=next((p for p in candidates if (p/'dist/index.js').exists()),None)
        if not sdk:raise ValueError('SDK unavailable')
        proc=await asyncio.create_subprocess_exec(os.environ.get('WORKBENCH_NODE','node'),str(Path(__file__).with_name('heartbeat-model.mjs')),stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
        try:
            out,_=await asyncio.wait_for(proc.communicate(json.dumps({'sdk':str(sdk),'digest':digest},ensure_ascii=False).encode()),55)
            if proc.returncode:raise ValueError('model unavailable')
            result=json.loads(out)
            if result.get('usage',{}).get('totalTokens',0)>4096:raise ValueError('token budget exceeded')
            return normalize(result['decision'])
        finally:
            if proc.returncode is None:proc.kill();await proc.wait()
    def digest(self,tasks):
        recent=self.recent(6)
        try:checklist=self.checklist.read_text()[:500]
        except OSError:checklist='清单未找到，保持安静'
        value={'tasks':[{'title':t['title'][:40],'status':t['status'],'reason':t.get('block_reason','')[:100]} for t in tasks[-8:]],
               'recent':[{'action':r['decision']['action'],'reason':r['decision']['reason']} for r in recent], 'checklist':checklist}
        text=json.dumps(value,ensure_ascii=False)
        # UTF-8 bytes conservatively bound input tokens; reserve schema/system and output512.
        while len(text.encode())>2600 and value['tasks']:value['tasks'].pop(0);text=json.dumps(value,ensure_ascii=False)
        if len(text.encode())>2600:raise ValueError('input budget exceeded')
        return text
    async def tick(self,reason='timer',force=False):
        async with self.lock:
            cfg=self.settings();now=self.clock();local=datetime.fromtimestamp(now,ZoneInfo('Asia/Shanghai'))
            history=self.recent(100)
            if cfg['paused']:return {'skipped':'paused'}
            if not force and now-max(self.last_attempt,history[0]['at'] if history else 0)<cfg['interval_seconds']:return {'skipped':'interval'}
            if cfg['quiet_start']<=local.hour or local.hour<cfg['quiet_end']:return {'skipped':'quiet_hours'}
            today=local.date().isoformat()
            if sum(r['day']==today for r in history)>=cfg['daily_max']:return {'skipped':'daily_budget'}
            tasks=[t for t in self.tasks.list() if task_kind(t)=='job']
            if sum(t['status'] in ('queued','running','waiting','dispatching','cancel_requested') for t in tasks)>cfg['max_running']:return {'skipped':'running_limit'}
            self.last_attempt=now
            row={'at':now,'day':today,'trigger':reason,'shadow':cfg['shadow'],'effect':'none'}
            try:
                row['digest']=self.digest(tasks)
                decision=normalize(await self.model(row['digest']))
                live=self.settings()
                if live['paused']:decision={'action':'nothing','reason':'用户已暂停，丢弃本轮决定','text':''}
                duplicate=any(now-r['at']<cfg['dedup_seconds'] and r['decision']['reason']==decision['reason'] and r['decision']['action']==decision['action'] for r in history)
                if duplicate:decision={'action':'nothing','reason':'短时间重复原因，保持静默','text':''}
                row['decision']=decision
                row['shadow']=cfg['shadow'] or live['shadow']
                if not row['shadow'] and not live['paused'] and decision['action']=='speak':row['effect']='awareness'
                elif not row['shadow'] and not live['paused'] and decision['action']=='escalate':
                    key='heartbeat:'+hashlib.sha256((today+decision['reason']).encode()).hexdigest()[:40]
                    proposal=self.proposals.propose(agent='pi',relative_cwd='.',title=decision['text'][:12],prompt=decision['text'],sandbox='danger-full-access',reason='心跳触发：'+decision['reason'],origin_session_id='',origin_message_id='',origin_request_id='',idempotency_key=key)
                    row.update(effect='proposal',proposal_id=proposal['id'])
            except Exception:
                row.update(decision={'action':'nothing','reason':'护栏或模型不可用，静默降级','text':''},error='guard_or_model_unavailable')
            self.log(row);return row
