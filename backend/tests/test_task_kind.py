from work_cards import task_kind, linked_card

def test_manual_chat_is_not_a_linked_job():
    chat={'authorization':{'entry':'work_page_human_chat'}}
    assert task_kind(chat)=='chat'
    assert linked_card([chat]) == {'linked_tasks':[], 'work_events':[], 'results':[]}

def test_missing_origin_preserves_legacy_job():
    assert task_kind({})=='job'
