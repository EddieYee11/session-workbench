# Com! iOS 动效规范

所有运动表达真实状态；重连、历史加载和旧完成消息不播放完成触感。真源参数在 `DesignSystem.ComMotion`（2026-10-29），尚未经 Instruments 校准。

## Motion tokens

| Token | 用途 | 参数 |
|---|---|---|
| `ComMotion.snap` | Dock 选中撑开、chip 切换 | spring response 0.46 / damping 0.66 |
| `ComMotion.settle` | 顶栏、舞台收合、列表折叠 | spring response 0.38 / damping 0.86 |
| `ComMotion.pop` | 气泡进场、依据袋、交给 Com 打开航程 | spring response 0.42 / damping 0.62 |
| `ComMotion.flight` | 发送气泡飞行 | spring duration 0.38 / bounce 0.18 |
| `ComMotion.rise` | Today 等页面区块错峰上浮 | spring response 0.55 / damping 0.9 |
| `ComMotion.lift` | 健康页轻量区块 | spring response 0.5 / damping 0.86 |
| `ComMotion.crossfade` | 工作「对话↔终端」等模式切换 | spring response 0.4 / damping 0.88 |
| `ComMotion.press` | 轻按压回弹（SoftPress / MessagePress） | spring duration 0.18 / bounce 0.14 |
| `ComMotion.breath` | 注意力条柔和呼吸（仅透明度） | easeInOut 1.6s 往复 |
| `EnterRise` / `.enterRise` | 共用进场 modifier（y/blur/delay 可调） | 默认 y+26、blur 10 |
| `SoftPressStyle` | 卡片/chip 轻按压 | Reduce Motion → 仅透明度 |
| `AttentionBreath` | 「等你」条 / 舞台状态呼吸，不位移 | Reduce Motion → 静止 |
| `AmbientMotionPolicy` | 角色 Timeline：前台 + 非低电量 + 未开减少动态效果 | 后台/省电静止 |
| NextCard land | 建议卡进场 scale 0.97→1 + opacity（`ComMotion.pop`） | Reduce Motion → 立即到位 |
| DockPress | Dock 胶囊按压缩放 | 同 SoftPress；与 `ComMotion.press` 对齐 |
| Dock selected | 选中描边 + 轻微 1.02 scale（`snap`）；角标有件时 breath | Reduce Motion → 无 scale/breath |
| SuggestionChips | SoftPress + `ComMotion.pop` 错峰；点选 crossfade | Reduce Motion → 淡入 |
| Health TilePress | 拼图按压对齐 `ComMotion.press` | Reduce Motion → 仅透明度 |
| PendingNote / Waiting | 进场 pop；划走/「已经回了」用 `settle` 离场 | Reduce Motion → 短淡入 |
| Stage open/close | `UIAccessibility.isReduceMotionEnabled` → `ComMotion.reduced` | 无长弹簧 |
| Settings / Search | 分组与结果 `EnterRise` 错峰 | Reduce Motion → 短淡入 |
| Voyage / CaseDetail | Banner lift；详情分块 rise/pop；进度 settle | Reduce Motion 安全 |
| VoiceSessionPanel | phase crossfade；高度 settle | Reduce Motion → 短切 |
| Pairing / PairCode | Companion + 表单 EnterRise；码区 pop | Reduce Motion → 短淡入 |
| DeviceReceipts | 页眉 rise；空态 pop；列表错峰 | Reduce Motion → 短淡入 |
| HotBoard | 空态/列表 EnterRise；行 SoftPress | Reduce Motion → 短淡入 |
| WorkApprovalCard | 进场 pop；选项 SoftPress | Reduce Motion → 短淡入 |
| WorkSidebar | 「更早」加载 settle | Reduce Motion → easeOut |
| ProjectBoard | 列表 settle；卡片 SoftPress | Reduce Motion → 短淡入 |
| Connections | 页眉 rise；列表 pop | Reduce Motion → 短淡入 |
| TalkBubble | 开 pop / 收 settle（绕尾尖） | Reduce Motion → 短切 |
| SuggestionChips | 标签「可以这样回」；进场 lift | 同 SoftPress 行 |
| Health action stack | 翻面 lift；回弹 pop；甩出后 settle | Reduce Motion → 短切 |
| TaskHub 列表 | 决策段 settle | Reduce Motion → 短淡入 |
| BodyCard / SleepBar | TileRise → lift；按压 → press | Reduce Motion → 短切 |

