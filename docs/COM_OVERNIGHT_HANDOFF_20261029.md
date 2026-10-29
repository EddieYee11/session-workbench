# Com 过夜冲刺 · 起床交接 · 2026-10-29

> Harden 晨报 **定稿**（~07:09）。**Goal 已收束**（~08:00 窗口结束；监督循环已停；过夜冲刺代理未再推进）。

**分支**：`com-personal-agent-overnight-20261029`（相对出发点约 **58 files / +7.9k −1.1k**，未提交过夜 WIP）  
**窗口**：约 01:00 → 08:00 Asia/Shanghai（**已结束**）  
**计划**：`docs/COM_OVERNIGHT_PERSONAL_AGENT_20261029.md`  
**最终装机**：~07:09 CST · **`install-delegate-wait-194`**（Duo 过夜 Locked；醒来解锁打开即可）  
**监督**：tick 已停；不再推进  
**Harden**：**定稿可用**（醒来清单 A–F 可执行）

### 醒来第一步（先做这一步）

1. **解锁 Duo** → 主屏点开 **Com**（`work.eddie.com`）  
2. **不要**先跑重装，除非 App 图标消失或版本明显旧于下表装机名  
3. 有网且已配对时走下方 **A→F**；断网可抽验「刷失败开口」

**当前应在机上的包**：**`install-delegate-wait-194`**（~07:09；含 discuss-wait-193）。仅图标消失或明显旧包才重装。

---

## 过夜主线（一句话）

Com 更像可打开的 personal agent：空态/等你/下一步像值班伙伴；**mutate 成功但列表没刷齐会开口**（乐观收卡 + InlineNotice），不假装已齐；终端诚实（**Com 通 · herdr 未接**）。「记一下咖啡18」快路径已在 mini。动效真源：`ios/Docs/MOTION.md`。

### 本夜三条工作流

1. **Presence → Gravity → Action → Brief**：空态、注意力条、一卡一动作、今天 brief  
2. **门控 / busy / 失败留页**：送达才跳聊天、划掉失败回弹、审批/航程拍板留页  
3. **Silent-fail 扫尾（末段 180+）**：Tab refresh、next/runNext、加待办/交给我办、waitingTodo/applyPlan/waitingAck、航程 Cancel·Resolve、agency prepare/later、提醒写回

### 已知限制

| 项 | 状态 |
|---|---|
| Duo 装机 | ✅ **`install-delegate-wait-194`**（及 prior 链）已装 |
| Duo launch | ❌ Locked 过夜，**未**自动 launch；醒来解锁后打开 |
| HerdrKit / 真 SSH | ❌ 未接；终端探测只证 Com，不假装 herdr |
| 五 Tab | ❌ 未改 |
| SoftPress 末段 | ❌ 未新铺（早段已有 SoftPress 保留） |
| Git 提交 | ❌ 过夜改动仍为工作区脏树，未要求提交 |

---

## 醒来怎么验（照做 · 约 6 分钟）

**版本**：解锁 → 打开 `work.eddie.com`（目标包 **delegate-wait-194**；仅装机过期才重装，命令见下）。

### 末段优先 A–F（约 2 分钟 · 可执行）

| # | 点哪里 | 期望（过 = 可继续） |
|---|---|---|
| A | 下一步 → 某卡「加待办」或「交给我办」 | 卡应收起；若列表刷失败，下一步/今天有 InlineNotice（plan/doing） |
| B | 等你 →「已经回了」或「晚点」 | 卡收起；刷失败等你/卡回执开口（waiting / agencyCards） |
| C | 航程详情 →「算了标完成」或停止 | 横幅/角标不再当它在跑；刷失败 waiting/activity 开口 |
| D | 等你事项 →「先整理资料」→ 打开详情 | 能见整理包；刷失败有 agencyCardsNote；重开详情不丢包 |
| E | 今天 → 某提醒 → 完成或取消 | 详情可关；刷失败今天顶栏 doingOpenNote |
| F | 工作 →「终端」→「探测 Com 链路」 | 文案含 **`Com 通 · herdr 未接`**（或探测失败说明），**不**出现假「已连接 herdr」 |

### 全表抽验（有空再点）

手机解锁 → 打开已装的 `work.eddie.com`：

