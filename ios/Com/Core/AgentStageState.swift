import Foundation

public enum AgentStageState: String, Sendable {
    case idle, thinking, working, review, delivered, failed, offline, searching, writing, remembering, calendar, handoff, waiting
    public var title: String {
        switch self {
        case .searching: "正在翻找相关资料…"
        case .writing: "正在把这件事整理好…"
        case .remembering: "正在想之前记下的事…"
        case .calendar: "正在看你的日程…"
        case .handoff: "正在请帮手接着处理…"
        case .waiting: "还在等待新进展，暂时停一下"
        case .idle: "在这儿，随时叫我"
        case .thinking: "正在想怎么帮你办"
        case .working: "正在处理这件事"
        case .review: "这一步需要你确认"
        case .delivered: "整理好了，给你放在这边"
        case .failed: "遇到了问题，查看消息里的说明"
        case .offline: "连接断了，进度稍后再说"
        }
    }
    public var symbol: String {
        switch self {
        case .searching: "magnifyingglass"
        case .writing: "pencil"
        case .remembering: "book.closed"
        case .calendar: "calendar"
        case .handoff: "paperplane"
        case .waiting: "pause.circle"
        case .idle: "moon.zzz"
        case .thinking: "ellipsis.bubble"
        case .working: "keyboard"
        case .review: "hand.raised"
        case .delivered: "text.bubble"
        case .failed: "exclamationmark.bubble"
        case .offline: "wifi.slash"
        }
    }
    public var isBusy: Bool { [.thinking, .working, .searching, .writing, .remembering, .calendar, .handoff].contains(self) }
    public static func resolve(runs: [JSON], tasks: [JSON], messages: [JSON], connected: Bool) -> Self {
        if tasks.contains(where: { ["approval_required", "awaiting_review"].contains($0["status"].string) }) { return .review }
        guard connected else { return .offline }
        if let run = runs.first(where: { ["queued", "sending", "running"].contains($0["status"].string) }) {
            return run["phase"].string == "executing" ? .working : .thinking
        }
        if tasks.contains(where: { ["running", "dispatching"].contains($0["status"].string) }) { return .working }
        if let last = messages.last {
            if ["failed", "unknown", "uncertain"].contains(last["status"].string) { return .failed }
            if last["role"].string == "assistant" && last["status"].string == "completed" { return .delivered }
        }
        return .idle
    }
}

public enum AgentCopy {
    public static func event(_ event: JSON) -> String {
        if !event["display_text"].string.isEmpty { return event["display_text"].string }
        let kind = event["kind"].string.isEmpty ? event["type"].string : event["kind"].string
        let status = event["status"].string
        if kind.hasSuffix(".failed") || status == "failed" { return "这一步遇到了问题，查看详情" }
        if ["unknown", "uncertain"].contains(status) { return "结果还在核实" }
        if ["approval_required", "awaiting_review", "task.review"].contains(kind) || ["approval_required", "awaiting_review"].contains(status) { return "这一步需要你确认" }
        if kind.hasSuffix(".completed") || ["completed", "done", "execution_finished"].contains(status) { return "这一步已结束，可查看记录" }
        if kind.contains("cancel") || status == "cancelled" { return "正在停止或已停止，查看记录" }
        return "正在处理，请稍候"
    }
}
