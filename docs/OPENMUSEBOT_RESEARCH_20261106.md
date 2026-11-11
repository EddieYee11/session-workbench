# openmusebot (OpenMausBot) 架构深度调研与 Com! 吸收评估报告

> **文档性质**：Com! (comapp) 产品重构与 Agent Harness 体系升级 — 开源对标专项调研报告  
> **归档路径**：`work/工具与效率/会话工作台/docs/OPENMUSEBOT_RESEARCH_20261106.md`  
> **调研负责人**：Teamwork Explorer (`explorer_r2_openmusebot`)  
> **完成日期**：2026-11-06  
> **对齐基线**：GitHub 开源项目 `milind-soni/OpenMausBot`（业内常称 `openmusebot` / `MausBot`）、Com! PRD v2.2.0（`COM_CHAT_AND_NEXT_RESTRUCTURE_PRD_20261106.md`）及系统诊断报告（`COM_CHAT_AND_NEXT_DIAGNOSIS_20261106.md`）  
> **设备与架构约束**：适配目标严格限定为 iPhone Duo（`iPhone19,4`）与 MBP 网页端（`web/`）；业务后端坚持走 Mac mini 本地网关与 Magpie Vertex/Volcengine 赠金池，严禁引入商业付费订阅 API。

---

## 一、调研背景与项目源流定位

### 1.1 开源项目辨识与命名考证

在多 Agent 协同与桌面级 AI 工作台开源领域，GitHub 上的 **`openmusebot`**（主仓库：`milind-soni/OpenMausBot`，前身为 `OpenGrokBot` / 亦常被社区称为 `MausBot` 或 `OpenMuseBot`）是目前热度最高、工程完备度最扎实的独立开源实践之一。

1. **命名与渊源**：
   - 官方 README 明确自述：“*OpenMausBot is an open-source Grok Bot alternative: an independent project inspired by Grok Bot, and the open-source alternative to Meta Muse, OpenAI dots and Cue by Manus — bring-your-own-agent, local-first, on the models you already have.*”
   - 它是业内针对 **Meta Muse** 与 **Cue by Manus** 最主流的开源手搓对标项目。在代码库内部（`server/drivers/muse-code.ts`），该项目直接通过 Meta 的 Muse Session Protocol（MSP）及 `@muse-code/sdk` 深度集成了 Meta 编程智能体 `muse`，并支持本地 Pi、Antigravity、Claude、Codex、Grok 等多种模型引擎，因此在社区检索与技术讨论中常被称为 `openmusebot`。
2. **核心产品哲学**：
   - **Local-First & Bring Your Own Agent**：用户无需受制于单一厂商的 SaaS 云服务，直接驱动宿主机本地已登录的 CLI（`claude`、`codex`、`pi`、`muse`）或自建网关。
   - **Decoupled Client-Harness-Engine**：前端界面（Electron/React 桌面端或移动 Web）、核心运行时调度中枢（Harness Server）、底层引擎驱动（Driver Adapters）彻底解耦。
   - **Deterministic Guardrails & Interactive Approvals**：摒弃单纯靠 Prompt 约束模型的不可靠做法，在 Harness 宿主层建立强类型的确定性状态机与结构化卡片拦截层。

---

## 二、多 Agent 协同架构与交互流机制剖析

在 OpenMausBot 的核心运行时（`server/runtime/` 与 `server/coordinator.ts`）中，沉淀了一套极具工业参考价值的任务分配树与跨智能体协作规范。

### 2.1 单一任务树与不可变谱系（`Assignment` Tree）

在 `server/runtime/types.ts` 中，OpenMausBot 确立了统一的任务对象契约：

```typescript
export interface Assignment {
  id: string;
  rootId: string;
  parentId?: string;
  depth: number;
  origin: Origin;         // { kind: "person" | "routine" | "outside", source, quote }
  requester: Requester;   // { kind: "person" | "bot_turn" | "routine_run", botId, threadId, chief }
  assignee: Assignee;     // { botId, destination: { kind, threadId, groupId } }
  mode: Mode;             // "work" | "consult" | "notify"
  reply: Reply;           // "resume" | "poll" | "none"
  status: Status;         // "queued" | "running" | "needs_input" | "waiting" | "resume" | ...
  outcome?: Outcome;
  level: Level;           // "ask" | "edits" | "auto" | "full"
  levelSource: LevelSource;
  executions: number;
  restarts: number;
  brief: string;
  result: string;
  evidence?: TurnEvidence;// 宿主实际观察到的文件变更与命令行行为，非模型自述
  budgets?: { since: number; requests: number; executions: number; wakes: number };
  guard?: { stale: number; errors: string[] };
}
```

