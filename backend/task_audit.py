"""独立核对（11-02）：执行者不能自己验收。

- 任务：执行结束后，用没有工具的模型对照完成条件、真实文件和回报判断，模型碰不到也改不了任何东西。
  有真实产物才算 passed；纯文字结论只算 reviewed（看过了，但没有机器证据），不解锁依赖任务和目标完成。
  缺东西或判断不了的进「等你」，由 Eddie 决定补做还是算了；不自动派活。同一任务最多核对 3 轮。
- 写操作：记账、日程、提醒做完后回读真实系统，查不到就转成「结果不确定」，复用动态页已有的确认卡。
"""
import asyncio, json, re, sqlite3, sys, time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from hermes_review import direct_json
from memory import SENSITIVE
from quality_judge import INSTRUCTIONS as JUDGE_INSTRUCTIONS, normalize, review_input

TZ = ZoneInfo('Asia/Shanghai')
WINDOW = 7 * 86400          # 只核对近期的任务：更早的账没人记得了，翻出来只会变成噪音
SETTLE = 120                # 刚结束的任务等一会儿，让收尾的进度和产物写完
MAX_ROUNDS = 3
MAX_FILES = 8
WAITING = ('needs_work', 'uncertain')
PATHS = re.compile(r'''(?:~|(?<![\w/:.]))/[^\s`"'<>，。；：、）)\]]+\.[A-Za-z0-9]{1,6}|(?<![\w/.])(?:work|life|research|projects|_global|任务|项目|Inbox|收藏库)/[^\s`"'<>，。；：、）)\]]+\.[A-Za-z0-9]{1,6}''')
TODO_HINTS = re.compile(r'(?:行动台\s*[·:：]\s*|处理行动台待办「)([^\n」]+)')
DEFAULT_VAULT = Path.home() / 'Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian'
INSTRUCTIONS = JUDGE_INSTRUCTIONS + '''
补充规则：
- 如果完成条件只要求给出结论、判断或建议，executor_report_unverified 本身就是交付物，判断它有没有真的回答要求。
- 回报里说已写入、已发送、已修改的动作，actual_checks 没有对应文件也没有回读证据，就判 unknown。
- missing_paths 是回报提到但实际找不到的路径；是交付物的话判 revise，只是顺带提到的不算问题。
- 发送邮件和消息、提交付款或报销、发布内容，这些最后一步都由 Eddie 亲自点。执行者填好、写好草稿并停在按钮前就算做到位，「还没发」「还没提交」不是缺口，也不要建议它去发或去提交。
- earlier_reports 是这个任务前几轮的回报，也算交付；最后一轮只是在处理后续要求时，不要因为它没有重复前面的内容就判缺失。
- 只报会影响交付的缺口，不评价文风和格式。'''
READBACK_ACTIONS = {'bookkeeping': ('add',), 'calendar_event': ('create', 'add'), 'remind': ('add',)}
EFFECT_MIN_AGE, EFFECT_MAX_AGE = 300, 86400


def _resolve_hit(item, roots, vault_root):
    path = Path(item).expanduser()
    candidates = [path] if path.is_absolute() else [r / path for r in roots]
    if not path.is_absolute() and vault_root and path.parts[:2] == ('任务', '待处理'):
        candidates.append(vault_root / '任务' / '已完成' / path.name)
    return next((p for p in candidates if p.is_file() and p.stat().st_size > 0), None)


