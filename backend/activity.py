"""活动日志（10-25，借鉴 Muse 的 Activity log）：它替 Eddie 做过的每个写操作，一行一条，可以事后纠正。

审批已放宽到只拦不可逆删除（10-02），付款、外发、记账都没有执行前闸门；这本账就是事后那道闸：
- 数据来自工具账本 tool-effects.sqlite（agent_tools.authorize_tool 执行前写 uncertain，tool_result 回写 completed/failed）。
- uncertain 超过 10 分钟没有回音 = 结果不确定（进程断了、超时）：在「下一步」顶上出卡，让他确认「做成了 / 没做成」，
  免得记账重记或漏记。他的判断写回账本（verdict），不改原始执行状态之外的东西。
"""
import json, sqlite3, time
from pathlib import Path

VERDICTS = {'done': 'confirmed', 'not_done': 'not_done', 'wrong': 'disputed'}
ACTIONS = {'add': '新建', 'create': '新建', 'adjust': '调整', 'update': '修改', 'delete': '删除', 'remove': '删除', 'complete': '完成'}


def summarize(tool, params):
    """给人看的一句话：做了什么、对什么做的。"""
    p = params if isinstance(params, dict) else {}
    act = ACTIONS.get(p.get('action'), p.get('action') or '')
    if tool == 'bookkeeping':
        if p.get('action') == 'add':
            return ' '.join(str(x) for x in ('记账', f"¥{p.get('amount')}" if p.get('amount') is not None else '', p.get('category') or '', p.get('comment') or p.get('note') or '') if x)[:60]
        return ('账本' + act)[:60]
    if tool == 'calendar_event':
        return f"日程{act}「{p.get('title') or p.get('summary') or ''}」{p.get('start') or ''}".strip()[:60]
    if tool == 'remind':
        return f"提醒{act}「{p.get('title') or p.get('text') or ''}」{p.get('at') or p.get('due') or ''}".strip()[:60]
    if tool in ('write', 'edit', 'Write', 'Edit'):
        return '改文件 ' + Path(str(p.get('path') or p.get('file_path') or '')).name
    if tool in ('bash', 'Bash'):
        return '运行命令 ' + str(p.get('command') or '')[:40]
    return (tool + ' ' + act).strip()[:60]


class Activity:
    def __init__(self, effects, conversation, tasks, clock=time.time):
        self.path = Path(effects)
        self.conversation, self.tasks, self.clock = conversation, tasks, clock

    def _rows(self, limit):
        if not self.path.exists():
            return []
        with sqlite3.connect(self.path) as db:
            return db.execute('SELECT rowid, key, state, data FROM effects ORDER BY rowid DESC LIMIT ?', (limit,)).fetchall()

    def items(self, limit=60):
        rows = self._rows(limit)
        datas = [json.loads(r[3]) for r in rows]
        ids = [d.get('origin_message_id') for d in datas if d.get('origin_message_id')]
        messages = {}
        if ids:
            with self.conversation.db() as db:
                marks = ','.join('?' * len(ids))
                messages = {m[0]: (m[1], m[2]) for m in db.execute(f'SELECT id, text, created_at FROM messages WHERE id IN ({marks})', ids)}
        tasks = {t['id']: t for t in self.tasks.list()} if self.tasks else {}
        out = []
        for (rowid, key, state, _), d in zip(rows, datas):
            message = messages.get(d.get('origin_message_id'))
            task = tasks.get(d.get('task_id')) or {}
            at = d.get('at') or (message[1] if message else 0) or task.get('updated_at') or 0
            out.append({'key': key, 'seq': rowid, 'state': state, 'tool': d.get('tool', ''), 'at': at,
                        'summary': d.get('summary') or (('航程 · ' + task['title']) if task.get('title') else
                                                        ('「' + message[0][:20] + '」里的一步操作') if message else '较早的操作（没记下动作）'),
                        'source': (message[0] if message else task.get('title', ''))[:80], 'task_id': d.get('task_id', ''),
                        'verdict': d.get('verdict', '')})
        return out

    def uncertain(self, within=14 * 86400):
        now = self.clock()
        return [i for i in self.items(200) if i['state'] == 'uncertain' and i['at'] and 600 < now - i['at'] < within]

    def verdict(self, key, verdict):
        if verdict not in VERDICTS:
            raise ValueError('只能是 done / not_done / wrong')
        with sqlite3.connect(self.path) as db:
            row = db.execute('SELECT data FROM effects WHERE key=?', (key,)).fetchone()
            if not row:
                raise KeyError(key)
            data = json.loads(row[0]) | {'verdict': verdict, 'verdict_at': self.clock()}
            db.execute('UPDATE effects SET state=?, data=? WHERE key=?', (VERDICTS[verdict], json.dumps(data, ensure_ascii=False), key))
        return {'key': key, 'state': VERDICTS[verdict], 'verdict': verdict}
