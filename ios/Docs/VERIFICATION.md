# Com! iOS 实施与现场验证

2026-10-06，MBP macOS 15.7.1；实体 iPhone 17 Pro（iPhone18,1），iOS 27.0，USB 设备可枚举。此记录区分可验证的工程工作与尚未完成的日常使用验收。

## 已完成且有执行证据

- 新增 `ios/` 原生工程、五板块与 HTTPS 服务客户端、语音、HealthKit／EventKit／Contacts／前台位置设备桥、分享扩展、回执、成果预览和终端代码。
- XcodeGen 2.46.0 成功生成 `Com.xcodeproj`；签名团队保存在本机忽略的 `Signing.xcconfig`，重新生成后可继续构建，主 App 的设备族已核验为仅 iPhone。
- 真机完整构建、自动签名和安装已通过。主 App 与分享扩展的签名严格校验通过；profile 包含当前 iPhone、HealthKit 与同组共享权限，有效至 2026-10-13。首次启动待手机显式信任开发者。
- iPhone 17 Pro / iOS 26.2 模拟器 XCTest 与 UI XCTest 通过，0 失败。UI 测试实际检查了未配对连接页，**尚未覆盖真实五板块导航**；连接页角色与布局已查看。Mac 随后锁屏，界面工具明确要求 Eddie 手动解锁，已请求操作。
- ComCore 用当前 CLT Swift 6 编译并执行 **96 项恢复／传输检查**：分割 UTF-8、CRLF、多行 SSE、消息版本、历史保留、任务去重、本地序列化、原请求 ID、附件与 HTTPS 限制。
- 后端完整回归 **465 passed, 3 skipped**。跳过为现有受环境条件限制的测试；保留 FastAPI TestClient 的现有弃用警告。新增 iOS 契约测试包含平台默认 Android、iOS 不可用能力、私有附件上传／校验／去重、主消息回执、授权设备来源选择、不透明 EventKit ID。
- 本轮后端增量沿既有 Syncthing 同步到 mini，5 个受影响文件哈希一致；确认无 queued/sending/running 主对话、无活动任务后重启服务。最终附件中文文件名解码增量亦已在无活动主对话／任务时加载，公网 health 回读成功。health 返回 `ios_nodes_v1`、`main_receipts_v1`、`selected_attachments_v1` 为 true。
- MBP 上实际编译的 Swift ComCore，经公网 HTTPS 只读访问：聊天 455 条、今天 5 卡、任务 31 项、记忆 1 条、工作 274 会话；收到有事件 ID 的 SSE snapshot 并取消连接。没有提交测试用户指令。这证明客户端核心与真实接口可连接，**尚未证明五板块 UI 已接入真实数据**。
- 保留原有 `business_tools.py`、`conversation.py`、`hermes_runtime.py` 和记账相关未提交工作；在本机忽略目录保存原始修改补丁与回滚参考。未发布 GitHub Release。

证据保存在工程根目录被 Git 忽略的 `verification/ios-20261006/`：`backend-regression.txt`、`live-contract.txt`、原始用户修改补丁。图标三个主题已本机生成并目视检查，连接页截图为 `onboarding.png`；五板块页面与录屏待 Mac 解锁后继续。

## 当前工具链进展

- Xcode 26.3（17C529）已安装到 `/Applications/Xcode.app`，已完成首启；Apple 签名与 Gatekeeper 验证通过。构建脚本使用 `DEVELOPER_DIR`，无需改全局 CLT 选择或升级 macOS。
- Eddie 已登录 Apple 账号；主 App 和分享扩展的 Personal Team 自动签名配置成功，现有有效开发证书 1 个。未保存账号密码或验证码。
- iPhone 17 Pro 的开发者模式已启用、开发镜像服务可用。App 已成功安装，启动被系统拒绝，原因是个人开发者签名尚未在手机上显式信任；已请求 Eddie 完成设备信任。
- Metal Toolchain 17C7003j 已下载。iOS 26.2 与 26.3.1 arm64 Simulator 运行时及所需 iOS 平台支持已安装。
- 完整 Xcode 下 Swift Package XCTest 已通过；整个主 App 通过 iOS SDK Swift 6 类型检查。主 App、ComCore 和系统分享扩展完整构建及签名成功；健康与 App Group entitlement 均在 provisioning profile 中，且包含当前手机。证书链及 App 的深层严格签名校验通过。
- SwiftTerm 固定 1.20.0 的 build plugin 已检查：仅生成 Git 构建信息；在本工程命令中允许该固定依赖的插件运行，未修改全局验证设置。

## 尚未完成的必须验收

