import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conversation import PersonalConversation
from quality_judge import normalize, review_input
import pytest


def ledger_task(mid, **changes):
    return {'id': 'task_card_001', 'origin_message_id': mid, 'title': '修复连续发送',
            'status': 'running', 'created_at': 100, 'updated_at': 102,
            'verification_status': 'pending', 'events': [
                {'seq': 1, 'kind': 'tool.started', 'text': '{"tool":"read"}', 'at': 101}],
            'inputs': [], **changes}


def test_task_events_update_original_message_and_sse_after_reply(tmp_path):
    conversation = PersonalConversation(tmp_path)
    mid = conversation.submit('request-card-001', '帮我修复连续发送')['message_id']
    conversation._finish(mid, 'completed', '已交给后台继续处理')
    before = conversation.snapshot()['revision']
    task = ledger_task(mid)
    conversation.sync_task_cards([task])
    change = conversation.changes_since(before)
    row = next(m for m in change['messages'] if m['id'] == mid)
    assert row['linked_tasks'][0]['id'] == task['id']
    assert row['tasks'][0]['status'] == 'running'
    assert row['work_events'][0]['text'] == 'read：开始调用'
    assert row['summary'] is None
    assert change['changed_tasks'][0]['id'] == task['id']
    revision = change['revision']
    conversation.sync_task_cards([task])
    assert conversation.snapshot()['revision'] == revision
    reopened = PersonalConversation(tmp_path).snapshot()
    assert reopened['tasks'][0]['id'] == task['id']
    assert next(m for m in reopened['messages'] if m['id'] == mid)['tasks'] == row['tasks']


def test_finished_work_remains_pending_until_verified_and_exact_run_merged(tmp_path):
    c = PersonalConversation(tmp_path)
    mid = c.submit('request-card-002', '修改后交付')['message_id']
    c._finish(mid, 'completed', '后台完成')
    t = ledger_task(mid, status='execution_finished', run_id='run-2',
                    sandbox='workspace-write', workspace_copy='/tmp/copy', result='修复已写入副本')
    c.sync_task_cards([t])
    def summary():
        return next(m for m in c.snapshot()['messages'] if m['id'] == mid)['summary']
    assert summary()['status'] == 'execution_finished'
    t['verification_status'] = 'passed'
    t['merged_run_id'] = 'run-1'
    c.sync_task_cards([t])
    assert summary()['status'] == 'execution_finished'
    t['merged_run_id'] = 'run-2'
    c.sync_task_cards([t])
    assert summary()['status'] == 'done'
    assert summary()['verification_status'] == 'passed'
    # Legacy copies without a recorded run cannot prove which version was merged.
    t.pop('run_id')
    t.pop('merged_run_id')
    c.sync_task_cards([t])
    assert summary()['status'] == 'execution_finished'
    assert summary()['verification_status'] == 'pending'


def test_revoked_permission_does_not_accept_an_unmerged_historical_copy():
    from work_cards import accepted
    task=ledger_task('human',status='execution_finished',verification_status='passed',
                     sandbox='danger-full-access',workspace_copy='/tmp/historical-copy',run_id='old-run')
    assert not accepted(task)
    task['merged_run_id']='other-run'
    assert not accepted(task)
    task['merged_run_id']='old-run'
    assert accepted(task)


def test_tool_without_end_evidence_cannot_turn_green_when_reply_finishes(tmp_path):
    c = PersonalConversation(tmp_path)
    mid = c.submit('request-card-003', '检查环境')['message_id']
    c._record_tasks(mid, [{'id': 'tool-1', 'kind': 'tool', 'title': 'read', 'status': 'running'}])
    c._finish(mid, 'completed', '完成了')
    row = next(m for m in c.snapshot()['messages'] if m['id'] == mid)
    assert row['tasks'][0]['status'] == 'unknown'
    assert row['summary']['status'] != 'done'
    assert row['summary']['verification_status'] == 'unverified'
    c.sync_task_cards([ledger_task(mid, status='execution_finished', verification_status='passed')])
    row = next(m for m in c.snapshot()['messages'] if m['id'] == mid)
    assert row['summary']['status'] == 'unknown'
    assert row['summary']['verification_status'] != 'passed'


def test_judge_requires_valid_evidence_gap_result(tmp_path):
    with pytest.raises(ValueError):
        normalize({'verdict': 'pass', 'reason': '文件存在',
                   'evidence_gaps': [{'criterion_id': 'send', 'missing_evidence': '连续发送未测试'}], 'next_steps': []})
    assert normalize({'verdict': 'unknown', 'reason': '缺少正常使用证据',
                      'evidence_gaps': [], 'next_steps': ['补充连续发送回放']})['verdict'] == 'unknown'
    file = tmp_path / 'result.txt'
    file.write_text('actual file evidence')
    task = ledger_task('source', cwd=str(tmp_path), authorization={'source_quote': '修复发送'},
                       constraints=['保留配对'], result='我已经全部完成')
    data = review_input(task, [{'reference': str(file), 'check': 'file_contains'}])
    assert data['actual_checks'][0]['excerpt'] == 'actual file evidence'
    assert data['executor_report_unverified'] == '我已经全部完成'
    assert data['original_assignment'] == '修复发送'


def test_plain_conversation_has_no_synthetic_work_or_acceptance_summary(tmp_path):
    c = PersonalConversation(tmp_path)
    mid = c.submit('request-casual-001', '你好')['message_id']
    c._record_tasks(mid, [{'id': 'think', 'title': '分析用户请求', 'status': 'done'},
                          {'id': 'reply', 'title': '撰写回复', 'status': 'done'}])
    c._finish(mid, 'completed', '你好')
    row = next(m for m in c.snapshot()['messages'] if m['id'] == mid)
    assert row['tasks'] == []
    assert row['summary'] is None
    assert row['work_events'] == []
