# 四页签导航：聊天 / 今日 / 任务 / 我的

> 分支 `personal-agent-tabs`，基于 `main`（Com! 1.3.4）。目标：把 App 从抽屉导航改为底部四页签，
> 新增「今日」页（日历＋记账），任务与我的各自成页。现有会话逻辑零改动。

## 改动

- `Tabs.kt`（新增）：`MainTabs` 承载四个页签；`FloatingTabBar` 悬浮胶囊页签栏，
  选中项展开文字。键盘弹起时自动收起页签栏，给输入框让位。
- `MainActivity.kt`：`setContent` 改用 `MainTabs`；启动时一并申请 `READ_CALENDAR`。
- `AndroidManifest.xml`：新增 `READ_CALENDAR` 权限。
- `TodayScreen.kt`（新增）：今日页。
  - 顶部日期＋一句话摘要（今日日程数、今日支出、Agent 状态）。
  - 日历：经 `CalendarContract.Instances` 读取手机系统日历今日事件
    （Google 日历同步到手机即可显示）；未授权时显示授权卡片。
  - 记账：`LedgerStore`（见下）今日支出、本月支出、最近 5 笔，「记一笔」
    弹窗（金额＋分类＋备注）。
  - Agent 动态：运行中 / 等回应的任务数，取自 `vm.allRows`。
- `LedgerStore.kt`（新增）：记账存储，`filesDir/ledger.json`，JSON 数组，
  与现有 `Store` 缓存风格一致。`entries/add/delete/todayOut/monthOut`。
- `TasksScreen.kt`（新增）：任务页。「进行中」（等回应优先）＋「最近会话」，
  点开经 `vm.open()` 跳到聊天页对应会话。
- `MeScreen.kt`（新增）：我的页。头像＋连接状态；记忆（本地可增删，
  `prefs["memory"]`）；技能开关（记账/收藏/语音备忘，本地偏好）；
  连接（Mac mini、日历授权）；右上设置复用现有 `Settings` 弹窗。

## 页签与现状的对应

- 聊天 = 现有工作台（首页＋会话），逻辑未动。
- Hermes 尚不存在于代码中；Hermes 落地后，「聊天」页即为主对话入口，
  Pi/Codex 会话继续作为任务卡片回流。

## 未验证

本机（Linux VM）未能编译：Gradle daemon 与 client 的本地 socket 握手异常，
且 Java 进程无法经沙箱代理完成依赖下载。需在 Android Studio 或 Mac mini
上 `./gradlew assembleDebug` 验证。
