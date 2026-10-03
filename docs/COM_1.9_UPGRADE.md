# Com! 1.9.0：阅读、状态、历史与成果取用

2026-10-03。基于用户提供的 1.8.2 优化审查，在现有 Kotlin/Compose、FastAPI/SQLite 和 Pi 主线上升级；本轮优先完成第一、第二轮建议，并接入文字分享与任务双栏。

## 当前交付

- Android：1.9.0 / versionCode 21，优化 benchmark 包，沿用原签名覆盖安装，保留配对、草稿和历史。
- mini 后端：1.9.0 / API 契约 2；公网 `/sessions/health` 可读取版本、部署源码 commit 和能力。生产源码先经 Syncthing 同步逐文件 SHA256 核对，再在没有活跃 Com 任务／主线输入时备份 SQLite 并重启。
- 三个底部入口仍为对话、今天、工作。普通聊天和后台任务保持原语义；request_id、outbox、未知送达不自动重放的逻辑沿用。

## 已实现

| 使用路径 | 实际变化 |
|---|---|
| 今天看待办 | 页头、决策卡、在办摘要共用 `SourceReadState`。未读取、加载、同步、缓存、失败分开；缓存计数写“上次记录”，附最后成功时间。只依赖主对话、任务和工作建议，不因通知巡检失败误判整块决策卡 |
| 阅读长文 | 离开最新位置时整个顶部头像、状态条与菜单淡出；搜索、返回最新放在输入区上方。保留透明顶部，正文宽度收敛到约 620–640dp。普通成功消息收起重复完成状态；异常和待决定状态保留 |
| 继续工作 | 去掉外层重复顶栏。已有会话按项目简称分组优先展示，保留历史、会话设置和更多入口。三个底部标签常驻，减轻浮动导航阴影 |
| 找回旧消息 | 以消息 ID 对应的 `(created_at,id)` 游标向前分页。搜索主对话正文、任务标题与成果名；支持北京时间日期筛选。结果显示来源，点消息补齐连续历史再定位，并短暂高亮。搜索、分页均不恢复执行器 |
| 取用成果 | 已登记任务成果和主 Pi 直接生成的成果统一索引。Pi 新增 `artifact_register`，把真实文件挂回当前交办消息；稳定 ID、来源、类型、大小、可用状态持久保存。任务详情与消息卡可预览／下载／分享 |
| 成果安全边界 | 接口沿原 Bearer 鉴权，只访问已登记、允许类型、工作区内的文件；拒绝越界、隐藏文件、符号链接、任意路径和超过 100 MB 的文件。读取已校验的文件描述符，避免响应时再次按路径打开 |
| 手机预览与分享 | 图片、文本／Markdown／CSV、PDF 原生预览；PDF 可翻页。Office 文件通过系统打开／分享。文件保存到 App 私有成果目录，由仅开放该目录的 FileProvider 提供临时读取 URI |
| 分享给 Com! | Android 接收文字／链接。先预览、编辑、补充说明；主对话保留已有草稿，不自动发送，也可明确发送为所选活动任务的补充要求。未关闭预览时保留加密记录 |
| 展开任务详情 | 窗口达到 660dp 且满足字号下的最小宽度时显示列表－详情双栏；大字号和窄窗口退回单列。任务 ID 保留，详情成果提前展示，底部主导航保持不变 |
| 重连与读取 | SSE 携带已应用 revision，有效游标读增量，超出服务端版本回快照；旧 revision 不覆盖新消息或任务，恢复缓存不重播旧表情反馈。工作轮询按页面／活跃状态降频，列表与详情读去重，断线退避最多 30 秒 |
| 个人来源 | 心跳、提醒和概览独立并发读取，概览完成即可呈现，不等待其他来源；进入后台后失效相应 fresh 标记 |
| 诊断 | 更多→连接诊断。显示 App build、服务 build、API 契约、实际主线连接和各来源状态；Pi／worker 的配置状态与实际连接分别标注。提供重连和复制诊断 |

成果允许类型当前为 PDF、常见图片、MD、TXT、CSV、DOCX、XLSX、PPTX、MOV、MP4 和 patch。下载后仍需手机上有适配的外部 App，才能系统打开 Office／视频文件。未登记的正文路径不会自动变成可下载文件。

## 本轮验证

