"""Source-grounded UI labels shared by mobile clients; raw evidence stays separate."""

# 「工作过程」文案表：与 iOS `WorkProcess.swift` 的 StepKind 同一张表。
# 每类：匹配的工具名、进行中的多个说法（按步骤轮换）、做完 n 次的合并说法。
STEP_COPY = (
    ('ledger', ('bookkeeping_search', 'finance', 'ledger', 'expense_search'), ('翻账本', '查查花销', '对一下账'), lambda n: '查了账本' if n == 1 else f'查了 {n} 次账本'),
    ('money', ('bookkeeping', 'expense', 'business_operation'), ('正在记账', '记上一笔', '拨拉算盘'), lambda n: f'记了{_n(n)}笔账'),
    ('remember', ('memory_save', 'memory_write', 'memory_update', 'retain', 'remember'), ('记到小本本上', '把这件事记下', '写进记忆里'), lambda n: f'记下了{_n(n)}件事'),
    ('recall', ('memory_recall', 'memory_read', 'memory_search', 'recall', 'memory'), ('翻翻记忆', '想想你说过的', '回忆一下'), lambda n: '翻了翻记忆' if n == 1 else f'翻了 {n} 次记忆'),
    ('remind', ('remind', 'reminder', 'alarm'), ('定个提醒', '帮你记着时间', '设一个闹钟'), lambda n: f'定了{_n(n)}个提醒'),
    ('calendar', ('calendar', 'schedule', 'event'), ('看看日程', '翻一下日历', '对一下时间'), lambda n: '看了日程' if n == 1 else f'看了 {n} 次日程'),
    ('check', ('task_status', 'get_task', 'work_proposal_status', 'recent_work_sessions', 'list_tasks'), ('看看进度', '问问帮手做到哪了', '核对进展'), lambda n: '核对了进度' if n == 1 else f'核对了 {n} 次进度'),
    ('task', ('task_submit', 'create_task', 'propose_work', 'task_send', 'update_task', 'cancel_task', 'dispatch'), ('派活给电脑', '找帮手接手', '安排任务'), lambda n: f'派了{_n(n)}件活'),
    ('overview', ('personal_overview', 'personal_briefing', 'briefing', 'overview'), ('扫一眼今天', '看看总览', '翻今天的摘要'), lambda n: '看了总览'),
    ('mail', ('gmail', 'mail', 'email'), ('翻邮件', '看看信箱', '拆封邮件'), lambda n: '翻了邮箱' if n == 1 else f'翻了 {n} 次邮箱'),
    ('device', ('device_call', 'health', 'contacts', 'device'), ('问问你的手机', '在手机上查', '用一下手机'), lambda n: '用了手机' if n == 1 else f'用了 {n} 次手机'),
    ('web', ('web_search', 'web_extract', 'websearch', 'webfetch', 'browser', 'fetch', 'http', 'url'), ('上网查一查', '正在搜网页', '去网上找答案'), lambda n: f'查了{_n(n)}个网页'),
    ('edit', ('edit', 'write', 'patch', 'file_write', 'write_file', 'apply_patch', 'multiedit'), ('正在改文件', '动笔修改', '把改动写进去'), lambda n: f'改了{_n(n)}处文件'),
    ('search', ('grep', 'find', 'glob', 'ls', 'search_files', 'search', 'rg'), ('正在翻资料', '在资料堆里找线索', '四处翻翻看'), lambda n: f'翻了{_n(n)}处资料'),
    ('read', ('read', 'read_file', 'context_read', 'cat', 'view', 'open'), ('正在读文件', '打开文件细看', '逐行过一遍'), lambda n: f'读了{_n(n)}个文件'),
    ('shell', ('bash', 'terminal', 'shell', 'exec', 'run_command', 'command', 'process'), ('在电脑上跑命令', '敲几行命令', '让电脑动起来'), lambda n: f'跑了{_n(n)}条命令'),
)
OTHER = ('other', (), ('动手处理', '在忙这一步', '处理一下'), lambda n: f'做了{_n(n)}件事')
HIDDEN_TOOLS = {'react_to_user_message', 'react', 'think'}


def _n(n):
    return '一' if n == 1 else f' {n} '


def _seed(text):
    value = 0
    for ch in str(text):
        value = (value * 31 + ord(ch)) & 0xFFFF
    return value


