# 《Pi Durable Technical Manual》拆解与对 Com! 的适用性评估

> 2026-10-09，在 MacBook Pro 上完成。读的是 `/Users/eddiegao/Downloads/Pi-Durable-Technical-Manual.pdf`（190 页，Pi Durable 1.0.3，Engineering Edition，2026.10）。按章拆成文本逐章读完，未运行 pi-durable，未改任何上游代码。
> 结论口径：本次是**评估**，不是实施。与 2026-10-03 的 `COM_B0_REUSE_ASSESSMENT.md` 结论一致，本文把它具体化。

## 0. 先说结论

**作为运行时：不引入。作为设计参考：高价值，有 6 条可以零成本直接抄。**

一句话判据：Pi Durable 卖掉的是「用它的 harness 取代 Pi CLI」；Com! 的全部价值恰恰建立在「用 Pi CLI / Claude SDK / Codex App Server 的原生能力，三执行器并存」上。换过去是降级 + 多一个 Node 运行时。

## 1. 事实核查（本次实测）

| 事实 | 值 | 来源 |
|---|---|---|
| 手册对象 | `@earendil-works/pi-durable` **1.0.3**（commit `5b6c792`，2026-10-05） | PDF 前言 |
| 该包在 npm 上真实存在 | 是；版本 0.99.0–1.1.0 | `npm view` |
| npm 最新版 | **1.1.0**（2026-10-07） | `npm view` |
| 手册相对最新版 | 已过期一节（1.0.4、1.1.0 均含 Breaking Changes） | `CHANGELOG.md` |
| 依赖 | `pi-ai ^1.1.0`、`chord ^1.1.0`、diff、typebox；Node ≥ 22.19.0 | `package.json` |
| 本机 Pi CLI | **0.85.1** | `pi --version` |
| `pi-coding-agent@1.1.0` 是否依赖 pi-durable | **否**（依赖 chord / pi-ai / pi-mcp / pi-tui / pi-codemode / pi-agent-core，无 durable） | `npm view` |
| 结论 | 即使把 Pi CLI 升到 1.1.0，Pi CLI **也不会**用上 pi-durable。pi-durable 是并行的另一条产品线 | — |
| 发布节奏 | 1.0.3（10-05）→ 1.0.4（10-05）→ 1.1.0（10-07），**三次都带 Breaking Changes** | `CHANGELOG.md` |

1.0.3 打破自定义 `FileSystem`/`Shell` 实现；1.0.4 打破 env conformance（`watch()` 三个新行为）；1.1.0 打破 `Storage` 查询（新增 `order` 字段）与 `TaskRuntime.context()` 签名。

## 2. 这本书是什么

- 一份**把每条结论都追溯到源码/spec/测试/真实运行**的技术手册。作者写了 capture kit（`research/capture/`），用 SIGKILL 真杀进程，把 SQLite 每一行、每个 commit、每一帧 watch 操作打印出来当证据。手册自称「源码优先于 spec，冲突处会写明」。
- 定位：**durable agent harness** =「一打开的 storage + 在其上跑 agent 的机器」。作者原话：「It does not replace the Pi coding agent. It is a framework for building any agentic application, coding agents included.」
- 读者假设：写过 LLM agent 循环的 TypeScript 工程师，读过 Pi 但没读过 Pi Durable 源码。
- 结构：10 个 Part + Reference，每节以「WHAT THIS MEANS FOR YOU」收口，每节末列 Sources。

## 3. 逐章机制拆解

### Part 1 · The Model（p.10–24）

**核心规则（spec 原文）**：「A Session atomically commits immutable entries, full task records, and Chord-tracked documents. Only committed state is observable.」

**8 条不变量**（第一条是全部设计的根）：

1. 一个 commit 在所有 record 与 document 写入上原子
2. document 更新只在 storage commit 成功后才发布
3. 所有可见进度都是 durable 的，**没有 volatile publication 路径**
4. 外部副作用**不得**跑在 mutation transaction 内
5. entry 与 ID 不可变、永不复用
6. callback 结束时撤回 draft；值按值复制、必须是严格 JSON
7. mutation line 贯穿 settlement 与 adoption；用户 callback 稍后、在线外运行
8. **不确定的 storage 失败对当前 Session 是致命的**

**四层架构**：Host → Harness（conversation handles / submissions / task scheduler / views）→ Session kernel（mutation line、Tx、document trackers，每次变更都是一个 commit）→ Storage（Memory / SQLite / JSONL，每个 Harness 只能有一个后端）。

**内存 vs 存储的分界**（整本书的钥匙）：storage 存真相；内存只存「总是能从 storage 重建的working set」（live tasks、已加载文档缓存、waiter 与 watch）。进程死了这些都不重要。

