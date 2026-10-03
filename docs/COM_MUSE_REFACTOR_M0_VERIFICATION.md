# Com! Muse 式重构 · M0 只读核验报告

> 2026-10-03 · 执行者：Pi（MBP）。依据任务书 `COM_MUSE_REFACTOR_TASK.md` 第 1 节。本阶段**未修改任何源码**，只做读取、grep 与目标主机实测。

## 0. 结论

- 工作区 1.7.1 进行中改动**已提交**为 `0c5ee73`，未回退、未覆盖。
- mini 后端当前**没有运行中的交办**（17 条历史任务，非终态 0 条），M4／M6 部署不会打断用户会话。
- 任务书假设与源码基本一致；有 4 处需要按当前源码调整，见第 7 节。
- 可以开始 M1。

## 1. 已读文档

| 文档 | 读到的关键事实 |
| --- | --- |
| `docs/COM_APP_CURRENT_STATE.md`（1418 行，全文） | 1.7.0 基线、页面地图、五入口、五种 ID、状态多层、后端模块表、API 索引、mini 状态目录、测试入口、部署与安装流程 |
| `docs/COM_1.7_UPGRADE.md` | 1.7.0 行为与回滚口径 |
| `docs/COM_UX_RESTRUCTURE.md` | 我上一轮写的方案；顶部为已整合部分 |
| `docs/TASK_LAYER_CONTRACT.md` | 任务层角色、授权、事件与结果契约 |

## 2. Git 状态

- HEAD：`0c5ee73`「Com! 1.7.1 进行中：任务详情分层、输入区入口收敛、1.7.0 基线文档」
- 上一提交：`6d5abb1`（1.7.0 合并）
- 本次 M0 提交内容：`android/app/build.gradle`（版本）、`HermesChat.kt`（移除输入区「＋」）、`TaskLedger.kt`（详情分层）、`docs/COM_APP_CURRENT_STATE.md` + 4 张截图（用户撰写）、`README.md`／`docs/app-overview.md` 指向当前状态说明。
- 仍未跟踪：`_archive/removed-drawables-20261002`（12 MB，1.5.2 期的旧 drawable 归档，不属于本轮范围，未提交、未删除）。

## 3. Android 版本事实

| 项 | 值 | 位置 |
| --- | --- | --- |
| applicationId / namespace | `work.eddie.sessions` | `android/app/build.gradle:6` |
| versionName | `1.7.1` | 同上 |
| versionCode | `17` | 同上 |
| compileSdk / targetSdk / minSdk | 35 / 35 / 28 | 同上 |
| 已安装设备 | 小米 18 Fold（`lhasa`，`2608BPX34C`）已装 1.7.1；安装证书 SHA256 `d01d14be…0434a`（= 本机 debug keystore，可同签名覆盖） | `adb` 实测 |

## 4. mini 在线实测

`ssh mini` + `curl 127.0.0.1:8650/health`：

```json
{"service":"mini-sessions","version":"1.7.0","main_operation_mode":"full-access",
 "worker_operation_mode":"full-access","operation_policy_revision":"com-full-access-20261003",
 "readonly_restrictions_revoked":true,
 "features":{"pi_main":true,"task_events_sse_v1":true,"work_cards_v1":true,"work_chat_v1":true,"goals_scheduler":false,...}}
```

- `~/.session-workbench/agent-config.json`：`main_agent=pi`、`claude_model=deepseek-v4.1-flash`、`execution_host=EddiedeMac-mini.local`。
- 常驻进程：`uvicorn app:app --host 127.0.0.1 --port 8650`、Caddy、Codex app-server（tmux）、Pi 主线 RPC 子进程。
- **运行中交办：0 条**。`/personal/tasks` 共 17 条：`execution_finished` 12、`cancelled` 3、`failed` 1、`unknown` 1。→ M4／M6 部署安全。
- 后端版本仍为 1.7.0（尚未加载 1.7.1 源码），符合预期：1.7.1 只改了 Android 端。

## 5. grep 定位结果（任务书第 1.5 节）

