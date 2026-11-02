import json
import time

from batch_fold import BatchFold
from router_plan import RouterPlan, rule_hit, has_deletion
from superagent_flags import SuperagentFlags
from tasks import TaskStore


NOW = 2_000_000_000.0


def test_rule_hit_narrow():
    assert rule_hit('分别用 Pi 和 Codex 处理')
    assert rule_hit('用 pi 做 A，用 claude 做 B')
    assert not rule_hit('北京和上海的天气')
    assert not rule_hit('午饭和晚饭各记一笔')
    assert has_deletion('分别删除两个目录')


def test_batch_creates_parallel_tasks_and_suppresses_child_receipts(tmp_path):
    (tmp_path / 'superagent-flags.json').write_text(json.dumps({'router': 'on'}))
    store = TaskStore(tmp_path)
    class Conv:
        def __init__(self):
            self.receipts = []
        def task_receipt(self, rid, text):
            self.receipts.append((rid, text))
        def task_receipt_for_message(self, rid, text, parent):
            self.receipts.append((rid, text, parent))
    conv = Conv()
    plan = RouterPlan(tmp_path, store, conv, flags=SuperagentFlags(tmp_path), workspace=tmp_path / 'ws', clock=lambda: NOW)
    row = {'id': 'msg1', 'request_id': 'req-batch-001234', 'text': '分别用 Pi 在目录 X 做只读盘点，用 Codex 在目录 Y 做只读盘点'}
    result = plan._create_batch(row, [
        {'agent': 'pi', 'title': '盘点X', 'prompt': '只读盘点 X', 'relative_cwd': 'x'},
        {'agent': 'codex', 'title': '盘点Y', 'prompt': '只读盘点 Y', 'relative_cwd': 'y'},
    ])
    assert len(result['task_ids']) == 2
    tasks = store.list()
    assert all(t.get('batch_id') for t in tasks)
    assert all(t.get('batch_suppress_receipt') for t in tasks)
    # 模拟 finish → outbox → deliver 应吞掉子回执
    for t in tasks:
        store.finish(t['id'], 'execution_finished', f'结果-{t["agent"]}')
    store.deliver(conv)
    assert conv.receipts == []
    # 折叠
    fold = BatchFold(plan, store, conv, clock=lambda: NOW + 9 * 60)
    assert fold.tick() == 1
    assert any(r[0].startswith('batch:') for r in conv.receipts)
    assert '结果-pi' in conv.receipts[0][1] and '结果-codex' in conv.receipts[0][1]


def test_maybe_dispatch_off_when_flag_off(tmp_path):
    (tmp_path / 'superagent-flags.json').write_text(json.dumps({'router': 'off'}))
    store = TaskStore(tmp_path)
    plan = RouterPlan(tmp_path, store, object(), flags=SuperagentFlags(tmp_path), workspace=tmp_path / 'ws')
    assert plan.maybe_dispatch({'id': 'm', 'request_id': 'req-abcdefghij', 'text': '分别用 pi 和 codex 查'}) is None