| 场景 | 状态与验收标准 |
|---|---|
| 完整 App 构建 | 已通过真机编译、链接、签名与 entitlement 验证；主 App 与分享扩展已安装。AppIntents NL training 的 SSU archive 诊断未导致构建失败，快捷指令实际运行待确认 |
| 五板块 UI / 操作 | 待模拟器和真机；真实状态、权限缺失原因、补充／取消／恢复作用于正确任务，审批与模型选项有效 |
| 聊天送达 | 待设备；断网、重连、后台、重启草稿保留，同一请求不重复交办，未知先查回执 |
| 录音 | 待实际说话；开始、取消、上限停止、拒绝权限、ASR 失败重试和迟到取消；不自动发送测试音 |
| 日历／提醒事项／联系人 | 待系统授权；只用 `Com TEST iOS <UUID>` 对象，创建→更新→回读→撤销；不编辑已有真实对象 |
| 健康 | 待读真数据；不制造记录；空结果明确无可用数据；同步开关与来源／区间清楚 |
| 跨来源健康去重 | 待真实 HealthKit / Garmin 数据；不把多个设备摘要相加，跨来源重复关联不能凭数值猜测 |
| 双端同时使用 | 待安装；Android/iOS 可同时收流、回执一致；记忆纠正版本冲突保留双方来源 |
| 分享／预览／终端 | 待设备；实际系统分享扩展→草稿、文件／照片、Quick Look、导出；终端输入／resize，不重发断线输入 |
| 辅助功能与长列表 | 待真机；大字体、深浅色、降低透明度、减少动态效果、VoiceOver、键盘、连续返回和快速切换 |
| 性能 | 模拟器连接页 Time Profiler 采集 20.754s，未记录 ≥250ms 的 potential hangs；仅角色页基线。Animation Hitches 不支持此模拟器，真机滚动、能耗、内存与 ProMotion 待验收 |

用户手持确认单独保留：录音手感与实际说话、角色触摸回弹、键盘与单手导航、长时间阅读舒适度，以及在日常后台切换中恢复结果的可靠性。工程可继续，但当前不能标记整份计划完成。


## 2026-10-06 · Muse 参考界面改造

- 已在原生 SwiftUI 工程完成黑色画布、圆形 Com 头像／状态牌、蓝色用户气泡、深灰助手气泡、五图标悬浮底栏，以及今天、任务、记忆、Com 工作记录的排版。
- iPhone 17 Pro / iOS 26.2 模拟器：核心恢复／流式／传输契约 1 项，UI 2 项全部通过。UI 覆盖五页切换、设置开关、事项与任务详情返回、任务筛选、记忆搜索与清除、键盘输入和发送按钮可点击。
- 已亲自查看原生运行截图；修复了输入框被外层底栏遮挡，以及详情 zoom 返回后偶发阻塞点击的问题。键盘显示时聊天底栏收起。
- 模拟器使用隔离 Debug 预览数据，不访问服务或保存到真实缓存。UI 测试没有发送消息、创建任务或写入业务数据。
- 真机签名构建通过，已覆盖安装 `work.eddie.com` 到 Eddie 的 iPhone 17 Pro。启动被系统以 `Locked` 拒绝，需解锁后打开；本轮尚未看到真机界面。没有把安装成功当成真机使用验收。
- 日常语音、权限、后台恢复和真机辅助功能仍沿用上表的待验收状态。
- 证据：`verification/ios-muse-restyle/UI-final.xcresult`、`test-final.log`、`build-device.log`、`install-device.log`、`launch-device.log`；六屏预览为同目录 `preview.html`。
- 改动前源码备份：`verification/ios-muse-restyle/source-before.tar.gz`。本次未修改 Android 与后端；工程中原有未提交改动保持不动。

## 2026-10-07 · 主聊天键盘与消息连续性

- 键盘出现时，消息列表与输入区一起适应原生安全区；底栏收起。长列表自动滚到最新气泡，手动阅读历史时保留位置。消息从实际输入框沿弹簧弧线进入最终气泡；录屏逐帧复核后修复了滚动前坐标造成的落点跳变。
- 本地发件箱与服务端消息按原请求 ID 交接；收到受理回执但快照尚未到达时仍显示消息。同文不同请求保持独立。增加明确送达/执行状态、新回复跳转与被拒消息回到草稿；本轮没有自动重发真实请求。
- iPhone 17 Pro / iOS 26.2 模拟器完整检查：3 项核心测试与 9 项 UI 测试通过，0 失败。覆盖五页导航、语音与快捷语音小窗、记忆来源、长列表键盘抬升、发送交接、阅读位置、新回复提示、被拒草稿和减少动态效果。最后的落点修复再次通过键盘/发送与减少动态效果 2 项针对检查。
- 发送 UI 检查使用隔离 Debug 数据，模拟受理及延迟快照，没有向 Hermes 提交测试业务。实际服务只读合同检查确认用户消息包含请求 ID；不能把隔离 UI 发送测试当作一次真实 Hermes 执行。
- 最终真机签名构建成功，02:05 覆盖安装到 Eddie 的 iPhone 17 Pro；02:11 正常启动成功（不带 UI 测试参数），`devicectl` 返回 `Launched application with work.eddie.com bundle identifier.`。真机手持的键盘手感、120Hz 动效、实际说话与后台往返尚未在本轮目视验收。
- 证据位于 `verification/com-chat-motion/`：`Verified.xcresult`、`Handoff.xcresult`、`Landing.xcresult`、`build-device-landing.log`、`install-device.log`、`launch-device.log`；当前发送录屏为 `send-animation.mp4`，键盘与新回复截图为 `keyboard.png`、`unread.png`。
