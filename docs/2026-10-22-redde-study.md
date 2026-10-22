# Redde 项目研究：对 Com! 有哪些可取之处

> 说明：本文最初基于 `projects/session-workbench` 的 1.3.4 Android 基线（2026-10-22 已落后主线 51 个提交）。
> 当前主线为 Com 2.0.5（iOS + web + backend）；其中 SSE、outbox、审批选项、长会话窗口等已存在，
> 实际落地与差异以 [REDDE_GAPS_2026-10-22.md](REDDE_GAPS_2026-10-22.md) 为准。

> 研究日期：2026-10-22
> 对象：<https://github.com/goosehouse-llc/redde> （commit `747ccf0`，2026-10-21）
> 许可证：FSL-1.1-MIT（源码可见；内部使用允许，商业替代用途受限，两年后转 MIT）
> 结论前提：本文以我实际读过的代码和文档为准，未逐条跑过 Redde。文中「代码」= 已在本仓库核对，「README/文档」= 项目自述。

## 一句话结论

Redde 和 Com! 解决的是同一个问题：**人离开自己的电脑后，用手机继续推动电脑上的 AI 任务**。Redde 的价值不在功能多，而在把「离开电脑之后」的每个断点都补成了闭环：消息发不出去怎么办、回合没跑完怎么办、审批在锁屏时怎么答、长会话怎么读、换台机器怎么连。

Com! 现在的强项是**历史、终端和双 Agent**（Pi/Codex），Redde 的强项是**闭环与手感**。值得抄的是后者，不是它 233 个 Swift 文件的架构。

如果只做三件事：

1. 通知里直接批准 / 拒绝 / 回答（Com! 现在只能点回 App）。
2. `/live` 从 800ms 轮询改成 SSE 事件流（协议已经具备，只差传输层）。
3. 发送队列三态 + 断网重试（Com! 现在发送失败只报错，草稿留在输入框）。

---

## 一、Redde 是什么，成熟到什么程度

| 维度 | 事实 |
| --- | --- |
| 平台 | iOS 26+（iPhone / iPad / CarPlay / Watch），SwiftUI，主工程约 233 个 Swift 文件（含测试 383 个）、8.2 万行 |
| 后端 | 不是自带后端。连三种服务：Hermes Dashboard（WebSocket JSON-RPC）、Hermes API（runs + events）、任意 OpenAI 兼容端点 |
| 产品形态 | 自建 Agent 的随身客户端：语音、审批、会话账本、项目、技能、Cron、Kanban、文件、MCP、日志、重启更新 |
| 成熟信号 | 已上 App Store；有 UI 测试、demo 数据模式、对 Hermes 四个版本跑的集成测试脚本（`scripts/hermes-lab/lab.sh`）；文档记录到「哪种麦克风在多少 dBFS 下会误触发」这种颗粒度 |
| 关键取舍 | 无账号、无统计；语音识别在设备上；密钥进 Keychain；唯一自营服务是可选加密推送中继 |

对 Com! 的含义：这是一个**把同类问题做了很久、且把边界条件写进代码注释**的参照物。它的功能列表不必全抄，但它的「失败路径设计」几乎每一项都能直接映射到 Com! 的缺口。

---

## 二、Com! 与 Redde 的能力对照

