# Pi 主线实施记录 · Com! 1.6.0 / 1.6.1

2026-10-03。用户取消 Flash 路由对照实验，直接使用现有模型；随后批准仅 Com 的 Claude 执行器使用 `deepseek-v4.1-flash`，保持全局 Claude 配置。

## 已交付与生产状态

mini 的 `work.eddie.sessions` 已加载 Pi 主线，内网与公网 `/sessions/health` 均确认 `pi_main=true`、`task_timeline_v1=true`、`goals_scheduler=false`。原 `personal-main`、消息 ID、request_id 与父子关联保留；切换前 63 条用户消息、73 条助理消息的身份元组逐项一致，未发生产探针消息。

- 主 Pi 使用自有 RPC 会话与自定义主线提示；模糊指代先回查原任务、对话和既有项目/技能资料。1.6.1 起主 Pi 可直接使用原生工具工作，由 Pi 按实际效率决定是否委派独立 Pi、Claude 或 Codex。不会自动改回 Claude 主线。
- 共同工具为 capability_search/task_submit/task_status/task_send/task_cancel，Hermes MCP 旧名称映射同一服务。任务候选由真实来源与动作判断兜底，愿望、情绪、引用不能授权。
- 能力按主机、运行时、项目、配置版本登记；验证有效期 24 小时，配置、适配器、依赖或运行时变化失效。失败立即 unavailable，派发重新探测。安全生产探针只验证运行时协议/模型可发现；领域能力不使用 fixture 冒充 verified。
- 任务持久绑定 personal-main，显示真实工具事件、输入进入上下文、执行结束与验收。structured_result 包含执行/验收状态、摘要、产物、证据与 uncertain，自由文本完成不能验收通过。
- 工作页手动创建也登记真实来源和负责人，经同一任务服务、副本与验收运行；每次续接保留原执行器会话，每轮单独记录结果、回执、补丁、验收和合入。未纳管的旧执行器历史保持只读，可引用记录创建新任务，避免绕过受管写入边界。
- Pi 等 agent_settled；Claude 原生 UserPromptSubmit 确认输入送达。Claude 的补充在当前轮结束后沿同一原生会话与原任务额度执行。ACK、队列、实际送达分开；失去送达证据不重发。
- 原生事件投影维持 snapshot/update SSE；文字与快捷语音同一请求号只登记一次，/asr 继续只转写，旧语音回执可读。通知检查改为独立、无工具 Pi，会输出摘要/草稿，不获得执行授权。
- 写任务仅在已绑定 mini 上运行，Pi/Claude/Codex 项目写入采用同步目录外副本，保留未提交修改。Pi 与验收脚本有 macOS 文件写隔离，Claude 用原生 sandbox，Codex 副本使用 workspace-write。合入串行检查基线及 Syncthing，冲突保留补丁；被移除的原文件保留于 pre-merge。
- 可恢复归档保存来源、原/新路径和恢复入口，原位置冲突不覆盖；永久删除/未归类破坏命令按真实动作与参数审批，批准不扩展到其他对象。
- 后台最多两个、Claude 一个；Claude 自动每天三个任务、同任务最多十二轮，续接共享额度。可核验 Token 默认停止阈值 200000；Token 统计可用，真实金额未知。阈值约束后续调用，不能宣称精确金额硬上限。
- SQLite goals/event queue 与单一主线消费者已接入，用户消息优先，后台事件绑定原授权。调度器只登记到期与 09:30 Asia/Shanghai 事件，没有事件不启动主模型。真机验收前定时调度关闭。
- 目标已有未结束、uncertain、待验收或待合入任务时不能重复派发；通过验收并合入后可进入下一步。完成目标的旧唤醒事件静默结束，不启动模型。

生产配置仅在 mini `~/.session-workbench/agent-config.json`：main_agent=pi、claude_model=deepseek-v4.1-flash、execution_host=EddiedeMac-mini.local。Pi 模型登录复用既有本机 Pi 配置，Com 会话和状态独立；不读取微信 lane、账号和会话。

## 验证依据

Flash 路由命中率、误派率与 A/B 基线未测试，这是用户明确取消的阶段零。以下是协议、行为与恢复验证，不宣称模糊意图识别准确率。

