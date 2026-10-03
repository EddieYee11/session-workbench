# Com! Muse 式重构 · M1 导航与今天页分层

> 2026-10-03 · 依据 `COM_MUSE_REFACTOR_TASK.md` 第 4.1／4.6 节与第 5 节 M1 门禁。前置：`COM_MUSE_REFACTOR_M0_VERIFICATION.md`。

## 1. 本轮改了什么

### 1.1 底部三入口（`ChatUI.kt`）

- 底栏由「对话 / 今天 / 任务 / 工作 / 更多」改为 **对话 / 今天 / 工作**。
- `ComBottomNavigation` 去掉 `activity` 与 `more` 两个回调参数；选中态改为 `page==target || (target=="sources" && page in {calendar,finance,signals})`。
- 三项后重算选中项标签宽度（`maxWidth-130.dp`），避免沿用五项时的 `maxWidth-278.dp` 把「今天」挤成省略号。

### 1.2 「更多」移到顶栏右上角

| 页面 | 入口 |
| --- | --- |
| 对话 | 右上角圆形按钮（原「活动」按钮的位置），`contentDescription="更多"` |
| 今天 | 标题行刷新按钮右侧 |
| 工作 | 固定页头「工作会话历史」右侧 |

「任务」不再是一级入口；任务台账作为二级页，入口为**今天页的「进行中 N 项」/「全部 N」**与**对话内任务卡**。

### 1.3 返回栈（`Store.kt` + `ChatUI.kt`）

- 新增 `secondaryReturnPage`：离开一级页（对话／今天／工作）时记录来源。
- 新增 `goBack()`：二级页返回真实入口，不再固定回对话或今天。
- `calendar` / `finance` / `signals` / 任务台账列表都改用 `goBack()`；任务详情的 `taskBack()` 仍优先用已有的 `taskReturnPage`（更精确，可定位原消息），仅在没有详情时回退到 `goBack()`。
- 返回按钮文案改为不撒谎：`返回 Pi` → `返回`、`返回今天` → `返回`（通知巡检现在可能来自对话或工作页）。

### 1.4 今天页决策／知情分层（`TodaySections.kt`、`PersonalOverview.kt`）

- `todayDecisionItems()` 不再包含通知巡检结果；新增 `todayAwarenessItems()` 与 `TodayAwarenessCard`。
- 「待我处理」的计数与卡片内容现在严格一致（`items.size`），不再出现「计数排除知情项但卡片里仍有知情项」。
- 知情区只在其有内容时出现，位置在页面最后，不占决策位。
- 页面顺序：状态行 → 待我处理 → 今天（时间轴）→ 进行中 N 项 · 全部 N → 本月账本 → 仅供知情。

### 1.5 输入区上方快捷入口（`HermesChat.kt`）

- 新增 `ComQuickEntry`：**记一笔**（打开既有的 `ExpenseVoiceActivity`）、**今日日程**（进入完整手机日历页）。
- 日历与账本不再只能从「更多」里找到。

## 2. 测试改动与理由

任务书要求现有测试不得因改动失败，需要改的逐条说明：

| 测试 | 原期望 | 改成 | 理由 |
| --- | --- | --- | --- |
| `ComNavigationTest.destinationsStayBelowConversation` | 底栏 5 项 | 3 项 | 底栏本身就是本轮改动的对象 |
| `ComNavigationTest.backgroundTasksKeepIdentityAndCacheState` | 点底栏「任务」 | 今天 → `today-ongoing` → 点任务 | 「任务」不再是一级入口，新路径即产品新路径 |
| `ComNavigationTest.keyboardKeepsComposerVisibleAndReturnsNavigationAfterDismissal` | 用「更多」判断底栏是否隐藏 | 用「工作」 | 「更多」已移到顶栏，键盘不再隐藏它 |
| `ComNavigationTest.todayReadsPhoneCalendarWithoutPairing` | 断言旧日历卡页脚「手机日历 · 本地读取」在今天页 | 断言时间轴卡「打开日历」，进入日历页再断言页脚 | 今天页在 1.7.1 已换成时间轴卡；同时补上「二级页返回今天」的断言 |
| `TodayTaskExperienceTest` | 底栏 5 项、`nav-activity` | 3 项、「全部任务」进台账 | 同上 |
| `MainActivityKeyboardTest` | 用「更多」判断底栏隐藏 | 用「工作」 | 同上 |
| `HermesExperienceTest` / `WorkAuthorizationTest` / `WorkCardNavigationTest` | `HermesChat(vm,menu,showMenu,openTasks)` | 新签名 `(vm,menu,openTasks,openCalendar)` | 左侧菜单按钮已移除，参数随实现调整 |

