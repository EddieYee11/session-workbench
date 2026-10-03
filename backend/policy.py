"""Cheap source and action guard; language-model assertions are never authorization."""
import json
import re
import shlex
from pathlib import Path

ACTION = re.compile(r'请|帮我|给我|替我|把.{0,100}(?:做|改|查|记|收|存|导)|连接|启动|无线调试|跑起来|检查|排查|诊断|修复|修好|修改|优化|实现|添加|增加|编写|整理|记一下|记一笔|记账|记录|提醒|收藏|转写|导出|分析|查一下|查查|继续|照.{0,20}(?:办|做)|按.{0,40}(?:做|办|流程)|停止|取消|归档|删除|清空|销毁|发送|发布', re.S)
WISH = re.compile(r'^(?:我)?(?:最近)?(?:想|希望|打算|以后|有空|不想)|(?:不想折腾|好烦|真累|太累|心情不好)')
QUOTE = re.compile(r'「[^」]*」|“[^”]*”|"[^"\n]*"|```[\s\S]*?```|(?m:^>.*$)')
DANGER = re.compile(r'\b(?:rm|rmdir|unlink|shred|wipefs|mkfs|dd|mv)\b|\b(?:DROP|TRUNCATE)\b|(?:Remove-Item|deleteMany|rmtree)|(?:-X|--request)\s+(?:DELETE|PUT)|\.delete\s*\(|\bos\.remove\s*\(|\bfind\b[^\n]*-delete|(?<![><])>(?!>)\s*[^&\s]|\bsed\s+-i\b', re.I)
READ_ACTIONS = {'recent', 'summary', 'list', 'get', 'search', 'status', 'read', 'inspect', 'query'}


def assignment(text, quote):
    if not isinstance(quote, str) or len(quote.strip()) < 3 or quote not in text:
        return False
    # An instruction wholly inside quoted material has no authority by itself.
    spans = list(QUOTE.finditer(text))
    at = text.find(quote)
    if any(m.start() <= at and at + len(quote) <= m.end() for m in spans):
        return False
    external = QUOTE.sub('', text).strip()
    clause = QUOTE.sub('', quote).strip()
    if WISH.search(clause) and not re.search(r'请|帮我|现在.{0,10}(?:做|查|改)|记一下|提醒我', clause):
        return False
    return bool(ACTION.search(clause) and ACTION.search(external))


def deletion_risk(tool, args):
    action = str(args.get('action', args.get('operation', ''))).lower()
    blob = json.dumps(args, ensure_ascii=False)
    if action in ('delete', 'remove', 'clear', 'destroy', 'overwrite', 'truncate', 'purge'):
        return True
    if tool in ('bash', 'powershell', 'execute_command') and DANGER.search(str(args.get('command', ''))):
        return True
    if tool in ('write', 'edit'):
        return True  # Existing paths require explicit recoverability evidence from the worker copy.
    return bool(re.search(r'永久删除|不可逆|清空数据|破坏性覆盖', blob))


def recoverable_remove(tool,args,copy):
    if not copy or tool.lower()!='bash':return False
    command=args.get('command','')
    if re.search(r'[;&|`$<>*?\n]',command):return False
    try:argv=shlex.split(command)
    except ValueError:return False
    if not argv or argv[0] not in ('rm','rmdir','unlink'):return False
    paths=[]
    for word in argv[1:]:
        if word.startswith('-'):
            if word not in ('-r','-f','-rf','-fr','-v','--'):return False
        else:paths.append(word)
    root=Path(copy).resolve()
    return bool(paths and all((root/p).resolve()!=root and (root/p).resolve().is_relative_to(root) for p in paths))


def source(conversation, data):
    with conversation.db() as db:
        row = db.execute("SELECT * FROM messages WHERE id=? AND role='user'", (data.get('origin_message_id'),)).fetchone()
    if not row or row['request_id'] != data.get('origin_request_id'):
        raise ValueError('需要真实用户消息和 request_id')
    accepts = getattr(conversation, 'accepts_origin', lambda sid, mid: sid == conversation._session_id())
    if not accepts(data.get('origin_session_id'), row['id']):
        raise ValueError('主对话来源不匹配')
    result = dict(row)
    result['raw_text'] = result['text']
    # Resolve only a real, immediate reply to this conversation's offered choices.
    # The prior human must already have authorized work; assistant text cannot create it.
    reply = re.fullmatch(r'\s*([A-Ca-c])(?:[、.：:\s]+(.*))?\s*', result['text'], re.S)
    if reply:
        with conversation.db() as db:
            preceding = db.execute("SELECT * FROM messages WHERE created_at<? ORDER BY created_at DESC,id DESC LIMIT 1", (row['created_at'],)).fetchone()
            parent = db.execute("SELECT * FROM messages WHERE id=? AND role='user'", (preceding['parent_id'],)).fetchone() if preceding and preceding['role']=='assistant' else None
        if parent and assignment(parent['text'], parent['text']):
            choices = list(re.finditer(r'(?m:^\s*)([A-C])(?:[、.：:\s]+)([^\n]+)', preceding['text']))
            selected = next((m.group(2).strip() for m in choices if m.group(1)==reply.group(1).upper()), None)
            if len(choices)>=2 and selected and assignment(selected, selected):
                # No blanket confirmation of deletion/overwriting through an option letter.
                if not re.search(r'删除|清空|销毁|覆盖|抹掉', selected+parent['text']):
                    result['text'] = parent['text']+'\n选择：'+selected+'\n用户补充：'+result['raw_text']
                    result['authorization_parent_message_id'] = parent['id']
                    result['authorization_option'] = selected
    return result
