# Com! 2.0.0 · Hermes 升级与界面验收

更新：2026-10-05，Asia/Shanghai。源码包含本任务之前的未提交改动，尤其 Hindsight 接入；未重置、清理或整体覆盖这些改动。

## 已交付的界面

- 底部为聊天、今天、任务、记忆、工作。白灰主体保留；参考 Today 截图的线条图标、圆形操作按钮、圆角卡片与选中胶囊，不采用蓝色渐变背景。
- 工作页沿用原来的会话布局、项目分组、历史与输入方式，保留 Pi／Claude／Codex 明确选择。没有重写 `ConversationScene.kt`。
- 主聊天、搜索引用、语音交办、角色无障碍描述和设置中的当前执行器名称为 Hermes；历史消息及工作执行器身份仍保留真实来源。
- 设置使用分组卡片、图标入口与圆形关闭按钮；连接器、手机节点、安排回执／撤销、执行权限、观察建议、语音与原有配置均可进入。Material 控件改为中性色，聊天头部采用渐变透明边界，减少文字与按钮重叠。
- 今天支持来源、纠错、关注、稍后、已处理、不再提醒及关联解除。继续处理只提交用户原话与事项 ID，服务端保存对应资料快照；外部邮件／日程内容不并入用户指令，重复提交不能更换关联事项。

实现入口：`android/app/src/main/java/work/eddie/sessions/{MainActivity,HermesChat,ComIcons,Theme,SettingsComponents,AgentPages,HeartbeatUI,ConversationOutbox,Store}.kt`。

## 当前部署

Mac mini 上 Com 服务为 2.0.0，Hermes 服务现场自报 0.21.5。主会话 `com-hermes-main`，专属 profile `~/.hermes/profiles/com-personal`，模型 `deepseek / deepseek-v4-flash`。

主对话和 Com 持久任务使用当前用户 Full Access，原生终端／文件／网络／浏览器／Skills／MCP 可用，MCP 信任 full、自动批准开启；未增加 root。独立 Com 任务并发上限二，Hermes 原生子代理继承父工具与 MCP，仍遵循上游委派层级规则。技能目录包含迁移的业务技能和既有分类技能；外部目录复用 `.pi-gateway/skills` 与工作区 `.agents/skills`。

主聊天、小窗语音、眼镜转入 Com、默认任务和个人观察均路由 Hermes。工作页选择的其他执行器保留。普通业务工具直接访问原系统，避免经 Pi 模型中转。

主要实现：

| 能力 | 源码 |
|---|---|
| 原生会话、Runs、幂等提交、执行事件、steer 消费证明 | `backend/hermes_runtime.py`、`conversation.py`、`worker_runtime.py`、`tasks.py` |
| 专属配置、主提示词、Cron 安装 | `backend/deploy_hermes.py`、`hermes_prompt.py`、`install_hermes_cron.py` |
| 原 ezBookkeeping、提醒、收藏、苹果日历 worker | `backend/business_tools.py`、`calendar_bridge.py` |
| 个人安排授权、冲突与固定约束检查、回读、撤销 | `backend/autonomy.py` |
| 分类 Markdown 记忆、版本修正、Hindsight 来源校验 | `backend/memory_catalog.py`、`memory.py` |
| 来源同步、事项关联、持久反馈、版本化简报建议 | `backend/personal_hub.py`、`agent_tools.py`、`hermes_mcp.py` |
| 配对认证设备节点、调用账本、离线／权限状态 | `backend/device_nodes.py`、Android `PhoneNodeService.kt`、`PhoneNodeTools.kt` |

每日北京时间 09:00 晨报由 Hermes Cron 同步来源、读取事实与纠正、更新最多五张原卡片，生成相关理由和下一步。建议绑定来源版本，来源或纠正变化后失效。长期个人安排授权可用于有明确背景依据的个人提醒及可编辑日程，保留回执和撤销；共享参与者事件与对外发送遵循具体交办。兼容观察开关控制提醒／工作建议，不替代上述个人安排授权。

## 真实验收证据

这些检查分别证明对应使用路径，不把构建当作业务完成：