过夜增量（2026-10-29）：高频面动效已较饱和；后续优先收敛散落 `spring(response:…)` 到上表 token，避免无意义重复 SoftPress。Next 纸片出袋 choreography **保留原参数**，不硬套 token。

### 局部 Motion 枚举（故意不合并）

| 枚举 | 位置 | 说明 |
|---|---|---|
| `ReplyMotion` | `ReplyText.swift` | 主聊天回复进场：timingCurve rise/sweep；`pop` 参数与 `ComMotion.pop` 对齐；带 `played` 防重播 |
| `MemoryMotion` | `MemoryView.swift` | 记忆夹/图章 cascade 与帧率向 timingCurve；勿改成通用 rise，以免冲掉既定节拍 |
| Next 纸片 spring | `NextView.swift` | 出袋/入袋手感专用参数；Reduce Motion 已短切 |

`ComMotion.reduced`：Reduce Motion → `easeOut(0.2)`；否则原 preferred。

参考（模式非像素）：[bestsaaswebdesigns curated](https://bestsaaswebdesigns.com/curated-designs) 的 Animation 共性——错峰揭示、soft press、交叉淡入、注意力微动；落地遵守 Lime Glass，Liquid Glass 只用于浮层。

| 交互 | 运动与时序 | 状态来源 | 降级 |
|---|---|---|---|
| 角色呼吸／眨眼 | TimelineView 12–30fps（转身 60）；呼吸约 3.5s，眨眼间隔 5.3s | 前台可见角色 | AmbientMotionPolicy；减少动态效果静止 |
| 触摸角色 | 手指偏移映射注视、压扁与轻旋转；释放 spring response .45、damping .63 | 当前触摸 | 减少动态效果 120ms 回位 |
| 角色思考 | 仅 queued/sending/running；unknown 明确待核实、不持续假思考 | 主对话 runs | 状态文字始终可读 |
| 录音胶囊展开 | spring response .4、damping .86；内容与容器同步改变 | 麦克风实际录制状态 | 120ms 简短切换 |
| 声音到光晕 | 50ms 读取 AVAudioRecorder 电平；attack .60/release .15；离线 voice-glow 0.3.0 | 当前麦克风电平 | 降低透明度去模糊；减少动态效果停止流动 |
| 底栏选中 | `ComMotion.snap`；聊天键盘弹出时收起底栏 | 当前页面和键盘通知 | 减少动态效果直接切换 |
| 数字和筛选 | numericText；筛选 smooth .2s | 真实数据更新 | 没有伪计数 |
| 发送／交给 Com／选择 | soft impact／成功 notification／selection | 已受理、新到的完成更新与主动选择 | 不对历史快照触发 success |
| 等你列表消除 | `ComMotion.settle` | 用户划掉/已回 | — |

阅读聊天时角色收拢，正文保持静止；滚动离开底部后不强制追随新消息。返回最新消息是主动按钮。待发送失败／未知显示原因，回执核对不触发第二次业务操作。

待真机：实际说话光晕、键盘遮挡、录音到文字的连续性、大字体、减少动态效果、降低透明度、VoiceOver；通过后用 Instruments 的 Animation Hitches / Time Profiler / Allocations / Energy Log 检查长对话滚动与录音。尚不能声称 ProMotion、能耗与内存已经达标。

## 主聊天 · 2026-10-07（仍有效）

- 键盘：系统安全区避让、消息底部锚定与交互式收起同步；阅读历史时保持位置，不对每次按键附加动效。
- 发送：`ComMotion.flight`；50ms 布局交接后取得最终落点；850ms 兜底确保气泡解除隐藏。动画不延迟真实提交。
- 触按：发送与返回最新按钮 180ms 轻压缩回弹；减少动态效果保留透明度反馈。
- 交接：本地、已受理和服务端消息使用请求编号保持同一行；同文字不同请求不合并。
- 新回复：查看历史时显示未读提示，不抢走阅读位置；主动返回使用 280ms 小弹簧。
