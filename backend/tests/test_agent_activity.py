from agent_activity import AgentEventProjector, tool_activity


def frame(messages=(), runs=(), tasks=(), event='update'):
    return {'event': event, 'data': {'messages': list(messages), 'runs': list(runs), 'changed_tasks': list(tasks)}}


def message(ident, status='completed', at=1):
    return {'id':ident,'role':'assistant','status':status,'text':'真实的回复','created_at':at}


def test_delivery_is_a_new_receipt_not_history_or_repeated_update():
    projector=AgentEventProjector()
    assert not any(e['event']=='agent.push' for e in projector.project(frame([message('old')]))[1])
    _,events=projector.project(frame([message('new',at=2)]))
    assert [e['data']['message_id'] for e in events if e['event']=='agent.push']==['new']
    assert not any(e['event']=='agent.push' for e in projector.project(frame([message('new',at=2)]))[1])
    assert not any(e['event']=='agent.push' for e in AgentEventProjector().project(frame([message('new',at=2)],event='snapshot'))[1])


def test_tool_end_settles_and_failed_reply_never_delivers():
    projector=AgentEventProjector()
    assert projector.project(frame(runs=[{'id':'r','status':'running','active_tool':'mcp__web_search'}]))[0]['kind']=='searching'
    assert projector.project(frame(runs=[{'id':'r','status':'running','phase':'thinking'}]))[0]['kind']=='thinking'
    activity,events=projector.project(frame([message('failed','failed')]))
    assert activity['kind']=='failed'
    assert not any(e['event']=='agent.push' for e in events)
    assert 'retry_count' not in activity
    assert projector.project(frame([message('next',at=2)]))[0]['kind']=='idle'


def test_background_review_retains_until_explicit_terminal_update():
    projector=AgentEventProjector()
    assert projector.project(frame(tasks=[{'id':'t','status':'approval_required'}]))[1][0]['event']=='task.review'
    assert projector.project(frame())[0]['kind']=='review'
    assert projector.project(frame(tasks=[{'id':'t','status':'done'}]))[0]['kind']=='idle'


def test_real_run_priority_and_unknown_honesty():
    projector=AgentEventProjector()
    assert projector.project(frame(runs=[{'id':'r','status':'unknown'}]))[0]['kind']=='waiting'
    assert tool_activity('unknown_private_tool')=='working'
    assert tool_activity('memory_recall')=='remembering'
    assert tool_activity('write_file')=='writing'


def test_old_unknown_run_does_not_keep_stage_busy_after_a_new_answer():
    projector=AgentEventProjector()
    activity,_=projector.project(frame([message('new',at=100)], runs=[{'message_id':'old','status':'unknown'}]))
    assert activity['kind']=='idle'


def test_latest_failure_update_wins_over_earlier_partial_reply():
    projector=AgentEventProjector()
    partial=message('partial','streaming',at=2)
    projector.project(frame([partial]))
    failed={'id':'user','role':'user','status':'failed','created_at':1,'updated_at':3}
    assert projector.project(frame([failed]))[0]['kind']=='failed'


def test_label_merges_repeated_steps_and_names_pi_tools():
    from event_copy import current_step, group_steps
    tools=[{'id':f'tool-{i}','kind':'tool','tool':'grep','status':'done'} for i in range(6)]
    groups=group_steps(tools+[{'id':'tool-x','kind':'tool','tool':'react_to_user_message','status':'done'}])
    assert [g['done_text'] for g in groups]==['翻了 6 处资料']
    running={'id':'u','role':'user','status':'running','tasks':tools[:5]+[dict(tools[5],status='running')]}
    assert current_step(running)=='翻了 6 处资料…'
    projector=AgentEventProjector()
    activity,_=projector.project(frame([running],runs=[{'message_id':'u','status':'running','active_tool':'grep'}]))
    assert activity['kind']=='searching' and activity['label']=='翻了 6 处资料…'
    assert tool_activity('read')=='searching' and tool_activity('edit')=='writing' and tool_activity('bash')=='working'


def test_live_copy_rotates_and_never_repeats_the_generic_phrase():
    from event_copy import display_event
    texts={display_event({'kind':'tool.started','tool':'read_file','id':f'e{i}'}) for i in range(12)}
    assert len(texts)>1 and '正在查看相关资料' not in texts
    assert display_event({'kind':'tool.completed','tool':'bookkeeping'})=='已收到处理回执'