def found_paths(task, workspace, extra=(), vault=None):
    text = str(task.get('result') or '')
    prompt = str(task.get('prompt') or '')
    raw = list(extra) + [a.get('path') for a in task.get('artifacts') or [] if isinstance(a, dict) and a.get('path')] + PATHS.findall(text)
    vault_root = Path(vault) if vault else (DEFAULT_VAULT if DEFAULT_VAULT.exists() else None)
    roots = [Path(task.get('workspace_copy') or task.get('cwd') or workspace), Path(workspace)] + ([vault_root] if vault_root else [])
    existing, missing = [], []
    for item in dict.fromkeys(raw):
        hit = _resolve_hit(item, roots, vault_root)
        if hit:
            resolved = str(hit)
            if resolved not in existing:
                existing.append(resolved)
        else:
            missing.append(str(item))
    hints = list(PATHS.findall(prompt)) + [f"任务/待处理/{m.strip()}.md" for m in TODO_HINTS.findall(prompt)]
    for path_str in list(existing):
        try:
            if Path(path_str).suffix.lower() in ('.html', '.md', '.json', '.txt'):
                hints.extend(PATHS.findall(Path(path_str).read_text(encoding='utf-8', errors='ignore')[:20000]))
        except OSError:
            pass
    for item in dict.fromkeys(hints):
        hit = _resolve_hit(item, roots, vault_root)
        if hit and str(hit) not in existing:
            existing.append(str(hit))
    missing = [m for m in dict.fromkeys(missing) if m not in existing]
    return existing[:MAX_FILES], missing[:MAX_FILES]


def _clean_excerpts(checks):
    """附件摘录发给模型前去掉敏感行，和事件判断同一口径。"""
    for check in checks:
        check['excerpt'] = '\n'.join(line for line in str(check.get('excerpt') or '').splitlines() if not SENSITIVE.search(line))
    return checks


REWORK_RULE = '补的时候不要对外发送、提交、付款或发布，这些最后一步由 Eddie 自己点；填好停在按钮前，并告诉他还差哪一下。'


def rework_message(task):
    audit = task.get('audit') or {}
    gaps = '\n'.join('- ' + g.get('missing_evidence', '') for g in audit.get('gaps') or []) or '- ' + audit.get('reason', '')
    return '独立核对发现这些缺口，请补上，产物写清路径：\n' + gaps + '\n' + REWORK_RULE


def ticket_for(task):
    audit = task.get('audit') or {}
    steps = audit.get('next_steps') or []
    gaps = [g.get('missing_evidence', '') for g in audit.get('gaps') or []]
    return {'recommend': steps[0] if steps else '让它把缺的部分补上',
            'basis': '；'.join(x for x in [audit.get('reason', '')] + gaps[:2] if x)[:300],
            'on_yes': '把缺口发回给它，补完再核对一次',
            'on_no': '按现状算过，这张卡结束'}


