"""打扰边界统计（11-02）：把 Com 递给他的东西和他的实际反应对起来，看哪类事总被忽略。

只给建议，不自动改规则：调不调由 Eddie 定。
没点也没划、自己过期的（stale）算「没理」；这才是最常见的反应，老的精度只看划掉会高估。
"""
import json, time

USEFUL = {'acted', 'done', 'todo'}
MIN_SHOWN = 8
LOW_USE = 0.1
KIND_LABELS = {'mail': '邮件', 'event': '日程', 'wechat': '微信', 'project': '项目', 'task': '任务', 'todo': '待办', 'finance': '财务',
               'goal': '目标', 'health': '健康', 'board': '看板', 'inbox': '收件箱', 'reminder': '提醒', 'sms': '短信', 'news': '资讯'}


def next_step_rows(store, since):
    with store.db() as db:
        return [(json.loads(r['data']), r['state']) for r in db.execute('SELECT data,state FROM items WHERE created_at>=?', (since,))]


def by_kind(rows):
    """一条建议按它引用的来源各算一次；没有依据的归到「其他」。"""
    out = {}
    for item, state in rows:
        if state in ('open', 'snoozed', 'resolved'):
            continue  # 还没轮到他反应，或者自动办完了
        kinds = {e.get('kind') or str(e.get('ref', '')).split(':')[0] for e in item.get('evidence') or []} or {'other'}
        for kind in kinds:
            bucket = out.setdefault(kind, {'shown': 0, 'used': 0, 'dismissed': 0, 'ignored': 0})
            bucket['shown'] += 1
            if state in USEFUL:
                bucket['used'] += 1
            elif state == 'dismissed':
                bucket['dismissed'] += 1
            else:
                bucket['ignored'] += 1
    return out


def suggestions(kinds):
    out = []
    for kind, row in sorted(kinds.items(), key=lambda kv: -kv[1]['shown']):
        if row['shown'] >= MIN_SHOWN and row['used'] / row['shown'] <= LOW_USE:
            label = KIND_LABELS.get(kind, kind)
            out.append({'kind': kind, 'text': f"{label}类建议出了 {row['shown']} 条，只用了 {row['used']} 条，没理 {row['ignored']} 条，可以少出。"})
    return out


def report(next_steps, triggers, days=7, clock=time.time):
    since = clock() - days * 86400
    kinds = by_kind(next_step_rows(next_steps, since))
    with triggers.db() as db:
        events = {}
        for source, outcome, count in db.execute('SELECT t.source,e.outcome,COUNT(*) FROM triggers t JOIN evals e ON e.id=t.eval_id WHERE t.received_at>=? GROUP BY 1,2', (since,)):
            events.setdefault(source, {})[outcome] = count
        repeats = db.execute('SELECT COUNT(*) FROM (SELECT matter_id FROM evals WHERE finished_at>=? AND matter_id!=\'\' GROUP BY matter_id HAVING COUNT(*)>1)', (since,)).fetchone()[0]
    return {'days': days, 'next_steps': kinds, 'events': events, 'matters_judged_repeatedly': repeats, 'suggestions': suggestions(kinds)}
