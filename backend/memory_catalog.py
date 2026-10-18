"""Versioned Com memories: one active Markdown document per stable identity."""
import fcntl,hashlib,json,os,re,time,uuid
from contextlib import contextmanager
from pathlib import Path
from memory import ROOT,SENSITIVE,sources,sanitize,digest
CATEGORIES=('关于我','工作','项目','生活','兴趣','健康','财务')
# 手机上按「文件夹」浏览：比写入时的 category 粗一层、按用途分。category 仍是写入校验口径，不动。
FOLDERS=(
    {'name':'关于我','blurb':'身份、称呼和协作偏好'},
    {'name':'工作','blurb':'搜狐、求职与职业发展'},
    {'name':'创作','blurb':'视频号、素材与发布口径'},
    {'name':'技能','blurb':'自动化、工程与排障方法'},
    {'name':'设备','blurb':'电脑、手机、NAS 与网络'},
    {'name':'项目','blurb':'Agent 系统与在做的工程'},
    {'name':'生活','blurb':'记账、提醒、健康与兴趣'},
)
FOLDER_WORDS=(
    ('关于我',('身份','协作偏好','Markdown排版')),
    ('创作',('视频号','素材技术','内容偏好')),
    ('设备',('设备','网络','内网','移动端','Tailscale','Windows','NAS','macOS','Macmini')),
    ('技能',('自动化','前端工程','排障','EMFILE','微信数据','豆包','方法论')),
    ('工作',('搜狐','求职')),
    ('生活',('生活','记账','财务','健康','睡眠','运动','提醒','摩托车','攀岩','旅行')),
)
CATEGORY_FOLDER={'兴趣':'生活','健康':'生活','财务':'生活'}
def folder_of(row,name=''):
    if row.get('kind')=='knowledge':
        return next((f for f,words in FOLDER_WORDS if any(w in name for w in words)),'项目')
    return CATEGORY_FOLDER.get(row.get('category'),row.get('category') or '生活')
def plain(text,limit=160):
    """列表预览用的纯文本：去掉 Markdown 记号，免得手机上露出 ** 和反引号。"""
    text=re.sub(r'`([^`]*)`',r'\1',text);text=re.sub(r'\*\*|__|\[(.*?)\]\(.*?\)',lambda m:m.group(1) or '',text)
    text=re.sub(r'^\s*(?:[-*+]|\d+\.)\s+','',text,flags=re.M)
    return re.sub(r'\s+',' ',text).strip()[:limit]
def headline(text):
    """对话里记住的事没有标题：取第一句，太长截断。"""
    first=re.split(r'[。；;！!？?\n]',plain(text,400),maxsplit=1)[0]
    return first if len(first)<=24 else first[:23]+'…'
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


class SharedKnowledgeCatalog:
    """A live, read-only projection of the shared Markdown knowledge, not a copy.

    This belongs to the mobile browsing API. Agent context stays bounded and
    continues to use Hindsight recall instead of injecting all documents.
    """
    def __init__(self, root=ROOT):
        self.root = Path(root)

    @staticmethod
    def category(name):
        for category, words in (
            ('关于我', ('身份', '协作偏好', 'Markdown排版')),
            ('健康', ('健康', '睡眠', '运动')),
            ('财务', ('记账', '财务', '账单')),
            ('工作', ('搜狐', '求职', '视频号', '内容偏好', '素材技术')),
            ('生活', ('设备', '网络', 'macOS', 'Macmini', '内网', '移动端', 'Tailscale', '提醒同步')),
            ('兴趣', ('摩托车', '攀岩', '旅行')),
        ):
            if any(word in name for word in words):
                return category
        return '项目'

    def list(self):
        rows = []
        for (bank, relative), path in sources(self.root).items():
            if bank != 'personal-main' or not relative.startswith('_global/记忆库/知识/'):
                continue
            # Parent symlinks must not turn the knowledge API into a file browser.
            try:
                path.resolve().relative_to(self.root.resolve())
                raw = path.read_bytes()
                content = sanitize(raw.decode('utf-8')).strip()
                modified = path.stat().st_mtime
            except (OSError, UnicodeError, ValueError):
                continue
            if not content:
                continue
            title = next((line[2:].strip() for line in content.splitlines() if line.startswith('# ')), path.stem)
            paragraphs = [line.strip() for line in content.splitlines()
                          if line.strip() and not line.startswith(('#', '>', '|', '```', '---', '**来源', '**更新', '**日期'))]
            rows.append({
                'id': 'doc_' + hashlib.sha256(relative.encode()).hexdigest()[:24],
                'title': title, 'content': content, 'summary': '\n'.join(paragraphs)[:500],
                'category': self.category(path.stem), 'kind': 'knowledge', 'folder': folder_of({'kind': 'knowledge'}, path.stem),
                'preview': plain('\n'.join(paragraphs)),
                'read_only': True, 'updated_at': modified, 'version': 1,
                'archived': False, 'history': [],
                'source': {'type': 'shared_markdown', 'path': relative, 'sha256': digest(raw)},
            })
        return sorted(rows, key=lambda row: (-row['updated_at'], row['id']))

    def get(self, ident):
        if not re.fullmatch(r'doc_[0-9a-f]{24}', ident):
            raise ValueError('Invalid shared knowledge ID')
        for row in self.list():
            if row['id'] == ident:
                return row
        raise ValueError('Shared knowledge not found')
