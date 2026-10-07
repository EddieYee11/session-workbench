"""Isolated end-to-end check: schedule item -> durable event -> real model turn -> conversation receipt.

Runs against the live Hermes runtime with its own session and its own state directory, so it never
writes into the live Com conversation. Run only on mini.
"""
import asyncio
import json
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from background_events import BackgroundEvents
from conversation import HermesClient, PersonalConversation
from goals import GoalEvents
from proactive import Proactive
from tasks import TaskStore

LIVE = Path.home() / '.session-workbench'
SESSION = 'com-proactive-verify'


class VerifyClient(HermesClient):
    runtime_name = 'hermes'
    session_key = 'hermes_session_id'

    async def create_session(self):
        try:
            await self.request('POST', '/api/sessions',
                               {'id': SESSION, 'source': 'api_server', 'title': 'Com 主动消息验收'})
        except RuntimeError as exc:
            if str(exc) != 'hermes_api_409':
                raise
        return SESSION


async def main():
    state = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        '/Users/eddiegao/.hermes/profiles/com-personal/cache/scratch') / time.strftime('proactive-verify-%Y%m%d-%H%M%S')
    state.mkdir(parents=True, exist_ok=True)
    key = state / 'hermes-api-key'
    shutil.copy2(LIVE / 'hermes-api-key', key)
    key.chmod(0o600)
    events = GoalEvents(state)
    queued = Proactive(state).fire(events, 'evening-review')
    conversation = PersonalConversation(state, VerifyClient(state))
    consumer = BackgroundEvents(events, conversation, TaskStore(state))
    rounds = 0
    while await consumer.process():
        rounds += 1
        if rounds > 3:
            break
    with events.db() as db:
        events_state = [tuple(row) for row in db.execute('SELECT id,kind,state FROM events')]
    with conversation.db() as db:
        messages = [dict(row) for row in db.execute(
            'SELECT role,status,request_id,text,origin_agent FROM messages ORDER BY created_at')]
    print(json.dumps({'state': str(state), 'session': SESSION, 'queued': queued, 'rounds': rounds,
                      'events': events_state, 'messages': messages}, ensure_ascii=False, indent=2))


asyncio.run(main())