| 能力 | Redde 做法 | Com! 现状（代码位置） | 差距判断 |
| --- | --- | --- | --- |
| 实时更新 | SSE / WebSocket，按事件类型增量推送 | 800ms 轮询 `/sessions/{sid}/live`（`Store.kt:114`），详情/列表每 4s 刷新 | 中高：延迟、耗电、服务端压力都可降 |
| 发送可靠性 | Outbox 三态，严格顺序，1 小时过期转人工确认 | 直接 POST；失败报错，草稿保留；有 `request_id` + receipt（`Store.kt:193`） | 高：弱网/锁屏场景会丢动作 |
| 回合保活 | `UIBackgroundTask` + iOS 26 持续处理任务，回合跑完再通知 | 前台轮询；进程被杀后只剩服务端 tmux 在跑 | 高：通知和「跑完了」的体验断档 |
| 通知 | 通知里 Approve / Deny / 文字回答；按会话静音；加密推送 | 15 分钟周期 Worker 检查状态，点通知只能回 App（`StatusWorker.kt:5`、`MainActivity.kt:50`） | 高：审批必须进 App 是最大摩擦 |
| 审批 | 分型：command / clarify / sudo / secret；带完整命令、描述、可选项 | `params.command` + 问题选项已有（`runtime.py:116`、`MainActivity.kt:70`）；但非问题类只给 accept/decline，`availableDecisions` 没暴露，Pi 会话不产生审批 | 中高：危险操作看不清、选项语义丢失 |
| 语音输入 | 设备端识别；端点检测可调；barge-in；停止短语；语音答审批 | 固定 0.5s 静音提交、最长 60s；音频送 Mac mini 本地 ASR（`QuickVoiceActivity.kt:210`） | 中：够用，但「对话感」和误触发边界没做 |
| 语音控制 | 口述前缀 → 加文本前缀 / 切模型 / 两者 | 无；快捷语音固定 Pi | 中：低成本高感知 |
| 长会话 | 按字符预算分页（约 3 万字），4–60 条，流式文本 20Hz 合并 | `LazyColumn` 全量渲染（`ChatUI.kt:349`）；无分页预算 | 中高：长会话会卡、内存涨 |
| 富文本 | 代码高亮、表格、任务列表、Mermaid、KaTeX，全离线 | Markwon + 表格/删除线/链接（`ChatUI.kt:414`）；无 Mermaid/公式/高亮 | 中：技术会话里公式和图表会越来越多 |
| 上下文/用量 | 上下文环、token 数、tok/s；探测模型窗口 | 无 | 中：用户不知道「快满了」 |
| 结构化过程 | 工具卡、子代理、计划清单（todo.updated）、审批卡分离 | 工具/进度合并成文本行（`ChatUI.kt:399`）；无计划清单 | 中：过程可读性差距明显 |
| 配对 | 二维码 / 链接 setup code；先展示后保存；连接测试；失败可撤销；密钥不进网页 | 6 位配对码换 token（`backend/pair.py`、`MainActivity.kt:153`） | 中：换机/多设备体验差 |
| 多服务器 | 多 Hermes + 多 profile；切换有严格顺序；迟到响应丢弃 | 单 `base` + 单 token | 低（当前）→ 高（接 MBP 后） |
| 手机运维 | 服务器状态、MCP 开关与测试、日志、重启/更新、文件浏览编辑 | 有终端；无状态页/文件页 | 中：终端能兜底，但不适合日常 |
| 隐私 | 生物识别锁、截屏遮罩、隐身会话、密钥分域 | Keystore 加密 token；无应用锁/隐身 | 中低：个人设备，但有价值 |

---

## 三、最值得抄的 15 项

### P0：先把「离开电脑后的闭环」补上

#### 1. 通知就是操作面，不是提醒器

**Redde 做法**

- 审批通知注册固定 category，带 `Approve` / `Deny` 两个 action；`Deny` 标 destructive，两者都 `.authenticationRequired`（`Echo/Services/Notifier.swift:100-132`）。
- 问题通知带 `UNTextInputNotificationAction`，可以直接在通知里打字回答；有选项时按请求动态注册一个一次性 category，把选项做成按钮（同文件 150-158）。
- 推送由 Hermes 插件发出，中继只转发密文；通知扩展在设备上解密后替换文案（`docs/push.md`）。

**为什么对 Com! 有用**
Com! 的高频场景是「Pi 停下来等我批准」。现在必须：收到通知 → 解锁 → 打开 App → 找到会话 → 点批准。Redde 把这条路径压成一次点击。

**Com! 落点**

- `StatusWorker` / `Store.notifyStatus`：通知增加 action。Android 用 `PendingIntent.getBroadcast` 指向一个新的 `ApprovalActionReceiver`，直接调 `POST /approvals/{id}`。
- 后端 `/approvals` 返回里补 `choices`、`kind`、`command`、`description`（现在只有 id/title/text）。
- 锁屏安全：Android 没有 iOS 的 `.authenticationRequired` 等价物。建议 action 触发时若 `KeyguardManager.isDeviceLocked`，发一条「解锁后处理」并把审批 id 存成 pending，进 App 后弹确认；不要在锁屏直接执行。
- 有选项的问题：用 `RemoteInput` + `addAction`，或在通知里放「批准 / 拒绝 / 打开」三键，复杂问题仍回 App。

**成本**：后端半天，Android 1–2 天。风险低。

