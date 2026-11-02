"""Trigger 账本（2026-11-01，借鉴 DeepSeek Super-agent 的 Trigger/Thread）。

每个事项新增或实质变化时记一条不可变事件，同一内容只记一次。这里只记录，不行动。
外部正文一律是数据，判断见 evals.py。
"""
import hashlib, json, sqlite3, time
from contextlib import contextmanager
from pathlib import Path

# 这些字段每次采集都变，不算内容变化（短信、微信采集包带生成时间）。
VOLATILE = {'generated_at', 'window_start', 'window_end', 'updated_at', 'latest_in_db'}
SUMMARY_LIMIT = 4000


def fingerprint(title, facts):
    stable = {k: v for k, v in facts.items() if k not in VOLATILE} if isinstance(facts, dict) else facts
    return hashlib.sha256(json.dumps([title, stable], sort_keys=True, ensure_ascii=False, default=str).encode()).hexdigest()


class Triggers:
    def __init__(self, state, clock=time.time):
        self.path = Path(state) / 'triggers.sqlite'
        self.clock = clock
        with self.db() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS triggers(
                    id TEXT PRIMARY KEY, source TEXT NOT NULL, source_id TEXT NOT NULL, thread_key TEXT NOT NULL,
                    actor TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '',
                    empty INTEGER NOT NULL DEFAULT 0, occurred_at REAL NOT NULL, received_at REAL NOT NULL,
                    disposition TEXT NOT NULL DEFAULT 'queued', reason TEXT NOT NULL DEFAULT '',
                    eval_id TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS triggers_due ON triggers(disposition, received_at);
                CREATE INDEX IF NOT EXISTS triggers_thread ON triggers(thread_key, received_at);
                CREATE TABLE IF NOT EXISTS evals(
                    id TEXT PRIMARY KEY, thread_key TEXT NOT NULL, trigger_ids TEXT NOT NULL, outcome TEXT NOT NULL,
                    reason TEXT NOT NULL DEFAULT '', proposed TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '',
                    started_at REAL NOT NULL, finished_at REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS evals_thread ON evals(thread_key, finished_at);
            ''')
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

    def record(self, matter):
        """幂等写入，返回 trigger id；同一内容已记过时返回 None。"""
        source, source_id = matter['source'], matter['source_id']
        title, facts = matter.get('title', ''), matter.get('facts') or {}
        ident = 'trg_' + hashlib.sha256(f'{source}:{source_id}:{fingerprint(title, facts)}'.encode()).hexdigest()[:24]
        actor = str(facts.get('from', ''))[:300] if isinstance(facts, dict) else ''
        # 采集包里批次为空（如「短信 · 0 条」）：有这个字段且是空的才算。
        empty = isinstance(facts, dict) and any(k in facts and not facts[k] for k in ('messages', 'chats'))
        summary = json.dumps(facts, ensure_ascii=False, default=str)[:SUMMARY_LIMIT]
        now = self.clock()
        with self.db() as db:
            cursor = db.execute(
                'INSERT OR IGNORE INTO triggers(id,source,source_id,thread_key,actor,title,summary,empty,occurred_at,received_at) '
                'VALUES(?,?,?,?,?,?,?,?,?,?)',
                (ident, source, source_id, f'{source}:{source_id}', actor, title, summary, int(empty),
                 matter.get('source_updated_at') or now, now))
        return ident if cursor.rowcount else None

    def items(self, limit=50, outcome='', source=''):
        where, args = [], []
        if outcome:
            where.append('COALESCE(e.outcome, t.disposition)=?')
            args.append(outcome)
        if source:
            where.append('t.source=?')
            args.append(source)
        clause = 'WHERE ' + ' AND '.join(where) if where else ''
        with self.db() as db:
            rows = db.execute(
                'SELECT t.id,t.source,t.thread_key,t.actor,t.title,t.summary,t.occurred_at,t.received_at,t.disposition,t.reason AS filter_reason,'
                'e.id AS eval_id,e.outcome,e.reason,e.proposed,e.error '
                f'FROM triggers t LEFT JOIN evals e ON e.id=t.eval_id {clause} ORDER BY t.received_at DESC, t.rowid DESC LIMIT ?',
                (*args, limit)).fetchall()
        return [dict(r) for r in rows]

    def stats(self, days=7):
        since = self.clock() - days * 86400
        with self.db() as db:
            def counts(sql):
                return {r[0]: r[1] for r in db.execute(sql, (since,))}
            return {
                'days': days,
                'by_source': counts('SELECT source,COUNT(*) FROM triggers WHERE received_at>=? GROUP BY 1'),
                'by_disposition': counts('SELECT disposition,COUNT(*) FROM triggers WHERE received_at>=? GROUP BY 1'),
                'filter_reasons': counts("SELECT reason,COUNT(*) FROM triggers WHERE received_at>=? AND disposition='filtered' GROUP BY 1"),
                'outcomes': counts('SELECT outcome,COUNT(*) FROM evals WHERE finished_at>=? GROUP BY 1'),
            }