**一次回答要 17 个 commit**（真实 capture）。其中 commit 8 是分水岭：tool task 在 `execute()` 跑之前就把 **intent + 最终参数 + replay 策略** 落盘。

### Part 2 · Sessions and Commits（p.25–36）

- **5 种记录，1 个 ID 空间**：conversation / entry / task / submission / document，共用 `mintId()`。ID 1 保留给 root conversation。另有一个独立的 `Seq` 计数器给 commit 编号（严格递增、允许空洞）。
- ID 是普通 number + 编译期 brand（`Id<"entry">`）。回滚的 commit **会烧掉它 mint 的 ID**，这是正常的。
- conversation 的两条边长得一样但含义不同：`parent: { conversationId, at }` 是**历史继承**，`owner: { conversationId, taskId }` 是**归属/中止/空闲遍历**。owner「不是访问控制能力」。
- **mutation line**：queue，一次一个 commit。从 callback 开始一直持到 storage settle + adoption + publication 入队。callback 内先读后写，写完再读表抛 `ReadAfterWrite`；document draft 读写都可用。draft 在 callback 结束后吊销，留着再用会抛。
- commit 观察者在线内运行，**只能捕获不可变值**，不许 throw/block/调 Session API；watch 与 documentState 回调在线外跑，所以慢 UI 不会卡住下一个 commit。
- **commit 失败的三种结局**（图 2.4）：callback / settle / prepare 阶段失败 → **回滚**（可继续用，唯一痕迹是 ID 空洞）；storage 抛 `StorageRejected` → **拒绝**（可继续用）；其余 storage 错误，或 storage 成功后 adoption 失败 → **毒化（poisoned）**，之后每个调用都抛「Session is poisoned by a failed commit after storage admission; reopen it」。
- **毒化不重试**，因为两种猜测都不安全。唯一动作是 `close()`（即便毒化也能跑，顺序：Seal → Notify → Join → Settle）再 `open()`。close 不写任何 task outcome，运行中的 task 在 storage 里保持 running，等价于进程死掉。

### Part 3 · Conversations and Context（p.37–49）

- **entry 是给三个读者的三段式**：`model`（模型看到的 Message[]）、`data`（只有代码看到，模型永不可见）、`head` + `edits`（context 从哪里开始、哪些更早的 entry 要隐藏或替换）。写入后永不修改。
- 6 个内建 entry kind：`pi.user` / `pi.assistant` / `pi.system` / `pi.tool-result` / `pi.reset` / `pi.compaction`。`pi.assistant` **连失败的尝试都记**（含 error 文本与 usage），「transcript 不隐藏任何东西」。
- `pi.system` 不是 header，是**位置化的 delta**：只带 sections 补丁 + `toolsAdded`/`toolsRemoved`。稳定的对话只有一个 pi.system entry。
- **transcript → model context 有 9 条固定推导规则**（spec §2.1），核心目的是让「一个 durable transcript 合法处于的任何状态」都能变成 provider 接受的请求：找最新 head → 定范围 → 应用 edits（最新 edit 胜）→ head 排第一 → system 留在原位 → **把 tool result 按调用顺序挪到对应 assistant 消息之后** → 给没有结果的 call **合成**一个 error result（`missing_result`）→ 丢掉 aborted/error/deferred 的 assistant 消息。
- **fork**：新 conversation，`parent.at` 封顶，**不复制任何 entry**，读自己的 + 各祖先截到最小 cap 的。`asOf` 文档复制 fork 点那一刻的值，`current` 复制现值，`initial` 什么都不给。`pi.provider` 一定给新的 sessionId，`pi.live`/`pi.inbox`/`pi.usage` 一律清空，**task 与 task 文档永不复制**。
- **owned conversation**：归属某个 task（subagent 就是这么做的）。归属管的是 abort 与 idle，不是历史。
- **head 只能往前走**：指向当前起点之前的 head 写会被判 `stale` 并丢弃。reset 是 head 指向自己，所以永不过期。head 永不删除、永不换 provider ID、永不丢 system prompt（head 之后下一次请求写一份完整新 baseline）。

### Part 4 · Documents（p.50–62）

