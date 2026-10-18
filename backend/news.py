"""今日简报里的个人资讯：每天早上抓一批，手动刷新时重抓；按 Eddie 的兴趣和反馈挑。

- 抓：豆包搜索（火山 SearchInfinity，Key 和 Codex 的 byted_search MCP 共用），每个领域几条查询，近一天优先、不够补近一周。
- 兴趣：Obsidian 收藏库的 tags 和最近收藏的标题、本体画像的身份段、他点开过和左滑掉的资讯。
- 挑：不在这里挑，交给「下一步」那次模型调用；这里只负责给候选和兴趣，并把左滑掉的拦掉。
"""
import hashlib, json, os, re, sqlite3, time, tomllib
from collections import Counter
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx

TZ = ZoneInfo('Asia/Shanghai')
SEARCH_URL = 'https://open.feedcoopapi.com/search_api/web_search'
TOPICS = {
    'AI 工具': ('Claude Anthropic 发布', 'OpenAI Codex ChatGPT 更新', '豆包 火山方舟 大模型 发布', 'AI 智能体 新工具'),
    '内容创作': ('视频号 创作者 新规', '抖音 创作者 规则 更新', '短视频 爆款 选题 趋势'),
}
SKIP_TAGS = {'收藏', 'MOC', 'AI与科技', '视频与创作', '户外与旅行', '生活与娱乐', 'App与UI设计'}


def _text(value, limit):
    return re.sub(r'\s+', ' ', str(value or '')).strip()[:limit]


def _search_key():
    if os.environ.get('WEB_SEARCH_API_KEY'):
        return os.environ['WEB_SEARCH_API_KEY']
    try:
        cfg = tomllib.loads((Path.home() / '.codex/config.toml').read_text())
        return cfg['mcp_servers']['byted_search']['env']['ASK_ECHO_SEARCH_INFINITY_API_KEY']
    except (OSError, KeyError, tomllib.TOMLDecodeError):
        return ''


def _front(text):
    """frontmatter 里的 tags（只认列表和行内两种写法）。"""
    m = re.match(r'^---\n([\s\S]*?)\n---', text)
    if not m:
        return []
    block = m.group(1)
    inline = re.search(r'^tags:\s*\[(.*)\]', block, re.M)
    if inline:
        return [t.strip().strip('"\'') for t in inline.group(1).split(',') if t.strip()]
    listed = re.search(r'^tags:\s*\n((?:\s+-\s*.+\n?)+)', block, re.M)
    return [t.strip().strip('"\'') for t in re.findall(r'-\s*(.+)', listed.group(1))] if listed else []


