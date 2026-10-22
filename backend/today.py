"""「今天」：把今天的日程、提醒和行动台待办收成一份，给手机上的时间线用。

日程 → 当天待办（Eddie 设定，见 calendar_todos.py）：`todo_create(..., event_id=…)` 建，
`todo_sync_event()` 只更新来源待办的 `计划结束` 和 Com 自己写的来源备注行；`todo_index()` 带出
`com_event_id` 供幂等去重。

只读聚合，不新建任何存储：
- 日程：personal_hub 里已同步的日历事项（苹果 / Google / 手机日历），同一个日程在多个日历里只算一次；
- 提醒：pi-gateway 的提醒记录（reminder_cards），今天到点的，加上还没处理的过期提醒；
- 待办：Obsidian 行动台 `任务/待处理/`，计划结束在今天或已经过期、或今天落在计划区间里的。
派活待批准、停下来等你的任务不在这里：App 已经有那份数据（/personal/tasks、proposals），自己并进时间线。

写操作（轨道 r3-pages + 日程同步）：手机上打勾 / 撤销 / 改期只改那个文件属性头里的 `状态`、`完成时间`、
`计划结束` 三行；日程同步只新建来源待办、或更新它的 `计划结束` 与 Com 写的来源备注行；
两者都是临时文件 + replace 原子写，正文和其他字段不动，不挪文件（Obsidian 的 auto-move 插件按状态归位）。
"""
import json, os, re, stat, threading, time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo('Asia/Shanghai')
CALENDAR = ('apple_calendar', 'google_calendar', 'phone_calendar')
INFORMATIONAL = ('节假日', '中国大陆', '中国节日')
EVENT_FIELD = 'com_event_id'   # 由日程同步来的待办，记来源日程 id（幂等去重账本）
SOURCE_MARK = '来源：日程'      # Com 写的备注行前缀；只有这种备注才会被同步刷新

def todo_name(title):
    """待办标题 → 文件名：Obsidian 禁用字符换空格；【】只是装饰，直接去掉，
    这样日程「【AI德州扑克】预赛」和手建的「AI德州扑克预赛」算同名，不会多建一条。"""
    text = re.sub(r'[【】]+', '', str(title or ''))
    text = re.sub(r'[\\/:*?"<>|#^\[\]\n\r]+', ' ', text)
    return re.sub(r'\s+', ' ', text).strip()[:60].strip('. ')


def yaml_value(text):
    """frontmatter 的单行标量。含 ASCII `: ` 这类 YAML 敏感写法（Obsidian 按 YAML 读属性头）就加双引号，
    否则 Obsidian 会把这一行当成嵌套映射、整个属性头报错。_front 和 _value 读的时候都会剥掉引号。"""
    clean = re.sub(r'\s+', ' ', str(text or '')).strip()
    if ': ' in clean or clean[:1] in tuple('-?:#&*!|>@`"\'{[%,') or ' #' in clean:
        return '"' + clean.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return clean


def _instant(value):
    """日历时间：带时区的 ISO、无时区按北京时间、只有日期的算全天。返回 (datetime, 是否全天)。"""
    if isinstance(value, dict):
        value = value.get('dateTime') or value.get('date')
    if not value:
        return None, False
    text = str(value)
    try:
        d = datetime.fromisoformat(text)
    except ValueError:
        return None, False
    all_day = len(text) == 10
    return (d.replace(tzinfo=TZ) if d.tzinfo is None else d.astimezone(TZ)), all_day


def _front(path):
    """读 markdown 头部的 key: value；不认识的格式直接返回空。"""
    try:
        text = path.read_text(encoding='utf-8')
    except OSError:
        return {}
    if not text.startswith('---'):
        return {}
    end = text.find('\n---', 3)
    if end < 0:
        return {}
    out = {}
    for line in text[3:end].splitlines():
        if ':' in line and not line.startswith((' ', '\t', '-')):
            key, _, value = line.partition(':')
            out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def _day(value):
    try:
        return datetime.strptime(str(value)[:10], '%Y-%m-%d').date()
    except ValueError:
        return None


def _head(text):
    """属性头按行切（保留行尾）：返回 (行列表, 收尾 --- 的行号)。头部必须以单独一行 --- 开头、--- 收尾。"""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip('\r\n') != '---':
        raise ValueError('这条待办没有属性头，没法在手机上打勾')
    for i in range(1, len(lines)):
        if lines[i].rstrip('\r\n') == '---':
            return lines, i
    raise ValueError('这条待办的属性头没有收尾，没法在手机上打勾')


