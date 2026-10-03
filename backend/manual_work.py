"""Trusted Work-page chats are human messages, not model-proposed assignments."""
from policy import source
from operation_policy import effective_sandbox


def work_chat(conversation, proposals, data, context):
    row = source(conversation, context)
    text = data.get('prompt', '').strip()
    if not text or text != row['raw_text'].strip() or len(text) > 6000:
        raise ValueError('工作消息必须来自本次实际发送的用户原文')
    agent = data.get('agent')
    requested_sandbox = data.get('sandbox', 'danger-full-access')
    if agent not in ('claude', 'codex'):
        raise ValueError('工作页提供 Claude Code / Codex')
    sandbox = effective_sandbox(requested_sandbox)
    cwd = proposals._cwd(data['relative_cwd'])
    request_id = 'manual:' + data['request_id']
    links = row.get('source_links', [])
    scope = '用户在工作页主动发送的原文及所选目录；已撤销 Com 的只读限制，统一最高操作权限；普通对话直接回答，明确操作按原要求执行；严重不可逆动作仍按具体动作检查'
    task = {
        'agent': agent, 'cwd': cwd, 'sandbox': sandbox, 'requested_sandbox': requested_sandbox, 'interactive': True,
        'automatic': False, 'title': text[:120],
        'origin_session_id': context['origin_session_id'],
        'origin_message_id': row['id'], 'origin_request_id': row['request_id'],
        'source_links': links, 'source_message_ids': [link['message_id'] for link in links],
        'context_revision': 1, 'latest_user_message_id': row['id'],
        'completion_condition': '回答本条用户消息；执行操作时如实提供结果与检查证据',
        'prompt': '用户工作对话原文：\n' + text + '\n\n这是用户直接发送的工作消息。问候、问题、讨论均正常回复，不要求改写成交办句。只在用户要求操作时执行，不把愿望或引用当成操作命令。',
    }
    authorization = {
        'request_id': request_id, 'cwd': cwd, 'sandbox': sandbox,
        'source_message_id': row['id'], 'source_request_id': row['request_id'],
        'source_quote': row['raw_text'], 'source_links': links, 'scope': scope,
        'entry': 'work_page_human_chat',
    }
    return task, authorization, request_id
