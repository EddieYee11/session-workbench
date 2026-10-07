"""Bind hidden Com source arguments to the native caller session, never global latest."""
import sqlite3
import json
import time
from pathlib import Path

SOURCE_TOOLS = {
    'create_task', 'task_submit', 'artifact_register', 'task_send', 'task_cancel',
    'task_resume', 'task_verify', 'task_merge', 'business_operation', 'memory_save',
    'update_task_constraints', 'calendar_adjust', 'device_call', 'cancel_task', 'propose_work',
}


def bind_source(*, tool_name='', session_id='', args=None, state=None, **_):
    # Hermes invokes this for the underlying deferred tool as well as direct tools.
    prefix = 'mcp__com_workbench__'
    if not tool_name.startswith(prefix) or tool_name[len(prefix):] not in SOURCE_TOOLS:
        return None
    if not session_id:
        return {'action': 'block', 'message': 'Com 调用缺少真实会话来源，请在原对话中继续。'}
    root = Path(state) if state else Path.home()/'.session-workbench'
    path = root/'hermes-runs.sqlite'
    rows=[]
    try:
        db=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=1)
        try:
            bindings=db.execute("""SELECT s.context FROM tool_sources s JOIN runs r ON r.request_id=s.request_id
                WHERE s.session_id=? AND r.session_id=s.session_id AND r.status IN ('admitting','running') LIMIT 2""",(session_id,)).fetchall()
            if len(bindings)==1:
                context=json.loads(bindings[0][0])
                values=tuple(context.get(k) for k in ('origin_session_id','origin_message_id','origin_request_id'))
                if all(isinstance(v,str) and v for v in values):rows=[values]
            # Never fall back to another user if a durable (even incomplete) binding exists.
            if bindings and not rows:return {'action':'block','message':'Com 本次运行的来源不完整或有冲突，未执行。'}
        finally:db.close()
    except ValueError:
        return {'action':'block','message':'Com 运行来源记录无法验证，未执行。'}
    except (OSError,sqlite3.Error):
        pass
    if not rows:
        path=root/'personal-conversation.sqlite'
        try:
            db = sqlite3.connect(path.as_uri()+'?mode=ro', uri=True, timeout=1)
            try:
                rows = db.execute('''SELECT t.session_id,t.message_id,t.request_id
                    FROM reaction_turns t JOIN messages m ON m.id=t.message_id
                    WHERE t.session_id=? AND t.expires_at>? AND m.role='user'
                    AND m.status IN ('sending','running') AND m.request_id=t.request_id LIMIT 2''',
                    (session_id, time.time())).fetchall()
            finally:db.close()
        except (OSError,sqlite3.Error):rows=[]
    if len(rows) != 1:
        return {'action': 'block', 'message': 'Com 没有唯一有效的本轮用户来源；未执行，请回到原交办继续。'}
    return {'action': 'modify', 'args': dict(zip(
        ('origin_session_id','origin_message_id','origin_request_id'), rows[0]))}
