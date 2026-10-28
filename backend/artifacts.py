"""Authenticated single-owner access to registered task artifacts, never arbitrary paths."""
import sqlite3
import json
import time
from contextlib import closing
import os
import hashlib
import mimetypes
import re
from pathlib import Path

# 回复正文里提到的工作区文件（`work/航程产出/…html`、`~/AI_Work_System/work/…`）：自动登记成可点开的成果。
TEXT_PATH = re.compile(r'(?:~/AI_Work_System/|/Users/[^/\s]+/AI_Work_System/)?((?:work|research|life|projects)/[^\s`\'"“”「」（）()，。、；]+?\.(?:html|md|pdf|png|jpe?g|csv|xlsx|docx|pptx))')
OUTPUTS = Path('work') / '航程产出'
SHELF = {'.html', '.md', '.pdf', '.png', '.jpg', '.jpeg'}
ALLOWED = {'.pdf','.png','.jpg','.jpeg','.webp','.gif','.md','.html','.txt','.csv','.docx','.xlsx','.pptx','.mov','.mp4','.patch'}
class ArtifactAccess:
    def __init__(self, tasks, workspace, state=None):
        self.tasks, self.workspace = tasks, Path(workspace).resolve()
        self.path=Path(state)/'artifacts.sqlite' if state else None
        if self.path:
            with closing(sqlite3.connect(self.path)) as db:
                db.execute('CREATE TABLE IF NOT EXISTS artifacts(id TEXT PRIMARY KEY, data TEXT NOT NULL)')
                # 10-25：可交互产出（勾选、展开）的状态，按文件名存，手机和网页共用
                db.execute('CREATE TABLE IF NOT EXISTS artifact_state(key TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at REAL NOT NULL)');db.commit()
            self.path.chmod(0o600)

    def register(self, message_id, relative_path):
        raw=Path(relative_path)
        if not raw.is_absolute():raw=self.workspace/raw
        path=self._safe(raw)
        aid='art_'+hashlib.sha256(('message:'+message_id+'\0'+str(path)).encode()).hexdigest()[:32]
        if self.path is None:raise RuntimeError('成果登记未配置')
        value={'id':aid,'message_id':message_id,'path':str(path),'created_at':time.time()}
        with closing(sqlite3.connect(self.path)) as db:
            old=db.execute('SELECT data FROM artifacts WHERE id=?',(aid,)).fetchone()
            if old:value=json.loads(old[0])
            else:db.execute('INSERT INTO artifacts VALUES (?,?)',(aid,json.dumps(value,ensure_ascii=False)));db.commit()
        return self._record({'id':'','message_id':message_id,'created_at':value['created_at']}, {'path':str(path)},path,aid)


    def link_text(self, message_id, text):
        """正文里提到的文件逐个登记；不在工作区、不存在、类型不允许的跳过。"""
        out, seen = [], set()
        for rel in TEXT_PATH.findall(text or ''):
            if rel in seen:
                continue
            seen.add(rel)
            try:
                out.append(self.register(message_id, rel))
            except (PermissionError, FileNotFoundError, OSError):
                continue
        return out

    def state(self, key):
        with closing(sqlite3.connect(self.path)) as db:
            row = db.execute('SELECT data, updated_at FROM artifact_state WHERE key=?', (key,)).fetchone()
        return {'key': key, 'state': json.loads(row[0]) if row else {}, 'updated_at': row[1] if row else 0}

    def save_state(self, key, state):
        if not key or len(key) > 300 or not isinstance(state, dict) or len(json.dumps(state)) > 64 * 1024:
            raise ValueError('状态无效')
        now = time.time()
        with closing(sqlite3.connect(self.path)) as db:
            db.execute('INSERT OR REPLACE INTO artifact_state VALUES (?,?,?)', (key, json.dumps(state, ensure_ascii=False), now)); db.commit()
        return {'key': key, 'state': state, 'updated_at': now}

    def _entries(self):
        if self.path:
            with closing(sqlite3.connect(self.path)) as db:
                records=[json.loads(r[0]) for r in db.execute('SELECT data FROM artifacts')]
            for row in records:
                yield {'id':'','message_id':row['message_id'],'created_at':row['created_at']},row,Path(row['path']),row['id']
        for task in self.tasks.list():
            artifacts = task.get('artifacts') or (task.get('structured_result') or {}).get('artifacts') or []
            for item in artifacts:
                item = {'path':item} if isinstance(item,str) else item
                if not isinstance(item,dict) or not item.get('path'):
                    continue
                raw=Path(item['path'])
                if not raw.is_absolute():
                    raw=Path(task.get('cwd') or self.workspace)/raw
                identity=str(task['id'])+'\0'+str(task.get('run_id',''))+'\0'+str(raw)
                yield task,item,raw,'art_'+hashlib.sha256(identity.encode()).hexdigest()[:32]
        # 航程产出目录里的成品，不管有没有被哪条消息提到，都进产出库
        folder=self.workspace/OUTPUTS
        if folder.is_dir():
            for path in folder.iterdir():
                if path.suffix.lower() not in SHELF or path.name.startswith(('.','_')) or not path.is_file():
                    continue
                mtime=path.stat().st_mtime
                yield {'id':'','created_at':mtime},{'path':str(path)},path,'art_'+hashlib.sha256(('outputs:'+str(path)).encode()).hexdigest()[:32]

    def _safe(self, raw):
        path=raw.resolve()
        if not path.is_relative_to(self.workspace) or raw.is_symlink() or path.suffix.lower() not in ALLOWED:
            raise PermissionError('不允许访问该成果')
        if any(part.startswith('.') for part in path.relative_to(self.workspace).parts):
            raise PermissionError('隐藏文件不是公开成果')
        if not path.is_file():
            raise FileNotFoundError(path.name)
        if path.stat().st_size > 100*1024*1024:
            raise PermissionError('成果超过 100 MB 下载上限')
        return path

    def _record(self, task,item,raw,aid):
        try:
            path=self._safe(raw);stat=path.stat()
            status='available';size=stat.st_size
        except FileNotFoundError:
            status='missing';size=0
        except PermissionError:
            status='restricted';size=0
        return {'id':aid,'task_id':task['id'],'message_id':task.get('message_id',''),'run_id':task.get('run_id',''),
                'name':raw.name,'path':str(raw),'reference':item.get('path',''),'mime':mimetypes.guess_type(raw.name)[0] or 'application/octet-stream',
                'size':size,'created_at':task.get('updated_at',task.get('created_at',0)),
                'availability':status,'download_path':'/personal/artifacts/'+aid}

    def index(self):
        """同一个文件只列一次（先登记到消息/任务上的那条优先，点开能回到出处），新的在前。"""
        out, seen = [], set()
        for entry in self._entries():
            key = str(entry[2])  # 不 resolve：软链接和它指向的文件要分开判（前者必须被拒）
            if key in seen:
                continue
            seen.add(key)
            out.append(self._record(*entry))
        return sorted(out, key=lambda r: -(r['created_at'] or 0))

    def resolve(self, aid):
        for entry in self._entries():
            if entry[3]==aid:
                return self._record(*entry),self._safe(entry[2])
        raise KeyError(aid)

    def open(self, aid):
        record,path=self.resolve(aid)
        expected=path.stat()
        fd=os.open(path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
        try:
            actual=os.fstat(fd)
            checked=self._safe(path)
            if checked!=path or (actual.st_dev,actual.st_ino)!=(expected.st_dev,expected.st_ino):
                raise PermissionError('文件在读取期间发生变化，请重试')
            return record,os.fdopen(fd,'rb'),actual.st_size
        except BaseException:
            os.close(fd)
            raise
