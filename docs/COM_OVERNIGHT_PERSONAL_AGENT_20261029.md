# Com 过夜 Personal Agent 冲刺 · 2026-10-29

**分支**：`com-personal-agent-overnight-20261029`  
**窗口**：约 01:00 → 08:00 Asia/Shanghai（起床验收）  
**监督循环**：本地 `AGENT_LOOP_TICK_com_overnight`，约每 40 分钟唤醒继续推进  
**对标**：Muse（对话重心 + 确定性审批）· Grok Bot（伙伴存在感/想打开）· Hark（一卡一动作 + 主动找你）

---

## 产品判断（本夜只做「更想用」）

起床后应感到三件事：

1. **有人在** — 打开 App，伙伴状态、空状态、问候都像活的个人 agent，不是工具壳。
2. **有事找我** — 「等你 / 下一步 / 今天」能一眼看到该拍板的事；一卡一主动作。
3. **说完就走** — Com 对话仍是主入口；短路径（记账、下一步交给 Com）摩擦更低。

本夜**不做**：五 Tab→三 Tab 大改、新连接器（Gmail）、云端 VM、品牌重画、**覆盖现有工作 Tab 主画面**。  
本夜**可做**：iOS 体验与主动性表面、工作 Tab「对话 ↔ 远程终端」可切换面、后端快路径与送达边角、构建装机、进度日志。

承接本批已落地：记账词表、统一 Waiting、Motion tokens、下一步一卡一动作（见 `COM_IOS_UPGRADE_BATCH_20261029.md`）。

### 工作 Tab · Moshi × Heeler 远程面（Eddie 01:01–01:03 对齐）