---

#### 2. 发送队列：三态 + 顺序 + 过期降级

**Redde 做法**（`Echo/Models/OutboxItem.swift`）

- `queued`：前一条回复还在流式输出，排在后面。
- `waitingForConnection`：服务器不可达，联网后自动重发。
- `paused`：Stop 之后、回合失败、或排队超过 1 小时（`staleAfter = 3600`），改为等用户确认，不自动发。
- 严格按 oldest-first 发送；队列行在 UI 里单独显示，可取消/编辑（`QueuedMessageRow.swift`）。

**为什么对 Com! 有用**
Com! 已经有 `request_id` + receipt 防重复（这是很好的基础），但缺「发不出去时怎么办」。地铁、电梯、Mac mini 重启都会命中。

**Com! 落点**

- 新增 `Outbox.kt`：持久化到 SharedPreferences/文件，字段 `{requestId, sessionId, text, model, effort, state, queuedAt}`。
- `Store.mutation()` 改成先入队、再由单一 worker 顺序发送；发送前查 receipt（已有逻辑），成功后出队。
- 超过 1 小时仍未发出 → 标 `paused`，在会话里显示「这条还没发出去，点按重试」。
- 网络恢复：`ConnectivityManager.NetworkCallback` 触发 flush。

**成本**：2–3 天。风险中：要处理好「已送达但回执丢失」的重复发送，现有 receipt 机制正好复用。

---

#### 3. 回合在后台跑完，而不是靠前台轮询

**Redde 做法**（`Echo/Services/BackgroundTurn.swift`）

- 双保险：`UIApplication.beginBackgroundTask` 约 30 秒；再加 iOS 26 的 continued-processing task，允许锁屏后继续联网跑完，系统活动里显示进度和停止按钮。
- iOS 拒绝时（后台启动、模拟器、负载高）回落到 30 秒，并标记 `expired`，恢复前台时重新同步。
- 回合结束才发「回复完成」通知，避免「通知来了但内容还没到」。

**为什么对 Com! 有用**
Com! 的会话在服务端 tmux 里继续跑，但手机端展示会断：进程被回收后，用户再打开要靠重新拉详情。更关键的是**完成通知**：现在 15 分钟一次的 Worker 最多延迟 15 分钟，长回合结束时无法及时通知。

**Com! 落点**

- 回合进行中启动 `ForegroundService`（targetSdk 35 需要声明 `dataSync` 类型），通知栏显示「Pi 正在执行 · 停止」，与 Redde 的系统活动同构。
- 或用 `WorkManager` 的 expedited work + `setForeground`，跑一个「订阅 SSE 直到 turn 结束」的 worker。
- 进程被杀时，服务端 tmux 不受影响；下次打开用 `after` cursor 补事件（`/live` 已支持 cursor，只是现在没用）。

**成本**：2 天。风险中：Android 后台限制因厂商而异（小米尤其），需要真机验证。

---

#### 4. 审批卡要「能看懂」，不只是「能点」

**Redde 做法**

- 审批请求是结构化对象：`command`、`description`、`choices`（once/session/always/deny），UI 直接按 choices 生成按钮（`Echo/Views/ApprovalCard.swift`）。
- 还区分 `clarify`（问题，可多选/多问题）、`sudo`（要密码）、`secret`（要密钥）；密码类不提供语音回答（`SpokenRequest.swift`）。
- 通知和语音都复用同一份 choices，不另造语义。

**为什么对 Com! 有用**
Com! 的审批数据其实已经带 `params.command` 和 `questions.options`，卡片也渲染了命令和问题；缺的是两件事：非问题类只给「允许本次 / 拒绝」，而 Codex 的 `availableDecisions` 可能是 `acceptForSession` / `cancel`；以及 Pi 会话当前用 `--approve` + `pi-yolo`，根本不产生审批，用户容易误以为「Pi 不需要批准」。

**Com! 落点**

- `runtime.py:116` 的 approval 事件补：`kind`（command/clarify/sudo/secret）、`choices`（来自 `availableDecisions`）、`description`；问题类已有 `questions`。
- `MainActivity.Approval` 按 `kind` 分支渲染；命令用等宽字体、可选中、长命令可展开；危险命令（`rm -rf`、`sudo`、写系统目录）加色标；非问题类按 `availableDecisions` 生成按钮，而不是写死两个。
- 多问题用分步表单，不要挤在一张卡里。
- Pi 侧：如果希望 Pi 也有「需要批准」而不是全放行，需要换掉 `pi-yolo.ts`，改用 Pi 的审批扩展；这是产品决策，不是 UI 改动。

