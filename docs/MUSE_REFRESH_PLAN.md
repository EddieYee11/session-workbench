> 后续实现说明：此文保留 muse-refresh 基线记录。最新任务层已恢复明确任务授权，刷新不自动审批。手机日历仅权限页计数，未接入主对话上下文；Standard/Active 均开启重要通知，未实现差异化主动调度。语音发送成功只代表主对话消息已受理，不能视为实际记账成功。详见 HERMES_TASK_LOOP_IMPLEMENTATION.md。

# Com! muse-refresh 整合说明（2026-10-02）

分支：`muse-refresh`（基于 main @ 1.4.1）。目标：按 Eddie 确认的方向做第一轮整合——
Muse 式视觉语言、去掉审批流、手机权限真正用起来。审批不再复刻：App 直接拿最高权限，
工作建议自动执行，不再逐条要确认。

## 做掉的

### 1. 视觉统一（Muse 融合第一波）
- 底色从纯白 `#FFFFFF` 改为暖白 `#FAFAF8`（画布 90% 中性，点缀色只出现在可交互处）。
- 新增 `FrostedBar`：半透明暖白 + 顶部细线；底部导航改用它（毛玻璃感，不用实时模糊以保性能）。
- 设置从 `AlertDialog` 改为 `ModalBottomSheet`（`SettingsSheet`），与“更多”弹层、活动弹层同一语言。
- “更多”弹层新增“权限与上下文”入口。

### 2. 去掉审批流（最高权限）
- `Store.refreshWorkProposals()`：新到的工作建议（proposed 且未过期）自动调用 approve，
  每个 id 只自动批准一次；approve 按 request_id 幂等，不会重复派发。
- `WorkProposalSection` 重写为“工作动态”：只记录做了什么（标题/原因/指令/状态/进入工作会话），
  删除批准/拒绝按钮与二次确认弹窗。
- 对话页尾部卡片：“待你审阅”→“已自动接单/正在派发/已启动”；`approval_required` 状态文案改为“已自动继续”；
  红点提醒不再把审批算作“需要你处理”。

### 3. 权限：通知 / 位置 / 通讯录 / 日历（都接上，都用上）
- Manifest 新增：`ACCESS_FINE/COARSE_LOCATION`、`READ_CONTACTS`、`READ_CALENDAR`。
- 新文件 `PhonePermissions.kt`：
  - `PhoneContext`：授权状态、位置获取（LocationManager，无需额外依赖）、
    通讯录号码→名字解析、联系人计数、手机本地日历未来 24h 计数、位置共享开关。
  - `PermissionsSheetContent`：五行权限（通知/位置/通讯录/手机日历/麦克风），
    每行有状态、“为什么需要这个权限？”说明、按需申请；位置行带共享开关与当前位置刷新。
- 通知：沿用 1.4.1 的采集→Hermes 分析链路（已在用）。
- 位置/通讯录/日历：授权后上下文直接可见（当前位置、联系人数量、日历条数），
  为 Hermes 上下文做好准备。

### 4. Hermes 信任头 + 空状态 + 震动
- 对话页顶部 Hermes 形象/名字/状态行可点击，直达活动弹层（原来只有右侧小图标能点）。
- 空状态 `HermesHero`：4 个可点示例（今天安排/记一笔/未读通知/Pi 动态），点一下填入输入框。
- Hermes 发送按钮加 `HapticCue.Commit`（轻确认震动）；示例 chip 用 `Selection`。
  审批相关的震动已随审批流删除；导航切换、滚动等不加震动。

### 5. 主动强度开关
- `SignalConfig.intensity`：quiet / standard / active，放在通知设置页（Pill 分段选择）。
- 安静：关闭重要事项推送提醒，只在活动页看；标准/积极：重要事项推送提醒。
  该偏好已持久化，可供 Hermes/Mac mini 后续读取做更细的同步策略。

## 没做的（需要 Eddie / 后端配合）
- 后端（Mac mini）侧：Hermes 仍可能返回 `approval_required` 状态，客户端已按“自动继续”处理；
  如后端改成默认自动派发，可删掉 proposals 的 approve 调用。
- “Hermes 记得你”记忆卡片：Store 里没有记忆接口，等后端提供 `/personal/memory` 之类再补。
- 手机日历事件目前只在权限页计数，尚未并入“今天”页（PersonalOverview 走后端 Google 日历）。
- 未编译验证：云 VM 无 Android SDK，需在 Android Studio / Mac mini 上构建安装后手测：
  权限申请流程、自动批准是否触发、暖白与毛玻璃观感、折叠屏展开态。

## 文件清单
- 改：`Theme.kt`、`AndroidManifest.xml`、`Store.kt`、`WorkProposalSection.kt`、
  `HermesChat.kt`、`HermesHero.kt`、`ChatUI.kt`、`MainActivity.kt`、
  `NotificationSignals.kt`、`SignalSettings.kt`
- 新：`PhonePermissions.kt`、`docs/MUSE_REFRESH_PLAN.md`
