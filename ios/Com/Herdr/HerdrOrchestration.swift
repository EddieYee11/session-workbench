import AgentCore
import HerdrKit
import SwiftUI

/// 手机能派的 agent。名字就是 herdr `agent.start --kind` 的取值。
enum HerdrAgentKind: String, CaseIterable, Identifiable {
    case pi, agy, cursor, claude, codex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pi: "pi"
        case .agy: "agy"
        case .cursor: "Cursor"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
    /// 一句话说明它适合什么，和全局 CLAUDE.md 里的派活分工一致。
    var hint: String {
        switch self {
        case .pi: "整理、盘点、批量活，最便宜"
        case .agy: "口播稿、文案等写作"
        case .cursor: "第二意见、多文件代码活"
        case .claude: "要判断的活、读写代码"
        case .codex: "工程执行、补测试"
        }
    }
}

/// 在完整 herdr / 终端里新建 Tab 的预设类型（对齐 Mac 端快捷键脚本与日常工作流）。
enum HerdrNewTabPreset: String, CaseIterable, Identifiable {
    case terminal
    case agy
    case claudeCode
    case pi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: "普通终端"
        case .agy: "Agy"
        case .claudeCode: "Claude Code"
        case .pi: "Pi"
        }
    }

    var tabLabel: String {
        switch self {
        case .terminal: "zsh"
        case .agy: "agy"
        case .claudeCode: "claude x"
        case .pi: "pi"
        }
    }

    var command: String? {
        switch self {
        case .terminal: nil
        case .agy: "agy"
        case .claudeCode: "claude x"
        case .pi: "pi"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .agy: "sparkle"
        case .claudeCode: "cpu"
        case .pi: "circle.grid.cross"
        }
    }
}

struct HerdrDispatchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func herdrStatusLabel(_ status: HerdrAgentStatus?) -> String {
    switch status {
    case .working: "在跑"
    case .blocked: "等你"
    case .done: "完成"
    case .error: "出错"
    case .idle: "空闲"
    default: "—"
    }
}

func herdrStatusColor(_ status: HerdrAgentStatus?) -> Color {
    switch status {
    case .working: Palette.info
    case .blocked: Palette.warning
    case .done: Palette.success
    case .error: Palette.danger
    default: Palette.textTertiary
    }
}

/// agent 图标：有官方图标的（Claude / Codex / pi / Hermes）复用 Com 工作页的 AgentAvatar（单色蒙版 + 品牌色 + 浅底圆）；
/// 没有素材的（agy=Gemini、Cursor）先用品牌色符号顶上，别拿别家的图标冒充。
struct HerdrAgentIcon: View {
    let agent: String?
    var size: CGFloat = 30
    var body: some View {
        let key = (agent ?? "").lowercased()
        if agentBrand(key) != nil {
            AgentAvatar(agent: key, size: size)
        } else {
            let (symbol, ink): (String, Color) = switch key {
            case "agy", "gemini": ("sparkle", Color(red: 0.31, green: 0.52, blue: 0.96))
            case "cursor": ("cube.fill", Color(white: 0.85))
            case "", "shell": ("terminal", Color(white: 0.8))
            default: ("cpu", Color(white: 0.8))
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(ink)
                .frame(width: size, height: size)
                .background(ink.opacity(0.16), in: .circle)
        }
    }
}

struct HerdrCounts: Equatable {
    var working = 0, blocked = 0, done = 0, error = 0
}

extension HerdrSessionStore {
    /// 跑着 agent 的 pane（有 agent 名）。
    var agentPanes: [HerdrPane] {
        (snapshot?.panes ?? []).filter { ($0.agent ?? "").isEmpty == false }
    }

    var counts: HerdrCounts {
        var c = HerdrCounts()
        for pane in agentPanes {
            switch pane.agentStatus {
            case .working: c.working += 1
            case .blocked: c.blocked += 1
            case .done: c.done += 1
            case .error: c.error += 1
            default: break
            }
        }
        return c
    }

    /// 顶栏 StripFigure 角色状态映射：
    /// blocked (等你) -> .ask, working (在跑) -> .exec, done (完成) -> .done, broken (断线/异常) -> .broken, idle (空闲) -> .idle
    var stripState: StripState {
        switch phase {
        case .failed, .hostKeyChanged, .needsAuthorization:
            return .broken
        case .idle:
            return .idle
        case .connecting:
            return .idle
        case .connected:
            let c = counts
            if c.blocked > 0 {
                return .ask
            } else if c.working > 0 {
                return .exec
            } else if c.error > 0 {
                return .broken
            } else if c.done > 0 {
                return .done
            } else {
                return .idle
            }
        }
    }