**成本**：后端 0.5 天，Android 1 天。

---

### P1：语音与阅读体验

#### 5. 端点检测参数化 + 停止短语

**Redde 做法**（`Echo/Services/Voice/SpeechRecognizer.swift`、`StopPhrase.swift`）

- 端点判定是自己写的：`silenceTimeout 1.2s`、`speechMargin 0.12`、`maxUtterance 45s`，并明确说明「API 不提供 endpointing，所以自己做」。
- 停止短语是**整句匹配**，先剥掉礼貌词（okay / thanks / please / for now），避免「stop by the store」被误判；用户可自定义最多 20 条。
- Barge-in 只看电平不看词：因为识别器在扬声器播放时会把回声写进转写；给出实测 dBFS 阈值（手机 -28、耳机 -38，静默 1.2s 学习回声）。

**为什么对 Com! 有用**
Com! 的 0.5 秒静音是硬编码，且是「录音结束才 ASR」。在嘈杂环境或思考停顿时体验差；没有「停止」语义，只能松手/等 60 秒。

**Com! 落点**

- `SpeechEndpointDetector.kt` 暴露参数：静音阈值、最短语音、最长录音；设置页可调。
- 增加停止短语匹配（中文：停、不用了、结束、谢谢；英文同 Redde），整句匹配 + 去填充词。
- 如果要 barge-in，先做「播放时压低麦克风增益」或直接不做——Redde 的结论是这件事很容易做坏，收益有限。

**成本**：1–2 天。

---

#### 6. 语音回答审批：有限词表，默认不批准

**Redde 做法**（`SpokenRequest.swift`）

- 只有「一个是/否明确的审批」和「单问题、选项不超过 5 个」才能语音回答；密码、密钥、多问题一律回屏幕。
- 回答必须**整句**命中短词表（approve/yes/deny/no），「sure, why not」不算；没听清会再问一次，然后放弃。
- 语音审批的提示会明确说「任何在场的人都可能批准」，把风险讲给用户。

**为什么对 Com! 有用**
Com! 的语音小窗目前只能发消息，不能答审批。开车/走路场景里这是最实用的一步，但也是最容易出安全事故的一步。

**Com! 落点**

- 只对 `kind == command` 且 `choices` 含明确 yes/no 的审批开启；词表：批准/同意/可以/拒绝/不行。
- 回答前念出命令的前 80 字；不确定就回屏幕。
- 设置里默认关闭，文案写清「旁边的人也能批准」。

**成本**：1 天（在现有语音小窗上加状态机）。

---

#### 7. 口述前缀：一句话切换模型

**Redde 做法**（README「Spoken prefixes」+ `SpokenPrefixesView.swift`）

- 用户配置一个前缀词，例如「deep」「work」；以它开头的口述消息会被剥掉前缀，然后：加一段文本前缀、切换会话模型、或两者。
- 只在语音和 Siri 生效，不影响打字，避免误伤正文。

**为什么对 Com! 有用**
Com! 1.3.4 刚做了模型选择，但每次都要点「＋」开面板。语音场景下，「用 deep 模式问」比翻菜单自然得多。

**Com! 落点**

- `QuickVoiceModel` 里加前缀表：`{前缀: {model, effort, textPrefix}}`，命中后先调 `/sessions/{sid}/input` 的 model 字段（后端已支持），再发正文。
- 注意 Pi 的模型切换要空闲时进行（`com-set-model` 已处理），失败要回退并告知。

**成本**：1 天。

---

#### 8. 长会话分页 + 流式节流

**Redde 做法**（`docs/ARCHITECTURE.md`「Rendering」、`TranscriptPage.swift`）

- 不是按条数分页，而是按**字符预算**：约 30,000 字符（约十屏），最少 4 条、最多 60 条；「显示更早消息」再往前翻。
- 原因写得很具体：非 lazy 的 stack 每屏约一张位图，60 条长回复能到 1GB+；每次流式更新都要遍历整页。Com! 用 LazyColumn 不会 1GB，但每帧 recompose 全部可见项仍有成本。
- 流式文本约 20Hz 合并，思考内容 5Hz；工具事件、中断、回合结束时强制 flush。`StreamingTail` 只做「最后 18 个字渐入」，且明确说**不做逐帧动画**，因为会 60Hz 重排整段。

