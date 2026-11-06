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
}
