# Com iOS · 主动 Agent、记账与项目看板

2026-10-07。实现与验收报告。iOS 1.0.0（2026100701）。这是本次交付范围；更早的完整升级方案还包含未实施的后续设想。

## 最终信息架构

- **今天**：紧凑日期与状态 → 记账大卡（环形图、今日花销、本月花销）→ 来自工作看板的行动建议 → 近期目标 → 最近简报。原日历、健康与连接详情保留在展开区。
- **记账详情**：月份与今天／本月切换 → 分类环形图 → 横向排行 → 某分类按日期排列的金额、事项和账户。多币种分开展示；整数分值汇总，不把转账当消费。图表与明细使用同一份 ezBookkeeping 记录。
- **工作**：默认项目看板，保留会话入口和新建工作。看板有进行中、待推进、已完成、待核对；点项目看具体事项，再点事项看进展依据和原会话摘录。底部入口统一叫“工作”。
- **任务／目标**：目标可建档、暂停、恢复、确认完成；晨晚报和周复盘使用真实目标。原执行任务与定时工作仍保留。

## Mac mini 常驻工作

1. MacBook 的 `work.eddie.com.project-collector` 每 10 分钟采集一次本机近期会话，经既有 `ssh mini` 通道发送派生快照。MacBook 休眠或离线时不会伪造实时进展。
2. mini 后端每轮整理后等待 15 分钟再继续：采集 mini 的原生会话，按最近变更逐批分析（每批最多 12 个）。首次积压会逐步补齐，不代表全部历史已分析。
3. 索引范围为最近 30 天、每机最多 200 个最近会话、每会话最后 8 条用户／助手消息，正文有长度限制；不复制原生登录态，不续接原会话，不读推理内容或全量工具日志。MBP 原生索引当前保留最近 160 个候选。
4. 覆盖 Pi、Codex、Claude Code 的原生会话及 Hermes SQLite 会话。现场 MBP 的 Hermes 源不存在，mini 有 Hermes 记录；UI 不把缺失来源当已接通。
5. 进展提取要求有效消息 ID 和能在原文逐字匹配的证据。会话停止不等于完成；“已完成”表示具体事项有完成报告，不代表整个项目已验收。来源版本变化时旧提取降为待核对。
6. 项目建议进入今天页、固定简报和主聊天。延期 3 小时、已处理、事项版本去重；过期主机快照不产生新建议。项目归类为模型推断，保留原设备、Agent、会话身份与证据，原始会话不改写。
7. 当前强度为“积极”：固定简报之外每天最多 4 条主动消息，23:00–08:00 安静。09:00 晨报、21:00 晚报；周日 20:30 周复盘替代晚报。支持 App 内调整／暂停。只改变信息整理和提醒，不凭历史资料扩张业务执行授权。

## 对话、准备与动效

- 固定简报使用独立事件消费者与 Hermes 会话，不再占用主聊天的模型回合。
- Agent 统一使用简短中文回复规则：结果优先、默认 1–3 句、约 100 字；复杂方案按需展开。
- 行动详情可整理已有事实、下一步、待确认问题和来源版本。先生成真实资料包，再显示“资料已整理”。资料变化后不沿用旧包。
- 卡片显隐／状态变化使用约 0.28 秒的短弹簧；图表出现使用小幅缩放与淡入，金额使用数字过渡；保留原光效录音和转写动效。减少动态效果时改为短淡入。
- `ComControls` 提供系统“常用控制”里的“Com 语音小窗”。按用户最后确认保留自定义光效，入口会打开 Com；未实现跨 App 覆盖的自定义录音悬浮窗。

## 现场已验证