| 检查 | 结果 | 证据 |
|---|---|---|
| 后端协议/授权/恢复检查 | 172 passed；零失败 | backend/tests，mini Python 3.12 venv |
| Android 单元与构建 | 44 passed；debug/test/benchmark 构建成功 | app/build/test-results/testDebugUnitTest |
| 窄 411dp / 宽 610dp 模拟器 | 相关 9 项界面检查各通过一次；主页、底部导航、工作历史、缓存控制与键盘 | HermesExperienceTest、ComNavigationTest、TaskLedgerLinkTest |
| Pi 主线 native Flash RPC | 同场景两次：文字/语音去重、结果、SSE、重启身份保留 | `verification/com-pi-main/pi-native.json`（本地） |
| Claude SDK native Flash | 读取、原会话恢复、排队输入进入原生上下文、副本写入、实际中断；每项两次 | `verification/com-pi-main/claude-native-1.json`（本地）、`verification/com-pi-main/claude-native-2.json`（本地） |
| 完整执行链路 | 来源校验→幂等派发→真实工具步骤→副本写入→待验收→文件检查→串行合入，两次；退出清理通过 | `verification/com-pi-main/chain-native.json`（本地） |
| 工作页手动创建与续接 | 来源/负责人→副本写入→验收合入→同会话续接→第二轮验收合入→原生用户回执，两次 | `verification/com-pi-main/manual-native.json`（本地） |
| 文件写隔离 | 原生 Pi 在 sandbox 中可启动 RPC；越界写被系统拒绝 | native get_state、安全测试 |
| 通知只读检查 | 独立 Pi 无工具，JSON 摘要两次通过 | `verification/com-pi-main/triage-native.json`（本地） |
| 生产只读探测 | Pi get_state、第三方 Flash 模型列表/Claude CLI、Codex 原生模型列表成功，零模型 turn；历史身份和 Claude 全局配置一致 | `verification/com-pi-main/production.json`（本地） |

确定化故障覆盖：进程终止、断线、压缩/排队、中断、重复请求/事件、写入后 ACK 丢失、恢复时不重放；新增 SDK 单次关闭检查修复消费结果与关服务同时 disconnect 的竞态。样例均在临时 HOME/STATE/项目内，账本、提醒、收藏和生产任务库未用于探针。合入端到端使用 fixture Syncthing 服务；生产真实 Syncthing 另行只读检查为稳定，没有借探针改同步项目。

