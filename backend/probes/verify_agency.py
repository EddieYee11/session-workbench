"""Isolated real-Hermes check of the new report queue, without touching live chat.
Run on mini with its existing Hermes service. Uses only a clearly labeled fixture.
"""
import asyncio,json,shutil,sys,time
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from agency import Agency
from personal_hub import PersonalHub
from goals import GoalEvents
from proactive import Proactive
from tasks import TaskStore
from conversation import PersonalConversation

async def main():
    live=Path.home()/'.session-workbench'
    state=live/'verification'/time.strftime('agency-%Y%m%d-%H%M%S')
    state.mkdir(parents=True,exist_ok=True);state.chmod(0o700)
    shutil.copy2(live/'hermes-api-key',state/'hermes-api-key')
    (state/'hermes-api-key').chmod(0o600)
    try:
        hub=PersonalHub(state,state)
        hub.matter('gmail','fixture-only','验收资料：确认样片范围',{'snippet':'仅用于验收：样片范围待确认，没有真实截止日期。'})
        events=GoalEvents(state);proactive=Proactive(state)
        conversation=PersonalConversation(state,SimpleNamespace())
        agency=Agency(state,hub,events,TaskStore(state),proactive,conversation)
        proactive.fire(events,'morning-briefing')
        started=time.monotonic();await agency.process()
        result=agency.snapshot()
        print(json.dumps({'seconds':round(time.monotonic()-started,1),'runs':result['runs'],
                          'reports':result['reports'],'prepared':len([c for c in result['cards'] if c.get('preparation')])},ensure_ascii=False,indent=2))
        if result['runs'][0]['status']!='completed':raise SystemExit(1)
    finally:(state/'hermes-api-key').unlink(missing_ok=True)

asyncio.run(main())