class News:
    def __init__(self, state, vault=None, profile=None, search=None, clock=time.time):
        self.path = Path(state) / 'news.sqlite'
        self.vault = Path(vault) if vault else None
        self.profile = Path(profile) if profile else None
        self.search = search or self._search
        self.clock = clock

    def db(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        db.execute('CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, data TEXT NOT NULL, day TEXT, fetched_at REAL)')
        db.execute('CREATE TABLE IF NOT EXISTS feedback(id TEXT PRIMARY KEY, action TEXT, title TEXT, site TEXT, at REAL)')
        return db

    def today(self):
        return datetime.fromtimestamp(self.clock(), TZ).date().isoformat()

    # ---------- 抓 ----------

    async def _search(self, query, time_range):
        key = _search_key()
        if not key:
            raise RuntimeError('没有豆包搜索 Key')
        body = {'Query': query, 'SearchType': 'web', 'Count': 8, 'NeedSummary': True, 'TimeRange': time_range}
        async with httpx.AsyncClient(timeout=20, trust_env=False) as client:
            r = await client.post(SEARCH_URL, json=body, headers={'Authorization': 'Bearer ' + key, 'X-Traffic-Tag': 'skill_web_search_common'})
            r.raise_for_status()
            return (r.json().get('Result') or {}).get('WebResults') or []

    async def fetch(self, force=False):
        """当天第一次（或手动刷新）才真去搜；其余时候用当天已抓的。单条查询失败不拖累别的。"""
        day = self.today()
        with self.db() as db:
            have = db.execute('SELECT count(*) n FROM items WHERE day=?', (day,)).fetchone()['n']
        if have and not force:
            return have
        found = {}
        for topic, queries in TOPICS.items():
            for query in queries:
                for time_range in ('OneDay', 'OneWeek'):
                    try:
                        rows = await self.search(query, time_range)
                    except Exception:
                        rows = []
                    for row in rows:
                        title, url = _text(row.get('Title'), 120), row.get('Url') or ''
                        if not title or not url:
                            continue
                        title = re.split(r'[|_]', title)[0].strip() or title
                        ident = hashlib.sha256(url.encode()).hexdigest()[:12]
                        found.setdefault(ident, {'id': ident, 'topic': topic, 'title': _text(title, 60), 'url': url, 'site': _text(row.get('SiteName'), 20),
                                                 'published': _text(row.get('PublishTime'), 25), 'summary': _text(row.get('Summary') or row.get('Snippet'), 220)})
                    if len(rows) >= 3:
                        break  # 近一天够了就不补近一周
        if not found:
            return have
        now = self.clock()
        with self.db() as db:
            db.execute('DELETE FROM items WHERE day=?', (day,))
            db.execute('DELETE FROM items WHERE fetched_at<?', (now - 14 * 86400,))
            for item in found.values():
                db.execute('INSERT OR REPLACE INTO items VALUES (?,?,?,?)', (item['id'], json.dumps(item, ensure_ascii=False), day, now))
        return len(found)

    # ---------- 给模型 ----------

    def candidates(self, limit=24):
        """今天抓的、没被左滑掉的，按发布时间新到旧。"""
        with self.db() as db:
            muted = {r['id'] for r in db.execute("SELECT id FROM feedback WHERE action='dismiss'")}
            rows = [json.loads(r['data']) for r in db.execute('SELECT data FROM items WHERE day=?', (self.today(),))]
        rows = [r for r in rows if r['id'] not in muted]
        rows.sort(key=lambda r: r.get('published', ''), reverse=True)
        return rows[:limit]

    def interests(self):
        """他喜欢看什么：收藏库高频 tag + 最近收藏 + 画像身份段 + 点开 / 左滑的资讯。"""
        out = {'topics': list(TOPICS), 'tags': [], 'recent_saves': [], 'identity': '', 'liked': [], 'disliked': []}
        if self.vault:
            folder = self.vault / '收藏库'
            notes = sorted(folder.rglob('*.md'), key=lambda p: p.stat().st_mtime, reverse=True) if folder.exists() else []
            tags = Counter()
            for i, path in enumerate(notes[:120]):
                if path.name.startswith('00-'):
                    continue
                weight = 2 if i < 30 else 1  # 最近收藏的权重高一点
                for tag in _front(path.read_text(encoding='utf-8', errors='ignore')[:1500]):
                    if tag not in SKIP_TAGS:
                        tags[tag] += weight
            out['tags'] = [t for t, _ in tags.most_common(20)]
            out['recent_saves'] = [_text(re.sub(r'\s*-\s*\d{6,}$', '', p.stem), 40) for p in notes if not p.name.startswith('00-')][:12]
        if self.profile and self.profile.exists():
            body = re.sub(r'^---[\s\S]*?\n---\n', '', self.profile.read_text(encoding='utf-8', errors='ignore'))
            out['identity'] = _text(body, 600)
        with self.db() as db:
            for r in db.execute('SELECT action, title, site FROM feedback ORDER BY at DESC LIMIT 40'):
                (out['liked'] if r['action'] == 'open' else out['disliked']).append(_text(r['title'], 40))
        out['liked'], out['disliked'] = out['liked'][:15], out['disliked'][:15]
        return out

    # ---------- 反馈 ----------

    def feedback(self, ident, action):
        if action not in ('open', 'dismiss'):
            raise ValueError('不支持的操作')
        with self.db() as db:
            row = db.execute('SELECT data FROM items WHERE id=?', (ident,)).fetchone()
            item = json.loads(row['data']) if row else {}
            old = db.execute('SELECT action FROM feedback WHERE id=?', (ident,)).fetchone()
            if old and old['action'] == 'dismiss' and action == 'open':
                return  # 左滑过的不因为误点又算喜欢
            db.execute('INSERT OR REPLACE INTO feedback VALUES (?,?,?,?,?)', (ident, action, item.get('title', ''), item.get('site', ''), self.clock()))

    def dismissed(self):
        with self.db() as db:
            return {r['id'] for r in db.execute("SELECT id FROM feedback WHERE action='dismiss'")}
