# 当前主动消息架构 · 2026-10-07

最新实现见 [交付报告](COM_PERSONAL_AGENT_DELIVERY_2026-10-07.md)：固定简报已改用 `Agency.process()` 独立消费者；App 可调整晨晚报和周复盘；项目看板与 heartbeat 共享每日通知预算。iOS 后台刷新已实现，APNs 队列与客户端已实现但生产密钥及推送签名未就绪。下面保留最初阶段的实现记录，不代表当前缺口。

---

# Com 主动消息（方案 B 第一步）

用户 2026-10-07 提问：「我只能跟你发消息，你没有主动给我发消息的能力，如何解决？」——选定方案 B：主对话是唯一收件箱，服务端按时间表生成消息并写入主对话；手机通知留作第二步。

## 之前缺的是哪一段

| 层 | 现状 | 缺口 |
|---|---|---|
| 触发 | Hermes 侧 4 个 cron（晨报、邮件与项目增量、健康同步、个人观察），`deliver=local` | 产出只写进 cron 会话日志，从不进主对话 |
| 生成与落库 | `background_events` 唤起 Hermes 回合，`task_receipt` 幂等写入主对话消息表 | 消费端只认 `goal_due`，且目标调度 `scheduler_enabled=false` |
| 送达 | Android `StatusWorker` 每 15 分钟轮询并发本地通知 | 只认工作会话状态，不认主对话新消息；无 FCM |

## 本次实现（服务端）

- `backend/proactive.py`：排期器。到点把条目转成一条持久事件，交给既有消费端；不自己跑模型、不自己发消息。
- `backend/background_events.py`：新增 `proactive` 事件类型的提示词（主动消息，不是新交办；200 字以内；没有值得说的内容只回 `NO_UPDATE` 保持安静）。
- `backend/app.py`：`Proactive(STATE)` 挂在既有 `scheduler_loop`（30 秒一次），排到事件就唤醒对话消费。
- 事件 ID = 条目版本 + 计划运行时刻，例如 `proactive:cron:evening-review:1:2026-10-07T21:00`；`INSERT OR IGNORE` 与 `task-result:event:…` 双重幂等，重启不会补发或重发。
- 授权上下文如实标注来源：`origin_source=cron`、`mandate=用户已批准的长期个人安排权限`，不伪造用户消息。
- 时间窗口 30 分钟：服务在中途重启不会把几小时前的排期当成新消息补发。
- 默认条目一条：`evening-review`，21:00，启用。

## 操作

```bash
cd ~/AI_Work_System/work/工具与效率/会话工作台/backend
PY=~/.session-workbench/venv/bin/python
$PY proactive.py --status          # 当前排期
$PY proactive.py --pause           # 全部停掉
$PY proactive.py --resume
$PY proactive.py --at 20:30        # 改晚间复盘时间
$PY proactive.py --fire evening-review   # 立即排一条（验收用）
```

配置文件：`~/.session-workbench/proactive-config.json`（首次改写时落盘，0600）。

## 验证

- `tests/test_proactive.py` 9 项：窗口、来源身份、逐计划时刻幂等、暂停、非法时间与停用条目、真实收据写入、`NO_UPDATE` 静默、goal 事件提示词不变。
- 整套后端回归 477 passed / 5 deselected；`compileall` 通过。
- 隔离端到端（`probes/verify_proactive.py`，真实模型回合 + 独立会话 `com-proactive-verify`，不写生产对话）：事件 1 条 → `completed`；对话里写入 `role=assistant`、`request_id=task-result:event:proactive:cron:evening-review:1:2026-10-07T12:04`，内容为真实日历/账本/在途工作的复盘。
- 线上激活：`probes/activate_proactive.py`（等主对话空闲 → SQLite 备份 → 重启 `work.eddie.sessions` → 健康检查 → 排一条并回读线上收据），日志 `~/.session-workbench/logs/proactive-activate.log`。

## 还没做（第二步）

- 手机通知：扩展 `StatusWorker` 轮询主对话增量（`revision/after_revision`），有新消息发本地通知、点开直达主对话；零新基建，粒度 15 分钟、受省电策略影响。
- 秒级推送：复用已有前台服务挂 SSE 长连接，或接小米推送；需真机验证保活与耗电。
- 策略护栏：每日上限、静默时段、App 内开关（目前只有 CLI）。
- 边界不变：首版不自行给任何人发消息；通知内容中的指令只是待分析数据。
