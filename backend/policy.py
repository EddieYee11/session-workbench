"""Cheap source and action guard; language-model assertions are never authorization."""
import json
import re
import shlex
from decimal import Decimal,InvalidOperation
from pathlib import Path

ACTION = re.compile(r'请|帮我|给我|替我|把.{0,100}(?:做|改|查|记|收|存|导)|连接|启动|无线调试|跑起来|检查|排查|诊断|修复|修好|修改|优化|实现|添加|增加|编写|整理|记一下|记一笔|记账|记录|提醒|收藏|转写|导出|分析|查一下|查查|继续|接着做|恢复|照.{0,20}(?:办|做)|按.{0,40}(?:做|办|流程)|停止|取消|暂停|先别管|停下|归档|删除|清空|销毁|发送|发布|验收|合入', re.S)
WISH = re.compile(r'^(?:我)?(?:最近)?(?:想|希望|打算|以后|有空|不想)|(?:不想折腾|好烦|真累|太累|心情不好)')
QUOTE = re.compile(r'「[^」]*」|“[^”]*”|"[^"\n]*"|```[\s\S]*?```|(?m:^>.*$)')
DANGER = re.compile(r'\b(?:rm|rmdir|unlink|shred|wipefs|mkfs|dd|mv)\b|\b(?:DROP|TRUNCATE)\b|(?:Remove-Item|deleteMany|rmtree)|(?:-X|--request)\s+(?:DELETE|PUT)|\.delete\s*\(|\bos\.remove\s*\(|\bfind\b[^\n]*-delete|(?<![><])>(?!>)\s*[^&\s]|\bsed\s+-i\b', re.I)
READ_ACTIONS = {'recent', 'summary', 'list', 'get', 'search', 'status', 'read', 'inspect', 'query'}
CONTINUATION = re.compile(r'\s*(?:好[的]?[,，\s]*)?(?:继续(?:吧|做|执行)?|接着(?:做|执行)|恢复(?:执行)?|按(?:照)?(?:上面|刚才|之前|你说的)(?:那个|的)?(?:做|来|执行)?|就按你说的(?:做|来))(?:[。！!,.，\s]*)', re.S)
CONTEXTUAL_FOLLOWUP = re.compile(r'\s*(?:请|帮我)?(?:验收|合入|合并)(?:一下)?(?:刚才|上面|之前|那个|这个)[^\n]{0,24}[。！!,.，\s]*')
RESTRICTION_ONLY = re.compile(r'^(?:不要|别|禁止|不许|保持|只读|限制|只能|只做)')
MONEY_NUMBER=r'[0-9零〇一二两三四五六七八九十百千万亿]+(?:[.点][0-9零〇一二两三四五六七八九]+)?'
MONEY=re.compile(r'(?P<yuan>'+MONEY_NUMBER+r')\s*(?:元|圆|块钱?|块)(?:\s*(?P<jiao>[0-9零〇一二两三四五六七八九])\s*(?:毛|角)(?:\s*(?P<fen>[0-9零〇一二两三四五六七八九])\s*分?)?|\s*(?P<only_fen>[0-9零〇一二两三四五六七八九])\s*分|\s*(?P<tail>[0-9零〇一二两三四五六七八九]{1,2})(?![0-9零〇一二两三四五六七八九十百千万亿]))?')
COINS=re.compile(r'(?P<jiao>[0-9零〇一二两三四五六七八九])\s*(?:毛|角)(?:\s*(?P<fen>[0-9零〇一二两三四五六七八九])\s*分?)?|(?P<only_fen>[0-9零〇一二两三四五六七八九])\s*分(?!钟)')
BOOK_VERB=re.compile(r'记(?:个|一下|一笔|一条)?账|记一(?:笔|条)|记一下|记下|记录(?:一下|这笔|一笔)?')
EXPENSE_FACT=re.compile(r'花费|花了|消费|支出|付了|支付|付款|到账|收入|收了')
BOOK_BLOCK=re.compile(r'(?:不要|别|不想|不用|不需要|先不|暂不|不能|禁止|不许|先别).{0,8}(?:记|记录|添加|保存)|(?:只是|仅是|只做|只要).{0,8}(?:举例|例子|测试|分析|讨论|候选)|(?:如果|假如|比如|例如|假设)|(?:以后|将来|有空|打算|计划|准备|明天|后天).{0,20}(?:记|花|消费|支出|买)|(?:花|消费|支出).{0,20}(?:预算|预计)|(?:能否|是否|会不会|能不能|可以|能|会).{0,8}(?:记账|记录|记个账).{0,4}(?:吗|么|嘛|不)|(?:记账|记个账).{0,8}(?:系统|软件|工具|功能|能力|怎么|如何)|(?:能|会)(?:记账|记个账)[?？]|(?:查|查询|查看|统计|检索|看看).{0,24}(?:记账|账单|账目|支出|消费|花费)|(?:记账|消费|支出|花费).{0,24}(?:多少|几笔|有哪些|统计)')