**为什么对 Com! 有用**
Com! 现在每 800ms 拉一次 `/live`，每次返回完整 items，UI 全量替换。长会话 + 长回复时会明显掉帧；而且轮询本身让「流式」看起来像一跳一跳。

**Com! 落点**

- `ChatUI.kt:349` 的 `LazyColumn` 保持，但 `displayRows` 只取「从末尾往前、累计字符 ≤ 30k」的窗口；顶部加「显示更早」。
- 流式合并：`WorkbenchModel` 里对同一 message id 的 delta 做 50ms 节流（coroutine `sample`），不要每个事件都 `mutableStateOf` 赋值。
- 工具/思考折叠默认收起，展开状态用 `rememberSaveable` 保留（Com! 已有部分）。

**成本**：1–2 天。

---

#### 9. 事件流替代轮询

**Redde 做法**

- Dashboard 用一条 WebSocket 承载 JSON-RPC，事件按类型分发：`message.delta`、`reasoning.delta`、`tool.start/complete`、`approval.request`、`clarify.request`、`sudo.request`、`secret.request`、`todo.updated`、`session.usage`（`HermesServeTransport.swift:127-211`）。
- Hermes API 用 SSE：`POST /v1/runs` 拿 run id，再 `GET /v1/runs/{id}/events` 流式读；`SSEParser` 是增量解析（`Transport/SSEParser.swift`），支持多行 data、CRLF、注释行。
- 断线重连靠 cursor / last event id，客户端只处理增量。

**为什么对 Com! 有用**
Com! 的 `/live` 已经返回 `{items, cursor, approvals, status}`，但每次都是全量 items，客户端每 800ms 拉一次。改成 SSE 后：延迟从 0–800ms 降到实时、请求数下降两个数量级、服务端不用反复读事件文件。

**Com! 落点**

- 后端新增 `GET /sessions/{sid}/live/stream?after=N`，`StreamingResponse` + `text/event-stream`，事件用 `id:` 带 seq，`data:` 带 JSON；空闲每 15s 发注释心跳。
- Caddy 反代要确认不缓冲（`flush_interval -1` 或依赖 Caddy 对流式响应的自动 flush；上线前用 `curl -N` 验证）。
- Android 用 OkHttp `okhttp-sse`（或手写 `BufferedSource.readUtf8Line`），断线指数退避，重连带 `after`。
- 保留轮询作为降级路径（老版本 App、代理不支持流式时）。

**成本**：后端 1 天，Android 1–2 天。风险中：小米后台杀连接、Caddy 缓冲、代理超时。收益最高的一项。

---

#### 10. 把「过程」建模成结构，不是文本

**Redde 做法**

- `Message` 里分 `reasoning`、`tools`、`subagents`、`approvals`、`attachments`，各自有视图（`SubagentRows`、`ToolActivity`、`TodoChecklist`）。
- 计划清单专门解析 Hermes 的 todo 工具调用，支持「整体替换」和「按 id 合并」两种语义（`TodoList.swift`），最多 256 项。
- 上下文占用单独建模：`usage` + `contextWindow`，用环显示；窗口大小主动探测（llama.cpp `/props`、`/v1/models` 的 `context_length`），探测失败缓存为 0，不反复问。

**为什么对 Com! 有用**
Com! 的实时输出把 tool/progress 都压成 `role + title + text`，用户看到一长串「工具 · 执行中」。Pi 的 `todo`、Codex 的计划、子代理都没有结构化呈现，长任务的可读性差。

**Com! 落点**

- `pi-events.ts` 已经能拿到 `tool_execution_*` 和 `message_update`；后端 `live_items` 里把 `todo`/`plan` 工具调用单独成 `kind: "todo"`，带 items 和 status。
- Android 端 `ChatUI` 增加 `TodoChecklist` composable（勾选/进行中/待办），折叠在回复下方。
- 上下文：`/sessions/{sid}` 返回 `usage`（Pi 的 `message_end` 通常带 usage，Codex `turn/completed` 带 usage；接入前先实测字段）与 `contextWindow`（Pi 可由 `/models` 或会话配置推），UI 在标题栏加一个小环。
- tok/s：用首 token 时间和结束时间算，显示在回合 footer，不必每帧更新。

