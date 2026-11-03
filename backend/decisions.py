"""决定账本（11-02，借鉴「定的事 / 定了不做的事」）：只记 Eddie 本人的决定，带原话和日期。

- decided：定下来的做法，随主对话注入，判断事件时也会带上，同样的问题不再问他。
- declined：他拒绝或划掉过的事，后台不再拿来烦他；不挡他亲口提的新要求。
写入只有四个入口：App 接口、划掉下一步、驳回审批卡、主对话工具（原话必须出自他当前这条消息）。
邮件、网页这类外部内容到不了这里。
"""
import json, re, sqlite3, time, uuid
from contextlib import closing, contextmanager
from pathlib import Path

KINDS = ('decided', 'declined')
BLOCK_CHARS = 900


def _clip(value, limit, name):
    value = str(value or '').strip()
    if not value:
        raise ValueError(f'{name} 不能为空')
    return value[:limit]


class Decisions:
    def __init__(self, state, clock=time.time):
        self.path = Path(state) / 'decisions.sqlite'
        self.clock = clock
        with self.db() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS decisions(
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, topic TEXT NOT NULL, rule TEXT NOT NULL DEFAULT '',
                    quote TEXT NOT NULL, source TEXT NOT NULL, source_ref TEXT NOT NULL,
                    decided_at REAL NOT NULL, revoked_at REAL, UNIQUE(source, source_ref));
                CREATE INDEX IF NOT EXISTS decisions_kind ON decisions(kind, revoked_at, decided_at);
                CREATE TABLE IF NOT EXISTS conclusions(
                    card_id TEXT PRIMARY KEY, title TEXT NOT NULL, text TEXT NOT NULL, at REAL NOT NULL);
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

    def add(self, kind, topic, quote, source, source_ref='', rule='', at=None):
        """同一来源同一引用只记一次，重复调用返回原记录。"""
        if kind not in KINDS:
            raise ValueError('kind 只能是 decided 或 declined')
        topic, quote, source = _clip(topic, 120, 'topic'), _clip(quote, 500, 'quote'), _clip(source, 40, 'source')
        ident = 'dec_' + uuid.uuid4().hex[:20]
        with self.db() as db:
            db.execute('INSERT OR IGNORE INTO decisions(id,kind,topic,rule,quote,source,source_ref,decided_at) VALUES(?,?,?,?,?,?,?,?)',
                       (ident, kind, topic, str(rule or '')[:500], quote, source, source_ref or ident, at or self.clock()))
            row = db.execute('SELECT * FROM decisions WHERE source=? AND source_ref=?', (source, source_ref or ident)).fetchone()
        return dict(row)

    def revoke(self, ident):
        with self.db() as db:
            cursor = db.execute('UPDATE decisions SET revoked_at=? WHERE id=? AND revoked_at IS NULL', (self.clock(), ident))
        if not cursor.rowcount:
            raise KeyError(ident)
        return {'id': ident, 'revoked': True}

    def items(self, kind='', limit=200):
        sql, args = 'SELECT * FROM decisions WHERE revoked_at IS NULL', []
        if kind:
            sql, args = sql + ' AND kind=?', [kind]
        with self.db() as db:
            return [dict(r) for r in db.execute(sql + ' ORDER BY decided_at DESC LIMIT ?', (*args, limit))]

    def declines(self, title):
        """返回拦住这个标题的那条决定；口径与下一步去重一致：几乎同一句，或点过两次的同话题。"""
        from next_steps import _cjk_runs, _near, muted_topics
        rows = self.items('declined', 1000)
        for row in rows:
            if _near(title or '', row['topic']):
                return row
        topics = muted_topics([r['topic'] for r in rows])
        hit = _cjk_runs(title or '') & topics
        return next((r for r in rows if _cjk_runs(r['topic']) & hit), None) if hit else None

    def relevant(self, text, limit=5):
        """和这段文字相关的已定事项，交给判断模型参考。"""
        from next_steps import _cjk_runs, _near
        grams = _cjk_runs(text or '')
        hits = [r for r in self.items('decided', 200) if _near(text or '', r['topic']) or grams & _cjk_runs(r['topic'] + r['rule'])]
        return [{'topic': r['topic'], 'rule': r['rule'], 'quote': r['quote']} for r in hits[:limit]]

    def conclude(self, card_id, title, text):
        """卡片点完后留下结论，「等你」里还能看到一天。"""
        with self.db() as db:
            db.execute('INSERT OR REPLACE INTO conclusions(card_id,title,text,at) VALUES(?,?,?,?)',
                       (card_id, str(title or '')[:120], str(text or '')[:300], self.clock()))

    def conclusions(self, within=86400, limit=5):
        with self.db() as db:
            rows = db.execute('SELECT * FROM conclusions WHERE at>=? ORDER BY at DESC LIMIT ?', (self.clock() - within, limit))
            return [{**dict(r), 'id': r['card_id']} for r in rows]


