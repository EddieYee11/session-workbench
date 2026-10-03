"""Isolated, non-Syncthing code copies and optimistic, serialized acceptance merge."""
import fcntl
import hashlib
import json
import os
import shutil
import time
from pathlib import Path

IGNORE={'.git','node_modules','.venv','__pycache__','.gradle','build','.DS_Store'}


def snapshot(root):
    root=Path(root)
    result={}
    total=0
    for base,dirs,files in os.walk(root,followlinks=False):
        dirs[:]=[d for d in dirs if d not in IGNORE]
        for filename in files:
            path=Path(base)/filename
            if filename in IGNORE:
                continue
            if '.sync-conflict-' in filename:
                raise ValueError('项目存在 Syncthing 冲突文件，先处理冲突')
            relative=str(path.relative_to(root))
            if path.is_symlink():
                raise ValueError('项目含文件符号链接，不能保证隔离写入：'+relative)
            total+=path.stat().st_size
            if total>512*1024*1024:
                raise ValueError('项目副本超过 512MB，请选更精确的项目目录')
            with path.open('rb') as f:
                result[relative]=hashlib.file_digest(f,'sha256').hexdigest()
        # Directory symlinks must not point back into live synchronized projects.
        if any((Path(base)/d).is_symlink() for d in dirs):
            raise ValueError('项目含目录符号链接，需明确隔离策略')
    return result


class WorkspaceCopies:
    def __init__(self,state,sync_check=None):
        self.root=Path(state)/'worker-copies'
        self.root.mkdir(parents=True,exist_ok=True)
        self.sync_check=sync_check

    def prepare(self,task):
        from execution_boundary import require_host
        require_host(self.root.parent)
        destination=self.root/task['id']
        if destination.exists():
            raise ValueError('副本已存在，不重复派发未确认任务')
        original=Path(task['cwd']).resolve()
        baseline=snapshot(original)
        destination.mkdir(mode=0o700)
        working=destination/'work'
        shutil.copytree(original,working,ignore=shutil.ignore_patterns(*IGNORE))
        if snapshot(original)!=baseline or snapshot(working)!=baseline:
            raise ValueError('复制时基线变化，保留副本并暂停派发')
        (destination/'baseline.json').write_text(json.dumps({'cwd':str(original),'files':baseline}))
        return str(working)

    def changes(self,task):
        directory=Path(task['workspace_copy']).parent
        baseline=json.loads((directory/'baseline.json').read_text())
        current=snapshot(task['workspace_copy'])
        changed=[p for p in sorted(set(current)|set(baseline['files'])) if current.get(p)!=baseline['files'].get(p)]
        # Exact copies of changed files + manifest are a recoverable patch artifact even without Git.
        patch=directory/'patch'/str(task.get('run_id') or 'snapshot')
        patch.mkdir(parents=True,exist_ok=True)
        for name in changed:
            source=Path(task['workspace_copy'])/name
            if source.exists():
                target=patch/name
                target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(source,target)
        (patch/'manifest.json').write_text(json.dumps({'original':baseline['cwd'],'changed':changed,
            'deleted':[p for p in changed if p not in current],'baseline':baseline['files']},ensure_ascii=False))
        return changed,str(patch)

    async def merge(self,task):
        from execution_boundary import require_host
        require_host(self.root.parent)
        if task.get('verification_status')!='passed':
            raise ValueError('先验收独立副本，再合入')
        directory=Path(task['workspace_copy']).parent
        baseline=json.loads((directory/'baseline.json').read_text())
        project=Path(baseline['cwd'])
        changed,patch=self.changes(task)
        lock=self.root/(hashlib.sha256(str(project).encode()).hexdigest()+'.lock')
        with lock.open('a') as holder:
            fcntl.flock(holder,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if not self.sync_check or not await self.sync_check(project):
                raise ValueError('Syncthing 未确认同步稳定，补丁保留于 '+patch)
            if snapshot(project)!=baseline['files']:
                raise ValueError('项目基线已变化，补丁保留于 '+patch)
            backup=directory/'pre-merge'/str(time.time_ns())
            backup.mkdir(parents=True)
            written=[]
            try:
                for name in changed:
                    target=project/name
                    if not target.resolve().is_relative_to(project):
                        raise ValueError('合入路径越界')
                    saved=backup/name
                    if target.exists():
                        saved.parent.mkdir(parents=True,exist_ok=True)
                        shutil.copy2(target,saved)
                    target.parent.mkdir(parents=True,exist_ok=True)
                    if not (Path(task['workspace_copy'])/name).exists():
                        # Removed originals remain in pre-merge: this is a recoverable archive.
                        target.unlink(missing_ok=True)
                        written.append(name)
                        continue
                    temp=target.with_name(target.name+'.com-merge-tmp')
                    shutil.copy2(Path(task['workspace_copy'])/name,temp)
                    os.replace(temp,target)
                    written.append(name)
            except Exception:
                for name in reversed(written):
                    if (backup/name).exists():
                        shutil.copy2(backup/name,project/name)
                    else:
                        (project/name).unlink(missing_ok=True)
                raise
            (directory/'baseline.json').write_text(json.dumps({'cwd':str(project),'files':snapshot(project)}))
        return {'status':'merged','files':changed,'recovery':str(backup),'patch':patch}