**成本**：后端 1 天，Android 1–2 天。

---

### P1/P2：连接、运维与隐私

#### 11. Setup code：把配对做成可审计的动作

**Redde 做法**（`docs/ARCHITECTURE.md`「Setup codes」、`SetupCodeInstaller.swift`）

- 三种入口：扫码、粘贴、点链接；统一进一个确认 sheet。
- **链接是不可信输入**：不在到达时应用；展示每个地址的全文和「将连接哪一个」；地址必须 http/https、有 host、不能带用户名；版本不认识的 code 整体拒绝。
- **绝不覆盖已配置的服务器**：只有该服务器在 Keychain 里完全没有密钥时才填入；否则新增一台并切换。
- 安装后立刻测连接，失败可以撤销（返回 receipt，`remove` 恢复原状）。
- 密钥默认不出现在 code 里，要看需生物识别；带密钥的链接复制后 2 分钟清空剪贴板。

**为什么对 Com! 有用**
Com! 的 6 位配对码够用，但换手机、重装、加第二台 Mac 时都要回终端跑脚本。二维码/链接能把「配对」变成扫一下，且可以复用同一套安全审查。

**Com! 落点**

- `pair.py` 生成一个短时效 token（如 10 分钟、一次性），编码成 `com://pair?base=...&code=...`，同时打印 ASCII QR（`qrencode`）。
- Android 加 `QR` 扫描（ML Kit / ZXing）或「粘贴配对链接」；解析后先展示 base + 主机名，再调 `/pair`。
- 后端 `/pair` 增加「一次性 + 过期 + 使用后失效」；返回的 token 仍只存 Keystore。
- 不做「链接自动应用」，保持「先展示、后确认」。

**成本**：1–2 天。

---

#### 12. 多服务器/多配置的切换纪律

**Redde 做法**

- `Settings` 里的连接字段是「当前服务器的可写副本」；切换时先把当前会话存盘（带 serverID），再断开旧 socket、清 cookie，最后加载新服务器。
- 列表请求按 `connectionKey`（server + profile）打标，切换后到达的旧响应直接丢弃。
- 密钥按 `<account>@<server id>` 分域；删除服务器时一并删。
- 旧版本单服务器升级：把现有配置变成第一台，密钥逐条迁移并读回验证后才删旧项。

**为什么对 Com! 有用**
现在只有 mini 一台，但你已经有多台机器的使用习惯（MBP / mini）。一旦加第二台，「切过去看到上一台的会话」「密钥串台」是最常见的 bug。

**Com! 落点**

- `Store` 从单 `base/token` 改成 `servers: [{id, name, base, tokenRef}]` + `activeServerId`；token 在 Keystore 里按 id 分条。
- `WorkbenchModel` 的所有请求带 `serverId`，回调时比对当前 id，不一致就丢弃。
- 切换时先 `refreshDetail` 存缓存，再清 live/detail 状态。

**成本**：3–4 天（现在做可以，但可以等真有第二台机器再做）。

---

#### 13. 手机上的「服务器状态页」

**Redde 做法**

- Settings → Gateway 一屏：版本、是否在跑、连接了什么、机器负载/磁盘、MCP 服务器列表（每个有开关和测试）、日志（按级别/搜索）、重启、检查更新。
- 关键设计：不提供「启动」按钮，因为启动会在服务器上装 launchd/systemd 服务，「这不是手机该决定的事」；只给命令。
- 重启/更新的跟踪有明确结束条件（命令结束、或 boot_id 变化），不会无限转圈。

**为什么对 Com! 有用**
Com! 现在出问题只能进终端。一个只读状态页 + 两个危险动作（重启后端、重启 Pi）能覆盖 80% 的「怎么不动了」。

**Com! 落点**

- 后端已有 `/status`（index、managed、host、default_cwd），扩展为 `{gateway_ok, pi_version, codex_version, caddy_ok, disk, uptime, sessions_indexed}`。
- Android `MeScreen` 加「服务器」区：状态、延迟、最近错误、重启按钮（二次确认）。
- 文件浏览可以后置；先做「只读日志尾部」就够排障。

**成本**：1–2 天。

---

#### 14. 隐私与设备边界（按需）

**Redde 做法**