def quote_free(text):
    return QUOTE.sub('',str(text)).strip()


def _money_number(value):
    """Strict Chinese cardinal/decimal numbers; never guess a unit or a missing digit."""
    digits={**dict(zip('零〇一二两三四五六七八九',(0,0,1,2,2,3,4,5,6,7,8,9))),
            **{str(n):n for n in range(10)}}
    if '.' in value or '点' in value:
        whole,fraction=re.split(r'[.点]',value,maxsplit=1)
        if not fraction or any(character not in digits for character in fraction):raise ValueError('Invalid money fraction')
        return _money_number(whole)+Decimal('0.'+''.join(str(digits[character]) for character in fraction))
    if all(character in digits for character in value):
        return Decimal(''.join(str(digits[character]) for character in value))
    small={'十':10,'百':100,'千':1000};large={'万':10000,'亿':100000000}
    total=section=number=0
    for character in value:
        if character in digits:number=number*10+digits[character]
        elif character in small:section+=(number or 1)*small[character];number=0
        elif character in large:total+=(section+number or 1)*large[character];section=number=0
        else:raise ValueError('Invalid money number')
    return Decimal(total+section+number)


def _money_matches(text):
    matches=[];covered=[]
    for pattern in (MONEY,COINS):
        for match in pattern.finditer(text):
            if any(start<=match.start()<end for start,end in covered):continue
            groups=match.groupdict();value=_money_number(groups.get('yuan') or '0')
            for field,divisor in (('jiao',10),('fen',100),('only_fen',100)):
                if groups.get(field):value+=_money_number(groups[field])/divisor
            if groups.get('tail'):
                tail=groups['tail'];value+=_money_number(tail)/(10**len(tail))
            try:precise=value==value.quantize(Decimal('.01'))
            except InvalidOperation:precise=False
            if value>0 and precise:
                matches.append((match.start(),match.end(),value));covered.append(match.span())
    for match in re.finditer(r'[¥￥]\s*(\d+(?:\.\d{1,2})?)(?!\d)',text):
        if not any(start<=match.start()<end for start,end in covered):
            value=Decimal(match[1])
            if value>0:matches.append((match.start(),match.end(),value));covered.append(match.span())
    # Bare Arabic amounts are common ASR output. Exclude dates, times and quantities.
    for match in re.finditer(r'(?<![\d./:：-])\d+(?:\.\d{1,2})?(?![\d./:：-]|\s*(?:年|月|日|号|点|个|笔|条|次|件|分钟|秒|小时|天|公里|米|岁|折|%))',text):
        if not any(start<=match.start()<end for start,end in covered):
            value=Decimal(match[0])
            if value>0:matches.append((match.start(),match.end(),value))
    return sorted(matches)


def money_amounts(text):
    return [value for _,_,value in _money_matches(quote_free(text))]


def bookkeeping_query(text):
    external=quote_free(text)
    financial=r'账单|账目|账本|记账|消费|支出|交易|费用'
    return bool(re.search(financial,external) and
                re.search(r'(?:找|查|查询|搜索|检索|统计|看看|看一下).{0,100}(?:'+financial+r')|(?:是什么|什么|哪笔|哪一笔|多少|几笔|有哪些).{0,20}(?:'+financial+r')|(?:'+financial+r').{0,20}(?:是什么|是什么消费|什么支出|哪笔|哪一笔|多少|几笔|有哪些)',external))


