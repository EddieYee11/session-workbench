"""Private, idempotent uploads for files the owner explicitly selects in Com."""
import asyncio
import hashlib
import json
import re
import sqlite3
import time
from contextlib import closing
from pathlib import Path
from urllib.parse import unquote

from fastapi import APIRouter, HTTPException, Request

MAX_BYTES = 20 * 1024 * 1024
IDENTIFIER = re.compile(r'^[a-f0-9-]{36}$')


class AttachmentStore:
    def __init__(self, state):
        self.root = Path(state) / 'attachments'
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db_path = self.root / 'index.sqlite'
        with closing(sqlite3.connect(self.db_path)) as db:
            db.execute('CREATE TABLE IF NOT EXISTS attachments(id TEXT PRIMARY KEY, data TEXT NOT NULL)')
            db.commit()
        self.db_path.chmod(0o600)

    def save(self, ident, filename, mime, content):
        if not IDENTIFIER.fullmatch(ident):
            raise ValueError('附件标识无效')
        if not content or len(content) > MAX_BYTES:
            raise ValueError('附件为空或超过 20 MB')
        name = Path(unquote(filename).replace('\\', '/')).name
        while len(name.encode('utf-8')) > 220: name = name[:-1]
        if not name or name in ('.', '..'):
            raise ValueError('附件名称无效')
        digest = hashlib.sha256(content).hexdigest()
        with closing(sqlite3.connect(self.db_path, timeout=20)) as db:
            db.execute('BEGIN IMMEDIATE')
            old = db.execute('SELECT data FROM attachments WHERE id=?', (ident,)).fetchone()
            if old:
                result = json.loads(old[0])
                if result['sha256'] != digest or result['name'] != name or result['mime'] != mime:
                    raise ValueError('附件标识冲突')
                return result
            folder = self.root / ident
            folder.mkdir(mode=0o700, exist_ok=True)
            target = folder / name
            target.write_bytes(content)
            target.chmod(0o600)
            result = {'id': ident, 'name': name, 'mime': mime[:120], 'size': len(content),
                      'sha256': digest, 'path': str(target), 'created_at': time.time(),
                      'authority': 'user_selected_external_reference'}
            db.execute('INSERT INTO attachments VALUES(?,?)', (ident, json.dumps(result, ensure_ascii=False)))
            db.commit()
            return result

    def resolve(self, ids):
        if not isinstance(ids, list) or len(ids) > 8 or any(not isinstance(i, str) or not IDENTIFIER.fullmatch(i) for i in ids):
            raise ValueError('附件列表无效，最多八个附件')
        rows = []
        with closing(sqlite3.connect(self.db_path)) as db:
            for ident in dict.fromkeys(ids):
                record = db.execute('SELECT data FROM attachments WHERE id=?', (ident,)).fetchone()
                if not record:
                    raise ValueError('附件不存在')
                row = json.loads(record[0]); path = Path(row['path'])
                if path.is_symlink() or not path.resolve().is_relative_to(self.root.resolve()) or not path.is_file():
                    raise ValueError('附件文件不可用')
                if hashlib.sha256(path.read_bytes()).hexdigest() != row['sha256']:
                    raise ValueError('附件内容已改变')
                rows.append(row)
        return rows


def attachment_router(store):
    router = APIRouter()

    @router.post('/personal/attachments/{ident}')
    async def upload(ident: str, request: Request):
        if not IDENTIFIER.fullmatch(ident):
            raise HTTPException(400, '附件标识无效')
        content = bytearray()
        async for chunk in request.stream():
            if len(content) + len(chunk) > MAX_BYTES:
                raise HTTPException(413, '附件超过 20 MB')
            content.extend(chunk)
        try:
            row = await asyncio.to_thread(store.save, ident, request.headers.get('x-filename', ''),
                             request.headers.get('content-type', 'application/octet-stream'), bytes(content))
        except ValueError as exc:
            raise HTTPException(409 if '冲突' in str(exc) else 400, str(exc)) from exc
        return {k: v for k, v in row.items() if k not in ('path', 'authority')}

    return router