- 生物识别锁：离开前台超过宽限期才锁；进入后台立刻盖一层遮罩，避免 App Switcher 截图泄露内容（`AppLock.swift`）。
- 隐身会话：不落盘、不进列表；离开时删服务端会话；删不掉的下次启动重试（`Incognito.swift`）。
- 密钥 `WhenUnlockedThisDeviceOnly`；iCloud 同步时走 iCloud Keychain。
- 推送中继只存 APNs token 和 secret 的 SHA-256，密文用 X25519 + HKDF + AES-256-GCM，中继没有私钥。

**为什么对 Com! 有用**
Com! 能在手机上触发 Mac mini 的真实工作（最高权限），一旦手机丢失，风险比普通聊天 App 高。至少该有应用锁和「最近任务」遮罩。

**Com! 落点**

- `BiometricPrompt` 应用锁（设置里可关）；`onPause` 时 `FLAG_SECURE` 或盖品牌遮罩。
- 隐身会话可以不做；先做「不在通知里显示正文」的选项（现在通知只显示标题+状态，已经不错）。
- 推送中继不建议自建；如果将来要做后台通知，优先用「服务器 → 手机」的自建 WebSocket/长连接，而不是经过第三方。

**成本**：1 天（应用锁 + 遮罩）。

---

#### 15. 工程方法：demo 模式、版本矩阵、把实测写进文档

**Redde 做法**

- 每个复杂界面都有 demo 数据开关（`-echo.demoGateway`、`-echo.demoFiles`），UI 测试直接跑 demo，不依赖真服务器。
- `scripts/hermes-lab/lab.sh` 对 Hermes 0.21.0 / 0.21.3 / 0.21.5 / 0.22.2 跑同一套动作（登录、文件、Bot、Routine），把「哪个版本支持什么」变成可执行断言。
- 文档记录的是**测量值**：麦克风 -28/-38 dBFS、回合分页 3 万字、60 条长回复 1GB、流式 20Hz。这些数字让后来的人不用重新踩坑。
- 每条协议行为都标了版本；旧版本不支持时 UI 明确说「需要 Dashboard 登录 / 需要 0.22」。

**为什么对 Com! 有用**
Com! 的 `docs/app-overview.md` 已经写了「已实现 vs 已验证」的区分，这是好习惯。下一步是把「对 Pi/Codex 版本的假设」也写进去，并加一个可重复的 demo 模式，减少每次真机验证的成本。

**Com! 落点**

- `WorkbenchModel` 支持 `DEMO=1` 或 `-com.demo`，返回固定会话/事件，让 Compose Preview 和 instrumentation test 可跑。
- `backend/tests` 已有 15 项；补一个「用固定事件文件驱动 `/live` 和 SSE」的契约测试。
- 版本记录里写清「Pi 版本 / Codex App Server 版本 / 实测通过的交互」，而不只是 App 版本号。

**成本**：1 天起步，长期收益最大。

---

## 四、明确不建议照搬的部分

| 不抄 | 原因 |
| --- | --- |
| 主工程 233 个 Swift 文件的分层 | Com! 只有 31 个 Kotlin 文件、4k 行；按 Redde 的粒度拆会先把自己拖死。按需拆 `Outbox`、`EventStream`、`Approval` 三个模块即可 |
| 三种后端连接 + Profile + Bot + Kanban + Cron 全套 | 这是 Hermes 生态的产品面，Com! 的核心是 Pi/Codex 双 Agent + 历史 + 终端，不需要第三套抽象 |
| CarPlay / Watch / Siri / AirPods 头势 / APNs relay | iOS 专属；Android 对应物是 Glance 小组件、Wear OS、Assistant/App Actions、自建长连接，成本和收益都要重算 |
| 自建推送中继 | 对个人工具是过度设计；Com! 的场景里，前台服务 + 通知已经能覆盖大部分 |
| 「无第三方依赖」的渲染器 | iOS 生态里这是合理取舍；Android 上 Markwon、Coil、OkHttp 都是成熟选择，自己写解析器不划算 |
| 把每个交互都做成「有解释的设置项」 | Redde 的设置项非常多，是因为它有大量付费用户和平台差异；Com! 是个人工具，默认值 + 少量开关更好维护 |