- document = 和 transcript 同一个 commit 里落盘的 typed JSON。定义是 token（`defineDoc()`），`kind` / `version` / `scope` / `history` / `fork` / `initial()` / `migrate?()` / `checkpointWhen?()`。
- **7 种合法语义组合**（scope × history × fork）。scope 定归属与寿命：session（活到手动 retire）/ conversation / task（task 结束自动 retire）。
- **只有 `tx.doc()` 会创建**，所有读方法对不存在的文档返回 `undefined`。**一次「只读的」`tx.doc()` 也是写**——要看不创建请用 `snapshot()`。
- **base / delta**：creation、换 version、`checkpointWhen()` 返回 true 时写整份 base，其余写 Chord 操作 delta。没有 `checkpointWhen` 的文档会「storage 无界增长」，storage 永不自己取 base。
- `history: "latest"` 的文档在新 base 落地时同事务删掉旧行；`"rewindable"` 永久保留，`snapshotAsOf()` 才可用。
- 旧 version 的迁移在**使用时**发生，不批量。kind 永不改名（改名会在旧文档旁边创建一个空的新文档）。
- 5 个内建文档：`pi.agent`（rewindable·asOf，存名字不存代码）、`pi.provider`（provider sessionId，用于 prompt cache 亲和）、`pi.live`（run control + 进度）、`pi.inbox`（排队项）、`pi.usage`（花费账本，失败与中止的尝试也计入）。
- `pi.live` 的 `checkpointWhen` 是范例：「没有东西在跑时写 base」，所以它的 delta 永远不会堆过一轮 tool round。

### Part 5 · Tasks（p.63–83）

- **任务 = 一串 phase，每个 phase 结束 commit 一个 checkpoint**。变量和闭包不跨重启，只有记录活下来。
- **5 个状态**：`pending` / `running` / `waiting` / `completing` / `terminal`。三个是活的；`completing` 是「结果已定但自己起的工作还没结束」。`abortRequested` 是 live record 上的**标志**，不是状态。只有 Harness 能写 pending / fault / orphan / abort mark；你的代码只能通过 `runtime.commit()` 提交 checkpoint、wait、outcome。
- **每个 phase 前的 step 有 6 条判定**，第一条匹配的胜：已 terminal/completing/waiting → 结束 → 正在 close → 有 abort mark → phase 抛错则 faulted → checkpoint 变了则继续（或交给新代码）→ **checkpoint 没变则 faulted**（"no durable progress"）。一个 phase「commit 了 entry 或 document 但没返回新 state」也算没进度。
- **memo**：task record 上的小值，**先写者胜**，用来让「同一 phase 内部的副作用」不重复（如 `printed-${n}`）。memo 不算进度。
- **effect sandwich**（spec 原文）：`commit intent → perform external effect → commit outcome`。三种收尾方式：重试安全（intent 阶段生成幂等 key 并存进 checkpoint——**key 生成在 effect 阶段就失去去重效果**）、轮询 handle、记录「可能已经发生」。
- **scheduler**：reservation 是一个 commit（查 kind → 置 running → 建 invocation）；task 的代码按 kind 查 registry。**blocked 三种原因**：`missing_task` / `task_too_old` / `migration_failed`。**「Harness 永不因为代码缺失就把 task 终结」**——只有 abort 能让它变成 `orphaned`。blocked 是派生的运行时状态，**从不持久化**。
- 重开时：running → pending（保留 checkpoint、memos、abort mark），**open 不派发任何东西**；要 `resume()` 或 submit/waitForTask 才动。reload 时 phase 边界会检查 registry，能接就 handover（old/new 代码不重叠）。
- **ownership 树**：task 与 conversation 合成一棵树。**owner 必须在创建 child 时是活的**——「在结束自己的那个 commit 里创建 child」会 fault（capture 里有真实案例，receipt 从未落库，charge 从未退款）。
- 等待策略：`allSettled` / `failFast`。`failFast` 下一个失败会给 `on` 里其余活着的任务打 abort mark（**下一个 commit**）。wait 规则：`on` 不能指向不存在的 task、自己、或自己的 owner。
- **abort 是 commit 出来的 mark，向下流、清理向上跑**。5 步：打 mark → 信号运行中的 invocation → 等自己 owned 的工作结束 → 起新 invocation 跑 abort handler → handler 提交最终 outcome。handler **不能 wait、不能创建 child**，且必须自己提交一个 terminal outcome（不交就 fault）。abort handler 可能跑多次，必须幂等。
- `orphaned` / `faulted` = **什么都没清理**，外部世界要自己查。

### Part 6 · Runs（p.84–102）

