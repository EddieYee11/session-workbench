# Com! iOS

原生 iPhone 工程，iOS 26 起。底部保留聊天、今天、任务、记忆、Com（工作记录）。SwiftUI + Swift Concurrency；SwiftTerm 提供原生终端，Textual 提供 Markdown。主聊天及确认后的语音均走 Hermes 持续对话，工作页沿既有 Pi / Claude / Codex 接口。

**当前交付状态（2026-10-07）：原生 App 已构建、签名、安装并在 iPhone 17 Pro 正常启动。** 模拟器核心与界面检查覆盖键盘抬升、发送动效、请求回执交接、历史阅读位置、语音入口与记忆来源。真机手持动效、实际说话、权限和日常使用仍待验收。详见 [现场验证记录](Docs/VERIFICATION.md) 与 [设计记录](Docs/DESIGN.md)。

## 工程入口

打开 `Com.xcodeproj`。修改 `project.yml` 后使用 XcodeGen 生成；签名团队通过 Xcode 或构建参数传入；安装脚本将团队 ID 保存到忽略的 `Signing.xcconfig`，重新生成工程后仍可使用同一签名，不提交账户信息。`Com/Core` 为可独立检查的网络、消息与恢复层。`Com/Platform` 为设备桥接与加密持久化。`Com/Views` 为五板块与设置、预览、终端。`ComShare` 为系统分享扩展，`Shared` 为受文件保护的 App Group 收件箱。

## 安装流程

1. 按 [Apple 官方下载页](https://developer.apple.com/download/all/?q=Xcode%2026.3) 下载 Xcode 26.3。它支持当前 MBP 的 macOS 15.7.1；依据 [Apple 工具链要求](https://developer.apple.com/xcode/system-requirements)。官方表列设备支持 iOS 15 或更高，但本机 iOS 27 的实际连接、开发镜像与调试必须现场验证。
2. 解压到 Applications，打开 Xcode 完成首启组件安装与许可证流程。脚本默认使用 `/Applications/Xcode.app/Contents/Developer`，也可通过 `DEVELOPER_DIR` 指定。Xcode Settings → Accounts 中由 Eddie 本人登录 Apple 账号、完成验证。
3. 手机解锁并信任这台电脑；系统提示时由 Eddie 开启开发者模式。选择当前 iPhone，配置 Com 和 ComShare 的同一个 Personal Team。启用 HealthKit 及 `group.work.eddie.com` App Group。若标识已有占用，修改两个 Bundle ID、同组标识以及 `ShareInbox.group`。
4. 先运行模拟器构建和测试，再运行真机安装脚本：

```sh
./Scripts/check-environment.sh
./Scripts/test-simulator.sh
./Scripts/build-install.sh <Personal-Team-ID> 00008150-000E04CA2ED8401C
```

5. App 中填写 HTTPS 地址 `https://pi.eddiegao.work:8443/sessions` 和 mini 生成的一次性配对码。令牌存 Keychain，拒绝 HTTP 与跨站重定向。配对码应在实际安装就绪后生成，避免提前过期。
6. 按 [验收记录](Docs/VERIFICATION.md) 逐项验证后才算日常可用。若 Xcode 26.3 不能处理此手机的 iOS 27，再报告具体工具链错误并单独决定升级条件；不默认升级 macOS。

免费账号的 provisioning profile 在签发 7 天后到期，届时重新构建、安装；见 [Apple 免费账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account)。系统能力的 entitlement 仍需现场签名验证；官方 [能力表](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) 列出普通 Apple Developer 账号支持 HealthKit 和 App groups，不支持 Push notifications。这里未启用 APNs。

## 无完整 Xcode 时可执行的检查

```sh
./Scripts/check-core.sh
```

该脚本用当前 CLT 编译真实 ComCore，测试 UTF-8 SSE、断线快照合并、历史保留、请求 ID 和附件恢复，以及 HTTPS 请求约束。`Package.swift` 为 Swift 6 标准包；当前 CLT 的 ManifestAPI 接口混用会导致 `swift test` manifest 失败，因此本轮采用独立编译检查，未修改系统工具链。完整 Xcode 下的 Swift Package XCTest 现已通过，App 与 UI XCTest 仍需模拟器运行时。

`check-live.sh` 从 stdin 接收令牌，只读五板块并检查 SSE，**不提交用户指令**。令牌不要作为命令行参数、写入文档或打印到日志。

## 运行边界

- 本地草稿、待发送与缓存加密保存；音频和分享文件受系统文件保护并排除备份。
- 新请求在发送前持久化 ID。结果未知先查回执；未知工作请求不会重新创建执行器。
- App 在前台保持 SSE 与设备 WebSocket；后台关闭连接和持续动画、保存录音，任务由 mini 继续。返回前台补取快照。
- 麦克风到 60 秒停止录制，等待转写／取消／确认发送；转写本身不交办。取消后丢弃迟到的转写结果。
- 健康只读；空结果不产生零值，也不推断用户拒绝。健康和联系人查询结果默认不向 mini 提供，需在设置分别开启。
- 日历、提醒事项和联系人 ID 按不透明字符串处理。写入回读、版本校验与撤销凭据在设备回执中保留；未知结果不重放。
- 同一 HealthKit 来源的聚合及睡眠区间去重；mini 不将多个设备摘要相加。Garmin 与手机来源对同一数据的跨来源关联仍需真机数据验证，不能仅凭数值相同合并。
- 其他 App 的通知读取、任意控制及应用清单明确不支持。照片走系统选择器。

[设计与参考来源](Docs/DESIGN.md) · [动效规范](Docs/MOTION.md) · [验收与未完成项](Docs/VERIFICATION.md)
