"""Cards update the existing gateway reminder records; no new reminder database."""
import fcntl,hashlib,json,os,re
from datetime import datetime,timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

class ReminderCards:
    def __init__(self,path,clock=None):
        self.path=Path(path);self.clock=clock or (lambda:datetime.now(ZoneInfo('Asia/Shanghai')))
    def read(self):
        try:rows=json.loads(self.path.read_text())
        except FileNotFoundError:raise ValueError('提醒来源尚未就绪') from None
        except (OSError,ValueError):raise ValueError('真实提醒记录不可读') from None
        if not isinstance(rows,list):raise ValueError('真实提醒记录格式错误')
        return rows
    def list(self):
        return [{k:r.get(k) for k in ('id','text','due','repeat','mode','status')} for r in self.read() if isinstance(r,dict) and r.get('id')][-100:]
    def act(self,ident,action,request_id,expected):
        if action not in ('confirm','snooze10','snooze60','cancel'):raise ValueError('未知提醒动作')
        if not isinstance(request_id,str) or not re.fullmatch(r'[A-Za-z0-9_-]{10,120}',request_id):raise ValueError('无效请求号')
        if not isinstance(expected,dict):raise ValueError('需要真实记录快照')
        lock=self.path.with_suffix('.com-lock')
        with lock.open('a') as f:
            fcntl.flock(f,fcntl.LOCK_EX);lock.chmod(0o600)
            rows=self.read();stamp=self.path.stat().st_mtime_ns
            target=next((r for r in rows if r.get('id')==ident),None)
            if not target:raise ValueError('提醒已不存在，请刷新')
            commands=target.setdefault('_com_card_actions',{})
            fingerprint=hashlib.sha256(json.dumps([action,expected],sort_keys=True).encode()).hexdigest()
            if request_id in commands:
                if commands[request_id]['fingerprint']!=fingerprint:raise ValueError('请求号与原动作不一致')
                return {'item':{k:target.get(k) for k in ('id','text','due','repeat','mode','status')},'confirmed':True,'duplicate':True}
            if any(target.get(k)!=expected.get(k) for k in ('due','status')):raise ValueError('提醒已变化，请刷新后再操作')
            if target.get('status')!='pending':raise ValueError('这条提醒已结束，不能再次更改')
            if action in ('confirm','cancel'):target['status']='done' if action=='confirm' else 'cancelled'
            else:
                old=datetime.strptime(target['due'],'%Y-%m-%d %H:%M').replace(tzinfo=ZoneInfo('Asia/Shanghai'))
                target['due']=(max(old,self.clock())+timedelta(minutes=10 if action=='snooze10' else 60)).strftime('%Y-%m-%d %H:%M')
            commands[request_id]={'fingerprint':fingerprint,'action':action}
            tmp=self.path.with_suffix('.com-tmp-'+request_id)
            tmp.write_text(json.dumps(rows,ensure_ascii=False,indent=1));tmp.chmod(0o600)
            if self.path.stat().st_mtime_ns!=stamp:
                tmp.unlink();raise ValueError('提醒来源正在更新，请刷新重试')
            tmp.replace(self.path)
            saved=next((r for r in self.read() if r.get('id')==ident),None)
            if not saved or any(saved.get(k)!=target.get(k) for k in ('due','status')):raise ValueError('动作结果待核实，请回读；不会自动重放')
            return {'item':{k:saved.get(k) for k in ('id','text','due','repeat','mode','status')},'confirmed':True}
