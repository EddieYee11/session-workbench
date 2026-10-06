# Com! 2.0.2 · 输入光标、语音取消与底边光晕

更新：2026-10-05，Asia/Shanghai。在 2.0.1（Hermes 全链路 + 参考图底部面板）基础上做三处修复，未改动后端与 Hermes 路由。

## 修了什么

### 1. 输入框光标跑到中间

`HermesChat.kt::HermesComposer` 的 `decorationBox` 在 `compact=true`（今天/任务/记忆/工作页底部 composer）时用了 `contentAlignment = Alignment.Center`。空文本时内层 `BasicTextField` 宽度为 0，被 Box 居中 → 光标落在输入框正中，占位文字也在中间。

改为 `Alignment.CenterStart`：横向靠左、纵向仍然居中，光标与占位文字回到最左边。

> 参考图（Jakub 那版）里占位文字是**居中**的，但居中同时会把光标也带走。这里选择统一左对齐。若要保留「未聚焦居中、聚焦后靠左」，需要再加一个 focus 状态分支。

### 2. 语音只能发不能撤

原录音态只有一个「停止并发送」。现在：

- `Store.cancelHermesVoice()`：停录 → `MediaRecorder.stop/release` → 删除录音文件 → 清状态与提示，**不提交**给 Hermes。
- composer 在 `voice == "recording" | "transcribing"` 时整条替换成录音条：左侧 `×` 取消、中间状态与说明、右侧计时 `m:ss` + 发送按钮。
- 触感：开始录音 `RecordingStart`、发送 `RecordingStop`、取消 `Reject`。

### 3. 语音光晕（voice-glow）

新增 `HermesVoiceGlow.kt`，形态参考 Jakub Antalik 的 npm `voice-glow`（`收藏库/App与UI设计/Jakub Antalik - Voice 语音光效（voice-glow）.md`），但 **Com! 是原生 Compose，没有接入那个 React 包**，是按同一形态自绘的：

- 三层结构：泛光（低透明度高梯度冒充模糊）→ 内光（贴底实心带）→ 流动描边（横向渐变，`flow` 无限循环）。零依赖，`Modifier.blur` 在 minSdk 28 上不生效，所以用叠层而不是真模糊。
- 高度跟音量走：`Store.hermesVoiceLevel`，由 `MediaRecorder.maxAmplitude()` 每 50ms 采样（`/24000` 归一化）得到；起音 70ms、收音 280ms 的不对称补间做 attack/release。
- 静默时保留 `reach * 0.14 + 呼吸` 的底线，避免「录着音但看起来没在听」。
- 转写态（`processing`）切冷色并叠一道左右往返的光束。
- 配色用 Com! 自己的暖色（`#D2703F` / `#C99A3C`）与 `CompanionBlue`，没有抄参考图的 candy 配色。

光晕是 composer 的同形 `Box` 兄弟节点（`matchParentSize()` + `clip(composerShape)`），画在 Surface 之上，随 `voice != "idle"` 淡入淡出。

### 4. 「Pi」改名补完

Eddie 早前要求「主页聊天里边的派的相关名称都改掉，现在用的是 Hermes」，2.0.1 只改了主聊天头部、小窗与主 composer。本次补齐：

- `AgentWorkCard` 兜底文案 `"Pi 正在处理"` → `"Hermes 正在处理"`
- `PhonePermissions` 权限页：通知 / 位置 / 麦克风四段文案
- `SignalSettings`「由隔离的 Pi / DeepSeek 分析」、`ConnectionDiagnostics`「主 Pi 配置」
- `WorkProposalSection`「Pi 工作动态」、`TodaySections`「Pi 任务」
- `WorkProposalSection` / `TaskLedger` 的「交给 X 的指令」改用 `agentDisplayName(agent)`
- `ModelPickerSheet` 的 `agentName` 与切换模型提示改用 `agentDisplayName(agent)`
- `ChatUI` 的「重启空闲 Pi 进程」→「重启空闲执行器进程」

**保留**：工作页的 Pi / Claude / Codex 选择入口、历史会话的真实执行器身份、聊天搜索里的 agent 过滤器、Pi 专属伙伴头像的无障碍描述——这些指向的是真的 Pi。

## 验收

- `assembleBenchmark` 通过；`testBenchmarkUnitTest` 71 tests / 0 failures。
- 实机（小米 Fold 内屏，同签名覆盖安装 2.0.2，配对与历史保留）：
  - 点开 composer，光标在最左、占位文字「消息」紧随其后。
  - 点麦克风 → 录音条（× / 正在倾听 / 0:03 / 发送），底边有暖色光晕；连拍两帧比对色带在横向流动。
  - 点 × → 立刻回到普通输入框，未产生消息。
- 已知未验：真实说话时音量到 1.0 的光晕上限、转写态扫光束，需要用真实语音复看一次。

## 注意

- 源码真源是 `work/工具与效率/会话工作台/`；`projects/session-workbench/` 是 1.3.x 的旧副本，别改错。
- 小米 Fold 双屏：`adb exec-out screencap -p` 会返回 `[Warning] Multiple displays` 文本，必须加 `-d <内屏 id>`（`dumpsys SurfaceFlinger --display-id` 取）。
- 录音满 60 秒会自动 `finishHermesVoice()` 发送——验收光晕时用 440Hz 测试音喂过麦克风，whisper 幻听出一句中文并当成了真实用户消息，Hermes 已把它存成记忆。测试时注意这条自动发送路径。
