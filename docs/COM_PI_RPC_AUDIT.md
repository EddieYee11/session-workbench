# B1 Pi RPC 协议对照审计

2026-10-03。mini实际Pi0.99.2、Node25.9.0；upstream coding-agent为1.0.1，Node要求>=22.19；GitHub latest页面当前指向v1.0.0（https://github.com/earendil-works/pi/releases/tag/v1.0.0），与main中的1.0.1不同；API请求403，采用官方发布页面核验。本任务不升级生产Pi，不改settings。文档本次已拆分rpc-commands/json，新版字段兼容旧ACK未带disposition。

## 关键语义

- prompt ACK只表示接受/排队/处理；Com在prompt前建立事件队列，避免快速结束丢事件，以agent_settled结束而不是agent_end（官方rpc.md:60-71）。
- steer/follow_up只保证队列ACK。Com使用steer，原生message_start匹配Com input request_id后才切换来源、确认delivered；无echo不认为送达。follow_up未调用，当前无需增加。
- abort可能继续残留队列；rpc-commands.md:107-128要求先clear_queue再abort，Com已按此实现，并在结束race清队列。cancel_requested仍是等待确认。
- new/switch/fork/compact/session stats/模型/思考级别设置等未提供入口不是缺陷，不凭文档新增执行路径。

## 已复现修复

rpc.md:67：disposition=handled不会启动原生run，不应等待agent_settled。旧stream忽略ACK.data可能等待1200秒；test_pi_rpc_handled.py在无settled的隔离假RPC中先失败TimeoutError（/tmp/com-b1-before.log），修复后37项相关测试通过。

修复：解析prompt ACK；handled返回input.handled与done，不发run.completed、不声称执行完成。主线如实显示扩展已处理但需核对结果；未知不重放，身份与队列语义不变。

升级建议：先隔离跑新版原生回显/steer/abort/queue/settled契约，再另行安排升级；本次只兼容可选disposition。

## 官方命令全集

| 命令 | Com现状 |
|---|---|
| prompt | 已调用 |
| steer | 已调用 |
| follow_up | 未调用，不自动增加 |
| abort | 已调用 |
| clear_queue | 已调用 |
| new_session | 未调用，不自动增加 |
| get_state | 已调用 |
| get_messages | 未调用，不自动增加 |
| set_model | 未调用，不自动增加 |
| cycle_model | 未调用，不自动增加 |
| get_available_models | 未调用，不自动增加 |
| set_thinking_level | 未调用，不自动增加 |
| cycle_thinking_level | 未调用，不自动增加 |
| get_available_thinking_levels | 未调用，不自动增加 |
| set_steering_mode | 未调用，不自动增加 |
| set_follow_up_mode | 未调用，不自动增加 |
| compact | 未调用，不自动增加 |
| set_auto_compaction | 未调用，不自动增加 |
| set_auto_retry | 未调用，不自动增加 |
| abort_retry | 未调用，不自动增加 |
| bash | 未调用，不自动增加 |
| abort_bash | 未调用，不自动增加 |
| get_session_stats | 未调用，不自动增加 |
| export_html | 未调用，不自动增加 |
| switch_session | 未调用，不自动增加 |
| fork | 未调用，不自动增加 |
| clone | 未调用，不自动增加 |
| get_fork_messages | 未调用，不自动增加 |
| get_entries | 未调用，不自动增加 |
| get_tree | 未调用，不自动增加 |
| get_last_assistant_text | 未调用，不自动增加 |
| set_session_name | 未调用，不自动增加 |
| get_commands | 未调用，不自动增加 |

## 官方事件全集

agent_start, agent_end, agent_settled, turn_start, turn_end, message_start, message_update, message_end, start, text_start, text_delta, text_end, thinking_start, thinking_delta, thinking_end, toolcall_start, toolcall_delta, toolcall_end, done, error, tool_execution_start, tool_execution_update, tool_execution_end, queue_update, entry_appended, session_info_changed, thinking_level_changed, response
