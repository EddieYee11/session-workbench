# 会话工作台

独立 Android 应用（`work.eddie.sessions`）与 Mac mini 会话服务。可从手机发起和继续 Pi / Codex 会话，查看实时过程和终端，并检索 Mac mini 上保存的历史会话。

- `backend/`：只读历史索引、Codex App Server 接口、Pi 实时扩展、tmux 终端桥。
- `android/`：Kotlin / Compose 原生会话、全文搜索、离线缓存与 xterm.js 终端。
- `backend/tests/`、`android/app/src/{test,androidTest}/`：项目检查代码。

本机虚拟环境、Android 构建产物、连接令牌和 `verification/` 中的设备截图不会提交到仓库。

Android 工程位于 `android/`，可用 Android Studio 打开，或在配置好 JDK 17+ 与 Android SDK 后运行 `./gradlew assembleDebug`。Mac mini 端需要 Python 3.12+、Pi、Codex、tmux 和 Caddy；`backend/install-mini.py` 是针对当前 Mac mini 的部署脚本，运行前应先核对其中的 Caddy 路径和路由。服务状态与会话数据保存在 Mac mini 的 `~/.session-workbench/`，不属于此仓库。

工作台新建和显式继续的会话默认使用最高权限。Codex 采用 `danger-full-access` 与无审批；Pi 使用 `--approve` 和工作台专属工具扩展。如果 Mac mini 全局加载了额外的 Pi 命令护栏，需要让该护栏仅在 `SESSION_WORKBENCH_YOLO=1` 的工作台进程中跳过确认，其余 Pi 入口保持原行为。
