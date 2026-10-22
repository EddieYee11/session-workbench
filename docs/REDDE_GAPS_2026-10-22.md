# Redde 借鉴项落地 · 2026-10-22

> 分支：`redde-gaps-20261022`，基于 `main@4847299`。
> 参照：[2026-10-22-redde-study.md](../../docs/2026-10-22-redde-study.md)（研究结论）与 Redde commit `747ccf0`。
> 范围：当前主线以 iOS + web + backend 为主（Android 自 10-08 后未改动），因此本轮落在 **backend + iOS**；web/Android 复用同一后端字段，未单独改 UI。

## 一、先核对：哪些其实已经有了

对照第 2 节能力表逐项查过当前代码，以下项**在 2.0.5 已存在**，不重复实现：

| 能力 | 现有实现 |
| --- | --- |
| 事件流（非轮询） | iOS `Com/Core/APIClient.stream` + `SSE.swift`；Android `Store.kt`；后端 `/personal/conversation/stream` |
| 发送队列 / 幂等 | iOS `PendingMessage` + `AppModel.deliver/recoverOutbox`（queued/checking/uncertain/rejected/delivered）与 `request_id` + receipt；Android `ConversationOutbox.kt` |
| 审批卡选项 | iOS `WorkApprovalCard` 已按 `params.availableDecisions` 生成按钮，并显示收件人/金额/路径等范围 |
| 长会话窗口 | `ChatView` 原有 30 条窗口 + 「更早的对话」；本轮改成按字符预算 |
| 计划/工具过程 | `WorkProcess`、`ProcessRow`、任务事件；已有折叠与状态 |
| 后台状态 | `LiveActivity`、`ComNotifications` 后台刷新 |
| Demo 数据 | `AppModel.seedUIPreview`、`--ui-testing`；后端 `probes/` |

## 二、本轮新增

### 1. 审批通知可直接批准 / 拒绝（P0）

- 后端 `push_notifications.py`
  - 新增 `approvals` 表与 `enqueue_approvals()`：5 秒轮询把 `runtime.approvals` 变成一次性的可操作推送；同一审批按 `device + approval` 去重，24 小时清理。
  - APNs payload 增加 `category: COM_APPROVAL`、`comApprovalID`、`comSessionID`；正文只放一句 `reason`（截 140 字），命令正文不入通知库。
  - Bark 走 `com-eddie://approval?id=…&sid=…` 深链。
- 后端 `app.py`：`notification_loop` 在 `process()` 前调用 `enqueue_approvals(list(runtime.approvals.values()))`。
- iOS `Com/ComApp.swift`
  - 注册 `COM_APPROVAL` 分类：批准（需设备认证）/ 拒绝（destructive）。
  - `didReceive` 在通知里直接 `POST /approvals/{id}`，不打开 App；默认点按则深链到对应工作会话。
  - `approvalWaiting()` 在工作页轮询到新审批且不在工作页时发本地通知（无 APNs 时兜底）。
- iOS `WorkSessionModel.refresh` 把 `live["approvals"]` 接到通知。
- iOS `AppModel.openApproval` + `RootView` 监听 `.comOpenApproval/.comApprovalResolved`。

### 2. 应用锁与后台遮罩（P2）

- 新增 `ios/Com/Platform/AppLock.swift`：`LocalAuthentication` + 30 秒宽限期；`.inactive` 立即盖住（任务切换器截图不露正文），回前台认证（Face ID → 设备密码）。
- `RootView` 全屏 `LockScreen` 覆盖；`ComApp` 在 `scenePhase` 变化时驱动。
- 设置 → 隐私：开关 + 「立即上锁」；设备无密码时说明不可用。
- `Info.plist` 增加 `NSFaceIDUsageDescription`。

### 3. 长会话按字符预算分页（P1）

- 新增 `ComCore.ChatPage`：按 `text` UTF-8 字节 + 附件/行开销计算权重，预算 30,000 字符，最少 4 条、最多 60 条，从最新往回取。
- `ChatView` 的 `historyWindow` 换成 `historyBudget`；「更早的对话」增加预算或拉服务端历史；跳转/新回复锚点用权重保持当前页。
- 新增 `Tests/Core/ChatPageTests.swift`（3 条）。

### 4. 语音控制词与可调停顿（P1）

- 新增 `ios/Com/Platform/VoiceCommands.swift`：整句匹配的中英文停止词（停/取消/不用了/stop/…），去标点与语气词后再判定，避免「停下想一想」误触发。
- `AppModel.transcribeVoice`：转写完成后命中停止词 → `voice.cancel()`、关闭小窗、不入发送队列。
- `VoiceRecorder.pauseToSend` 改为读取 `voice.pauseToSend`（0.6/0.9/1.2/1.8 秒），设置 → 快捷语音可选。

### 5. 二维码配对（P2）

- 后端 `POST /pair/code`（需已配对令牌）：生成新的 10 分钟一次性码，覆盖旧码。
- iOS 新增 `Views/PairCodeView.swift`：CoreImage 生成二维码（`com-eddie://pair?base=…&code=…`）、显示倒计时、分享链接、可重新生成。
- 设置 → 连接 → 「配对另一台设备」；`ComApp.onOpenURL` 处理 `pair` 深链，未配对时填入地址与码；已配对时提示先解除。
- `PairingView` 读取待处理的码，相机扫码即可自动填入。