| # | 点哪里 | 期望 |
|---|---|---|
| 1 | Com 空态 | 时段问候像活人；有等你则催办口吻 + **点名标题**；starter ≤2 且首枚强调。可点「记一笔开销」→「记一下咖啡18」 |
| 1b | 有等待时主聊底栏 | **一卡**：标题 +「去拍板」（不是两枚件数芯片） |
| 1f | 等你列表 | 导语点名；首卡「先看这件」高亮；「交给我办」后有反馈/进对话 |
| 1g | 工作（对话面） | 进页侧栏应有会话/项目（不必先切走）；新对话有时段旁白；空会话活人提示（非假终端）；语音发送失败应保留转写可重试 |
| 1h | 健康 | 进页应有曲线/评估（不必先切走再回来）；无数据时 agent 一句；有简报「身体上我说一句」 |
| 1w | 分享收件箱 | 「加入聊天草稿」成功后应收起收件箱，进 Com 能看见草稿；失败应留页且分享仍在 |
| 1i | 下一步空 vs 有卡 | 进页应有最新卡/待核对/明天计划（不必先下拉）；空态「没什么要推的」；有卡导语 +「现在 · 先办」；已做/划掉失败卡应回弹并提示；主动作失败卡还在；Glance「没成」可再点；等你「交给我办」失败卡应还在；过期待办完成失败应回弹 |
| 1j | 建议芯片 / 过程 | 「我想你可以：」；点芯片失败应回弹可重试；送达成功才收起；过程「收到了/我在办/办完了」 |
| 1k | 记忆待确认 | 旁白请点头；「对，记住 / 纠正我 / 先不用」；确认失败纸片应回来；旧任务「全部归档」失败不应报已归档 |
| 1l | 航程停顿 | 等待段置顶；删除题用删 CTA，其它用「可以继续/先别」；拍板失败应留页可重试；失败可「跟我说怎么改」；拍板后等你角标应立刻掉 |
| 1q | 动态入口 | 菜单/下一步「动态」打开应是新列表（有航程停顿时能看到） |
| 1m | 审批卡 | 标题点名操作；「批准才动真格」；「批准，去做 / 先别做」；派活详情批准失败应留在页上；等你左划失败卡应还在 |
| 1n | 等你深链/点名 | 有航程停顿时底栏点名应是航程；推送 case-wait **或**应用内「去拍板」/今天举手 打开「等你」并刷新 |
| 1o | 记账→账本 | 「已记」回执后打开账本（或账本已开着）应能看到新账（不必等轮询） |
| 1p | 微信已经回了 | 等你里点「已经回了」→ 角标下降；划掉重开不回；对方再发才再现 |
| 1r | 过期待办交给我办 | 成功后该条离开等你、角标下降；进航程或主对话。失败不应出现「已接进」提示 |
| 1aa | 语音批审批 | 说批准/拒绝若未送达，审批卡与语音窗应还在，可再说一次 |
| 1s | 结果待核对 | 下一步或动态里点「做成了/没做成」应立刻亮起；失败回弹可重试；两边更新；「做错了/让它改」应进 Com 并带草稿 |
| 1t | 菜单记忆/账本/连接器 | 打开应是新数据（非明显过期快照）；连接失败/未接通应警示；目标暂停/完成失败应留页可重试 |
| 1u | 下一步回微信 | 「复制草稿去微信」后，该聊天应从等你消失、角标下降 |
| 1v | 下一步记账/日程 | 送达失败时卡应还在且不跳聊天；成功才消并进 Com。设置→服务器状态应是新数 |
| 1x | 交给 Com / 起草 / 热点讲讲 | 送达失败应留在原页（等你不关）；成功才进 Com。依据袋→事项「交给 Com」失败应留在事项页可重试 |
| 1y | 深链/小组件/灵动岛 | 有审批点小组件应进「等你」；航程结果推送进动态应是新列表；灵动岛 plan 进下一步；系统关实时活动或开岛失败 → 设置「平台能力」开口（不假装岛在跳）；小组件写 Keychain 失败同区开口且不 reload 成假新鲜 |
| 1c | 今天 | 进页应有时间线/简报/热点（不必先切走）；副标题点名等待/下一步；「我说几句」首条像开场；提醒完成失败应留在详情 |
| 1z | 热点全表讲讲 | 送达失败应收起失败提示且列表还在；成功才进 Com |
| 1d | 下一步 | 页头「先办这一件：…」；卡上主动作口语化 |
| 1e | 顶栏有等待 | 状态行点名；举牌短标题（非空「等你」） |
| 2 | 记账回执 | 应快通道「已记」类标签（mini 已 kickstart；服务侧 parse 已断言） |
| 3 | 等你 / 审批 | 导语「一卡看一件」；「等你拍板」；划走 settle |
| 4 | 工作 → 终端 → 探测 | **`Com 通 · herdr 未接`**；探测后说明「不会假装已连上」（不是假已连接） |
| 5 | 设置 / 健康 / TaskHub 抽查 | 空态人话；断网 InlineNotice 像伙伴说话；任务详情验收/补充失败应留页提示；Hub 进页应有新任务数；设备撤销失败应可再试；账本读失败应警示；开通知后若 token 上报失败应开口（可「再试一次上报」），不假装远程推送已通 |
| 6 | 回归 | 五 Tab 未改；工作「对话」未盖；HerdrKit 未挂；Reduce Motion 无长弹簧 |