- **submission** 两种：`input`（用户消息，可能开启 run）与 `write`（加 entry，不叫模型）。**每个消息在提交的那一刻就已经落盘**。`requestId` 让重试安全（同 ID 返回同一条 submission，不产生副本），作用域限一个 conversation。
- **busy 判定只有一个**：`pi.live.run` 是否存在。`whenBusy`：`steer`（当前 tool round 结束就告知，加入当前 run）/ `followUp`（默认，下一轮）/ `reject`（抛 `ConversationBusy`，什么都不写）。
- **boundary 两种**：`postTools`（tool round 之后）取**所有 write + 第一个 steer**；`final`（run 成功结束）取所有 write + 第一个 steer + 第一个 followUp。**placement 顺序：write 先、用户消息后**。
- **失败的 run 不动 inbox**：排队中的 followUp 留在 `pi.inbox`，`wait()` 永不 resolve，直到你重新提交或撤回。
- **`pi.live`** 是 busy 标志 + 直播进度的唯一载体：`run`、`generation`（attempt / 已流出的 message / retry 等待 / deferred）、`tools[]`（callId、name、status、output so far、result entry）、`compactions[]`。**每个更新都是一次 commit，因此必须节流**：`settings.progress.partialIntervalMs` 与 `.outputIntervalMs` 默认各 100 ms。崩溃丢掉的是「上次成功 commit 之后的进度」，**且没有固定时间上界**。
- **generation 5 个 phase**：`prepare`（渲染 system prompt、检查 compaction 预算、把 model + options + `cutoff` 钉进 checkpoint）/ `request`（调模型、流式）/ `retry`（提交 `until`，重开后睡完剩余退避而不是重头开始）/ `poll`（provider 说「稍后给」）/ `tools`（等这一轮 tool call）。默认 `retry` = 首次之后 3 次，2000 ms 起、翻倍、上限 60 000 ms。
- **tool replay**：`pi.tool` 两个 phase，`call` → 提交 intent（`phase: "execute"` + 最终参数 + replay 策略，默认 `"unsafe"`）→ `execute()` → 提交 result。崩溃后**只有 stored 策略与当前策略都 safe 才重跑**；否则写一条 interrupted error result，带已提交的输出。诊断 code：`tool_unavailable` / `invalid_arguments` / `blocked` / `tool_error` / `interrupted` / `aborted`。
- run 中途崩在 request：**已提交的 partial 会变成一条 aborted assistant entry**，重开后重建保存的 context 并**重跑 beforeRequest hook**（hook 输出不落盘，可能变）。
- **compaction**：两个预算 `reserveTokens`（16384，阻塞线：超过 contextWindow − reserve 就让 generation 等它）/ `backgroundTokens`（32768，后台提前量，0 关闭）；`keepRecentTokens`（20000）决定切口（从最新往回数，落点必须落在 user/assistant 消息上，**不许切在 tool result**）。**并发 compaction 不协商，靠 stale-head 规则决出唯一胜者**（切口比当前起点更早的判 stale）。每次 summary 尝试都要花钱，哪怕最后判 stale。
- **usage**：`pi.usage` 文档在「写响应」的同一个 commit 里更新，所以账本与 transcript 永不打架。失败与中止的尝试也计入（provider 收了钱）。跨 conversation 用 `harness.usage()` 求和，**不存总量**。subagent 的花费由子 conversation 自己记，父工具再报一次就是双计。

### Part 7 · Extensions and the Agent（p.103–124）

- **代码在进程内的 registry，storage 只存名字**。conversation 的 `pi.agent` 只记 `extensions: ["coding", "reviewer"]`；没装的扩展名被跳过、不是错误。task 同理：**没有代码的 task 是 blocked，不是 failed**。
- registry 是进程局部、可以比 Harness 活得久、**不持久化**。`install(同名)` 原位置替换（优先级不变），`uninstall` 后再装会挪到末尾。位置就是优先级：后装的同名 tool 胜，后装的同名 section 原位替换。
- **7 个 hook**：`beforeRequest` / `afterResponse` / `onYield` / `afterTools`（generation）、`beforeTool` / `afterTool`（tool）、`beforeCompact`（compaction）。**作用域模型只有一个**：只问「这个 conversation 选中的扩展」的 hook，**没有全局 hook**；反过来说，扩展列表里漏掉权限扩展，那个 conversation 就没有护栏。**hook 抛错 = 拦住调用（fail closed）**。hook 可能跑两次，人的审批决定要存进 memo。
- **tool 定义**：`replay`（默认 unsafe）、`executionMode`（默认跟随 settings）、`prepareArguments`、`outputLimits`（默认 50 KiB / 2000 行 / 保留头）。`execute()` 拿到的 `api` 有 `env` / `output()` / `details()` / `diagnostic()` / `commit` / `memo` / `createTask` / `conversation`。`isError: true` 是**普通回答**（task 仍 completed）；`throw` 会让 tool task **failed** 并中止它起的东西。内建 `CodingTools`（read/write/edit/bash）**没人替你装**，且四个全是 replay-unsafe。
- **system prompt 不落盘**：每次请求从 sections 渲染；只把「变了的那一节」作为位置化 delta 追加进 transcript，从而不打断 provider 的 prompt cache。要求 renderer 确定性——**在 section 里塞时间戳会每次都生成 delta 并打掉缓存**。
- **reload while running**：没有 reload API，就是同名 install。三条规则：phase 保留它开始时的 registry 快照；下一个 phase 拿新快照；tool call 一旦开始就钉住直到写完结果。卸载/替换**不跑任何清理代码**，也没法强杀忽略 signal 的扩展代码。
- **subagents** 不是 API，是「conversation + ownership + tool」的组合。前景模式：`replay: "safe"` 的 tool 在 execute 里先 `scanConversations({ ownerTaskId })` 找已有 child（找不到才建），`requestId: "subagent:<taskId>"` 保证重跑不重复提交，`api.details({ conversationId })` 让 UI 挂到子流。后台模式：`app.subagent-anchor`（background task，立刻 completed 但保持打开）+ reporter task 逐条转发。

