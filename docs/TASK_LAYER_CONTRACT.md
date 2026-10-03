# 任务层后端契约（Mac mini）

> 2026-10-03 修订，以用户当前决定为准。取消 Flash 模型对照实验，直接用现有模型；运行时接入必须验收。实际实施状态见 [实施记录](COM_PI_MAIN_IMPLEMENTATION.md)。

## 一、角色、真源与迁移

Pi 是唯一主线和主要执行者，允许直接使用原生 Shell、读写文件与业务工具；根据实际效率自主选择直接执行或独立 Pi / Claude / Codex，不强制派活或指定项目执行器。工作页仍提供 Claude / Codex 手动入口。主对话 UI 身份固定 personal-main，旧消息、request_id 与任务 origin 不改写。运行时映射记录原 Hermes com-personal-main 与新 Pi 会话及切换边界。Goal、任务、结果与事件真源是 Com SQLite，长期知识是 AI_Work_System。

## 二、共同工具和能力

capability_search / task_submit / task_status / task_send / task_cancel 由传输无关服务提供；Hermes MCP 旧名称保持兼容，Pi 扩展使用同一服务。

能力按 host/runtime/project/config_version 登记。文件扫描只表示 discovered；运行时工具报告表示 loaded；安全真实探针或真实成功表示 verified（24 小时）。配置、依赖和版本变化失效，失败 unavailable。派发前检查健康；测试数据不计生产验证，跨机不可互认。

## 三、授权契约

候选判断必须同时绑定真实用户消息、可定位动作、当前交办或已有授权。支持句中动作与上下文续办，不要求固定动词开头；无法确认则留在主线或记录候选。情绪、愿望与引用指令不触发操作。A/B/C 续答必须关联同一对话紧邻的真实助手选项及其已有明确用户交办，记录原消息关联；不能由愿望或引用派生授权。用户自行采纳示例是新用户交办，不能因为与助手示例相同就拒绝。

已授权范围内宽权限执行。审批依据实际动作、对象、可恢复性：永久删除、破坏性覆盖、未归类高风险删除需具体批准；可恢复归档记录恢复路径。工具真正执行处落实约束，模型提供的“已授权”不是真源。

任务持久绑定 owner_conversation_id；执行器不能接管事项责任。后续补充不得扩大原授权。ACK 只表示受理，关联实际输入事件后才送达；未知输入不重发。取消以真实终止事件为准。

## 四、事件与结果

时间线由真实 created/started/tool.started/tool.completed/tool.failed/waiting/execution_finished/failed/cancelled/verification 事件生成。结果包含 execution_status、verification_status、summary、artifacts、evidence；uncertain 单独记录。自由文本完成、RPC ACK、执行结束都不等于验收通过。

Pi RPC supervisor 新建，负责生命周期、退避、会话续接、持久输入和中断；agent_settled 才结束。原生事件先适配内部事件，再维持 snapshot/update SSE。进程/连接中断标 uncertain，不自动重放。

## 五、文件、资源与预算

所有执行落在 mini。主线原生 write/edit 在工作区内保存恢复副本，恢复记录绑定原 request_id；它不等同后台任务的 OS 隔离。主线 Shell 也按真实高风险动作检查并保留副作用去重，未分类的删除/覆盖不能绕过。后台项目任务使用同步目录外独立副本，包括未提交修改；验收后串行合入，检查基线与 Syncthing 冲突，冲突保留补丁停止合入。最多两个后台任务，Claude 最多一个。

Claude Agent SDK 继承已有第三方 endpoint/凭据；按用户补充决定，仅 Com 的模型覆盖为 deepseek-v4.1-flash，全局配置保持不变。真实调用、续接、中断、工具兼容通过才可用。默认每天三个自动任务、每任务十二轮；续接占同一任务额度，用量和金额无法核验时明确未知。

## 六、目标与验收

LaunchAgent 保持 FastAPI，task_loop 负责执行状态。事件队列单一主线消费者，用户消息优先，后台事件沿原授权，不伪装用户。调度器只登记事件；09:30 Asia/Shanghai，空闲不调用模型。目标调度真机验收后启用。

隔离 fixture 与固定时钟测试断线、压缩、重复事件、进程终止、写入成功 ACK 丢失；协议和恢复全部通过，重复副作用/误报成功零。固定端到端场景各两次，随后手机主页/工作/语音/折叠屏/恢复验收。Hermes 可回滚，已投递或 uncertain 不重发。生产账本不用于探针。
