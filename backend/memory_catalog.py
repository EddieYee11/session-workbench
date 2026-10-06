"""Versioned Com memories: one active Markdown document per stable identity."""
import fcntl,hashlib,json,os,re,time,uuid
from contextlib import contextmanager
from pathlib import Path
from memory import ROOT,SENSITIVE
CATEGORIES=('关于我','工作','项目','生活','兴趣','健康','财务')
class MemoryCatalog:
    def __init__(self,root=ROOT):
        self.root=Path(root)/'_global/记忆库/Com'
        self.root.mkdir(parents=True,exist_ok=True)
    @contextmanager
    def lock(self):
        with (self.root/'.lock').open('a') as f:
            fcntl.flock(f,fcntl.LOCK_EX);yield
    def path(self,ident):
        if not re.fullmatch(r'mem_[0-9a-f]{24}',ident):raise ValueError('Invalid memory ID')
        return self.root/(ident+'.md')
    def get(self,ident):
        try:return json.loads(self.path(ident).read_text().split('```json\n',1)[1].split('\n```',1)[0])
        except FileNotFoundError:raise ValueError('Memory not found') from None
    def list(self,category='',archived=False):
        rows=[self.get(p.stem) for p in self.root.glob('mem_*.md')]
        return sorted([r for r in rows if (not category or r['category']==category) and (archived or not r['archived'])],key=lambda r:r['updated_at'],reverse=True)
    def save(self,content,category,source,ident='',kind='fact',expected_version=None,archived=False):
        if category not in CATEGORIES or kind not in ('fact','inference'):raise ValueError('Invalid memory category/kind')
        if not isinstance(content,str) or not 1<=len(content.strip())<=4000 or SENSITIVE.search(content):raise ValueError('Memory content is invalid or contains credentials')
        if not isinstance(source,dict) or not source.get('message_id') or not source.get('quote'):raise ValueError('Memory needs a real source')
        content=content.strip()
        ident=ident or 'mem_'+hashlib.sha256((source['message_id']+category+content).encode()).hexdigest()[:24]
        with self.lock():
            path=self.path(ident);old=self.get(ident) if path.exists() else None
            if old and old['content']==content and old['category']==category and old['archived']==archived:return old
            if old and expected_version!=old['version']:raise ValueError('Memory changed; refresh before correcting')
            row=dict(id=ident,content=content,category=category,kind=kind,source=source,updated_at=time.time(),version=(old['version']+1 if old else 1),archived=archived,
                     history=(old.get('history',[])+[{k:v for k,v in old.items() if k!='history'}] if old else []))
            text='# '+category+' · '+ident+'\n\n'+content+'\n\n```json\n'+json.dumps(row,ensure_ascii=False,indent=2)+'\n```\n'
            tmp=path.with_suffix('.'+uuid.uuid4().hex+'.tmp');tmp.write_text(text);tmp.chmod(0o600);tmp.replace(path)
            return row
    def context(self,limit=25):
        return [{k:r[k] for k in ('id','category','content','kind','source','version')} for r in self.list()[:limit]]
