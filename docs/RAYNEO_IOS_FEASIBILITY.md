# 雷鸟 iO → Com! · iOS 可行性核对

2026-10-07。用户要求检查，眼镜当前未配对/不在手边。本轮不改绑定、不刷固件、不替换雷鸟 App。

结论：Turbo-IO 有 iOS 语音→自定义模型→镜片回显基础，可以接 Com；当前 Com iOS 本身没有 iO BLE/协议/眼镜 ASR，不能把普通蓝牙麦克风选项当成已打通。

## 推荐接入路径

眼镜 → 兼容的雷鸟官方 iOS App + Turbo-IO V2 → 官方 ASR → Com 眼镜专用 HTTPS 接口 → Com 主对话/实际执行器 → 流式回答 → 官方回显。

- 上游 [扩展说明](https://github.com/Turbo1123/Turbo-IO/blob/main/official-addon/README.md) 提供自定义 HTTPS 模型入口，Key 存钥匙串；保留官方识别、配对及显示。
- 源码 [Core.m](https://github.com/Turbo1123/Turbo-IO/blob/main/official-addon/Core.m) 的 `TIOChatRequest` 生成 model、stream=true、messages，但没有 Com 必需的稳定 request_id；`Addon.m` 可配置完整 chat/completions URL、模型、Key。因此不能只填地址就宣称完全兼容。
- 适配需给每次新眼镜问题生成稳定 ID，断线重连沿用同一 ID；模型 `com-personal`，接口 `https://pi.eddiegao.work:8443/sessions/rayneo/v1/chat/completions`。使用专用眼镜令牌，不暴露手机主权限；查询原请求回执，不重放记账等操作。
- Com `backend/rayneo.py` 已有配对、专用令牌、请求去重、流式输出和真实结果核实。本轮从 mini 对公网眼镜 health 实际请求，返回 ok=true、com-rayneo、com-personal。已有 Android derivative 在本机保留，iOS 对应定制未实现。
- V2 构建需要兼容官方应用输入及本人签名，不能把普通商店加密 App 当成已合并插件。现有来源/签名未核验，暂未制作或安装 iOS 雷鸟扩展。

另一路是 [V1 独立 SDK](https://github.com/Turbo1123/Turbo-IO)：可研究配对、录音、ASR及显示，工作量更大；切换客户端会影响现有绑定。当前不迁入 Com、不争抢连接。

## 验收边界

已核对：上游说明、具体请求字段、Com 接口契约及公网响应。未核对：这副眼镜固件、iPhone 配对、语音识别、镜片回答、后台追问。眼镜在手边后，按确切 iOS 宿主版本构建适配，再测短问答→同请求重连→实际指令/回执→镜片确认。

## 2026-10-09 · iOS 插件侧实现完成，实机验收待做

按上面的推荐路径，在 Turbo-IO `official-addon`（V2 注入到官方 iOS 宿主）里补上了与 Android 对等的 Com! 眼镜入口，源码在本地 `work/工具与效率/雷鸟眼镜/Turbo-IO/official-addon/`：

- `ComIngress.h/.m`：地址校验与 `<base>/<path>` 拼接、`rayneo-<uuid>` 请求标识、`com-personal` 流式请求体（只带最后一条用户话语，不带插件历史、不注册本机工具）、配对码/health/receipt 文本，以及有界的 OpenAI 兼容 SSE 累加器。
- `ComIngressUI.h/.m`：`模型与对话 → Com! · 配对与请求回执` 面板，提供地址、一次性配对码配对、配对状态、真实服务连接、手机链路测试、查询上次回执、重连上次请求。配对成功即写入 `comBase`、`endpoint`、`model=com-personal`、`mode=2`，令牌存手机钥匙串（不回显）。
- `Addon.m`：官方 ASR final 到达时生成并持久化稳定 `request_id`；Com! 模型走 `com-personal` 分支，`TIOWebChatRequest` 追加 `X-Com-Request-Id` 并把资源超时放宽到 140 秒以覆盖服务端 80 秒等待窗口；已配对时本轮所有 NLP 意图交给 Com!，官方回调不再另执行官方待办。
- `ResearchCatalog.m`/`WebSearch.h`：新增入口行，以及聊天请求的 `requestID`/`resourceTimeout` 字段。

已验证（本机，无眼镜）：`ComIngressTests.m` 契约测试覆盖地址/标识/请求体/接管/receipt/SSE 帧，`official-addon/test.sh` 全量通过；`bash official-addon/build.sh embedded` 生成 `build/embedded/TurboIOPrivateAddon.dylib`（`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`），`preview/build.sh` 模拟器预览可编译。

未验证：把该 dylib 合并进有权使用的官方 iOS 1.0.5(201) 宿主、本人签名安装，以及真机上的短问答→同请求重连→实际指令/回执→镜片回显、打断和后台追问。手机链路测试返回文字不等于镜片显示成功。

## 2026-10-09 · 真机安装：宿主与签名链路已就绪，前置条件缺两项

官方 iOS 1.0.5(201) 宿主已在本地备好（`~/RayNeo-ios-private/`，仓库外）：`RayNeo_AI_1.0.5_201_decrypted_original.ipa` → `extract/Payload/Runner.app`，已核 `CFBundleIdentifier=com.rayneo.venus.pub`、`1.0.5/201`、thin arm64、UUID `748FD301-DA60-3095-A244-9BD0558FACA5`、无符号链接、无 PlugIns，可执行文件 SHA-256 `b27f3581bea7a945560bce501823a9697fc878ab54286a330fa199bb85b828aa`（源保持不变，合并由 `package.mjs` 自己执行）。

本轮实测的两个前置条件（`zsh ~/RayNeo-ios-private/install-rayneo-com.sh --check` 可复现）：

- **Xcode 26.3 当前没有任何 Apple ID 账号**（`DVTDeveloperAccountManagerAppleIDLists` 为 `{"IDE.Identifiers.Prod":[]}`，钥匙串无 `Xcode-AppleID` 项），`xcodebuild -allowProvisioningUpdates` 直接失败：`No Accounts: Add a new account in Accounts settings.`。本机只有 `AJN4TFSWT9` 免费 Personal Team 的 `Apple Development: [个人邮箱] (HQQ8DQXD7B)` 证书和四个 `work.eddie.*` 描述文件（2026-10-13/14 到期），**没有** `com.rayneo.venus.pub` 的描述文件，离线也无法新建 App ID。
- **iPhone 17 Pro 当时未连 USB**：`devicectl` 状态 `unavailable`，`tunnelState=unavailable`、`transportType=nil`，无法作为构建目标或安装目标。

因此本轮未产出可安装包，未做任何安装。补齐上述两项后，`zsh ~/RayNeo-ios-private/install-rayneo-com.sh` 一条命令完成：生成描述文件 → `package.mjs` 合并签名 → `devicectl` 安装，并打印后续 App 内步骤。

已在本机去掉风险的环节：宿主可执行文件与 88 个 Frameworks 的全部 89 个嵌套 Mach-O 用本人证书重签成功，`codesign --verify --deep --strict` 通过；`macho-embed.mjs` 会校验插件里编译进的 Bundle ID，只接受 `com.rayneo.venus.pub`（不能用其他 Bundle ID 走捷径签名）。

改签影响（已核官方 1.0.5 宿主自身 entitlement）：原包只有 `application-identifier`、`aps-environment=production`、`com.apple.developer.applesignin`，**没有 App Groups**。改签后推送与「通过 Apple 登录」会失效；蓝牙、本地网络、麦克风、定位等只依赖 Info.plist 描述，眼镜连接路径不依赖丢失的两项，但仍须真机核验。开发描述文件 7 天到期，过期后需重新签名安装。

另：本轮 `ssh mini`、LAN `192.168.5.215`、Tailscale `100.72.89.33` 均不可达，本机 `~/.session-workbench/` 也没有 `rayneo-pairing.json`；一次性配对码由 Com! 服务端签发，端到端（配对 → 流式回答 → 回执）在 mini 恢复前无法完成。

## 2026-10-09 · 已装入 iPhone：宿主改名 `work.eddie.rayneo`（重要偏离）

当晚补齐 Xcode Apple ID 后，实际装机又暴露三个硬约束，最终产物与原计划不同：

1. **`com.rayneo.venus.pub` 无法注册到本人团队**。Apple 的显式 App ID 全局唯一，该 ID 属雷鸟团队 `SL7932DRJ3`，注册报错 `The app identifier "com.rayneo.venus.pub" cannot be registered to your development team because it is not available`。通配符描述文件同样被拒（`XC work eddie *` 无效）。**因此"保留官方 Bundle ID"在个人团队下不可行。**
2. 宿主改为 **`work.eddie.rayneo`**，插件用 `bash build.sh embedded work.eddie.rayneo` 同步重编译（`TIO_TARGET_BUNDLE_ID` 会同时驱动 `Addon.m` 与 `ProtocolContext.m` 的宿主校验；后者本轮从硬编码字面量改为该宏，否则改名后字幕默认模板会失效）。`test.sh` 全量仍通过。
3. **免费个人团队每台设备只允许 3 个自签 App**。安装被 `MIFreeProfileValidatedAppTracker` 拒绝，占用者为 `AltStore`、`Clip`、`Com!`。按用户指示删除 AltStore 与 Clip 后安装成功。

本轮实测边界（`~/RayNeo-ios-private/install-rayneo-com.sh` 已把这四点都固化成检查）：

- `UISupportedDevices` 是商店裁剪产物，只到 `iPhone16,x`，iPhone 17 Pro（`iPhone18,1`）首次安装被 `DeviceNotSupportedByThinning` 拒绝；`package.mjs --product iPhone18,1` 补入后通过。
- `devicectl` 的可用状态会写 `available` 或 `connected`，两者都算在线。
- 成功产物 `~/RayNeo-ios-private/signed-20261009-115842/`（IPA SHA-256 `d779f8f3a8eac42c574f59a746f3c138411836616402632cb6b7ff21c8e47319`）：Bundle `work.eddie.rayneo`、版本 1.0.5(201)、宿主 UUID `748FD301-DA60-3095-A244-9BD0558FACA5` 未变、插件已内嵌、`codesign --verify --deep --strict` 通过、`devicectl` 安装成功且进程存活、无崩溃日志。
- 官方 ID 那版插件保留在 `~/RayNeo-ios-private/TurboIOPrivateAddon-official-bundle.dylib`（SHA `b91a7658…`），供有权注册该 ID 的场景使用。

未验证 / 需要留意：

- **改名的功能风险**：`RayneoNet.framework` 内含 `cn.rayneo.mercury / com.rayneo.venus.dev / com.rayneo.venus.pub` 变体分支，改名后 MFi 重连分支是否仍正确尚无实机结论；推送与 Sign in with Apple 按预期失效。
- **续签链路变了**：AltStore 已删除，Com! 的免费描述文件 2026-10-13 到期后需要改用 Xcode 重新签名（现在 Xcode 已有账号）；每 7 天需重签一次，且三个槽位已被 Com!、雷鸟宿主占用两个。
- **镜片层完全未验收**：未配对眼镜、未做短问答→同请求重连→真实指令/回执→镜片回显。手机端能装、能启动不等于眼镜可用。