#### 关键设计亮点：
1. **谱系不可变性（Immutable Lineage）**：
   - 任务树从根节点 `rootId` 开始，其来源 `origin`（人直接发起、定时例程触发、还是外部 Webhook 传入）沿树全部分支不可变向下继承。即使经过多层 Agent 级联交办，底层执行者始终知晓“最初由谁发起、以谁的名义执行（`onBehalfOf`）”。
2. **三类交互模式（Modes of Collaboration）**：
   - **`work`（自主执行）**：被委托的 Agent 调动自身工具自主推进，产出最终结论并汇报。
   - **`consult`（只读咨询）**：仅凭已有知识或只读检索作答，严格禁止执行具有任何副作用的写操作。
   - **`notify`（单向通知）**：向目标 Agent 投递事件或通知，不建立等待父节点，不阻塞当前任务。
3. **唤醒返回通道（Reply Lanes）**：
   - **`resume`**：子任务完成后，通过 Harness 调度宿主唤醒父任务，触发父任务的新一轮恢复轮（Resume Turn）。
   - **`poll`**：结果静置于收件箱，供外部长轮询获取，不主动打扰当前对话。
   - **`none`**：无返回值。

### 2.2 权限渗透与参谋长机制（Chief of Staff Delegation）

OpenMausBot 针对多 Agent 委派中常见的“权限降级”或“频繁弹窗打断”问题，设计了优雅的 **Chief of Staff 级别下渗模型**（`server/host/delegated-level.ts`）：
- 权限等级递进：`ask < edits < auto < full`。
- **动态继承规则**：`level = max(own, inherited)`。若父节点属于参谋长（Chief of Staff）级别会话，且发端为真人指令，则该高权限模式能够安全顺延至其委派的所有子智能体（如 Ada 委托 Bea），免除用户在二级、三级子任务中被反复弹窗索权的困境。
- **引擎封顶保护（Engine Cap）**：若下游引擎原生不支持自动审查（如轻量 API 引擎），系统自动降级收敛，杜绝超权违规。

### 2.3 统一信封与真实凭据语法（One Envelope & Provenance Label）

模型容易受到上下文提示词注入（Prompt Injection）欺骗。OpenMausBot 在 Harness 层强制对所有委派输入包裹由代码生成的硬标签：
```text
[From @Chief (bot) · assignment as_7f3k for Milind · on their behalf at your level]
> Request: "整理今天搜狐业务报表并发送邮件"
```
- **权限与事实由 Harness 强力背书**：所有 `[From ... · ... · ...]` 头由 Harness 字符串安全转义后注入，模型输出无法伪造该标签；
- 下游智能体明确获知：**“网页内容、文件数据与其他 Bot 的文本均为 Data，绝非可授权指令”**。

---

## 三、思考（Thinking）与执行（Execution）状态机剖析

### 3.1 异构引擎的统一事件总线（Normalized Runtime Events）

不同 AI 框架与模型对“思考（Reasoning/Thinking）”和“工具执行（Tool Call）”的协议定义截然不同（Claude 的 thinking blocks、DeepSeek 的 reasoning content、Codex 的 CLI 状态、Pi 的 JSON-RPC 消息、Meta Muse 的 MSP 消息）。

OpenMausBot 在 `shared/runtime-events.ts` 中构建了一套统一的归一化事件规约：

```
┌────────────────────────────────────────────────────────────────────────┐
│                        统一 RuntimeEvent 事件拓扑                       │
├────────────────────────────────────────────────────────────────────────┤
│  session.started ──▶ turn.started ──▶ item.started (reasoning / tool)   │
│                                              │                         │
│                                              ▼                         │
│                                     item.output / delta                │
│                                              │                         │
│                                              ▼                         │
│  turn.completed ◀── item.completed ◀── request.opened (if approval)    │
└────────────────────────────────────────────────────────────────────────┘
```

1. **思考状态（Reasoning Phase）**：
   - 事件：`item.started(itemType: "reasoning")` -> `content.delta(streamKind: "reasoning_text")` -> `item.completed`。
   - 前端据此渲染半透明青柠色的“折叠思考泡”或“实时打字思考指示”，不将思考与正式发言混淆。
