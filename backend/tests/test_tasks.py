import asyncio
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tasks import TaskStore, TaskController
from conversation import PersonalConversation


def proposal(tid, mid):
    return dict(id=tid,origin_message_id=mid,title=tid,agent='codex',cwd='/isolated',prompt='inspect',sandbox='read-only')


class FakeWorker:
    def __init__(self):
        self.state='running';self.calls=[]
    async def status(self,sid):return self.state
    def events(self,sid):return [{'text':'verified output','role':'assistant','kind':'item'}]
    async def steer_task(self,sid,turn,text):self.calls.append(('steer',sid,turn,text))
    async def stop(self,sid):self.calls.append(('stop',sid))


def active(store,tid,mid):
    store.ensure(proposal(tid,mid))
    store.change(tid,'start-'+tid,'started',status='running',session_id='sid-'+tid,run_id='turn-'+tid)


def test_two_tasks_update_not_third_and_completion_outbox(tmp_path):
    store=TaskStore(tmp_path);chat=PersonalConversation(tmp_path);worker=FakeWorker()
    active(store,'task-A','message-A');active(store,'task-B','message-B')
    controller=TaskController(store,worker,chat)
    chat.submit('smalltalk-001','你好') # conversational submission does not dispatch work
    assert len(store.list())==2
    asyncio.run(controller.command('task-A','不要修改代理','constraint-001'))
    asyncio.run(controller.command('task-A','不要修改代理','constraint-001'))
    assert len(worker.calls)==1
    assert len(store.list())==2
    assert next(t for t in store.list() if t['id']=='task-A')['constraints']==['不要修改代理']
    worker.state='completed'
    asyncio.run(controller.poll());asyncio.run(controller.poll())
    assert len([m for m in chat.snapshot()['messages'] if m['role']=='assistant'])==2
    assert all(t['status']=='execution_finished' for t in store.list())
    # Simulate crash after conversation insert, before outbox acknowledgement.
    with store.db() as db:db.execute('UPDATE outbox SET delivered=0')
    TaskStore(tmp_path).deliver(PersonalConversation(tmp_path))
    assert len([m for m in chat.snapshot()['messages'] if m['role']=='assistant'])==2


def test_cancel_waits_and_restart_never_replays(tmp_path):
    store=TaskStore(tmp_path);chat=PersonalConversation(tmp_path);worker=FakeWorker()
    active(store,'task-A','message-A');controller=TaskController(store,worker,chat)
    asyncio.run(controller.command('task-A','','cancel-0001',cancel=True))
    asyncio.run(controller.command('task-A','','cancel-0001',cancel=True))
    asyncio.run(controller.poll())
    assert store.list()[0]['status']=='cancel_requested'
    assert len(worker.calls)==1
    worker.state='interrupted';asyncio.run(controller.poll())
    assert store.list()[0]['status']=='cancelled'
    active(store,'task-B','message-B');store.recover()
    restarted=TaskController(TaskStore(tmp_path),worker,chat)
    asyncio.run(restarted.poll())
    assert next(t for t in store.list() if t['id']=='task-B')['status']=='unknown'
    assert len(worker.calls)==1