另外，FSL-1.1-MIT **不是 OSI 开源许可**：内部使用、研究、非商业教育可以；如果 Com! 将来要商业化分发，直接拷贝代码前需要单独确认「是否构成 Competing Use」。当前阶段借鉴设计与思路没有问题，但不要整段搬运 Swift 实现。

---

## 五、建议的落地顺序

### 1.3.5（小步、可验证）

1. **通知可操作审批**：`StatusWorker` + `ApprovalActionReceiver`；后端 approval 事件补 `choices`。
2. **审批卡结构化**：`kind` / `command` / `description` / 多问题分步。
3. **长会话窗口**：按 3 万字符截取 + 「显示更早」；流式 50ms 合并。
4. **`/live` SSE**：新端点 + Android OkHttp SSE；保留轮询降级。

验收：锁屏收到审批 → 直接批准 → 会话继续；断网发消息 → 恢复后自动送达一次；10 万字会话滚动不卡；SSE 断开后 5 秒内自动重连。

### 1.4（体验层）

1. **Outbox 三态** + 连接恢复重试。
2. **前台服务**：回合进行中常驻通知 + 停止按钮；完成通知即时。
3. **语音**：端点参数、停止短语、语音答审批（默认关）。
4. **上下文/用量**：标题栏环 + 回合 footer 的 tok/s。
5. **服务器状态页**：状态、日志尾部、重启。

### 以后（按真实需求触发）

 1. 二维码配对 / 换机。
 2. 多服务器（真的加了第二台 Mac 再做）。
 3. 文件浏览、Glance 小组件、QS tile、分享入口。
 4. 应用锁 / 遮罩 / 隐身会话。

---

## 六、给 Com! 的三条判断

1. **Com! 的差异化不是「又一个 Agent 客户端」，而是「Pi/Codex 的历史与终端」**。Redde 没有历史索引，也没有完整终端；这两项不要为了「像 Redde」而弱化。
2. **Redde 最值得学的是它对失败路径的诚实**：每个功能都写了「什么时候不工作、怎么告诉用户、怎么恢复」。Com! 的后端已经有 receipt、capabilities、`archived` 这些好基础，下一步是把它们暴露到 UI 和通知里。
3. **不要追功能列表**。Redde 有 8 万行，是因为它要覆盖 iOS 的全部入口和 Hermes 的全部版本；Com! 只要把「手机离开电脑后的 5 个断点」补完，体验就会跨一个台阶：发得出、跑得完、看得懂、答得上、找得回。

---

## 附：关键源码索引（便于回看）

| 主题 | Redde 文件 |
| --- | --- |
| 架构与取舍 | `docs/ARCHITECTURE.md` |
| 通知与推送 | `Echo/Services/Notifier.swift`、`docs/push.md`、`EchoPush/` |
| 发送队列 | `Echo/Models/OutboxItem.swift`、`Echo/Views/QueuedMessageRow.swift` |
| 后台回合 | `Echo/Services/BackgroundTurn.swift` |
| 审批 / 问题 / sudo / secret | `Echo/Views/ApprovalCard.swift`、`Echo/Services/Voice/SpokenRequest.swift` |
| 语音 | `Echo/Services/Voice/`（`SpeechRecognizer`、`StopPhrase`、`BargeInDetector`、`SpokenRequest`） |
| 事件流 | `Echo/Services/Transport/SSEParser.swift`、`HermesServeTransport.swift` |
| 渲染与分页 | `docs/ARCHITECTURE.md#Rendering`、`Echo/Models/TranscriptPage.swift`、`Echo/Views/StreamingTail.swift` |
| 计划清单 | `Echo/Models/TodoList.swift`、`Echo/Views/TodoChecklist.swift` |
| 上下文/用量 | `Echo/Services/ContextWindowProbe.swift`、`Echo/Models/Message.swift` |
| 配对 | `Echo/Services/SetupCodeInstaller.swift`、`Echo/Views/SetupCodeSheet.swift`、`scripts/setup-code.py` |
| 多服务器 | `Echo/Services/ServerSwitcher.swift`、`Echo/Models/HermesServer.swift` |
| 隐私 | `Echo/Services/AppLock.swift`、`Echo/Services/Incognito.swift` |
| 小组件 | `Echo/Services/StatusWidgets.swift`、`WatchWidgets/` |
| 测试方法 | `scripts/hermes-lab/lab.sh`、`EchoUITests/`、`-echo.demo*` 开关 |