def _field(lines, end, key):
    """属性头里第一行顶格的 `key:`，返回行号；没有就是 None。"""
    pattern = re.compile(r'^' + re.escape(key) + r'\s*:')
    return next((i for i in range(1, end) if pattern.match(lines[i])), None)


def _value(line):
    return line.partition(':')[2].strip().strip('"').strip("'")


def _ending(line, fallback='\n'):
    return line[len(line.rstrip('\r\n')):] or fallback


DONE_FIELDS = ('状态', '完成时间')


class Today:
    def __init__(self, hub=None, reminders=None, vault=None, clock=time.time):
        self.hub, self.reminders, self.clock = hub, reminders, clock
        self.vault = Path(vault) if vault else None
        self._lock = threading.Lock()

    def snapshot(self):
        now = datetime.fromtimestamp(self.clock(), TZ)
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        end = start + timedelta(days=1)
        out = {'date': start.date().isoformat(), 'generated_at': now.timestamp(), 'events': [], 'reminders': [], 'todos': [], 'wechat': None, 'health': None, 'errors': {}}
        for name, fn in (('events', self.events), ('reminders', self.reminder_items), ('todos', self.todos), ('wechat', self.wechat_digest), ('health', self.health)):
            try:
                out[name] = fn(start, end)
            except Exception as exc:  # 一个来源坏了不拖累其余来源
                out['errors'][name] = str(exc)[:200]
        return out

    def events(self, start, end):
        if not self.hub:
            return []
        seen, rows = set(), []
        for row in self.hub.matters():
            if row.get('source') not in CALENDAR or (row.get('feedback') or {}).get('action') == 'mute':
                continue
            facts = row.get('facts') if isinstance(row.get('facts'), dict) else {}
            begin, all_day = _instant(facts.get('start') or row.get('deadline'))
            finish, _ = _instant(facts.get('end'))
            if not begin:
                continue
            finish = finish or begin
            # 和今天有交集就算今天的（跨天的会议、今天的全天日程）；全天日程的结束日是开区间。
            if not (begin < end and (finish > start or (finish == begin and begin >= start))):
                continue
            if all_day and finish <= start:
                continue
            key = (row.get('title'), begin.timestamp(), finish.timestamp())
            if key in seen:
                continue
            seen.add(key)
            calendar = str(facts.get('calendar') or '')
            rows.append({'id': row['id'], 'title': row.get('title') or '日程', 'start': begin.timestamp(), 'end': finish.timestamp(),
                         'all_day': all_day or (begin <= start and finish >= end), 'location': facts.get('location') or '',
                         'notes': str(facts.get('description') or facts.get('notes') or '')[:400], 'source': row['source'],
                         'calendar': calendar, 'informational': facts.get('availability') == 1 or any(k in calendar for k in INFORMATIONAL),
                         'link': facts.get('htmlLink') or ''})
        rows.sort(key=lambda r: (not r['all_day'], r['start']))
        return rows

    def health(self, start, end):
        """身体数据：今天全量 + 7 天序列（只读 hub 里已同步的 Garmin / 手机健康，不在这里拉网络）。"""
        if not self.hub or not hasattr(self.hub, 'health'):
            return None
        data = self.hub.health(7)
        return data if data['days'] or data['phone'] else None

    def wechat_digest(self, start, end):
        """今天收到的微信摘要，合并成一张卡：同一个聊天只留最新的那条，有人 @我的排前面。"""
        if not self.hub:
            return None
        lo, hi = start.timestamp(), end.timestamp()
        merged = {}
        for row in self.hub.matters():
            if row.get('source') != 'wechat' or (row.get('feedback') or {}).get('action') in ('mute', 'handled'):
                continue
            at = float(row.get('source_updated_at') or row.get('changed_at') or 0)
            if not lo <= at < hi:
                continue
            facts = row.get('facts') if isinstance(row.get('facts'), dict) else {}
            for chat in facts.get('chats') or []:
                if chat.get('is_group') and not (chat.get('mention') or chat.get('keyword') or chat.get('priority')):
                    continue
                name = str(chat.get('name') or '')
                if not name:
                    continue
                prev = merged.get(name)
                if prev and prev['at'] >= at:
                    continue
                merged[name] = {'name': name, 'username': chat.get('username') or '', 'at': at,
                                'is_group': bool(chat.get('is_group')), 'mention': bool(chat.get('mention')),
                                'keyword': bool(chat.get('keyword')), 'priority': bool(chat.get('priority')),
                                'keywords': (chat.get('keywords') or [])[:4], 'sender': chat.get('sender') or '',
                                'summary': str(chat.get('summary') or '')[:400],
                                'messages': [{'sender': m.get('sender') or '', 'at': int(m.get('at') or 0),
                                              'text': str(m.get('text') or '')[:300]} for m in (chat.get('messages') or [])[-12:]]}
        chats = sorted(merged.values(), key=lambda c: (not c['mention'], c['is_group'], -c['at']))
        if not chats:
            return None
        private = sum(1 for c in chats if not c['is_group'])
        mentioned = sum(1 for c in chats if c['mention'])
        keywords = sum(1 for c in chats if c['keyword'] and not c['mention'] and c['is_group'])
        parts = [f'私聊 {private}' if private else '', f'群 @我 {mentioned}' if mentioned else '',
                 f'关键词 {keywords}' if keywords else '']
        return {'id': 'wechat:' + start.date().isoformat(), 'title': f'微信 · 今日 {len(chats)} 条重点',
                'subtitle': ' · '.join(p for p in parts if p), 'chats': chats}

    def reminder_items(self, start, end):
        if not self.reminders:
            return []
        rows = []
        for r in self.reminders.list():
            try:
                due = datetime.strptime(str(r.get('due')), '%Y-%m-%d %H:%M').replace(tzinfo=TZ)
            except ValueError:
                continue
            pending = r.get('status') == 'pending'
            today = start <= due < end
            if r.get('status') == 'cancelled' or not (today or (pending and due < start)):
                continue
            rows.append({'id': r['id'], 'title': r.get('text') or '提醒', 'at': due.timestamp(), 'due': r.get('due'), 'status': r.get('status'),
                         'repeat': r.get('repeat') or '', 'overdue': pending and due < start, 'record': r})
        rows.sort(key=lambda r: r['at'])
        return rows

    def todos(self, start, end):
        if not self.vault:
            return []
        folder = self.vault / '任务' / '待处理'
        if not folder.is_dir():
            return []
        today, rows = start.date(), []
        for path in sorted(folder.glob('*.md')):
            if path.stem.startswith(('00-', 'zz')):
                continue
            f = _front(path)
            if f.get('flow') != '任务' or f.get('状态', '待处理') != '待处理':
                continue
            due, begin = _day(f.get('计划结束')), _day(f.get('计划开始'))
            if not due and not begin:
                continue
            if not ((due and due <= today) or (begin and begin <= today and (not due or due >= today))):
                continue
            project = re.sub(r'^\[\[|\]\]$', '', f.get('关联项目', ''))
            rows.append({'id': path.stem, 'title': path.stem, 'due': f.get('计划结束', ''), 'start': f.get('计划开始', ''),
                         'overdue': bool(due and due < today), 'next_step': f.get('下一步', ''), 'project': project, 'note': f.get('备注', ''),
                         'path': str(path.relative_to(self.vault))})
        rows.sort(key=lambda r: (not r['overdue'], r['due'] or '9999'))
        return rows

    # ---- 待办打勾 / 撤销（轨道 r3-pages） ----------------------------------------------------

    def _pending_file(self, rel):
        """快照里的 path（相对 vault）→ 真实文件。只认 `任务/待处理/` 下直接放着的 .md，防路径穿越和软链接出界。"""
        if not self.vault:
            raise ValueError('行动台没接上')
        if not isinstance(rel, str) or not rel.strip() or '\x00' in rel:
            raise ValueError('待办路径无效')
        folder = (self.vault / '任务' / '待处理').resolve()
        path = (self.vault / rel).resolve()
        if path.parent != folder or path.suffix != '.md' or path.stem.startswith(('00-', 'zz')):
            raise ValueError('只能改行动台「待处理」里的待办')
        return path

    def _write(self, path, text, stamp):
        """原子写：同目录临时文件（点开头，Obsidian 不认）写完再 replace；写之前文件被别处改过就放弃。"""
        tmp = path.with_name('.' + path.name + '.com-tmp')
        try:
            tmp.write_bytes(text.encode('utf-8'))
            os.chmod(tmp, stat.S_IMODE(path.stat().st_mode))
            if path.stat().st_mtime_ns != stamp:
                raise ValueError('这条待办刚被别处改过，请刷新再试')
            os.replace(tmp, path)
        finally:
            if tmp.exists():
                tmp.unlink()

    def todo_done(self, rel):
        """打勾：`状态` 改成 已完成、写 `完成时间: YYYY-MM-DD`，其余一字不动。
        返回 undo：两行原样（没有这一行就是 None），撤销时照它恢复。已经是已完成就什么都不改（幂等）。"""
        with self._lock:
            path = self._pending_file(rel)
            if not path.is_file():
                raise ValueError('这条待办已经不在待处理里了，请刷新')
            stamp = path.stat().st_mtime_ns
            lines, end = _head(path.read_bytes().decode('utf-8'))
            state, when = _field(lines, end, '状态'), _field(lines, end, '完成时间')
            if state is not None and _value(lines[state]) == '已完成':
                return {'status': 'completed', 'path': rel, 'changed': False, 'undo': None}
            undo = {'状态': None if state is None else lines[state].rstrip('\r\n'),
                    '完成时间': None if when is None else lines[when].rstrip('\r\n')}
            day = datetime.fromtimestamp(self.clock(), TZ).date().isoformat()
            newline = _ending(lines[0])
            out, extra = list(lines), []
            for index, text in ((state, '状态: 已完成'), (when, '完成时间: ' + day)):
                if index is None:
                    extra.append(text + newline)
                else:
                    out[index] = text + _ending(lines[index], newline)
            out[end:end] = extra  # 原来没有的字段补在属性头末尾，撤销时整行删掉就回到原样
            self._write(path, ''.join(out), stamp)
            return {'status': 'completed', 'path': rel, 'changed': True, 'undo': undo, 'completed_at': day}

    def todo_undo(self, rel, undo):
        """撤销打勾：两行精确恢复成打勾前的原文，原来没有的就删掉。
        auto-move 插件可能已经把文件挪进 `任务/已完成/`（同名），那就在那里恢复，插件会再按状态挪回来。"""
        if not isinstance(undo, dict) or set(undo) != set(DONE_FIELDS):
            raise ValueError('撤销信息不完整')
        for key in DONE_FIELDS:
            line = undo[key]
            if line is not None and (not isinstance(line, str) or '\n' in line or '\r' in line
                                     or not re.match(r'^' + re.escape(key) + r'\s*:', line)):
                raise ValueError('撤销信息无效')
        with self._lock:
            path = self._pending_file(rel)
            if not path.is_file():
                moved = (self.vault / '任务' / '已完成' / path.name).resolve()
                if moved.parent != (self.vault / '任务' / '已完成').resolve() or not moved.is_file():
                    raise ValueError('找不到这条待办了，可能已经被挪走或改名')
                path = moved
            stamp = path.stat().st_mtime_ns
            lines, end = _head(path.read_bytes().decode('utf-8'))
            state, when = _field(lines, end, '状态'), _field(lines, end, '完成时间')
            current = {'状态': None if state is None else lines[state].rstrip('\r\n'),
                       '完成时间': None if when is None else lines[when].rstrip('\r\n')}
            relative = str(path.relative_to(self.vault.resolve()))
            if current == undo:
                return {'status': 'completed', 'path': relative, 'changed': False}
            if state is None or _value(lines[state]) != '已完成':
                raise ValueError('这条待办在别处改过状态，没法撤销')
            newline = _ending(lines[0])
            out = list(lines)
            # 先改后删，删的时候从下往上，行号不会错位。
            drop = []
            for key, index in (('状态', state), ('完成时间', when)):
                if undo[key] is None:
                    if index is not None:
                        drop.append(index)
                elif index is None:
                    out.insert(end, undo[key] + newline)
                else:
                    out[index] = undo[key] + _ending(lines[index], newline)
            for index in sorted(drop, reverse=True):
                del out[index]
            self._write(path, ''.join(out), stamp)
            return {'status': 'completed', 'path': relative, 'changed': True}

    def todo_postpone(self, rel, day=None):
        """改期：只把 `计划结束` 改到 day（默认明天），其余一字不动；返回原行，撤销时照原样写回。"""
        target = _day(day) if day else (datetime.fromtimestamp(self.clock(), TZ) + timedelta(days=1)).date()
        if not target:
            raise ValueError('日期无效')
        with self._lock:
            path = self._pending_file(rel)
            if not path.is_file():
                raise ValueError('这条待办已经不在待处理里了，请刷新')
            stamp = path.stat().st_mtime_ns
            lines, end = _head(path.read_bytes().decode('utf-8'))
            index = _field(lines, end, '计划结束')
            before = None if index is None else lines[index].rstrip('\r\n')
            text = '计划结束: ' + target.isoformat()
            out = list(lines)
            if index is None:
                out.insert(end, text + _ending(lines[0]))
            else:
                out[index] = text + _ending(lines[index], _ending(lines[0]))
            self._write(path, ''.join(out), stamp)
            return {'status': 'completed', 'path': rel, 'due': target.isoformat(), 'undo': before}

    # ---- 下一步 → 待办（2026-10-17 航程与闭环） ----------------------------------------------

    def todo_index(self):
        """`任务/待处理/` 里还没做的待办：名字、计划结束、来源建议 id 和依据签名（由「加到待办」写入），给下一步去重。"""
        folder = self.vault / '任务' / '待处理' if self.vault else None
        if not folder or not folder.is_dir():
            return []
        rows = []
        for path in folder.glob('*.md'):
            if path.stem.startswith(('00-', 'zz')):
                continue
            f = _front(path)
            if f.get('flow') != '任务' or f.get('状态', '待处理') != '待处理':
                continue
            rows.append({'name': path.stem, 'due': f.get('计划结束', ''), 'path': str(path.relative_to(self.vault)),
                         'next_id': f.get('com_next_id', ''), 'sigs': [s for s in f.get('com_sigs', '').split(',') if s],
                         'event_id': f.get(EVENT_FIELD, '')})
        return rows

    def todo_create(self, title, day, next_step='', note='', body='', next_id='', sigs=(), event_id='', progress=''):
        """新建一条行动台待办（frontmatter 与手建的一致，另记 com_next_id / com_sigs / com_event_id 供去重）。同名已存在就不覆盖，返回已有那条。
        event_id：由日程同步来的待办记来源日程 id；progress：换掉「## 进展」里那句来源说明。"""
        if not self.vault:
            raise ValueError('行动台没接上')
        target = _day(day)
        if not target:
            raise ValueError('日期无效')
        name = todo_name(title)
        if not name:
            raise ValueError('待办标题为空')
        folder = self.vault / '任务' / '待处理'
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / (name + '.md')
        rel = str(path.relative_to(self.vault))
        if path.exists():
            return {'status': 'exists', 'path': rel, 'name': name, 'due': _front(path).get('计划结束', '')}
        one = lambda v: re.sub(r'\s+', ' ', str(v or '')).strip()[:200]
        today = datetime.fromtimestamp(self.clock(), TZ).date().isoformat()
        text = ('---\nflow: 任务\n状态: 待处理\n关联项目:\n计划开始:\n计划结束: ' + target.isoformat() + '\n完成时间:\n'
                + '下一步: ' + yaml_value(one(next_step)) + '\n备注: ' + yaml_value(one(note)) + '\ncreated: ' + today + '\n'
                + ('com_next_id: ' + one(next_id) + '\n' if next_id else '')
                + ('com_sigs: ' + ','.join(s.replace(',', ' ') for s in sigs if s) + '\n' if sigs else '')
                + (EVENT_FIELD + ': ' + one(event_id) + '\n' if event_id else '')
                + '---\n\n# ' + name + '\n\n## 说明\n\n' + (body.strip() or one(next_step)) + '\n\n## 进展\n- ' + today + ' '
                + (progress or '由 Com「下一步」加入待办') + '\n')
        tmp = path.with_name('.' + path.name + '.com-tmp')
        with self._lock:
            try:
                tmp.write_bytes(text.encode('utf-8'))
                os.link(tmp, path)  # 目标已存在就失败，绝不覆盖 Obsidian 里刚建的同名文件
            except FileExistsError:
                return {'status': 'exists', 'path': rel, 'name': name, 'due': _front(path).get('计划结束', '')}
            finally:
                if tmp.exists():
                    tmp.unlink()
        return {'status': 'created', 'path': rel, 'name': name, 'due': target.isoformat()}

    # ---- 日程 → 当天待办（设定：日程上的事情就是当天的待办） ------------------------------------------

    def todo_sync_event(self, rel, day, note=''):
        """日程同步：只更新 `计划结束`（改期）和 Com 自己写的 `来源：日程…` 备注行，其余字节一字不动。
        返回 {'status','path','due','changed','updated'}；已经不是待处理（被勾掉/挪走）就抛 ValueError，由调用方跳过。
        不新建文件、不改标题、不动正文和其他 frontmatter —— 用户改过的备注（不以 `来源：日程` 开头）永不覆盖。"""
        target = _day(day)
        if not target:
            raise ValueError('日期无效')
        with self._lock:
            path = self._pending_file(rel)
            if not path.is_file():
                raise ValueError('这条待办已经不在待处理里了，请刷新')
            stamp = path.stat().st_mtime_ns
            lines, end = _head(path.read_bytes().decode('utf-8'))
            out, updated = list(lines), []
            index = _field(lines, end, '计划结束')
            text = '计划结束: ' + target.isoformat()
            if index is None:
                out.insert(end, text + _ending(lines[0]))
                updated.append('计划结束')
            elif _value(lines[index])[:10] != target.isoformat():
                out[index] = text + _ending(lines[index], _ending(lines[0]))
                updated.append('计划结束')
            index = _field(lines, end, '备注')
            if note and index is not None and _value(lines[index]).startswith(SOURCE_MARK):
                line = '备注: ' + yaml_value(re.sub(r'\s+', ' ', str(note)).strip()[:200])
                if _value(line) != _value(lines[index]):
                    out[index] = line + _ending(lines[index], _ending(lines[0]))
                    updated.append('备注')
            if not updated:
                return {'status': 'same', 'path': rel, 'due': target.isoformat(), 'changed': False, 'updated': []}
            self._write(path, ''.join(out), stamp)
            return {'status': 'updated', 'path': rel, 'due': target.isoformat(), 'changed': True, 'updated': updated}

    # ---- 航程结论回流（2026-10-18）：追加到待办 / 项目页的「## 进展」 ------------------------------

    def _append_progress(self, path, line):
        """在「## 进展」段末尾追加一行（没有这段就在「## 笔记」前新建，再没有就放文末）。只追加，不改别的字节。"""
        with self._lock:
            if not path.is_file():
                return False
            stamp = path.stat().st_mtime_ns
            text = path.read_bytes().decode('utf-8')
            if line.strip() in text:
                return False  # 已经写过（幂等）
            lines = text.splitlines(keepends=True)
            newline = _ending(lines[0]) if lines else '\n'
            head = next((i for i, l in enumerate(lines) if l.rstrip('\r\n') == '## 进展'), None)
            if head is None:
                notes = next((i for i, l in enumerate(lines) if l.rstrip('\r\n') == '## 笔记'), None)
                block = ['## 进展' + newline, newline, line + newline, newline]
                if notes is None:
                    if lines and not lines[-1].endswith(('\n', '\r')):
                        lines[-1] += newline
                    lines += [newline] + block
                else:
                    lines[notes:notes] = block
            else:
                end = next((i for i in range(head + 1, len(lines)) if lines[i].startswith('## ')), len(lines))
                while end > head + 1 and not lines[end - 1].strip():
                    end -= 1
                if end == len(lines) and lines and not lines[-1].endswith(('\n', '\r')):
                    lines[-1] += newline
                lines.insert(end, line + newline)
            self._write(path, ''.join(lines), stamp)
            return True

    def todo_progress(self, rel, line):
        path = self._pending_file(rel)
        if not path.is_file():  # auto-move 已挪进已完成
            path = (self.vault / '任务' / '已完成' / path.name)
        return self._append_progress(path, line)

    def todo_project(self, rel):
        """待办的「关联项目」（[[项目名]] → 项目名），没有返回空串。"""
        try:
            path = self._pending_file(rel)
        except ValueError:
            return ''
        if not path.is_file():
            path = self.vault / '任务' / '已完成' / path.name
        return re.sub(r'^\[\[|\]\]$', '', _front(path).get('关联项目', '')).split('|')[0].strip()

    def project_file(self, name):
        if not self.vault or not name or '/' in name or name.startswith('.'):
            return None
        path = self.vault / '项目' / (name + '.md')
        return path if path.is_file() else None

    def project_progress(self, name, line):
        path = self.project_file(name)
        return self._append_progress(path, line) if path else False
