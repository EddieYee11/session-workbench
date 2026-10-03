"""Recoverable archive actions with durable source/destination evidence."""
import hashlib
import json
import os
import sqlite3
from pathlib import Path


class Archives:
    def __init__(self,state,workspace):
        self.state=Path(state);self.workspace=Path(workspace).resolve()
        self.path=self.state/'archives.sqlite'
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE IF NOT EXISTS archives(id TEXT PRIMARY KEY,data TEXT NOT NULL)')
        self.path.chmod(0o600)

    def archive(self,relative_path,request_id,origin):
        from execution_boundary import require_host
        require_host(self.state)
        source=(self.workspace/relative_path).resolve()
        if not source.is_relative_to(self.workspace) or source==self.workspace:
            raise ValueError('归档需要明确的工作区内对象')
        ident='archive_'+hashlib.sha256(request_id.encode()).hexdigest()[:24]
        destination=self.state/'archives'/ident/source.name
        with sqlite3.connect(self.path) as db:
            old=db.execute('SELECT data FROM archives WHERE id=?',(ident,)).fetchone()
            if old:
                saved=json.loads(old[0])
                if saved['source']!=str(source) or saved['origin']!=origin:raise ValueError('归档请求标识冲突')
                if saved['status']=='uncertain' and not source.exists() and Path(saved['destination']).exists():
                    saved['status']='archived'
                    db.execute('UPDATE archives SET data=? WHERE id=?',(json.dumps(saved),ident))
                return saved
            data={'id':ident,'source':str(source),'destination':str(destination),'origin':origin,
                  'status':'uncertain','recoverable':True,'restore_endpoint':'/personal/archives/'+ident+'/restore'}
            db.execute('INSERT INTO archives VALUES (?,?)',(ident,json.dumps(data)));db.commit()
            destination.parent.mkdir(parents=True,exist_ok=True)
            # Rename is atomic. A crash after rename leaves a reconcilable saved destination.
            os.rename(source,destination)
            data['status']='archived'
            db.execute('UPDATE archives SET data=? WHERE id=?',(json.dumps(data),ident))
        return data

    def restore(self,ident):
        from execution_boundary import require_host
        require_host(self.state)
        with sqlite3.connect(self.path) as db:
            row=db.execute('SELECT data FROM archives WHERE id=?',(ident,)).fetchone()
            if not row:raise ValueError('归档记录不存在')
            saved=json.loads(row[0]);source=Path(saved['source']);destination=Path(saved['destination'])
            if saved['status']=='restored':return saved
            if saved.get('restore_started') and source.exists() and not destination.exists():
                saved['status']='restored'
                db.execute('UPDATE archives SET data=? WHERE id=?',(json.dumps(saved),ident))
                return saved
            if source.exists():raise ValueError('原位置已有内容，停止恢复，不覆盖')
            saved['restore_started']=True
            db.execute('UPDATE archives SET data=? WHERE id=?',(json.dumps(saved),ident));db.commit()
            source.parent.mkdir(parents=True,exist_ok=True)
            os.rename(destination,source)
            saved['status']='restored';db.execute('UPDATE archives SET data=? WHERE id=?',(json.dumps(saved),ident))
        return saved
