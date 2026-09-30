# Com!

Com! 是原「会话工作台」Android 应用（`work.eddie.sessions`）与 Mac mini 会话服务。保留原包名以便原位升级和保留本机配对、缓存。可从手机发起和继续 Pi / Codex 会话，查看实时过程和终端，并检索 Mac mini 上保存的历史会话。

- `backend/`：只读历史索引、Codex App Server 接口、Pi 实时扩展、tmux 终端桥。
- `android/`：Kotlin / Compose 原生会话、全文搜索、离线缓存与 xterm.js 终端。
- `backend/tests/`、`android/app/src/{test,androidTest}/`：项目检查代码。

本机虚拟环境、Android 构建产物、连接令牌和 `verification/` 中的设备截图不会提交到仓库。

Android 工程位于 `android/`，可用 Android Studio 打开，或在配置好 JDK 17+ 与 Android SDK 后运行 `./gradlew assembleDebug`。Mac mini 端需要 Python 3.12+、Pi、Codex、tmux 和 Caddy；`backend/install-mini.py` 是针对当前 Mac mini 的部署脚本，运行前应先核对其中的 Caddy 路径和路由。服务状态与会话数据保存在 Mac mini 的 `~/.session-workbench/`，不属于此仓库。

工作台新建和显式继续的会话默认使用最高权限。Codex 采用 `danger-full-access` 与无审批；Pi 使用 `--approve` 和工作台专属工具扩展。如果 Mac mini 全局加载了额外的 Pi 命令护栏，需要让该护栏仅在 `SESSION_WORKBENCH_YOLO=1` 的工作台进程中跳过确认，其余 Pi 入口保持原行为。

Android 1.1.0 使用已选定的「灵动伙伴」界面：暖白底色、圆角会话卡片和本地流体圆脸 Bot。首页卡片读取真实会话，点开历史仍是只读；对话、终端、搜索和新建入口保持原有结构。网页 `docs/ai-style-directions.html` 仍是使用模拟数据的风格对照页。

Android 1.2.0 起系统显示名为 Com!。早期产品方向保存在 `docs/COM_PRODUCT_DIRECTION.md`；当前实现与设备验收情况以 1.3.1 的说明为准。

Bot 直接复用用户指定的「Grok 灵动助手 v2」矢量动画与控制器，通过隔离的本地 WebView 播放，不加载远程资源。执行中显示思考，等待回应显示好奇，失败显示错误；只有本次观察到执行/等待转为完成才庆祝一次。初次读取已完成会话、离线缓存及只读历史不触发庆祝。首页支持点按互动，标题栏头像只展示状态；退到后台暂停播放，并遵循系统关闭动画的设置。来源与许可证见 `android/app/src/main/assets/grok-bot/NOTICE.md`。

## Com! 1.3.1

双伙伴（Pi 流体圆脸 / Codex 蓝色毛绒）、角色居中布局、连续场景过渡与背靠背旋转。系统快捷语音默认 Pi，检测到说话后静音约 0.5 秒发送，小窗内等待并显示回复，可继续录音或上滑展开同一会话。详见 [实现与验证](docs/com-1.3.1.md)。