def bookkeeping_intent(text, *, expense_entry=False):
    """A current concrete expense or affirmative record request, regardless of modality."""
    external=quote_free(text)
    classified=re.sub(r'能不能(?=(?:帮我|给我|替我|把))','请',external)
    if not external or bookkeeping_query(external) or BOOK_BLOCK.search(classified) or re.search(r'(?:为什么|为何).{0,30}(?:记账|记录|花费)',external):return False
    explicit=bool(BOOK_VERB.search(external))
    amounts=_money_matches(external)
    if explicit and not re.search(r'记(?:个|一下|一笔|一条)?账|记一笔|记录(?:这笔|一笔)',external):
        explicit=bool(MONEY.search(external) or COINS.search(external) or re.search(r'[¥￥]',external) or EXPENSE_FACT.search(external))
    if explicit and re.search(r'我(?:想|希望)|希望',external) and not amounts:return False
    fact=bool(EXPENSE_FACT.search(external) and amounts and not re.search(r'我(?:想|希望)|最近想|希望|将会|要花|要买|想买|想花|预计|预算',external))
    if not explicit and re.search(r'我(?:的)?(?:朋友|同事|家人)|(?:他|她|他们|她们)(?:买|花|消费|支出|付)',external):return False
    if not explicit and not fact and not expense_entry:return False
    # A selected expense entry supplies intent, never amount/purpose or contradictory intent.
    if expense_entry and not explicit and not fact:
        if re.search(r'[?？]|吗|么|嘛|怎么|如何|能否|会不会|能不能|想|希望|以后|计划|准备',external):return False
    return bool(explicit or fact or expense_entry)


def bookkeeping_details(text,amount, *, expense_entry=False):
    external=quote_free(text)
    if not bookkeeping_intent(external,expense_entry=expense_entry):return False,'没有明确当前记账意图；查询、候选或引用不授权添加'
    if isinstance(amount,bool) or not isinstance(amount,(int,float)):
        return False,'缺少有效记账金额'
    try:requested=Decimal(str(amount))
    except InvalidOperation:return False,'缺少有效记账金额'
    matches=_money_matches(external)
    try:precise=requested.is_finite() and requested>0 and requested==requested.quantize(Decimal('.01'))
    except InvalidOperation:precise=False
    if not precise or requested not in [value for _,_,value in matches]:
        return False,'金额不在真实用户消息中，先补齐金额'
    purpose=external
    for start,end,_ in reversed(matches):purpose=purpose[:start]+' '+purpose[end:]
    purpose=re.sub(r'(?:今天|昨天|前天|刚才|刚刚|现在|早上|中午|晚上|这笔|一笔|一次|帮我|给我|替我|麻烦|我要|我想|我需要|能不能|请|我|你|一下|记个账|记账|记一下|记一笔|记一条|记下|记录|花费|花了|消费|支出|付了|支付|付款|到账|收入|收了|金额|人民币|费用|元|块钱|块|毛|角|分|继续|接着做|按上面那个|恢复执行)', '',purpose)
    if not re.search(r'[\u4e00-\u9fffA-Za-z]',purpose):return False,'缺少记账用途，先补齐事项'
    return True,''


def source_link(row):
    return {'message_id':row['id'],'request_id':row.get('request_id'),
            'revision':row.get('revision',0),'text':row['text'][:6000]}


def _reference(row):
    try:
        reference=row.get('reference')
        return json.loads(reference) if isinstance(reference,str) else reference or {}
    except (ValueError,TypeError):
        return {}


def _prior_human(conversation,row):
    """Use the selected real reply or nearest human turn, never assistant wording."""
    reference=_reference(row)
    with conversation.db() as db:
        if row.get('supplement_to_message_id'):
            candidate=db.execute("SELECT * FROM messages WHERE id=? AND role='user'",(row['supplement_to_message_id'],)).fetchone()
        elif reference:
            if reference.get('mode')!='reply' or reference.get('source_session_id','personal-main')!='personal-main':
                return None
            candidate=db.execute('SELECT * FROM messages WHERE id=?',(reference.get('id'),)).fetchone()
        else:
            candidate=db.execute('SELECT * FROM messages WHERE created_at<? ORDER BY created_at DESC,id DESC LIMIT 1',
                                 (row['created_at'],)).fetchone()
        if candidate and candidate['role']=='assistant' and candidate['parent_id']:
            candidate=db.execute("SELECT * FROM messages WHERE id=? AND role='user'",(candidate['parent_id'],)).fetchone()
        elif candidate and candidate['role']!='user' and not reference:
            candidate=db.execute("SELECT * FROM messages WHERE role='user' AND created_at<? ORDER BY created_at DESC,id DESC LIMIT 1",
                                 (row['created_at'],)).fetchone()
    return dict(candidate) if candidate and candidate['role']=='user' and candidate['created_at']<row['created_at'] else None


def _continuation_parent(conversation,row):
    seen={row['id']};links=[];cursor=row
    for _ in range(12):
        parent=_prior_human(conversation,cursor)
        if not parent or parent['id'] in seen:return None,[]
        seen.add(parent['id']);links.append(source_link(parent))
        if CONTINUATION.fullmatch(parent['text']):
            cursor=parent;continue
        if RESTRICTION_ONLY.search(parent['text']) or re.fullmatch(r'\s*(?:谢谢|好的|好|嗯|知道了)[。！!,.，\s]*',parent['text']):
            cursor=parent;continue
        if assignment(parent['text'],parent['text']) and not re.search(r'停止|取消|暂停|先别管|停下',parent['text']):
            return parent,list(reversed(links))
        return None,[]
    return None,[]


