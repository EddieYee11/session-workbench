# 主对话上下文瘦身（2026-10-07）

用户反馈「从我发消息到 A 进程处理完，整体时间过长」，实测根因之一：每轮都注入全量快照。
本文记录这一轮的改动、实测数据和回滚方式。

## 改前实测（真实数据，非估算）

单条用户消息里注入的包装体量（`~/.hermes/profiles/com-personal/state.db`，`active` 消息实测）：

| 消息 | 总计 | 历史记忆 | 当前有效个人事实 | Com 主对话上下文 | 能力清单 |
|---|---|---|---|---|---|
| rowid 6299 | 32,327 | 929 | 25,907 | 3,457 | — |
| rowid 6303 | 55,029 | 776 | 669 | 51,150 | 2,307 |

用户原话只有 21 字符（「修改就按照你说的方案进行修改。」），包装 55,008 字符。
任务上下文是最大单项：30 条任务、50,409 字符，因为每条都带完整
`work_brief`（与顶层字段重复）、`constraints`/`constraints_audit` 双份、
`source_links` 全文、`inputs` 全文。

## 改动

- `capabilities.py`：`render(limit=110)` 只输出「标签（id）：截断关键词」，完整说明交给
  `capability_search` 现查。
- `conversation.py`：新增 `slim_tasks()`，任务是紧凑投影——保留
  `id/title/status/agent/executor/goal_id/plan_node_id/verification_status` 与短字段
  （`latest_instruction` ≤200、`completion_condition` ≤240、`block_reason` ≤120、`result` ≤260）；
  去掉 `work_brief`、成对的 constraints、`source_links` 全文、`inputs` 全文。主链路和眼镜分支共用。
- `hermes_runtime.py`：新增 `slim_facts()`（≤12 条、正文 ≤500、来源只留 id+短引文）与
  `slim_memories()`（≤5 条、正文 ≤300、只留来源路径），替换原先整段透传的 JSON。
- `background_events.py`：后台事件（含主动消息）同样走 `slim_tasks`。

注入仍放在用户消息里，不改成 run 级 `instructions`：system prompt 保持稳定才能吃到前缀缓存，
把每轮都变的上下文挪到 system prompt 会让缓存整体失效，反而更慢。

## 改后实测

同一行真实数据（rowid 6303，含 21 字原话）用改后代码重跑 `_pi_input`：**16,975 字符**，
比改前的 55,029 字符减少 69%；其中任务块 50,409 → 9,647 字符。再叠加事实块（≤约 1k）与
召回块（实测 1.1k，改前 2.5–2.7k），整轮约 18–19k 字符。

测试：`tests/` 全量 500 passed / 5 deselected（`--deselect tests/test_ios_contract.py`），
含 `test_capabilities.py`、`test_rayneo_latency.py`（原断言 `tasks` 只含 id/status，仍通过）、
`test_conversation_delivery.py`、`test_input_move.py`、`test_proactive.py`。

复现脚本：`~/.hermes/profiles/com-personal/cache/scratch/latency/payload.py`。

## 回滚

三个文件都是小函数级改动：`capabilities.render` 去掉 `limit` 裁剪即回全量；
`conversation.slim_tasks` 从 `_pi_input` 换回 `task_context()` 直接取值即回全量任务块；
`hermes_runtime.slim_facts/slim_memories` 换回原 `catalog` / `memories['items']` 即回全量记忆块。

生效需要重启后端：`launchctl kickstart -k gui/$(id -u)/work.eddie.sessions`（`KeepAlive=true`）。