def step_kind(tool):
    """工具名 → 文案类别；内部工具不展示返回 None，未知工具归 other（不暴露内部名字）。"""
    name = str(tool or '').lower().split('__')[-1]
    if name in HIDDEN_TOOLS:
        return None
    for row in STEP_COPY:
        if name in row[1]:
            return row
    for row in STEP_COPY:
        if any(len(word) > 3 and word in name for word in row[1]):
            return row
    return OTHER


def group_steps(tasks):
    """同类连续工具调用合并：连续 6 次搜索 → 一组「翻了 6 处资料」。"""
    groups = []
    for task in tasks or []:
        if not isinstance(task, dict) or not (task.get('kind') == 'tool' or str(task.get('id', '')).startswith('tool-')):
            continue
        row = step_kind(task.get('tool'))
        if row is None:
            continue
        if groups and groups[-1]['kind'] == row[0]:
            groups[-1]['steps'].append(task)
        else:
            groups.append({'kind': row[0], 'copy': row, 'steps': [task]})
    for group in groups:
        n = len(group['steps'])
        live_row = group['copy']
        group['running'] = any(t.get('status') == 'running' for t in group['steps'])
        seed = _seed(group['steps'][0].get('id', ''))
        group['live_text'] = live_row[3](n) + '…' if n > 1 else live_row[2][seed % len(live_row[2])]
        group['done_text'] = live_row[3](n)
        group['count'] = n
        del group['copy']
    return groups


def current_step(message):
    """在跑的用户消息此刻在做什么：iOS 顶栏气泡与流里那一行用同一句。"""
    groups = group_steps(message.get('tasks'))
    seed = _seed(message.get('id', ''))
    if groups and groups[-1]['running']:
        return groups[-1]['live_text']
    if message.get('phase') in ('responding', 'speaking'):
        return ('在组织回复', '开始写回复', '把结果理一理')[seed % 3]
    if not groups:
        return ('在想怎么办', '先理一理思路', '琢磨一下')[seed % 3]
    return ('想想下一步', '接着往下做', '看看还缺什么')[(seed + len(groups)) % 3]

def display_event(event):
    kind = str(event.get('kind') or event.get('type') or '')
    status = str(event.get('status') or '')
    tool = str(event.get('tool') or event.get('tool_name') or '')
    if kind.endswith('.failed') or status == 'failed':
        return '这一步遇到了问题，查看详情'
    if status in ('unknown','uncertain'):
        return '结果还在核实，暂不重复操作'
    if kind in ('task.review','approval_required','awaiting_review') or status in ('approval_required','awaiting_review'):
        return '这一步需要你确认'
    if kind in ('cancelled','task.cancelled') or status == 'cancelled':
        return '已停止'
    done = kind.endswith('.completed') or status in ('done','completed','execution_finished')
    for names, active, finished in (
        (('web_search','web_extract','browser'), '正在查找资料', '资料查询已结束'),
        (('memory_recall','memory_read'), '正在查找之前记下的事', '记忆查询已结束'),
        (('memory_save','memory_write'), '正在整理要记住的事', '记忆整理已结束'),
        (('calendar_read','calendar_event'), '正在查看或整理日程', '日程处理已结束'),
        (('terminal','shell','exec','run_command'), '正在电脑上处理', '这一步已结束'),
        (('task_submit','create_task'), '正在安排帮手处理', '任务安排已有回执'),
        (('read_file','search_files','context_read'), '正在查看相关资料', '资料读取已结束'),
        (('bookkeeping','business_operation'), '正在办理这件事', '已收到处理回执'),
        (('file_write','write_file','patch'), '正在整理文件', '文件处理已结束'),
    ):
        if any(tool == n or tool.endswith('_'+n) for n in names):
            if done:return finished
            break
    row = step_kind(tool) if tool else None
    if row:
        # 进行中按「工作过程」类别轮换说法，不再一律「正在查看相关资料」；
        # 完成只说做了几次，不把调用结束当成办成。
        if not done:return row[2][_seed(event.get('id') or tool) % len(row[2])]
        if row is not OTHER:return row[3](1)
    if kind in ('task.done','verified_success'):return '结果已验证，可以查看'
    if kind in ('queued','task.queued') or status == 'queued':return '已收到，正在排队'
    return '这一步已结束，可查看记录' if done else '正在处理，请稍候'