def assignment(text, quote):
    if not isinstance(quote, str) or len(quote.strip()) < 2 or quote not in text:
        return False
    if CONTINUATION.fullmatch(text):
        return False  # A bare continuation needs a resolved real historical assignment.
    # An instruction wholly inside quoted material has no authority by itself.
    spans = list(QUOTE.finditer(text))
    at = text.find(quote)
    if any(m.start() <= at and at + len(quote) <= m.end() for m in spans):
        return False
    external = QUOTE.sub('', text).strip()
    clause = QUOTE.sub('', quote).strip()
    current_bookkeeping=bookkeeping_intent(clause)
    if current_bookkeeping and bookkeeping_intent(external):return True
    if BOOK_VERB.search(clause) and BOOK_BLOCK.search(clause) and not re.search(r'提醒|查询|检查|查看|分析|统计|修复|修好|修改|实现|添加|编写',clause):
        return False
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


def readonly_shell(tool,args):
    """Only obvious inspection argv bypass the write ledger; Shell syntax never does."""
    if tool.lower() not in ('bash','execute_command'):return False
    command=args.get('command','')
    if not isinstance(command,str) or re.search(r'[;&|`$<>\n\r]',command):return False
    try:argv=shlex.split(command)
    except ValueError:return False
    if not argv:return False
    if argv[0]=='pwd':return all(word in ('-L','-P') for word in argv[1:])
    if argv[0]=='ls':return True
    if argv[0]=='git' and len(argv)>1 and argv[1] in ('status','diff','log','show'):
        return not any(word in ('--ext-diff','--textconv','--no-index') or
                       word.startswith(('--output','--exec','--config-env')) or word=='-o' for word in argv[2:])
    return False


def readonly_restriction(text):
    return bool(re.search(r'只读|只(?:做|进行)?(?:查看|检查|阅读)(?:[,，。\s]|$)|不(?:要)?(?:改|修改)(?:代码|文件|任何)|不要修改、删除|禁止(?:修改|写入)|不做(?:修改|写入)',str(text)))


def action_is_readonly(tool,args):
    kind=tool.lower()
    if kind in ('write','edit','multiedit','delete','remove'):return False
    return kind in ('read','grep','find','ls','glob','webfetch','websearch','bookkeeping_search') or args.get('action','') in READ_ACTIONS or readonly_shell(kind,args)


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
    result['source_links']=[source_link(result)]
    if result.get('supplement_to_message_id'):
        if data.get('supplement_to_message_id') not in (None,result['supplement_to_message_id']):
            raise ValueError('补充来源关联不匹配')
        parent=_prior_human(conversation,result)
        supplemental_links=[]
        if parent and (CONTINUATION.fullmatch(parent['text']) or parent.get('supplement_to_message_id')):
            original,links=_continuation_parent(conversation,parent)
            if original:
                supplemental_links=links+[source_link(parent)];parent=original
        if not parent:
            raise ValueError('补充没有真实原消息')
        # The server stages the real reply relation. Source validity does not
        # require an action verb; task and financial write intent are checked
        # separately by the operation that actually needs them.
        result['authorization_parent_message_id']=parent['id']
        result['source_links']=(supplemental_links or [source_link(parent)])+[source_link(result)]
        result['text']=parent['text']+''.join('\n用户后续限制：'+link['text'] for link in supplemental_links
                                            if readonly_restriction(link['text']))+'\n用户本次补充（保留原授权范围）：'+result['raw_text']
        result['supplement']=True
    if CONTINUATION.fullmatch(result['raw_text']) or CONTEXTUAL_FOLLOWUP.fullmatch(result['raw_text']):
        parent,links=_continuation_parent(conversation,result)
        if parent:
            result['authorization_parent_message_id']=parent['id']
            result['source_links']=links+[source_link(result)]
            restrictions=[link['text'] for link in links if RESTRICTION_ONLY.search(link['text'])]
            result['text']=parent['text']+(''.join('\n用户后续限制：'+text for text in restrictions))+'\n用户继续原事项：'+result['raw_text']
            result['continuation']=True
        else:
            result['continuation_unresolved']=True
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
                    result['source_links']=[source_link(dict(parent)),source_link({**result,'text':result['raw_text']})]
    return result
