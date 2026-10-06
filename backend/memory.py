"""Markdown is authoritative; Hindsight is a disposable, source-checked index."""
import asyncio
import hashlib
import json
import os
import re
import time
from pathlib import Path
from urllib.parse import quote
import httpx

ROOT = Path(os.environ.get('COM_MEMORY_WORKSPACE', str(Path.home() / 'AI_Work_System')))
STATE = Path(os.environ.get('COM_MEMORY_STATE', str(Path.home() / '.com-memory')))
URL = os.environ.get('COM_MEMORY_URL', 'http://127.0.0.1:8888')
ROUTES = {
    'personal-main': ['_global/本体画像/*.md', '_global/记忆库/知识/**/*.md', '_global/记忆库/事件/**/*.md', '_global/记忆库/Com/mem_*.md'],
    'project-com': ['work/工具与效率/会话工作台/README.md', 'work/工具与效率/会话工作台/docs/**/*.md'],
}
POLICY_VERSION = 'markdown-no-secrets-v2'
SENSITIVE = re.compile(r'密码|口令|密钥|验证码|登录态|凭据|password|passwd|secret|api[_ -]?key|access[_ -]?token|auth[_ -]?token|authorization|bearer|cookie|sk-[A-Za-z0-9]|https?://[^/\s]+:[^/@\s]+@', re.I)

def sanitize(text):
    # Omit whole fenced blocks with credential fields, then sensitive lines.
    text = re.sub(r'```[^\n]*\n.*?```', lambda m: '[已排除敏感配置块]' if SENSITIVE.search(m.group()) else m.group(), text, flags=re.S)
    return '\n'.join(line for line in text.splitlines() if not SENSITIVE.search(line))

EXCLUDED = {'.git', '_archive', 'node_modules', '.claude', '.codex'}

def digest(content):
    return hashlib.sha256(content).hexdigest()

def sources(root=ROOT):
    result = {}
    for bank, patterns in ROUTES.items():
        for pattern in patterns:
            for path in root.glob(pattern):
                relative = path.relative_to(root)
                if 'memory-reflections' in relative.parts or path.is_symlink() or set(relative.parts) & EXCLUDED or 'sync-conflict' in path.name:
                    continue
                if not path.is_file() or path.stat().st_size > 512 * 1024:
                    continue
                if 'Com' in relative.parts and '"archived": true' in path.read_text():
                    continue
                result[(bank, relative.as_posix())] = path
    return result

async def request(method, bank, suffix='', body=None, timeout=8):
    async with httpx.AsyncClient(timeout=timeout, trust_env=False) as client:
        response = await client.request(method, URL + '/v1/default/banks/' + quote(bank, safe='') + suffix, json=body)
        if method == 'DELETE' and response.status_code == 404:
            return {}
        response.raise_for_status()
        return response.json() if response.content else {}

def valid_result(row, bank, allowed):
    relative = (row.get('metadata') or {}).get('source_path')
    sha = (row.get('metadata') or {}).get('source_sha256')
    path = allowed.get((bank, relative))
    if not path or not sha or (row.get('metadata') or {}).get('policy_version') != POLICY_VERSION or SENSITIVE.search(row.get('text', '')):
        return None
    try:
        if digest(path.read_bytes()) != sha:
            return None
    except OSError:
        return None
    score = (row.get('scores') or {}).get('reranker')
    if score is not None and score < 0.03:
        return None
    return {'text': row['text'], 'source': relative, 'sha256': sha, 'bank': bank, 'relevance': score or 0}

def status():
    manifest_path = STATE / 'manifest.json'
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, ValueError):
        manifest = {}
    allowed = sources()
    counts = {bank: 0 for bank in ROUTES}
    pending = 0
    for (bank, relative), path in allowed.items():
        record = manifest.get(bank + ':' + relative, {})
        try:
            fresh = record.get('policy_version') == POLICY_VERSION and record.get('sha256') == digest(path.read_bytes())
        except OSError:
            fresh = False
        if fresh: counts[bank] += 1
        else: pending += 1
    return {'authority': 'Markdown', 'banks': counts, 'source_documents': len(allowed),
            'pending_documents': pending, 'policy_version': POLICY_VERSION, 'interval_seconds': 60}