### 5.1 `task_submit` 与主线提示词

| 用途 | 位置 |
| --- | --- |
| **主线系统提示词**（M4 改这里） | `backend/pi_main.py:7` `MAIN_PROMPT`（单条字符串常量） |
| Pi 扩展工具 schema + 逐工具描述 | `backend/com-pi.ts:24`（schema）、`backend/com-pi.ts:41`（`task_submit` 描述） |
| MCP 兼容入口 | `backend/hermes_mcp.py:325` `task_submit(...)`；白名单在 `:308` |
| 别名桥接 | `backend/agent_tools.py:58`（`create_task` → `task_submit`）、`:93` |
| 委派判定与真实来源守卫 | `backend/task_tools.py`、`backend/policy.py` |

`task_submit` 现有参数：`request_id, title, prompt, agent, relative_cwd, sandbox, source_quote, completion_condition, goal_id, plan_node_id, depends_on, acceptance_criteria`。**没有 `kind`／短标题与长说明的分离字段**。

### 5.2 任务映射与筛选

| 用途 | 位置 |
| --- | --- |
| `ledgerGroup()` | `android/.../TaskLedger.kt:134` |
| `LedgerTask` 数据类 | `TaskLedger.kt:29-49` |
| 筛选键与 chip | `TaskLedger.kt:161`（`taskFilters`）、`:163`（`TaskFilterChips`） |
| 筛选消费 | `TaskLedger.kt:176-185`（`TaskLedgerSection`） |
| 记录合并（含 proposal 回填） | `TaskLedger.kt:144` `ledgerTaskRecords()` |

当前筛选键：`all / decision / active / verify / done / ended`（六项）。

### 5.3 路由与返回状态

| 状态 | 声明 | 写入点 |
| --- | --- | --- |
| `rootPage` | `Store.kt:214` | `ChatUI.kt:105`（`LaunchedEffect(page)`） |
| `taskDetailId` | `Store.kt:238` | `Store.kt:697`（`openTaskDetail`）、`:701`（`openTaskList`）、`:706`（`returnToHermes`）、`ChatUI.kt:108`（`taskBack` 清空） |
| `taskReturnMessageId` | `Store.kt:239` | 同上 |
| `taskReturnPage` | `Store.kt:240` | `Store.kt:696`：`openTaskDetail` 时若 `taskDetailId` 为空则记下 `rootPage` |
| `taskFilter` | `Store.kt:241` | `Store.kt:702`（`openTaskList`）、`TaskFilterChips` 内点击 |
| `externalTaskRoute` / `externalHermesRoute` | `Store.kt:236-237` | `ChatUI.kt:90-91` 消费 |
| 返回实现 | — | `ChatUI.kt:107-114` `taskBack()`：详情态回 `taskReturnPage`，列表态回 `hermes`；`ChatUI.kt:119` `BackHandler` |

→ **返回栈已有雏形**，M1 需要做的是把「任务」从一级入口降级后补齐它的两个入口（今天页、任务卡）与返回目标。

### 5.4 `message.tasks` / `linked_tasks` / `work_events`

| 端 | 位置 |
| --- | --- |
| 服务端生产 | `backend/work_cards.py:73-74`（`linked_tasks` + `work_events`）、`:136-142`（写回 `message`）；`backend/conversation.py:146`（列）、`:262`、`:317`、`:423-426`（读取） |
| Android 消费 | `AgentWorkCard.kt:29-31`（契约注释）、`:75`（`tasks`）、`:85`（`work_events`）；`Store.kt:541`；`TaskLedger.kt:145`（`linked_tasks` 参与台账合并） |

### 5.5 工作页聊天产生的 ledger task 来源标记

`backend/manual_work.py` `work_chat()` 产出：

- `authorization.entry = 'work_page_human_chat'`
- `request_id = 'manual:' + data['request_id']`
- task 上：`interactive: True`、`automatic: False`
- 调用点：`backend/app.py:472-473`

→ `kind` 派生（M3）可用这三个标记，无需改库。

