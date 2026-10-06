#!/usr/bin/env python3
"""目标提取合成器：读采集 bundle → 分级目标提案 JSON。

两段式（语料 30 天约 13 万 token，一次调用吃不下，见 tools/goal_harvest/README.md）：

  A 抽取  把语料按**记录边界**切块，每块抽「体现目标/承诺」的条目，带证据锚点
  B 综合  合并表达同一件事的条目、判 relation、定分级与置信，产出提案

**为什么不用 hermes_review.review_json()**：它内部直接 `json.loads`，模型一旦把
JSON 包进 ```json 代码块就整段失败且无法挽救（run 已持久化）。本模块用同一个
HermesRuntime、同一句「只做本轮数据判断」护栏，只在解析处容忍代码块与前后缀。

**为什么 B 段用 `sources` 回指而不让模型重抄证据**：模型重抄 60 字原文极易漂移，
一旦漂了就变成幻觉证据。让 B 段只回指 A 段的条目 id，证据由本模块从 A 段原样
拼回——模型不可能编造出它没被给过的引文。

用法:
    python3 goal_synth.py --mode weekly                 # 全量 30 天
    python3 goal_synth.py --mode daily                  # 只看昨天以来
    python3 goal_synth.py --mode weekly --dry-run       # 只跑 A 段，看抽出了什么
    python3 goal_synth.py --mode weekly --bundles a.md b.md --out /tmp/x.json
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hermes_runtime import HermesRuntime  # noqa: E402

TZ = timezone(timedelta(hours=8))
HOME = Path.home()
WORKSPACE = HOME / 'AI_Work_System'
INBOX = WORKSPACE / '_global' / '目标提取' / 'inbox'
PROPOSALS = WORKSPACE / '_global' / '目标提取' / 'proposals'
PROFILE = WORKSPACE / '_global' / '本体画像'
EVENTS = WORKSPACE / '_global' / '记忆库' / '事件'
KNOWLEDGE = WORKSPACE / '_global' / '记忆库' / '知识'
SKILLS = WORKSPACE / '.claude' / 'skills'
TOOLS = WORKSPACE / 'work' / '工具与效率'
VAULT = HOME / 'Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian'

CHUNK_CHARS = 40000   # 单块上限；更小=注意力更集中但调用更多
DAILY_MAX = 3         # 日增量上限（见计划的日/周分工）

GUARD = '\n只做本轮数据判断，不调用工具，不派发任务，不写入记忆或业务对象。'
# 与 tools/goal_harvest/collect.py 的 MACHINE_SOURCES 对应：缺哪台的包要能指名道姓。
EXPECTED_MACHINES = ('Eddie-MBP', 'EddiedeMac-mini')

_FENCE = re.compile(r'```(?:json)?\s*(.*?)```', re.S)
_ENTRY_LINE = re.compile(r'^-\s*(⟨[^⟩]*⟩)\s*(.*)$')
_TOKEN_FIELDS = re.compile(r'^⟨(.*)⟩$')


# ------------------------------------------------------------------ LLM 调用（容错解析）

def _loads(text: str) -> object:
    """容忍 ```json 代码块与前后解释文字。"""
    text = (text or '').strip()
    if not text:
        raise ValueError('Hermes 返回空内容')
    fence = _FENCE.search(text)
    if fence:
        text = fence.group(1).strip()
    try:
        return json.loads(text)
    except ValueError:
        pass
    start, end = text.find('{'), text.rfind('}')
    if start >= 0 and end > start:
        return json.loads(text[start:end + 1])
    raise ValueError(f'无法解析 JSON：{text[:200]}')


async def _ask_json(state: Path, request_id: str, instructions: str, payload: dict, timeout: float) -> object:
    client = HermesRuntime(state, 'com-goal-' + request_id, instructions=instructions + GUARD)
    output, completed = '', False
    try:
        async with asyncio.timeout(timeout):
            async for kind, chunk in client.stream(json.dumps(payload, ensure_ascii=False), request_id):
                if kind == 'assistant.completed':
                    output = chunk.get('content', '')
                if kind == 'run.completed':
                    completed = True
        if not completed:
            raise ValueError('Hermes 合成未正常结束')
        return _loads(output)
    finally:
        if not completed and client.run_id:
            try:
                await client.abort()
            except Exception:
                pass


# ---------------------------------------------------------------------------- 语料

def parse_records(text: str) -> list[dict]:
    """把 bundle 切成记录。记录 = `- ⟨锚点⟩ 正文` 行 + 其后的缩进续行。"""
    records: list[dict] = []
    current: dict | None = None
    for line in text.splitlines():
        match = _ENTRY_LINE.match(line)
        if match:
            if current:
                records.append(current)
            current = {'token': match.group(1), 'lines': [line], 'text': match.group(2)}
        elif current is not None and line.startswith('  '):
            current['lines'].append(line)
            current['text'] += '\n' + line[2:]
        elif current is not None:
            records.append(current)
            current = None
    if current:
        records.append(current)
    for record in records:
        record['date'] = token_date(record['token'])
    return records


def token_date(token: str) -> str:
    inner = _TOKEN_FIELDS.match(token)
    if not inner:
        return ''
    parts = inner.group(1).split('|')
    return parts[2][:10] if len(parts) >= 3 else ''


def load_bundles(paths: list[Path]) -> tuple[list[dict], list[str]]:
    """返回 (全部记录, 各 bundle 的机器名)。缺件是显式事实，不是静默跳过。"""
    records: list[dict] = []
    machines: list[str] = []
    for path in paths:
        text = path.read_text(encoding='utf-8', errors='ignore')
        found = re.search(r'<!--\s*machine:\s*(\S+)\s*-->', text)
        machines.append(found.group(1) if found else path.stem)
        records += parse_records(text)
    records.sort(key=lambda r: r['token'])
    return records, machines


def freshness_gaps(bundles: list[Path]) -> list[str]:
    """对面机器没交今天的包要明说。少了半边会话的提案看起来一样完整，
    不说就没人知道这次只综合了一台机器。"""
    newest: dict[str, str] = {}
    for path in bundles:
        text = path.read_text(encoding='utf-8', errors='ignore')
        found = re.search(r'<!--\s*machine:\s*(\S+)\s*-->', text)
        machine = found.group(1) if found else path.stem
        day = path.stem.rsplit('-', 1)[-1]
        if len(day) == 8 and day.isdigit():
            newest[machine] = max(newest.get(machine, ''), day)
    today = datetime.now(TZ).date().strftime('%Y%m%d')
    gaps = []
    for machine in EXPECTED_MACHINES:
        day = newest.get(machine)
        if day is None:
            gaps.append(f'缺少 {machine} 的采集包')
        elif day != today:
            gaps.append(f'{machine} 的采集包是 {day} 的，不是今天')
    return gaps


def chunk_records(records: list[dict], limit: int = CHUNK_CHARS) -> list[str]:
    """按记录边界贪心装箱；绝不从中途切开一条记录。"""
    chunks: list[str] = []
    buffer: list[str] = []
    size = 0
    for record in records:
        block = '\n'.join(record['lines'])
        if buffer and size + len(block) > limit:
            chunks.append('\n'.join(buffer))
            buffer, size = [], 0
        buffer.append(block)
        size += len(block) + 1
    if buffer:
        chunks.append('\n'.join(buffer))
    return chunks


def _norm(text: str) -> str:
    return re.sub(r'\s+', '', text)


def _sig(*parts: str) -> str:
    """输入指纹。放进 request_id 后：输入没变就命中 Hermes 的幂等缓存，
    提示词或语料一改就重新计算——开发迭代与生产幂等兼得。"""
    return hashlib.sha256('\x00'.join(parts).encode()).hexdigest()[:10]


# ---------------------------------------------------------------------------- A 段

EXTRACT_PROMPT = """你在从 Eddie（用户）与 AI 助手的会话记录里，抽取**真正体现目标与承诺**的条目。

## 收录
- Eddie 明确表达的**长期方向**：愿景、想长期做的事、职业或内容方向
- Eddie 明确说**正在推进**的项目或计划（"我要做/我在做/打算/准备/计划/接下来/以后"）
- Eddie 明确**承诺**的具体动作（"明天要发/记得/别忘了/下周提交/我答应"）

## 坚决不收录
- 排障、调试、配置过程（VPN、网络、脚本报错、装软件）——那是做事过程中的杂音，不是目标本身
- AI 自己提出的方案或建议（Eddie 没有明确采纳并承诺的）
- 寒暄、情绪、对已发生事情的纯叙述
- 一次性技术问答、查询
- 随口一提、玩笑、假设（"要是……就好了"）

**宁缺毋滥：拿不准就不收。**

## 证据
输入每条以 `⟨来源|会话|时间戳|序号⟩` 开头，这就是证据锚点。
- `token`：**原样复制**该锚点，一字不改
- `quote`：不超过 60 字的**逐字原文片段**，必须能在输入里一字不差地找到

## 输出（只输出 JSON，不要代码块不要解释）
{"items":[{"statement":"这条目标/承诺的一句话概括","kind":"long_term|active|commitment","quote":"逐字原文","token":"⟨...⟩","date":"YYYY-MM-DD"}]}
没有任何命中就输出 {"items":[]}"""


async def extract_chunk(state: Path, request_id: str, chunk: str, timeout: float) -> list[dict]:
    data = await _ask_json(state, request_id, EXTRACT_PROMPT, {'记录': chunk}, timeout)
    items = data.get('items') if isinstance(data, dict) else None
    out: list[dict] = []
    for item in items or []:
        if not isinstance(item, dict):
            continue
        quote = str(item.get('quote') or '').strip()
        token = str(item.get('token') or '').strip()
        statement = str(item.get('statement') or '').strip()
        if not (quote and token and statement):
            continue
        out.append({
            'statement': statement,
            'kind': str(item.get('kind') or '').strip(),
            'quote': quote,
            'token': token,
            'date': str(item.get('date') or '').strip() or token_date(token),
        })
    return out


# ---------------------------------------------------------------------------- B 段

SYNTH_PROMPT = """你在把从多个 AI 会话里抽出的目标线索，合并成一份**分级提案**。

## 任务
1. **合并**表达同一件事的条目（字面不同但指同一件事要合并，如"AI 内容变现"与"把内容做成收入"）。
2. **分级 tier**：
   - long_term：**愿景级**方向——跨年仍成立，不随技术方案或产品形态变化（如「做内容品牌」「转 AI 方向的工作」）
   - active：正在推进的项目或计划。**技术选型、架构决策、"在哪个基座上搭"都属这里**——那是项目的属性，不是长期方向
   - commitment：具体待办承诺——有时间点或明确动作
3. **定置信 confidence**：high = 多次明确出现或有明确承诺动词；medium = 出现过但语境偏弱；low = 单次、含糊、或疑似排障被误判成目标。
4. **判关系 relation**，对照下面「现状」**全部五段**（画像 / 行动台 / 已建成的 skill / 已有产出目录 / 共享知识库 / 事件归档）。**尤其注意**：vault 行动台里没有的东西，很可能已经做成 skill 或工具了——先核对再下结论：
   - new：现状里没有，是新目标
   - existing：现状里已有对应对象 → 在 existing_ref 填它的**路径**（如 `项目/探馆系列.md`）
   - completed：从证据看这件事已经做完了
   - changed：现状里有一件相关的事，但方向或范围变了
   **不要用字面匹配**——语义相同即视为同一件事。
5. **给动作 proposed_action**：create_area（新领域）/ create_project（新项目）/ create_task（新任务）/ update_status（更新状态）/ archive（可归档）/ note_only（只记录）

## 铁律
- 每条 `sources` 只能引用**给定的线索 id**（a0、a1…），不得发明 id。
- **排障过程绝不算目标**。拿不准就标 low，宁可挡住也不要凑数。
- `statement` **不超过 60 字**，一句话说清；别把整段项目史塞进一条。
- 单次出现的**配置/权限/开关类指令**（如"给某端开全部权限""关掉某个功能"），若看不出它服务于某个长期方向，标 low 放 suspect——那是操作，不是目标。
- relation 要结合「事件归档」判断：归档里已记录完成的，用 completed。
- 用 `changed` 时**必须**填 existing_ref；填不出就说明是 new。
- 若线索之间互相矛盾或证据太薄，放进 suspect，不进 items。

## 线索（A 段抽取结果）
{{ITEMS}}

## 现状（画像 + 行动台）
{{CONTEXT}}

## 输出（只输出 JSON，不要代码块不要解释）
{"items":[{"id":"goal_xxx","tier":"long_term|active|commitment","title":"短标题","statement":"完整陈述","sources":["a0","a3"],"confidence":"high|medium|low","relation":"new|existing|completed|changed","existing_ref":"","proposed_action":"note_only"}],"suspect":[{"title":"…","why":"为什么存疑","sources":["a7"]}],"notes":""}"""


def build_context() -> str:
    """画像 + 行动台清单。给 B 段判 relation 用，不做字面匹配的前提是先看见现状。"""
    parts: list[str] = []
    for name in ('00-核心身份.md', '05-目标与规划.md'):
        path = PROFILE / name
        if path.exists():
            parts.append(f'### 画像/{name}\n{path.read_text(encoding="utf-8").strip()}')
    rows: list[str] = []
    for folder, kind in (('领域', '领域'), ('项目', '项目'), ('任务/待处理', '任务')):
        directory = VAULT / folder
        if not directory.exists():
            continue
        for file in sorted(directory.glob('*.md')):
            if file.name.startswith('00-'):
                continue
            meta = read_frontmatter(file)
            rows.append(f'- [{kind}] {file.relative_to(VAULT)} | 状态={meta.get("状态", "")}'
                        f' | 下一步={meta.get("下一步", "")}')
    if rows:
        parts.append('### 行动台对象\n' + '\n'.join(rows))
    # 这三段专门回答「这事我是不是已经做了」——vault 里没有的东西往往已经做成 skill/工具了
    skills = [p.name for p in sorted(SKILLS.glob('*')) if p.is_dir()] if SKILLS.exists() else []
    if skills:
        parts.append('### 已建成的 skill\n- ' + '\n- '.join(skills))
    tools = [p.name for p in sorted(TOOLS.iterdir()) if p.is_dir()] if TOOLS.exists() else []
    if tools:
        parts.append('### work/工具与效率/ 下已有的产出目录\n- ' + '\n- '.join(tools))
    notes = [p.stem for p in sorted(KNOWLEDGE.glob('*.md'))] if KNOWLEDGE.exists() else []
    if notes:
        parts.append('### 共享知识库条目\n- ' + '\n- '.join(notes))
    milestones = [f'- {p.stem}' for p in sorted(EVENTS.glob('*/*.md')) if p.parent.name[:4].isdigit()]
    if milestones:
        parts.append('### 事件归档（里程碑；据此判断某目标是否已完成）\n' + '\n'.join(milestones))
    return '\n\n'.join(parts) if parts else '（现状为空）'


def read_frontmatter(path: Path) -> dict:
    meta: dict[str, str] = {}
    try:
        lines = path.read_text(encoding='utf-8', errors='ignore').splitlines()
    except OSError:
        return meta
    if not lines or lines[0].strip() != '---':
        return meta
    for line in lines[1:]:
        if line.strip() == '---':
            break
        if ':' in line:
            key, _, value = line.partition(':')
            meta[key.strip()] = value.strip().strip('"')
    return meta


# ---------------------------------------------------------------------------- 编排

async def synthesize(state: Path, bundles: list[Path], *, mode: str = 'weekly',
                     timeout: float = 240, log=print) -> dict:
    records, machines = load_bundles(bundles)
    gaps: list[str] = freshness_gaps(bundles)
    if mode == 'daily':
        cutoff = (datetime.now(TZ).date() - timedelta(days=1)).isoformat()
        records = [r for r in records if r['date'] >= cutoff]
    if not records:
        return {'generated_at': datetime.now(TZ).isoformat(), 'mode': mode, 'machines': machines,
                'items': [], 'suspect': [], 'gaps': ['no_records'] + gaps, 'notes': ''}

    chunks = chunk_records(records)
    log(f'[synth] {len(records)} 条记录 / {len(chunks)} 块 / 来源 {machines}')

    run = f'goal-{mode}-{datetime.now(TZ).date().strftime("%Y%m%d")}'
    extracted: list[dict] = []
    for index, chunk in enumerate(chunks):
        got = None
        tag = f'{run}-a{index}-{_sig(chunk, EXTRACT_PROMPT)}'
        for attempt in (0, 1):  # 实测 Hermes 首调偶发 unknown；换 request_id 重试一次
            try:
                got = await extract_chunk(state, f'{tag}-r{attempt}', chunk, timeout)
                break
            except Exception as exc:
                log(f'[synth] 块 {index} 第 {attempt + 1} 次失败：{exc}')
                await asyncio.sleep(3)
        if got is None:  # 两次都失败：记进 gaps，不拖垮整轮
            gaps.append(f'chunk{index}_failed')
            continue
        log(f'[synth] 块 {index}: {len(got)} 条')
        extracted += got

    # 证据核验：引文必须能在语料里逐字找到，否则是幻觉，直接丢。
    corpus = _norm('\n'.join(r['text'] for r in records))
    kept: list[dict] = []
    dropped = 0
    for item in extracted:
        if _norm(item['quote']) in corpus:
            item['id'] = f'a{len(kept)}'
            kept.append(item)
        else:
            dropped += 1
    if dropped:
        gaps.append(f'unverified_quotes:{dropped}')
        log(f'[synth] 丢弃 {dropped} 条引文无法核验的条目')

    if not kept:
        return {'generated_at': datetime.now(TZ).isoformat(), 'mode': mode, 'machines': machines,
                'items': [], 'suspect': [], 'gaps': gaps + ['no_verified_items'], 'notes': ''}

    by_id = {item['id']: item for item in kept}
    clues = [{'id': i['id'], 'statement': i['statement'], 'kind': i['kind'],
              'date': i['date'], 'quote': i['quote']} for i in kept]
    # 用 replace 而非 format：提示词里含字面 JSON 花括号，format 会当成占位符。
    prompt = (SYNTH_PROMPT
              .replace('{{ITEMS}}', json.dumps(clues, ensure_ascii=False, indent=1))
              .replace('{{CONTEXT}}', build_context()))
    result = await _ask_json(state, f'{run}-b-{_sig(prompt)}', prompt, {}, timeout)
    if not isinstance(result, dict):
        raise ValueError('B 段返回的不是 JSON 对象')

    return finish(result, by_id, mode, machines, gaps)


def finish(result: dict, by_id: dict, mode: str, machines: list[str], gaps: list[str]) -> dict:
    """把 B 段的 sources 回指展开成真实证据；低置信与坏引用一律降到 suspect。"""
    items: list[dict] = []
    suspect: list[dict] = list(result.get('suspect') or [])
    for raw in result.get('items') or []:
        if not isinstance(raw, dict):
            continue
        refs = [by_id[s] for s in (raw.get('sources') or []) if s in by_id]
        if not refs:
            suspect.append({'title': raw.get('title', ''), 'why': '无可核验证据', 'sources': []})
            continue
        evidence = [{'source': _token_parts(r['token'])[0], 'date': r['date'],
                     'quote': r['quote'], 'token': r['token']} for r in refs]
        item = {
            'id': str(raw.get('id') or f'goal_{len(items)}'),
            'tier': str(raw.get('tier') or 'commitment'),
            'title': str(raw.get('title') or '').strip(),
            'statement': str(raw.get('statement') or '').strip(),
            'evidence': evidence,
            'mentions': len(evidence),
            'first_seen': min((e['date'] for e in evidence if e['date']), default=''),
            'last_seen': max((e['date'] for e in evidence if e['date']), default=''),
            'confidence': str(raw.get('confidence') or 'low'),
            'relation': str(raw.get('relation') or 'new'),
            'existing_ref': str(raw.get('existing_ref') or '').strip(),
            'proposed_action': str(raw.get('proposed_action') or 'note_only'),
        }
        # 低置信只存不提案（计划硬约束：宁缺毋滥）
        if item['confidence'] == 'low':
            suspect.append({'title': item['title'], 'why': '低置信', 'sources': [r['token'] for r in refs],
                            'item': item})
        else:
            items.append(item)

    items.sort(key=lambda i: ({'long_term': 0, 'active': 1, 'commitment': 2}.get(i['tier'], 3), -i['mentions']))
    if mode == 'daily':
        items = items[:DAILY_MAX]
    return {
        'generated_at': datetime.now(TZ).isoformat(),
        'mode': mode,
        'machines': machines,
        'items': items,
        'suspect': suspect,
        'gaps': gaps,
        'notes': str(result.get('notes') or '').strip(),  # 模型的合并说明，不是缺件
    }


def _token_parts(token: str) -> list[str]:
    inner = _TOKEN_FIELDS.match(token)
    return inner.group(1).split('|') if inner else []


def render_markdown(result: dict) -> str:
    """人读版：人工核对与 Com! 卡片文案共用同一份来源。"""
    lines = [f"# 🎯 目标提案 · {result.get('mode', '')} · {result.get('generated_at', '')[:16].replace('T', ' ')}", '',
             f"> 来源：{' + '.join(result.get('machines', []))}　｜　每条引文均可在采集 bundle 里逐字核验", '']
    if result.get('gaps'):
        lines += [f"> ⚠️ 缺件：{'；'.join(result['gaps'])}", '']
    badge = {'existing': '已有', 'completed': '已完成', 'changed': '有变化'}
    for key, label in (('long_term', '长期方向'), ('active', '在推进'), ('commitment', '待办承诺')):
        group = [i for i in result.get('items', []) if i.get('tier') == key]
        if not group:
            continue
        lines += [f'## {label}', '']
        for item in group:
            head = f"### {item['title']}"
            if item['relation'] in badge:
                head += f"　`{badge[item['relation']]}`"
            lines += [head, '', item['statement'], '',
                      f"- 置信 {item['confidence']}｜命中 {item['mentions']} 次｜{item['first_seen']} ~ {item['last_seen']}"
                      f"｜建议 `{item['proposed_action']}`"]
            if item.get('existing_ref'):
                lines.append(f"- 对应现状：`{item['existing_ref']}`")
            lines.append('')
            for ev in item.get('evidence', []):
                lines.append(f"    - `{ev['source']}` {ev['date']}：「{ev['quote']}」")
            lines.append('')
    if result.get('suspect'):
        lines += ['## 存疑（未提案，仅留存）', '']
        for item in result['suspect']:
            lines.append(f"- **{item.get('title', '')}** — {item.get('why', '')}")
        lines.append('')
    if result.get('notes'):
        lines += ['## 合成说明', '', result['notes'], '']
    return '\n'.join(lines)


# ---------------------------------------------------------------------------- CLI

def default_bundles() -> list[Path]:
    """inbox 里最新的各机器 bundle（同机器取最新一份）。"""
    latest: dict[str, Path] = {}
    for path in sorted(INBOX.glob('*.md')):
        machine = path.name.split('-')[0]
        latest[machine] = path
    return sorted(latest.values())


async def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='目标提取合成器')
    parser.add_argument('--mode', choices=('daily', 'weekly'), default='weekly')
    parser.add_argument('--bundles', nargs='*', type=Path, help='bundle 文件，默认取 inbox 最新')
    parser.add_argument('--state', type=Path, default=Path(os.environ.get('WORKBENCH_STATE') or HOME / '.session-workbench'))
    parser.add_argument('--out', type=Path, help='输出 JSON 路径，默认 _global/目标提取/proposals/')
    parser.add_argument('--timeout', type=float, default=240)
    parser.add_argument('--dry-run', action='store_true', help='只跑 A 段，打印抽取结果')
    args = parser.parse_args(argv)

    bundles = args.bundles or default_bundles()
    if not bundles:
        raise SystemExit(f'inbox 里没有 bundle：{INBOX}')

    if args.dry_run:
        records, machines = load_bundles(bundles)
        chunks = chunk_records(records)
        base_id = f'goal-dry-{datetime.now(TZ).strftime("%Y%m%d%H%M%S")}'
        total = 0
        for index, chunk in enumerate(chunks):
            got = await extract_chunk(args.state, f'{base_id}-a{index}', chunk, args.timeout)
            total += len(got)
            print(f'--- 块 {index}（{len(chunk)} 字符）：{len(got)} 条 ---')
            for item in got:
                print(f"  [{item['kind']}] {item['statement']}")
                print(f"      {item['token']} {item['quote']}")
        print(f'=== 合计 {total} 条 / {len(chunks)} 块 / 来源 {machines} ===')
        return 0

    result = await synthesize(args.state, bundles, mode=args.mode, timeout=args.timeout)
    target = args.out
    if target is None:
        PROPOSALS.mkdir(parents=True, exist_ok=True)
        target = PROPOSALS / f'{args.mode}-{datetime.now(TZ).date().strftime("%Y%m%d")}.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    digest = target.with_suffix('.md')
    digest.write_text(render_markdown(result), encoding='utf-8')
    # 入队：文件是给人看的底稿，Com! 卡片读的是这行写入的 sqlite 提案。
    # 空提案不入队——不能让 Eddie 收到一张没有内容的卡。
    queued = None
    if result['items']:
        from goal_proposals import GoalProposals
        queued = GoalProposals(args.state).create(
            datetime.now(TZ).date().strftime('%Y%m%d'), result, mode=args.mode)['id']
    print(json.dumps({'out': str(target), 'markdown': str(digest), 'proposal': queued,
                      'items': len(result['items']), 'suspect': len(result['suspect']),
                      'gaps': result['gaps']}, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(asyncio.run(main()))