Claude Code 2.1.233 / Agent SDK 0.2.163 的实际 Flash 调用通过；CLI 会输出 unrecognized_model。官方文档允许[第三方网关](https://code.claude.com/docs/en/llm-gateway)，同时不承诺非 Claude 模型兼容；此组合以本次真实运行证据为准，升级需复验。本轮只查 Codex RPC/模型列表，没有额外调用 Codex 模型。

## 成品与剩余验收

`verification/com-pi-main/Com-1.6.0.apk`（本地），versionCode 14，原包名与签名方式，3,907,391 字节。SHA256：eb12a2d26a8d6364ab1b4dd23a0d3d8b9334f3e865026a45f0728c16d173ce27。

已亲自查看模拟器 `verification/com-pi-main/home-narrow.png`（本地） 与 `verification/com-pi-main/work-wide.png`（本地）。底部导航与既有视觉语言保留。

1.6.0 初次接入阶段没有连接实体手机，APK 当时未装到真实手机；1.6.1 安装与查看结果见下文。真实语音、折叠内外屏切换、实体设备后台恢复仍待用户设备验收；不能用构建或模拟器代替。目标定时调度保持关闭，不将未验收阶段标完成。

## 回滚与恢复

mini 持久备份：`~/.session-workbench/backups/com-pi-20261003-021923/`，通过 SQLite backup API 保存切换前数据库、原配置与身份边界。CLAUDE 全局配置未写入；Hermes 配置未删除。最初已有代码/资源改动保留，本机修改前 diff 位于 `/tmp/com-pi-cutover-20261003/`。

在 mini 执行 `~/.session-workbench/venv/bin/python backend/probes/deploy_pi.py --rollback ~/.session-workbench/backups/com-pi-20261003-021923`，再重启 `work.eddie.sessions` LaunchAgent。回滚只改变主线选择和身份映射，不用旧 SQLite 覆盖新消息，不重发已投递或 uncertain 的操作；有活动主线输入或工作任务时切换脚本拒绝执行。目标调度保持关闭。

隔离验收可复现：mini venv 执行 backend/probes/run_acceptance.py、claude_acceptance.py、task_chain.py、manual_chain.py；脚本创建私有临时状态。部署脚本无参数只读检查，--apply 才保存备份与切换，不能当作测试 fixture 运行。


## 1.6.1 主线工作权限与界面修订（2026-10-03）

用户明确取消“主线只能短操作、项目必须交 Claude/Codex”：Pi 主线现在是主要执行者，可以直接使用 bash/read/write/edit 与业务工具，按需要自主委派独立 Pi / Claude / Codex。task_submit 描述、主提示词、能力注入与默认执行器同步修订。历史对话中的“本会话无 Shell 权限”不再适用。后台任务仍沿既有副本、验收和串行合入流程；主线普通文件编辑保存私有恢复副本，高风险删除/覆盖仍审批，不宣称原生 Shell 具有后台任务的文件写隔离。

修复交办判断漏掉连接、启动、无线调试、跑起来；“a + 地址”通过紧邻助手选项和原明确用户交办解析，原消息/request_id 保留，关联来源记录在任务授权中。情绪、愿望、引用与破坏性选项仍不能这样授权。用户采纳助手示例、末尾残留代码标记不再因句式缺词被拒绝。

mini 新增 Google 官方 Android Platform-Tools 37.0.1，位于 ~/.local/share/com-tools/platform-tools，~/bin/adb 是本机入口；Com Pi PATH 包含 ~/bin。未复制 MBP 的 adb 配对密钥。隔离原生 Pi RPC 已直接用 bash 回读 adb 路径和版本，没有创建任务。案例中“libshizuku.so 不能执行”的断言也已纠正：[官方构建文件](https://github.com/RikkaApps/Shizuku/blob/master/manager/src/main/jni/CMakeLists.txt)将它定义为 add_executable。未据引用案例重新启动真实手机 Shizuku。

主页和工作会话共享既有 Markwon 渲染器，支持标题、粗体、列表、代码、链接、表格及流式追加；保留链接短点、长按选择。界面所有用户可见 Claude Code 缩为 Claude，正文 16sp、辅助文字 12–14sp，标题与标签的字重和行高统一，1.3 倍系统字体下底部导航等高对齐。

提速减少持续 Pi 会话历史重复注入、旧 Hermes 提示词生成、Android 历史 JSON 反复复制和流式消息后的额外轮询。能力查询复用单次清单和运行时版本：mini 本地准备耗时从约 15ms 降为约 1.6ms；这不是模型生成耗时或端到端速度指标。

本轮后端 181 项通过，Android 44 项单元检查通过。411dp 窄屏与 610dp 展开屏/1.3 倍字体的 Markdown、链接、导航、工作历史、键盘等各 10 项检查通过。APK 1.6.1 / versionCode 15 以同签名覆盖安装到真实 Xiaomi 2608BPX34C，保留原数据与配对；安装前后检查版本，实际主页 Markdown 已查看。真机语音、完整折叠切换和后台恢复仍未完成，目标定时调度保持关闭。

成品及本轮证据见 `verification/com-1.6.1/`（本地）。


### 旧拒收回执恢复

用户回报旧工作创建请求的“尚未确认”。查证为手动创建工作时旧交办规则拒绝，尚未创建任务/工作器，却被 once 误记 unknown。确定的交办拒绝和启动前环境检查失败现返回 rejected/not_submitted；真正启动/送达后的异常仍 unknown、不重放。旧记录只有特定授权拒绝、原工作消息已失败且没有关联任务时才恢复为 not_submitted。App 刷新会解除这类旧 pending 标记并保留草稿，不自动发送。此恢复不将引用案例变成设备执行请求。

公开安装包：[Com! 1.6.1](https://github.com/EddieYee11/session-workbench/releases/tag/v1.6.1)。设备截图与原生事件报告保存在本地验证目录，不上传公开仓库；协议与隔离探针源代码随仓库提供。
