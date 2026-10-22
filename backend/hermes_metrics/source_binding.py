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
KEYS = ('origin_session_id', 'origin_message_id', 'origin_request_id')


def _origin(context):
    """One durable binding as an origin triple, or None when it is unusable."""
    try:
        values = json.loads(context)
    except ValueError:
        return None
    if not isinstance(values, dict):
        return None
    row = tuple(values.get(key) for key in KEYS)
    return row if all(isinstance(value, str) and value for value in row) else None


def _live_turn(root, session_id):
    """This session's single in-flight turn, or None when ambiguous or unreadable."""
    path = root/'personal-conversation.sqlite'
    try:
        db = sqlite3.connect(path.as_uri()+'?mode=ro', uri=True, timeout=1)
        try:
            rows = db.execute('''SELECT t.session_id,t.message_id,t.request_id
                FROM reaction_turns t JOIN messages m ON m.id=t.message_id
                WHERE t.session_id=? AND t.expires_at>? AND m.role='user'
                AND m.status IN ('sending','running') AND m.request_id=t.request_id LIMIT 2''',
                (session_id, time.time())).fetchall()
        finally:
            db.close()
    except (ValueError, OSError, sqlite3.Error):
        return None
    return rows[0] if len(rows) == 1 else None


def _bound_runs(root, session_id):
    path = root/'hermes-runs.sqlite'
    db = sqlite3.connect(path.as_uri()+'?mode=ro', uri=True, timeout=1)
    try:
        return db.execute("""SELECT s.context FROM tool_sources s JOIN runs r ON r.request_id=s.request_id
            WHERE s.session_id=? AND r.session_id=s.session_id AND r.status IN ('admitting','running')""",
            (session_id,)).fetchall()
    finally:
        db.close()


def _resolve(rows, live):
    """The live turn's own binding wins; a superseded sibling must never block it.

    A worker killed mid-run leaves both its ``runs`` row and its durable binding behind,
    so two bindings for one session are not proof of ambiguity: whichever one belongs to
    the current in-flight turn is still that turn's exact source. Anything else stays a
    hard stop instead of guessing.
    """
    sources = [row for row in (_origin(context) for (context,) in rows) if row]
    if live:
        matched = [row for row in sources if row[1] == live[1]]
        if len(matched) == 1:
            return matched[0]
    if len(rows) == 1 and len(sources) == 1:
        return sources[0]
    return None


def bind_source(*, tool_name='', session_id='', args=None, state=None, **_):
    # Hermes invokes this for the underlying deferred tool as well as direct tools.
    prefix = 'mcp__com_workbench__'
    if not tool_name.startswith(prefix) or tool_name[len(prefix):] not in SOURCE_TOOLS:
        return None
    if not session_id:
        return {'action': 'block', 'message': 'Com 调用缺少真实会话来源，请在原对话中继续。'}
    root = Path(state) if state else Path.home()/'.session-workbench'
    live = _live_turn(root, session_id)
    try:
        rows = _bound_runs(root, session_id)
    except ValueError:
        return {'action': 'block', 'message': 'Com 运行来源记录无法验证，未执行。'}
    except (OSError, sqlite3.Error):
        rows = []
    resolved = _resolve(rows, live)
    if resolved is not None:
        return {'action': 'modify', 'args': dict(zip(KEYS, resolved))}
    # Never fall back to another user if a durable (even incomplete) binding exists.
    if rows:
        return {'action': 'block', 'message': 'Com 本次运行的来源不完整或有冲突，未执行。'}
    if not live:
        return {'action': 'block', 'message': 'Com 没有唯一有效的本轮用户来源；未执行，请回到原交办继续。'}
    return {'action': 'modify', 'args': dict(zip(KEYS, live))}
