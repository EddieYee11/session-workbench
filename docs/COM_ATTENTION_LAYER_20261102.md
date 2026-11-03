# Com 注意力层落地记录（2026-11-02）

来源：卡兹克《折腾了整整1年，毫无保留地分享一下我这套Agent自动化系统》。Eddie 要求落实 4 条借鉴和 3 条顺手项。

## 改了什么

| 项 | 落点 | 说明 |
|----|------|------|
| 规则表 | `backend/event_rules.json`、`event_rules.py` | 来源过滤、并发、冷却、能否备草稿、主对话快模型都在表里；改文件即生效，改坏继续用上一份。检查：`python event_rules.py`。敏感内容、过期、空批次是代码硬闸门，表放不开 |
| 决定账本 | `backend/decisions.py`，`~/.session-workbench/decisions.sqlite` | decided 注入主对话和事件判断；declined 拦后台提醒，不挡他亲口提的要求。入口：App 接口、划掉下一步、驳回审批卡、`decision_record` 工具（原话必须出自当前消息） |
| 事项归并 | `backend/triggers.py`（`event_matters`）、`evals.py` | 同线索、3 天内相近标题、模型 `same_as` 三种归并；判过冷却 120 分钟，期间事件攒到下一轮；开着的事项不降级 |
| 独立核对 | `backend/task_audit.py` | 无工具模型对照完成条件和真实文件。有文件 passed；纯文字 reviewed（不解锁依赖和目标）；缺口进「等你」，最多 3 轮。不自动派活。写操作回读账本、日历、提醒，查不到转「结果不确定」 |
| 票拟卡 | `decisions.ticket`，iOS `TicketLines`、`AuditCard`，`web/js/cases.js` | 建议 / 依据 / 同意 / 不同意；拍完进「刚拍板的」留 24 小时 |
| 打扰统计 | `backend/attention.py`，`GET /personal/attention` | stale 算「没理」；用上率 ≤10% 且 ≥8 条才出建议，显示在下一步页脚，不自动改规则 |
| MBP 接单 | `backend/worker_queue.py`，`backend/herdr_push/mbp_worker.py` | 长轮询 50 秒，只有 ping、pi_readonly 两种活，超时记 unknown 不重跑。走 `ssh mini` 隧道（18650） |

## 口径

- 「还没发 / 还没提交」不算核对缺口；「让它补做」的消息明确禁止外发、提交、付款、发布。
- 主对话和航程的外发、付款、发布仍是 10-02 的直达规则，和 11-02「最终点击由 Eddie」冲突，待他定。
- 三个 Super-agent 开关（router、mandate、herdr_write）这次没动，仍全关。MBP 接单还没有自动派活路径，只能经接口手动建活。

## 坑

- `store.change` 的 key 幂等，相同 key 内容不同报 `Request conflicts with another command`。
- 航程产物在 `cases.data.artifacts`，不在 `task.artifacts`；核对只看后者会误判。
- `next-waiting-section` 挂在容器上，盖住了「等你」里所有子控件的标识，UI 测试按文字找。
- MBP 经 `pi.eddiegao.work` 直连超时（11-02 实测），所以接单走 ssh 隧道。
