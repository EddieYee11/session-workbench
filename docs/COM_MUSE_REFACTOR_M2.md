# Com! Muse 式重构 · M2 对话内联任务卡与详情重排

> 2026-10-03 · 依据 `COM_MUSE_REFACTOR_TASK.md` 第 4.2／4.3 节。前置：M0 核验报告、M1 导航与今天页。

## 1. 对话内联任务卡（新增 `MessageTaskCard.kt`）

**判据**：只收 `message.linked_tasks`（服务端 `work_cards.card_task` 产出的真实派发任务）。同一轮内的工具步骤仍在 `message.tasks` 的 `kind=='tool'` 里，继续由 `AgentWorkCard` 呈现；普通问答两者都不出现。

| 元素 | 行为 |
| --- | --- |
| 一行结构 | 状态点 + 标题 + 状态文字 + 箭头 |
| 在办 | 呼吸绿点；状态文字取 `ledgerStatus` 的文案 |
| 等我（decision） | Amber 底色 + Amber 描边，标题行不折叠 |
| 待确认（verify） | 墨色点，仍展开，直到用户核对 |
| 已结束（done／ended） | 不占展开位；完成显示 ✓ +「查看过程」，停止／拒绝显示灰点 |
| 数量上限 | 在办／等我／待确认合计最多 3 张，其余合并为「另有 N 项」 |
| 折叠入口 | 「另有 N 项」按被折叠条目的分组跳到任务页 `decision` 或 `active` 筛选 |
| 缓存 | `taskLedgerFresh=false` 时状态文字前缀「上次同步：」，不新增一套 freshness 表达 |

点击卡片 → `vm.openTaskDetail(id, message.id)`，与工作过程卡共用同一入口，返回时定位回原消息。

## 2. 修掉一个真实布局缺陷

内联卡与工作过程卡原本都直接放进同一个 `Box`。`Box` 是堆叠语义，两张卡会**重叠**在同一位置——测试里表现为「点 job-2 的卡却打开了 job-1」，实际是 job-1 的工作过程卡压在上面。

修法：`Box { Column { 内联卡; 工作过程卡 } }`。这是本轮唯一一处由测试发现并修正的真实缺陷，已由 `MessageTaskCardExperienceTest.tappingACardOpensThatExactTaskAndKeepsItsMessage` 守住。

## 3. 任务详情重排（`TaskLedger.kt`）

按任务书 4.3 的六段顺序重排，字段没有丢，只改位置与默认折叠状态：

| 顺序 | 内容 | 默认 |
| --- | --- | --- |
| 1 现在怎样 + 主操作 | 范围·目录、目标、当前阶段、最近一步、完成条件、控制回执；授权块／原生审批／继续／**请求停止** | 展开 |
| 2 结果与产物 | 结果文字（BodySm，行高 20） | 展开 |
| 3 步骤 | 事件时间线，默认只显示最近 3 步，可展开全部 | 最近 3 步 |
| 4 补充要求 | 输入框（标签「补充要求」）+「发送补充要求」 | 展开（在底部） |
| 5 来源与历史 | 交办原文、约束、**输入送达记录**、完整执行指令 | 折叠 |
| 6 去哪 | 进入执行会话、回到交办消息 | 展开 |

文案同时去掉技术腔：`补充约束` → `补充要求`；`来源与约束` → `来源与历史`；`时间线` → `步骤`。

## 4. 测试

新增：

- `MessageTaskCardTest`（JVM，5 项）：上限 3 张、折叠计数、被折叠项的分组决定筛选、已结束不占位、待确认仍展开、空输入无卡。
- `MessageTaskCardExperienceTest`（模拟器，3 项）：工具步骤不生成内联卡而派发任务生成；超过上限合并为「另有 N 项」并跳到 `decision` 筛选；点第二张卡打开的是第二张任务且带回原消息。

调整（逐条理由）：

| 测试 | 改动 | 理由 |
| --- | --- | --- |
| `ComNavigationTest.backgroundTasksKeepIdentityAndCacheState` | `补充要求` → `发送补充要求` | 该文案现在是输入框标签，动作按钮改名为「发送补充要求」；断言的语义（离线时动作不可用）不变 |

## 5. 验证结果

| 层 | 命令 | 结果 |
| --- | --- | --- |
| Android JVM | `./gradlew test` | **63 / 63 通过**（58 + 5） |
| 模拟器 UI（411dp） | `am instrument -w work.eddie.sessions.test/…AndroidJUnitRunner` | **OK (60 tests)**（57 + 3） |
| 构建 | `assembleDebug` / `assembleDebugAndroidTest` / `assembleBenchmark` | 成功 |
| 截图 | `verification/muse-m2/inline-cards.png` | 普通问答只有工具步骤卡；派发消息下出现 3 张内联任务卡（执行中／执行中／已受理·排队中） |

## 6. 本轮未做

- 短标题（≤12 字）与 `work_brief` 分离、`kind` 派生、四类状态的统一文案（M3／M4）。
- 步骤人话化（「搜索了 N 个来源」）与产物卡（M5）；本轮只做了步骤折叠与顺序。
- 「等我」卡上的直接主操作（任务书允许点击进详情处理，本轮取后者）。