- 后端 81 项相关测试通过：历史、分页、搜索、文件鉴权与边界、成果登记／投影、主对话、任务卡、消息引用、送达、任务连续性。
- Android 67 项单元测试通过；Debug、测试 APK 和优化 benchmark 构建通过。
- 411dp 正常字号最终 12 项设备检查通过，包含新状态、历史阅读与追加旧消息的锚点、工作页、分享草稿、任务自适应、真实主／工作聊天键盘和 PDF／中文文本预览。
- 686dp 正常字号 15 项页面与导航检查通过；另 3 项最终视觉检查通过，亲自查看了实际双栏任务和工作页截图。
- 411dp / 1.5 倍字号最终 13 项检查通过，检查单列回退、导航标签、阅读和状态条。
- Xiaomi 实体手机从公网下载 mini 真实生成的 PDF（607 字节）与 Markdown（51 字节）。手机文件 SHA256 与 mini 同步到 MBP 的原文件一致；PDF 由手机 PdfRenderer 成功读取，系统分享 content URI 可读。两项只读手机下载检查通过。
- 使用同一 PDF 在模拟器运行实际原生预览，检查通过并亲自查看截图。实体手机的 Compose 自动界面测试因系统 InputManager 与 Espresso 不兼容失败；平台 Activity 启动测试也超时，因此**不把手机手持预览／实际分享到其他 App 记为通过**。
- 最终 APK 与 1.8.2 签名证书 SHA256 一致：`d01d14be850e7386ca77b2bbb1d5b9d36282b84f12cc70d6bde8e5ec8780434a`。设备包管理器回读版本 1.9.0 / 21。

未发送生产聊天、未操作账本／提醒、未启用主动观察。验证 PDF／MD 的登记使用独立临时成果记录，没有新建生产任务或主线消息；验收后删除临时登记，保留本地验证材料。

测试截图曾被配对弹层或关闭动画盖住，已修正测试的弹层关闭和截图等待，重新抓取可见页面。历史失败日志也保留在本地验证目录，不将第一次失败改写为成功。

## 当前边界与后续建议

本轮不是整份提案的全部实现。以下保持后续范围：

- 三个领域 Repository／不可变业务 UiState 的完整迁移、Room／DataStore 迁移与工作会话 SSE；目前只统一来源读取状态并协调必要的读取。
- Android 图片／PDF 分享上传、附件去重、媒体模型协议和抽取能力；当前分享目标仅文字／链接。
- 主对话和工作页的全套双栏／成果并排；本轮双栏落在任务详情。
- 通知合并、点击回流和稍后处理策略；主动观察仍沿原影子／暂停／受限设置，未启用新权限。
- 语音全阶段文案、蓝牙／锁屏／噪声／弱网与连续输入的完整实机验收；保留现有快捷发送语义。
- 记忆来源／更正／失效、承诺实体和技能晋升；不从随口表达自动建立承诺。
- 响应 P50/P95、空闲请求数、传输量和丢帧指标；本轮没有新实测基线，不宣称整体提速百分比。

主线最近快照仍保留 500 条以兼容现有协议，新的只读分页可以取回更早记录。历史长期可查不意味着全部历史进入模型上下文；大量历史的本地查询和缓存迁移仍可继续优化。Pi 自动生成→调用成果登记的真实模型回合尚未发送验证，登记工具、持久投影和手机取用分别有检查证据。

手持待验收：物理折叠／展开、真正点击文件分享并在外部 App 使用、完整语音锁屏／蓝牙路径，以及弱网与杀进程后的端到端体验。

## 文件与复现

- 安装包：`verification/com-1.9.0/Com-1.9.0.apk`；精确 SHA256 和设备更新时间记录在本地 `verification/com-1.9.0/delivery.json`。
- 正常窄屏和 PDF 预览：`verification/com-1.9.0/screenshots/narrow/`；大字号：`screenshots/font15/`；686dp 工作和任务截图位于 `screenshots/`。
- 构建／后端／设备日志在 `verification/com-1.9.0/logs/`，不提交含设备状态的验证目录。

```sh
.venv/bin/python -m pytest backend/tests/test_history_artifacts.py backend/tests/test_conversation.py backend/tests/test_work_cards.py backend/tests/test_api.py backend/tests/test_message_references.py backend/tests/test_conversation_delivery.py backend/tests/test_task_continuity.py -q
JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./android/gradlew -p android assembleDebug assembleDebugAndroidTest testDebugUnitTest assembleBenchmark
```

| 源码 | 职责 |
|---|---|
| `SourceFreshness.kt`、`TodaySections.kt`、`PersonalOverview.kt` | 来源新鲜度、计数和今天布局 |
| `HermesChat.kt`、`ConversationSearch.kt` | 阅读避让、分页入口、搜索与定位 |
| `Store.kt` | 既有加密缓存、outbox、增量应用、读取生命周期与协调 |
| `backend/conversation.py` | 稳定历史游标、搜索、SSE 恢复、成果投影 |
| `backend/artifacts.py`、`backend/agent_tools.py`、`backend/com-pi.ts` | 主线成果登记、索引、受限文件访问和 Pi 工具 |
| `TaskPresentation.kt`、`ArtifactPreview.kt` | 下载、原生预览和系统分享 |
| `IncomingShare.kt`、`MainActivity.kt`、`AndroidManifest.xml` | 分享接收、预览草稿、来源路由 |
| `TaskLedger.kt`、`ChatUI.kt` | 任务双栏、工作页与底部导航 |
| `ConnectionDiagnostics.kt`、`backend/app.py` | 诊断、版本与 API 能力元数据 |
