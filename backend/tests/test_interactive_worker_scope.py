"""A genuine Work-page full-access conversation uses the selected directory directly."""
import asyncio
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from history import History
from worker_runtime import WorkerRuntime,interactive_full_access


def task(tmp_path,**fields):
    return {'id':'manual-real-source','agent':'codex','cwd':str(tmp_path),
            'sandbox':'danger-full-access','workspace_copy':None,'interactive':True,
            'authorization':{'source_message_id':'real-work-user-message','source_quote':'你好'},**fields}


def test_full_guard_revokes_old_readonly_and_retains_path_and_deletion_limits(tmp_path):
    runtime=WorkerRuntime(SimpleNamespace(state=tmp_path))
    draft=task(tmp_path)
    assert interactive_full_access(draft)
    runtime.guard(draft,'Write',{'file_path':'project.py'})
    runtime.guard(draft,'Edit',{'file_path':str(tmp_path/'project.py')})
    with pytest.raises(ValueError,match='超出任务目录'):
        runtime.guard(draft,'Write',{'file_path':'../outside.py'})
    runtime.guard({**draft,'constraints':['先只读，不改代码']},'Write',{'file_path':'project.py'})
    with pytest.raises(ValueError,match='不可逆'):
        runtime.guard(draft,'Bash',{'command':'rm -rf project'})
    runtime.guard({**draft,'interactive':False},'Write',{'file_path':'project.py'})


@pytest.mark.parametrize('sandbox',['danger-full-access','workspace-write','read-only'])
def test_interactive_codex_revokes_legacy_ui_sandbox_and_never_copies(tmp_path,sandbox):
    state=tmp_path/'state';history=History(tmp_path,state);calls=[];copies=[]
    class Runtime:
        def __init__(self):self.state=state;self.h=history
        async def models(self,agent):return [{'id':'advertised-default','is_default':True}]
        async def create(self,agent,cwd,**kwargs):
            calls.append({'cwd':cwd,**kwargs});history.save_managed('codex:manual',{});return 'codex:manual'
    workers=WorkerRuntime(Runtime())
    def prepare(draft):copies.append(draft['id']);return str(tmp_path/'copy')
    workers.copies.prepare=prepare
    asyncio.run(workers.create(task(tmp_path,sandbox=sandbox)))
    assert calls[0]['sandbox']=='danger-full-access'
    assert not copies and calls[0]['cwd']==str(tmp_path)


def test_background_full_permission_task_also_uses_original_directory(tmp_path):
    state=tmp_path/'state';history=History(tmp_path,state);calls=[]
    class Runtime:
        def __init__(self):self.state=state;self.h=history
        async def models(self,agent):return [{'id':'default','is_default':True}]
        async def create(self,agent,cwd,**kwargs):
            calls.append({'cwd':cwd,**kwargs});history.save_managed('codex:background',{});return 'codex:background'
    workers=WorkerRuntime(Runtime());workers.copies.prepare=lambda draft:str(tmp_path/'copy')
    asyncio.run(workers.create(task(tmp_path,interactive=False)))
    assert calls[0]['cwd']==str(tmp_path) and calls[0]['sandbox']=='danger-full-access'
    assert history.managed()['codex:background']['workspace_copy'] is None


def test_new_worker_clears_finished_previous_copy_from_active_task_metadata(tmp_path):
    from tasks import TaskStore
    state=tmp_path/'state';history=History(tmp_path,state);store=TaskStore(state)
    draft=task(tmp_path,origin_message_id='real-work-user-message',workspace_copy=str(tmp_path/'old-copy'),title='旧副本结果',prompt='实际工作')
    store.ensure(draft)
    store.change(draft['id'],'old-finished-copy-for-worker','result',status='execution_finished',
                 workspace_copy=str(tmp_path/'old-copy'),run_id='old-result-run',operation_policy_revision=None)
    store.apply_operation_policy()
    class Runtime:
        def __init__(self):self.state=state;self.h=history;self.task_store=store
        async def models(self,agent):return [{'id':'default','is_default':True}]
        async def create(self,agent,cwd,**kwargs):
            assert cwd==str(tmp_path)
            history.save_managed('codex:next-native',{});return 'codex:next-native'
    workers=WorkerRuntime(Runtime())
    asyncio.run(workers.create(store.list()[0]))
    current=store.list()[0]
    assert current['workspace_copy'] is None
    assert current['previous_operation_scope']['workspace_copy']==str(tmp_path/'old-copy')
    assert current['previous_operation_scope']['run_id']=='old-result-run'