**真源对齐（已核对 session）**
| 来源 | 是什么 | Session / 路径 |
|---|---|---|
| **Moshi** | 商业远程 agent 客户端；白天用 [REA](https://github.com/morluto/rea) 拆包 | Pi `2026-10-27…01a17c5b` → `projects/moshi-ios` |
| **Heeler** | GitHub 开源 herdr 原生 iOS 客户端（Claude 10-26 选型首选） | Claude `fca7c7bd-db05-4eda-b016-1c4c864af945`；记忆 `project_herdr_mobile_client_selection.md`；仓库 [ZingerLittleBee/Heeler](https://github.com/ZingerLittleBee/Heeler) |
| 备选调研 | Ovis（PWA）、Collie 等 | 同 session；**不**进 Com 主路径 |
| REA | 逆向工具，不是 UI 依赖 | 只产出 Moshi 协议判断 |

**取长补短（放进 Com 的分工）**
- **Heeler 长处进「终端」面**：Swift 原生、SSH → `herdr.sock` 零改服务端、会话树/纯终端/Composer、Live Activity、已在 Duo 试装、公网 `ssh.eddiegao.fun:22022` 已通。Com 学它的**连接与终端交互**，不整仓 fork、不沿用商标与 push relay。
- **Moshi 长处叠在结构化层**：moshi-hook gateway 的 transcript / 审批 / 计划 / diff（`MoshiGateway`）；Com 主对话与「等你」已有审批语义时可对接，不必一夜做满 Chat View。
- **自研桥**：`projects/moshi-ios/app` 的 `HerdrKit`（Citadel SSH + herdr protocol 22）作为 Com 可链的协议层，避免把 Heeler 闭源/商标包直接嵌进 `work.eddie.com`。

**融合原则（硬约束）**
1. **默认仍是现在的工作 Tab**（派活 / Pi·Claude·Codex），一行不拆。
2. 同 Tab 内切换：`对话` | `终端`（`WorkSurface.sessions` / `.remote`）；切走不丢会话状态。
3. 本夜不做：整仓合并 Heeler、替换 Work 主 UI、完整 PTY 通宵硬扛。
4. 凭据 Keychain；装机目标仍 iPhone Duo。

**本夜远程面最小交付**
- 工作顶栏 `对话` / `终端` 切换壳。
- `终端` 面：mini / 公网入口说明 + Heeler/Moshi 能力卡片 + 连接状态占位；能链 HerdrKit 则 ping，否则 stub + 起床后续。
- 文档写清：完整 SSH/PTY + moshi-hook 审批回流 = 白天续。

---

## 阶段表

| Tick | 时段（约） | 代号 | 交付 |
|------|------------|------|------|
| 0 | 01:00 | Bootstrap | 分支、本计划、Goal、循环启动 |
| 1 | 01:00–01:40 | Presence | Grok 式伙伴存在感：空聊问候、状态文案、打开欲望 |
| 1b | 穿插 | RemoteShell | 工作 Tab `对话↔终端` 切换壳（不覆盖现画面）+ Moshi 融合说明 |
| 2 | 01:40–02:20 | Gravity | Muse 式对话重心：聊天空态/建议芯片/「有事找你」入口更顺 |
| 3 | 02:20–03:00 | Action | Hark 式行动面：Waiting / Next / Today 统一语气与一卡一动作收尾 |
| 4 | 03:00–03:40 | Brief | 今天页晨间驾驶舱：更像 agent brief，少仪表盘堆砌 |
| 5 | 03:40–04:20 | Speed | 快路径与摩擦：记账/建议/交给 Com 的可感知反馈 |
| 6 | 04:20–05:00 | Polish | 动效与角色 ambient（Reduce Motion 安全）、文案人格 |
| 7 | 05:00–05:40 | Build | `xcodegen` + 真机构建；能装则装 |
| 8 | 05:40–06:20 | Verify | 模拟器/真机冒烟；修编译与明显回归 |
| 9 | 06:20–07:20 | Harden | 补漏、文档、进度定稿；禁止大范围重写 |
| 10 | 07:20–08:00 | Handoff | 起床报告：改了什么、怎么打开验、未完成清单 |

超时策略：到点停在当前阶段，写 handoff，不硬塞半成品架构。

---

## 每轮监督 checklist

1. 读本文件「进度日志」最后一条与 Goal 状态。  
2. 只推进**当前未完成的最小下一阶段**；不重开已完成阶段。  
3. 改完：尽量编译或跑相关断言；更新进度日志（时间、做了什么、验证、下一 tick）。  
4. 若设备不可用：继续纯代码 + 写清「起床后一键装机命令」。  
5. 截止前 40 分钟强制进入 Harden/Handoff，不再开新功能面。

---

## 验收（起床）

- [x] 分支上有可构建的 iOS 增量（多次 `BUILD SUCCEEDED` + Duo 装机）  
- [ ] Com 空态/伙伴让人想开口（Presence）— **代码在；需解锁点验**  
- [ ] 等你 / 下一步仍一卡一主动作，语气像 agent 不是后台工单 — **代码在；需点验**  
- [ ] 今天页更像 brief — **代码在；需点验**  
- [x] `docs/COM_OVERNIGHT_HANDOFF_20261029.md` 写好如何验  
- [x] 本批未改五 Tab / 未覆盖工作对话主画面；Waiting / Motion / 记账快路径意图保留

---

## 进度日志

### 2026-10-29 00:58 · Tick 0 Bootstrap
- 从 `com-ios-upgrade-batch-20261029` 开出本分支（含当日未提交升级 WIP）。
- 本计划落盘；Goal 已建；监督循环即将每 40 分钟唤醒。
- 下一 tick：Presence（伙伴存在感 / 空聊欲望）。

### 2026-10-29 01:01 · 纠错 + Remote 并入
- 用户纠错：不是 RIA/Mushroom，是 **REA + Moshi**。
- 融合策略写入上方「工作 Tab · Moshi / 远程面」；现有工作画面保留，只加可切换终端面。
- Presence 空聊组件已加（`ChatPresence.swift`）；下一动作：RemoteShell 切换壳 + 继续 Presence/Gravity。

### 2026-10-29 01:03 · 找到第二源 Heeler + 落地切换壳
- GitHub 项目锁定：**[ZingerLittleBee/Heeler](https://github.com/ZingerLittleBee/Heeler)**（Claude session `fca7c7bd…`，10-26；记忆 `project_herdr_mobile_client_selection.md`）。同会话末尾已问「融进 Com 可行性」。
- 取长补短：Heeler → 连接/终端；Moshi → transcript/审批；HerdrKit → 自研桥。
- 代码：`WorkRemote.swift`（`对话|终端` picker + 终端面）；`WorkHome.swift` 默认对话面不改，终端面隐藏 WorkComposer。

### 2026-10-29 01:04 · 构建装机
- Tick1（仅 Presence）与 Tick1b（含 WorkRemote）均 **BUILD SUCCEEDED**；已 `devicectl install` 到 Duo（`work.eddie.com`）。

### 2026-10-29 01:07 · Curated motion + Gravity/Action/Brief
- 参考 [bestsaaswebdesigns/curated-designs](https://bestsaaswebdesigns.com/curated-designs)：提炼错峰揭示 / soft press / crossfade / 注意力呼吸（不抄网页仪表盘）。
- `ComMotion` 增 `crossfade` / `press` / `breath`；`SoftPressStyle`、`AttentionBreath`、`.enterRise`。
- Gravity：`ChatAttentionStrip`（对话进行中仍可点进等你/下一步）。
- Action：等你 sheet 进场 + 人话空态 + SoftPress 行。
- Brief：今天页时段 agent 问候句。
- 工作：表面切换用 crossfade + matchedGeometry 胶囊。
- Tick2 构建 **BUILD SUCCEEDED** 并已装机 Duo。

### 2026-10-29 01:10 · Speed → Polish
- Speed：主聊/工作发送按下即 selection 触感；Dock 切换触感；EmptyState 统一 EnterRise；主按钮/DockPress 走 `ComMotion.press`。
- Polish：主动消息折叠 SoftPress + settle；终端占位光标闪烁（Reduce Motion 静止）；顶栏 stripCaption 交叉淡入。
- 仍不改五 Tab、不覆盖工作对话主画面。
- Tick5–6 构建 **BUILD SUCCEEDED**，已装机 Duo（`install-tick56`）。下一阶段：Verify 冒烟 → 临近 07:20 再 Harden/Handoff。

### 2026-10-29 01:12 · Verify + 早 Harden
- `build-verify` **BUILD SUCCEEDED**；源码库存：Presence / AttentionStrip / WorkSurface / SoftPress / breath / briefLine / Waiting EnterRise 均在位。
- 已再装 Duo（设备 connected / booted；未解锁故未强 launch）。
- 早写交接：`docs/COM_OVERNIGHT_HANDOFF_20261029.md`（起床 5 分钟验收 + 重装命令 + 未做清单）。
- 现约 01:12，远早于 07:20：Handoff 已可交，但按用户要求**继续过夜冲刺**（更深克制 polish），07:20 后再只 Harden。

### 2026-10-29 01:14 · Deep polish（不推翻 Handoff）
- **终端面诚实探测**：去掉假「connected」；按钮改为「探测 Com 链路」→ 配对检查 + `GET /health`；成功态文案 `Com 通 · herdr 未接`（warning tone，不用 success 触感）；重置按钮；主机 SoftPress。
- **下一步卡**：进场 scale+opacity（`ComMotion.pop`）；「更多」SoftPress。
- **舞台 / Presence**：有等你时 stripCaption 警告色 + AttentionBreath；空态 stripCaption/statusLine crossfade；注意力条 numericText。
- **CountBadge**：numericText + snap。
- 构建 `build-deep-polish` **BUILD SUCCEEDED**；装机 `install-deep-polish`（Locked，未 launch）。仍不挂 HerdrKit SPM、不开五 Tab、不盖工作对话。

### 2026-10-29 01:15 · Deep polish-2 · Today 边角
- 今天页 brief 有等你时字重感加强；等你入口 SoftPress + AttentionBreath + 角标 numericText；任务档案 SoftPress。
- `build-deep-polish-2` **BUILD SUCCEEDED**；已再装 Duo。Handoff 已同步验收步骤。

### 2026-10-29 01:16 · Deep polish-3 · 探测文案
- `/health` 成功时附带 `version` / `main_operation_mode`（仍明确 herdr 未接线）。
- `build-deep-polish-3` **BUILD SUCCEEDED**；已再装 Duo。下一监督唤醒：继续克制边角 / 回归构建；**07:20 后只 Harden/定稿 Handoff**。

### 2026-10-29 01:18 · Deep polish-4 · curated 统一
- **SuggestionChips**：SoftPress + `ComMotion.pop` 错峰；点选 selection 触感；Reduce Motion 无旋转。
- **健康**：为什么/维度 SoftPress；TilePress 对齐 `ComMotion.press`；进场 `withAnimation(lift)`；跨度胶囊 SoftPress。
- **下一步空态**：人话 EmptyState +「跟我说一声」→ Com；有等你时举手芯片。
- **Dock 选中态**：色描边 + 轻微 1.02 scale（snap）；角标有件时 AttentionBreath。
- **HerdrKit**：评估本地 SPM——依赖 Citadel/NIO，本夜**不硬挂**；终端文案写明；仍只诚实 `/health`。
- `build-deep-polish-4` **BUILD SUCCEEDED**；装机 `install-deep-polish-4`。

### 2026-10-29 01:19 · Deep polish-5 · 警告 + 聊天边角
- 去掉 `QLPreviewControllerDataSource` 上无效 `@preconcurrency` 警告。
- 聊天：回到最新 SoftPress；中断按钮 SoftPress + selection；麦克风 SoftPress。
- `build-deep-polish-5` **BUILD SUCCEEDED**（日志无 warning）；已装 Duo。

### 2026-10-29 01:19 · Deep polish-6 · 工作筛选 SoftPress
- 工作侧栏主机条 / Agent 芯片 SoftPress（不改派活主画面结构）。
- `build-deep-polish-6` **BUILD SUCCEEDED**；已装 Duo。Handoff 点验已含芯片/健康/Dock/空态/HerdrKit 未接线。下一唤醒继续克制边角；**07:20 后只 Harden**。

### 2026-10-29 01:22 · Deep polish-7 · Waiting / 记账 / 舞台文案
- **Waiting / PendingNote**：进场 pop；划走回弹与微信「已经回了」统一 `ComMotion.settle` 离场；Reduce Motion 短淡入。
- **记账快路径 UI**：助手「已记 …」回执加「已记账」标签 + 左侧成功条；消息 3 秒内到则 success 触感。
- **舞台 / Live Activity 文案**：空闲按时段人格问候；等你/办完/卡住措辞更像伙伴（Live Activity 读同一 `stripCaption`）。
- **Reduce Motion**：舞台开合走 `UIAccessibility.isReduceMotionEnabled` + `ComMotion.reduced`。
- **文档**：README 对齐终端探测 / Presence / 记账回执；`COM_APP_CURRENT_STATE` 顶注指向过夜 Handoff（不重写整篇旧 IA）。
- `build-deep-polish-7` **BUILD SUCCEEDED**；装机 `install-deep-polish-7`。

### 2026-10-29 01:22 · Deep polish-8 · 警告清理
- 修 LedgerNote `Text` + 拼接弃用警告；AgentAvatar keyframe 闭包不再捕获 `@Environment reduce`；`usage ?? .null` 无效合并。
- `build-deep-polish-8` **BUILD SUCCEEDED**（本轮相关 warning 清掉）；已装 Duo。下一唤醒继续新边角；**07:20 后只 Harden**。

### 2026-10-29 01:24 · Deep polish-9 · 记忆/设置/航程/语音 + 快路径
- **设置 / 搜索**：进场 EnterRise；设置顶栏人格说明；搜索空态与无结果文案更像伙伴。
- **记忆空态**：待确认 / 已学到 / 文件夹 / 搜索无结果 人话重写。
- **航程**：VoyageBanner EnterRise + SoftPress（单点入口）；进度条 `ComMotion.settle`；CaseDetail 分块 EnterRise；动作胶囊 SoftPress。
- **语音面板**：phase / 高度过渡走 `ComMotion.reduced`；计时 numericText；停顿即发 SoftPress。
- **后端**：`bookkeeping_intent` 对「记一下」+ 裸数字金额认可（`记一下咖啡18` / `帮我记一下咖啡18`）；无记账动词的「美团外卖32」仍不直写。
- `build-deep-polish-9` **BUILD SUCCEEDED**；装机 `install-deep-polish-9`。

### 2026-10-29 01:30 · Deep polish-10 · mini 部署 + Finance/动态/分享
- **mini 部署**：`ssh mini` OK；Syncthing 已同步 `policy.py`（01:23）；`launchctl kickstart -k gui/$(id -u)/work.eddie.sessions`；`http://127.0.0.1:8650/health` 与公网 `/sessions/health` → `mini-sessions 2.0.0 full-access`；mini 源码树 Python 断言：`记一下咖啡18` / `帮我记一下咖啡18` parse OK，`美团外卖32` 仍 None。本地 `/sessions/*` 需配对令牌，核验用 `/health` + in-process parse。
- **Finance**：支出卡 / 分类行 EnterRise + SoftPress；金额 `numericText`；进度条 `ComMotion.settle`；空态提示「记一下咖啡18」。
- **动态**：空态/页眉 EnterRise；页眉文案「已经替你动过手的事…」；筛选 / 展开 / 未读点改走 `ComMotion`（去掉散落 spring）。
- **分享收件箱**：进场 EnterRise；丢弃 `ComMotion.settle`；空态更像伙伴。
- **Agency**：`AgencyMotion` 对齐 `ComMotion.settle` + BlurShift 进场；目标空态文案已人话。
- `build-deep-polish-10b` **BUILD SUCCEEDED**；装机 `install-deep-polish-10b`（Locked，未 launch）。证据：`ios/verification/overnight-20261029/{build,install}-deep-polish-10b.log`、`mini-deploy-polish-10.txt`。下一唤醒继续未覆盖边角；**07:20 后只 Harden**。

### 2026-10-29 01:31 · Deep polish-11 · Next/Finance 边角
- **Next**：进度步骤与详情 `Rise` 对齐 `ComMotion.settle` / `rise`（纸片出袋 choreography 保留原 spring 参数）。
- **Finance**：月份切页 SoftPress + 月份 `numericText`/`crossfade`。
- `build-deep-polish-11` **BUILD SUCCEEDED**；装机 `install-deep-polish-11`。下一唤醒继续未覆盖边角；**07:20 后只 Harden**。

### 2026-10-29 01:34 · Deep polish-12 · 配对/回执/HotBoard/审批/侧栏 + 测试
- **配对页 / 扫码配对**：EnterRise 进场；文案更像伙伴；过期提示与「先连上」错误人话。
- **设备回执**：空态人格 + 页眉说明；列表 EnterRise。
- **HotBoard**：空态/stale 文案；卡片进场；行 SoftPress。
- **工作侧栏**：空态人话；「更早」加载走 `ComMotion.settle`。
- **审批卡**：「等你拍板」+ 说明；选项 SoftPress；EnterRise。
- **InlineNotice**：常见网络/超时/凭据失效收成伙伴口吻，其余原文保留。
- **测试**：`test_fast_bookkeeping` 补「记下星巴克25 / 帮我记一下打车36 / 记一下奶茶22」与无动词负例；本机 parse 断言 OK。
- `build-deep-polish-12` **BUILD SUCCEEDED**；装机 `install-deep-polish-12`。下一唤醒继续未覆盖边角；**07:20 后只 Harden**。

### 2026-10-29 01:34 · Deep polish-13 · 项目看板 / 发送记录
- **项目看板**：空态人话；卡片 SoftPress + `ComMotion.settle`；详情条目 SoftPress。
- **设置 · 发送记录**：空态说明回执用途。
- `build-deep-polish-13` **BUILD SUCCEEDED**；装机 `install-deep-polish-13`。下一唤醒继续未覆盖边角；**07:20 后只 Harden**。

### 2026-10-29 01:35 · Deep polish-14 · 数据连接 / ComMotion 边角
- **数据连接**：页眉人话 + EnterRise；列表副文案；应用锁 / Google 授权说明人话。
- **动效对齐**：舞台开合 `ComMotion.rise/settle`；切到工作 Tab `snap`；Finance ring `settle`；工作输入路由提示 / 停止钮 `settle/pop`（未改对话气泡主路径）。
- `build-deep-polish-14` **BUILD SUCCEEDED**；装机 `install-deep-polish-14`。下一唤醒继续未覆盖边角；**07:20 后只 Harden**。

### 2026-10-29 01:36 · Deep polish-15 · 健康 / Chrome
- **健康**：Garmin 空态人话；Hero 评估缺省文案；headline / 维度动效用 `ComMotion`。
- **Chrome**：顶栏 motion 对齐 `ComMotion.settle`。
- `build-deep-polish-15` **BUILD SUCCEEDED**；装机 `install-deep-polish-15`。下一唤醒继续未覆盖边角（建议：SuggestionChips / Character 边角 / Health 翻卡散落 spring）；**07:20 后只 Harden**。

### 2026-10-29 01:37 · Deep polish-16 · 建议卡 / TalkBubble / 健康卡堆
- **SuggestionChips**：标签「可以这样回」；进场 `ComMotion.lift`。
- **TalkBubble**：开合对齐 `ComMotion.pop/settle`。
- **健康建议卡堆**：翻面 / 回弹 / 甩出后归位走 `ComMotion`。
- `build-deep-polish-16` **BUILD SUCCEEDED**；装机 `install-deep-polish-16`。下一唤醒继续未覆盖边角；**07:20 后只 Harden**。

### 2026-10-29 01:39 · Deep polish-17 · 文档对齐 + TaskHub/Body + 干净构建
- **稳定性**：`build-deep-polish-17` 扫描 **0 warning**（相对本轮 Swift 源）。
- **MOTION.md**：补过夜表面 token 表（配对/回执/HotBoard/审批/侧栏/看板/连接/TalkBubble/建议卡/健康卡堆/TaskHub/Body）；注明高频饱和、勿重复 SoftPress、Next 纸片保留原参数。
- **DESIGN.md**：InlineNotice companion 原则；动效真源与过夜 Handoff 指针。
- **TaskHub**：空态人话；筛选 `crossfade`；决策列表 `settle`。
- **BodyViews**：空态/手机健康文案；TileRise→`lift`；SleepBar→`rise`；CardPress→`press`；详情 grown→`lift`。
- **Handoff**：点验清单压到约 6 步。
- 装机 `install-deep-polish-17`。下一唤醒：若仍早于 07:20，优先 Memory/Reply 本地 Motion 文档标注或小回归；**07:20 后只 Harden**。

### 2026-10-29 01:39 · Deep polish-18 · 局部 Motion 文档 + PaneBar
- **MOTION.md**：标明 `ReplyMotion` / `MemoryMotion` / Next 纸片为故意不合并的局部枚举。
- **ReplyMotion.pop** → 直接引用 `ComMotion.pop`（同参，去重复）。
- **PaneBar**：标题切换 `ComMotion.crossfade`。
- `build-deep-polish-18` **BUILD SUCCEEDED**（0 warning）；装机 `install-deep-polish-18`。下一唤醒：小回归或 Harden 准备；**07:20 后只 Harden**。

### 2026-10-29 01:40 · 监督 tick #1 已响应
- 监督循环首 tick 到达；进度与 Handoff 已读；mini `/health` + `记一下咖啡18` parse 抽检 **OK**；WorkRemote 仍诚实标明 herdr 未接、未挂 HerdrKit；`project.yml` 无 HerdrKit 依赖。
- 动效/文档已较饱和：本 tick 做稳定性抽检 + Handoff 微调 + 终端说明文案小修（不堆 SoftPress）。

### 2026-10-29 01:41 · Deep polish-19 · tick1 稳定性 + 终端文案
- **WorkRemote**：底栏说明改伙伴口吻（仍明确「herdr 未接 / 白天接线」）；进场 `ComMotion.lift`。
- **抽检证据**：`ios/verification/overnight-20261029/stability-tick1.txt`。
- `build-deep-polish-19` **BUILD SUCCEEDED**（0 warning）；装机 `install-deep-polish-19`。下一监督 tick：继续稳定性/小修；**07:20 后只 Harden**。

### 2026-10-29 01:42 · Deep polish-20 · 测试补强 + Presence 小修 + Handoff 骨架
- **测试**：`test_bare_number_bookkeeping_edges_overnight`（空格、句末动词、中文十八、否定/查询负例）；本机 parse 断言全过。
- **ChatPresence**：问候改用 `Asia/Shanghai` 时区；空态「记一笔开销」starter → `记一下咖啡18`（起床可一点直验快路径）。
- **Handoff**：写成起床照做表格式骨架（验什么 / 期望 / 未完成 / 证据）。
- `build-deep-polish-20` **BUILD SUCCEEDED**（0 warning）；装机 `install-deep-polish-20`。下一 tick：稳定性或 Harden 准备；**07:20 后只 Harden**。

### 2026-10-29 01:43 · Deep polish-21 · 工作过程/主聊 spring 收敛 + 全量抽检
- **实质小修**（未改对话结构）：`WorkChat` / `WorkProcess` 步骤开合与送达态 → `ComMotion.settle`；主聊 stage/voice/主动消息展开 → `settle`/`crossfade`；空会话提示人话微调。
- **抽检**：公网 `/sessions/health` OK（`stability-polish-21.txt`）；构建 **0 warning**；已装 Duo。
- `build/install-deep-polish-21`。
- **下一 tick（写清楚）**：优先（1）监督循环到点再健康/parse 抽检；（2）若有编译 warning 或真机路径回归再修；（3）无新问题则只维护 Handoff，**勿再铺 SoftPress**；**07:20 后只 Harden/定稿**。

### 2026-10-29 01:44 · 扎实抽检 audit-22（无新 bug，未改代码/未重装）
证据：`ios/verification/overnight-20261029/audit-polish-22.txt` + `build-audit-polish-22.log`
- **构建**：`BUILD SUCCEEDED`，**warning_count=0**
- **mini**：公网 + `127.0.0.1:8650/health` → `mini-sessions 2.0.0 full-access`
- **记账 parse**（MBP+mini）：`记一下咖啡18` / `帮我记一下咖啡18` / `记下外卖40` OK；`不要记一下咖啡18` / `美团外卖32` None
- **假 herdr**：未回潮；探测文案仍为 **`Com 通 · herdr 未接`** +「不会假装 herdr 已连上」；`project.yml` **无** HerdrKit/Citadel
- **关键符号**：`ChatEmptyPresence` / `WorkSurface` / `WorkRemote` / `ComMotion` / `EnterRise` / `InlineNotice.companion` / `bookkeeping_intent` 均在
- **五 Tab**：`SectionTab` 仍为 Com / 下一步 / 今天 / 健康 / 工作
- **对话|终端**：`@AppStorage("work.surface")` 持久化；切终端只换 `WorkRemoteSurface`，`model.work` 会话态保留（不销毁 AppModel）
- **Reduce Motion**：`ComMotion.reduced` → `easeOut(0.2)`；Work 切面 / EnterRise / 多页均有 reduce 分支
- **结论**：无真实回归可修；本 turn **不堆 SoftPress、不重装**。
- **下一 tick**：监督到点可再跑同一套 audit；有回归才修装；否则只 Harden 准备；**07:20 后只 Harden/定稿 Handoff**。

### 2026-10-29 01:47 · Gravity-23 · 对话重心「一件事」+ 伙伴点名 + 诚实终端
缺口：有等你/下一步时聊天侧只报件数芯片，不像 agent 引导行动。
- **Muse**：`ChatAttentionStrip` → 一卡（标题 + 单一 CTA「去拍板/去看」）；等你优先于下一步；`ChatAttentionHint` 抽最要紧标题。
- **Grok**：空态 `statusLine`/starter、顶栏 `stripCaption`、Next 空态等待钮均点名那一件（非装饰动效）。
- **Hark**：Waiting 非空导语「一卡看一件」；语气边角对齐。
- **Remote**：探测后/失败后诚实说明文案按状态切换（仍 **不** 假 herdr、不挂 HerdrKit）。
- **未铺 SoftPress**；五 Tab / 工作对话主画面未动。
- **构建**：`BUILD SUCCEEDED`，0 Com warning；`install-gravity-23` 已装 Duo；launch 因 **Locked** 被拒（过夜预期）。
- 证据：`ios/verification/overnight-20261029/build-gravity-23.log` · `install-gravity-23.log` · `gravity-23-notes.txt`
- **下一 tick**：解锁后点验注意力条点名；可做 Waiting 卡语气/远程细节再实质一小步；**勿再铺 SoftPress**；07:20 后 Harden。

### 2026-10-29 01:49 · Brief-24 · 今天开口 + 下一步语气 + 举牌点名
缺口：今天仍像仪表盘报数；下一步页眉/主动作偏工具；顶栏举牌只写「等你」。
- **Today**：`briefLine` 点名等待/下一步标题；`ScheduleAdvice` →「我说几句」+ 首条「开场」（agent 开口，非纯日程列表）。
- **Next**：`headerLead`「先办这一件：…」；主动作文案「复制草稿，去微信回 / 跟我说怎么办」等。
- **Grok**：`stripSign` 有等待时举牌点名短标题（牌面 ≤5 字）。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-brief-24` 已装 Duo；mini `/health` OK。
- 证据：`build-brief-24.log` · `install-brief-24.log` · `brief-24-notes.txt`
- **下一 tick**：解锁验今天开场 / 下一步页头 / 举牌；可再做 Waiting 卡语气或后端低风险边角；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 01:52 · Presence-25 · 空态人格 + 第一卡 + 交给我办反馈
缺口：空态仍偏功能介绍；等你列表首卡不突出；「交给 Com」点完反馈弱。
- **空态**：等待时问候改催办口吻；空闲按时段活人值班文案；注意力时 starter ≤2 且首枚强调色。
- **等你**：导语点名；首张 `PendingNote(lead:)`「先看这件」高亮；交接成功行内 note。
- **交给我办**：事项 CTA / Next 菜单改口吻；`pendingDiscuss`/`delegateNext` 关 Waiting 并切主对话；Next 卡手写反馈。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-presence-25`；mini health OK。
- 证据：`build-presence-25.log` · `install-presence-25.log` · `presence-25-notes.txt`
- **下一 tick**：解锁验空态/等你首卡/交给我办；可后端快路径边角；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 01:54 · Surfaces-26 · 工作空态 + 健康开口 + 下一步空/有卡对比
缺口：工作新对话/空会话偏冷；健康像仪表盘；下一步空态与有卡同质。
- **工作**：`NewWorkChat` 时段伙伴旁白；空会话活人提示（仍不假 herdr）；侧栏空态口吻。
- **健康**：无 Garmin / 无评估时 agent 通知；有数据先说准备度；`HealthBrief`「身体上我说一句」+ 开场。
- **下一步**：空态「这会儿我没什么要推的」；有卡导语 +「现在 · 先办」；页头空/有对照。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话主画面未盖；HerdrKit 未挂。
- **构建**：`BUILD SUCCEEDED`；`install-surfaces-26`。
- 证据：`build-surfaces-26.log` · `install-surfaces-26.log` · `surfaces-26-notes.txt`
- **下一 tick**：解锁验工作空态 / 健康开口 / 下一步对比；可后端边角；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 01:56 · Voice-27 · 建议芯片 + 过程反馈 + 记忆待确认
缺口：建议卡像工具条；送达/过程状态像系统码；记忆待确认语气偏冷。
- **芯片**：「我想你可以：」；首枚建议强调色（非按钮墙）。
- **主聊过程**：送达「收到了 / 我在办 / 办完了」；`WorkProcess.current/summary` 伙伴自语。
- **记忆**：空态请你点头；待确认纸片旁白 +「对，记住 / 纠正我 / 先不用」；入口「想请你点头」。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-voice-27`（Locked 未 launch）。
- 证据：`build-voice-27.log` · `install-voice-27.log` · `voice-27-notes.txt`
- **下一 tick**：解锁验芯片/过程/记忆；可后端边角；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 01:57 · Guard-28 · 审批实质 + 航程停顿 CTA + 失败/离线
缺口：航程停顿卡对非删除场景硬编码「可以删」；等待航程可能被「进行中」盖住；审批卡不说后果。
- **航程**：`VoyageBanner` **优先置顶 waiting/attention**；停顿卡按问题分流删除/通用 CTA；失败态加「跟我说怎么改」。
- **审批**：标题取 reason/tool/command；说明「批准才动真格」；按钮「批准，去做 / 先别做」。
- **离线/信源**：顶栏掉线文案可行动；信源断卡「去把 X 接上」。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-guard-28`（Locked 未 launch）。
- 证据：`build-guard-28.log` · `install-guard-28.log` · `guard-28-notes.txt`
- **下一 tick**：解锁验航程停顿/审批/离线；可后端边角；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 01:59 · Route-29 · 等待优先级 + 深链拉新 + 推送落地
缺口（行为）：注意力条优先 pending 会盖住航程停顿；`com-eddie://waiting` 可能撞上其它 sheet 且不刷新；case-wait 推送需进统一等你。
- **点名**：`ChatAttentionHint.topWaitingTitle` **先读 Waiting API 排序**（case→wechat→todo），再才 pending。
- **深链/通知**：打开 waiting 时收起 cases/activity/presentedCase，并 `load(/personal/waiting)+refreshFlow`。
- **Agency**：discuss 进主聊时关 Waiting sheet。
- **mini**：kickstart 确认 `case-wait` → `com-eddie://waiting` 已在线。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-route-29`（Locked 未 launch）。
- 证据：`build-route-29.log` · `install-route-29.log` · `route-29-notes.txt`
- **下一 tick**：解锁验推送进等你 / 注意力条点名航程；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:01 · Sync-30 · 应用内打开等你也拉新 + 记账刷账本
缺口（行为）：深链已拉新，但注意力条/今天/下一步/菜单/舞台条等仍 `showWaiting=true` 可能空壳；`refreshFlow` 不含 waiting；「已记」后账本等轮询。
- **`openWaitingInbox`**：统一收起冲突 sheet + `load(/personal/waiting)+refreshFlow`；深链/通知与应用内入口共用。
- **`refreshFlow`**：并入 `/personal/waiting`。
- **流**：新「已记」助手消息立刻 `load(/personal/finance)`。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-sync-30`（Locked 未 launch）。
- 证据：`build-sync-30.log` · `install-sync-30.log` · `sync-30-notes.txt`
- **下一 tick**：解锁验应用内点「去拍板」列表已新；记账后账本即时；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:05 · Ack-31 · 微信「已经回了」持久确认
缺口（行为）：「已经回了」只本地藏卡，刷新又回来，角标不掉。
- **backend**：`waiting_inbox.py` + `POST /personal/waiting/ack`；按 `wechat:…` + 末条 `at` 确认；新消息换 `at` 再进等你。
- **iOS**：`waitingAck` 接按钮；成功后重载 waiting。
- **测试**：`tests/test_waiting_ack.py` 2 passed；mini kickstart，路由在线（无 token→401）。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-ack-31` → `install-ack-31b`（失败时撤本地藏卡；Locked 未 launch）。
- 证据：`build-ack-31b.log` · `install-ack-31b.log` · `test-ack-31.log` · `mini-deploy-ack-31.txt` · `ack-31-notes.txt`
- **下一 tick**：解锁验微信「已经回了」角标下降且重开不回；应用内等你拉新；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:06 · Ledger-32 · 已开账本跟「已记」刷新
缺口：Sync-30 刷 finance 后，已打开的 FinanceDetail 仍卡本地旧 `data`。
- **FinanceDetail**：`onChange(fetchedAt[/personal/finance])` 本月视图直接吃 `datasets` 缓存。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-ledger-32`（Locked 未 launch）。
- 证据：`build-ledger-32.log` · `install-ledger-32.log` · `ledger-32-notes.txt`
- **下一 tick**：解锁验应用内等你拉新 / 微信已回 / 记账后账本（含已开 sheet）；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:07 · Voyage-33 · 航程拍板后刷新等你
缺口：停顿卡点「继续/先别/完成/停止」只刷 case 详情，waiting 角标与注意力条仍挂旧航程。
- **`refreshAfterCaseChange`**：并行 `load(waiting)+load(cases)`；`caseSend/Cancel/Resolve` 后调用。

### 2026-10-29 02:08 · Feed-34 · 打开动态立刻拉新
缺口：菜单/下一步进「动态」可能看到旧航程列表（有停顿提示却点进去空/旧）。
- **`openActivityFeed`**：`showActivity=true` + `loadFeed()`；Chrome / Next / UITest 入口共用。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-feed-34`（含 Voyage-33；Locked 未 launch）。
- 证据：`build-voyage-33.log` · `build-feed-34.log` · `install-feed-34.log` · `voyage-33-notes.txt` · `feed-34-notes.txt`
- **下一 tick**：解锁验航程继续后角标掉 / 动态入口新列表；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:10 · Cover-35 · 交给我办后过期待办离开等你
缺口：过期待办「交给我办」建航程后仍因 due 留在 waiting，角标不掉。
- **backend**：`cases.covers_source`；`waiting_items` 跳过已被活跃航程覆盖的 todo。
- **iOS**：`delegateTodo` / `delegateNext` 后拉 waiting；等你审批卡批准/先别有一句 handoff。
- **测试**：`test_covers_source…` 1 passed；mini kickstart。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-cover-35`（Locked 未 launch）。
- 证据：`build-cover-35.log` · `install-cover-35.log` · `test-cover-35.log` · `mini-deploy-cover-35.txt` · `cover-35-notes.txt`
- **下一 tick**：解锁验过期待办交给我办后角标掉；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:12 · Verdict-36 · 核对结果双刷 + 入口拉新
缺口：activityVerdict 只刷短路径，下一步「结果待核对」与动态 feedPath 不同步；批准失败仍 handoff；记忆/账本/连接器打开偏旧。
- **activityVerdict**：并行 `load(/personal/activity)` + `feedPath`。
- **action→Bool**：等你批准/先别仅成功才 handoff。
- **openMemory / openFinance / openConnectors**：打开即拉新（对齐 Waiting/动态）。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-verdict-36`（Locked 未 launch）。
- 证据：`build-verdict-36.log` · `install-verdict-36.log` · `verdict-36-notes.txt`
- **下一 tick**：解锁验下一步待核对点掉后动态同步；菜单账本/记忆新；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:13 · Draft-37 · 复制微信草稿后清等你
缺口：下一步「复制草稿去微信」只关掉 next 卡，同聊天仍占 waiting 角标。
- **`ackWaitingWechat(named:)`**：按 `wechat:名` / 标题匹配后走 Ack-31。
- **`runNextAction` reply_wechat**：drafted 后立刻确认。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-draft-37`（Locked 未 launch）。
- 证据：`build-draft-37.log` · `install-draft-37.log` · `draft-37-notes.txt`
- **下一 tick**：解锁验微信草稿动作后角标掉；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:15 · Fix-38 · 做错了进对话改
缺口：下一步待核对「做错了」只标状态；动态「让它改」只带草稿不记账。
- **Next UncertainCard**：「做错了，去改」→ verdict + 草稿进 Com。
- **Feed「让它改」**：先标 wrong，再进对话。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-fix-38`（Locked 未 launch）。
- 证据：`build-fix-38.log` · `install-fix-38.log` · `fix-38-notes.txt`
- **下一 tick**：解锁验做错了进对话；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:16 · Book-39 · 下一步记账成功才消卡 + 设置刷 status
缺口：bookkeep/calendar 发送失败仍 `done`；设置页 /status 常旧。
- **send→Bool**：仅 delivered 为 true。
- **runNextAction**：记账/加日程成功才 nextAction(done)。
- **Settings**：打开 `.task` 拉 `/status`。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-book-39`（Locked 未 launch）。
- 证据：`build-book-39.log` · `install-book-39.log` · `book-39-notes.txt`
- **下一 tick**：解锁验失败记账卡还在；设置审批数新；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:17 · Health-40 · 健康进页拉齐 + 分享进草稿即关
缺口：健康 `.task` 只拉今天/下一步，曲线与评估靠切 Tab；分享「加入草稿」成功后可能仍停在收件箱看不到输入框。
- **HealthView.task**：并行 `/personal/today` · `next` · `health?days=30` · `health/insight`。
- **ShareInbox**：`persistNow`；导入成功一律 `dismiss` 进聊天。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-health-40`。
- 证据：`build-health-40.log` · `install-health-40.log` · `health-40-notes.txt`
- **下一 tick**：解锁验健康首屏有数/评估；分享进草稿即见输入框；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:19 · 监督 tick #2 已响应 · Hand-41 · 送达才跳聊天
- **监督**：tick #2 已响应；循环仍跑（pid 18419 · 40m）；未到 07:20，继续产品实质。
缺口：今天「交给 Com」、等你「起草回复」、热点「讲讲」、下一步记账/日程——失败仍跳空聊天或先关等你。
- **Today.hand / draftWechatReply / askAboutHot**：`send` 成功才关收件箱/切 Com。
- **bookkeep/calendar**：补全 Book-39——成功才 `tab=.chat` + done。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-hand-41`。
- 证据：`build-hand-41.log` · `install-hand-41.log` · `hand-41-notes.txt`
- **下一 tick**：解锁验失败不丢等你/不空跳；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:21 · Link-42 · 深链 tasks/cases/plan 对齐行为
缺口：小组件 `://tasks` 进「今天」；航程推送 `://cases` 不拉动态；灵动岛 `://plan` 不刷新下一步。
- **tasks** → `openWaitingInbox()`（与通知 section=tasks 同路）。
- **cases** → `showCases` + 立刻 `loadFeed()`；关冲突 sheet。
- **plan** → 切下一步并拉 `/personal/next` + `/plan`。
- **today** 仍回主对话（灵动岛 chatLink 约定）。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-link-42`；循环仍跑。
- 证据：`build-link-42.log` · `install-link-42.log` · `link-42-notes.txt`
- **下一 tick**：解锁验小组件审批进等你 / 航程推送动态新；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:22 · Day-43 · 今天进页拉齐 + 提醒/热点失败不丢页
缺口：今天无进页拉齐；提醒失败仍关详情；热点全表「讲讲」先关再发；加日程不预热今天。
- **TodayView.task**：并行 today · next · hot。
- **reminderAction→Bool**：成功才 dismiss。
- **askAboutHot→Bool**：热点 sheet 成功才关。
- **calendar**：送达后 `load(/personal/today)`。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-day-43`；循环仍跑。
- 证据：`build-day-43.log` · `install-day-43.log` · `day-43-notes.txt`
- **下一 tick**：解锁验今天首屏 / 提醒失败留页；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:23 · Next-44 · 下一步进页拉齐 + 讨论失败不假完成
缺口：下一步只刷 activity；等你「交给我办」失败仍报已接进；记忆进页缺列表；事项反馈失败仍关。
- **NextView.task**：并行 next · activity · waiting · cases。
- **pendingDiscuss→Bool**：成功才 completed / 跳聊天。
- **MemoryView.task**：memory + inbox。
- **事项 feedback/mute**：`action` 成功才 dismiss。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-next-44`；循环仍跑。
- 证据：`build-next-44.log` · `install-next-44.log` · `next-44-notes.txt`
- **下一 tick**：解锁验下一步首屏 / 交给我办失败不消卡；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:25 · Gate-45 · 审批/划走/航程收尾失败不假完成
缺口：派活详情批准失败仍关；左划失败仍报已划掉；航程停止/标完成失败仍刷状态。
- **ProposalDetail**：`action` 成功才 dismiss。
- **pendingDismiss→Bool**：左划成功才 completed。
- **caseCancel/caseResolve→Bool**：成功才 `refreshAfterCaseChange` 与详情重载。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-gate-45b`；循环仍跑。
- 证据：`build-gate-45.log` · `build-gate-45b.log` · `install-gate-45b.log` · `gate-45-notes.txt`
- **下一 tick**：解锁验审批失败留页 / 划走失败卡还在；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:27 · Voice-46 · 语音送达才清录音 + 工作进页拉齐
缺口：语音 `send` 先 `cancel` 再 deliver，失败丢转写；工作侧栏不进页拉 projects/sessions。
- **send(voice)**：仅 `delivered` / `rejected` 才清录音；uncertain/失败保留可重试。
- **WorkView.task**：并行 `/personal/projects` · `/sessions`。
- **nextAction / nextToTodo→Bool**（签名对齐门控）。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-voice-46`；循环仍跑。
- 证据：`build-voice-46.log` · `install-voice-46.log` · `voice-46-notes.txt`
- **下一 tick**：解锁验语音失败保留转写 / 工作侧栏进页有数；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:28 · Hand-47 · 交给我办失败不误报 + 语音审批保留上下文
缺口：等你底栏常是 chat，「交给我办」失败仍报已接进；语音审批失败清 pendingApproval。
- **delegateNext/Todo**：chat → `""`；失败 → `nil`；航程 → id。
- **Waiting/Next UI**：仅非 nil 报完成。
- **answerApproval→Bool**：失败保留审批；语音成功才关窗。
- **activityVerdict→Bool**。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-hand-47`；循环仍跑。
- 证据：`build-hand-47.log` · `install-hand-47.log` · `hand-47-notes.txt`
- **下一 tick**：解锁验交给我办失败无假完成 / 语音拒批失败可重说；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:30 · Plan-48 · 明天计划进页拉齐 + 待办乐观确认
缺口：下一步不拉 plan；等你待办完成/改期无乐观隐藏；明天计划 apply 成功不收起。
- **NextView.task**：+ `/personal/plan`。
- **waitingTodo→Bool**：完成/改期先藏，失败还原（同「已经回了」）。
- **applyPlan**：成功才本地收起明天卡。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-plan-48`；循环仍跑。
- 证据：`build-plan-48.log` · `install-plan-48.log` · `plan-48-notes.txt`
- **下一 tick**：解锁验明天计划首屏 / 待办完成失败回弹；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:32 · Mem-49 · 记忆确认失败回弹 + 归档假成功
缺口：记忆确认后无论成败都 unhide（成功可能闪回）；删失败仍藏；旧任务归档/全部稍后一律报成功。
- **actOnLearned→Bool**：成功才拉新并返回 true。
- **MemoryReview**：失败才放回纸片；成功保持隐藏。
- **archiveStale→Bool** / **dismissAll**：有成功才报完成文案。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit 未动。
- **构建**：`BUILD SUCCEEDED`；`install-mem-49b`；循环仍跑。
- 证据：`build-mem-49.log` · `build-mem-49b.log` · `install-mem-49b.log` · `mem-49-notes.txt`
- **下一 tick**：可扫动态「做成了」乐观点亮失败回弹、或 ChatPresence starter 送达门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:33 · Feed-50 · 动态「做成了」乐观回弹 + 建议芯片送达门控
缺口：动态核对只靠服务态，无乐观点亮、全失败不回弹；建议芯片点后即 `picked`/`usedSuggestions`，发送失败整组假收起。
- **FeedDetailCard**：`pending`/`busy`；点「做成了/没做成」先亮；任一条 `activityVerdict` 失败则清 pending 可重试；「让它改」仍进聊天。
- **SuggestionChips.choose→Bool**：乐观 `picked`；`ok==false` 回弹；ChatView 仅送达成功才写 `usedSuggestions`。
- **禁令**：未铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-feed-50`；循环仍跑。
- 证据：`build-feed-50.log` · `install-feed-50.log` · `feed-50-notes.txt`
- **下一 tick**：解锁验动态核对失败回弹 / 芯片失败可重试；可扫 UncertainCard 或 ChatPresence starter 送达门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:34 · Check-51 · 结果待核对乐观回弹 + 空态 starter 送达门控
缺口：下一步 UncertainCard 点「做成了」无乐观点亮、失败不回弹；空态 starter 连点可叠发、失败无门控。
- **UncertainCard**：`pending`/`busy`；「做成了/没做成」先亮；`activityVerdict` 失败清 pending；「做错了，去改」仍进聊天。
- **ChatEmptyPresence**：`sending` 期间 starter 禁用；`send` 失败才放开可重试（成功由时间线顶替空态）。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-check-51`；循环仍跑。
- 证据：`build-check-51.log` · `install-check-51.log` · `check-51-notes.txt`
- **下一 tick**：解锁验待核对失败回弹 / starter 失败可再点；可扫 NextGlanceCard 或其它送达门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:37 · Glance-52 · 下一步主卡乐观收起 + Glance 失败反馈
缺口：主卡「已经做了/划掉/稍后再说」等服务回才消失、失败无回弹；`runNextAction` 无 Bool；Glance 失败只闪 busy。
- **runNextAction→Bool**：微信/邮件标 drafted、记账/日程送达后才标 done；失败返回 false（微信草稿打开后若标状态失败也不清等你）。
- **NextCard**：done/dismiss/snooze 先 `gone`，失败回弹 + 脚注；主动作/交给我办/加待办失败脚注。
- **NextGlanceCard**：`failNote`「没成，还可以再点」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-glance-52`；循环仍跑。
- 证据：`build-glance-52.log` · `install-glance-52.log` · `glance-52-notes.txt`
- **下一 tick**：解锁验主卡失败回弹 / Glance 失败提示；可扫 EvidencePocket 或其它送达门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:38 · Evidence-53 · 依据袋→事项「交给 Com」失败留页
缺口：依据详情跳事项用过期 stub；事项「交给 Com」可连点、失败仅 banner；更正/静音/解除无失败留页提示。
- **EvidenceDetail.openMatter**：缺卡先 `load(/personal/agency)`，再打开完整卡或 stub。
- **MatterDetailView**：`busy`/`failNote`；交给 Com 成功才 dismiss+进聊天；关注/稍后/已处理/更正/不再提醒/解除失败留页可重试。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-evidence-53`；循环仍跑。
- 证据：`build-evidence-53.log` · `install-evidence-53.log` · `evidence-53-notes.txt`
- **下一 tick**：解锁验依据→事项失败可重试；可扫 TaskDetail 指令门控或其它送达门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:40 · Task-54 · 任务详情指令失败留页 + Hub 进页拉齐
缺口：TaskDetail 指令失败仅 banner、补充成功才清空但无页内提示；回原消息先 dismiss；TaskHub 进页不拉 tasks；归档/全部稍后失败无文案。
- **TaskDetailView.command**：失败写 `failNote`（验收/补充/停止/恢复/合入）；成功才清 supplement；回原消息先定位再收起。
- **TaskHubView**：`.task` 拉 `/personal/tasks` + agency；归档失败 / 全部稍后全失败有结果句。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-task-54`；循环仍跑。
- 证据：`build-task-54.log` · `install-task-54.log` · `task-54-notes.txt`
- **下一 tick**：解锁验任务指令失败可重试 / Hub 首屏新数；可扫 GoalList 或连接器门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:42 · Goal-55 · 目标列表进页拉齐 + 暂停/完成失败留页；连接器失败警示
缺口：GoalList 进页不拉 agency；GoalRow 死盯入参、失败仅 banner；新建目标失败无页内提示；连接器失败/未接通也用中性 notice、失败仍清密码观感不清。
- **GoalList**：`.task` 拉 `/personal/agency`。
- **GoalRow**：跟 `current` 状态；暂停/恢复/完成失败 `failNote` 可重试。
- **GoalEditor**：创建失败留页提示，成功才 dismiss。
- **ConnectionDetail**：失败/未接通用 danger notice；请求失败保留密码可改再试。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-goal-55`；循环仍跑。
- 证据：`build-goal-55.log` · `install-goal-55.log` · `goal-55-notes.txt`
- **下一 tick**：解锁验目标失败可重试 / 连接器失败警示；可扫 AgencySettings 或航程 Process 门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:43 · Agency-56 · 主动性保存失败留页 + 航程停顿拍板门控
缺口：AgencySettings 保存失败仅 banner；进页不拉最新 settings；航程停顿 CTA 可连点叠发、失败无提示；标完成/停止/发送失败静默。
- **AgencySettings**：进页拉 agency 并 hydrate；保存失败 `failNote` 留页；成功才 dismiss。
- **CaseDetailView**：`acting`/`actFail`；停顿卡继续/改做法/标完成、停止、composer 失败留页可重试（草稿保留）。
- **禁令**：未新铺 SoftPress（pill 原有 SoftPress 未扩）；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-agency-56`；循环仍跑。
- 证据：`build-agency-56.log` · `install-agency-56.log` · `agency-56-notes.txt`
- **下一 tick**：解锁验主动性保存失败 / 航程拍板失败可重试；可扫 AcceptancePanel 或配对/账本门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:45 · Accept-57 · 验收「让它补证据」送达门控 + 配对码失败留页
缺口：AcceptancePanel 补问 fire-and-forget，失败无提示可叠发；配对重新生成失败文案弱、可连点。
- **AcceptancePanel**：`ask→async Bool`；`asking`/`failNote`；与航程 `locked` 互斥；失败「补问没送出去，还可以再点」。
- **CaseDetailView.actSend→Bool**：补问与停顿拍板共用送达结果。
- **PairCodeSheet**：生成失败留页提示可再生成；防连点叠请求。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-accept-57`；循环仍跑。
- 证据：`build-accept-57.log` · `install-accept-57.log` · `accept-57-notes.txt`
- **下一 tick**：解锁验验收补问失败可重试 / 配对码失败提示；可扫账本或回执门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:46 · Receipt-58 · 设备撤销失败回滚 + 发送记录查回执 + 账本读失败警示
缺口：设备回执撤销先占坑，请求失败按钮假锁死；设置里查回执无忙态/失败提示；账本读失败只空态无错误句。
- **DeviceReceiptsView**：撤销先占坑防叠发；mutate 失败回滚 `undo_requested` 可再试；失败 danger notice。
- **SettingsView 发送记录**：查回执 busy + 仍待核实提示；防连点。
- **FinanceDetail**：`errors[/personal/finance]` 时 danger InlineNotice。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-receipt-58`；循环仍跑。
- 证据：`build-receipt-58.log` · `install-receipt-58.log` · `receipt-58-notes.txt`
- **下一 tick**：解锁验设备撤销失败可再试 / 账本读失败警示；可扫分享收件箱或产物定位门控；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:48 · Share-59 · 分享加入草稿失败留页 + 搜索/原消息定位门控
缺口：分享加入失败提示弱；搜索点中先 dismiss 再 locate，找不到也关页；成果打开失败 notice 中性；任务「回原消息」定位失败仍关页。
- **ShareInboxView**：失败 danger notice、分享保留可重试；未配对明确提示。
- **locateMessage→Bool**：对上消息才跳聊天。
- **SearchView**：定位/任务对上才 dismiss；失败留列表提示。
- **ArtifactList**：打开失败 danger + 可再点；未配对提示。
- **TaskDetail**：原消息 locate 失败留页。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-share-59`；循环仍跑。
- 证据：`build-share-59.log` · `install-share-59.log` · `share-59-notes.txt`
- **下一 tick**：解锁验分享失败保留 / 搜索定位失败留页；可扫剩余送达门控或 Harden 准备；**勿 SoftPress**；07:20 后 Harden。

### 2026-10-29 02:50 · Gate-60 · Agency 交给 Com 失败留页 + 舞台先定位 + 等你失败反馈
缺口：AgencyDetail 整理/讨论失败仅 banner，讨论失败不挡跳聊天风险已在 catch，但无页内提示；舞台「看回复」先关再 locate；等你卡 act/prepare/批准失败无文案；记忆保存失败 notice 中性。
- **AgencyDetail**：prepare/discuss `failNote`；失败不 dismiss。
- **Chrome 看回复**：`locateMessage` 成功才 `closeStage`。
- **PendingNote**：批准/先别/act/prepare 失败写结果句；busy 真正生效。
- **Memory 纠正保存** / **RunSheet**：失败 danger 提示可重试。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**（等 ~07:20）。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-gate-60`；循环仍跑。
- 证据：`build-gate-60.log` · `install-gate-60.log` · `gate-60-notes.txt`
- **下一 tick**：解锁验 Agency 失败留页 / 看回复定位；可继续扫 ChatView 查回执等门控；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 02:52 · Chat-61 · 查回执忙态 + 中断防连点
缺口：uncertain「查回执」fire-and-forget 可连点叠查；全部中断 /「停下这件」无忙态。
- **MessageView**：`checkingReceipt` →「查询中…」+ spinner；`deliver` 完才复原；busy 时 disable。
- **停下这件 / 全部中断**：`interrupting` / `interruptingAll` 防连点，文案「正在停下…/正在中断…」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（本轮 0 新 warning；既有 ScrollFrameMonitor deprecation）；`install-chat-61`（Locked，未 launch）；循环仍跑。
- 证据：`build-chat-61.log` · `install-chat-61.log` · `chat-61-notes.txt`
- **下一 tick**：解锁验查回执忙态；可做 WorkHome「停止执行」busy 或 Threads「起草回复」失败反馈；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 02:54 · Work-62 · 停止执行 busy + 失败提示
缺口：工作页作曲器与顶栏「停止执行」fire-and-forget，可连点；失败仅靠全局 banner。
- **WorkSessionModel**：`stopping` 共享忙态；`stop` 防重入；失败写 `note`（并保留 action banner）。
- **WorkComposer / WorkTitleMenu**：hourglass /「正在停止…」+ disabled。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话面未改架构；HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-work-62`（Locked，未 launch）；循环仍跑。
- 证据：`build-work-62.log` · `install-work-62.log` · `work-62-notes.txt`
- **下一 tick**：解锁验停止 busy；可做 Threads「起草回复」忙态/失败反馈；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 02:55 · Draft-63 · 等你微信起草忙态/失败反馈
缺口：「让 Com 起草回复」无忙态可连点；失败仅靠全局 banner，页内无提示。
- **draftWechatReply** → `Bool`；失败不关等你。
- **WaitingSheet**：`draftingID`「起草中…」+ disable；失败 `draftFailNote` 危险色可重试。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-draft-63`（Locked，未 launch）；循环仍跑。
- 证据：`build-draft-63.log` · `install-draft-63.log` · `draft-63-notes.txt`
- **下一 tick**：解锁验微信起草忙态；可做 Work 置顶/结束会话 busy，或 HotBoard「讲讲」忙态；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 02:56 · Work-63 · 置顶/结束会话 busy + 失败提示
缺口：工作顶栏置顶/结束 fire-and-forget，可连点；失败仅全局 banner。
- **WorkSessionModel**：`pinning` / `ending`；失败写 `note`；与停止互斥 disable。
- **WorkTitleMenu**：文案「处理中…/正在结束…」+ disabled。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话架构 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-work-63`（Locked，未 launch）；循环仍跑。
- 证据：`build-work-63.log` · `install-work-63.log` · `work-63-notes.txt`
- **下一 tick**：解锁验置顶/结束 busy；可做 HotBoard「讲讲」忙态/失败反馈；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 02:57 · Hot-64 · 热点「讲讲」忙态/失败反馈
缺口：今天/热点表「让 Com 讲讲」无忙态可连点；失败无行内提示（仅全局 banner）。
- **HotTopicRow**：`talking`「正在交给 Com…」；失败行内危险色；菜单「讲讲中…」+ disable。
- **HotBoardSheet** 24h 精选：`talkingTitle` + `sheetFail`；失败不 dismiss。
- **禁令**：未新铺 SoftPress（沿用既有 row SoftPress）；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-hot-64`（Locked，未 launch）；循环仍跑。
- 证据：`build-hot-64.log` · `install-hot-64.log` · `hot-64-notes.txt`
- **下一 tick**：解锁验讲讲忙态；可做 FlowCards 左划主操作 busy，或设置解除配对/刷新门控；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 02:59 · Flow-65 · 等你卡左右划 busy/失败反馈
缺口：右划 `pendingPrimary` / 左划 dismiss 无 busy 可连划叠批；批准失败无结果句；长按「聊」失败静默。
- **pendingPrimary** → `Bool`；右划走 `primarySwipe`（busy + 批准/讨论成败文案）。
- **左划 dismiss**：busy 防重入；失败「划掉没成」留卡。
- **长按聊**：busy + 失败反馈。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-flow-65`（Locked，未 launch）；循环仍跑。
- 证据：`build-flow-65.log` · `install-flow-65.log` · `flow-65-notes.txt`
- **下一 tick**：解锁验左右划；可做设置「刷新连接/服务器状态/解除配对」busy；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:00 · Set-66 · 设置刷新/解除配对 busy（tick #3）
缺口：刷新连接、服务器状态、全量同步、解除配对 fire-and-forget，可连点；解除后立刻 dismiss 不等完成。
- **刷新连接 / 服务器状态 / 更新服务端状态**：「刷新中…/更新中…」+ disabled。
- **解除配对**：`unpairing`；完成后才 dismiss；进行中禁用完成按钮。
- **监督**：过夜 tick #3 已响应（循环仍跑）；**未做 Harden**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-set-66`（Locked，未 launch）。
- 证据：`build-set-66.log` · `install-set-66.log` · `set-66-notes.txt`
- **下一 tick**：解锁验设置刷新/解除；可做权限授权按钮 busy，或 Chrome 健康/下一步刷新门控；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:02 · Chrome-67 · 健康/下一步顶栏刷新门控
缺口：顶栏刷新在服务端 `running` 亮起前可连点叠刷；健康刷新失败不回落 running。
- **TopBarTrailing**：`localBusy` 挡住连点；hourglass 覆盖本地忙。
- **refreshHealthInsight / refreshNext**：先乐观 `running=true`；失败回落 + banner。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-chrome-67`（Locked，未 launch）；循环仍跑。
- 证据：`build-chrome-67.log` · `install-chrome-67.log` · `chrome-67-notes.txt`
- **下一 tick**：解锁验健康/下一步刷新；可做设置权限授权 busy；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:03 · Auth-68 · 设置权限/通知授权 busy
缺口：健康/日历等授权与开启通知 fire-and-forget，可连点叠弹系统框。
- **permission**：`authBusyDomain`「· 请求中…」；同组互斥 disable。
- **开启通知**：`notifyBusy`「请求中…」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-auth-68`（Locked，未 launch）；循环仍跑。
- 证据：`build-auth-68.log` · `install-auth-68.log` · `auth-68-notes.txt`
- **下一 tick**：解锁验授权 busy；可做 Search 定位失败反馈，或 Root 菜单刷新门控；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:04 · Search-69 · 搜索命中打开 busy
缺口：点搜索结果可连点叠定位；失败文案已有但无忙态。
- **openingID**：「正在打开…」+ 行标题「打开中…」；列表互斥 disable；完成按钮忙碌时禁用。
- 定位/任务失败仍留页既有危险色提示。
- **禁令**：未新铺 SoftPress（沿用 MessagePress）；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-search-69`（Locked，未 launch）；循环仍跑。
- 证据：`build-search-69.log` · `install-search-69.log` · `search-69-notes.txt`
- **下一 tick**：解锁验搜索打开；可做 Root/菜单入口拉新 busy，或线索 msg 定位失败反馈；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:05 · Thread-70 · 线索/通知 msg 定位失败反馈
缺口：线索「消息」环与 Root 通知定位失败静默，人以为已跳进聊天。
- **openThreadNode(msg)**：`locateMessage` 失败写 banner「这条消息对不上了…」。
- **Root 通知 locate**：同样失败反馈。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-thread-70`（Locked，未 launch）；循环仍跑。
- 证据：`build-thread-70.log` · `install-thread-70.log` · `thread-70-notes.txt`
- **下一 tick**：解锁验线索定位失败提示；可做菜单入口打开中 busy，或 Artifact 下载失败门控；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:07 · Artifact-71 · 成果不可用门控 + 菜单拉新防叠
缺口：missing/未核对成果仍发起 download；菜单记忆/账本等入口连点可叠刷。
- **ArtifactList.open**：`missing` / 非 available 先危险色提示，不下载；登记后再核对 missing。
- **AppModel 菜单入口**：`menuOpening` 防同一入口叠刷（waiting/activity/memory/finance/connectors）。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-artifact-71`（Locked，未 launch）；循环仍跑。
- 证据：`build-artifact-71.log` · `install-artifact-71.log` · `artifact-71-notes.txt`
- **下一 tick**：解锁验成果 missing 提示；可做 HTML 预览态保存失败反馈，或 Connections 重授权 busy；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:08 · Preview-72 · HTML 预览态保存失败反馈
缺口：HTML 勾选/输入态 `try?` 静默写回，失败人以为已存。
- **saveState**：失败/无 client/解码失败写底栏危险色 `saveNote`；成功清掉。
- Connections 重授权本就有 `busy`，本轮未改。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-preview-72`（Locked，未 launch）；循环仍跑。
- 证据：`build-preview-72.log` · `install-preview-72.log` · `preview-72-notes.txt`
- **下一 tick**：解锁验 HTML 存态失败条；可做 FlowCards 连接器卡重授权跳转，或 Today 简报刷新本地 busy；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:10 · Conn-73 · 信源断卡拉新再跳转
缺口：「去把 X 接上」直接塞旧 source 开详情，可连点；配置页可能带着过期断连快照。
- **SourceBrokenNote**：`opening`「打开中…」；先 `load(/personal/connectors)` 再取 fresh 设 `selectedConnector`。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-conn-73`（Locked，未 launch）；循环仍跑。
- 证据：`build-conn-73.log` · `install-conn-73.log` · `conn-73-notes.txt`
- **下一 tick**：解锁验信源断卡跳转；可做 Today 简报刷新 localBusy；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:11 · Today-74 · 简报刷新 localBusy
缺口：今天「我说几句」刷新仅靠 nextData.running，亮起前可连点叠刷。
- **ScheduleAdvice**：`localBusy` 与 running 合并 disable；旋转动画覆盖本地忙。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-today-74`（Locked，未 launch）；循环仍跑。
- 证据：`build-today-74.log` · `install-today-74.log` · `today-74-notes.txt`
- **下一 tick**：解锁验今天简报刷新；可扫剩余门控（如 Voice 开麦 busy、LedgerNote 打开账本）或小回归；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:12 · Voice-75 · 开麦 starting busy
缺口：录音 `starting` 对 UI 不可见，开麦可连点叠启；`openVoice` 仅内部防重。
- **VoiceRecorder**：`starting` → `private(set)` 供 UI 读。
- **openVoice**：starting/recording/transcribing/hasCapture 时直接 return。
- **ChatView 麦按钮 / VoiceSessionPanel**：hourglass·「开麦中…」+ disabled。
- **禁令**：未新铺 SoftPress（沿用既有 SoftPress）；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-voice-75`（Locked，未 launch）；循环仍跑。
- 证据：`build-voice-75.log` · `install-voice-75.log` · `voice-75-notes.txt`
- **下一 tick**：解锁验开麦 busy；可做 LedgerNote 打开账本 busy，或小回归扫门控；**勿 SoftPress**；**07:20 后再 Harden**。

### 2026-10-29 03:14 · Ledger-76 · 账本卡打开 busy
缺口：下一步 LedgerNote 点开账本无 UI busy（底层 menuOpening 已防叠刷但看不见）。
- **AppModel**：`financeOpening` 暴露拉新中。
- **LedgerNote**：「打开中…」+ ProgressView + disabled。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-ledger-76`（Locked，未 launch）；循环仍跑。
- 证据：`build-ledger-76.log` · `install-ledger-76.log` · `ledger-76-notes.txt`
- **下一 tick**：解锁验账本卡 busy；可小回归扫剩余门控，或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:16 · Evidence-77 · 依据跳事项 busy
缺口：EvidenceDetail「看这个日程/微信/邮件」拉 agency 无 busy，可连点；拉失败静默走 stub。
- **EvidenceDetail**：`openingMatter` busy（「打开中…」+ disabled）；agency 拉失败提示仍可开 stub 再点拉齐。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-evidence-77`（Locked，未 launch）；循环仍跑。
- 证据：`build-evidence-77.log` · `install-evidence-77.log` · `evidence-77-notes.txt`
- **下一 tick**：解锁验依据跳事项 busy；可继续小回归门控（如菜单记忆/连接器打开 busy UI），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:18 · Menu-78 · 记忆/连接器打开 busy
缺口：菜单记忆/连接器/账本与舞台信源芯片打开时无 UI busy（底层 menuOpening 已防叠刷）。
- **AppModel**：暴露 `memoryOpening` / `connectorsOpening`。
- **菜单**：记忆/账本/连接器「打开中…」+ ProgressView + disabled。
- **MemorySheet / MemoryView**：拉齐中顶栏与标题旁 busy。
- **ConnectorsSheet / ConnectionsView**：拉齐中顶栏与页内提示；舞台信源芯片同步 busy。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-menu-78`（Locked，未 launch）；循环仍跑。
- 证据：`build-menu-78.log` · `install-menu-78.log` · `menu-78-notes.txt`
- **下一 tick**：解锁验菜单记忆/连接器 busy；可继续小回归（如等你/动态打开 busy UI），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:21 · Wait-79 · 等你/动态打开 busy
缺口：菜单「等你/动态」、舞台「等你」芯片、下一步入口打开时无 UI busy（底层 menuOpening 已防叠刷）。
- **AppModel**：暴露 `waitingOpening` / `activityOpening`。
- **菜单 + 舞台**：等你/动态「打开中…」+ ProgressView/disabled；舞台等你芯片同步。
- **WaitingSheet**：拉齐中顶栏 + 页内提示；拉齐中不闪空态。
- **ActivityFeedSheet / Feed**：拉齐中顶栏 + 标题旁 busy；下一步入口同步。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-wait-79`（Locked，未 launch）；循环仍跑。
- 证据：`build-wait-79.log` · `install-wait-79.log` · `wait-79-notes.txt`
- **下一 tick**：解锁验等你/动态 busy；可继续小回归（如 ChatPresence 等你条打开 busy、或剩门控），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:23 · Presence-80 · ChatPresence 等你条打开 busy
缺口：主聊空态 starter「去拍板」与底栏注意力条点「去拍板」无 UI busy，可连点叠开。
- **ChatEmptyPresence**：waiting starter「打开中…」+ hourglass + disabled（沿用 `waitingOpening`）。
- **ChatAttentionStrip**：等你态「正在打开等你…」+ ProgressView + disabled，呼吸动效暂停。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-presence-80`（Locked，未 launch）；循环仍跑。
- 证据：`build-presence-80.log` · `install-presence-80.log` · `presence-80-notes.txt`
- **下一 tick**：解锁验主聊等你条 busy；可继续小回归（今天/工作入口等你、或剩门控），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:26 · Entry-81 · 今天/工作等你入口 busy
缺口：今天页举手按钮、工作 Remote「等你」无 UI busy，可连点叠开。
- **TodayView**：举手钮打开中 ProgressView + disabled；角标与呼吸暂停。
- **WorkRemote**：「打开中…」+ hourglass + disabled。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-entry-81`（Locked，未 launch）；循环仍跑。
- 证据：`build-entry-81.log` · `install-entry-81.log` · `entry-81-notes.txt`
- **下一 tick**：解锁验今天/工作等你 busy；可继续小回归剩门控，或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:29 · Ledger-82 · 账本 sheet 拉齐 busy
缺口：openFinance 底层有 financeOpening，但支出明细页不显示拉齐中；无缓存时易空闪。
- **FinanceDetail**：`financeOpening || loading` 顶栏 busy 文案；有缓存可边看边拉；无数据时 ProgressView；进页先吃 datasets 快照。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-ledger-82`（Locked，未 launch）；循环仍跑。
- 证据：`build-ledger-82.log` · `install-ledger-82.log` · `ledger-82-notes.txt`
- **下一 tick**：解锁验账本 sheet 拉齐 busy；可继续小回归剩门控（如设置页打开、或失败反馈扫尾），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:32 · Settings-83 · 设置打开 busy
缺口：菜单「设置」只 `showSettings=true`，无打开 busy；/status 靠 sheet `.task`，连点可叠开观感旧。
- **AppModel**：`openSettings` + `settingsOpening`；打开即拉 `/status`。
- **菜单**：设置「打开中…」+ ProgressView + disabled。
- **SettingsView**：顶栏/页内拉齐提示；服务器行空态写「拉齐中…」；刷新钮与 open 拉齐互斥。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-settings-83`（Locked，未 launch）；循环仍跑。
- 证据：`build-settings-83.log` · `install-settings-83.log` · `settings-83-notes.txt`
- **下一 tick**：解锁验设置打开 busy；可继续门控扫尾（搜索打开 busy、或剩失败反馈），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:36 · Search-84 · 搜索打开 busy
缺口：顶栏搜索 /「查看成果」只 `showSearch=true`，无打开 busy；成果列表靠 sheet `.task`，易空闪旧快照。
- **AppModel**：`openSearch` + `searchOpening`；打开即拉 `/personal/artifacts`。
- **顶栏 / Chat 加号**：hourglass + disabled；「查看成果」同步。
- **SearchView**：拉齐提示；无成果时不闪空态；与 openSearch 防叠刷。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-search-84`（Locked，未 launch）；循环仍跑。
- 证据：`build-search-84.log` · `install-search-84.log` · `search-84-notes.txt`
- **下一 tick**：解锁验搜索打开 busy；可继续剩失败反馈扫尾，或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:38 · Todo-85 · 过期待办交接失败反馈
缺口：等你「交给我办」失败只 `return`，页内无提示；改期/完成可连点无 busy。
- **WaitingSheet**：`todoBusyID` 门控；「交给我办」失败页内 `todoFailNote`；改期/完成失败回弹 + 文案。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-todo-85`（Locked，未 launch）；循环仍跑。
- 证据：`build-todo-85.log` · `install-todo-85.log` · `todo-85-notes.txt`
- **下一 tick**：解锁验过期待办交接失败提示；可继续扫尾（如 WorkApproval 页内失败、或其它 silent fail），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:46 · Approval-86 · 审批卡页内失败反馈（tick #4）
缺口：WorkApprovalCard 批准/拒绝失败只写顶栏 banner，卡上无提示；人以为没点上或已走。
- **WorkApprovalCard**：`failNote` 页内危险提示；提交中文案；选项/语音入口提交中禁用。
- **监督**：过夜 tick #4 已响应；循环仍跑；**未做 Harden**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-approval-86`（Locked，未 launch）；循环仍跑。
- 证据：`build-approval-86.log` · `install-approval-86.log` · `approval-86-notes.txt`
- **下一 tick**：解锁验审批失败卡上提示；可继续 silent fail 扫尾，或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:50 · Source-87 · 进展依据读失败可重试
缺口：BoardSourceView 拉来源会话失败后 `?? .null`，空 messages 永远显示「正在读取来源会话…」。
- **BoardSourceView**：loading busy；失败 InlineNotice +「再试一次」；真空虚文案；成功才列消息。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-source-87`（Locked，未 launch）；循环仍跑。
- 证据：`build-source-87.log` · `install-source-87.log` · `source-87-notes.txt`
- **下一 tick**：解锁验进展依据读失败可重试；可继续 silent fail（如更早对话 loadHistory 失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:53 · History-88 · 更早对话失败反馈
缺口：`loadHistory` 失败静默；「更早的对话」busy 结束后人以为已到顶或已读完。
- **AppModel.loadHistory** → `Bool`（失败 false）。
- **ChatView**：失败页内 `historyFailNote`；失败不扩本地窗口预算。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-history-88`（Locked，未 launch）；循环仍跑。
- 证据：`build-history-88.log` · `install-history-88.log` · `history-88-notes.txt`
- **下一 tick**：解锁验更早对话失败提示；可继续 silent fail（如附件上传未配对静默），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 03:56 · Attach-89 · 附件未配对/上传失败提示
缺口：`upload` 无 client 时直接 return；照片读不出 / 文件选择失败也静默。
- **ChatView.upload**：未配对 / 断连写 banner；上传失败前缀「附件没传上」；照片空数据与 fileImporter failure 提示。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-attach-89`（Locked，未 launch）；循环仍跑。
- 证据：`build-attach-89.log` · `install-attach-89.log` · `attach-89-notes.txt`
- **下一 tick**：解锁验附件未配对提示；可继续 silent fail 扫尾，或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:01 · Dir-90 · 工作目录浏览失败可重试
缺口：`DirectoryPicker.browse` 失败时仍空白路径/空文件夹，无提示、无重试；「使用这里」只是灰掉像没内容。
- **DirectoryPicker**：loading busy；失败 InlineNotice +「再试一次」；空路径人话；浏览中禁用切目录。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-dir-90`（Locked，未 launch）；循环仍跑。
- 证据：`build-dir-90.log` · `install-dir-90.log` · `dir-90-notes.txt`
- **下一 tick**：解锁验工作目录读失败可重试；可继续 silent fail（如 NewWork 模型列表加载失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:02 · Models-91 · 派新活模型列表失败可重试
缺口：`NewWorkView` 拉 `/models?agent=` 失败时静默空列表，只剩「执行器默认」，像没可选模型。
- **NewWorkView.loadModels**：busy；失败 InlineNotice +「再试一次」；仍可用默认派出去；切换执行器时重拉。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-models-91`（Locked，未 launch）；循环仍跑。
- 证据：`build-models-91.log` · `install-models-91.log` · `models-91-notes.txt`
- **下一 tick**：解锁验派新活模型列表失败可重试；可继续 silent fail（如健康详情页拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:04 · Health-92 · 健康详情拉齐失败可重试
缺口：`HealthDetailView` 拉 `/personal/health?days=7` 失败静默，可能一直显示旧总览或空白曲线，像没数据。
- **HealthDetailView.refreshDetail**：busy；失败 InlineNotice +「再试一次」；仍可回退展示已有 `model.health`；真空虚人话。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-health-92`（Locked，未 launch）；循环仍跑。
- 证据：`build-health-92.log` · `install-health-92.log` · `health-92-notes.txt`
- **下一 tick**：解锁验健康详情拉齐失败可重试；可继续 silent fail（如工作首页侧栏 projects/sessions 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:05 · Side-93 · 工作侧栏 projects/sessions 失败可重试
缺口：侧栏拉 `/personal/projects` + `/sessions` 失败时一直「正在拢…」或空白像没历史，无提示、无重试。
- **WorkSidebarLayer.refreshSidebar**：busy；失败 InlineNotice +「再试一次」；区分全挂 / 项目挂 / 会话挂；结束 loading 不再假忙。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-side-93`（Locked，未 launch）；循环仍跑。
- 证据：`build-side-93.log` · `install-side-93.log` · `side-93-notes.txt`
- **下一 tick**：解锁验工作侧栏拉齐失败可重试；可继续 silent fail（如主动性 Agency 页拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:07 · Agency-94 · 目标页拉齐失败可重试
缺口：`GoalList` 拉 `/personal/agency` 失败静默，空列表像「还没有目标」假空态。
- **GoalList.refreshGoals**：busy；失败 InlineNotice +「再试一次」；失败空态改「目标还没读上」；成功才列目标。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-agency-94`（Locked，未 launch）；循环仍跑。
- 证据：`build-agency-94.log` · `install-agency-94.log` · `agency-94-notes.txt`
- **下一 tick**：解锁验目标页拉齐失败可重试；可继续 silent fail（如任务与目标 Hub 进页 tasks/agency 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:08 · Hub-95 · 任务与目标 Hub 拉齐失败可重试
缺口：`TaskHubView` 进页拉 `/personal/tasks` + `/personal/agency` 失败静默，空段像真的没事可办。
- **TaskHubView.refreshHub**：busy；失败 InlineNotice +「再试一次」；区分全挂 / 任务挂 / 目标挂；下拉刷新一并重拉。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-hub-95`（Locked，未 launch）；循环仍跑。
- 证据：`build-hub-95.log` · `install-hub-95.log` · `hub-95-notes.txt`
- **下一 tick**：解锁验任务与目标 Hub 拉齐失败可重试；可继续 silent fail（如航程详情轮询失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:09 · Case-96 · 航程详情轮询失败可重试
缺口：`CaseDetailView` 轮询 `/personal/cases/{id}` 失败时一直转圈（无数据）或静默停在旧稿（有数据），像还在对齐。
- **CaseDetailView.refreshCase**：失败 InlineNotice +「再试一次」；首拉失败结束假忙；有旧稿时标明「仍是上一版」；下拉刷新同路。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-case-96`（Locked，未 launch）；循环仍跑。
- 证据：`build-case-96.log` · `install-case-96.log` · `case-96-notes.txt`
- **下一 tick**：解锁验航程详情轮询失败可重试；可继续 silent fail（如主动性设置 AgencySettings 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:11 · Agency-97 · 主动性设置拉齐失败可重试
缺口：`AgencySettings` 拉 `/personal/agency` 失败静默，表单 hydrate 成默认值像已对齐，保存可能盖掉真安排。
- **AgencySettings.refreshSettings**：busy；失败 InlineNotice +「再试一次」；区分无缓存默认值 vs 旧稿；拉齐中禁用保存。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-agency-97`（Locked，未 launch）；循环仍跑。
- 证据：`build-agency-97.log` · `install-agency-97.log` · `agency-97-notes.txt`
- **下一 tick**：解锁验主动性设置拉齐失败可重试；可继续 silent fail（如搜索与成果 artifacts 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:13 · Search-98 · 搜索与成果 artifacts 拉齐失败可重试
缺口：`SearchView` 拉 `/personal/artifacts` 失败静默，空列表像「还没收过成果」假空态。
- **SearchView.refreshArtifacts**：busy；失败 InlineNotice +「再试一次」；与 openSearch 错开叠刷；失败空态改「成果还没读上」；无配对搜也提示。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-search-98`（Locked，未 launch）；循环仍跑。
- 证据：`build-search-98.log` · `install-search-98.log` · `search-98-notes.txt`
- **下一 tick**：解锁验搜索与成果拉齐失败可重试；可继续 silent fail（如线索 ThreadStrip 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:15 · Thread-99 · 线索 ThreadStrip 拉齐失败可重试
缺口：`ThreadStrip` 拉 `/personal/thread?key=` 失败静默，像没有上下游；有旧线索时也不提示刷新失败。
- **ThreadStrip.refreshThread**：首拉 busy；失败 InlineNotice +「再试一次」；无节点时显失败条；有旧节点标明仍是上一版。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-thread-99`（Locked，未 launch）；循环仍跑。
- 证据：`build-thread-99.log` · `install-thread-99.log` · `thread-99-notes.txt`
- **下一 tick**：解锁验线索拉齐失败可重试；可继续 silent fail（如记忆页 Memory 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:16 · Mem-100 · 记忆页拉齐失败可重试
缺口：`MemoryView` 拉 `/personal/memory` + inbox 失败静默，空文件夹像真的没记住；有旧稿也不提示刷新失败。
- **MemoryView.refreshMemory**：busy；失败 InlineNotice +「再试一次」；区分全挂 / 列表挂 / 待确认挂；与 openMemory 错开叠刷；失败空态改「记忆还没读上」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-mem-100`（Locked，未 launch）；循环仍跑。
- 证据：`build-mem-100.log` · `install-mem-100.log` · `mem-100-notes.txt`
- **下一 tick**：解锁验记忆页拉齐失败可重试；可继续 silent fail（如账本 Finance 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:18 · Fin-101 · 账本拉齐失败可重试
缺口：`FinanceDetail.reload` 失败把画面清空成 `.null`；错误只认 `/personal/finance`、无「再试一次」；换月路径失败更静默。
- **FinanceDetail.reload**：失败保留上一版；InlineNotice +「再试一次」；与 openFinance 错开叠刷；换月清画面再拉；「已记」刷新成功清 fail。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-fin-101`（Locked，未 launch）；循环仍跑。
- 证据：`build-fin-101.log` · `install-fin-101.log` · `fin-101-notes.txt`
- **下一 tick**：解锁验账本拉齐失败可重试；可继续 silent fail（如连接器 Connectors 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:20 · Conn-102 · 连接器拉齐失败可重试（tick #5）
缺口：`ConnectionsView` 虽露出 `errors[/personal/connectors]`，无「再试一次」；失败时空列表像没接过信源。
- **ConnectionsView.refreshConnectors**：busy；失败 InlineNotice +「再试一次」；与 openConnectors 错开叠刷；失败空态改「信源还没读上」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-conn-102`（Locked，未 launch）；循环仍跑；**tick #5 已响应**。
- 证据：`build-conn-102.log` · `install-conn-102.log` · `conn-102-notes.txt`
- **下一 tick**：解锁验连接器拉齐失败可重试；可继续 silent fail（如设置 /status 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:22 · Status-103 · 设置 /status 拉齐失败可重试
缺口：设置页拉 `/status` 失败静默，服务器段可能显示 0 / 空主机像正常诊断；刷新按钮不反馈失败。
- **SettingsView.refreshStatus**：busy；失败 InlineNotice +「再试一次」；与 openSettings 错开叠刷；无缓存时字段显示「— / 未读上」而非假 0。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-status-103`（Locked，未 launch）；循环仍跑。
- 证据：`build-status-103.log` · `install-status-103.log` · `status-103-notes.txt`
- **下一 tick**：解锁验设置 /status 拉齐失败可重试；可继续 silent fail（如定时 automations 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:24 · Auto-104 · 定时 automations 拉齐失败可重试
缺口：TaskHub「定时」只读 `/personal/automations` 缓存；失败时空文案像「还没有读到定时工作」，无重试。
- **TaskHubView.refreshHub**：一并拉 automations；`autoFail` InlineNotice +「再试一次」；失败空态改「定时工作还没读上」；有旧 jobs 标明上一版。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-auto-104`（Locked，未 launch）；循环仍跑。
- 证据：`build-auto-104.log` · `install-auto-104.log` · `auto-104-notes.txt`
- **下一 tick**：解锁验定时拉齐失败可重试；可继续 silent fail（如设备回执 DeviceReceipts 拉齐失败），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:25 · Receipt-105 · 设备回执拉齐失败可重试
缺口：`DeviceReceiptsView` 读 SecureVault 时目录失败被吞成 `[]`，像「还没有设备操作回执」；坏 sealed 条也静默丢。
- **SecureVault.loadRecords**：目录错误 / decode 失败分开计。
- **DeviceReceiptsView.reloadReceipts**：busy；失败 InlineNotice +「再试一次」；下拉刷新；失败空态改「回执还没读上」；目录瞬断保留已有列表。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-receipt-105`（Locked，未 launch）；循环仍跑。
- 证据：`build-receipt-105.log` · `install-receipt-105.log` · `receipt-105-notes.txt`
- **下一 tick**：解锁验设备回执拉齐失败可重试；可继续 silent fail（如分享收件箱 ShareInbox 列表拉齐），或实质产品缺口；或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:27 · Share-106 · 分享收件箱拉齐失败可重试
缺口：`ShareInbox.all()` 在 App Group 缺失 / 目录失败时返回 `[]`，像「还没收过分享」；坏 json 静默丢。
- **ShareInbox.loadAll**：容器 / 目录错误与 decode 失败分开计。
- **ShareInboxView.reloadList**：busy；失败 InlineNotice +「再试一次」；下拉刷新；失败空态改「分享还没读上」；瞬断保留已有列表。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-share-106`（Locked，未 launch）；循环仍跑。
- 证据：`build-share-106.log` · `install-share-106.log` · `share-106-notes.txt`
- **下一 tick**：解锁验分享收件箱拉齐失败可重试；silent fail 渐饱和，可转向实质产品缺口（如航程列表 Cases 拉齐），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 04:29 · Cases-107 · 动态/航程列表拉齐失败可重试
缺口：航程入口已并进动态；`loadFeed` 失败静默，空列表像「眼下还没什么动静」；「电脑上的活」航程挂了也无提示。
- **AppModel.loadFeed** → `(activity, cases)` 成败。
- **ActivityFeedView.refreshFeed**：busy；失败 InlineNotice +「再试一次」；区分全挂 / 航程挂 / 写操作挂；与 openActivityFeed 错开叠刷；失败空态改「航程/动态还没读上」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工作对话 / HerdrKit / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-cases-107`（Locked，未 launch）；循环仍跑。
- 证据：`build-cases-107.log` · `install-cases-107.log` · `cases-107-notes.txt`
- **下一 tick**：解锁验动态/航程拉齐失败可重试；**silent fail 主路径已较饱和**，可转向实质产品缺口（如明天计划 Plan 拉齐/开口），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~04:45 · Plan-108 · 明天计划拉齐/开口失败反馈
缺口：`TomorrowPlanCard` 拉 `/personal/plan` 失败时整卡消失像「没计划」；apply 失败仅 banner、卡上无提示。
- **拉齐**：进卡 `.task` 刷新 plan；失败 InlineNotice +「再试一次」；有缓存开口计划则「仍是上一版」。
- **开口**：无缓存失败时短句「明天计划还没读上」；有 open plan 才露卡（不假开口）。
- **Apply**：busy「放进去…」；失败卡上 `applyFail` 留卡可重试（成功才收起）。
- **构建**：`BUILD SUCCEEDED`（0 warning）；`install-plan-108`（Locked，未 launch）；循环仍跑。
- 证据：`install-plan-108.log`
- **下一 tick**：解锁验明天计划失败可重试 / apply 失败留卡；**Plan 优先项已齐，silent fail 主路径饱和** → 转向实质产品缺口（建议 HotBoard 全表进页拉齐/失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~04:50 · Hot-109 · 热点全表进页拉齐/失败开口
缺口：`HotBoardSheet` 进页不拉齐、失败像空表；今天卡空态藏「全部」进不了全表；刷新无失败反馈。
- **全表**：`.task` / 下拉 / 右上角重抓走 `pullSheet`；busy「正在拉齐」；失败 InlineNotice +「再试一次」；空失败开口「全表还没读上」。
- **今天卡**：空/失败也露「全部」；失败可重试；有缓存失败「仍是上一版」。
- **refreshHot**：返回 Bool；强制失败回落普通拉齐。
- **构建**：`BUILD SUCCEEDED`；`install-hot-109`（Locked，未 launch）；循环仍跑。
- 证据：`build-hot-109.log` · `install-hot-109.log` · `hot-109-notes.txt`
- **下一 tick**：解锁验热点全表失败可重试；可转向实质产品缺口（建议 VoyageBanner / 项目看板进页拉齐开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~04:55 · Board-110 · 航程条 / 项目看板进页拉齐开口
缺口：`VoyageBanner` 失败整卡消失像没航程；`ProjectBoardHome` sheet 进页不拉齐、失败像「没有项目」。
- **VoyageBanner**：`.task` 拉 `/personal/cases`；有缓存不叠刷；失败 InlineNotice + 重试；空失败开口「航程还没读上」。
- **ProjectBoardHome**：进页/下拉拉齐；失败可重试；空失败 EmptyState 勿当成无项目。
- **构建**：`BUILD SUCCEEDED`；`install-board-110`（Locked，未 launch）；循环仍跑。
- 证据：`build-board-110.log` · `install-board-110.log` · `board-110-notes.txt`
- **下一 tick**：解锁验航程条/项目看板失败可重试；可转向实质产品缺口（建议 WorkRemote 探测失败开口，或今天页其余进页拉齐边角，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:00 · Remote-111 · WorkRemote 探测失败开口
缺口：终端面进页不自动探测；失败只写终端旁注，开口弱；`/health` 错误未露出。
- **进页/换主机**：`.task(id: hostPreset)` 自动开口探测；成功仍只报「Com 通 · herdr 未接」。
- **失败**：InlineNotice +「再试一次」；露出 `errors[/health]`；页头/诚实旁白直说未通。
- **禁**：不假 herdr、不加 SoftPress 铺面。
- **构建**：`BUILD SUCCEEDED`；`install-remote-111`（Locked，未 launch）；循环仍跑。
- 证据：`build-remote-111.log` · `install-remote-111.log` · `remote-111-notes.txt`
- **下一 tick**：解锁验终端进页探测失败可重试；可转向实质产品缺口（建议今天提醒/日程详情进页失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:05 · Today-112 · 今天日程/提醒拉齐 + 详情失败开口
缺口：今天进页拉 `/personal/today` 失败像「没有日程」；提醒/日程详情动作失败无提示。
- **TodayView**：`pullToday` busy + InlineNotice + 再试；空失败开口「还没读上」勿当成无日程。
- **TodayDetail**：提醒写回 / 交给 Com 失败 InlineNotice 留页；busy 文案防连点。
- **构建**：`BUILD SUCCEEDED`；`install-today-112`（Locked，未 launch）；循环仍跑。
- 证据：`build-today-112.log` · `install-today-112.log` · `today-112-notes.txt`
- **下一 tick**：解锁验今天拉齐失败可重试 / 详情动作失败留页；可转向实质产品缺口（建议 PairCode 配对失败开口，或健康简报进页边角，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:10 · Pair-113 · 配对失败开口
缺口：`PairingView` 失败只抛系统串、无开口；地址未校验；`PairCodeSheet` 失败像空白无码可冒充。
- **PairingView**：失败旁白 + Companion `.broken`；校验地址/码；按钮「再试一次」；扫码带码有开口。
- **PairCodeSheet**：空失败开口；InlineNotice；空 code 勿当可用；「再试一次」。
- **构建**：`BUILD SUCCEEDED`；`install-pair-113`（Locked，未 launch）；循环仍跑。
- 证据：`build-pair-113.log` · `install-pair-113.log` · `pair-113-notes.txt`
- **下一 tick**：解锁验配对失败开口可重试；可转向实质产品缺口（建议健康页简报/评估进页失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:15 · Health-114 · 健康简报/评估进页失败开口
缺口：健康进页拉齐失败被说成「Garmin 还没到」；身体简报失败整块消失。
- **pullHealth**：曲线 + insight + today/next；失败 InlineNotice + 再试；有缓存「仍是上一版」。
- **区分**：只有真拉齐成功且无测量才说手表没到。
- **HealthBrief**：失败开口「还没读上」；loading 态。
- **构建**：`BUILD SUCCEEDED`；`install-health-114`（Locked，未 launch）；循环仍跑。
- 证据：`build-health-114.log` · `install-health-114.log` · `health-114-notes.txt`
- **下一 tick**：解锁验健康拉齐失败可重试；可转向实质产品缺口（建议等你收件箱进页失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:20 · Wait-115 · 等你收件箱进页失败开口
缺口：`WaitingSheet` 拉齐失败像「没有要拍板的」；与 `openWaitingInbox` 叠刷无失败开口。
- **pullWaiting**：等入口 busy 结束再判 errors；强制刷新走本路径；失败 InlineNotice + 再试。
- **空失败开口**：EmptyState「还没读上」勿当成无事项；有缓存失败「仍是上一版」。
- **构建**：`BUILD SUCCEEDED`；`install-wait-115`（Locked，未 launch）；循环仍跑。
- 证据：`build-wait-115.log` · `install-wait-115.log` · `wait-115-notes.txt`
- **下一 tick**：解锁验等你进页失败可重试；可转向实质产品缺口（建议语音窗开麦/转写失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:25 · Voice-116 · 语音开麦/转写失败开口
缺口：开麦/转写失败标题仍像「录音已保留」；错误只灰字旁注；未配对转写只 banner。
- **VoiceSessionPanel**：失败 InlineNotice + 开口标题；「再试开麦 / 重新转写」。
- **VoiceRecorder**：权限/开麦/转写错误人话；phase=.failed。
- **transcribeVoice**：无 api 时窗内 error + failed，勿只 banner。
- **构建**：`BUILD SUCCEEDED`；`install-voice-116`（Locked，未 launch）；循环仍跑。
- 证据：`build-voice-116.log` · `install-voice-116.log` · `voice-116-notes.txt`
- **下一 tick**：解锁验语音失败开口可重试；可转向实质产品缺口（建议工作 Composer 发送失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:30 · Composer-117 · 工作 Composer 发送失败开口
缺口：派活/续发失败只靠气泡旁注或首页灰 Caption；队列失败系统串；Composer 不抬头开口。
- **WorkComposer**：`work.note` → InlineNotice（首页+会话）；发送前清 note。
- **queue fail**：草稿保留 + 人话「没排进队列」。
- **failStart / submit rejected/uncertain**：Composer 同步开口；可「回到草稿」。
- **构建**：`BUILD SUCCEEDED`；`install-composer-117`（Locked，未 launch）；循环仍跑。
- 证据：`build-composer-117.log` · `install-composer-117.log` · `composer-117-notes.txt`
- **下一 tick**：解锁验工作发送失败开口；可转向实质产品缺口（建议主聊 Composer 发送失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:35 · Chat-118 · 主聊 Composer 发送失败开口
缺口：发送失败只靠气泡旁注/banner alert；未配对仍清空草稿再假排队。
- **chatComposerNote**：Composer 顶 InlineNotice；拒收/待核实人话开口。
- **未配对**：草稿保留，不假装发出。
- **回到草稿**：收回后 Composer 再开口说明。
- **构建**：`BUILD SUCCEEDED`；`install-chat-118`（Locked，未 launch）；循环仍跑。
- 证据：`build-chat-118.log` · `install-chat-118.log` · `chat-118-notes.txt`
- **下一 tick**：解锁验主聊发送失败开口；可转向实质产品缺口（建议主聊打断失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~04:55 · Interrupt-119 · 主聊打断失败开口
缺口：`interrupt` 失败只写 banner alert；未连上静默 return；页内无 InlineNotice / 可重试开口。
- **interrupt() → Bool**：`interruptNote`；未配对/API 失败人话；成功清 note。
- **ChatView**：忙碌条上方 InlineNotice；全部中断 /「停下这件」可再试；失败不假装已停。
- **构建**：`BUILD SUCCEEDED`；`install-interrupt-119`（Locked，未 launch）；循环仍跑。
- 证据：`build-interrupt-119.log` · `install-interrupt-119.log` · `interrupt-119-notes.txt`
- **下一 tick**：解锁验打断失败开口可重试；可转向实质产品缺口（建议主聊附件失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:00 · Attach-120 · 主聊附件/照片失败开口
缺口：选文件/照片/上传失败只写 banner alert；Composer 无窗内开口。
- **chatComposerNote**：选文件失败、照片读失败、超限/未配对/上传失败 → Composer InlineNotice；不假装已挂上。
- **busy**：`uploading` 仍锁「+」防连点。
- **构建**：`BUILD SUCCEEDED`；`install-attach-120`（Locked，未 launch）；循环仍跑。
- 证据：`build-attach-120.log` · `install-attach-120.log` · `attach-120-notes.txt`
- **下一 tick**：解锁验附件失败开口；可转向实质产品缺口（建议工作审批卡 / TaskHub 动作失败留页开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:00 · Task-121 · 任务详情 / 工作审批失败 InlineNotice
缺口：任务验收/补充/停止与工作审批失败多靠灰字 Caption + banner；错误细节不在卡上。
- **TaskDetailView**：failNote → InlineNotice，带错误文案；验收与补充区都开口。
- **WorkApprovalCard**：failNote → InlineNotice；失败不假装已批/已拒。
- **构建**：`BUILD SUCCEEDED`；`install-task-121`（Locked，未 launch）；循环仍跑。
- 证据：`build-task-121.log` · `install-task-121.log` · `task-121-notes.txt`
- **下一 tick**：解锁验任务/审批失败开口；可转向实质产品缺口（建议 Agency 目标动作失败 InlineNotice，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:00 · Agency-122 · 目标 / 主动性失败 InlineNotice
缺口：Agency 整理/交办、目标完成暂停、新建目标、保存安排多靠灰 Caption + banner。
- **AgencyDetail / GoalRow / GoalEditor / AgencySettings**：failNote → InlineNotice + 错误文案；失败不假跳/假保存。
- **构建**：`BUILD SUCCEEDED`；`install-agency-122`（Locked，未 launch）；循环仍跑。
- 证据：`build-agency-122.log` · `install-agency-122.log` · `agency-122-notes.txt`
- **下一 tick**：解锁验 Agency 失败开口；可转向实质产品缺口（建议航程补问失败 InlineNotice，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:00 · Case-123 · 航程验收补问失败 InlineNotice
缺口：验收区「让它补证据」失败只靠灰 Caption。
- **AcceptanceCard**：failNote → InlineNotice；失败不假装已催补证据。
- **构建**：`BUILD SUCCEEDED`；`install-case-123`（Locked，未 launch）；循环仍跑。
- 证据：`build-case-123.log` · `install-case-123.log` · `case-123-notes.txt`
- **下一 tick**：解锁验补问失败开口；可转向实质产品缺口（建议记忆确认灰字→InlineNotice 或账本笔记开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:00 · Mem-124 · 记忆确认失败 InlineNotice
缺口：记住/纠正/删掉失败只回弹纸片 + banner；页内无开口。
- **MemoryReview.actFailNote**：失败 InlineNotice（自动记忆页 + 文件夹页）；纸片回滚；不假装已写入/归档。
- **构建**：`BUILD SUCCEEDED`；`install-mem-124`（Locked，未 launch）；循环仍跑。
- 证据：`build-mem-124.log` · `install-mem-124.log` · `mem-124-notes.txt`
- **下一 tick**：解锁验记忆操作失败开口；可转向实质产品缺口（建议 Presence starter 失败窗内开口 / Threads 草稿失败，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:05 · Presence-125 · 空态 starter 发送失败开口
缺口：空对话 starter 发送失败只回弹按钮；Composer 可能不在视野，页内无开口。
- **ChatEmptyPresence.starterFail**：失败 InlineNotice；复用 `chatComposerNote`；可再点。
- **构建**：`BUILD SUCCEEDED`；`install-presence-125`（Locked，未 launch）；循环仍跑。
- 证据：`build-presence-125.log` · `install-presence-125.log` · `presence-125-notes.txt`
- **下一 tick**：解锁验空态 starter 失败开口；可转向实质产品缺口（建议工作侧栏会话跳转失败 / Matter 详情失败，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:05 · Matter-126 · 事项详情失败 InlineNotice
缺口：事项「交给 Com」/反馈/更正/静音/解绑失败多靠灰 Caption + banner。
- **MatterDetailView**：failNote → InlineNotice；失败不假跳聊天、不假装已反馈。
- **构建**：`BUILD SUCCEEDED`；`install-matter-126`（Locked，未 launch）；循环仍跑。
- 证据：`build-matter-126.log` · `install-matter-126.log` · `matter-126-notes.txt`
- **下一 tick**：解锁验事项失败开口；可转向实质产品缺口（建议 Search 定位失败窗内开口 / Artifact 下载失败，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:05 · Locate-127 · Search / 线索定位失败开口
缺口：`locateMessage` 历史拉失败与对不上一律含糊；线索点消息先关 sheet 再只弹 banner；搜索失败无「再试对准」。
- **locateNote**：区分历史没拉上 / 对不上；成功清 note。
- **SearchView**：失败 InlineNotice +「再试对准」；不关搜索页。
- **openThreadNode(msg)**：对准成功才收 sheet；等你/线索条显示 locateNote。
- **舞台「看回复」/ 主聊**：失败 InlineNotice，可再点。
- **构建**：`BUILD SUCCEEDED`；`install-locate-127`（Locked，未 launch）；循环仍跑。
- 证据：`build-locate-127.log` · `install-locate-127.log` · `locate-127-notes.txt`
- **下一 tick**：解锁验定位失败开口；可转向实质产品缺口（建议 Artifact 下载失败再试按钮，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:05 · Artifact-128 · 成果下载失败再试开口
缺口：下载失败只有文案「可以再点一次」；未配对/网络失败无明确再试；HTML 态保存失败是灰字。
- **ArtifactList**：失败 InlineNotice +「再试一次」；未配对保留 retryItem；不假装已打开。
- **HTMLPreview**：saveNote → InlineNotice。
- **构建**：`BUILD SUCCEEDED`；`install-artifact-128`（Locked，未 launch）；循环仍跑。
- 证据：`build-artifact-128.log` · `install-artifact-128.log` · `artifact-128-notes.txt`
- **下一 tick**：解锁验成果下载失败再试；可转向实质产品缺口（建议线索/动态点开失败或 Flow 划卡失败留页，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:10 · Flow-129 · 划卡 / 派活 / 动态核对失败留页
缺口：等你划卡失败仍用成功勾提示；事项「交给我办」失败静默；派活详情批准失败只 return；动态核对失败只回弹无文案。
- **WaitingSheet**：失败 handoff → InlineNotice（危险）；草稿/待办失败同款。
- **PendingNote**：事项交办 busy + 失败开口；卡留页可再试。
- **ProposalDetail**：failNote InlineNotice；批准/回绝失败不关页。
- **FeedDetailCard**：核对全失败 InlineNotice。
- **构建**：`BUILD SUCCEEDED`；`install-flow-129`（Locked，未 launch）；循环仍跑。
- 证据：`build-flow-129.log` · `install-flow-129.log` · `flow-129-notes.txt`
- **下一 tick**：解锁验划卡失败留页开口；可转向实质产品缺口（建议 Next 纸片动作失败 InlineNotice，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:10 · Next-130 · 下一步纸片 / 外屏 / 待核对失败开口
缺口：Next 卡失败 handoff 仍像灰提示；外屏 Glance 失败是 warning 字；UncertainCard 核对失败只回弹。
- **Next 卡**：失败 → InlineNotice；成功仍绿勾。
- **NextGlanceCard / UncertainCard**：失败 InlineNotice。
- **构建**：`BUILD SUCCEEDED`；`install-next-130`（Locked，未 launch）；循环仍跑。
- 证据：`build-next-130.log` · `install-next-130.log` · `next-130-notes.txt`
- **下一 tick**：解锁验下一步失败开口；可转向实质产品缺口（建议设置/断配对失败留页或归档旧任务失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:10 · Archive-131 · 归档旧任务 / 解除配对失败开口
缺口：全部归档部分失败仍像成功勾；`archiveStale` 一律 Bool；解除配对推送注销失败静默关设置。
- **archiveStale→(ok,fail)**：部分失败人话件数；全失败不假装已归档。
- **TaskHub**：失败 result → InlineNotice。
- **disconnect / ComPush.disable**：推送注销成败分开；本机已解但注销失败留页 InlineNotice。
- **构建**：`BUILD SUCCEEDED`；`install-archive-131`（Locked，未 launch）；循环仍跑。
- 证据：`build-archive-131.log` · `install-archive-131.log` · `archive-131-notes.txt`
- **下一 tick**：解锁验归档/解除配对失败开口；可转向实质产品缺口（建议连接器重授权失败或发送记录查回执强化，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:15 · Conn-132 · 断信源打开配置失败开口
缺口：断信源卡「去接上」拉 connectors 失败仍可能假开详情；无页内开口。
- **SourceBrokenNote**：load 失败 InlineNotice，卡留页可再点；不假装已打开配置。
- **构建**：`BUILD SUCCEEDED`；`install-conn-132`（Locked，未 launch）；循环仍跑。
- 证据：`build-conn-132.log` · `install-conn-132.log` · `conn-132-notes.txt`
- **下一 tick**：解锁验断信源打开失败开口；可转向实质产品缺口（建议健康/账本打开失败或权限授权失败开口，非 SoftPress），或等 ~07:20 Harden；**勿 SoftPress**。

### 2026-10-29 ~05:13 · Auth-133 · 权限授权 / 健康读 / 账本打开失败开口
缺口：设置点权限授权失败只落远处 `devices.note`；HealthCard 读失败像灰字；`openFinance` 失败 LedgerNote 无页内开口。
- **DeviceBridge.authorize→Bool**：拒绝/失败写人话 `note`，不假装已授权；读健康失败同款。
- **Settings**：authNote + authFailed → InlineNotice（危险）；通知授权失败仍危险口。
- **HealthCard**：含「没成/权限」→ InlineNotice，可再点「读取」。
- **financeOpenNote**：`openFinance` 拉齐失败写入；LedgerNote 页内 InlineNotice；FinanceDetail 当月拉齐成功清 note。
- **构建**：`BUILD SUCCEEDED`；`install-auth-133`（Locked，未 launch）；循环仍跑。
- 证据：`build-auth-133.log` · `install-auth-133.log` · `auth-133-notes.txt`
- **下一 tick**：解锁验设置授权失败 / 健康读失败 / 账本打开失败开口；可转向实质产品缺口（建议工作侧栏点开会话失败开口或连接器「检查连接」假成功边角，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:16 · Session-134 · 工作侧栏点开会话失败开口
缺口：侧栏点开即关栏 + `open()` 清空 history；拉齐失败却写「历史缓存 ·」像还在看旧内容；摘录 load 失败静默；坏 id 仍关栏。
- **WorkSidebarLayer.open**：缺/空 id 留侧栏 + failNote；对上才关栏。
- **WorkSessionModel.refresh**：首开失败人话「会话/摘录没读上」；已有内容则「刷新没成、下面仍是刚才的」；摘录 load 失败不再静默。
- **WorkChat**：失败 InlineNotice（危险）+ 打开中 busy；空态仅在 loaded 且无 fail。
- **构建**：`BUILD SUCCEEDED`；`install-session-134`（Locked，未 launch）；循环仍跑。
- 证据：`build-session-134.log` · `install-session-134.log` · `session-134-notes.txt`
- **下一 tick**：解锁验侧栏点开会话/摘录失败开口；可转向实质产品缺口（建议连接器「检查连接」假成功——load 失败勿报已核验，或 sync 结果未核验边角，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:18 · Conn-135 · 检查连接假成功（load 失败勿报已核验）
缺口：`ConnectionDetail.update` 忽略 sync 回包；`load` 失败仍可能凭陈旧 `connected` 报「连接已核验」；断开同理空口报已停止。
- **applyCheckVerdict**：仅 connectors 拉齐且 status=connected →「连接已核验」；load 失败即使用 sync 回报 connected 也只提示回列表刷新，不说已核验；失败带 error 文案。
- **applyDisconnectVerdict**：load 失败或未变 disconnected → 危险开口，不假装已断开。
- **构建**：`BUILD SUCCEEDED`；`install-conn-135`（Locked，未 launch）；循环仍跑。
- 证据：`build-conn-135.log` · `install-conn-135.log` · `conn-135-notes.txt`
- **下一 tick**：解锁验检查连接/断开诚实开口；可转向实质产品缺口（建议发送记录/出站重试失败开口，或工作停止结果假成功边角，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:20 · Outbox-136 · 发送记录 / 查回执失败开口
缺口：主聊「查回执」查完仍 uncertain 无 Composer 开口；未配对 deliver 静默 return；查回执 early-return 可能卡在 checking；设置发送记录失败文案不含 detail。
- **deliver→DeliveryState?**：未配对 / unknown / 工作 404 均落 uncertain + 人话 note；返回最终态。
- **deliverWork**：未配对同款开口。
- **Chat 查回执**：仍待核实 / 拒收 → `chatComposerNote` InlineNotice；已受理清 note。
- **设置发送记录**：receiptNote 带 detail；拒收可恢复草稿提示。
- **构建**：`BUILD SUCCEEDED`；`install-outbox-136`（Locked，未 launch）；循环仍跑。
- 证据：`build-outbox-136.log` · `install-outbox-136.log` · `outbox-136-notes.txt`
- **下一 tick**：解锁验查回执失败开口；可转向实质产品缺口（建议工作停止结果假成功边角，或审批语音/卡片双路径失败留页，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:22 · Stop-137 · 工作停止假成功边角
缺口：`action(/stop)` HTTP 200 即当真停住；失败 note 被 3s refresh 清空成「没事」；结束/置顶同款假成功风险。
- **stop/end**：成功后 refresh + 若仍 `running` 再等 700ms 复核；仍在跑 → 危险 note，不假装已停/已结束；未配对开口。
- **togglePin**：刷新后核对 pinned 是否真变。
- **clearOpenFailNote**：轮询成功只清打开/刷新失败文案，保留停止/结束/发送失败开口。
- **构建**：`BUILD SUCCEEDED`；`install-stop-137`（Locked，未 launch）；循环仍跑。
- 证据：`build-stop-137.log` · `install-stop-137.log` · `stop-137-notes.txt`
- **下一 tick**：解锁验停止后仍在跑会开口；可转向实质产品缺口（建议审批语音/卡片双路径失败留页，或主聊流式断线恢复假成功，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:24 · Approval-138 · 审批语音/卡片双路径失败留页
缺口：语音审批失败只靠 banner；关语音窗后卡片无开口；没听清同款；卡片与语音失败态不共享。
- **approvalFailNote / approvalFailID**：双路径共享；`rememberApprovalFail` 写 note + `voice.error` + phase=failed；成功 `clearApprovalFail`。
- **answerApproval**：未配对/网络失败保留 pendingApproval；语音窗 InlineNotice 可再说。
- **WorkApprovalCard**：展示本地 failNote 或共享 note；提交失败同步写入共享；未配对开口。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-approval-138`（Locked，未 launch）；循环仍跑。
- 证据：`build-approval-138.log` · `install-approval-138.log` · `approval-138-notes.txt`
- **下一 tick**：解锁验语音批失败回卡仍开口；可转向实质产品缺口（建议主聊流式断线恢复假成功，或配对码刷新失败开口，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:26 · Stream-139 · 主聊流式断线恢复假成功
缺口：SSE 字节流正常结束仍保持 `streaming=true`，轮询以为在线；HTTP 拉齐清掉「正在恢复」；主聊无页内开口。
- **markStreamDown**：正常结束与 throw 都清 streaming、舞台离线、写 `streamNote`（不假装已恢复）。
- **load**：不因 conversation HTTP 成功清流式断线 errors / streamNote。
- **receive**：仅 snapshot/update 才算恢复并清 note；心跳不算。
- **ChatView**：streamNote InlineNotice；设置「重连中（缓存）」；舞台 offline 文案改诚实。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-stream-139`（Locked，未 launch）；循环仍跑。
- 证据：`build-stream-139.log` · `install-stream-139.log` · `stream-139-notes.txt`
- **下一 tick**：解锁验断线主聊开口且拉齐不清；可转向实质产品缺口（建议配对码刷新失败开口，或分享收件箱加入草稿假成功边角，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:28 · Pair-140 · 配对码过期作废 + 换新失败开口
缺口：倒计时归零后旧码/二维码/分享链仍可点，像还能用；无自动换新失败开口。
- **usable**：仅 code 非空且 seconds>0 才展示 QR/码/ShareLink；过期立刻清空 code。
- **到期**：自动换新一次；失败 InlineNotice（旧码已作废）；不死循环打接口。
- **手动重试**：secondaryAction（未再铺 SoftPress）。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-pair-140`（Locked，未 launch）；循环仍跑。
- 证据：`build-pair-140.log` · `install-pair-140.log` · `pair-140-notes.txt`
- **下一 tick**：解锁验过期作废与换新失败开口；可转向实质产品缺口（建议分享收件箱加入草稿假成功边角，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:30 · Share-141 · 分享加入草稿假成功
缺口：上传/落盘未核就 dismiss；`remove` 用 try? 失败仍像已清；空分享可走成功路径。
- **importDraft**：拒空分享；附件存在且非空；上传回 id；Vault+内存草稿核对通过才进聊天。
- **ShareInbox.remove→Bool**：删不掉则 chatComposerNote 说明收件箱可能还挂着；分享失败留页可重试。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-share-141`（Locked，未 launch）；循环仍跑。
- 证据：`build-share-141.log` · `install-share-141.log` · `share-141-notes.txt`
- **下一 tick**：解锁验加入草稿失败留页 / 成功才进聊天；可转向实质产品缺口（建议灵动岛/小组件状态假成功，或设备回执撤销失败开口，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:31 · Receipt-142 · 设备回执撤销失败开口
缺口：撤销未验证仍保留 `undo_requested`，按钮假锁「已申请撤销」；未配对/无 undo 步骤静默或假锁。
- **undo**：仅 verified+succeeded 保留占坑；否则 `clearUndoClaim` 回滚可再点。
- **未配对 / 无撤销步骤 / 网络失败**：危险 InlineNotice +「不会假装已撤销」；解锁失败另说。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-receipt-142`（Locked，未 launch）；循环仍跑。
- 证据：`build-receipt-142.log` · `install-receipt-142.log` · `receipt-142-notes.txt`
- **下一 tick**：解锁验撤销失败可再试；可转向实质产品缺口（建议灵动岛/小组件状态假成功边角，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:34 · Live-143 · 灵动岛/小组件状态假成功
缺口：`push` 无活 Activity 仍推进 `last` → 之后不再重开/更新却以为岛上已是最新；`ensure` 吞掉系统关闭实时活动与 `Activity.request` 失败；小组件 Keychain `save` 失败不 reload（好）但无开口。
- **push / enterBackground**：仅有活岛才写 `last`；空列表清 `last`，下次 `ensure` 重开。
- **ensure**：关实时活动 / request 失败 → `liveActivityNote`；成功清 note。
- **updateStatusWidget**：save 失败 → `widgetUpdateNote`（不假 reload）；成功/解配对清 note。
- **设置 › 平台能力**：InlineNotice 开口两则 note。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-live-143`（Locked，未 launch）；循环仍跑。
- 证据：`build-live-143.log` · `install-live-143.log` · `live-143-live-activity-fake-success.md`
- **下一 tick**：解锁验设置关实时活动→平台能力开口 / 重开后 note 清；可转向实质产品缺口（建议推送 token 上报失败开口——`ComPush.registerToken` catch 只翻 ready=false 无用户可见提示，或工作会话草稿 Vault 写入失败开口，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:36 · Push-144 · 推送 token 上报失败开口
缺口：`registerToken` catch 只翻 ready=false；`notificationRefreshStatus` 有写无显；设置「开启新消息通知」成功只说通知已开，人以为远程推送已通。
- **ComPush.registerToken→Bool**：失败/未配置写清 status；成功「系统推送已接通」；Vault 存 token 失败 / 系统 register 失败同写。
- **ComNotifications.enable→(allowed, note)**：权限开了但上报失败 note 诚实；`requestIfNeeded` 补报一次。
- **设置 › 主动消息通知**：展示 note；未 ready「再试一次上报」；进页带回上次 status。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-push-144`（Locked，未 launch）；循环仍跑。
- 证据：`build-push-144.log` · `install-push-144.log` · `push-144-token-register-fail.md`
- **下一 tick**：解锁验开通知后上报失败开口 / 再试上报；可转向实质产品缺口（建议工作会话草稿 Vault 写入失败开口——`sessionDraft` `try? SecureVault.save` 静默丢字，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:38 · Draft-145 · 工作会话草稿 Vault 读写失败开口
缺口：`sessionDraft` didSet `try? save` 静默丢字；`open` `try? load` 失败变空框像「没写过」。
- **draftPersistNote**：存失败 / 读失败人话；作曲器 InlineNotice（`work-draft-persist-fail`）。
- **suppressDraftPersist**：灌回时不重写，避免盖掉「没读上」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-draft-145`（Locked，未 launch）；循环仍跑。
- 证据：`build-draft-145.log` · `install-draft-145.log` · `draft-145-work-draft-vault.md`
- **下一 tick**：解锁验草稿存/读失败开口；可转向实质产品缺口（建议主聊 AppCache 草稿落盘失败开口，或连接诊断写入失败开口，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:40 · Cache-146 · 主聊 AppCache 草稿落盘/恢复失败开口
缺口：`persistNow` 缓存失败只写顶栏 banner；草稿读失败并进总 catch，易空框假「没写过」。连接诊断写入仅 DEBUG，本 tick 不做。
- **cachePersistNote**：存/读失败人话；Chat 作曲器 InlineNotice（`chat-cache-persist-fail`）。
- 草稿+附件单独 Vault 恢复；落盘成功/解配对清 note。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-cache-146`（Locked，未 launch）；循环仍跑。
- 证据：`build-cache-146.log` · `install-cache-146.log` · `cache-146-appcache-draft.md`
- **下一 tick**：解锁验主聊草稿存/读失败开口；可转向实质产品缺口（建议语音 capture Vault 写入失败开口，或设备能力刷新失败开口，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:42 · Voice-147 · 语音 capture Vault 读写失败开口
缺口：`saveCapture` / cancel / 冷启动 load 用 `try?`；落盘失败仍像已保留；元数据在文件没了也假保留。设备能力授权/离线已有 note——本 tick 做语音。
- **saveCapture**：失败 → `voice.error`「不会假装已保留」
- **init load**：抛错开口；有元数据无文件 → 清 id + 开口
- **cancel 清元数据失败**：开口可能残留旧提示
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-voice-147`（Locked，未 launch）；循环仍跑。
- 证据：`build-voice-147.log` · `install-voice-147.log` · `voice-147-capture-vault.md`
- **下一 tick**：解锁验录音元数据存/读失败开口；可转向实质产品缺口（建议设备操作回执/invocation Vault 写入失败，或自动化启停失败开口，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:44 · Invoke-148 · 设备操作 invocation Vault 诚实
缺口：`try? load` 把损坏当没有 → 可能重跑；`save`+`send` 捆在一起，存失败却说「待补传」。自动化卡无启停控件——本 tick 做 invocation。
- **loadInvocation**：missing / corrupt / value；corrupt 回报 unknown，不重跑。
- 结果落盘与 socket 回传分开；note 区分没落盘 / 没送出 / 两者都没。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-invoke-148`（Locked，未 launch）；循环仍跑。
- 证据：`build-invoke-148.log` · `install-invoke-148.log` · `invoke-148-invocation-vault.md`
- **下一 tick**：解锁验连接区坏账/落盘失败 note；可转向实质产品缺口（建议健康同步开关失败开口，或分享 App Group 列表失败边角，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:45 · Sync-149 · 健康/联系人同步开关诚实
缺口：`updateSync` 只写 UserDefaults + connect；开关立刻亮。未配对 / 通道失败 / 未授权时人以为 mini 已按新范围同步。分享列表失败已有 loadAll 开口——本 tick 做同步开关。
- **syncNote**：未配对、通道失败、健康/联系人未授权分别开口；设置 InlineNotice。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-sync-149`（Locked，未 launch）；循环仍跑。
- 证据：`build-sync-149.log` · `install-sync-149.log` · `sync-149-health-sync-toggle.md`
- **下一 tick**：解锁验同步开关 syncNote；可转向实质产品缺口（建议分享收件箱角标用 `all()` 吞掉 App Group 错误——有货却不提示打开，或菜单打开失败开口，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:48 · Share-150 · 分享收件箱角标 / App Group 诚实
缺口：前台 `ShareInbox.all()` 吞掉 App Group/目录失败 → 有待处理分享也不弹、不提示。菜单打开已有 busy——本 tick 做角标。
- **refreshShareInboxPresence**：`loadAll`；失败 → `shareInboxNote` + 主聊「打开收件箱」；有可读条目仍自动开 sheet。
- ShareInboxView 拉齐成功清 note；失败回写 note。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-share-150`（Locked，未 launch）；循环仍跑。
- 证据：`build-share-150.log` · `install-share-150.log` · `share-150-inbox-badge.md`
- **下一 tick**：解锁验 App Group 异常时主聊开口；可转向实质产品缺口（建议菜单账本/记忆打开拉新失败表面强化，或深链 share 在 Group 坏时仍开口，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:49 · Menu-151 · 菜单记忆/账本打开失败 + 深链 share
缺口：openMemory 失败无 model 级 note；financeOpenNote 菜单看不见；`com-eddie://share` 只塞草稿不探测 App Group。
- **memoryOpenNote**；菜单记忆/账本 InlineNotice。
- **openShareInbox**：refresh + 强制 sheet；深链 share / 设置 / 主聊 CTA 共用。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-menu-151`（Locked，未 launch）；循环仍跑。
- 证据：`build-menu-151.log` · `install-menu-151.log` · `menu-151-memory-finance-share.md`
- **下一 tick**：解锁验菜单失败 notice / 深链 share 开口；可转向实质产品缺口（建议菜单连接器/动态打开失败 note，或配对深链边角，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:52 · Menu-152 · 菜单连接器/动态打开失败
缺口：openConnectors / openActivityFeed 拉新失败无 model 级 note；菜单关了人以为已读上。
- **connectorsOpenNote** / **activityOpenNote**；菜单 InlineNotice；页内成功清 note。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-menu-152`（Locked，未 launch）；循环仍跑。
- 证据：`build-menu-152.log` · `install-menu-152.log` · `menu-152-connectors-activity.md`
- **下一 tick**：解锁验连接器/动态菜单失败 notice；可转向实质产品缺口（建议配对深链边角——无 code/无 base/已配对开口，或等你/搜索打开失败 note，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:54 · Pair-153 · 配对深链边角
缺口：`com-eddie://pair` 无 code 静默；有 code 无 base 只塞码无开口；已配对仍写 pendingPairCode。
- **applyPairDeepLink**：已配对 banner 且不写 pending；无码/无 base → banner + pendingPairNote；配对页 warning InlineNotice。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-pair-153`（Locked，未 launch）；循环仍跑。
- 证据：`build-pair-153.log` · `install-pair-153.log` · `pair-153-deeplink.md`
- **下一 tick**：解锁验配对深链开口；可转向实质产品缺口（建议等你/搜索打开失败 note，或设置打开 /status 失败 note，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:55 · Wait-154 · 等你/搜索打开失败
缺口：openWaitingInbox / openSearch 拉新失败无 model 级 note；菜单/主聊关 sheet 后像没事。
- **waitingOpenNote**（菜单）；**searchOpenNote**（主聊 CTA）；页内成功清 note。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-wait-154`（Locked，未 launch）；循环仍跑。
- 证据：`build-wait-154.log` · `install-wait-154.log` · `wait-154-search-open.md`
- **下一 tick**：解锁验等你菜单 / 搜索主聊开口；可转向实质产品缺口（建议设置打开 /status 失败 note，或设置菜单 notice，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:57 · Set-155 · 设置打开 /status 失败
缺口：openSettings 拉 /status 失败无 model 级 note；菜单关了人以为服务器现况已读上。
- **settingsOpenNote**；菜单 InlineNotice；设置页成功清 note。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-set-155`（Locked，未 launch）；循环仍跑。
- 证据：`build-set-155.log` · `install-set-155.log` · `set-155-settings-open.md`
- **下一 tick**：解锁验设置菜单失败 notice；可转向实质产品缺口（建议语音深链未配对开口，或审批深链失败表面，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~05:59 · Approval-156 · 审批深链失败表面
缺口：openApproval / 通知缺 sid 仍切工作 Tab 静默；无页内开口。
- **approvalDeepLinkNote**；工作页 InlineNotice +「打开等你」；通知与深链共用 `openApproval(sid:)`。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-approval-156`（Locked，未 launch）；循环仍跑。
- 证据：`build-approval-156.log` · `install-approval-156.log` · `approval-156-deeplink.md`
- **下一 tick**：解锁验审批缺 sid 工作页开口；可转向实质产品缺口（建议语音深链未配对在配对页 leave note——今日仅 banner，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~06:01 · Voice-157 · 语音深链未配对配对页 note
缺口：openVoice 未配对只设 banner；配对页无留页 note，alert 关掉像没事。
- **pairGateNote**；配对页 InlineNotice；配对成功清 note。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-voice-157`（Locked，未 launch）；循环仍跑。
- 证据：`build-voice-157.log` · `install-voice-157.log` · `voice-157-unpaired-pair-note.md`
- **下一 tick**：解锁验未配对语音深链配对页 note；可转向实质产品缺口（建议 cases 深链 loadFeed 失败 note，或 today 深链边角，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~06:02 · Cases-158 · cases 深链 loadFeed 失败
缺口：`com-eddie://cases` 调 loadFeed 忽略结果；失败无 activityOpenNote。
- **openCasesDeepLink** + **beginActivityFeedLoad**（与菜单动态同路）；下一步页留 note +「打开动态」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-cases-158`（Locked，未 launch）；循环仍跑。
- 证据：`build-cases-158.log` · `install-cases-158.log` · `cases-158-deeplink-feed.md`
- **下一 tick**：解锁验 cases 深链失败开口；可转向实质产品缺口（建议 today 深链刷主聊/简报边角，或 plan 深链拉齐失败 note，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~06:05 · Plan-159 · plan 深链拉齐失败
缺口：`com-eddie://plan` 拉 next/plan 忽略失败；下一步像已读上。
- **openPlanDeepLink** + **planOpenNote**；TomorrowPlanCard 等 planOpening；下一步页 InlineNotice。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-plan-159`（Locked，未 launch）；循环仍跑。
- 证据：`build-plan-159.log` · `install-plan-159.log` · `plan-159-deeplink.md`
- **下一 tick**：解锁验 plan 深链失败开口；可转向实质产品缺口（建议 today 深链刷主聊 conversation 失败 note，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~06:07 · Today-160 · today 深链刷主聊失败
缺口：`com-eddie://today` 只切 chat Tab，不刷 conversation，失败无开口。
- **openTodayDeepLink**：load conversation；失败 **todayOpenNote** + 主聊「再刷主聊」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-today-160`（Locked，未 launch）；循环仍跑。
- 证据：`build-today-160.log` · `install-today-160.log` · `today-160-deeplink-chat.md`
- **下一 tick**：解锁验 today 深链主聊失败开口；可转向实质产品缺口（建议其它深链/入口 silent-fail，非 SoftPress）；**现在不要 Harden**（等 ~07:20）；**勿 SoftPress**。

### 2026-10-29 ~06:09 · Approval-161 · 审批仅 id→等你；通知无 id 刷主聊
缺口：Bark `approval?id=` 无 sid 硬开工作页；通知无 comMessageID 只切 chat 不刷。
- 仅审批 id → **openWaitingInbox** + **approvalDeepLinkNote**（等你页可见）。
- 无 message id → **openTodayDeepLink**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-approval-161`（Locked，未 launch）；循环仍跑。
- 证据：`build-approval-161.log` · `install-approval-161.log` · `approval-161-id-only.md`
- **下一 tick**：解锁验审批仅 id / 无消息 id 通知；可继续 silent-fail 扫尾或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:10 · Notify-162 · 通知审批静默 + 线索空 id
缺口：`resolveApproval` 无 token/空 id 静默；`openThreadNode` 空 id 假打开。
- resolveApproval 失败 **post banner**；openThreadNode 空 id 开口不弹空 sheet。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-notify-162`（Locked，未 launch）；循环仍跑。
- 证据：`build-notify-162.log` · `install-notify-162.log` · `notify-162-resolve-thread.md`
- **下一 tick**：解锁验通知批准失败 banner / 空线索开口；可继续 silent-fail 扫尾或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:12 · Finance-163 · 记账回执后账本刷失败
缺口：SSE「已记」后 fire-and-forget load finance；失败无开口。
- load 失败写 **financeOpenNote**；主聊 InlineNotice +「打开账本」。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-finance-163`（Locked，未 launch）；循环仍跑。
- 证据：`build-finance-163.log` · `install-finance-163.log` · `finance-163-receipt-refresh.md`
- **下一 tick**：解锁验已记回执后账本失败开口；可继续 silent-fail 扫尾或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:14 · Case-164 · 航程动作后刷失败 + 会话入口 refresh
缺口：case 动作成功后 load 失败静默；selectedSession 不立刻 refresh。
- 送达/标完成/停止成功但详情没刷上 → **actFail**；selectedSession → 立刻 **work.refresh**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-case-164`（Locked，未 launch）；循环仍跑。
- 证据：`build-case-164.log` · `install-case-164.log` · `case-164-reload-after-act.md`
- **下一 tick**：解锁验航程动作后刷失败 / 会话跳转；可继续 silent-fail 扫尾或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:16 · Memory-165 · 纠正/核对后列表刷失败
缺口：记忆纠正与 activityVerdict 成功后 load 失败无开口。
- 纠正已存但列表没刷 → **memoryOpenNote**；核对已记但双路没刷 → **activityOpenNote**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-memory-165`（Locked，未 launch）；循环仍跑。
- 证据：`build-memory-165.log` · `install-memory-165.log` · `memory-165-save-reload.md`
- **下一 tick**：解锁验纠正/核对后列表失败开口；可继续 silent-fail 扫尾或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:18 · Matter-166 · 事项交给 Com + 流程表刷失败
缺口：事项「交给 Com」后 refresh(.chat) 吞 conversation 失败；排流程表后 load next 静默。
- 交给 Com → **openTodayDeepLink**（失败 todayOpenNote）；流程表已请出但下一步没刷 → **error** 开口。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-matter-166`（Locked，未 launch）；循环仍跑。
- 证据：`build-matter-166.log` · `install-matter-166.log` · `matter-166-handoff-runsheet.md`
- **下一 tick**：解锁验交给 Com / 排表刷失败开口；可继续 silent-fail 扫尾或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:20 · Case-167 · 航程插一句后详情刷失败
缺口：caseSend 成功后 load 详情失败静默；草稿已清却无新一句。
- 话已送上但详情没刷 → **actFail** 开口。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-case-167`（Locked，未 launch）；循环仍跑。
- 证据：`build-case-167.log` · `install-case-167.log` · `case-167-send-reload.md`
- **下一 tick**：解锁验插一句后刷失败开口；可继续 silent-fail（如 MemoryFolder 下拉失败）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:21 · Folder-168 · MemoryFolder 下拉刷失败
缺口：夹子页 `.refreshable` 吞 memory/inbox 失败，旧纸片无开口。
- 下拉后列表或待确认没刷上 → **refreshFailNote** InlineNotice。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-folder-168`（Locked，未 launch）；循环仍跑。
- 证据：`build-folder-168.log` · `install-folder-168.log` · `folder-168-refresh-fail.md`
- **下一 tick**：解锁验夹子下拉失败开口；可继续 silent-fail（LearnedMemory 下拉失败）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:23 · Learned-169 · LearnedMemory 下拉刷失败
缺口：自动记忆页 `.refreshable` 吞 inbox load 失败，旧纸片无开口。
- 下拉后 inbox 没刷上 → **refreshFailNote** InlineNotice。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-learned-169`（Locked，未 launch）；循环仍跑。
- 证据：`build-learned-169.log` · `install-learned-169.log` · `learned-169-refresh-fail.md`
- **下一 tick**：解锁验自动记忆下拉失败开口；可继续 silent-fail（ActivityFeed 下拉 / Goal 创建后列表）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:24 · Goal-170 · 创建成功后 agency 拉齐失败
缺口：createPersonalGoal mutate 成功后 load agency 失败静默；列表可能无新目标。
- load 失败 → 乐观并入 goal + **agencyGoalsNote**；下拉成功清 note。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-goal-170`（Locked，未 launch）；循环仍跑。
- 证据：`build-goal-170.log` · `install-goal-170.log` · `goal-170-create-reload.md`
- **下一 tick**：解锁验建目标后刷失败开口；可继续 silent-fail（AgencySettings 保存后拉齐失败）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:26 · Agency-171 · Settings 保存后拉齐失败
缺口：saveAgencySettings 成功后 load 失败仍 dismiss，像已拉齐。
- load 失败 → 乐观写入 settings、返回 false；页内 **failNote** 留页。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-agency-171`（Locked，未 launch）；循环仍跑。
- 证据：`build-agency-171.log` · `install-agency-171.log` · `agency-171-settings-reload.md`
- **下一 tick**：解锁验保存安排后刷失败开口；可继续 silent-fail（agencyAction 暂停/完成后再拉齐）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:27 · Agency-172 · 暂停/完成后再拉齐失败
缺口：pause/resume/complete 成功后 load agency 失败静默。
- load 失败 → 乐观改 status + **agencyGoalsNote**；GoalRow 行内 failNote。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-agency-172`（Locked，未 launch）；循环仍跑。
- 证据：`build-agency-172.log` · `install-agency-172.log` · `agency-172-action-reload.md`
- **下一 tick**：解锁验暂停/完成后刷失败开口；可继续 silent-fail（dismissTask 归档后 tasks 拉齐 / discuss 后主聊刷失败）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:29 · Task-173 · 归档后 tasks 拉齐失败
缺口：dismissTask 成功后 load tasks 失败静默；划掉仍报「已归档」像列表已齐。
- load 失败 → 乐观 cancelled + **tasksOpenNote**；任务页/划掉回执开口。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-task-173`（Locked，未 launch）；循环仍跑。
- 证据：`build-task-173.log` · `install-task-173.log` · `task-173-dismiss-reload.md`
- **下一 tick**：解锁验归档后刷失败开口；可继续 silent-fail（agency discuss 后主聊刷失败 / TaskDetail 指令后 refresh）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:31 · Discuss-174 · agency discuss 后主聊刷失败
缺口：discuss 成功后 refresh(.chat) 吞 conversation 失败；跳主聊无开口。
- discuss 后显式 load conversation；失败 → **todayOpenNote**（已交给 Com / 不会假装派活已显示）。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-discuss-174`（Locked，未 launch）；循环仍跑。
- 证据：`build-discuss-174.log` · `install-discuss-174.log` · `discuss-174-chat-reload.md`
- **下一 tick**：解锁验交给 Com 后主聊失败开口；可继续 silent-fail（TaskDetail 指令后 refresh.doing 失败）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:33 · Detail-175 · TaskDetail 指令后刷失败
缺口：mutate 成功后 refresh(.doing) 吞 tasks 失败；补充框已清、详情仍旧。
- refresh 后再核 load(tasks)；失败 → **failNote**；仅刷上才清补充框。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-detail-175`（Locked，未 launch）；循环仍跑。
- 证据：`build-detail-175.log` · `install-detail-175.log` · `detail-175-command-reload.md`
- **下一 tick**：解锁验指令后刷失败开口；可继续 silent-fail（TaskDetail 进页/下拉 tasks 失败）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:34 · Detail-176 · TaskDetail 进页/下拉失败
缺口：进页 `.task` / 下拉 `.refreshable` 吞 tasks 失败，详情像已最新。
- reloadTasks 失败 → **loadFailNote** + 再试；下拉先 refresh(.doing) 再核。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-detail-176`（Locked，未 launch）；循环仍跑。
- 证据：`build-detail-176.log` · `install-detail-176.log` · `detail-176-load-refresh.md`
- **下一 tick**：解锁验进页/下拉失败开口；可继续 silent-fail（Chat 下拉 refresh.chat 失败 / prepare 后 agency 拉齐）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:36 · Chat-177 · 下拉 refresh(.chat) 失败
缺口：Chat `.refreshable` 与各处 refresh(.chat) 吞 conversation 失败。
- refresh(.chat) 失败 → **todayOpenNote**（主聊已有 InlineNotice + 再刷）。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-chat-177`（Locked，未 launch）；循环仍跑。
- 证据：`build-chat-177.log` · `install-chat-177.log` · `chat-177-pull-refresh.md`
- **下一 tick**：解锁验主聊下拉失败开口；可继续 silent-fail（Next 下拉 / refresh(.next) 失败）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:38 · Next-178 · 下拉 / refresh(.next) 失败
缺口：refresh(.next) 吞 next/plan；下拉 refreshNext 失败仅 banner；activity 静默。
- refresh(.next) / 整理失败 → **planOpenNote**；待核对刷失败 → **activityOpenNote**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-next-178`（Locked，未 launch）；循环仍跑。
- 证据：`build-next-178.log` · `install-next-178.log` · `next-178-pull-refresh.md`
- **下一 tick**：解锁验下一步下拉/菜单刷新失败开口；可继续 silent-fail（Health / Work refresh 失败）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:40 · Work-179 · refresh(.work) 失败
缺口：refresh(.work) 吞 projects/sessions；派活后/进页侧栏可能无新会话无开口。Health 页内 pull 已有 failNote，本轮修 Work。
- refresh(.work) → **workOpenNote**；WorkView 顶栏 + 再拉；进页走 refresh(.work)。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-work-179`（Locked，未 launch）；循环仍跑。
- 证据：`build-work-179.log` · `install-work-179.log` · `work-179-refresh-fail.md`
- **下一 tick**：解锁验工作侧栏刷失败开口；可继续 silent-fail（refresh(.health) 菜单刷新 / refreshHealthInsight）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:42 · Health-180 · refresh(.health) / insight 失败
缺口：refresh(.health) 吞 range/insight；refreshHealthInsight 失败仅 banner / 假 running。
- refresh(.health) / 评估失败 → **healthOpenNote**；HealthView 顶栏开口。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-health-180`（Locked，未 launch）；循环仍跑。
- 证据：`build-health-180.log` · `install-health-180.log` · `health-180-refresh-fail.md`
- **下一 tick**：解锁验健康菜单刷新/评估失败开口；可继续 silent-fail（refresh(.doing) 菜单刷新）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:44 · Doing-181 · refresh(.doing) 菜单刷新失败
缺口：refresh(.doing) 吞 flow + today + automations；菜单刷新无开口。
- today/automations 失败 → **doingOpenNote**；TodayView 顶栏开口。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-doing-181`（Locked，未 launch）；循环仍跑。
- 证据：`build-doing-181.log` · `install-doing-181.log` · `doing-181-refresh-fail.md`
- **下一 tick**：解锁验今天菜单刷新失败开口；可继续 silent-fail（Today 下拉 refreshHot / nextAction discuss）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:46 · Hot-182 · Today 下拉 refreshHot 失败
缺口：下拉调 refreshHot() 无 force、忽略失败；热点卡不知父级下拉失败。
- 下拉 **force:true**；失败 → **hotOpenNote**；HotBoardCard 显示。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-hot-182`（Locked，未 launch）；循环仍跑。
- 证据：`build-hot-182.log` · `install-hot-182.log` · `hot-182-pull-refresh.md`
- **下一 tick**：解锁验今天下拉热点失败开口；可继续 silent-fail（Today 下拉 next 失败 / nextAction discuss）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:48 · Today-next-183 · Today 下拉 next 失败
缺口：下拉/进页吞 load(/personal/next)；「我说几句」简报像已齐。
- pullTodayNext → **todayNextOpenNote**；ScheduleAdvice 开口。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-today-next-183`（Locked，未 launch）；循环仍跑。
- 证据：`build-today-next-183.log` · `install-today-next-183.log` · `today-next-183-pull-fail.md`
- **下一 tick**：解锁验今日简报刷失败开口；可继续 silent-fail（nextAction discuss 后主聊）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:50 · Next-act-184 · discuss 后 next 列表拉齐失败
缺口：nextAction 成功后 load next 失败静默；回下一步卡可能还在。
- load 失败 → 乐观收卡 + **planOpenNote**（已交给 Com / 已标做完…列表没刷齐）。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-next-act-184`（Locked，未 launch）；循环仍跑。
- 证据：`build-next-act-184.log` · `install-next-act-184.log` · `next-act-184-discuss-reload.md`
- **下一 tick**：解锁验交给 Com 后列表刷失败开口；可继续 silent-fail（runNextAction bookkeep/calendar 后）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:52 · Run-next-185 · 记账/日程送达后列表拉齐
缺口：bookkeep 不预热 finance；calendar 预热 today 失败静默。
- 记账后 finance 失败 → **financeOpenNote**；日程后 today 失败 → **doingOpenNote**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-run-next-185`（Locked，未 launch）；循环仍跑。
- 证据：`build-run-next-185.log` · `install-run-next-185.log` · `run-next-185-bookkeep-calendar.md`
- **下一 tick**：解锁验记账/日程后刷失败开口；可继续 silent-fail 扫尾或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:55 · Todo-186 · 加待办/交给我办后列表拉齐
缺口：nextToTodo / delegateNext / delegateTodo 成功后 load 吞失败；卡可能还在、今天/等你/航程像已齐。
- nextToTodo：next 失败 → 乐观收卡 + **planOpenNote**；today → **doingOpenNote**。
- delegateNext：next/cases 失败 → **planOpenNote**（同口）。
- delegateTodo：waiting/cases → **waitingOpenNote**；today → **doingOpenNote**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-todo-186`（Locked，未 launch）；循环仍跑。
- 证据：`build-todo-186.log` · `install-todo-186.log` · `todo-186-reload.md`
- **下一 tick**：解锁验加待办/交给我办后刷失败开口；可继续 silent-fail（waitingTodo / applyPlan 后拉齐）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:56 · Wait-plan-187 · waitingTodo / applyPlan 后拉齐
缺口：waitingTodo / applyPlan 成功后 load 吞失败。
- waitingTodo：waiting → **waitingOpenNote**；today → **doingOpenNote**。
- applyPlan：plan 失败 → 乐观 closed + **planOpenNote**；next → **planOpenNote**；today → **doingOpenNote**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-wait-plan-187`（Locked，未 launch）；循环仍跑。
- 证据：`build-wait-plan-187.log` · `install-wait-plan-187.log` · `wait-plan-187-reload.md`
- **下一 tick**：解锁验改期/明天计划后刷失败开口；可继续 silent-fail（waitingAck 后 waiting 拉齐）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:57 · Wait-ack-188 · waitingAck 后拉齐
缺口：waitingAck 成功后 load waiting 吞失败；角标/重开可能回弹。
- load 失败 → 乐观收卡（同步 count）+ **waitingOpenNote**；成功清 note。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-wait-ack-188`（Locked，未 launch）；循环仍跑。
- 证据：`build-wait-ack-188.log` · `install-wait-ack-188.log` · `wait-ack-188-reload.md`
- **下一 tick**：解锁验「已经回了」后刷失败开口；可继续 silent-fail（refreshAfterCaseChange / caseCancel·Resolve）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~06:59 · Case-change-189 · refreshAfterCaseChange / Cancel·Resolve
缺口：refreshAfterCaseChange 吞 waiting/cases 失败；Cancel/Resolve 后横幅/动态可能仍当在跑。
- refreshAfterCaseChange(head:)：waiting → **waitingOpenNote**；cases → **activityOpenNote**。
- Cancel/Resolve：cases 未齐 → 乐观 patch cancelled/done + active/waiting 计数。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-case-change-189`（Locked，未 launch）；循环仍跑。
- 证据：`build-case-change-189.log` · `install-case-change-189.log` · `case-change-189-reload.md`
- **下一 tick**：解锁验停止/标完成后刷失败开口；可继续 silent-fail（agency prepare 后 cards 拉齐）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~07:01 · Agency-prep-190 · prepare 后 cards 拉齐
缺口：prepare 成功后 agency load 失败静默；重开详情可能丢整理包。
- load 失败 → 乐观写 card.preparation + **agencyCardsNote**；详情/等你露出。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-agency-prep-190`（Locked，未 launch）；循环仍跑。
- 证据：`build-agency-prep-190.log` · `install-agency-prep-190.log` · `agency-prep-190-reload.md`
- **下一 tick**：解锁验整理后刷失败开口；可再找小缺口（later/mute 后 cards 开口）或等 ~07:20 Harden；**现在不要 Harden**；**勿 SoftPress**。

### 2026-10-29 ~07:03 · Agency-later-191 · later/mute 后 cards 拉齐
缺口：later/mute/handled 成功后只乐观收卡、无开口。
- load 失败 → **agencyCardsNote**（waitingOpenNote 若空同写）；等你晚点/划掉回执露出。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动；**未做 Harden**。
- **构建**：`BUILD SUCCEEDED`；`install-agency-later-191`（Locked，未 launch）；循环仍跑。
- 证据：`build-agency-later-191.log` · `install-agency-later-191.log` · `agency-later-191-reload.md`
- **下一 tick**：~07:20 起 **Harden**（定稿 Handoff 晨报、已装版本、醒来验收）；在此之前不新开大面；**勿 SoftPress**。

### 2026-10-29 ~07:05 · Harden 开 + Remind-192
- **Harden**：Handoff 晨报定稿（主线摘要、Locked 限制、醒来 A–F 优先清单、分支 ~58 files 脏树核对）。
- **极小缺口**：reminderAction 后 today load 吞失败 → 乐观改 reminders + **doingOpenNote**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab / 工程文档覆盖未动。
- **构建**：`BUILD SUCCEEDED`；`install-remind-192`（Locked，未 launch）；循环仍跑。
- 证据：`build-remind-192.log` · `install-remind-192.log` · `remind-192-reload.md` · Handoff 晨报
- **下一 tick**：继续 Harden/Handoff 微调至 Goal ~08:00；勿新开大面；**勿 SoftPress**。

### 2026-10-29 ~07:07 · Harden 补全 + Discuss-wait-193
- **Harden**：醒来第一步写清；A–F 可执行期望；装机名与限制表对齐。
- **极小缺口**：agency discuss 后 waiting/cases 吞失败 → **waitingOpenNote** / **activityOpenNote**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab 未动。
- **构建**：`BUILD SUCCEEDED`；`install-discuss-wait-193`（Locked，未 launch）；循环仍跑。
- 证据：`build-discuss-wait-193.log` · `install-discuss-wait-193.log` · `discuss-wait-193-reload.md`
- **下一 tick**：继续 Harden 至 Goal；勿新开大面；**勿 SoftPress**。

### 2026-10-29 ~07:09 · Harden 定稿 + Delegate-wait-194
- **Harden**：**定稿可用**（醒来第一步 + A–F + Locked/装机对齐）；至 Goal 不新开大面。
- **极小缺口**：delegateNext 后 waiting 吞失败 → **waitingOpenNote**。
- **禁令**：未新铺 SoftPress；无假 herdr；五 Tab 未动。
- **构建**：`BUILD SUCCEEDED`；`install-delegate-wait-194`（Locked，未 launch）；循环仍跑。
- 证据：`build-delegate-wait-194.log` · `install-delegate-wait-194.log` · `delegate-wait-194-reload.md`
- **下一 tick**：守 Goal 至 ~08:00；仅措辞微调 / 监督响应；**勿 SoftPress**。

### 2026-10-29 ~07:10 · Harden 待命
- 无新实质 silent-fail；Handoff 时间戳与装机名已对齐；**待命 `install-delegate-wait-194`**。
- **禁令**：未 SoftPress / 假 herdr / 五 Tab / 新开大面。
- **下一 tick**：守至 Goal ~08:00；醒来解锁验 A–F。
