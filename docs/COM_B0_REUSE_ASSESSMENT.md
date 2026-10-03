# B0 开源借鉴评估

2026-10-03，只读浅克隆到 `/tmp/com-research/{pibot,pi-chat,pi}`，未安装依赖、未运行任何上游服务、未加载外部扩展，未向第三方代码提供凭据。以下是本次实际源码而非任务书旧快照。

## 快照与许可

| 仓库 | SHA | 最新提交时间 | LICENSE |
|---|---|---|---|
| glebis/pibot | 3fb1162742ac35b1b59f41d441bbd3e76672474b | 2026-10-02 18:53:38 +02:00 | MIT，版权 Gleb Kalinin 2026 |
| earendil-works/pi-chat | 9adbd29b40ee27ff1decf0fc87cbe180b40924f5 | 2026-06-05 12:26:44 +02:00 | Apache-2.0，以 LICENSE 为准 |
| earendil-works/pi | 4c6fb7cfe8c538a668726f6f8b3554098c39faee | 2026-10-03 14:21:11 +02:00 | MIT，版权 Mario Zechner 2025 |

本任务全部重新实现，只参考设计，不复制第三方源码。上游链接：[pibot](https://github.com/glebis/pibot)、[pi-chat](https://github.com/earendil-works/pi-chat)、[Pi](https://github.com/earendil-works/pi)。不采用 star 数作为结论。

## A 事实核查

1. **pibot 的二手说法在当前版本确有对应实现**，与任务书的旧 README 观察不同：`src/core/capabilities.ts:53-78` 定义工厂、allowlist、可用性与描述；`agent-manager.ts:185-241` 实际解析加载；`capabilities.ts:203` 接入 agent-comms，`:229-232` 接入 delegate_cli（按 manifest opt-in）。`index.ts:15,185,231-260` 接入 Jev 影子观察、可选 goal Judge 与 Web App；`core/jev-evaluator.ts` 是实际评测实现，`core/evolution.ts:441` 明确影子 Jev 不影响评分/晋升。这些不是只存在 README 的占位。Web Dashboard 实现在 `src/web.ts`，`index.ts:260` 初始化，身份认证在 `web-auth.ts`。不能把这些与 Com! 的既有能力注册表或完整权限策略混同。
2. 心跳：`core/heartbeat.ts:295` 默认45分钟，manifest可改，min/max为5分钟/12小时（`:636-639`）；`:309-329` 检查 enabled、snooze、quietHours、两次无回应退避、15分钟近期用户活动。`:372-445` 建临时 inMemory 会话、thinking off、清除普通扩展/技能/上下文，只给 heartbeat_act（晨报另给 calendar_today）。模型由 heartbeatModelWithFallback 及 manifest/cascade 选择，允许提供者限制；不是固定厂商。工具提示 exactly once，但 execute 用 called 布尔标记与 Object.assign，不应当成强制“第二次调用绝不生效”的安全边界。
3. 摘要 `heartbeat.ts:595-672`：persona截800字符、memory截1200字符，最多6个日程/8条事件，再附节奏、维护、backlog与可选research；因此常见输入是千级token，但尾部可变，源码未给硬token上限。实际tick token量需要usage实测，本次不运行上游，不宣称具体数。
4. 提醒 `plugins/scheduler-plugin.ts:19-21,42-75` 创建即 cardPending，按钮完成/推迟10分钟/1小时/取消映射到真实scheduler。`promise_make:82-137` 在截止前24小时预检，若过近则取剩余时间中点且至少5分钟，预先assertCapacity确保一或两个槽位；仅截止前可添加预检。
5. 技能 `core/evolution.ts:52-89` 检查命名、描述至少10字符、15KB体积、正文结构；风险pattern含exec/fetch/POST/eval/child_process/rm-rf等；patch要求唯一命中。`:116,134-140` proposal带task/criteria探针，由加载候选的会话执行并评分。`:442-492` 平均分>=4且无风险pattern才自动晋升，否则暂存；`:629-656` 晋升并尝试git commit，提交失败被捕获，并非一定成功。Com!不采用自动晋升。
6. pi-chat 两层记忆：`src/config.ts:80-81` 账号shared/memory.md与频道workspace/memory.md；`index.ts:531-540,808-819` 读取并构造上下文，在 `before_agent_start:1371` 使用。`safeReadMountedText:141-156` 校验真实路径在挂载内、regular file、NOFOLLOW，但读取全文，未见字节上限或每条来源/时间元数据，不能直接移植。
7. 秘密：`src/secrets.ts:10-21` 每次生成RSA2048公私钥，公钥/请求号进入pi.dev/secret的URL fragment，私钥只在进程内pendingSecrets Map；`:23-49` 收到密文后RSA-OAEP-SHA256解AES key，AES-256-GCM验签解密，成功移除请求。`index.ts:683-697` 在沙箱文件 `/workspace/.secrets/<name>` 写真实密钥，仅把占位通知送入会话。此机制避免正文传密钥，但不能说同权限Agent永远无法读秘密文件；Com!不引入该沙箱。
8. pi-durable `packages/durable/README.md:1-7,80,103-106,523-529` 明示Experimental、API可变；把对话/model turns/tool calls/自定义document state原子commit，Memory、SQLite WAL、JSONL存储，单进程拥有且无跨进程锁。具备 child tasks/task graph（README目录及对应章节），与Com task/outbox/input持久层大幅重叠。未知副作用恢复语义仍须应用裁决，不能用它替换既有链路。
9. chord `packages/chord/README.md:1-35` 是独立应用组合运行时，facets/plugins、依赖验证、typed services与replicated state、可插远程服务边界；不是Com需要立刻引入的任务框架。

## B 映射与决定

| 设计 | 来源 | Com已有 | 差距 | 采用方式 | 风险 |
|---|---|---|---|---|---|
| settled/ACK语义 | Pi docs/rpc.md:60-71 | pi_rpc.py的agent_settled、clear_queue、原生回显来源 | handled prompt仍可能等待终止事件 | B1可复现后修复 | 不能把ACK当执行完毕 |
| ephemeral heartbeat | pibot heartbeat.ts | goals scheduler关闭、task/proposal | 无低成本影子观察入口 | B2重新实现后端驱动 | 主会话污染、预算、静默 |
| 提醒动作卡 | scheduler-plugin.ts | mini remind扩展reminders.json与日历 | 无一键推迟/确认 | B3复用原提醒记录 | 跨进程并发写、微信到点触发 |
| 两层记忆 | pi-chat index.ts | AI System共享知识、按需检索 | 来源与撤销元数据不统一 | B4仅设计四层 | 多Agent迁移、注入膨胀 |
| 暂存评测 | evolution.ts | workspace skills/Git | 缺人工晋升流程 | B5仅设计 | 完整权限下不是访问控制 |
| 加密secret交换 | secrets.ts | 私有凭据文件/执行器env | 部分上下文/日志防泄漏需审计 | B6仅设计 | 占位不等于不可读取 |
| durable/chord | durable/README、chord/README | task/outbox/input/来源 | 现有Python与SQLite已满足核心持久边界 | 不引入，后续仅参考 | 双真源、实验API与自动重放 |

三个决定：

1. 当前不值得用pi-durable替换或补充生产task/outbox/input；未来若全新隔离应用可参考原子发布设计，本次不增加运行时。
2. 心跳由Com后端驱动独立临时会话，严格隔离主会话；主Pi不增加第三方扩展。影子只写观察日志；受限升级为现有proposal，不绕过用户批准与来源快照。
3. 成本/收益顺序：B1协议核验最高优先，B3原提醒卡直接收益，B2先影子；B4–B6只交提案。实际remind只有add/list/cancel，推迟/确认需要对同一个真实记录更新，不能另建提醒库。