class TaskAudit:
    def __init__(self, store, state, workspace, judge=None, effects=None, business=None, skip=None, clock=time.time, extra_paths=None):
        self.extra_paths = extra_paths
        self.store, self.state, self.workspace = store, Path(state), Path(workspace)
        self.judge = judge or (lambda data: direct_json(INSTRUCTIONS, data, 90))
        self.effects, self.business = Path(effects) if effects else None, business
        self.skip, self.clock = skip, clock

    def _recent(self):
        since = self.clock() - WINDOW
        with self.store.db() as db:
            rows = db.execute("SELECT data FROM tasks WHERE json_extract(data,'$.status')='execution_finished' AND json_extract(data,'$.updated_at')>=?", (since,)).fetchall()
        return [json.loads(r[0]) for r in rows]

    def due(self):
        now = self.clock()
        out = []
        for task in self._recent():
            audit = task.get('audit') or {}
            if (task.get('verification_status') or 'pending') != 'pending' or now - task.get('updated_at', now) < SETTLE:
                continue
            if (task.get('authorization') or {}).get('entry') == 'work_page_human_chat':
                continue
            if audit.get('result_round') == task.get('result_round', 0) or audit.get('rounds', 0) >= MAX_ROUNDS:
                continue
            if self.skip and self.skip(task):
                continue
            out.append(task)
        return sorted(out, key=lambda t: t.get('updated_at', 0))

    async def _action_checks(self, text):
        if not self.business or not text:
            return []
        checks = []
        today = datetime.fromtimestamp(self.clock(), TZ).date()
        queries = [
            ('bookkeeping', r'记账|账本', {'action': 'recent', 'count': 20}),
            ('remind', r'提醒', {'action': 'list'}),
            ('calendar_event', r'日历|日程', {'action': 'list', 'start_date': (today - timedelta(days=2)).isoformat(), 'end_date': (today + timedelta(days=90)).isoformat()}),
        ]
        for tool, pattern, args in queries:
            if not re.search(pattern, text):
                continue
            try:
                rows = (await self.business.execute(tool, args)).get('items', [])
                checks.append({'reference': f'readback:{tool}', 'check': f'{tool}_readback', 'passed': True,
                               'excerpt': json.dumps(rows[:15], ensure_ascii=False)[:3000]})
            except Exception:
                pass
        return checks

    async def audit(self, task):
        # 航程的产物挂在航程上，回报里不一定写路径。
        existing, missing = found_paths(task, self.workspace, self.extra_paths(task) if self.extra_paths else ())
        evidence = [{'reference': path, 'check': 'file_exists', 'passed': True} for path in existing]
        data = review_input(task, evidence)
        readbacks = await self._action_checks(str(task.get('result') or ''))
        data['actual_checks'] = _clean_excerpts(data['actual_checks'] + readbacks)
        data['missing_paths'] = missing
        data['earlier_reports'] = self._earlier_reports(task)
        rounds = (task.get('audit') or {}).get('rounds', 0) + 1
        record = {'rounds': rounds, 'at': self.clock(), 'files': existing, 'missing': missing, 'result_round': task.get('result_round', 0)}
        # 账本按 key 幂等，同样的 key 内容不同会报冲突；重复核对由 due() 挡，这里每次用新的。
        key = f"audit:{task['id']}:{task.get('result_round', 0)}:{time.time_ns()}"
        try:
            result = normalize(await self.judge(data))
        except Exception as error:
            # 模型出问题不算任务有问题：不进等你，下一轮再试，试满就停。
            failures = (task.get('audit') or {}).get('failures', 0) + 1
            record.update(verdict='unavailable', reason=f'{type(error).__name__}: {error}'[:200], failures=failures, rounds=rounds - 1)
            if failures < MAX_ROUNDS:
                record.pop('result_round')
            self.store.change(task['id'], f'{key}:failed:{failures}', 'audit.unavailable', '核对模型不可用，稍后再试', audit=record)
            return 'unavailable'
        record.update(verdict=result['verdict'], reason=result['reason'], gaps=result['evidence_gaps'], next_steps=result['next_steps'])
        verdict = result['verdict']
        if verdict == 'pass' and existing:
            criteria = [c['id'] for c in task.get('acceptance_criteria') or []]
            proof = [{'reference': path, 'check': 'independent_audit', 'passed': True} for path in existing]
            proof += [{'reference': existing[0], 'check': 'independent_audit', 'passed': True, 'criterion_id': c} for c in criteria]
            self.store.change(task['id'], key + ':record', 'audit.done', '独立核对通过', audit=record)
            self.store.verify(task['id'], proof)
            return 'passed'
        status = {'pass': 'reviewed', 'revise': 'needs_work'}.get(verdict, 'uncertain')
        label = {'reviewed': '独立核对看过，内容符合要求', 'needs_work': '独立核对发现缺口', 'uncertain': '独立核对判断不了'}[status]
        self.store.change(task['id'], key, 'audit.done', label, audit=record, verification_status=status)
        return status

    def _earlier_reports(self, task):
        if task.get('result_round', 0) < 2:
            return []
        with self.store.db() as db:
            rows = db.execute("SELECT text FROM events WHERE task_id=? AND kind='execution_finished' ORDER BY seq DESC LIMIT 3", (task['id'],)).fetchall()
        current = str(task.get('result') or '')
        return [r[0][-3000:] for r in rows if r[0] and r[0] != current][:2]

    def waiting(self):
        return [t for t in self._recent() if t.get('verification_status') in WAITING and not (t.get('audit') or {}).get('settled')]

    def _effects_due(self):
        if not self.effects or not self.effects.exists():
            return []
        now = self.clock()
        with sqlite3.connect(self.effects) as db:
            rows = db.execute("SELECT key,data FROM effects WHERE state='completed' AND json_extract(data,'$.tool') IN ('bookkeeping','calendar_event','remind') "
                              "AND json_extract(data,'$.at') BETWEEN ? AND ? AND json_extract(data,'$.audit') IS NULL AND json_extract(data,'$.verdict') IS NULL",
                              (now - EFFECT_MAX_AGE, now - EFFECT_MIN_AGE)).fetchall()
            later = db.execute("SELECT json_extract(data,'$.tool'),json_extract(data,'$.at') FROM effects "
                               "WHERE json_extract(data,'$.detail.action') IN ('delete','remove','cancel','update','adjust')").fetchall()
        due = []
        for key, raw in rows:
            data = json.loads(raw)
            if (data.get('detail') or {}).get('action') not in READBACK_ACTIONS[data['tool']]:
                continue
            # 之后又改过或删过同类记录，回读对不上不代表当初没做成。
            data['_changed_later'] = any(tool == data['tool'] and (at or 0) > data['at'] for tool, at in later)
            due.append((key, data))
        return due

    async def readback(self, data):
        """True=查到，False=确实查不到，None=这条查不了。"""
        detail = data.get('detail') or {}
        if data['_changed_later']:
            return None
        tool = data['tool']
        if tool == 'bookkeeping':
            try:
                amount = round(float(detail.get('amount')) * 100)
            except (TypeError, ValueError):
                return None
            rows = (await self.business.execute('bookkeeping', {'action': 'recent', 'count': 30})).get('items', [])
            comment = str(detail.get('comment') or detail.get('note') or '')
            return any(abs(int(r.get('sourceAmount', r.get('amount', 0)) or 0) - amount) < 1 and comment in str(r.get('comment') or '') for r in rows)
        if tool == 'remind':
            text = str(detail.get('text') or detail.get('title') or '')
            due = str(detail.get('at') or detail.get('due') or '')
            # 提醒响过就不在待办里了，到点之后没法回读。
            if not text or not due or due <= datetime.fromtimestamp(self.clock(), TZ).strftime('%Y-%m-%d %H:%M'):
                return None
            rows = (await self.business.execute('remind', {'action': 'list'})).get('items', [])
            return any(text in str(r.get('text') or '') for r in rows)
        title = str(detail.get('summary') or detail.get('title') or '')
        if not title:
            return None
        today = datetime.fromtimestamp(self.clock(), TZ).date()
        rows = (await self.business.execute('calendar_event', {'action': 'list', 'start_date': (today - timedelta(days=2)).isoformat(), 'end_date': (today + timedelta(days=90)).isoformat()})).get('items', [])
        return any(title in str(r.get('title') or r.get('summary') or '') for r in rows)

    async def check_effects(self, limit=5):
        if not self.business:
            return 0
        done = 0
        for key, data in self._effects_due()[:limit]:
            found = await self.readback(data)
            changed = data.pop('_changed_later')
            data['audit'] = {'found': found, 'at': self.clock(), **({'changed_later': True} if changed else {})}
            with sqlite3.connect(self.effects) as db:
                db.execute('UPDATE effects SET state=?, data=? WHERE key=?', ('uncertain' if found is False else 'completed', json.dumps(data, ensure_ascii=False), key))
            done += 1
        return done

    async def run_once(self, limit=2):
        for task in self.due()[:limit]:
            try:
                if await self.audit(task) == 'unavailable':
                    break
            except ValueError as error:
                # 一条任务出问题不能挡住后面的。
                print('task_audit skip', task['id'], str(error)[:200], file=sys.stderr, flush=True)
        with __import__('contextlib').suppress(asyncio.TimeoutError):
            await asyncio.wait_for(self.check_effects(), 60)