    /// 往 pane 里按键。herdr 的键名：`enter` `esc` `C-c` 等（见 `herdr pane send-keys --help`）。
    func sendKeys(paneId: String, keys: [String]) async -> String? {
        guard let client else { return "还没连上 herdr。" }
        do { _ = try await client.sendKeys(paneId: paneId, keys: keys); return nil } catch { return "\(error)" }
    }

    /// 读 pane 最后几行，不开 PTY 就能看 agent 卡在哪。
    func tail(paneId: String, lines: Int = 24) async -> String {
        guard let client else { return "" }
        return (try? await client.readPane(paneId, lines: lines)) ?? ""
    }

    /// 追问正在跑的 agent。HerdrKit 自带的 `prompt` 参数名是 pane_id，但 herdr 要的是 target，这里直接发。
    func ask(paneId: String, text: String) async -> String? {
        guard let client else { return "还没连上 herdr。" }
        do {
            _ = try await client.request("agent.prompt", ["target": .string(paneId), "text": .string(text)])
            await refresh()
            return nil
        } catch { return "\(error)" }
    }

    /// 新开一个 tab → 在里面启动 agent → 投任务。返回新 pane 的 id。和 `herdr_dispatch.sh` 同一条链路，只是不等结果。
    func dispatch(kind: HerdrAgentKind, label: String, task: String, cwd: String?) async throws -> String {
        guard let client else { throw HerdrDispatchError(message: "还没连上 herdr。") }
        var params: [String: JSONValue] = ["label": .string(label), "focus": .bool(false)]
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        let tab = try await client.request("tab.create", params)
        guard case .string(let paneId)? = tab["root_pane"]?["pane_id"] else {
            throw HerdrDispatchError(message: "herdr 没返回新 pane。")
        }
        do {
            // agent 名必须是 [a-z][a-z0-9_-]{0,31}，中文标签只给 tab 标题用。
            let agentName = "com-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            _ = try await client.request("agent.start", ["name": .string(agentName), "kind": .string(kind.rawValue), "pane_id": .string(paneId)])
            _ = try await client.request("agent.prompt", ["target": .string(paneId), "text": .string(task)])
        } catch {
            // 启动失败也留着这个 tab，让人能进去看原因，不替他关。
            await refresh()
            throw error
        }
        await refresh()
        return paneId
    }

    /// 在当前工作区新建一个 Tab（支持：普通终端、Agy、Claude Code、Pi），并自动聚焦到新 Tab。
    @discardableResult
    func openNewTab(preset: HerdrNewTabPreset, cwd: String? = nil) async throws -> String {
        guard let client else { throw HerdrDispatchError(message: "还没连上 herdr。") }
        let snap = (try? await client.snapshot()) ?? snapshot
        var params: [String: JSONValue] = [
            "label": .string(preset.tabLabel),
            "focus": .bool(true),
        ]
        if let ws = snap?.focusedWorkspaceId, !ws.isEmpty {
            params["workspace_id"] = .string(ws)
        }
        let resolvedCwd = cwd
            ?? snap?.panes.first(where: { $0.paneId == snap?.focusedPaneId })?.cwd
            ?? snap?.panes.first?.cwd
        if let resolvedCwd, !resolvedCwd.isEmpty {
            params["cwd"] = .string(resolvedCwd)
        }
        let tab = try await client.request("tab.create", params)
        guard case .string(let paneId)? = tab["root_pane"]?["pane_id"] else {
            throw HerdrDispatchError(message: "herdr 没返回新 pane。")
        }
        if let cmd = preset.command, !cmd.isEmpty {
            _ = try? await client.request("pane.send_input", [
                "pane_id": .string(paneId),
                "text": .string(cmd),
                "keys": .array([.string("enter")]),
            ])
        }
        await refresh()
        return paneId
    }

    /// 关闭当前 Tab（若指定了 paneId 则关闭该 pane 所属的 Tab，否则关闭当前聚焦的 Tab）。
    func closeCurrentTab(paneId: String? = nil) async throws {
        guard let client else { throw HerdrDispatchError(message: "还没连上 herdr。") }
        let snap = (try? await client.snapshot()) ?? snapshot
        let tabId: String? = {
            if let paneId, let match = snap?.panes.first(where: { $0.paneId == paneId }) {
                return match.tabId
            }
            return snap?.focusedTabId ?? snap?.workspaces.first(where: { $0.focused })?.activeTabId ?? snap?.tabs.first(where: { $0.focused })?.tabId
        }()
        guard let tabId, !tabId.isEmpty else {
            throw HerdrDispatchError(message: "未找到当前活动的 Tab。")
        }
        _ = try await client.request("tab.close", ["tab_id": .string(tabId)])
        await refresh()
    }
}
