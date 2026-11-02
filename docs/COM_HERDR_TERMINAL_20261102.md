# Com 内嵌 herdr 终端（2026-11-02）

工作 Tab →「终端」→ 选 MBP / mini →「打开完整 herdr」，或点某个 pane 直接进它的终端。

## 结构
- 渲染：libghostty-spm（`GhosttyTerminal`，固定在 Heeler 审过的 revision 7e45d27）。
- SSH 与会话树：`projects/moshi-ios/app` 的 HerdrKit（Citadel）。新增 `SSHPTYSession`（真 PTY，xterm-256color）。
- 完整界面命令：`env HERDR_CONFIG_PATH=~/.config/herdr/config-com-phone.toml herdr`；单 pane：`herdr terminal attach <id> --takeover`。
- 替换了 Cursor 11-01 版（每 0.9 秒 `pane.read` + UITextView，无 ANSI，只连 MBP），旧文件在 `_archive/ios-removed-20261101/`。

## 配置与密钥
- 机器地址：mini `~/.session-workbench/herdr-machines.json`（不进仓库，仓库是公开的）；App 缓存一份，按顺序试公网 / Tailscale / 局域网（每个 10 秒）。
- 密钥：手机本地生成 ed25519，私钥只在 Keychain；启动时把公钥登记到 `POST /remote/herdr/device-key`。
- 后端只记录公钥，不写 authorized_keys。换设备或清钥匙串后，在 MBP 跑 `python3 backend/herdr_push/install_device_keys.py`，它同时重新生成手机版 herdr 配置。**改了 `config.toml` 的按键后也要跑一次**，手机版配置是快照。
- 主机指纹：首次信任后固定，变化时拒绝连接并让人确认。

## 已知取舍
手机连着完整 herdr 时，服务端 pane 尺寸跟随最新连接的客户端（实测 120×40 → 38×28，弹键盘 38×11），桌面端和 agent 会被重排；断开后恢复（实测回到 120×40）。

## 验收
`Tests/UI/HerdrLiveUITests.swift` 连真实机器，平时跳过。按键会进目标机当前聚焦的 pane，`COM_LIVE_HERDR_TYPE=1` 才打字，不要对 MBP 开。
真机跑不了 UI 测试：`ComUITests` 签名报 No Accounts。

## 外网连接（2026-11-02）

- mini：`ssh.eddiegao.fun:22022` 直连。
- MBP：没有公网入口，走手机 → mini 公网 → `127.0.0.1:22222` → MBP sshd。隧道由 MBP 的 LaunchAgent `work.eddie.herdr-mbp-tunnel` 维持（源文件 `backend/herdr_push/work.eddie.herdr-mbp-tunnel.plist`，日志 `/tmp/herdr-mbp-tunnel.log`）。认证和主机指纹端到端校验到 MBP。
- 手机钥匙权限：MBP `restrict,pty`；mini `restrict,pty,port-forwarding,permitopen="127.0.0.1:22222"`，转其他端口（如 8650）会被拒绝。
- 依赖：MBP 必须开机联网，且 `ssh mini` 通。MBP 在公司网时 `ssh mini` 走 Tailscale 中继，MBP 这条路的延迟明显高于 mini。
- 公司网下 mini 连不到 MBP 的 Tailscale 地址（100.109.249.43、100.70.194.111 的 22 端口都超时），所以不能用它做跳板目标。
