# M3 分类与状态展示

2026-10-03。沿 M2 的 153bf1c 继续。

- 授权来源 `entry=work_page_human_chat` 读取时派生为 chat；不出现在任务列表与派发卡。旧来源缺失记录默认 job，不改历史数据库。
- 工具步骤仍由 AgentWorkCard 呈现。job 的用户决策依据 ledgerGroup；四类展示为在办、等我、待确认、已结束。取消中为正在停止，unknown 为需要你核实，验收与执行结束保持区分。
- 详情进度只展示 events 中实际出现的受理、排队、原生开始、执行结束及真实 acceptance；无证据的阶段不高亮。
- 工作聊天禁止 task verify；已有工作聊天续聊不要求验收的路径保留。

验证：后端分类、连续性与 manual_work 44 项通过；Android debug JVM 与构建成功；模拟器 TodayTaskExperienceTest 与 MessageTaskCardExperienceTest 6 项通过。

旧 TaskLedgerTest 的 cancel_requested 文案期望从取消待确认改为正在停止，语义保持等待执行器确认。
