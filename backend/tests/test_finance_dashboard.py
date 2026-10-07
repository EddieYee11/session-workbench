from datetime import datetime
from zoneinfo import ZoneInfo
from finance_dashboard import project

def test_month_currency_categories_and_drilldown_agree():
    now=datetime(2026,10,7,12,tzinfo=ZoneInfo('Asia/Shanghai'))
    def tx(i,amount,account=1,typ=3,at=None):return {'id':str(9007199254740993+i),'sourceAmount':amount,'sourceAccountId':account,'type':typ,'categoryId':2,'time':(at or now).timestamp()*1000,'comment':'午饭'}
    result=project([tx(1,3010),tx(2,2000),tx(3,100,2),tx(4,300,typ=4),tx(5,999,at=now.replace(month=9))],{'expense':[{'id':1,'name':'餐饮','subCategories':[{'id':2,'name':'午餐'}]}]},[{'id':1,'name':'卡','currency':'CNY'},{'id':2,'name':'卡2','currency':'USD'}],'2026-10',now)
    assert len(result['items'])==3
    cny=result['currencies'][0]
    assert cny['month_minor']==cny['today_minor']==5010
    assert cny['categories'][0]['amount_minor']==5010 and cny['categories'][0]['group']=='餐饮'
    assert result['items'][0]['id']=='9007199254740994'

def test_empty_and_missing_currency_are_not_fabricated():
    assert project([],{},[],'2026-10')['currencies']==[]
    now=datetime(2026,10,7,tzinfo=ZoneInfo('Asia/Shanghai'))
    result=project([{'id':'a','sourceAmount':100,'type':3,'time':now.timestamp(),'categoryId':99}],{},[],'2026-10',now)
    assert result['currencies'][0]['currency']=='UNKNOWN'
    assert result['items'][0]['category']=='未分类'
