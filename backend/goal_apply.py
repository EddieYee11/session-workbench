"""把批准的提案条目落进画像与行动台。

三条不可越过的线：
1. **写前必备份** —— 所有将被触碰的文件先复制到 `_global/目标提取/backup/<时间戳>/`。
   vault 的 git 指望不上（上次提交 2026-08-01，上千个未提交改动），所以自己兜底。
2. **画像只改区块** —— 只重写 `<!-- GOAL:START --> … <!-- GOAL:END -->` 之间，
   区块外 Eddie 手写的内容原样保留（照 lifeos_mirror.py 的 LIFEOS:START/END 模式）。
3. **只增不删** —— 已存在的 vault 对象绝不覆盖；「更新状态」只追加带日期的进展行，
   不改 `状态` 字段（那是 auto-move 插件的触发键，得由 Eddie 自己动）。

LifeOS/ 只读——本模块只写真源 05-目标与规划.md，镜像由 lifeos_mirror.py 单向完成。
"""
from __future__ import annotations

import re
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

TZ = timezone(timedelta(hours=8))
HOME = Path.home()
WORKSPACE = HOME / 'AI_Work_System'
PROFILE = WORKSPACE / '_global' / '本体画像'
TARGET = PROFILE / '05-目标与规划.md'
BACKUP = WORKSPACE / '_global' / '目标提取' / 'backup'
VAULT = HOME / 'Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian'

START, END = '<!-- GOAL:START -->', '<!-- GOAL:END -->'

# 动作 → (vault 子目录, frontmatter 的 flow 值)。archive / note_only 不建对象。
VAULT_ACTIONS = {
    'create_area': ('领域', '领域'),
    'create_project': ('项目', '项目'),
    'create_task': ('任务/待处理', '任务'),
}

_TITLE = re.compile(r'^- \*\*(.+?)\*\*')
_ILLEGAL = re.compile(r'[\\/:*?"<>|#^\[\]]')

PROFILE_HEADER = """# 05-目标与规划

> 按需读取。**区块内由目标提取管线自动维护**——每天/每周综合 MBP 与 mini 各 agent
> 会话里的目标线索，经 Eddie 在 Com! 勾选批准后落库。区块外的人工内容原样保留。

"""


def safe_name(title: str) -> str:
    """vault 命名规范：短横线连接、不留空格、去掉非法字符。"""
    cleaned = _ILLEGAL.sub('', title).strip()
    return re.sub(r'\s+', '-', cleaned)[:60] or '未命名'


def vault_path(item: dict) -> Path | None:
    action = item.get('proposed_action')
    if action not in VAULT_ACTIONS:
        return None
    folder, _ = VAULT_ACTIONS[action]
    return VAULT / folder / f"{safe_name(item['title'])}.md"


# ------------------------------------------------------------------------------ 备份

def backup(paths: list[Path], stamp: str) -> tuple[Path, list[str]]:
    root = BACKUP / stamp
    saved: list[str] = []
    for path in paths:
        if not path.exists():
            continue
        if path.is_relative_to(WORKSPACE):
            rel = path.relative_to(WORKSPACE)
        elif path.is_relative_to(VAULT):
            rel = Path('vault') / path.relative_to(VAULT)
        else:
            rel = Path('other') / path.name
        dest = root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)
        saved.append(str(rel))
    return root, saved


# ------------------------------------------------------------------------ 画像区块

def render_entry(item: dict) -> str:
    """区块里每条压成一行——单行才能按标题做可靠的合并去重。"""
    tail = f"　`{item['confidence']} · 命中 {item['mentions']} 次 · {item['first_seen']}~{item['last_seen']}`"
    return f"- **{item['title']}**：{item['statement']}{tail}"


def merge(existing: list[str], incoming: list[str]) -> list[str]:
    """按标题归并：新的覆盖旧的，旧的保持原顺序。"""
    order: list[str] = []
    index: dict[str, str] = {}
    for line in existing + incoming:
        match = _TITLE.match(line)
        key = match.group(1) if match else line
        if key not in index:
            order.append(key)
        index[key] = line
    return [index[key] for key in order]


def section_lines(block: str, heading: str) -> list[str]:
    found: list[str] = []
    inside = False
    for line in block.splitlines():
        if line.startswith('## '):
            inside = line[3:].strip() == heading
            continue
        if inside and line.startswith('- '):
            found.append(line)
    return found


def split_block(text: str) -> tuple[str, str, str]:
    """返回 (区块前, 区块内, 区块后)。没有区块时区块内为空。

    区块**内**必须回传——它就是上一轮累积的长期方向/已完成/变更记录，
    丢了就等于每次落库都把画像历史清零。
    """
    if START not in text or END not in text:
        return text, '', ''
    head, _, rest = text.partition(START)
    middle, _, tail = rest.partition(END)
    return head, middle, tail


def build_block(previous: str, items: list[dict], log_line: str) -> str:
    long_term = [render_entry(i) for i in items if i['tier'] == 'long_term']
    # 已完成的不再算「在推进」，否则同一条会同时出现在两节里
    active = [f"- **{i['title']}** → `{i['existing_ref'] or '未建对象'}`"
              for i in items if i['tier'] == 'active' and i['relation'] != 'completed']
    done = [f"- {i['title']}（{datetime.now(TZ).date().isoformat()} 归档）"
            for i in items if i['relation'] == 'completed']
    body = [
        START, '',
        '## 长期方向', '',
        *(merge(section_lines(previous, '长期方向'), long_term) or ['（暂无）']), '',
        '## 在推进', '',
        *(merge(section_lines(previous, '在推进'), active) or ['（暂无）']), '',
        '## 已完成', '',
        # 参数顺序反着来：merge 里后出现的胜出，让**旧的**归档行赢，保住原始归档日期
        *(merge(done, section_lines(previous, '已完成')) or ['（暂无）']), '',
        '## 变更记录', '',
        f'- {log_line}',
        *section_lines(previous, '变更记录'),
        '',
        END,
    ]
    return '\n'.join(body)


