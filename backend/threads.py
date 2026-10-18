"""线索（2026-10-18）：把下一步、待办、航程、对话、执行会话、项目页串成一条线，每张卡片都能看到上下游并互相跳转。

节点统一写成「类型:ID」：
  next:<建议 id>  todo:<任务/待处理/x.md>  case:<task_id 或 turn:消息>  msg:<用户消息 id>  session:<sid>  project:<项目名>
关系在创建的地方记下（交给 Com、加到待办、对话派活、明天建议落地、航程结论回流），存 threads.sqlite；
另有两种隐式关系查询时现补：待办 →（关联项目）→ 项目页、航程 →（执行）→ Pi 会话。
展示信息（标题、状态、怎么打开）由 app.py 注入的 resolver 现查，线索本身不存业务数据。
"""
import sqlite3, time
from contextlib import contextmanager
from pathlib import Path

ORDER = {'msg': 0, 'next': 1, 'todo': 2, 'case': 3, 'session': 4, 'project': 5}


class Threads:
    def __init__(self, state, clock=time.time):
        self.path = Path(state) / 'threads.sqlite'
        self.clock = clock
        self.resolve = lambda key: None       # key -> {title, state, ...} 或 None（已不存在）
        self.implicit = lambda key: []        # key -> [(另一端 key, 关系)]
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS links(a TEXT NOT NULL, b TEXT NOT NULL, rel TEXT NOT NULL, at REAL NOT NULL, PRIMARY KEY(a, b))')
            db.execute('CREATE INDEX IF NOT EXISTS links_b ON links(b)')
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

    def link(self, a, b, rel):
        """a 在上游、b 在下游（a → b）。重复记一次无害。"""
        if not a or not b or a == b or a.endswith(':') or b.endswith(':'):
            return
        with self.db() as db:
            db.execute('INSERT OR IGNORE INTO links VALUES (?,?,?,?)', (a, b, rel, self.clock()))

    def _edges(self, key, implicit=None):
        with self.db() as db:
            rows = db.execute('SELECT a, b, rel FROM links WHERE a=? OR b=?', (key, key)).fetchall()
        edges = [(r['a'], r['b'], r['rel']) for r in rows]
        try:
            edges += [(key, other, rel) for other, rel in (implicit or self.implicit)(key)]
        except Exception:
            pass
        return edges

    def thread(self, key, depth=3, limit=12, resolve=None, implicit=None):
        """从 key 出发沿关系走 depth 步，返回整条线（按 对话→下一步→待办→航程→会话→项目 排好）。"""
        seen, frontier, edges = {key}, [key], set()
        for _ in range(depth):
            nxt = []
            for k in frontier:
                for a, b, rel in self._edges(k, implicit):
                    edges.add((a, b, rel))
                    for other in (a, b):
                        if other not in seen and len(seen) < limit:
                            seen.add(other)
                            nxt.append(other)
            frontier = nxt
        nodes = []
        for k in seen:
            try:
                info = (resolve or self.resolve)(k)
            except Exception:
                info = None
            if info is None and k != key:
                continue
            kind, _, ident = k.partition(':')
            nodes.append({'key': k, 'kind': kind, 'id': ident, 'current': k == key, **(info or {'title': ident, 'state': ''})})
        keys = {n['key'] for n in nodes}
        nodes.sort(key=lambda n: (ORDER.get(n['kind'], 9), n.get('at', 0)))
        return {'key': key, 'nodes': nodes,
                'edges': [{'from': a, 'to': b, 'rel': rel} for a, b, rel in sorted(edges) if a in keys and b in keys]}
