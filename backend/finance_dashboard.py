"""One source of truth: read ezBookkeeping and project a monthly expense dashboard."""
import asyncio,time
from datetime import datetime,timedelta
from zoneinfo import ZoneInfo
from business_tools import BusinessTools
TZ=ZoneInfo('Asia/Shanghai')

def project(transactions,tree,accounts,month,now=None):
    now=now or datetime.now(TZ)
    first=datetime.strptime(month,'%Y-%m').replace(tzinfo=TZ)
    end=(first.replace(day=28)+timedelta(days=4)).replace(day=1)
    categories={};account_map={}
    def visit(rows,parent=''):
        for row in rows:
            if not isinstance(row,dict):continue
            name=row.get('name') or '未分类';key=str(row.get('id',''))
            categories[key]={'id':key,'name':name,'group':parent or name}
            visit(row.get('subCategories',[]),parent or name)
    for rows in tree.values():
        if isinstance(rows,list):visit(rows)
    def account_rows(rows):
        for a in rows:
            account_map[str(a['id'])]=a
            account_rows(a.get('subAccounts',[]))
    account_rows(accounts)
    items=[]
    for tx in transactions:
        if tx.get('type')!=3:continue
        stamp=float(tx['time']);stamp=stamp/1000 if stamp>1e11 else stamp
        at=datetime.fromtimestamp(stamp,TZ)
        if not first<=at<end:continue
        amount=int(tx['sourceAmount']);account=account_map.get(str(tx.get('sourceAccountId')),{});category=categories.get(str(tx.get('categoryId')),{'id':str(tx.get('categoryId','unknown')),'name':'未分类','group':'未分类'})
        items.append({'id':str(tx['id']),'amount_minor':amount,'currency':account.get('currency') or 'UNKNOWN',
          'category_id':category['id'],'category':category['name'],'group':category['group'],'comment':str(tx.get('comment','')),
          'date':at.date().isoformat(),'time':at.isoformat(),'account':account.get('name','')})
    items.sort(key=lambda i:i['time'],reverse=True)
    currencies=[]
    for currency in sorted({i['currency'] for i in items}):
        rows=[i for i in items if i['currency']==currency];groups=[]
        for ident in dict.fromkeys(i['category_id'] for i in rows):
            same=[i for i in rows if i['category_id']==ident]
            groups.append({'id':ident,'name':same[0]['category'],'group':same[0]['group'],'amount_minor':sum(i['amount_minor'] for i in same),'count':len(same)})
        for index,group in enumerate(sorted(groups,key=lambda g:g['id'])):group['color_index']=index
        groups.sort(key=lambda g:g['amount_minor'],reverse=True)
        currencies.append({'id':currency,'currency':currency,'month_minor':sum(i['amount_minor'] for i in rows),
          'today_minor':sum(i['amount_minor'] for i in rows if i['date']==now.date().isoformat()),'categories':groups,'count':len(rows)})
    return {'available':True,'source':'ezBookkeeping','month':month,'updated_at':time.time(),'stale':False,
            'currencies':currencies,'items':items,'coverage':'所选月份全部支出；不同币种分别展示，转账不计支出。','count':len(items)}

class FinanceDashboard:
    def __init__(self,state,home):self.business=BusinessTools(state,home=home);self.cache={};self.lock=asyncio.Lock()
    async def snapshot(self,month=None):
        month=month or datetime.now(TZ).strftime('%Y-%m')
        try:
            parsed=datetime.strptime(month,'%Y-%m')
            if parsed.strftime('%Y-%m')!=month:raise ValueError()
        except (TypeError,ValueError):raise ValueError('月份格式应为 YYYY-MM') from None
        async with self.lock:
            old=self.cache.get(month)
            if old and time.time()-old['updated_at']<60:return old
            try:
                tx,tree,accounts=await asyncio.gather(*[self.business.book_api(p) for p in ('/api/v1/transactions/list/all.json','/api/v1/transaction/categories/list.json','/api/v1/accounts/list.json')])
                value=project(tx,tree,accounts,month);self.cache[month]=value;return value
            except Exception:
                if old:return {**old,'stale':True,'note':'暂时未能更新，显示上次读取的账本。'}
                return {'available':False,'month':month,'source':'ezBookkeeping','note':'账本暂时无法读取，请稍后重试。'}