### Part 8 · Watching（p.125–140）

- **`documentState()`**：Chord state，attach 时先给当前值（`hydrate 0`），之后每个 commit 一次 update，带**恰好产生它的那些操作**。值不可变、结构共享（改了 title，cards 数组仍是同一个对象）。
- **Chord 操作元组**：`["r", value]` 全量替换 / `["s", path, value]` / `["d", path]` / `["a", path, text]` 追加字符串 / `["t", path, count]` 从头删 n 个 code unit / `["p", path, index, remove, items]` 数组 splice / `["m", path, permutation]` 重排。**同一个变更可以用不同元组表达，只有「结果值」有保证**。
- **`watch()` 契约 5 条**：先读 `watch.value`（早于 `start()` 的帧进 buffer）；`start(listener)` 只调一次且从不同步调用 listener；一次一个 callback（下一个等你的 promise settle，但 commit 永不为你等待）；传给你的 context 是那个 commit 的（去掉 abort signal）；`stop()` 可重复、丢未投递帧、返回 `WatchEnd.reason`（`stopped` / `cancelled` / `session_closed` / `retired` / `listener_error`）。
- **慢消费者**：watch 最多存 100 个未投递帧，第 101 个 commit 会把等待中的帧**全部换成一帧 `["r", 最新值]`**。正在投递的那一帧永不被替换。**因此 watch 不是审计日志**——它告诉你最终在哪，不是每一步。要计数就必须写进 entry/文档，或读 `Submission.wait()` 的结果。
- **conversation view**（`viewState()` / `watch()`）：`{ conversation, entries, docs }` 三块，其中 `docs` 只挂 5 个内建文档；**你自己的文档不在 view 里**，要用 `documentState()`。帧的构造顺序固定：先 document 变更（路径加 `docs.` 前缀），再按 ID 顺序排 entry（`["p", ["entries"], n, 0, [entry]]` 追加；head marker 是 `["p", ["entries"], 0, k, [H]]` 替换前面全部）。一帧里「entry 被插入」和「slot 指向该 entry」同时发生，所以渲染器永远不会看到悬空引用。
- **`watchEvents()`（experimental）**：把每个 commit 变成一批 coding-agent 事件。**事件名与 Com! 现在 Pi 扩展写出的完全一致**：`message_start` / `message_update` / `message_end` / `tool_execution_start` / `tool_execution_update` / `tool_execution_end` / `run_start` / `run_end` / `turn_start` / `turn_end` / `submission` / `inbox_update` / `agent_changed` / `usage_changed` / `auto_retry_*` / `deferred_poll` / `task_failed` / `compaction_start` / `compaction_end`。批次内顺序固定：**进度 → 新 entry → ends → beginnings**。一个 commit 最多一批；纯 attempt 变更（commit 3、16）**不产生批次**。`message_update` 只带 delta（`text_delta` / `thinking_delta` / `toolcall_delta`）；tool output 用 `{ set }` 或 `{ trimStart?, append? }`。**snapshot 可能在任何时刻到达，不只第一次**。
- **`taskGraph()`**：只显示已 commit 的事实，节点是 task record 去掉 payload；`on` 是**照实存的**（包含已结束的 task），`running` 只表示「**本进程**在跑」，background 完成后节点就消失。**graph 显示不了 blocked，因为没东西存它**。
- **`inspect()`**：不写任何东西、不跑任何 task 代码，返回 `scheduling`（paused / running / closing）+ 每个 live task 的完整记录 + 派生状态（`running` / `completing` / `waiting, on` / `blocked, reason` / `ready, migrates`）+ 排队与已放置的 submission。**「什么都没发生」→ 定位顺序**：先看 scheduling 是不是 paused（只读 viewer 永不启动调度），再看有没有 blocked，再顺着 `on` 往下追，再看 completing，最后看 running（去 `pi.live` 看 attempt / retry / 工具输出）。

### Part 9 · Storage and Environment（p.141–158）

