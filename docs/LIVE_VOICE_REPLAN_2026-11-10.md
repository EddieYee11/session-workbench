# Com! 实时语音通话 · 重规划（2026-11-10）

> 目标：通话流畅、像真人、界面好看。本文件是现状梳理 + 改造清单；旧白皮书 `AI_REALTIME_VOICE_RESEARCH.md` 保留作背景，结论以本文件为准。

## 一、现状结论（都已对着代码核实）

| # | 问题 | 位置 | 后果 |
|---|------|------|------|
| 1 | 没开真正的回声消除：AVAudioEngine 没调 `setVoiceProcessingEnabled(true)`，只设了 `.voiceChat` 模式 | `LiveVoiceSession.swift:284-326` | 只能靠下面第 2 条硬顶 |
| 2 | Com 说话期间上行全换成静音帧，音量 ≥0.44 连续 200ms 才放行 | `LiveVoiceSession.swift:330-354` | 正常音量打不断；打断成功也吞掉句首；服务端听不到人声 |
| 3 | 上行 100ms 一帧 | `LiveVoiceSession.swift:13` | 固定多 100ms 延迟 |
| 4 | 抖动缓冲按「每包间隔 100ms」估抖动，实际上游是突发下发 | `LiveVoiceSession.swift:622-641` | 首包多等 80–240ms |
| 5 | 圆球音量在「排入播放队列」时算，不是播放时算 | `LiveVoiceSession.swift:678-679` | 球的起伏跑在声音前面，对不上嘴 |
| 6 | 缓冲一空就切回「在听」 | `LiveVoiceSession.swift:695-698` | 说话/在听来回闪 |
| 7 | 断线即失败，无重连；上游连接约 10 分钟必断，未做 sessionResumption | `LiveVoiceSession.swift:478-520`、`voice_live.py:596-617` | 聊到 10 分钟掉线、上下文全丢 |
| 8 | 主力模型是 `gemini-live-2.5-flash`（非原生音频），原生音频排第二 | `voice_live.py:52-77` | 声音平、没情绪 |
| 9 | 未开 affective dialog / proactive audio；静默判停 450ms（官方建议 500–800） | `voice_live.py:600-612` | 语气不随人变；想一下就被抢话 |
| 10 | 人设只有 5 条原则，没有说话方式约束；不注入身份画像和最近聊天；接通后不开口 | `voice_live.py:237-263` | 像客服，不像认识他的人 |
| 11 | 「情绪」靠关键词猜，驱动圆球变紫/变珊瑚色 | `voice_live.py:1078`、`LiveVoiceOrb.swift:24-61` | 颜色乱跳，廉价 |
| 12 | 打断波纹只要触发过一次就永远循环 | `LiveVoiceOrb.swift:115` | 视觉 bug |
| 13 | 字幕 `lineLimit(4)` 截尾 | `LiveVoiceView.swift:221` | 最新说的话被省略号吃掉 |
| 14 | 死代码：`LegacyUpstreamAdapterWrapper`、`_connect_vertex_live`、`detect_emotion_state` | `voice_live.py:979-1095` | 维护负担 |

官方文档核实（2026-11-10）：Vertex 已有 `gemini-3.8-live`（GA、推荐）；连接寿命约 10 分钟、纯音频会话无压缩上限 15 分钟；`sessionResumption` 句柄 2 小时有效；`contextWindowCompression.slidingWindow` 可无限延长；实时输入字段已是 `audio`（代码仍用 `mediaChunks`）。

## 二、改造清单

### A. iOS 音频链路（`LiveVoiceSession.swift`）
1. 开硬件回声消除，删掉静音门控，全程上行真实人声。
2. 上行帧 100ms → 40ms。
3. 本地只做「软压低」：Com 说话时检测到人声，立刻把播放音量压到 0.3，等服务端 `interrupted` 再清队列；600ms 没等到就恢复。
4. 抖动缓冲：首块 60ms，稳态上限 120ms。
5. 圆球音量改为在混音器输出端实时取。
6. 说话态保持 350ms 再回落。
7. 断线自动重连 3 次（0.5/1/2s），带会话号续上下文，音频引擎不拆；新增 `.reconnecting` 状态。
8. 新增逐轮字幕历史 `lines`、扬声器/听筒切换。

### B. 后端（`backend/voice_live.py`）
1. 模型顺序：`gemini-3.8-live` → `gemini-live-2.5-flash-native-audio` → `gemini-live-2.5-flash`，双账号各一轮；不支持的字段按目标降级重试。
2. 开 affective dialog / proactive audio（模型支持时）；静默判停 650ms；上行字段改 `audio`。
3. sessionResumption + 滑窗压缩；收到 `goAway` 在后端静默换连接，客户端无感；客户端重连凭会话号续接。
4. 人设重写：说话方式硬约束（短句、口语、先结论、可以反问、查东西前先应一声、不用每句都叫名字）；注入核心身份摘要 + 主聊天最近几轮 + 今日日程。
5. 接通后 Com 先开口，一句话，按时间段和上下文变化。
6. 删死代码。

### C. 界面（`LiveVoiceView.swift`、`LiveVoiceOrb.swift`）
1. 圆球只用品牌青柠一个色系，靠形变和明度表达「在听 / 在想 / 在说 / 静音 / 断线」，不再按情绪换色。
2. 字幕改成向上滚动的对话流，最新一句最亮，旧句渐隐；不截尾。
3. 顶栏只留时长和收起；音色、字幕开关收进一个菜单。
4. 底部三键：静音、扬声器、挂断（电话图标）。状态提示缩成圆球下方一行短词。
5. 打断波纹改为一次性。

## 三、验收
- 后端：`backend/tests/test_voice_live.py`、`test_e2e_voice_live.py` 通过；mini 上真连 Vertex 探针拿到 `setupComplete` 和首包音频。
- iOS：Duo 模拟器构建通过，`--ui-testing --ui-live-voice` 截图；真机通话需 Eddie 实际说话验收（打断、回声、10 分钟续接）。

## 四、落地结果（2026-11-10 晚）
- A、B、C 三块均已实现。后端测试 41 项通过，已在 mini 重启上线；真实通道验证：接通走 `gemini-3.8-live`，Com 先开口，`resume=1` 续接成功且不重复开场。
- 实测修正：`gemini-3.8-live` 只在 us-central1 可用（global 报 not found），且不支持 affective dialog；文本回合首包约 0.8–0.9s，2.5 native-audio 约 1.1–1.3s。
- iOS 在 Duo 模拟器编译通过并截图；真机当时未连接，未装机，通话实测待做。

## 五、未做
- Web 端 `web/js/chat.js` 的通话浮层未同步改。
- 自定义音色克隆、Live Avatar。