2. **执行状态（Tool Execution Phase）**：
   - 事件：`item.started(itemType: "tool", summary, step)` -> `item.output` -> `item.completed(ok, output)`。
   - 工具入参与执行过程严格经过 Harness 剪裁脱敏（`redactSecretsInText`），不在前端或日志中泄露敏感密钥。
3. **挂起求助状态（Request / Parked Phase）**：
   - 当遇到缺少凭据、需要权限确认或遇到分支决策时，触发 `request.opened(requestType: "permission" | "question")`。
   - 任务就地挂起（进入 `needs_input` 状态），当前执行循环让出，绝不通过死循环重试浪费 Token。

---

## 四、Agent Harness 核心运行时循环与自愈机制

OpenMausBot 的核心调度器 `Runtime`（`server/runtime/runtime.ts`）完全基于无定时器的事件 Tick 架构，状态纯粹基于 SQLite 持久化层驱动。

### 4.1 工业级有限状态机生命周期

```
    ┌──────────┐
    │  queued  │ ──(admit / slot available)──┐
    └──────────┘                             │
         ▲                                   ▼
         │                             ┌──────────┐
  (answer/continue)                    │ running  │
         │                             └──────────┘
         │                               │      │
         │   ┌───────────────────────────┘      └────────────────────────────┐
         │   ▼ (hand out child work)                                         ▼ (park for input)
   ┌───────────┐                                                       ┌─────────────┐
   │  waiting  │ ──(all kids settled OR child asks question)──▶ ┌──────┴──────┐│ needs_input │
   └───────────┘                                               │    resume    │└─────────────┘
                                                               └──────┬───────┘
                                                                      ▼
                                                       ┌───────────────────────────────┐
                                                       │ completed | failed | cancelled│
                                                       └───────────────────────────────┘
```

- **等待与穿透恢复（Interrupted Wait）**：
  - 当父节点处于 `waiting`（等待多个子 Agent 运行）时，若某个子节点突发提问（`needs_input`），父节点的等待被安全打断并进入 `resume` 状态，带入子节点的 open question 立即向用户呈现微卡，而无需等待其他健康的兄弟子节点全部执行完毕。
- **就地继续与进度守卫（Continuation & Loop Guard）**：
  - 遇到长耗时任务或单轮步骤上限时，状态机输出 `continue` 并重新排队；
  - **防死循环双重哨兵（Loop Guard）**：
    1. 连续 2 轮续跑中没有发生任何一次成功的工具调用（`stale >= 2`）；
    2. 或连续 3 次工具调用报错信息完全相同（`errors` 队列命中）。
    系统立即判定该任务卡死，主动置为 `failed(stalled)` 并熔断，阻止 Token 资金池被持续消耗。

### 4.2 重启对齐与外向动作幂等检查（Restart Reconciliation）

服务意外重启或断电是个人 Agent 系统的常见故障点。OpenMausBot 提出了业内极罕见但至关重要的 **外向动作检查（Outward Action Inspection）**：

| 停机前状态 | 是否已产生外向行为（邮件/git push/付款） | 重启对齐策略 |
|:---|:---|:---|
| `queued` | 否 | 正常放行调度 |
| `running` | **是**（通过 `outward(a)` 识别已执行外部副作用） | **严格禁止重新执行**，直接结转为 `failed(interrupted)`，写明“已完成外向动作，不作重试以避免重复发送/付款” |
| `running` | **否**（仅在本地分析或未发生外部写入） | 允许原位重跑一次（`restarts = 1`），输入前置提示“检查之前执行切片” |
| `running` | 曾已派发出子节点 | 转换为 `waiting`，等待子节点自愈，父节点本身不重跑 |
| `needs_input` | 不适用 | 保持原位挂起，静默恢复卡片绑定，不向用户重复发送报警弹窗 |

该机制彻底攻克了传统 Agent 系统中“服务一重启，脚本自动重新发了一遍邮件/重复转账”的灾难性缺陷。

### 4.3 三维预算与四维时钟防护

```typescript
export interface Limits {
  depth: number;          // 最大委派层深（默认 4 层）
  requests: number;       // 根节点累计总请求预算（默认 24 次）
  executions: number;     // 根节点累计执行轮次预算（默认 48 次）
  wakes: number;          // 唤醒唤回次数预算（默认 48 次）
  queueMs: number;        // 排队等待超时（默认 24h）
  stallMs: number;        // 无进展全局停滞超时（默认 4h）
  turnStallMs: number;    // 单轮工具执行卡死超时（默认 20min，结合 monotonic 时钟）
  inputWaitMs: number;    // 等待用户输入超时（卡片等待默认无穷大）
}
```
通过有进展（Durable Progress）才刷新时钟的严谨算法，既包容了人类用户的异步响应习惯，又在失控时拥有确定性的兜底保护。

