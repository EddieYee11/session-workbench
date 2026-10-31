"""回复里的互动内容：模型写 ```com-widget 代码块，或服务端把 Markdown 表格 / 任务列表直接转成组件。

读消息时投影，不落库：历史消息也能得到互动内容，原文保持不变。
"""
import json
import re

FENCE = re.compile(r'```com-widget[ \t]*\n(.*?)\n?```[ \t]*\n?', re.S)
OPEN_FENCE = '```com-widget'
TYPES = {'checklist', 'choices', 'table', 'chart', 'steps', 'form', 'html'}
MAX_WIDGETS = 4
MAX_HTML = 64 * 1024
TABLE = re.compile(r'(?:^|\n)((?:\|[^\n]*\|[ \t]*\n)\|[ \t:|-]+\|[ \t]*\n(?:\|[^\n]*\|[ \t]*(?:\n|$))+)')
TASK_LINE = re.compile(r'^[ \t]*[-*][ \t]+\[( |x|X)\][ \t]+(.+)$')


def _valid(widget):
    if not isinstance(widget, dict) or widget.get('type') not in TYPES:
        return False
    kind = widget['type']
    if kind == 'html':
        html = widget.get('html')
        return isinstance(html, str) and 0 < len(html) <= MAX_HTML
    if kind == 'chart':
        return isinstance(widget.get('labels'), list) and isinstance(widget.get('series'), list) and bool(widget['series'])
    if kind == 'table':
        return isinstance(widget.get('columns'), list) and isinstance(widget.get('rows'), list)
    if kind == 'choices':
        return isinstance(widget.get('options'), list) and bool(widget['options'])
    if kind == 'form':
        return isinstance(widget.get('fields'), list) and bool(widget['fields']) and bool(widget.get('submit'))
    return isinstance(widget.get('items'), list) and bool(widget['items'])


def _cells(line):
    return [cell.strip().replace('**', '') for cell in line.strip().strip('|').split('|')]


def _derive_tables(text):
    widgets = []

    def replace(match):
        lines = [line for line in match.group(1).strip().split('\n') if line.strip()]
        columns, rows = _cells(lines[0]), [_cells(line) for line in lines[2:]]
        if len(rows) < 3 or len(columns) < 2:  # 两三行的小表格留在正文里更好读
            return match.group(0)
        widgets.append({'type': 'table', 'columns': columns, 'rows': rows, 'derived': True})
        return '\n'
    return TABLE.sub(replace, text), widgets


def _derive_checklist(text):
    lines, items, kept = text.split('\n'), [], []
    for line in lines:
        match = TASK_LINE.match(line)
        if match:
            items.append({'id': str(len(items)), 'text': match.group(2).strip(), 'checked': match.group(1) != ' '})
        else:
            kept.append(line)
    if len(items) < 2:
        return text, []
    return '\n'.join(kept), [{'type': 'checklist', 'items': items, 'derived': True}]


def split_widgets(text):
    """返回 (正文, 组件)。写坏的代码块只从正文里去掉，不让原始 JSON 露给他看。"""
    if not isinstance(text, str):
        return text, []
    widgets = []
    if OPEN_FENCE in text:
        def take(match):
            try:
                widget = json.loads(match.group(1))
            except ValueError:
                return ''
            if _valid(widget) and len(widgets) < MAX_WIDGETS:
                widgets.append(widget)
            return ''
        text = FENCE.sub(take, text)
    if '|' in text:
        text, derived = _derive_tables(text)
        widgets += derived
    if '[ ]' in text or '[x]' in text or '[X]' in text:
        text, derived = _derive_checklist(text)
        widgets += derived
    return (text.strip() if widgets else text), widgets[:MAX_WIDGETS]


def strip_partial_widget(text):
    """流式中途：完整的块先收起，没写完的块从开头截掉。"""
    if not isinstance(text, str) or OPEN_FENCE not in text:
        return text
    text = FENCE.sub('', text)
    start = text.find(OPEN_FENCE)
    return text[:start].rstrip() if start >= 0 else text