- 后端全量 502 passed、3 skipped（本地可选依赖），后续修正另跑受影响检查。
- iPhone 17 Pro 模拟器交互：记账分类排行、分类明细、工作看板、原会话依据、资料准备、延期、创建目标、暂停主动消息，2 个综合 UI 场景通过；此前导航与详情 2 项通过；最终复验记账／看板综合场景及 3 项 ComCore 检查通过。
- mini 的真实账本接口返回本月 40 笔支出、7 个分类；未向文档复制消费明细。
- 两机采集成功；首轮 mini 接入四类 Agent，MBP 接入三类（无本地 Hermes 源）。真实 Hermes 首轮提取 16 个会话未出现无效证据错误，剩余积压继续分批整理。
- 新简报链路在隔离状态目录使用真实 Hermes 完成，约 6.2 秒，写入真实独立对话回执；不污染生产聊天。
- 生产主聊天已经写入首条项目看板主动建议。
- Xcode 登录后的 GUI 自动签名成功，命令行随后也构建通过，主 App、分享扩展和 Controls 扩展均有签名。
- 预览截图为明确标识的 UI 验收样例；线上账本、会话数及模型验证来自真实 mini，不能互相替代。

## 尚需真实设备条件

- 用户出门后 iPhone 在 devicectl 中显示 unavailable；安装命令返回设备不可定位（CoreDeviceError 1011）。新版本已准备签名构建，不能把构建通过说成完成本次装机。设备再次连接后安装，再做控制入口、录音、通知权限与实际光效的手动验收。
- APNs 持久队列、设备登记、HTTP/2 / ES256、退避重试、失效 token 停用已实现；生产未配置 APNs provider key，当前签名不含 `aps-environment`，所以系统推送尚未接通。后台刷新可尝试读取真实消息，但 iOS 不保证准点唤醒。不能承诺锁屏09:00必达。
- 邮箱、Garmin 及手机健康／手机日历未全部连接；建议只使用已经同步的资料。健康数据缺失不会被推断为正常或异常。
- 长期目标当前生产库无用户建档记录；本次没有编造个人目标，也没有打开通用目标自动执行开关。

## 主要实现入口

| 路径 | 职责 |
|---|---|
| `backend/agency.py` | 今天行动、资料包、目标反馈、独立简报与每日预算 |
| `backend/project_board.py` | 双机派生快照、进展提取、引用校验、看板和行动建议 |
| `backend/probes/export_project_board.py` | 只读采集与 SSH 导入 |
| `backend/probes/install_project_collector.py` | MBP launchd 定时导出 |
| `backend/finance_dashboard.py` | 真实账本按月、币种、分类投影 |
| `backend/proactive.py` | 持久排期及周报替代逻辑 |
| `backend/push_notifications.py` | APNs outbox；受理不等于到达 |
| `ios/Com/Views/AgencyViews.swift` | 行动首页、目标、主动性设置与状态动效 |
| `ios/Com/Views/FinanceViews.swift` | 环形图、排行和逐笔下钻 |
| `ios/Com/Views/ProjectBoardViews.swift` | 工作看板、项目详情和证据 |
| `ios/ComControls/ComVoiceControl.swift` | 系统控制入口 |

## 部署与回滚

mini 服务仍是 `work.eddie.sessions`，独立新数据库在 `~/.session-workbench/`。每次重载先确认主聊天和任务空闲，再用 SQLite backup 保存；本次备份目录前缀 `com-proactive-20261007-*`。源码通过 Syncthing 同步后核对，再在 mini 重载，不用 scp 覆盖共享目录。

停止 MBP 采集：`launchctl bootout gui/$(id -u)/work.eddie.com.project-collector`；原生 Agent 会话不会被修改。暂停主动消息可用 App 内“主动性”设置。

APNs 后续配置保存在 mini 私有状态目录的 `apns-config.json`，仅含 team_id、key_id、key_path 和固定 topic `work.eddie.com`；密钥留在受保护文件，禁止提交。具备推送能力的描述文件就绪后，构建参数使用 `COM_ENTITLEMENTS_FILE=Com/ComPush.entitlements COM_APNS_ENVIRONMENT=development`，发布签名则使用对应 production 环境。[Apple 推送文档](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)。

## 本机交付文件

- 签名包：`~/Downloads/Com-Personal-Agent-2026100701.ipa`（约 12.8 MB）。用于已注册设备开发安装，不是 App Store 发布包。
- 可直接安装的 App：`ios/DerivedDataControls/Build/Products/Debug-iphoneos/Com.app`。
- UI 验收截图：`ios/verification/Com-2026100701/`；样例数据有标注。
- 当前主 App 开发描述文件到期：2026-10-13 13:11:23 UTC；之后需重新签名。
