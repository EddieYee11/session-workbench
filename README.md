# Com!

Com! 是 Android 应用（`work.eddie.sessions`）与 Mac mini 会话服务，保留原包名、配对和历史。当前版本 **1.6.1**：主页由 Pi 持续负责，使用现有 Flash；工作页提供 Claude / Codex，旧 Pi 从工作历史只读访问。

主 Pi 可直接使用 Shell、读写文件和业务工具，自主决定直接执行或委派独立 Pi / Claude / Codex，不强制派活。“A + 地址”等选项续答沿真实上文继续。主页支持 Markdown，工作页简称 Claude，统一字体与布局；减少重复历史注入、JSON 复制和流式轮询开销。共同能力目录区分发现、加载与真实验证；任务显示真实工具步骤、送达状态、结果和验收。主聊天与快捷语音使用同一请求登记。明确授权范围内执行，严重不可逆动作显示具体审批卡。

后台项目写任务在 mini 的同步目录外副本执行，包含当前未提交修改；验收后检查基线与 Syncthing，串行合入。主线普通文件编辑保留恢复副本，高风险删除/覆盖需要具体审批。目标与事件已落入 SQLite，09:30 目标调度在真机验收前保持关闭。仅 Com 的 Claude worker 使用 Flash，继承原第三方 endpoint/凭据，未改全局配置。

