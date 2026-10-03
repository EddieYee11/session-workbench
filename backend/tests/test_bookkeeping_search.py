"""Exercise the shared client adapter without touching a real ledger."""
import asyncio
import json
import shutil
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bookkeeping_search import criteria, search


@pytest.mark.parametrize('args', [
    {'date': '2026-02-30'}, {'date': '2026-09-05', 'start_date': '2026-09-01'},
    {'start_date': '2026-01-01', 'end_date': '2026-12-31'},
    {'date': '2026-09-05', 'amount': True}, {'date': '2026-09-05', 'amount': 13.251},
    {'date': '2026-09-05', 'amount': float('nan')}, {'date': '2026-09-05', 'amount': -1},
    {'date': '2026-09-05', 'limit': 51}, {'date': '2026-09-05', 'limit': True},
    {'date': '2026-09-05', 'client_module': '/tmp/untrusted.js'},
])
def test_search_parameters_cannot_change_client_or_escape_scope(args):
    with pytest.raises(ValueError):
        criteria(args)


def test_shared_read_client_filters_beijing_day_exact_cents_and_returns_only_matches(tmp_path):
    if not shutil.which('node'):
        pytest.skip('Node runtime unavailable')
    module = tmp_path / 'shared-client.js'
    module.write_text('''
+class EzBookkeepingClient {
+ async listTransactions() { return [
+  {id:'3843404382045470720',time:Date.parse('2026-09-05T00:01:00+08:00')/1000,sourceAmount:132500,type:3,categoryId:'food',sourceAccountId:'bank',comment:'指定餐费'},
+  {id:'income',time:Date.parse('2026-09-05T10:00:00+08:00')/1000,sourceAmount:132500,type:2,categoryId:'food',comment:'不是支出'},
+  {id:'previous-day',time:Date.parse('2026-09-04T23:59:00+08:00')/1000,sourceAmount:132500,type:3,categoryId:'food',comment:'其他日期'},
+  {id:'different-amount',time:Date.parse('2026-09-05T12:00:00+08:00')/1000,sourceAmount:132501,type:3,categoryId:'food',comment:'其他金额'}
+ ]; }
+ async getCategoryLookup() { return {food:{primary:'餐饮',secondary:'外卖'}}; }
+ async listAccounts() { return [{id:'bank',name:'真实测试银行',currency:'CNY'}]; }
+}
+module.exports={EzBookkeepingClient};
+'''.replace('\n+', '\n'))
    result = asyncio.run(search({'date': '2026-09-05', 'amount': 1325}, client_module=module))
    assert result['read_only']
    assert result['coverage']['scanned_count'] == 4
    assert result['coverage']['matched_count'] == 1
    assert not result['coverage']['truncated']
    assert result['items'] == [{'id': '3843404382045470720', 'date': '2026-09-05',
                               'time': '2026-09-05 00:01:00', 'amount': 1325,
                               'amount_minor': 132500, 'type': 'expense',
                               'category': '餐饮 / 外卖', 'comment': '指定餐费',
                               'account': '真实测试银行', 'currency': 'CNY'}]
    assert result['duration_ms'] >= 0
    filtered = asyncio.run(search({'date': '2026-09-05', 'amount': 1325, 'keyword': '不存在'}, client_module=module))
    assert filtered['items'] == []


def test_shared_client_failure_never_returns_auth_headers(tmp_path):
    if not shutil.which('node'):
        pytest.skip('Node runtime unavailable')
    module = tmp_path / 'failed-client.js'
    module.write_text('module.exports={EzBookkeepingClient:class {async listTransactions(){throw Object.assign(new Error("secret-token"),{response:{status:403}})}}}')
    with pytest.raises(ValueError) as error:
        asyncio.run(search({'date': '2026-09-05'}, client_module=module))
    assert '403' in str(error.value)
    assert 'secret-token' not in str(error.value)


def test_numeric_id_beyond_javascript_precision_never_becomes_fake_record(tmp_path):
    if not shutil.which('node'):
        pytest.skip('Node runtime unavailable')
    module = tmp_path / 'unsafe-id-client.js'
    module.write_text('''module.exports={EzBookkeepingClient:class {
 async listTransactions(){return [{id:3843404382045470720,time:Date.parse('2026-09-05T12:00:00+08:00')/1000,sourceAmount:132500,type:3}]}
 async getCategoryLookup(){return {}}
 async listAccounts(){return []}
}}''')
    with pytest.raises(ValueError, match='历史查账读取失败（filter）'):
        asyncio.run(search({'date': '2026-09-05', 'amount': 1325}, client_module=module))
