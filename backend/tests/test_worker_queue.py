import asyncio
import pytest
from worker_queue import LEASE, WorkerQueue

NOW = 2_000_000_000.0


def test_only_fixed_kinds_and_known_machines(tmp_path):
    queue = WorkerQueue(tmp_path)
    for args in [('mbp', 'shell', 'rm -rf /'), ('mini', 'ping'), ('mbp', 'pi_readonly', '')]:
        with pytest.raises(ValueError):
            queue.create(*args)


def test_claim_is_exclusive_and_result_only_once(tmp_path):
    queue = WorkerQueue(tmp_path)
    job = queue.create('mbp', 'ping')

    async def go():
        return await queue.claim('mbp', 0), await queue.claim('mbp', 0)
    first, second = asyncio.run(go())
    assert first['id'] == job['id'] and second is None
    assert queue.finish(job['id'], 'mbp', True, 'pong')['state'] == 'done'
    with pytest.raises(KeyError):
        queue.finish(job['id'], 'mbp', True, 'again')


def test_long_poll_wakes_immediately_when_a_job_arrives(tmp_path):
    queue = WorkerQueue(tmp_path)

    async def go():
        waiter = asyncio.create_task(queue.claim('mbp', 5))
        await asyncio.sleep(0.05)
        started = asyncio.get_running_loop().time()
        queue.create('mbp', 'ping')
        job = await waiter
        return job, asyncio.get_running_loop().time() - started
    job, elapsed = asyncio.run(go())
    assert job['kind'] == 'ping' and elapsed < 1


def test_expired_lease_becomes_unknown_and_is_not_rerun(tmp_path):
    now = [NOW]
    queue = WorkerQueue(tmp_path, clock=lambda: now[0])
    job = queue.create('mbp', 'ping')
    asyncio.run(queue.claim('mbp', 0))
    now[0] += LEASE + 1
    assert asyncio.run(queue.claim('mbp', 0)) is None
    assert queue.get(job['id'])['state'] == 'unknown'
