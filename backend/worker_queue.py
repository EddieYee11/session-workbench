"""机器接单队列（11-02）：MBP 没有可靠的入站通道，所以由它主动长轮询 mini 领活，一次最长等 50 秒。

活的种类写死，没有「执行任意命令」这一项：ping 测通路，pi_readonly 调 MBP 上的 pi（默认只读）。
建活只有 App 接口一个入口，事件判断和外部内容到不了这里。
领走后超时没回音记 unknown，不自动重跑，免得同一件事做两遍。
"""
import asyncio, json, sqlite3, time, uuid
from contextlib import contextmanager
from pathlib import Path

KINDS = {'ping', 'pi_readonly'}
MACHINES = {'mbp'}
LEASE = 15 * 60
MAX_WAIT = 50
PROMPT_LIMIT = 8000
RESULT_LIMIT = 20000


class WorkerQueue:
    def __init__(self, state, clock=time.time):
        self.path = Path(state) / 'worker-queue.sqlite'
        self.clock = clock
        self.events = {}
        with self.db() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS jobs(
                id TEXT PRIMARY KEY, machine TEXT NOT NULL, kind TEXT NOT NULL, prompt TEXT NOT NULL DEFAULT '',
                state TEXT NOT NULL DEFAULT 'queued', result TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
                claimed_at REAL, finished_at REAL)''')
            db.execute('''CREATE TABLE IF NOT EXISTS machines(name TEXT PRIMARY KEY, last_seen REAL NOT NULL)''')
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def create(self, machine, kind, prompt=''):
        if machine not in MACHINES or kind not in KINDS:
            raise ValueError('不支持的机器或活')
        prompt = str(prompt or '').strip()
        if kind == 'pi_readonly' and not prompt:
            raise ValueError('pi_readonly 需要 prompt')
        ident = 'job_' + uuid.uuid4().hex[:20]
        with self.db() as db:
            db.execute('INSERT INTO jobs(id,machine,kind,prompt,created_at) VALUES(?,?,?,?,?)', (ident, machine, kind, prompt[:PROMPT_LIMIT], self.clock()))
        if machine in self.events:
            self.events[machine].set()
        return self.get(ident)

    def get(self, ident):
        with self.db() as db:
            row = db.execute('SELECT * FROM jobs WHERE id=?', (ident,)).fetchone()
        if not row:
            raise KeyError(ident)
        return dict(row)

    def _take(self, machine):
        now = self.clock()
        with self.db() as db:
            db.execute("UPDATE jobs SET state='unknown',finished_at=? WHERE state='claimed' AND claimed_at<?", (now, now - LEASE))
            db.execute('INSERT OR REPLACE INTO machines(name,last_seen) VALUES(?,?)', (machine, now))
            row = db.execute("SELECT * FROM jobs WHERE machine=? AND state='queued' ORDER BY created_at LIMIT 1", (machine,)).fetchone()
            if not row:
                return None
            db.execute("UPDATE jobs SET state='claimed',claimed_at=? WHERE id=?", (now, row['id']))
        return {k: row[k] for k in ('id', 'kind', 'prompt')}

    async def claim(self, machine, wait=MAX_WAIT):
        """有活立刻给，没活挂到 wait 秒后返回 None。"""
        if machine not in MACHINES:
            raise ValueError('未知机器')
        deadline = time.monotonic() + max(0, min(wait, MAX_WAIT))
        event = self.events.setdefault(machine, asyncio.Event())
        while True:
            job = self._take(machine)
            remaining = deadline - time.monotonic()
            if job or remaining <= 0:
                return job
            event.clear()
            try:
                await asyncio.wait_for(event.wait(), remaining)
            except asyncio.TimeoutError:
                pass

    def finish(self, ident, machine, ok, result):
        with self.db() as db:
            cursor = db.execute("UPDATE jobs SET state=?,result=?,finished_at=? WHERE id=? AND machine=? AND state='claimed'",
                                ('done' if ok else 'failed', str(result or '')[:RESULT_LIMIT], self.clock(), ident, machine))
        if not cursor.rowcount:
            raise KeyError(ident)
        return self.get(ident)

    def status(self):
        with self.db() as db:
            machines = {r['name']: r['last_seen'] for r in db.execute('SELECT * FROM machines')}
            jobs = [dict(r) for r in db.execute('SELECT id,machine,kind,state,created_at,finished_at FROM jobs ORDER BY created_at DESC LIMIT 20')]
        return {'machines': machines, 'jobs': jobs}
