"""Source-grounded UI labels shared by mobile clients; raw evidence stays separate."""

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
        if any(tool == n or tool.endswith('_'+n) for n in names):return finished if done else active
    if kind in ('task.done','verified_success'):return '结果已验证，可以查看'
    if kind in ('queued','task.queued') or status == 'queued':return '已收到，正在排队'
    return '这一步已结束，可查看记录' if done else '正在处理，请稍候'