| 验收 | 结果／可复查入口 |
|---|---|
| 模型与原生工具 | Hermes 模型实际回复，终端返回 `COM_HERMES_TOOL_OK`；真实原账本只读查询完成。`backend/probes/hermes_native.py`、`com_hermes_roundtrip.py` |
| 两项并发及主聊天继续 | A、B 独立 Hermes 会话实际执行；主消息 `b95a7d46083e4473a41d375d4925c65d` 继续响应。`hermes_tasks_roundtrip.py` |
| 补充、服务重启、取消 | A `task_5ce4ae894f17fb3535acfe4b` context revision 2、输入 delivered、结果确认最新要求；B `task_bdb9ff356b0dad7c21095253` cancelled。重启后读取原运行，没有重新提交；原消息收到完成／取消回执 |
| 自动记忆、纠正、再召回 | `mem_bac338a13b075ca1c29b4eec` version 3 保存真实 Com 产品偏好和历史；下一次回复采用新版本。`hermes_memory_voice.py` |
| 语音接口及去重 | 识别文字进入小窗语音接口后由 Hermes 完成；重复 ID 返回同一消息。此项未测试实体麦克风 |
| Hindsight 不可用 | 隔离验收运行注入召回连接失败，真实 Hermes 仍回复 `COM_MEMORY_FALLBACK_OK`；未停用其他 Agent 的 Hindsight。`hermes_final_acceptance.py` |
| 日历／提醒及撤销 | 原苹果日历 worker 实际创建、回读、重复请求去重、调整、撤销调整、删除本次创建的验收事件；提醒实际创建、回读、去重、取消。`business_roundtrip.py`。仅清理本次验收对象 |
| 日历调整回读 | 调整操作 `3967b725263fb0442e7d22410961adb70d3dd2feee7622346767120bac0606e5` 已回读并撤销。修复移动开始时间晚于原结束时间时的 Calendar 写入顺序 |
| 收藏 | 原 Obsidian 收藏库实际保存 Hermes Runs API 参考，回读成功，同操作 ID 重复返回原文件；不是全文抓取验收。操作 `997663672b82082f96b1b722ecc05104626d9d27f8b805a83af9a9e866620a1d` |
| 手机正常与拒绝 | 小米节点实际返回设备状态、日历列表；重复调用去重；Health Connect 权限拒绝明确返回，未编造健康结果 |
| 手机离线 | 当前实体手机断开，公网设备调用返回 offline；不执行或重放。`hermes_final_acceptance.py` |
| 公网与关联按钮 | 公网 `/sessions/health` 和认证消息接口响应，Hermes 完成事项背景读取；重复消息 ID 返回同一对象，用户正文未混入来源事实。`hermes_final_acceptance.py` |
| 定时任务 | 邮件／项目、健康及个人观察均实际运行，12:30–12:31 回读 last_status=ok。09:00 首次运行安排 2026-10-06，尚未到时 |
| 简报建议工具 | 原生 Hermes 调用 `personal_briefing`／`briefing_annotate` 实际保存卡片建议，事实保持原样。`hermes_briefing_acceptance.py` |
| 自动化测试 | 后台 451 passed、3 skipped；Android 71 单元测试通过。日志 `verification/hermes-upgrade-20261005-102142/{backend-final,android-final}.log` |
| 界面查看 | 模拟器真实连接 mini 检查聊天、今天、任务、记忆、工作及设置；键盘、1.3 倍字体与 2400×1600 布局已检查。截图同目录；宽屏是模拟器布局验证 |

## 连接状态与尚未完成项

- 苹果日历、原账本、GitHub 已实际连接；复用独立 Google Calendar 授权后 API 查询成功，目前返回零事件。这不等于 Gmail 同时授权。
- Gmail 的原授权 invalid_grant，需要重新登录；搜狐工作邮箱缺 IMAP 账号／专用密码；Garmin 的旧会话不兼容新连接器，需要本人的登录／可能的验证码。应用已有具体连接说明或配置入口；Garmin MFA 完成流程仍需补齐。健康缺失不会生成睡眠／恢复结论。
- 实体小米先前已同签名覆盖到 2.0.0，保留配对与数据。但它随后断开无线调试，**本文最终新版 APK 尚未覆盖到实体手机**。最后的设置／页面变化已在模拟器验收，需手机重新在线后完成最终覆盖及实机复查。
- 实体麦克风的文本／小窗语音记账、日历、提醒和收藏完整操作链尚未验收；没有为验收伪造账目。真实账本写入与重复请求验收应使用用户实际发生的支出。
- Health Connect 授权、实体联系人／闹钟等设备动作、系统终止后的重新连接与补传还需实机验收。已注册 19 项手机工具；未把短信、通话记录列作可用。
- NAS、视频归档和文档技能复用已部署，但各实际业务场景未逐项验收。共享参与者事件的具体交办编辑流程、日历重复事件单次修改需要进一步完善。
- SSE 断开后的原运行状态和最终结果可恢复，已观测事件持久保存；断线区间的全部中间原生事件补齐尚未完整实现。未知副作用不会自动重放。
- 旧 Pi 任务存在业务结果未知记录，执行容量已与执行器是否活跃区分；保留审计和原身份，没有重新执行旧财务指令。

因此，全链路主执行器与本次界面升级已实现，并通过上述真实验证；原四阶段计划的所有账号、实体能力与异常场景验收还未全部完成。

## 安装与回滚

最终安装包：`verification/com-2.0.0/Com-2.0.0-hermes.apk`，包名 `work.eddie.sessions`、version 2.0.0／code 23。最终 APK SHA-256：`1df65f4e01fc29c3ea132b9087e8d934db6f09ede1cbbb25934d3b065a7c623e`。证书 SHA-256：`d01d14be850e7386ca77b2bbb1d5b9d36282b84f12cc70d6bde8e5ec8780434a`，与原安装包一致。覆盖安装，不卸载、不清数据。

本机切换前备份：`verification/hermes-upgrade-20261005-102142/{before.patch,source-before.tar.gz,com-1.9.1-before.apk}`。mini 数据库快照：`~/.session-workbench/backups/hermes-upgrade-20261005-102228/`；profile 修改分别保存在 `hermes-profile-*`，最近一次 `hermes-profile-20261005-124242`；Cron 更新保存在 `com-cron-*.json`，原日历 worker 配置另有备份。

回滚仅恢复 `agent-config.json` 主执行器、会话 origin 映射与 Com profile 的调度归属，并重启对应服务；先确认原运行已退出。不恢复整套旧数据库，不覆盖现有业务记录、记忆、操作回执或消息。旧主会话保留为只读来源，禁止重放旧指令。回滚前再对当前状态做备份，保留本次已经产生的业务记录。

## 产品依据

- [Today 拆解报告](/Users/eddiegao/AI_Work_System/work/工具与效率/应用拆解/Today/2026-10-05-1.19.0/拆解报告.md)
- [用户附件调研](/Users/eddiegao/.codex/attachments/48f3777f-c42c-4e22-8fd3-f56f6f3b2ff0/已粘贴的文本.txt)
- 当前会话确认的原生应用、底部五入口、工作布局保留、白灰配色及 Hermes 全链路选择。
