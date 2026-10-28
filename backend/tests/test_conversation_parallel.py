"""10-28 并行：一轮长任务在跑时，新消息另开一条线立刻处理，结果各自回到原消息下。"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conversation import PersonalConversation


async def until(predicate):
    async with asyncio.timeout(3):
        while not predicate():
            await asyncio.sleep(.01)


class LaneFixture:
    runtime_name = 'legacy-lane'
    session_key = 'hermes_v2_session_id'
    has_native_history = True

    def __init__(self, gates, seen, n=0):
        self.gates, self.seen, self.n = gates, seen, n
        self.aborted = False

    def lane(self, n):
        return LaneFixture(self.gates, self.seen, n)

    def key(self):
        return 'k'

    async def create_session(self):
        return 'main'

    async def abort(self):
        self.aborted = True

    async def stream_chat(self, session_id, text):
        word = text.rsplit('\n', 1)[-1]
        self.seen.append((word, self.n))
        yield 'run.started', {'run_id': 'run-' + word}
        await self.gates.setdefault(word, asyncio.Event()).wait()
        yield 'assistant.completed', {'content': '答复 ' + word}
        yield 'run.completed', {}
        yield 'done', {}


def rows(conversation):
    with conversation.db() as db:
        return {r['text']: dict(r) for r in db.execute('SELECT * FROM messages')}


def test_second_message_runs_while_first_is_still_working(tmp_path):
    async def scenario():
        gates, seen = {}, []
        conversation = PersonalConversation(tmp_path, LaneFixture(gates, seen))
        conversation.start()
        try:
            conversation.submit('request-long-0001', '长任务')
            await until(lambda: ('长任务', 0) in seen)
            conversation.submit('request-quick-0002', '快问题')
            # 第一轮没放行，第二轮已经在另一条线上开跑并先答完
            await until(lambda: ('快问题', 1) in seen)
            gates['快问题'].set()
            await until(lambda: rows(conversation).get('答复 快问题'))
            assert rows(conversation)['长任务']['status'] == 'running'
            gates['长任务'].set()
            await until(lambda: rows(conversation)['长任务']['status'] == 'completed')
            data = rows(conversation)
            assert data['答复 长任务']['parent_id'] == data['长任务']['id']
            assert data['答复 快问题']['parent_id'] == data['快问题']['id']
            assert data['快问题']['status'] == 'completed'
        finally:
            await conversation.stop()
    asyncio.run(scenario())


def test_interrupt_one_turn_keeps_the_other(tmp_path):
    async def scenario():
        gates, seen = {}, []
        conversation = PersonalConversation(tmp_path, LaneFixture(gates, seen))
        conversation.start()
        try:
            first = conversation.submit('request-aaaa-0001', '甲')['message_id']
            await until(lambda: len(seen) == 1)
            conversation.submit('request-bbbb-0002', '乙')
            await until(lambda: len(seen) == 2)
            client = conversation.turn_clients[first]
            assert await conversation.interrupt(first) == [first]
            assert client.aborted
            assert rows(conversation)['甲']['status'] == 'unknown'
            assert rows(conversation)['乙']['status'] == 'running'
            gates['乙'].set()
            await until(lambda: rows(conversation)['乙']['status'] == 'completed')
        finally:
            await conversation.stop()
    asyncio.run(scenario())


def test_parallel_cap_queues_the_fourth(tmp_path):
    async def scenario():
        gates, seen = {}, []
        conversation = PersonalConversation(tmp_path, LaneFixture(gates, seen))
        conversation.start()
        try:
            for i, word in enumerate('一二三四'):
                conversation.submit(f'request-cap-{i:05d}', word)
            await until(lambda: len(seen) == 3)
            await asyncio.sleep(.2)
            assert [w for w, _ in seen] == ['一', '二', '三']
            gates['一'].set()
            await until(lambda: len(seen) == 4)
            assert seen[-1] == ('四', 0)  # 空出来的那条线被复用
            for word in '二三四':
                gates[word].set()
            await until(lambda: all(rows(conversation)[w]['status'] == 'completed' for w in '一二三四'))
        finally:
            await conversation.stop()
    asyncio.run(scenario())
