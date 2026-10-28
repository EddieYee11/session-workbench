from cases import Cases


def test_acceptance_marks_covered_missing_and_manual_criteria():
    task = {'status': 'execution_finished', 'verification_status': 'unverified',
            'work_brief': {'completion_condition': '测试通过并列出上线步骤'},
            'acceptance_criteria': [{'id': 'c1', 'description': '受影响测试跑通'}, {'id': 'c2', 'description': '改期后不产生重复文件'},
                                    {'id': 'c3', 'description': '列出需 Eddie 授权的上线/重启步骤'}],
            'structured_result': {'evidence': [{'criterion_id': 'c1', 'reference': 'pytest -q tests', 'check': 'tests', 'passed': True}]},
            'quality_review': {'verdict': 'revise', 'reason': 'c2 没证据', 'evidence_gaps': [{'criterion_id': 'c2', 'missing_evidence': '没有改期后的文件列表'}], 'next_steps': ['跑一次改期']}}
    a = Cases.acceptance(task, {'evidence': ['生成了 2 个待办文件']})
    assert [c['state'] for c in a['criteria']] == ['covered', 'missing', 'manual']
    assert a['criteria'][0]['evidence'] == [{'reference': 'pytest -q tests', 'check': 'tests'}]
    assert a['completion'] == '测试通过并列出上线步骤' and a['reported'] == ['生成了 2 个待办文件']
    assert a['review']['verdict'] == 'revise' and a['review']['gaps'] == ['没有改期后的文件列表']


def test_acceptance_without_criteria_still_has_completion_and_no_review():
    a = Cases.acceptance({'status': 'running'}, {'completion': '回复草稿能直接发'})
    assert a == {'completion': '回复草稿能直接发', 'status': 'pending', 'criteria': [], 'reported': [], 'review': None}
