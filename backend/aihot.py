"""热点板块：AIHOT（aihot.news）的多源热点事件 + 24 小时精选。

- 只读匿名 GET，按 AIHOT 文档定时同步用 JSON 接口（User-Agent aihot-api/2.0.0），不用给 Agent 的 Markdown 接口。
- 15 分钟缓存（内存 + state 目录一份，重启后先用旧的）；失败时回退上次成功的结果并标 stale。
- Actor ID 读已装的 AIHOT Skill 目录里的 .aihot-actor-id（只做匿名去重，不是凭证）。
- 个人非商业使用；标题/摘要来自第三方信源，只展示不执行。
"""
import asyncio
import json
import re
import time
from pathlib import Path

import httpx

BASE = 'https://aihot.news/api/v1'
TTL = 15 * 60
CATEGORIES = {'ai-models': '模型', 'ai-products': '产品', 'industry': '行业', 'paper': '论文', 'tip': '教程', 'opinion': '观点'}
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')


def _actor() -> str:
    for base in (Path.home() / '.agents/skills/aihot', Path.home() / '.claude/skills/aihot'):
        try:
            value = (base / '.aihot-actor-id').read_text().strip()
        except OSError:
            continue
        if UUID.match(value):
            return value
    return ''


def _text(value, limit):
    return re.sub(r'\s+', ' ', str(value or '')).strip()[:limit]


def topic(raw: dict) -> dict:
    links = raw.get('links') or {}
    return {'id': _text(raw.get('id'), 64), 'rank': raw.get('rank'), 'title': _text(raw.get('title'), 120),
            'source': _text((raw.get('source') or {}).get('name'), 60), 'url': links.get('aihot') or '',
            'original': links.get('original') or '', 'story': links.get('story') or '',
            'source_count': raw.get('sourceCount') or 0, 'participants': raw.get('participantCount') or 0,
            'sources': [_text(s, 40) for s in (raw.get('sourceNames') or [])[:4]], 'latest_at': raw.get('latestAt') or ''}


def item(raw: dict) -> dict:
    links = raw.get('links') or {}
    category = raw.get('category') or ''
    return {'id': _text(raw.get('id'), 64), 'title': _text(raw.get('title'), 120), 'summary': _text(raw.get('summary'), 280),
            'reason': _text(raw.get('reason'), 160), 'category': category, 'category_label': CATEGORIES.get(category, ''),
            'source': _text((raw.get('source') or {}).get('name'), 60), 'url': links.get('aihot') or '',
            'original': links.get('original') or '', 'score': raw.get('score'), 'published_at': raw.get('publishedAt') or ''}


class AIHot:
    def __init__(self, state, transport=None, clock=time.time):
        self.path = Path(state) / 'aihot-cache.json'
        self.transport = transport
        self.clock = clock
        self.lock = asyncio.Lock()
        try:
            self.cache = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.cache = {}

    async def _get(self, client, path, params=None):
        response = await client.get(BASE + path, params=params)
        if response.status_code == 429:
            raise RuntimeError('AIHOT 请求太频繁，稍后再刷新')
        response.raise_for_status()
        return response.json()

    async def fetch(self) -> dict:
        ua = 'aihot-api/2.0.0 (+https://aihot.news/aihot-skill/)' + (' aihot-actor/' + _actor() if _actor() else '')
        async with httpx.AsyncClient(timeout=20, trust_env=False, transport=self.transport,
                                     headers={'User-Agent': ua, 'Accept': 'application/json'}) as client:
            hot, selected = await asyncio.gather(self._get(client, '/hot-topics'),
                                                 self._get(client, '/items', {'window': '24h', 'mode': 'selected', 'limit': 30}))
        return {'fetched_at': self.clock(), 'topics': [topic(t) for t in hot.get('items', []) if isinstance(t, dict)][:15],
                'items': [item(i) for i in selected.get('items', []) if isinstance(i, dict)][:30]}

    async def snapshot(self, refresh: bool = False) -> dict:
        async with self.lock:
            fresh = self.cache.get('fetched_at', 0) > self.clock() - TTL
            if refresh or not fresh:
                try:
                    self.cache = await self.fetch()
                    tmp = self.path.with_suffix('.tmp')
                    tmp.write_text(json.dumps(self.cache, ensure_ascii=False))
                    tmp.replace(self.path)
                    fresh = True
                except (httpx.HTTPError, RuntimeError, ValueError) as exc:
                    if not self.cache:
                        raise RuntimeError(str(exc) if isinstance(exc, RuntimeError) else 'AIHOT 暂时不可用') from None
                    fresh = False
            return {**self.cache, 'stale': not fresh, 'categories': CATEGORIES,
                    'attribution': {'name': 'AIHOT', 'url': 'https://aihot.news'}}