def ticket(recommend, basis, on_yes, on_no=''):
    """票拟：每张卡都回答三件事——建议怎么办、凭什么、点了会发生什么。"""
    clean = lambda value: str(value or '').strip()[:300]
    return {'recommend': clean(recommend), 'basis': clean(basis), 'on_yes': clean(on_yes), 'on_no': clean(on_no)}


NEXT_ACTION_RESULT = {'reply_mail': '打开写好的邮件草稿，发不发你定', 'bookkeep': '帮你记这一笔', 'calendar': '把它加进日程'}


def next_step_ticket(item):
    action = (item.get('action') or {}).get('type', '')
    return ticket(item.get('title'), item.get('why'), NEXT_ACTION_RESULT.get(action, '交给 Com 去办，进展在动态里看'), '这件事和同类的不再提')


def proposal_ticket(item):
    return ticket('这一步删掉就找不回来，建议先看清范围再批' if item.get('actual_action') else '看清范围再批', item.get('reason') or item.get('prompt'),
                  '按上面的范围执行：' + str(item.get('title') or ''), '不执行，后台不再提这件事')


def goal_ticket(item):
    count = len(item.get('items') or [])
    return ticket('勾选你真要做的目标' + (f'（共 {count} 条）' if count else ''), item.get('summary') or '从最近的对话里提取，只收你明确说过的',
                  '勾中的写进目标和行动台', '没勾的不写，也不再提')


def decisions_block(state):
    """给 context_builder 用的只读片段；出错不影响这一轮对话。"""
    path = Path(state) / 'decisions.sqlite'
    if not path.exists():
        return ''
    try:
        with closing(sqlite3.connect('file:' + str(path) + '?mode=ro', uri=True)) as db:
            rows = db.execute("SELECT topic,rule,decided_at FROM decisions WHERE kind='decided' AND revoked_at IS NULL ORDER BY decided_at DESC LIMIT 20").fetchall()
    except sqlite3.Error:
        rows = []
    head = '他明确拍板或拒绝某事时，用 decision_record 记下，source_quote 用他的原话。'
    if not rows:
        return head
    lines = ['他定过的事（照办，不要再问）：'] + [f"- {time.strftime('%m-%d', time.localtime(at))} {topic}：{rule}" for topic, rule, at in rows]
    return (head + '\n' + '\n'.join(lines))[:BLOCK_CHARS]


def seed_from_next_steps(ledger, rows):
    """把下一步里已经划掉的旧记录补进账本；可重复执行。「别人在负责」不算他不要这件事。"""
    done = 0
    for ident, raw, updated_at in rows:
        item = json.loads(raw)
        if item.get('dismiss_reason') == 'others' or not item.get('title'):
            continue
        ledger.add('declined', item['title'], '划掉下一步：' + item['title'], 'next_step', ident, at=updated_at)
        done += 1
    return done


def is_explicit_quote(quote, message):
    """原话必须真的来自他这条消息，而且不是几个字的碎片。"""
    quote = re.sub(r'\s+', '', str(quote or ''))
    return len(quote) >= 4 and quote in re.sub(r'\s+', '', str(message or ''))