实现与真实验证见 [Pi 主线实施记录](docs/COM_PI_MAIN_IMPLEMENTATION.md)，当前决策见 [路线图](docs/COM_MUSE_ROADMAP.md) 与 [任务层契约](docs/TASK_LAYER_CONTRACT.md)。以前的版本说明和 Hermes 规划保留为历史资料。安装包见 [Com! 1.6.1 Release](https://github.com/EddieYee11/session-workbench/releases/tag/v1.6.1)。

- `backend/`：历史索引、持续主线、共同工具、能力目录、RPC/SDK 执行器、任务/目标/事件服务。
- `android/`：Kotlin / Compose 原生应用、底部导航、语音、通知、离线缓存与历史。
- `backend/probes/`：隔离真实运行时验收与显式切换/回滚脚本；不接生产账本。
- `backend/tests/`、`android/app/src/{test,androidTest}/`：协议、授权、恢复和界面检查。

本机虚拟环境、Android 构建产物、连接令牌和 `verification/` 中的设备截图不会提交到仓库。

Android 工程位于 `android/`，可用 Android Studio 打开，或在配置好 JDK 17+ 与 Android SDK 后运行 `./gradlew assembleDebug`。Mac mini 端需要 Python 3.12+、Pi、Claude Code、Codex、tmux 和 Caddy；`backend/install-mini.py` 是针对当前 Mac mini 的部署脚本，运行前应先核对其中的 Caddy 路径和路由。服务状态与会话数据保存在 Mac mini 的 `~/.session-workbench/`，不属于此仓库。

Mac mini 使用 `~/.session-workbench/agent-config.json` 选择主线、Com Claude 模型及执行主机。实际生产已设置 Pi；没有此文件的新环境仍保留 Hermes 兼容入口，不能据此宣称已切换。Pi RPC 是新增适配器，不复用旧 tmux 输入与微信会话。Claude 使用本地 Agent SDK，Codex 沿用 app-server。来源、具体动作、文件隔离与预算在执行处校验。切换前后不重放已投递或 uncertain 操作，回滚方法见实施记录。

Android 1.1.0 使用已选定的「灵动伙伴」界面：暖白底色、圆角会话卡片和本地流体圆脸 Bot。首页卡片读取真实会话，点开历史仍是只读；对话、终端、搜索和新建入口保持原有结构。网页 `docs/ai-style-directions.html` 仍是使用模拟数据的风格对照页。

Android 1.2.0 起系统显示名为 Com!。早期产品方向保存在 `docs/COM_PRODUCT_DIRECTION.md`；当前实现与设备验收情况以最新版本说明为准。

Bot 直接复用用户指定的「Grok 灵动助手 v2」矢量动画与控制器，通过隔离的本地 WebView 播放，不加载远程资源。执行中显示思考，等待回应显示好奇，失败显示错误；只有本次观察到执行/等待转为完成才庆祝一次。初次读取已完成会话、离线缓存及只读历史不触发庆祝。首页支持点按互动，标题栏头像只展示状态；退到后台暂停播放，并遵循系统关闭动画的设置。来源与许可证见 `android/app/src/main/assets/grok-bot/NOTICE.md`。

## Com! 1.3.1

双伙伴（Pi 流体圆脸 / Codex 蓝色毛绒）、角色居中布局、连续场景过渡与背靠背旋转。系统快捷语音默认 Pi，检测到说话后静音约 0.5 秒发送，小窗内等待并显示回复，可继续录音或上滑展开同一会话。详见 [实现与验证](docs/com-1.3.1.md)。

## Com! 1.3.2

每次新呼出 Pi 快捷小窗都会直接开启录音，包括留有旧草稿或上一条仍在后台发送时；旧草稿保留到新录音成功为止。已提交的发送继续由 WorkManager 处理。首次使用需允许麦克风权限。

## Com! 1.3.3–1.3.4

1.3.3 调整原生输入、快捷小窗手势和关键操作触感；1.3.4 加入从 Mac mini 实时读取的 Pi / Codex 模型目录，以及输入框旁「＋」中的模型与推理水平选择。1.3.4 已覆盖安装在小米折叠屏；所选模型的真实消息回合尚待实机验收。详见 [1.3.3](docs/com-1.3.3.md) 和 [1.3.4](docs/com-1.3.4.md)。

## Com! 1.4.0 · Personal Agent 开发中

默认入口改为独立 Hermes 的一条持久主对话，回复通过 SSE 逐段显示服务端实际阶段；「今天」直接展示 Google「Pi」日历未来 14 天和 NAS ezBookkeeping 的只读概览，以及待我处理和在途工作。Mac mini 的 Google OAuth 已恢复，概览在本机与公网均可读取；Hermes 两轮连续对话、重启后历史读取和本机／公网真实流式增量已验证。Pi/Codex 仍在「工作」中，Hermes 提出的工作建议须经 Com! 审批，实际派发闭环尚未验收。

通知采集需要用户在 Android 系统中手动开启特殊访问；选定来源的新通知才会入队，由隔离的 Hermes 分析成摘要、建议记录和回复草稿。**不会自动发送消息**。目前只通过合成通知验证了服务端分析；真实微信／短信通知、后台可靠性和新版 Android 整机交互仍待手机验收。新主导航四枚图标和 Hermes 形象采用同系 GPT 生成 PNG；旧工作区的部分控件仍使用原有 Material Icons。详情及当前边界见 [实施记录](docs/COM_PERSONAL_AGENT_PLAN.md#7-2026-10-01-实施记录)。

## Com! 1.4.1 · 白灰聊天界面

按 Muse 参考图统一为纯白背景、浅灰大圆角气泡和胶囊输入框，功能图标改为同一套黑灰矢量符号；保留 Hermes / Pi / Codex 的角色形象。对话页的数据卡片集中到「今天」，空会话使用轻量欢迎文字。

手机与折叠屏展开都使用底部「对话、今天、活动、工作、更多」，不再切换到侧边功能栏。日历、账本、设置从「更多」底部弹层进入；工作历史也从底部展开。键盘打开时底部导航收起，为输入保留空间。既有对话、配对、审批与快捷语音逻辑沿用。

本轮已通过 Android 编译和现有 24 项单元测试，优化安装包版本为 1.4.1（versionCode 10）。展开屏实机检查已完成；411dp 窄屏与 608dp 宽屏模拟器的导航、账本、工作历史和键盘检查均通过，新增设备检查见 `ComNavigationTest`。物理折叠/展开切换仍需用户手持体验。截图保存在本机 `verification/com-1.4.1/`，测试中的示例对话仅用于模拟器。