async def recall(query, banks=None):
    query = str(query).strip()[:3000]
    if not query:
        return {'status': 'empty', 'items': []}
    banks = banks or list(ROUTES)
    if not isinstance(banks, list) or not banks or any(b not in ROUTES for b in banks):
        raise ValueError('未知记忆 bank')
    allowed = sources()
    async def one(bank):
        data = await request('POST', bank, '/memories/recall', {'query': query, 'budget': 'low', 'max_tokens': 1200, 'types': ['world', 'experience']})
        return [valid for row in data.get('results', []) if (valid := valid_result(row, bank, allowed))]
    responses = await asyncio.gather(*(one(bank) for bank in banks), return_exceptions=True)
    items, failed = [], []
    for bank, response in zip(banks, responses):
        if isinstance(response, BaseException):
            failed.append(bank)
        else:
            items.extend(response)
    return {'status': 'unavailable' if len(failed) == len(banks) else 'partial' if failed else 'ok',
            'items': sorted(items, key=lambda item: item['relevance'], reverse=True)[:8], 'unavailable_banks': failed, 'authority': 'Markdown'}

async def sync_once(root=ROOT, state=STATE):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    manifest_path = state / 'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    current = sources(root)
    changed = 0
    def save():
        temporary = manifest_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        temporary.chmod(0o600)
        temporary.replace(manifest_path)
    for (bank, relative), path in sorted(current.items(), key=lambda item: (0 if item[1].name == "00-核心身份.md" else 1 if item[1].name == "MARKDOWN_HINDSIGHT_MEMORY.md" else 2 if item[1].name == "README.md" else 3, item[0])):
        key = bank + ':' + relative
        content = path.read_bytes()
        sha = digest(content)
        if manifest.get(key, {}).get('sha256') == sha and manifest[key].get('policy_version') == POLICY_VERSION:
            continue
        # Stable document IDs make timeout retries idempotent and replacement
        # removes earlier facts rather than accumulating competing versions.
        doc = 'md-' + digest(relative.encode())
        indexed_text = sanitize(content.decode('utf-8'))
        if relative.startswith('_global/记忆库/Com/'):
            active = json.loads(content.decode().split('```json\n', 1)[1].split('\n```', 1)[0])
            indexed_text = active['category'] + '：' + active['content'] + '\n来源：' + json.dumps(active['source'],ensure_ascii=False)
        try:
            await request('DELETE', bank, '/documents/' + doc, timeout=60)
            await request('POST', bank, '/memories', {'items': [{'content': indexed_text,
                'document_id': doc, 'context': 'Markdown权威资料；来源：' + relative,
                'metadata': {'source_path': relative, 'source_sha256': sha, 'policy_version': POLICY_VERSION}, 'tags': ['markdown-authority']}], 'async': False}, timeout=300)
        except Exception as error:
            print(json.dumps({'document_error': type(error).__name__, 'source': relative, 'http_status': error.response.status_code if isinstance(error, httpx.HTTPStatusError) else None}, ensure_ascii=False), flush=True)
            continue
        manifest[key] = {'sha256': sha, 'document_id': doc, 'bank': bank, 'source': relative, 'synced_at': time.time(), 'policy_version': POLICY_VERSION}
        save()
        changed += 1
        print(json.dumps({'indexed': relative, 'bank': bank, 'changed': changed}, ensure_ascii=False), flush=True)
    for key, record in list(manifest.items()):
        if (record['bank'], record['source']) not in current:
            await request('DELETE', record['bank'], '/documents/' + record['document_id'], timeout=60)
            del manifest[key]
            save()
    return {'changed': changed, 'documents': len(manifest)}

async def sync_loop():
    while True:
        try:
            print(json.dumps(await sync_once()), flush=True)
        except Exception as error:
            # Do not log credential-bearing HTTP bodies.
            print(json.dumps({'sync_error': type(error).__name__, 'http_status': error.response.status_code if isinstance(error, httpx.HTTPStatusError) else None}), flush=True)
        await asyncio.sleep(60)

async def reflect_to_markdown(query, bank):
    if bank not in ROUTES:
        raise ValueError('未知记忆 bank')
    result = await request('POST', bank, '/reflect', {'query': query, 'budget': 'low'}, timeout=120)
    folder = ROOT / 'work/工具与效率/会话工作台/docs/memory-reflections'
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / (time.strftime('%Y%m%d-%H%M%S') + '-' + digest(query.encode())[:8] + '.md')
    target.write_text('# 记忆提炼草稿\n\n> 模型推断，待核对原始 Markdown；不是新增事实。\n\n银行：' + bank + '\n\n问题：' + query + '\n\n' + result.get('text', '') + '\n')
    return str(target)

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['sync', 'watch', 'recall', 'reflect'])
    parser.add_argument('query', nargs='?', default='')
    parser.add_argument('--bank', choices=list(ROUTES), default='personal-main')
    args = parser.parse_args()
    if args.action == 'watch': asyncio.run(sync_loop())
    elif args.action == 'sync': print(asyncio.run(sync_once()))
    elif args.action == 'reflect': print(asyncio.run(reflect_to_markdown(args.query, args.bank)))
    else: print(json.dumps(asyncio.run(recall(args.query)), ensure_ascii=False, indent=2))
