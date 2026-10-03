# Com! M3–M7 与 B0–B6 交付报告

2026-10-03；旧 Kotlin/Compose 会话工作台，包名 work.eddie.sessions。当前版本1.8.1 / versionCode19。代码、生产部署和手机覆盖安装均已完成；具体未验证项与只提案项分别列在下面。没有 push、tag 或 GitHub release。

## 1. B0 研究交付

[COM_B0_REUSE_ASSESSMENT.md](COM_B0_REUSE_ASSESSMENT.md) 给出各仓库快照、源码定位、许可与存在／部分存在结论、Com 映射及决策回答。[COM_THIRD_PARTY_PROCESS.md](COM_THIRD_PARTY_PROCESS.md) 记录处理方式。只在临时目录浅克隆，未安装依赖、运行第三方项目或将真实令牌传给研究代码；实现由本项目自行编写，仓库未纳入上游源码，无新增第三方版权代码登记条目。

## 2. 已实现及验证

| 阶段 | 改动 | 核验 |
|---|---|---|
| M3 | 读时派生chat/job，工作人工聊天不进台账/Judge；四类筛选统一；unknown需要核实，停止不冒充完成 | 后端源/连续性回归，JVM状态规则，真实Compose截图、取消与完成同属已结束且状态区分 |
| M4 | 主Pi同轮路由；补充依真实input映射；未投递撤销并另开，已送达/unknown只另开；持久new_item防止误归补充 | 五输入状态、幂等、约束撤销、完整原正文/来源、新事项意图；模拟器三输入状态；真实Pi隔离路由 |
| M5 | 人话步骤按真实完成call_id计数，未结束不计完成；文件路径只复制，HTTP链接可打开/复制/分享；失败如实显示 | 三个JVM及三个UI产物/步骤用例，截图检查 |
| M6 | capability_search只读投影；提供者、说明、验证状态/时间缺失返回null | registry/当前配置/loaded失效/只读查询相关回归 |
| M7 | 文档、版本、构建、同签名覆盖安装 | 1.8.0完成后继续交付1.8.1；见下方最终证据 |
| B1 | 官方RPC命令/事件对照；handled响应不再等待不存在的settled，不虚构run.completed | 失败先行fixture触发TimeoutError；修复后相关37项通过，最终全回归保持通过 |
| B2 | 一次性SDK心跳、独立路由UUID、受限单决定、预算/静默/暂停/并发/去重；默认影子；两次成功后才允许手动受限 | 两轮真实模型nothing，无错误，摘要1155/1356bytes；task/proposal始终17/3；暂停立即跳过；受限仍OFF |
| B3 | 对话/今天真实提醒卡，确认/+10分钟/+1小时/取消；请求持久幂等与回读；既有网关/扩展共同CAS锁，避免整文件覆盖 | 原remind工具创建2099年临时记录，四动作本地/公网回读一致，重复安全，旧快照409；全部验收提醒清理；真正断连错误显示并禁用按钮 |

最后一次 Mac mini 后端全回归 **403 passed**；Android JVM **67 tests**；完整模拟器 UI **71 tests**，额外当前宽屏9项、大字体1项通过。Gradle testDebugUnitTest / assembleDebug / assembleDebugAndroidTest / assembleBenchmark 均通过。既有连续性、送达、RPC诊断、Judge、语音、账本、权限测试保持通过。

真实 Pi 路由使用临时 Com 会话库/任务库、原生Pi及本项目Com扩展：你好0任务，快速查询0任务，长事项1任务，两件独立事项2任务；标题≤12字符，task来源均与临时真实用户消息一致。查询使用隔离空数据集，不是实际财务金额校验；没有启动这些验收任务的执行器或改变生产会话/台账。因此这里证明真实模型路由、受理及来源关联，文件执行/完整长任务终态沿已有回归验证，不将路由测试说成真实工程任务交付。

## 3. 已部署与安装

