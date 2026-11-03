"""Trigger 账本（2026-11-01，借鉴 DeepSeek Super-agent 的 Trigger/Thread）。

每个事项新增或实质变化时记一条不可变事件，同一内容只记一次。这里只记录，不行动。
外部正文一律是数据，判断见 evals.py。

11-02 加事项层（event_matters）：同一条线索或几乎同一句标题的事件算一件事，跨来源也归到一起，
比如同一件事同时出现在苹果日历和手机提醒。判断按事项走。
"""
import hashlib, json, re, sqlite3, time, uuid
from contextlib import contextmanager
from pathlib import Path

# 这些字段每次采集都变，不算内容变化（短信、微信采集包带生成时间）。
VOLATILE = {'generated_at', 'window_start', 'window_end', 'updated_at', 'latest_in_db'}
SUMMARY_LIMIT = 4000
# 标题相近只在这个时间内算同一件事：隔几天的重复日程是新的一次。
NEAR_WINDOW = 3 * 86400
# 这么久没新事件的事项关闭，再来就算新事项。
IDLE_CLOSE = 14 * 86400
RANK = {'': 0, 'ignore': 1, 'notify': 2, 'accept': 3}
SUBJECT_PREFIX = re.compile(r'^(?:\s*(?:re|fw|fwd|回复|答复|转发)\s*[:：]\s*|\s*【[^】]{1,8}】\s*)+', re.I)


def normalize_title(title):
    return SUBJECT_PREFIX.sub('', title or '').strip()


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
                CREATE TABLE IF NOT EXISTS event_matters(
                    id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'open',
                    outcome TEXT NOT NULL DEFAULT '', merged_into TEXT NOT NULL DEFAULT '', last_eval_at REAL NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS event_matters_open ON event_matters(state, updated_at);
            ''')
            for table in ('triggers', 'evals'):
                if 'matter_id' not in {r['name'] for r in db.execute(f'PRAGMA table_info({table})')}:
                    db.execute(f"ALTER TABLE {table} ADD COLUMN matter_id TEXT NOT NULL DEFAULT ''")
        self.backfill_matters()
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

    def assign_matter(self, trigger):
        """给一条事件定事项：同线索优先，其次是近几天内几乎同一句的标题，都没有就新开一件。"""
        from next_steps import _near
        if trigger['matter_id']:
            return trigger['matter_id']
        now = self.clock()
        title = normalize_title(trigger['title'])
        with self.db() as db:
            row = db.execute("SELECT t.matter_id FROM triggers t JOIN event_matters m ON m.id=t.matter_id "
                             "WHERE t.thread_key=? AND m.state='open' ORDER BY t.received_at DESC LIMIT 1", (trigger['thread_key'],)).fetchone()
            ident = row['matter_id'] if row else ''
            if not ident:
                near = db.execute("SELECT id,title FROM event_matters WHERE state='open' AND updated_at>=? ORDER BY updated_at DESC", (now - NEAR_WINDOW,)).fetchall()
                ident = next((m['id'] for m in near if _near(title, m['title'])), '')
            if ident:
                db.execute('UPDATE event_matters SET updated_at=? WHERE id=?', (now, ident))
            else:
                ident = 'emt_' + uuid.uuid4().hex[:20]
                db.execute('INSERT INTO event_matters(id,title,created_at,updated_at) VALUES(?,?,?,?)', (ident, title[:200], now, now))
            db.execute('UPDATE triggers SET matter_id=? WHERE id=?', (ident, trigger['id']))
        return ident

    def merge_matter(self, source_id, target_id):
        """判断模型认出两件其实是一件时合并；判断结果取较重的。"""
        now = self.clock()
        with self.db() as db:
            rows = {r['id']: r for r in db.execute('SELECT * FROM event_matters WHERE id IN (?,?)', (source_id, target_id))}
            if source_id == target_id or set(rows) != {source_id, target_id} or rows[target_id]['state'] != 'open':
                return False
            outcome = max(rows[source_id]['outcome'], rows[target_id]['outcome'], key=lambda o: RANK.get(o, 0))
            db.execute('UPDATE triggers SET matter_id=? WHERE matter_id=?', (target_id, source_id))
            db.execute('UPDATE evals SET matter_id=? WHERE matter_id=?', (target_id, source_id))
            db.execute("UPDATE event_matters SET state='merged',merged_into=?,updated_at=? WHERE id=?", (target_id, now, source_id))
            db.execute('UPDATE event_matters SET outcome=?,updated_at=? WHERE id=?', (outcome, now, target_id))
        return True

    def note_outcome(self, ident, outcome):
        """事项还开着就不降级：判过 accept 的事，后面一次 ignore 不算撤销，否则同一件事会来回翻。"""
        now = self.clock()
        with self.db() as db:
            row = db.execute('SELECT outcome FROM event_matters WHERE id=?', (ident,)).fetchone()
            if not row:
                return ''
            kept = max(row['outcome'], outcome, key=lambda o: RANK.get(o, 0))
            db.execute('UPDATE event_matters SET outcome=?,last_eval_at=?,updated_at=? WHERE id=?', (kept, now, now, ident))
        return kept

    def close_idle(self):
        with self.db() as db:
            return db.execute("UPDATE event_matters SET state='closed' WHERE state='open' AND updated_at<?", (self.clock() - IDLE_CLOSE,)).rowcount

    def backfill_matters(self):
        """已判断过的旧事件补上事项，只在升级后第一次有活干。"""
        with self.db() as db:
            rows = db.execute("SELECT t.*,e.outcome AS judged,e.finished_at AS judged_at,e.id AS judged_id FROM triggers t JOIN evals e ON e.id=t.eval_id "
                              "WHERE t.matter_id='' ORDER BY t.received_at, t.rowid").fetchall()
        real_clock = self.clock
        try:
            for row in rows:
                # 按事件当时的时间归并，避免所有旧事件都落进「最近三天」的窗口。
                self.clock = lambda at=row['received_at']: at
                ident = self.assign_matter(row)
                self.clock = lambda at=row['judged_at']: at
                self.note_outcome(ident, row['judged'] if row['judged'] in RANK else '')
                with self.db() as db:
                    db.execute('UPDATE evals SET matter_id=? WHERE id=?', (ident, row['judged_id']))
        finally:
            self.clock = real_clock
        return len(rows)

    def open_matters(self, exclude='', limit=20):
        with self.db() as db:
            rows = db.execute("SELECT id,title,outcome FROM event_matters WHERE state='open' AND id!=? ORDER BY updated_at DESC LIMIT ?", (exclude, limit))
            return [dict(r) for r in rows]

    def matter_counts(self):
        with self.db() as db:
            return {r[0]: r[1] for r in db.execute('SELECT state,COUNT(*) FROM event_matters GROUP BY 1')}

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
                'SELECT t.id,t.matter_id,t.source,t.thread_key,t.actor,t.title,t.summary,t.occurred_at,t.received_at,t.disposition,t.reason AS filter_reason,'
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
                'matters': self.matter_counts(),
            }