## 3. 顺带修掉的两个测试环境问题（非本轮功能改动）

模拟器 UI 全量跑通过程中发现，之前被记为「环境问题」的 5 个失败其实是两件可复现的事：

1. **`POST_NOTIFICATIONS` 未授权**：`MainActivity.kt:57` 在 SDK≥33 启动时申请通知权限，系统对话框盖住 App，导致所有 `createAndroidComposeRule<MainActivity>` 测试报 `No compose hierarchies found in the app`。预先 `pm grant` 后，`MainActivityKeyboardTest`(4) 与 `HermesHeaderExperienceTest`(1) 全部通过。
2. **测试共用 App 数据里的残留草稿**：`ComNavigationTest.open()` 没清草稿，上一轮测试留下的 `第二段转写测试草…` 会拼在新输入后面，`onNodeWithText("测试草稿")` 随即不匹配。`open()` 现在调用 `vm.updateHermesDraft("")` 并清 outbox／提示。

复现命令（模拟器，需要先装 debug + androidTest 包并授权）：

```bash
adb -s <设备> shell pm grant work.eddie.sessions android.permission.POST_NOTIFICATIONS
adb -s <设备> shell pm grant work.eddie.sessions android.permission.READ_CALENDAR
adb -s <设备> shell pm grant work.eddie.sessions android.permission.RECORD_AUDIO
adb -s <设备> shell am instrument -w work.eddie.sessions.test/androidx.test.runner.AndroidJUnitRunner
```

## 4. 验证结果

| 层 | 命令 | 结果 |
| --- | --- | --- |
| Android JVM | `./gradlew test` | **58 / 58 通过** |
| 模拟器 UI（411dp，com151 AVD） | `am instrument -w work.eddie.sessions.test/…AndroidJUnitRunner` | **OK (57 tests)** — 含全部 5 个真 Activity 测试 |
| 构建 | `./gradlew assembleBenchmark` | 成功 |
| 实机点击与截图 | 见下 | 对话页 / 今天页 / 更多 sheet |

截图（本机 `verification/` 之外，测试产出在模拟器 App 外部目录）：

- 对话页：右上角「更多」、左侧无按钮、形象居中、输入区上方「记一笔 / 今日日程」、底栏三项。
- 今天页：状态行 → 待我处理 → 今天（时间轴）→ 进行中 N 项 · 全部 N → 本月账本；顶栏右上角「更多」。
- 更多 sheet：日历 / 账本 / 通知巡检 / 权限与上下文 / 设置，全部仍可达。
- 任务详情：从今天页进入，底栏仍高亮「今天」，页头「任务详情 + 返回」。

## 5. 本轮未做（留给后续里程碑）

- 对话内联任务卡（M2）、`kind` 派生与四类状态映射（M3）、路由规则与补充去向（M4）、步骤人话化与产物卡（M5）、`capability_search`（M6）。
- 今天页的「今天」时间轴仍是独立圆角卡片，没有完全改成无卡片的骨架（任务书 4.6 的目标是「压缩成摘要行」，本轮已达到；是否进一步去卡片留待 M2 视觉统一时判断）。
