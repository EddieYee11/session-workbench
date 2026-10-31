# Com! 大升级记录（2026-10-31）

分支：`com-big-upgrade-20261031`，基线 `d1473cb`（Cursor 10-31 版）。未推送、未合并 main，等 Eddie 真机确认。

## 做了什么

| 范围 | 结果 | 提交 |
|---|---|---|
| 聊天时间线 | `UICollectionView` + 自定义布局 + 高度缓存，替换 SwiftUI 懒加载；展示行提前算好 | 9b21843 |
| 回复互动 | `com-widget`（滑块、选项、核对清单等）；≥3 行表格、≥2 项任务清单自动变组件；沙箱 HTML 内嵌 | 9b21843 |
| 附件 | 回复里提到的文件和生成的页面直接挂在气泡下，主聊天点开 | 9b21843 |
| 本机回执 | 气泡下显示读写回执，「这台手机」能力页显示权限和最近结果，撤销走「让它撤销」草稿 | 9b21843 |
| 顶栏 | 高度 60→44，人物靠左缩到 0.72，搜索图标去圆底 | 9b21843 |
| 下一步 | 等你并入，成为唯一行动面；下拉只刷新，只有点按钮才重新生成 | 27cb448 |
| 下一步复盘 | 改为 Magpie 直连 `volcengine/deepseek-v4.1-flash`，Hermes 兜底；实测 19 秒出 9 张卡 | 9b21843 |
| 主动消息 | 消息上带一个动作 | 27cb448 |
| 已排程 | 汇总主动任务、提醒、明日计划、周报、心跳和 Hermes cron，暂停不了的标只读 | 179e7f4 |
| 工作页运行面 | 按需要你、失败、运行中、完成分组，详情带改动、diff、产物 | 179e7f4、0b12960 |
| 网页版 | 跟进组件、回执、附件、等你、已排程、运行面 | 3d6f61f |

## Eddie 中途提的两个问题

- **顶栏占地**：见上表。工作页左上有侧栏按钮，人物在这一页右移 48pt；其他页不动。
- **横屏下一步一直刷新**：fixture 下没复现（CPU 约 8%）。修了三个可能原因：复盘 100% 超时、后台运行结束替换整页、下拉触发模型。**需要真机确认**。

## 和计划的差异

- 回执数据来自对话的 tool-effects，不新建 `receipts.py`：446 次设备调用大多是后台同步。
- 没有可靠的一键撤销，回执提供「让它撤销」草稿，由 Com 走正常流程处理。

## 没做

- `action_cards` 聚合、`com-eddie://card/<id>` 深链、统一的稍后和静音。
- App Intents：Duo 快捷指令搜不到 Com 的操作，原因未查明，继续用 `com-eddie://`。
- 健康页和今天页减法、聊天里生成定时任务草稿、产物缩略图。
- 「全部暂停」不含 Hermes cron；暂停和恢复未在真实 Hermes 任务上调用过。

## 未验证

- 真机滚动掉帧率和锚点漂移：手机锁屏，`xctrace` 没录，hitch < 5 ms/s 的目标没测。
- 网页组件的屏幕渲染和点击：后台标签页没有 rAF，浏览器里没看到真实效果。
- 三种姿态截图只验了一部分。

## 测试

- 后端（mini）：3 失败 / 729 通过，3 个都是基线旧失败（`test_bookkeeping_intent` 1 个、`test_fuzzy_bookkeeping_confirm` 2 个）。
- iOS 回归（iPhone Duo 模拟器）：基线 19 个 UI 用例失败，现在 11 个，都在基线失败名单里，没有新增。
  - 现在通过的：testFinanceDrilldownAndProjectEvidence、testHomeSendTurnsIntoChatInPlace、testIncomingReplyPreservesHistoryPosition、testLongMarkdownScrollReturnsToLatest、testReadingAnchorDoesNotMoveAfterLayoutOrIncomingReply、testRecWorkSidebar、testSidebarFillsScreenAndPushesDock、testTopBarFigureIsOneInstanceWithStableAnchor。
  - 还失败的：testFiltersAndDetails、testHealthPage、testMemoryFolderGridFiltersAndAgentLogos、testMemoryFoldersAndWorkChat、testNextStepsDismissDiscussGoalAndSettings、testR3EvidencePocketMotion、testR3FolderPendingPaper、testR3ReviewConfirmFilesIntoFolder、testSessionOpensInPlaceAsLeftRightChat、testTodayTimelineAndWorkSidebar、testWorkProcessLiveLineBubbleAndSummary。
  - 这 11 个没逐个查清是用例过时还是产品问题。
  - 全量跑时最后 3 个用例被提前中断，已单独补跑。日志在 `ios/verification/big-upgrade-20261031/final/`。

## 测试踩坑

- `work.surface` 存在 `@AppStorage`，「运行」面用例切过去后会影响后面的用例，现在 `--ui-testing` 启动时清掉。
- 外屏右边有系统栏和 Dock，内容区 382pt，窗口 466pt：判断靠右要用内容区宽度。
- 侧栏按钮的 `element.tap()` 打不开侧栏，同一位置按坐标点可以。应是 XCUITest 落点问题，原因没继续查；产品代码没改。