- **Storage 接口很小，而且故意分工**：Session 检查语义（记录合法、引用、祖先、task 迁移），Storage 只检查它自己能检查的（批次原子、ID 唯一、不可变记录不变、返回副本）。**Storage 从来看不到 document 定义**。commit 一次调用，八种 write，三种 lookup + 五种 scan（cursor 不透明，且**只能喂回同一个 scan 的同一个 storage**）。
- **SQLite**：9 张表。每个记录表都是「几个查询用列 + 一列完整 JSON，JSON 是真相」。索引串是 JSON 编码存的（`kind` 列读出来是 `"\"pi.generation\""`，为了 Unicode 无损）。`durable_metadata.next_id` 是 TEXT（`node:sqlite` 拒收超安全整数）。`record_ids` 每提交一个 ID 一行，这是「ID 空间全局」的实现。WAL + `synchronous = NORMAL`：**进程崩溃不丢，断电/主机故障可能丢最新几个 commit**。`busyTimeoutMs` 默认 5000 **只是让 SQLite 等文件锁，不会让两个 Harness 共用一个文件变安全**。
- **JSONL**：`main.jsonl` 一行一个 commit marker，只增长；`doc-<id>.jsonl` 与 `task-<id>.jsonl` 是 sidecar。发布三步：先写 sidecar → 再写 marker → 才可见。**commit 存在的充要条件就是它的 marker 行完整**。`fsync` 默认 **false**（进程崩溃能活，断电不能）。open 就是一次恢复：截掉撕裂行、截掉无 marker 背书的尾部、确认过但损坏的数据**直接让 open 失败且不修复**。
- **MemoryStorage 是参考实现**：它复制每个存进与读出的记录，「刻意模拟 SQLite 编解码 / JSONL 序列化天然造成的所有权边界」。
- **conformance 23 例**，包自己跑 5 遍（memory / sqlite / jsonl / 以及每 commit 都关闭重开的 sqlite 与 jsonl）。自定义后端必须过这 23 例 + 自己的崩溃测试。
- **实测性能**（M3 Max / Node 24.13，1000 entry + 300 task + 300 doc）：精确 entry 查询 memory 0.44 µs / sqlite 2.85 µs / jsonl 0.45 µs；提交一个 entry memory 5.5 µs / **sqlite 120 µs / jsonl 792 µs**；重开并首次读 sqlite **1.33 ms** / jsonl **249 ms**（188×）。JSONL 读得快是因为它就在内存里，代价付在每次 commit 与 open。
- **ExecutionEnv**：`env` 是 host 提供的函数，**每次使用都重新构建**（tool call 得到 `api.env`、prompt section 得到 `input.env`、task phase 可以 `runtime.env()`），只允许读 committed state。返回 `undefined` 就关掉文件与 shell 工具。`id` 命名文件命名空间（Node 本地一律 `"node:local"`）。`exec` 支持**数组形式**（参数不经 shell，模型/用户来的参数应优先用它）；所有操作**返回结果而不抛**（`{ ok }` 或 `{ ok: false, error: { code } }`）。**重跑会按「当时的 cwd」重建环境，可能和第一次attempt 不是一个目录**。

### Part 10 · In Practice（p.159–171）

- 组装一个 coding agent = registry（代码）+ settings（策略）+ env 函数 + `pi.agent`（对话级选择，只存名字）。「**改设置不产生 commit**」。
- **38 条 API footgun**（spec §12），按「在哪里咬人」分组，每条给症状 + 正确做法。三条自查题能抓住大部分：「commit callback 里有没有 await 会离开进程？」「有没有代码写了自己不拥有的 run 的 conversation？」「有没有消费者改动了自己读到的值，或依赖看到每一次更新？」。**「几乎没有一条是运行时检查的」**（registry 只查 section key 与单扩展内 tool 名唯一）。
- **11 条 non-goal**：whole-Session DOM / visible-undurable publication / Session 级语义事件日志 / session 级可回退文档 / 自动 checkpoint 启发式 / 自动挂载第三方 view / CRDT 离线多写合并 / Chord 操作的 SQL 翻译 / JSONL 全局压缩或修复 / 兼容被移除的 Pico 原型 / **强制终止扩展代码**。
- **一个 storage 只能有一个进程**：「没有跨进程锁」。两个进程开同一个文件，各自都会以为自己唯一——`SqliteStorage` 各自 mint ID，第二个 commit 会失败并毒化，或**静默覆盖**对方的 task/submission。**崩溃恢复是 host 的事**：得有人发现进程死了、重启、重开 storage。**open 本身就是一次写**（它提交 running→pending 的复位），所以 dashboard 不能「就打开一下」别人持有的 storage；但 SQLite 可以另开只读连接安全地读实时库（capture kit 就是这么读 mid-run 行的）。
- **「Inside and outside the guarantee」表**：Harness 保的是「从最后 checkpoint 恢复 / 一次 reopen 把所有 running 复位 / 每个 storage 一条 mutation line / intent 先于 effect / beforeTool 能拦 / storage 只开出一致状态」；host 要自己建「监督重启 / 保证一个 storage 一进程 / 远端 exactly-once（幂等 key）/ 用户与鉴权（API 里没有 user 概念）/ 备份」。
- **Pi CLI session vs Pi Durable 对照表**（§10.3）：两者共享 transcript 的想法（append-only entry、位置化 system delta、保留原始 entry 的 summary），差别在「一次写入意味着什么」——**Pi session 的一行记录「发生了什么」；Pi Durable 的一次 commit 记录「允许被看见的状态」，包括还没做完的活**。

