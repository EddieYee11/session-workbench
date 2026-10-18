"""助手回复末尾的「下一步选项」（r2-chat 轨道）。

约定：模型在回复最后一行写 `[[选项: 帮我改到明天 | 先不管 | 看看详情]]`。
落库时从正文剥离，存进 messages.suggestions；流式过程中半截标记也不下发。
"""
import re

_FULL = re.compile(r'\s*\[\[\s*选项\s*[:：]([^\[\]]*)\]\]\s*$')
_PREFIX = '[[选项'
MAX_OPTIONS = 3
MAX_CHARS = 16


def split_options(text: str) -> tuple[str, list[str]]:
    """完整标记：返回 (去掉标记的正文, 选项)。没有标记就原样返回、选项为空。"""
    if not isinstance(text, str):
        return text, []
    match = _FULL.search(text)
    if not match:
        return text, []
    options: list[str] = []
    for raw in re.split(r'[|｜]', match.group(1)):
        option = raw.strip().strip('「」"\'')
        if option and len(option) <= MAX_CHARS and option not in options:
            options.append(option)
    return text[:match.start()].rstrip(), options[:MAX_OPTIONS]


def strip_partial(text: str) -> str:
    """流式中途：去掉末尾还没写完的 `[[选项…`，免得原始标记闪现。"""
    body, _ = split_options(text)
    if body is not text:
        return body
    start = body.rfind('[')
    if start < 0:
        return body
    # 往前找到这串 [ 的起点，例如 "[[选"
    while start > 0 and body[start - 1] == '[':
        start -= 1
    tail = re.sub(r'\s', '', body[start:]).replace('：', ':')
    if ']' not in tail and (_PREFIX.startswith(tail) or tail.startswith(_PREFIX)):
        return body[:start].rstrip()
    return body
