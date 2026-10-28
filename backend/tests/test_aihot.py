import asyncio
import sys
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from aihot import AIHot

HOT = {'items': [{'rank': 1, 'id': 't1', 'title': '某模型发布', 'source': {'name': '官方博客'},
                  'links': {'aihot': 'https://aihot.news/items/t1', 'original': 'https://x/1'}, 'sourceCount': 9,
                  'sourceNames': ['A', 'B'], 'latestAt': '2026-10-28T07:00:00Z'}]}
ITEMS = {'items': [{'id': 'i1', 'title': '精选一条', 'summary': '摘要', 'category': 'tip', 'source': {'name': 'X'},
                    'links': {'aihot': 'https://aihot.news/items/i1'}, 'score': 80, 'publishedAt': '2026-10-28T08:00:00Z'}]}


def test_snapshot_caches_and_falls_back(tmp_path):
    calls = {'n': 0, 'fail': False}

    def handler(request):
        calls['n'] += 1
        assert request.headers['user-agent'].startswith('aihot-api/2.0.0')
        if calls['fail']:
            return httpx.Response(503)
        return httpx.Response(200, json=HOT if request.url.path.endswith('/hot-topics') else ITEMS)

    now = [1000.0]
    hot = AIHot(tmp_path, transport=httpx.MockTransport(handler), clock=lambda: now[0])

    async def scenario():
        first = await hot.snapshot()
        assert first['topics'][0]['title'] == '某模型发布' and first['topics'][0]['source_count'] == 9
        assert first['items'][0]['category_label'] == '教程' and not first['stale']
        await hot.snapshot()
        assert calls['n'] == 2  # 15 分钟内用缓存
        now[0] += 3600
        calls['fail'] = True
        stale = await hot.snapshot()
        assert stale['stale'] and stale['items'][0]['title'] == '精选一条'
        again = AIHot(tmp_path, transport=httpx.MockTransport(handler), clock=lambda: now[0])
        assert (await again.snapshot())['topics']  # 重启后先用落盘的旧结果
    asyncio.run(scenario())
