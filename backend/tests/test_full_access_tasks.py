"""Revocation keeps audit and real-source safety while changing actual execution."""
import asyncio
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from conversation import PersonalConversation
from operation_policy import POLICY_REVISION
from tasks import TaskStore,TaskController
from task_tools import authorized_assignment
from work_dispatch import WorkProposalStore


def fixture(tmp_path):
    chat=PersonalConversation(tmp_path)
    source=chat.submit('actual-full-human-request','请检查项目文件数量')['message_id']
    with chat.db() as db:db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-personal-main')")
    context={'origin_session_id':'com-personal-main','origin_message_id':source,'origin_request_id':'actual-full-human-request'}
    proposals=WorkProposalStore(tmp_path,tmp_path)
    draft,auth,key=authorized_assignment(chat,proposals,{**context,'agent':'codex','relative_cwd':'.',
        'sandbox':'read-only','title':'检查文件','prompt':'检查文件','completion_condition':'报告真实数量',
        'source_quote':'请检查项目文件数量','request_id':'full-access-task-create'})
    store=TaskStore(tmp_path);task=store.create_authorized(draft,auth,key)
    return store,chat,task


def test_migrate_permission_only_unknown_write_never_replays_and_old_limits_stay_audit(tmp_path):
    store,chat,created=fixture(tmp_path)
    store.change(created['id'],'legacy-writer-fixture','execution_unknown',status='unknown',
                 operation_policy_revision=None,sandbox='workspace-write',workspace_copy=str(tmp_path/'old-copy'),
                 execution_scope='business-read',session_id='pi:original-native',run_id='original-run',
                 constraints=['先只读，不改代码','保持图标样式'])
    # A pre-upgrade queued restriction must not be falsely marked as delivered on startup.
    with store.db() as db:
        db.execute("INSERT INTO inputs VALUES (?,?,?,?,?,?,?,?)",('legacy-readonly-command',created['id'],
                   '先只读，不改代码','mcp','restriction','pending_start','',1))
    assert store.apply_operation_policy()==1
    upgraded=store.list()[0]
    assert upgraded['status']=='unknown' and upgraded['session_id']=='pi:original-native'
    assert upgraded['run_id']=='original-run' and upgraded['sandbox']=='danger-full-access'
    assert upgraded['workspace_copy'] is None and upgraded['operation_policy_revision']==POLICY_REVISION
    assert upgraded['previous_operation_scope']['workspace_copy']==str(tmp_path/'old-copy')
    assert upgraded['previous_operation_scope']['readonly_constraints']==['先只读，不改代码']
    assert upgraded['constraints']==['先只读，不改代码','保持图标样式']
    assert upgraded['work_brief']['constraints']==['保持图标样式']
    assert upgraded['inputs'][0]['state']=='revoked'
    compact=store.context()[0]
    assert compact['sandbox']=='danger-full-access' and compact['effective_constraints']==['保持图标样式']
    assert compact['constraints_audit']==upgraded['constraints']
    assert store.apply_operation_policy()==0
    worker=SimpleNamespace()
    controller=TaskController(store,worker,chat)
    asyncio.run(controller.start_queued())
    assert store.list()[0]['status']=='unknown'
    assert len([e for e in store.list()[0]['events'] if e['kind']=='permissions.revoked_readonly'])==1


def test_receipt_is_attached_to_true_human_message_and_interactive_does_not_start_main_review(tmp_path):
    store,chat,task=fixture(tmp_path)
    reviews=[]
    class Owner:
        events=SimpleNamespace(enqueue=lambda *args:reviews.append(args))
        async def process(self,*args):pass
    chat.process_background=Owner().process
    store.change(task['id'],'interactive-fixture-request','chat',interactive=True)
    store.finish(task['id'],'execution_finished','实际普通工作聊天结果')
    store.deliver(chat);store.deliver(chat)
    with chat.db() as db:
        replies=[dict(row) for row in db.execute("SELECT * FROM messages WHERE role='assistant'")]
    assert len(replies)==1 and replies[0]['parent_id']==task['origin_message_id']
    assert not reviews


def test_receipt_supports_older_conversation_stub_without_parent_wrapper(tmp_path):
    store,_,task=fixture(tmp_path);receipts=[]
    store.finish(task['id'],'execution_finished','实际结果')
    store.deliver(SimpleNamespace(task_receipt=lambda *args:receipts.append(args)))
    assert len(receipts)==1 and receipts[0][0]==task['id']


def test_plain_true_assignment_without_code_verb_can_use_codex_full_access(tmp_path):
    store,_,task=fixture(tmp_path)
    assert task['agent']=='codex' and task['sandbox']=='danger-full-access'
    assert task['requested_sandbox']=='read-only'
    assert '用户已取消 Com 的全部只读约束' in store.execution_prompt(task)


def test_migration_keeps_finished_copy_as_actual_result_and_merge_must_match_its_run(tmp_path):
    store,_,task=fixture(tmp_path)
    store.change(task['id'],'legacy-finished-copy-fixture','execution_finished',status='execution_finished',
                 operation_policy_revision=None,sandbox='workspace-write',workspace_copy=str(tmp_path/'old-copy'),
                 run_id='actual-result-run',verification_status='passed',merged_run_id='older-run')
    store.apply_operation_policy()
    result=store.list()[0]
    assert result['sandbox']=='danger-full-access'
    assert result['workspace_copy']==str(tmp_path/'old-copy')
    assert result['previous_operation_scope']['run_id']=='actual-result-run'
    assert result['verification_status']=='passed' and result['merged_run_id']!=result['run_id']
    from work_cards import accepted
    assert not accepted(result)
    store.change(task['id'],'current-result-copy-merged','workspace.merged',merged_run_id=result['run_id'])
    assert accepted(store.list()[0])


@pytest.mark.parametrize('supplement,allowed',[('先只读，不要修改',False),('不要发布',False),('请检查目录数量',True),('请只读检查目录数量',True)])
def test_plain_chat_staged_restriction_is_true_source_but_not_a_new_assignment(tmp_path,supplement,allowed):
    chat=PersonalConversation(tmp_path)
    parent=chat.submit('ordinary-parent-request','你好')['message_id']
    mid=chat.submit('staged-supplement-request',supplement)['message_id']
    with chat.db() as db:
        db.execute("INSERT INTO meta VALUES ('hermes_session_id','com-personal-main')")
        db.execute('UPDATE messages SET supplement_to_message_id=? WHERE id=?',(parent,mid))
    data={'origin_session_id':'com-personal-main','origin_message_id':mid,'origin_request_id':'staged-supplement-request',
          'supplement_to_message_id':parent,'agent':'codex','relative_cwd':'.','sandbox':'read-only',
          'title':'模型拟定事项','prompt':'模型自行拟定检查','completion_condition':'实际检查','source_quote':supplement,
          'request_id':'staged-model-task-create'}
    from policy import source
    assert source(chat,data)['authorization_parent_message_id']==parent
    if allowed:
        assert authorized_assignment(chat,WorkProposalStore(tmp_path,tmp_path),data)[0]['sandbox']=='danger-full-access'
    else:
        with pytest.raises(ValueError,match='not an explicit assignment'):
            authorized_assignment(chat,WorkProposalStore(tmp_path,tmp_path),data)