### 5.6 `CapabilityRegistry` 现有字段

`backend/capabilities.py:145`，SQLite `capabilities.sqlite`（`key` 哈希 → `data` JSON）。单条观测字段：

`id, host, runtime, project, config_version, state(discovered|loaded|verified|unavailable), observed_at, verified_at, evidence`

- `verified` 必须有非 fixture 证据，否则抛错；`loaded` 不会抹掉仍在 24 小时有效期内的 `verified`。
- 只读接口 `/personal/capabilities` **已存在**（`app.py`）。
- → M6 的 `capability_search` 可以只做「工具 + 读取现有 Registry」，不需要新数据源。

## 6. 计划改动的文件与写入者

单 Agent 执行，`Store.kt` / `ChatUI.kt` / `app.py` 由我一人写入，按里程碑分批提交。

| 里程碑 | 主要文件 |
| --- | --- |
| M1 | `ChatUI.kt`（底栏、更多、返回栈）、`HermesChat.kt`（顶栏入口）、`PersonalOverview.kt`、`TodaySections.kt`、`Store.kt`（路由状态） |
| M2 | `HermesChat.kt`、`AgentWorkCard.kt`（或新 `MessageTaskCard.kt`）、`TaskLedger.kt`、`Store.kt` |
| M3 | `TaskLedger.kt`（`kind` 派生 + 四类映射）、`backend/tasks.py`、`backend/work_cards.py`（必要时） |
| M4 | `backend/pi_main.py`（MAIN_PROMPT）、`backend/com-pi.ts`（工具描述）、`backend/policy.py`、`HermesChat.kt`（补充提示与「改为新事项」） |
| M5 | 新映射模块 + `TaskLedger.kt`、`TaskSummaryCard.kt` |
| M6 | `backend/capabilities.py`、`backend/com-pi.ts`、`backend/hermes_mcp.py`、`backend/pi_main.py` |
| M7 | 文档、`build.gradle`、构建与安装 |

## 7. 与任务书不一致／需按源码调整的地方

1. **`taskReturnPage` 已存在**（`Store.kt:240`）。任务书 §20.3 把它列为「重要状态」是对的，但它不是待建项；M1 只需扩展它的覆盖范围（今天页进入详情已可用，需补任务卡与通知巡检等二级页的真实入口返回）。
2. **「更多」当前是底部第 5 个入口**（`ChatUI.kt:223` 的 `settings` → 打开 sheet），不是全屏页；任务书要求它移到顶栏。当前顶栏右侧是「活动」入口（`HermesChat.kt`），M1 需把该位置改成「更多」，并把「活动」的职责交给任务台账。
3. **今天页当前已实现**「待我处理 / 今天 / 在途工作 / 本月账本」四段（`PersonalOverview.kt`），但「通知巡检结果」仍与决策条目同卡（任务书 §4.6 要求移出到知情分区）。计数已排除知情项，卡片内容未分层。
4. **`task_submit` 没有短标题字段**：现在 `title` 就是给执行器看的说明截断（`manual_work.py` 用 `text[:120]`）。任务书 §4.7 要求「短标题（≤12 字）与 `work_brief` 分开」，需要新增一个展示用短标题参数（优先复用现有 `title` 语义并让模型传短标题，`work_brief` 沿用 `prompt`），不改库结构。
5. **`cancel_requested` 当前归入 `active`**（`ledgerGroup` 依赖 `task.status=="active"`），文案由 `ledgerStatus` 决定；任务书 §4.4 要求在办里显示「正在停止」，M3 需在派生层确认这条文案真实可达。

以上 5 点不改变任务书目标，只影响实现细节；实现时按当前源码为准。

## 8. M0 门禁

- [x] 1.7.1 进行中改动单独提交，未回退
- [x] 只读核验，未改源码
- [x] mini 无运行中交办，可安全进入需要部署的里程碑
- [x] 关键位置已用 grep 核实，不凭记忆

下一步：M1（底部三入口、更多移至顶栏、返回栈一致、今天页决策／知情分层）。