---

## 五、事件推流（SSE）与前端轻量闭环交互模式

### 5.1 工业级自愈 SSE 增量推流体系（`/api/events`）

OpenMausBot 针对浏览器与移动端网络波动的处理堪称范本：

```typescript
// server/index.ts:14872-14902
const since = cursorSeq(req.headers["last-event-id"]) ?? cursorSeq(url.searchParams.get("since"));
const resumed = since !== null && since <= lastSeq && replayBuffer.covers(since, lastSeq);

res.write(`data: ${JSON.stringify({ kind: "hello", cursor: `${STREAM_ID}:${lastSeq}`, resumed })}\n\n`);

if (resumed) {
  for (const buffered of replayBuffer) {
    if (buffered.seq <= since) continue;
    res.write(buffered.frame); // 增量补发丢失的帧
  }
}
```

1. **游标与连续序列号（Monotonic Sequence）**：
   - 游标格式为 `STREAM_ID:seq`（例如 `run:142`）。服务端维护环形 `replayBuffer`。
2. **优雅降级与全量快照拉取（Snapshot Required Protocol）**：
   - 客户端（`src/lib/live-events.ts`）在收到 `{ kind: "hello", resumed: false }` 时，明确获知游标已过期或脱离缓冲区，此时立刻触发 `onSnapshotRequired()` 挂起增量处理，从 REST 接口拉取最新完整快照。
   - 在拉取快照期间收到的后续实时增量帧暂存于 `pendingSnapshot`，快照载入完成后对齐应用，**彻底消灭界面空洞与数据分叉**。
3. **双层探活避开浏览器缺陷**：
   - 针对浏览器 `EventSource` 原生静默吞噬 HTTP 注释帧（`:\n\n`）导致客户端无法感知的缺陷，服务端同时发送带有明确 payload 的 `ping` 数据帧；
   - 客户端基于 `isLivePing` 动态重置探活计时器，一旦超过 40 秒未收到任何数据帧，自动启动指数退避重连（`500ms ~ 10s`）。

### 5.2 微卡就地闭环（In-Place Actionability）与零劫持交互

在 `src/components/QuestionCard.tsx` 与 `ApprovalCard.tsx` 中体现了与 Com! PRD 完全一致的交互哲学：
- **就地微卡（Micro-Sheet）**：
  - 遇到选项询问，直接在当前卡片呈现单选/多选胶囊。单选项支持 **One-Tap 瞬时闭环**；
  - 用户做出选择后，卡片立即在原地转变为极简收敛状态（`SettledQuestion` / `approvalCardOutcome`），展示绿色微勾与摘要文本，焦点自动交还输入框（`returnFocusToComposer()`）。
- **杜绝界面劫持与伪造气泡（Zero Tab Hijacking）**：
  - 严禁为了确认一项操作强行切走页面；
  - 严禁向聊天窗口伪造注入“我自己对自己说：我确认了”的假消息气泡，所有交互作为卡片组件的自身状态跃迁完成。

---

## 六、针对 Com! (comapp) 架构重构的全面吸收映射

对照 Com! PRD v2.2.0 与 R1 诊断报告，OpenMausBot 的核心机制可精准赋能 Com! 的三大重构阶段：

