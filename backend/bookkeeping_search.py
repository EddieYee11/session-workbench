"""Read-only history search through the existing shared ezBookkeeping client."""
import asyncio
import json
import math
import shutil
import time
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path


CLIENT = Path.home() / '.hermes/skills/productivity/cent-accounting/ezbookkeeping.js'

# The existing client owns service authentication. These are its read methods;
# no request body, session/lane reuse, credential output, or ledger write API.
QUERY = r'''
const {EzBookkeepingClient,loadConfig}=require(process.argv[1]);
const query=JSON.parse(process.argv[2]);
let stage='configuration';
(async()=>{
 const shared=loadConfig?loadConfig():{};
 const client=new EzBookkeepingClient({...shared,endpoint:shared.ezBookkeepingUrl||shared.endpoint,token:shared.ezBookkeepingToken||shared.token});
 // The native bookkeeping tool uses this same service JWT. A read query never
 // logs into another agent account or refreshes/writes its shared config.
 client.authorize=async()=>{throw new Error('Shared service authentication unavailable');};
 stage='transactions';
 const transactions=await client.listTransactions();
 stage='categories';
 const categories=await client.getCategoryLookup();
 stage='accounts';
 const accounts=await client.listAccounts();
 const accountNames=new Map(accounts.map(account=>[String(account.id),account]));
 stage='filter';
 const start=Date.parse(query.start_date+'T00:00:00+08:00');
 const end=Date.parse(query.end_exclusive+'T00:00:00+08:00');
 const matches=transactions.filter(tx=>{
  const numericTime=Number(tx.time);
  const at=numericTime<1e12?numericTime*1000:numericTime;
  const amount=Number(tx.sourceAmount);
  const category=categories[tx.categoryId]||{};
  return Number.isFinite(at)&&at>=start&&at<end&&
   (query.amount_minor===null||amount===query.amount_minor)&&
   (query.transaction_type==='all'||Number(tx.type)===(query.transaction_type==='income'?2:3))&&
   (!query.keyword||[tx.comment,category.primary,category.secondary].some(s=>String(s||'').includes(query.keyword)));
 }).sort((a,b)=>Number(b.time)-Number(a.time));
 const formatter=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'});
 const items=matches.slice(0,query.limit).map(tx=>{
  if(typeof tx.id==='number'&&!Number.isSafeInteger(tx.id))throw new Error('Unsafe transaction ID');
  const numericTime=Number(tx.time);
  const at=numericTime<1e12?numericTime*1000:numericTime;
  const time=formatter.format(new Date(at));
  const category=categories[tx.categoryId]||{};
  const account=accountNames.get(String(tx.sourceAccountId))||{};
  return {id:String(tx.id),date:time.slice(0,10),time,amount:Number(tx.sourceAmount)/100,
   amount_minor:Number(tx.sourceAmount),type:Number(tx.type)===2?'income':'expense',
   category:[category.primary,category.secondary].filter(Boolean).join(' / '),comment:String(tx.comment||''),
   account:String(account.name||''),currency:String(account.currency||'')};
 });
 process.stdout.write(JSON.stringify({items,scanned_count:transactions.length,matched_count:matches.length}));
})().catch(error=>{process.stdout.write(JSON.stringify({error:'accounting_read_failed',stage,status:error.response?.status||null}));process.exitCode=1;});
'''


def criteria(args):
    if not isinstance(args, dict):
        raise ValueError('查账参数无效')
    allowed = {'date', 'start_date', 'end_date', 'amount', 'keyword', 'limit', 'transaction_type'}
    if set(args) - allowed:
        raise ValueError('查账参数含未知字段')
    if args.get('date'):
        if args.get('start_date') or args.get('end_date'):
            raise ValueError('查账日期与日期范围不能同时使用')
        start = end = args['date']
    else:
        start, end = args.get('start_date'), args.get('end_date')
    try:
        first, last = date.fromisoformat(start), date.fromisoformat(end)
    except (ValueError, TypeError):
        raise ValueError('提供 YYYY-MM-DD 日期，或完整起止日期') from None
    if start != first.isoformat() or end != last.isoformat() or not 0 <= (last - first).days <= 92:
        raise ValueError('查账日期范围须有效且不超过93天')
    amount = args.get('amount')
    minor = None
    if amount is not None:
        if isinstance(amount, bool) or not isinstance(amount, (int, float)) or not math.isfinite(amount):
            raise ValueError('查询金额须为元数值')
        try:
            value = Decimal(str(amount))
            if value <= 0 or value > 99999999 or value != value.quantize(Decimal('.01')):
                raise InvalidOperation
            minor = int(value * 100)
        except InvalidOperation:
            raise ValueError('查询金额须为正数且精确到分') from None
    keyword = args.get('keyword', '')
    limit = args.get('limit', 20)
    transaction_type = args.get('transaction_type', 'expense')
    if not isinstance(keyword, str) or len(keyword) > 100:
        raise ValueError('查询关键词无效')
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 50:
        raise ValueError('查询结果条数须为1至50')
    if transaction_type not in {'expense', 'income', 'all'}:
        raise ValueError('查询交易类型无效')
    return {'start_date': first.isoformat(), 'end_date': last.isoformat(),
            'end_exclusive': (last + timedelta(days=1)).isoformat(),
            'amount_minor': minor, 'keyword': keyword.strip(), 'limit': limit,
            'transaction_type': transaction_type}


async def search(args, state=None, *, client_module=None, node=None):
    """Only matching records reach Com; internal paths cannot be supplied by the model."""
    query = criteria(args)
    module = Path(client_module) if client_module is not None else CLIENT
    binary = node or shutil.which('node')
    if not module.is_file() or not binary:
        raise ValueError('当前主机缺少共享记账查询客户端或 Node')
    started = time.monotonic()
    process = await asyncio.create_subprocess_exec(
        binary, '-e', QUERY, str(module), json.dumps(query, ensure_ascii=False),
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        cwd=str(module.parent))
    try:
        stdout, _ = await asyncio.wait_for(process.communicate(), 20)
    except (asyncio.TimeoutError, asyncio.CancelledError):
        process.kill()
        await process.wait()
        raise
    try:
        result = json.loads(stdout)
    except (ValueError, UnicodeDecodeError):
        raise ValueError('历史查账没有返回有效记录') from None
    if not isinstance(result, dict):
        raise ValueError('历史查账结果格式无效')
    if process.returncode or result.get('error'):
        status = result.get('status')
        stage = result.get('stage')
        raise ValueError('历史查账读取失败' + (f'（{stage}）' if stage in {'configuration','transactions','categories','accounts','filter'} else '')
                         + (f'（HTTP {status}）' if isinstance(status, int) else ''))
    if not isinstance(result.get('items'), list):
        raise ValueError('历史查账结果格式无效')
    return {'read_only': True,
            'criteria': {'start_date': query['start_date'], 'end_date': query['end_date'],
                         'amount': query['amount_minor'] / 100 if query['amount_minor'] is not None else None,
                         'keyword': query['keyword'], 'transaction_type': query['transaction_type']},
            'coverage': {'source': 'shared_ezbookkeeping_full_list', 'timezone': 'Asia/Shanghai',
                         'scanned_count': result['scanned_count'], 'matched_count': result['matched_count'],
                         'returned_count': len(result['items']), 'truncated': len(result['items']) < result['matched_count']},
            'items': result['items'], 'duration_ms': round((time.monotonic() - started) * 1000)}