### 一键重装（仅当装机过期）

```bash
cd "/Users/eddiegao/AI_Work_System/work/工具与效率/会话工作台/ios"
DEVICE=00008160-001E3CEA36E00036
xcodebuild -skipPackagePluginValidation -project Com.xcodeproj -scheme Com -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath DerivedDataDevice \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=AJN4TFSWT9 build
xcrun devicectl device install app --device "$DEVICE" \
  DerivedDataDevice/Build/Products/Debug-iphoneos/Com.app
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing work.eddie.com
```

证据目录：`ios/verification/overnight-20261029/`

---

## 分支现状（Harden 核对）

- **名**：`com-personal-agent-overnight-20261029`
- **脏树**：大量 iOS 视图 + AppModel/Agency + Cases/Threads/Next/Today；backend fast_bookkeeping/policy/cases；`ios/Docs/MOTION.md` / `DESIGN.md` 增量；**未**覆盖无关工程总文档为「只写过夜」
- **末段装机链**：… → remind-192 → discuss-wait-193 → **delegate-wait-194**
- **禁令核验**：无新 SoftPress 铺面、无假 herdr、无五 Tab 大改、无 HerdrKit SPM

---

## 本夜改了什么（摘要）

| 块 | 状态 |
|---|---|
| Presence / Gravity / Remote 诚实探测 | ✅ |
| Waiting / 记账 UI / 快路径（mini 部署） | ✅ |
| 设置·搜索·记忆·航程·语音 | ✅ |
| Finance / 动态 / 分享 / Agency / Next / HotBoard | ✅ |
| 配对 / 回执 / 审批 / 侧栏 / 看板 / 连接 | ✅ |
| 健康 / Chrome / 建议卡 / TalkBubble / TaskHub / Body | ✅ |
| InlineNotice · MOTION/DESIGN · ReplyMotion | ✅ |
| 监督 tick #1 稳定性抽检 | ✅ |
| audit-22 扎实抽检（无新 bug） | ✅ |
| Gravity-23 → … → Agency-later-191 | ✅ 见下表装机列（过夜 silent-fail / 门控链） |
| SoftPress / breath / 存在感早段 | ✅ 装机 deep-polish 等（早段） |
| 门控链 Guard → Hand → … → Voice-75… | ✅ 多轮 Duo Locked 装机 |
| Tab refresh 177–183 | ✅ chat/next/work/health/doing/hot/today-next |
| 列表拉齐 184–191 | ✅ next-act … agency-later |
| Remind-192 提醒写回后今天拉齐 | ✅ 装机 remind-192 |
| Discuss-wait-193 discuss 后 waiting/cases | ✅ 装机 discuss-wait-193 |
| Delegate-wait-194 delegateNext 后 waiting | ✅ 装机 delegate-wait-194 |
| 构建装机（本轮 0 新 warning） | ✅ … → discuss-wait-193 → delegate-wait-194 |
| 监督 tick #2–#9 | ✅ 已响应；循环 running |
| Harden | ✅ **定稿可用**（至 Goal 仅微调 / 极小补漏） |

---

## 明确未做 / 白天续

- HerdrKit SPM、真 SSH/PTY、moshi-hook→等你  
- 五 Tab→三 Tab、Instruments、锁屏自动 launch  
- 真机口说「记一下咖啡18」入账（点 starter 或口述均可验；服务侧已就绪）  
- Next 纸片 / MemoryMotion 局部参数故意保留  
- 过夜 WIP **未 git commit**（需你明示再提交）

---

## 关键入口

- 动效：`ios/Docs/MOTION.md` · `DesignSystem.ComMotion`  
- 设计：`ios/Docs/DESIGN.md`  
- 进度：`docs/COM_OVERNIGHT_PERSONAL_AGENT_20261029.md`  
- 后端：`policy.py` · `tests/test_fast_bookkeeping.py`