def update_profile(items: list[dict], log_line: str) -> str:
    text = TARGET.read_text(encoding='utf-8') if TARGET.exists() else PROFILE_HEADER
    head, previous, tail = split_block(text)
    if not head.strip():
        head = PROFILE_HEADER
    if not head.endswith('\n'):
        head += '\n'
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(head + build_block(previous, items, log_line) + '\n' + tail.lstrip('\n'),
                      encoding='utf-8')
    return str(TARGET)


# ---------------------------------------------------------------------- vault 对象

def frontmatter(folder: str, flow: str, item: dict, today: str) -> str:
    domain = item.get('existing_ref', '')
    if flow == '领域':
        fields = [('flow', '领域'), ('状态', '进行中'), ('备注', item['statement'][:60]), ('created', today)]
    elif flow == '项目':
        fields = [('flow', '项目'), ('状态', '进行中'),
                  ('关联领域', f'"[[{Path(domain).stem}]]"' if domain.startswith('领域/') else ''),
                  ('计划开始', ''), ('计划结束', ''), ('完成时间', ''),
                  ('下一步', item['statement'][:60]), ('备注', f'目标提取 · 证据 {item["mentions"]} 次'),
                  ('created', today)]
    else:
        fields = [('flow', '任务'), ('状态', '待处理'),
                  ('关联项目', f'"[[{Path(domain).stem}]]"' if domain.startswith('项目/') else ''),
                  ('关联领域', f'"[[{Path(domain).stem}]]"' if domain.startswith('领域/') else ''),
                  ('计划结束', ''), ('下一步', item['statement'][:60]), ('created', today)]
    return '---\n' + '\n'.join(f'{k}: {v}' for k, v in fields) + '\n---\n'


def write_vault(item: dict, today: str) -> dict:
    """建 vault 对象。已存在就只追加一条带日期的证据行，绝不覆盖原文。"""
    path = vault_path(item)
    if path is None:
        return {'item': item['id'], 'action': item.get('proposed_action'), 'path': None}
    quote = item['evidence'][0]['quote'] if item.get('evidence') else item['statement']
    citation = f'- {today} 目标提取：{quote}'
    if path.exists():
        with path.open('a', encoding='utf-8') as handle:
            handle.write(f'\n{citation}\n')
        return {'item': item['id'], 'path': str(path.relative_to(VAULT)), 'note': '已存在，仅追加证据'}
    folder, flow = VAULT_ACTIONS[item['proposed_action']]
    body = [frontmatter(folder, flow, item, today), '', f'# {item["title"]}', '', '## 目标', '',
            item['statement'], '', '## 下一步', '', '', '## 证据', '', citation, '']
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(body), encoding='utf-8')
    return {'item': item['id'], 'path': str(path.relative_to(VAULT)), 'note': '已创建'}


def append_progress(item: dict, today: str) -> dict:
    """update_status：只追加进展行，不动 `状态` 字段。"""
    ref = item.get('existing_ref', '')
    if not ref:
        return {'item': item['id'], 'path': None, 'note': '无 existing_ref，跳过'}
    path = VAULT / ref
    if not path.exists():
        return {'item': item['id'], 'path': ref, 'note': '目标文件不存在，跳过'}
    quote = item['evidence'][0]['quote'] if item.get('evidence') else item['statement']
    with path.open('a', encoding='utf-8') as handle:
        handle.write(f'\n- {today} 目标提取：{quote}\n')
    return {'item': item['id'], 'path': ref, 'note': '已追加进展'}


# ------------------------------------------------------------------------------ 入口

def apply_decision(proposal: dict, decision: dict) -> dict:
    """把批准条目落库。返回回执摘要，供 goal_proposals.record_applied 存档。"""
    approved = set(decision.get('approved') or [])
    items = [i for i in proposal.get('items', []) if i['id'] in approved]
    today = datetime.now(TZ).date().isoformat()
    stamp = datetime.now(TZ).strftime('%Y%m%d-%H%M%S')

    if not items:
        return {'applied_at': datetime.now(TZ).isoformat(), 'count': 0, 'profile': None,
                'vault': [], 'backup': None, 'summary': '没有勾选任何条目'}

    touched = [TARGET] + [p for p in (vault_path(i) for i in items) if p] + \
              [VAULT / i['existing_ref'] for i in items
               if i.get('proposed_action') == 'update_status' and i.get('existing_ref')]
    root, saved = backup(touched, stamp)

    vault_results = []
    for item in items:
        if item.get('proposed_action') == 'update_status':
            vault_results.append(append_progress(item, today))
        elif item.get('proposed_action') in VAULT_ACTIONS:
            vault_results.append(write_vault(item, today))

    created = sum(1 for r in vault_results if r.get('note') == '已创建')
    log_line = (f'{today} 应用 {proposal["id"]}：勾选 {len(items)} 条，'
                f'新建对象 {created} 个，更新 {len(vault_results) - created} 处')
    profile = update_profile(items, log_line)

    return {
        'applied_at': datetime.now(TZ).isoformat(),
        'count': len(items),
        'profile': profile,
        'vault': vault_results,
        'backup': str(root.relative_to(WORKSPACE)) if saved else None,
        'summary': log_line,
    }
