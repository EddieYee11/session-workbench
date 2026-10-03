# B2 心跳落点与边界

用户可编辑清单确认为 AI System 内现有项目根目录：work/工具与效率/会话工作台/HEARTBEAT.md，不建根级新目录。

由Com后端独立调用已有Pi ModelRuntime，一次性context、单工具结构化决定、最多一次调用；不经过主会话，不加载第三方包或扩展。默认影子：只写heartbeat-events.jsonl观察，不建task/proposal/通知。诊断与暂停在设置；手动受限启用后，speak仅今天知情区，escalate仅既有proposal等待批准。目标定时调度保持关闭。

## 已实现护栏与现场验证

每小时一次、每日最多24次、23:00–08:00静默、运行中任务超过3条跳过、同原因/同动作6小时去重。摘要按运行/待核实优先，包含待批准 proposal、近期事件及最多500字符清单；输入UTF-8≤2600 bytes，输出≤512 tokens，总返回usage>4096则拒绝。超预算与解析/SDK失败静默，停止受限副作用。重启从最后记录恢复间隔，暂停后丢弃尚未返回的决定。

SDK0.99.2的OpenCode Go接口需要x-opencode-session路由头。每次用新的com-heartbeat-UUID作为sessionId，保留cacheRetention=none；不加载agent/session/extension，不复用主缓存。SDK把off钳制到low，故通过原生onPayload显式disabled thinking并要求唯一工具决定。未升级Pi或变更其配置。

现场两轮真实模型影子决定均为nothing，摘要1155/1356 bytes，无错误，无通知路径，task/proposal数量前后17/3不变；POST暂停后tick立即skipped=paused，随后恢复默认影子。诊断shadow_verified=true；受限启用仍OFF，必须由用户亲自开启。单位测试覆盖两次成功门禁、预算、静默、去重、暂停中断、模型失败、重启间隔及SDK独立路由标识。