Mac mini Syncthing同步源的7个生产文件哈希逐一一致；重启前核对主会话及任务均无运行/排队/发送；SQLite在线备份在 ~/.session-workbench/backups/com-b-1.8.1-20261003-213321。循环启动后本地与公网 /sessions/health 确认1.8.1、main/worker full-access、goals_scheduler=false。心跳暂停恢复默认false、影子true，未手动受限启用。

既有提醒网关真源 ~/pi-hermes，提交76c7652；生产仅部署reminders.py/remind.ts/共享helper，settings、认证、其他用户改动不覆盖；重启前微信lane busy=false。未改MBP只读镜像。已有SQLite增加可空new_item元数据列，不迁移或重写历史，提醒仍用原JSON。

Xiaomi2608BPX34C无线ADB同证书install -r成功，21:45:14核对version19/1.8.1并启动MainActivity；保留数据与配对。签名SHA256 d01d14be850e7386ca77b2bbb1d5b9d36282b84f12cc70d6bde8e5ec8780434a。
APK：[Com-1.8.1.apk](../verification/com-1.8.1/Com-1.8.1.apk)，SHA256 **8bef5b36068c9dd4290ae3ef1f2bd2605afb3f3aed7a59ec2690b94e2a436d8e**。

## 4. 只提案，未启用

- [COM_MEMORY_LAYERING_PROPOSAL.md](COM_MEMORY_LAYERING_PROPOSAL.md)：四层记忆、来源/时间/明确或推断/撤销、迁移及回滚；现有MAIN_PROMPT2909字符/7023bytes；不改注入或共享记忆。待决定元数据落点、检索范围和预算。
- [COM_SKILL_PROMOTION_PROPOSAL.md](COM_SKILL_PROMOTION_PROPOSAL.md)：暂存、结构/15KB/补丁护栏、真实低风险样例、用户点击确认、Git提交/回滚；不是完整权限下的访问控制。自动晋升未启用。
- [COM_SECRETS_PROPOSAL.md](COM_SECRETS_PROPOSAL.md)：现场认证路径/0600及上下文/日志风险、独立保管/占位符/请求边界注入；未搬凭据或变更认证，未声称历史没有泄漏。
- [COM_REMINDER_CARDS_REPORT.md](COM_REMINDER_CARDS_REPORT.md)：承诺追踪复用goals或独立轻实体二选一，均未实现；不得把提醒触发当履约或task验收。

## 5. 可查看证据及剩余实体确认

[verification/com-1.8.1/](../verification/com-1.8.1/) 保存最终构建、403项后端、71项UI、真实心跳/提醒日志、真实原生路由JSON和APK。截图均为模拟器的明确本地数据，不冒充生产手机界面：

| 场景 | 截图 |
|---|---|
| 窄屏411dp | [narrow.png](../verification/com-1.8.1/screenshots/narrow.png) |
| 宽屏686dp | [wide.png](../verification/com-1.8.1/screenshots/wide.png) |
| 字体1.3 | [large-font.png](../verification/com-1.8.1/screenshots/large-font.png) |
| 原生键盘 | [keyboard.png](../verification/com-1.8.1/screenshots/keyboard.png) |
| 长标题、unknown | [long-title-unknown.png](../verification/com-1.8.1/screenshots/long-title-unknown.png) |
| 空数据 | [empty.png](../verification/com-1.8.1/screenshots/empty.png) |
| 缓存禁操作 | [cache.png](../verification/com-1.8.1/screenshots/cache.png) |
| 真实网络失败 | [actual-error.png](../verification/com-1.8.1/screenshots/actual-error.png) |

实体手机当时两个显示屏截图均黑屏，只证明屏幕当时不可见，未绕过锁屏。需你确认真实语音输入、折叠屏切换、后台限制与系统通知、日常主聊天连续操作；不把APK安装与模拟器证明当成这些实体体验已验收。自动心跳受限开关与B4–B6方案仍由你决定是否采用。
