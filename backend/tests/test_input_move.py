import pytest
from conversation import PersonalConversation
from tasks import TaskStore

def fixture(tmp_path,state):
 store=TaskStore(tmp_path);chat=PersonalConversation(tmp_path)
 task=store.create_authorized({'title':'原任务','prompt':'做事情','origin_message_id':'mid','agent':'codex','cwd':str(tmp_path)}, {'source_quote':'做事情'}, 'original-request-001')
 store.enqueue(task['id'],'保持原样','supplement-request-001')
 if state!='pending_start':store.transition_input('supplement-request-001',('pending_start',),state)
 return store,chat,task

@pytest.mark.parametrize('state,revoked',[('pending_start',True),('queued',True),('sending',False),('delivered',False),('unknown',False)])
def test_move_respects_delivery_and_retries(tmp_path,state,revoked):
 store,chat,task=fixture(tmp_path,state)
 a=store.move_input(task['id'],'supplement-request-001','new-matter-request-001',chat)
 b=store.move_input(task['id'],'supplement-request-001','new-matter-request-001',chat)
 assert a['revoked'] is revoked and b['message_id']==a['message_id']
 current=store.list()[0]
 assert current['inputs'][0]['state']==('revoked' if revoked else state)
 if revoked:assert '保持原样' not in store.execution_prompt(current)
 with pytest.raises(ValueError):store.move_input(task['id'],'supplement-request-001','new-matter-request-002',chat)


def test_new_item_preserves_body_and_explicit_intent(tmp_path):
 store,chat,task=fixture(tmp_path,'queued')
 receipt=store.move_input(task['id'],'supplement-request-001','new-matter-request-001',chat)
 with chat.db() as db:row=dict(db.execute('SELECT * FROM messages WHERE id=?',(receipt['message_id'],)).fetchone())
 text,context=chat._pi_input(row,'real-session','real-token')
 assert row['text']=='保持原样' and context['new_item']['task_id']==task['id']
 assert '本条独立处理' in text
