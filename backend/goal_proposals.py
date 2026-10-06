"""目标提案队列：合成器产出 → Eddie 在 Com! 勾选批准 → 落画像与行动台。

照 goals.py 的 sqlite 风格。两张表：
- proposals：合成器每次产出的一份提案（含 items/suspect/gaps）
- decisions：Eddie 的勾选结果，按 request_id 幂等

**为什么 decisions 按 request_id 去重**：手机端网络重试很常见，重复提交不能把同一份
提案落两遍库。首次记录后，重复请求直接返回旧结果，不再写文件。
"""
import json
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path


class GoalProposals:
    def __init__(self, state, clock=time.time):
        self.path = Path(state) / 'goal-proposals.sqlite'
        self.clock = clock
        with self.db() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS proposals(id TEXT PRIMARY KEY,day TEXT NOT NULL,
              mode TEXT NOT NULL,data TEXT NOT NULL,created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS decisions(id TEXT PRIMARY KEY,proposal_id TEXT NOT NULL,
              request_id TEXT NOT NULL UNIQUE,data TEXT NOT NULL,decided_at REAL NOT NULL);
            ''')
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                db.execute('BEGIN IMMEDIATE')
                yield db
        finally:
            db.close()

    @staticmethod
    def ident(mode, day):
        return f'{mode}-{day}'

    def create(self, day, result, mode='weekly'):
        """同日同模式幂等。已决策过的提案不再覆盖——Eddie 看过的内容不能被后台改写。"""
        ident = self.ident(mode, day)
        with self.db() as db:
            if db.execute('SELECT 1 FROM decisions WHERE proposal_id=?', (ident,)).fetchone():
                return self.get(ident, db)
            record = {
                'id': ident, 'day': day, 'mode': mode, 'created': self.clock(),
                'generated_at': result.get('generated_at', ''),
                'machines': result.get('machines', []),
                'items': result.get('items', []),
                'suspect': result.get('suspect', []),
                'gaps': result.get('gaps', []),
                'notes': result.get('notes', ''),
                'decision': None,
            }
            db.execute('INSERT OR REPLACE INTO proposals VALUES (?,?,?,?,?)',
                       (ident, day, mode, json.dumps(record, ensure_ascii=False), self.clock()))
        return record

    def get(self, proposal_id, db=None):
        if db is not None:
            return self._row(db, proposal_id)
        with self.db() as conn:
            return self._row(conn, proposal_id)

    @staticmethod
    def _row(db, proposal_id):
        row = db.execute('SELECT data FROM proposals WHERE id=?', (proposal_id,)).fetchone()
        if not row:
            return None
        record = json.loads(row[0])
        decision = db.execute('SELECT data FROM decisions WHERE proposal_id=?', (proposal_id,)).fetchone()
        record['decision'] = json.loads(decision[0]) if decision else None
        return record

    def list(self, limit=10):
        with self.db() as db:
            rows = db.execute('SELECT data FROM proposals ORDER BY created DESC LIMIT ?', (limit,)).fetchall()
            decisions = {r['proposal_id']: json.loads(r['data'])
                         for r in db.execute('SELECT proposal_id,data FROM decisions')}
        items = []
        for row in rows:
            record = json.loads(row[0])
            record['decision'] = decisions.get(record['id'])
            items.append(record)
        return items

    def decide(self, proposal_id, request_id, approved, rejected):
        """记录勾选结果。未知 id 一律忽略——客户端不该能凭猜 id 落任意条目。"""
        if not isinstance(request_id, str) or not request_id:
            raise ValueError('缺少有效请求标识')
        with self.db() as db:
            prior = db.execute('SELECT data FROM decisions WHERE request_id=?', (request_id,)).fetchone()
            if prior:
                return json.loads(prior[0])
            # 已决策的提案不再接受第二次审批：否则换个 request_id 就能重复落库。
            if db.execute('SELECT 1 FROM decisions WHERE proposal_id=?', (proposal_id,)).fetchone():
                raise ValueError('该提案已由另一次审批处理')
            row = db.execute('SELECT data FROM proposals WHERE id=?', (proposal_id,)).fetchone()
            if not row:
                raise ValueError('提案不存在')
            known = {item['id'] for item in json.loads(row[0]).get('items', [])}
            decision = {
                'proposal_id': proposal_id, 'request_id': request_id,
                'approved': [i for i in (approved or []) if i in known],
                'rejected': [i for i in (rejected or []) if i in known],
                'decided_at': self.clock(), 'applied': None,
            }
            db.execute('INSERT INTO decisions VALUES (?,?,?,?,?)',
                       (proposal_id + ':' + request_id, proposal_id, request_id,
                        json.dumps(decision, ensure_ascii=False), self.clock()))
        return decision

    def record_applied(self, proposal_id, request_id, applied):
        """落库完成后回填结果，卡片上据此显示回执。"""
        with self.db() as db:
            row = db.execute('SELECT data FROM decisions WHERE request_id=?', (request_id,)).fetchone()
            if not row:
                raise ValueError('决策不存在')
            decision = json.loads(row[0])
            decision['applied'] = applied
            db.execute('UPDATE decisions SET data=? WHERE request_id=?',
                       (json.dumps(decision, ensure_ascii=False), request_id))
        return decision
