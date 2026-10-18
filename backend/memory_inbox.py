"""Automatic memory from conversation: verify, then auto-write or queue for confirmation.

候选事实来自 conversation_summary 的同一次模型调用。这里只做确定性的分流：
- 原话必须逐字出现在该消息 ID 的 Eddie 原文里（role=user），否则丢弃；
- 临时任务、推测、测试对话、凭据类、命中敏感词的一律不写；
- 偏好 / 人物关系 / 固定日程习惯 / 在做的项目，且置信度高 → 直接写入 MemoryCatalog（Markdown 权威，
  带 source 引用，版本化），App 上可一键确认、纠正或删除（删除=归档，历史版本保留，可撤销）；
- 其余进收件箱等 Eddie 批准。
"""
import hashlib
import json
import re
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from memory import SENSITIVE
from memory_catalog import CATEGORIES, MemoryCatalog

AUTO_TYPES = {'preference': '关于我', 'relationship': '关于我', 'routine': '生活', 'project': '项目'}
REVIEW_TYPES = {'profile': '关于我'}
AUTO_CONFIDENCE = 0.8
TESTY = re.compile(r'^\s*(测试|test|ping|hello|hi|你好)[\s!！。.?？]*$', re.I)


def _norm(text):
    return re.sub(r'[\s，。、,.;；:：!！?？"“”\'‘’]+', '', str(text)).lower()


class MemoryInbox:
    def __init__(self, state, catalog=None, clock=time.time):
        self.path = Path(state) / 'memory-inbox.sqlite'
        self.catalog = catalog or MemoryCatalog()
        self.clock = clock
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,fingerprint TEXT UNIQUE,state TEXT,created REAL,data TEXT)')
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def _verify(self, fact, originals):
        """Returns (type, category, content, quote, message_id) or None when the fact must not be stored."""
        if not isinstance(fact, dict):
            return None
        kind = fact.get('type')
        if kind not in AUTO_TYPES and kind not in REVIEW_TYPES:
            return None  # temporary / speculation / test / credential / unknown
        content, quote, mid = (str(fact.get(k) or '').strip() for k in ('content', 'quote', 'message_id'))
        source = originals.get(mid)
        if not content or not quote or len(content) > 300 or len(quote) > 200 or not source:
            return None
        if source['role'] != 'user' or quote not in source['text'] or TESTY.match(source['text']):
            return None
        if SENSITIVE.search(content) or SENSITIVE.search(quote) or SENSITIVE.search(source['text']):
            return None
        category = fact.get('category') if fact.get('category') in CATEGORIES else (AUTO_TYPES.get(kind) or REVIEW_TYPES[kind])
        return kind, category, content, quote, mid

    def ingest(self, facts, originals, run=''):
        counts = {'auto': 0, 'pending': 0, 'dropped': 0}
        existing = {_norm(r['content']) for r in self.catalog.list(archived=True)}
        for fact in facts if isinstance(facts, list) else []:
            checked = self._verify(fact, originals)
            if not checked:
                counts['dropped'] += 1
                continue
            kind, category, content, quote, mid = checked
            fingerprint = hashlib.sha256(_norm(content).encode()).hexdigest()
            if _norm(content) in existing:
                counts['dropped'] += 1
                continue
            with self.db() as db:
                if db.execute('SELECT 1 FROM items WHERE fingerprint=?', (fingerprint,)).fetchone():
                    counts['dropped'] += 1
                    continue
            try:
                confidence = float(fact.get('confidence', 0))
            except (TypeError, ValueError):
                confidence = 0.0
            ident = 'learn_' + fingerprint[:24]
            data = {'id': ident, 'type': kind, 'category': category, 'content': content, 'quote': quote,
                    'message_id': mid, 'confidence': confidence, 'run': run}
            state = 'pending'
            if kind in AUTO_TYPES and confidence >= AUTO_CONFIDENCE:
                try:
                    saved = self.catalog.save(content, category, self._source(data))
                    data.update(memory_id=saved['id'], memory_version=saved['version'])
                    state = 'auto_saved'
                except ValueError:
                    state = 'pending'
            with self.db() as db:
                db.execute('INSERT OR IGNORE INTO items VALUES (?,?,?,?,?)',
                           (ident, fingerprint, state, self.clock(), json.dumps(data, ensure_ascii=False)))
            existing.add(_norm(content))
            counts['auto' if state == 'auto_saved' else 'pending'] += 1
        return counts

    @staticmethod
    def _source(data):
        return {'message_id': data['message_id'], 'quote': data['quote'], 'type': 'auto_learned',
                'fact_type': data['type'], 'learned_by': 'conversation_summary', 'run': data.get('run', '')}

    def _row(self, row):
        return {**json.loads(row['data']), 'state': row['state'], 'created_at': row['created']}

    def list(self, limit=10):
        with self.db() as db:
            learned = [self._row(r) for r in db.execute(
                "SELECT * FROM items WHERE state='auto_saved' ORDER BY created DESC LIMIT ?", (limit,))]
            pending = [self._row(r) for r in db.execute(
                "SELECT * FROM items WHERE state='pending' ORDER BY created DESC LIMIT ?", (limit * 2,))]
        return {'learned': learned, 'pending': pending}

    def get(self, ident):
        with self.db() as db:
            row = db.execute('SELECT * FROM items WHERE id=?', (ident,)).fetchone()
        if not row:
            raise ValueError('这条记忆已不存在，请刷新')
        return self._row(row)

    def _set(self, ident, state, **changes):
        item = self.get(ident)
        data = {k: v for k, v in {**item, **changes}.items() if k not in ('state', 'created_at')}
        with self.db() as db:
            db.execute('UPDATE items SET state=?,data=? WHERE id=?', (state, json.dumps(data, ensure_ascii=False), ident))
        return {**data, 'state': state}

    def act(self, ident, action, content=''):
        item = self.get(ident)
        state = item['state']
        if action == 'confirm':
            if state == 'auto_saved':
                return self._set(ident, 'confirmed')
            if state == 'pending':
                saved = self.catalog.save(item['content'], item['category'], self._source(item))
                return self._set(ident, 'confirmed', memory_id=saved['id'], memory_version=saved['version'])
        elif action == 'correct':
            content = str(content or '').strip()
            if not 1 <= len(content) <= 300:
                raise ValueError('请写下正确的内容')
            if state == 'pending':
                saved = self.catalog.save(content, item['category'], {**self._source(item), 'corrected_from': item['content']})
                return self._set(ident, 'corrected', content=content, memory_id=saved['id'], memory_version=saved['version'])
            if state in ('auto_saved', 'confirmed'):
                old = self.catalog.get(item['memory_id'])
                source = {'message_id': 'memory-correct:' + ident, 'quote': content, 'previous_source': old['source']}
                saved = self.catalog.save(content, old['category'], source, old['id'], old['kind'], old['version'], old['archived'])
                return self._set(ident, 'corrected', content=content, memory_version=saved['version'])
        elif action == 'delete':
            if state == 'pending':
                return self._set(ident, 'dismissed')
            if state in ('auto_saved', 'confirmed', 'corrected'):
                old = self.catalog.get(item['memory_id'])
                # Archive, never unlink: the Markdown keeps every version and can be restored.
                saved = self.catalog.save(old['content'], old['category'], old['source'], old['id'], old['kind'], old['version'], True)
                return self._set(ident, 'deleted', memory_version=saved['version'])
        else:
            raise ValueError('不支持的操作')
        raise ValueError('这条记忆已处理过')
