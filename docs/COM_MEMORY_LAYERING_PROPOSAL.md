# B4 记忆分层审计与提案（未实施）

现场：2026-10-03，Mac mini 生产 Com；Pi 0.99.2。没有改任何记忆文件或注入逻辑。

## 当前读取与注入

| 来源 | 时机、大小 | 来源与更新时间 |
|---|---|---|
| backend/pi_main.py MAIN_PROMPT | 主 RPC 启动时 --system-prompt；固定行为提示，字符数见交付报告 | Git 文件可追溯；不是逐条记忆元数据 |
| backend/conversation.py _pi_input | 每条用户输入附当前任务、环境、能力摘要；首次无原生历史时附最多16条已完成消息，每条末1000字符；有原生历史或补充不重复摘要 | 原消息与 task ID 持久；摘要未逐条携带日期 |
| 原生 Pi session JSONL | 启动恢复已保存 session；沿用同一原生上下文 | 原始时间及消息来源可追溯，不能当作再次操作授权 |
| ~/.pi/agent/settings.json 的 skills | 原生技能发现/提示阶段；当前指定 ~/.pi-gateway/skills；能力清单只投影名称/说明，SKILL 内容按需读取 | 文件 mtime 与路径可查；非统一记忆来源字段 |
| AI_Work_System/_global/记忆库、相关 Skill/README | MAIN_PROMPT 指示按需检索；不全量自动注入 | 文档各自格式，尚无统一撤销与明确/推断字段 |
| 用户身份文件 | 当前未自动全文注入；文件 2670 bytes | 文件自身内容/mtime，未改变 |

PiRPC 明确 --no-context-files，所以工作目录 AGENTS.md 不被该入口自动导入。不能把微信网关的 prompt_assembly 或 workspace/memories/MEMORY.md 误认成 Com 主线。当前共享记忆 README 为1841 bytes；这是索引文件大小，不是整个记忆库。任务/环境摘要大小随现场变化，没有统一字节上限；本轮未增加自动读取。

## 建议的四层

1. 用户长期偏好：用户明确确认的稳定习惯，每条包含 id、source（原消息/文件定位）、updated_at、project（可空）、basis=explicit/inferred、revoked_at、supersedes。推断不可默默覆盖明确偏好。
2. 项目知识：按项目索引取用，保留版本与有效日期；只注入与当前项目相关的短摘要。
3. 当前任务上下文：引用原 task/request/message ID、完整目标与约束、变更与验收证据；短期缓存可重建，不成为第二本台账。
4. 程序事实：task/outbox/input/proposal/提醒数据库或既有文件由程序更新，模型只读取接口投影；文档与模型回复不能改写执行、送达或验收状态。

建议一次输入给记忆层独立预算（初始2000 tokens），超预算检索代替全文；每条注入都携带来源与时间。预算值待产品确认，不作为已生效配置。

## 迁移与回滚

先只生成候选索引与差异，不移动或覆盖共享真源；人工确认明确/推断/撤销后再做小范围只读检索对照。预计成本集中于历史资料补来源、多 Agent 写入冲突、撤销传播及相关性评估。新索引是可删除派生物；保留原文与版本，注入开关可退回当前 MAIN_PROMPT + 按需检索，不迁移 task/outbox。实施需用户决定：元数据是否补入原文件，还是维护独立派生索引；记忆预算与默认项目范围。