### 6. 服务器只读诊断（P2）

- 后端 `/status` 扩展：`running`、`approvals`、`uptime`、`disk_free_gb`、`agents`（pi/codex 是否在 PATH）、`push` 通道；原字段保留。
- 设置 → 服务器：主机、已索引/运行中、等待审批、可用 Agent、磁盘余量、通知通道、运行时长、刷新按钮。

### 7. 语音回答审批（P1）

- `VoiceCommands.decision` 只认整句的「批准/同意/可以/拒绝/不行…」；`VoiceCommands.canAnswer` 只在「单命令审批 + availableDecisions 同时含 accept/decline」时开放。
- `WorkApprovalCard` 增加「用语音说」，把审批放进 `AppModel.pendingApproval` 后打开语音小窗；转写命中后直接 `POST /approvals/{id}`，不进入聊天队列。
- 多问题、密码、密钥和带选项的澄清不进语音路径。

### 8. work 会话用量（P1）

- `Runtime._usage` 归一 Pi `message_end.message.usage` 与 Codex `turn/completed` 的 usage；`Runtime.usage(sid)` 按事件文件 mtime/size 缓存，缺失或畸形返回 `null`，不猜。
- `/sessions/{sid}/live` 与 `/sessions/{sid}` 返回 `usage`；WorkChat 在标题下显示「上下文 N% · 本轮 N tok」。
- 新增 `tests/test_usage.py`（3 条）。

### 9. 审查修复

- `/pair` 的校验与消费放进 `flock`，并发请求只有一个能消费；输错码不消耗配对码。
- 通知审批失败/成功回到 App 时用 banner 显示；`reason` 为空不再回退到 `command`，通知库只存通用摘要。
- 只有 `availableDecisions` 同时含 accept/decline 的审批才标记 `actionable`，APNs 只给这类加 `COM_APPROVAL` 分类；其余点开处理。

### 10. 工程基线

- `ruff.toml`：把仓库既有的紧凑风格（长行、单行 import、分号）固化成配置。
- `pyrightconfig.json`：指向 `.venv` 与 `backend/`；仓库此前没有类型检查基线。
- `rules/ast-grep-rules/rules/python/unchecked-throwing-call-python.yml`：以同 id 规则遮蔽「所有 int()/float()/json.loads() 必须包 try」的内置启发式（本仓库在边界校验，逐行包 try 会制造大量噪音）。
- `.swiftlint.yml`（仓库根与 `ios/`）：行宽 320，匹配现有 Swift 代码。

## 三、验证

已跑：

```sh
cd backend && ../.venv/bin/python -m pytest tests -q
# 675 passed

cd ios
xcodegen generate
xcodebuild -project Com.xcodeproj -scheme Com \
  -destination 'platform=iOS Simulator,id=793310EE-0AE6-4761-944D-9F75D125CE0E' build
# exit 0

xcodebuild -project Com.xcodeproj -scheme Com \
  -destination 'platform=iOS Simulator,id=793310EE-0AE6-4761-944D-9F75D125CE0E' \
  -only-testing:ComCoreTests test
# exit 0
```

新增后端测试：`test_pair_code_needs_auth_and_status_reports_health`、`test_approval_becomes_actionable_notification_once`。
修正 `test_health.py` 中一条与 `version=2` 语义不符的夹具（旧格式行应被视为待补抓，新格式行带 `version`）。

**尚未在真机验证**：

- APNs 审批通知需要 `apns-config.json` 或 Bark，且手机上已注册设备；本轮只验证了入队、去重和 payload 结构（`test_approval_becomes_actionable_notification_once` 用假 sender）。
- 通知中心里的「批准/拒绝」需要解锁后执行，属于系统行为；模拟器无法完整复现设备锁屏。
- 应用锁的 Face ID 回退、二维码相机扫码需真机。

## 四、本轮没做的，以及原因

| 项 | 状态 | 原因 / 下一步 |
| --- | --- | --- |
| 多服务器 / 多 profile | 未做 | 当前 `base` + 单 token + 单套缓存是全局约定；改造成 server 列表要同时动 `SecureVault`、所有 `datasets` key、SSE 重连与切换时序。建议单独一版，以「先保存会话、再切、丢弃迟到响应」为验收 |
| 口述前缀切模型 | 未做 | 主对话没有「会话模型」概念；工作会话的模型选择在输入框里已有。等主对话支持 per-conversation 模型时再做 |
| 主对话上下文占用 | 未做 | 主对话的 Hermes 流没有稳定 usage；work 会话（Pi/Codex）已显示，主对话等上游字段稳定后再接 |
| 推送中继自建 | 未做 | 现有 APNs/Bark + 后台刷新已覆盖；自建中继属于基础设施，不是本轮收益点 |

## 五、给下一次的入口

1. 真机装 `redde-gaps-20261022` 构建，配置 Bark 或 APNs，制造一次 Codex 审批，验证锁屏通知两个按钮。
2. 设置 → 隐私开应用锁，切后台 30 秒再回来，确认盖住与 Face ID。
3. 设置 → 连接 → 配对另一台设备，用另一台 iPhone 相机扫码，确认只填入、不自动连接。
4. 长会话滚动到顶，确认「更早的对话」按预算增加而不是固定 30 条。