| PRD 重构模块与目标 | 现状诊断痛点（来自 R1 报告） | OpenMausBot 核心对标机制 | Com! 吸收与落地实施路径 |
|:---|:---|:---|:---|
| **Phase 1: 统一任务实体与就地闭环** | **P01/P04**: `next:` 与 `todo:` 身份突变与多态擦除；<br>**P02**: 跨界面强行劫持切 Tab 与伪造自身气泡 | **Assignment 不可变树** 与 **One-Tap In-Place QuestionCard** | 1. 后端确立以不可变 `matter_id` 为唯一主键的生命周期流转；<br>2. 移植 `QuestionCard` 的单键确认与原位收敛状态（微卡），任何 Obsidian、日程或记账动作在当前界面局部闭环。 |
| **Phase 2: 工业级 FSM 与双栏/挂起并发** | **P06**: 状态机缺失关键分支导致任务静默蒸发；<br>**C02/C04**: 主聊天单轮串行死锁，后台航程插话打断心流 | **9+11 完备状态拓扑**、**Interrupted Wait** 与 **Live Presence Capsule** | 1. 落地 11 状态机，引入 `waiting_input`、`error_retrying` 与 `error_blocked`；<br>2. 借鉴其树形等待模型，将后台长任务解耦为对话顶部的实时挂起胶囊，主线聊天保持即时畅通。 |
| **Phase 3: 自愈 SSE 增量推流与 GC** | **C06**: 弱网 SSE 中断抛红色横幅，缺乏游标自愈；<br>**P09**: 任务堆积缺乏无损归档 | **Last-Event-ID + ReplayBuffer + SnapshotRequired 握手协议** | 1. 前后端对齐 `STREAM_ID:lastSeq` 游标机制；<br>2. 消除红色报错条，断线后静默指数退避重连，超界自动走 REST 快照自愈；<br>3. 引入基于 SQLite 事件审计日志的冷热数据 GC 分离。 |
| **Work 区块与终端舒适化** | **C07**: 审批流与等你浮条双重打扰；终端历史无法滑动与字号丢失 | **Outward Action Inspection** 与 **免扰审批收敛** | 1. 在后台 Cases 执行中植入外向动作审计，防重启重复执行；<br>2. 审批统一汇入轻量通知或常驻工作台卡片，支持一键撤销（Undo）。 |

---

## 七、架构对比与必须坚守的底线红线

### 7.1 取其精华，弃其繁冗

OpenMausBot 的优秀之处在于其对 **协议分层、状态机韧性、SSE 推流自愈、就地交互闭环** 的极致打磨。但其部分设计并不适合 Com! 的特定定位：
1. **舍弃云端虚拟机与复杂隔离沙箱（Cloud Computers / VM）**：
   - OpenMausBot 为多用户 SaaS 提供了容器与 VM 隔离方案。Com! 属于 Eddie 个人自用的双机闭环系统（Mac mini 中枢 + MBP 移动 + iPhone Duo 随身），无需过度工程化引入沉重的 Docker/KVM 虚拟化，继续保持轻量本地进程管控与 Herdr 终端复用。
2. **舍弃三方商业集成平台（Composio / HighLevel CRM 依赖）**：
   - 彻底剔除商业 SaaS 胶水层，专注通过本地 MCP Server、AppleScript、快捷指令与 SQLite 联动个人核心数据（邮件、日程、微信解密库、Obsidian Vault）。

### 7.2 绝对严守的架构底线

在吸纳 OpenMausBot 的优秀设计时，必须无条件遵循以下不可逾越的红线：
1. **模型费用零增加**：
   - 所有模型调用坚持走 Mac mini 上的本地网关与 **Magpie Vertex/Volcengine 赠金池**，绝不在代码与配置中引入商业付费订阅 API。
2. **硬件专属体验专注**：
   - 客户端交互设计坚决聚焦于 **iPhone Duo 折叠屏（`iPhone19,4`）与 MBP 宽屏 Web 端**，不考虑 Android 兼容包袱，充分发挥折叠屏双栏视差、铰链避让与跨折痕拖拽手势的物理特性。
3. **数据主权与无损保全**：
   - 任何拖拽与状态流转严禁物理删除用户的 Obsidian 知识资产与笔记文件，保全本地数据的绝对安全。

---

## 八、调研结论与执行建议

OpenMausBot 为 Com! 当前推进的主聊天与「下一步」全量产品逻辑重构（PRD v2.2.0 Phase 1 ~ Phase 3）提供了直接可落地的开源工业代码范式：
1. **推荐立即吸收**：
   - **`server/runtime/` 的状态机设计与重启对齐算法**：引入不可变状态迁移与外向动作幂等检查，杜绝任务静默丢失与操作重放；
   - **`server/index.ts` 与 `src/lib/live-events.ts` 的 SSE 协议**：基于 `Last-Event-ID`、环形回放缓冲与快照降级策略，彻底根治跨端推流中断抛红的顽疾；
   - **`QuestionCard` 与 `ApprovalCard` 的就地轻量确认微卡机制**：消除跨 Tab 页面劫持与自言自语伪造气泡。
2. **与当前代码库深度融合**：
   - 本调研结论与具体实现蓝图已同步编入团队知识库，可直接作为后续编码实现的坚实设计依据。