### Reference（p.172–190）

Harness / Conversation / Tx / TaskRuntime / ToolExecutionApi / Registry 的逐个方法表；6 个 entry kind + 5 个 document kind + 3 个 task kind；完整默认值表（`retry.maxRetries 3`、`baseDelayMs 2000`、`maxAgentDelayMs 60000`、`compaction.reserveTokens 16384`、`keepRecentTokens 20000`、`backgroundTokens 32768`、`progress.*IntervalMs 100`、`thinkingLevel "off"`、`whenBusy "followUp"`、watch 100 帧、bash 保留 tail、其余 tool 保留 head）；error class × 7、submission reason × 9、task outcome × 5、blocked reason × 3、tool diagnostic × 6、watch end × 5；glossary。

## 4. 对 Com! 的适用性

### 4.1 分层对照

| 层 | Com! 现状（2026-10-08，802） | pi-durable 提供 | 判断 |
|---|---|---|---|
| 任务/事件真源 | Com SQLite：`tasks` / `events` / `inputs` / `outbox`，`execution_status` + `verification_status` + `uncertain` + `approval_required` + `block_reason` / `blocked_by` | TaskRecord 5 状态 + memo | **Com 更宽**。换过去是缩水 |
| 执行器 | Pi RPC supervisor（`pi_rpc.py`，有 accepted/handled/delivered 三级 ACK、`agent_settled`、断线标 uncertain 不重放）、Claude Agent SDK、Codex app-server | 自带 `pi.generation` / `pi.tool` / `pi.compaction`，只覆盖 Pi 一家 | 换过去要放弃原生 CLI 能力，且另外两家还得自己留着 |
| 客户端同步 | `events.jsonl` 全量重读 + `/live?after=` 轮询 + SSE snapshot/update | `watch()` frame + `applyImmutable()` + 100 帧合并 + `watchEvents()` | **参考价值最高的一层** |
| 存储 | 自建 SQLite（已开 WAL） | SQLite / JSONL / Cloudflare Durable Objects，带 conformance 套件 | 不需要换；`record_ids` / JSON-is-truth / 索引列 JSON 编码是可选参考 |
| 鉴权 | 配对码 + Bearer token + Keystore | **API 里没有 user / account / credential 概念** | pi-durable 缺这一层，不构成理由但说明它不是成品后端 |
| 语言 | Python 3.12 后端 | TypeScript / Node ≥ 22.19.0 | 引入即多一个运行时 |
| 交互设备 | Android + iOS + 折叠屏 + 语音小窗 + 终端 | 无 UI，无传输层 | 不重叠 |

### 4.2 不引入的具体代价

1. **必须写 Node sidecar**，Python 与 TS 跨语言管理会话状态；或者后端换语言——都不是小改动。
2. **单进程独占 storage，且没有跨进程锁**。Com 现在是单后端，勉强能接受，但「dashboard 不能只是打开一下」「open 本身是一次写」会让运维多一层注意；将来想多实例就没了。
3. **放弃 Pi CLI = 放弃 skills、扩展、MCP、原生 session、手机端已有的完整终端入口**。Com 的 Pi 适配器是围绕 CLI 写的；换 harness 等于重做一个 Pi。
4. **`visible-undurable publication` 是明确的 non-goal**：流式文本只能按 commit 节奏（默认 100 ms，且崩溃时丢失窗口无固定上界）出现，没有「先给 UI、后落盘」的快路径。Com 现在是扩展事件 100 ms 节流 + SSE，体感接近；但如果哪天想把流式做得更跟手，pi-durable 明确不给这个能力。
5. **没有 Pi CLI 会话迁移路径**（non-goal：「compatibility with removed Pico prototypes」+ 手册明确说 coding agent 保留自己的 session 文件）。Com 的历史索引要永远继续读原生 JSONL，或者分叉。
6. **API 4 天 3 个 breaking release**，手册自己提醒「check the CHANGELOG before you rely on a detail in a later version」。要引入必须 pin 版本 + 每次升级跑 conformance。
7. **没有强杀扩展代码的能力**：忽略 abort signal 的 handler 会让 `close()` 一直等。要真隔离只能把扩展跑在单独进程/worker 里——正好是 Com 已经在做的事（tmux / RPC 子进程）。

### 4.3 可以零成本直接抄的 6 条

