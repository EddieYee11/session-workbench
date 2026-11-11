# Com! 客户端红字修复与全能签打包记录 (Plan B)

> 记录时间：2026-11-11 13:06
> 执行脚本：`ios/scripts/build-push-allsign.sh`
> 任务阶段：步骤 4-5（编译打包与真机全能签通道核验）

---

## 一、改动文件清单与修复逻辑

### 1. 改动文件
- `ios/Com/AppModel.swift`
- `ios/Com/Views/ShareInboxView.swift`

### 2. 修复逻辑（Plan B 动态感知降级）
- **根因背景**：全能签（AllInSign）无证书重签方案在流水线打包时必须剔除 `PlugIns/ComShare.appex` 与 App Group 容器。在没有 App Group 扩展的环境下，原前台探测逻辑会触发红字异常横幅（`shareInboxNote` 报红，且进入收件箱时持续报错）。
- **`AppModel.swift` 变更**：
  - 新增 `hasShareExtension` 动态探针：通过 `Bundle.main.builtInPlugInsURL` 检查 `ComShare.appex` 物理存在性。
  - 改造 `refreshShareInboxPresence()`：若判定为无扩展重签环境（`!hasShareExtension`），静默收敛 `shareInboxNote = ""` 且 `showShareInbox = false`，彻底消除主聊天窗口顶部的常驻红字报错。
- **`ShareInboxView.swift` 变更**：
  - 改造 `reloadList()`：若为无扩展重签包，设为中性说明文案，`listFail` 提示 tone 由 `.danger` 降为 `.neutral`。
  - 隐藏无效的「再试一次」按钮，并在空状态卡片明确提示「当前为无扩展重签包，系统分享收件箱未启用；可正常使用聊天、看板与 Siri，系统分享需原生签名包」。

---

## 二、编译与打包记录

- **执行指令**：`zsh ios/scripts/build-push-allsign.sh`
- **XcodeGen 生成**：读取 `ios/project.yml` 重新生成 `ios/Com.xcodeproj`，成功。
- **Xcode 编译**：
  - Configuration: `Debug`
  - SDK: `iphoneos`
  - 架构: `arm64` (Any iOS Device)
  - 签名参数: `CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO`
  - 结果：`** BUILD SUCCEEDED **`
- **IPA 打包处理**：
  - 剔除 `PlugIns/ComShare.appex` 与 `_CodeSignature`
  - 剔除调试 `.dylib` 与 `.bak*` 临时文件
  - 打包产物：`Com.ipa`
  - 目标版本：`CFBundleShortVersionString = 1.0.0`，`CFBundleVersion = 2026111001`
  - 产物大小：`30,483,771 字节` (~29.07 MB)
  - 副本保存位置：`~/Downloads/Com.ipa`（防 tmp 清理，方便直接隔空投送或全能签读取）

---

## 三、真机安装与通信通道记录

- **目标设备**：`Eddie的iPhone (2)` (`00008160-001E3CEA36E00036`，iPhone 19,4)
- **目标沙盒**：全能签 `signall.nuosike.sign`
- **通道验证现象**：
  - 当前 Mac 处于搜狐公司 Wi-Fi（`10.2.147.193`），无线处于企业 AP 隔离环境，且手机未接入 USB 物理线缆。
  - `xcrun devicectl list devices` 设备状态呈 `unavailable`。
  - 脚本执行至第 3 步（`xcrun devicectl device copy to`）触发 CoreDevice 4016 错误（`remoteServiceDiscoveryTrustedConnectivityAvailable` 不满足）。
- **交付与安装方式**：
  1. **方式 A（USB 直连推入）**：手机插上 USB-C 数据线并解锁信任后，直接再次执行 `zsh ios/scripts/build-push-allsign.sh`，脚本将在 5 秒内将 IPA 与更新元数据注入全能签，并自动拉起全能签。
  2. **方式 B（隔空投送一键导入）**：直接把 `~/Downloads/Com.ipa` 隔空投送（AirDrop）到手机，选择用「全能签」打开并签名安装。

---

## 四、硬边界核验报告

- [x] **不动 entitlements**：未修改 `ios/Com/Com.entitlements` 中的既有项。
- [x] **不动签名与 Profile**：未变更开发团队、签名证书或任何 mobileprovision 描述文件。
- [x] **不动 backend**：未修改任何后端代码逻辑。
- [x] **不动 superagent-flags.json**：未触碰任何运行时特性开关。
- [x] **不改 ShareInbox.swift 读写逻辑**：底层 App Group 与文件容器读写原样保留，仅在上层 UI/Model 做了环境探测防御。