1. **tool 的 `replay` 声明（默认 unsafe）**。Com 现在是统一策略「uncertain 一律不重放」，比 pi-durable 保守，但**表达力更低**——一个只读工具本可以安全重跑。给 Pi 扩展 / MCP 工具 / 业务工具加一个 per-tool replay 声明，就能在崩溃后把只读类调用自动补完，把写类调用留成 uncertain。
2. **effect sandwich 显式化**：`intent（含幂等 key）→ effect → outcome`，且**key 必须在 intent 阶段生成并落盘**。Com 的 `tasks.py` 已有 ACK / uncertain 分层，但「先落 intent 再执行」值得在 task 执行器里做成硬约束，而不是靠调用方自觉。
3. **不确定的存储失败 = 致命，不重试，close + reopen**。Com 现在 `unknown` 状态没有这条纪律。把它写进任务层契约（`TASK_LAYER_CONTRACT.md`）能消掉一整类「内存与磁盘悄悄分叉」的隐患。
4. **watch frame 协议**。Com 的 SSE 可以让 `snapshot` 与 `update` 用同一套 op 语言（`["s"|"d"|"a"|"p"|"r", path, …]`），客户端只实现一个 `applyImmutable`；溢出时发一帧 `["r", 最新值]` 全量替换。现在 Com 用的是「全量重读 events.jsonl 再重建 items map」，这套能同时减少 payload 与客户端复杂度。
5. **`taskGraph()` 与 `inspect()` 的分工**。graph 只显示已 commit 的事实（**显示不了 blocked，因为没东西存它**）；inspect 才回答「调度器会怎么做」。`missing_task` / `task_too_old` / `migration_failed` 这套「为什么卡住」的词汇表，可以直接借到 Com 任务页的「执行中 / 待你决定」诊断里——Com 现在有 `block_reason` / `blocked_by`，但没有「因为代码版本不匹配而永远不会自己动」这个类别。
6. **「watch 不是审计日志」**。合并会跳步。Com 用事件流做通知与动画——**通知必须基于落库的 entry/task 状态，不能基于事件计数**；动画可以接受跳步。这条正好把 Com 现有的事件队列消费逻辑的边界说清楚了。

### 4.4 第七条（可选，优先级独立）

**`@earendil-works/chord` 可以单独用，且不依赖 Pi。** 它的官方定位就是「一个功能可能要在多个环境跑：agent worker、TUI、remote WebUI」，提供 facets / plugins、typed services、**replicated state、可插拔的远程服务边界**，且「不依赖任何其他 Pi workspace 包，可以被无关应用使用」。Chord 1.1.0 是 pi-durable 的 `watch()` 底座。

如果哪天真要重做 Com 的手机端 ↔ mini 状态同步（而不是继续用 SSE snapshot/update），**chord 比 pi-durable 更贴近需求**，且不必接受「换掉 Pi CLI」的代价。这条建议先记着，不要现在动手。

### 4.5 什么情况下回头用它

反过来才有正当理由：

- 新做一个**与 Com! 隔离**的、单 Agent（Pi 家）、不需要原生 CLI 能力的产品；
- 或者需要一个跑在 **Cloudflare Durable Objects** 上的无服务器会话后端（`openDurableObjectSqliteStorage` 已提供）；
- 或者需要一个**别人审得动**的、有 conformance 套件与 spec 的 agent 运行时。

到那时等 1.x 稳定、pin 版本即可。

## 5. 这份手册本身的价值

即使不引入，它值得作为设计参考长期保留：

- 「Contracts that bite」那 38 条 + 三条自查题，可以直接当 Com! 任务层/事件层的 code review checklist。
- §8 的 watching 与 §6 的 submission/boundary 是「远程客户端 + durable agent」这一对问题的少见完整答案，Com! 正好站在同一个问题上。
- §10.3 的 Pi CLI vs Pi Durable 对照表，是理解「Com 现在为什么这么写」的好镜子。
- 反面价值同样清楚：**它明确写出「不做什么」**（11 条 non-goal + 「Inside/outside the guarantee」表），这比承诺更有用。

## 6. 遗留与未验证

- 本次**没有安装、没有运行** pi-durable，所有性能数字来自手册引用的 M3 Max 基准，不是本机实测。
- 手册写的是 1.0.3；1.1.0 已改 `Storage` 查询 `order`、`TaskRuntime.context()` 签名，并新增 `startedAt` / `endedAt` / `durationMs` / `contextRetentionMs` / Cloudflare DO SQLite 存储。若真要动手，先读 1.1.0 的 `CHANGELOG.md`。
- 本机 `pi` 仍是 **0.85.1**（最新 1.1.0）。这个版本落差与本文结论无关，但会影响「Com 的 Pi 适配器能不能吃到上游新能力」——是另一件事，未在本次评估范围内。

## 附：本次使用的中间产物

- 拆章文本：`/tmp/pidur/{ch01…ch10,ref}.txt`（按印刷页切分，`c-*.txt` 为压缩版）
- npm 包快照：`/tmp/pdup/package`（pi-durable 1.1.0）、`/tmp/chd/package`（chord 1.1.0）
