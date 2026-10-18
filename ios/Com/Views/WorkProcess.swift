import SwiftUI
import ComCore

// 聊天轨道（chat）· 「工作过程」：Eddie 说完话后，助手一侧一行实时显示它在做什么；
// 10-17 起优先显示这一轮的 todo 清单（任务名 + 步骤），没有清单（闲聊）才退回工具步骤；
// 做完折成「做了 N 步 · 用时 X 秒」。顶栏人物旁的手绘气泡读同一份「当前步骤」（AppModel.workBubble）。
//
// 数据就是后端已有的工具事件：用户消息的 `tasks`（kind=tool，tool / status / started_at / finished_at），
// 由 conversation.py 在 tool.started / tool.completed 时写入并随 SSE update 推来。
// 文案和 backend/event_copy.py 的 STEP_COPY 是同一张表：同类连续步骤合并，每类多个说法轮换。

enum StepKind: String, CaseIterable, Sendable {
    case search, read, web, shell, edit, recall, remember, ledger, money, calendar, remind, task, check, device, overview, mail, other

    /// 工具名 → 类别。先精确后包含；未知工具一律「other」，不把内部名字露给用户。
    static func of(_ tool: String) -> StepKind? {
        let name = tool.lowercased().split(separator: "__").last.map(String.init) ?? tool.lowercased()
        if ["react_to_user_message", "react", "think"].contains(name) { return nil }
        let table: [(StepKind, [String])] = [
            (.ledger, ["bookkeeping_search", "finance", "ledger", "expense_search"]),
            (.money, ["bookkeeping", "expense", "business_operation"]),
            (.remember, ["memory_save", "memory_write", "memory_update", "retain", "remember"]),
            (.recall, ["memory_recall", "memory_read", "memory_search", "recall", "memory"]),
            (.remind, ["remind", "reminder", "alarm"]),
            (.calendar, ["calendar", "schedule", "event"]),
            (.check, ["task_status", "get_task", "work_proposal_status", "recent_work_sessions", "list_tasks"]),
            (.task, ["task_submit", "create_task", "propose_work", "task_send", "update_task", "cancel_task", "dispatch"]),
            (.overview, ["personal_overview", "personal_briefing", "briefing", "overview"]),
            (.mail, ["gmail", "mail", "email"]),
            (.device, ["device_call", "health", "contacts", "device"]),
            (.web, ["web_search", "web_extract", "websearch", "webfetch", "browser", "fetch", "http", "url"]),
            (.edit, ["edit", "write", "patch", "file_write", "write_file", "apply_patch", "multiedit"]),
            (.search, ["grep", "find", "glob", "ls", "search_files", "search", "rg"]),
            (.read, ["read", "read_file", "context_read", "cat", "view", "open"]),
            (.shell, ["bash", "terminal", "shell", "exec", "run_command", "command", "process"]),
        ]
        if let hit = table.first(where: { $0.1.contains(name) }) { return hit.0 }
        if let hit = table.first(where: { $0.1.contains { name.contains($0) && $0.count > 3 } }) { return hit.0 }
        return .other
    }

    /// 正在做时的说法，按步骤轮换。
    var live: [String] {
        switch self {
        case .search: ["正在翻资料", "在资料堆里找线索", "四处翻翻看"]
        case .read: ["正在读文件", "打开文件细看", "逐行过一遍"]
        case .web: ["上网查一查", "正在搜网页", "去网上找答案"]
        case .shell: ["在电脑上跑命令", "敲几行命令", "让电脑动起来"]
        case .edit: ["正在改文件", "动笔修改", "把改动写进去"]
        case .recall: ["翻翻记忆", "想想你说过的", "回忆一下"]
        case .remember: ["记到小本本上", "把这件事记下", "写进记忆里"]
        case .ledger: ["翻账本", "查查花销", "对一下账"]
        case .money: ["正在记账", "记上一笔", "拨拉算盘"]
        case .calendar: ["看看日程", "翻一下日历", "对一下时间"]
        case .remind: ["定个提醒", "帮你记着时间", "设一个闹钟"]
        case .task: ["派活给电脑", "找帮手接手", "安排任务"]
        case .check: ["看看进度", "问问帮手做到哪了", "核对进展"]
        case .device: ["问问你的手机", "在手机上查", "用一下手机"]
        case .overview: ["扫一眼今天", "看看总览", "翻今天的摘要"]
        case .mail: ["翻邮件", "看看信箱", "拆封邮件"]
        case .other: ["动手处理", "在忙这一步", "处理一下"]
        }
    }
    /// 做完 n 次的合并说法。
    func done(_ n: Int) -> String {
        let count = n == 1 ? "一" : " \(n) "
        switch self {
        case .search: return "翻了\(count)处资料"
        case .read: return "读了\(count)个文件"
        case .web: return "查了\(count)个网页"
        case .shell: return "跑了\(count)条命令"
        case .edit: return "改了\(count)处文件"
        case .recall: return n == 1 ? "翻了翻记忆" : "翻了 \(n) 次记忆"
        case .remember: return "记下了\(count)件事"
        case .ledger: return n == 1 ? "查了账本" : "查了 \(n) 次账本"
        case .money: return "记了\(count)笔账"
        case .calendar: return n == 1 ? "看了日程" : "看了 \(n) 次日程"
        case .remind: return "定了\(count)个提醒"
        case .task: return "派了\(count)件活"
        case .check: return n == 1 ? "核对了进度" : "核对了 \(n) 次进度"
        case .device: return n == 1 ? "用了手机" : "用了 \(n) 次手机"
        case .overview: return "看了总览"
        case .mail: return n == 1 ? "翻了邮箱" : "翻了 \(n) 次邮箱"
        case .other: return "做了\(count)件事"
        }
    }
    var symbol: String {
        switch self {
        case .search: "doc.text.magnifyingglass"
        case .read: "doc.text"
        case .web: "globe"
        case .shell: "terminal"
        case .edit: "pencil"
        case .recall, .remember: "book.closed"
        case .ledger, .money: "yensign.circle"
        case .calendar: "calendar"
        case .remind: "bell"
        case .task: "paperplane"
        case .check: "checklist"
        case .device: "iphone"
        case .overview: "sun.max"
        case .mail: "envelope"
        case .other: "sparkles"
        }
    }
}

struct WorkStep: Equatable, Sendable {
    let id: String
    let tool: String
    let kind: StepKind
    let status: String
    let startedAt: Double
    let finishedAt: Double
    var running: Bool { status == "running" }
    var failed: Bool { status == "failed" }
}

/// 同类连续步骤合并成一组。
struct WorkGroup: Identifiable, Equatable, Sendable {
    let kind: StepKind
    var steps: [WorkStep]
    var id: String { steps.first?.id ?? kind.rawValue }
    var running: Bool { steps.contains(where: \.running) }
    var failures: Int { steps.filter(\.failed).count }
    /// 稳定的轮换序号：同一步永远同一个说法，不同步之间换着说。
    var seed: Int { id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } }
    var liveText: String {
        steps.count > 1 ? kind.done(steps.count) + "…" : kind.live[seed % kind.live.count]
    }
    var doneText: String {
        failures > 0 ? kind.done(steps.count) + " · \(failures) 步没走通" : kind.done(steps.count)
    }
    /// 详情里那行小字：原始工具名和次数，例如「grep ×4 · find ×2」。
    var detail: String {
        var order: [String] = [], counts: [String: Int] = [:]
        for step in steps {
            let name = step.tool.split(separator: "__").last.map(String.init) ?? step.tool
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }.joined(separator: " · ")
    }
}

/// 10-17：这一轮的 todo 清单（后端 turn_planner / Hermes turn_plan 写在用户消息 tasks 里 kind=plan）。有它就替代工具日志当思考过程。
struct TurnPlan: Equatable, Sendable {
    let title: String
    let steps: [TodoStep]
    let active: String
    var done: Int { steps.filter { $0.status == "done" }.count }
    static func from(_ entry: JSON) -> TurnPlan? {
        let todos = entry["todos"].array
        guard !todos.isEmpty else { return nil }
        let steps = todos.map { t in
            TodoStep(id: t["id"].string, text: t["content"].string,
                     status: ["completed": "done", "in_progress": "doing", "blocked": "blocked", "skipped": "skipped"][t["status"].string] ?? "todo")
        }
        let active = todos.first { $0["status"].string == "in_progress" }?["active"].string ?? ""
        return TurnPlan(title: entry["title"].string, steps: steps, active: active)
    }
}

struct WorkProcess: Equatable, Sendable {
    let groups: [WorkGroup]
    let live: Bool
    let phase: String
    let startedAt: Double
    let finishedAt: Double
    let durationMS: Double
    let seed: Int
    var plan: TurnPlan? = nil
    var messageID = ""
    var stepCount: Int { groups.reduce(0) { $0 + $1.steps.count } }
    /// 3 步以上的轮次进了航程列表，可以回看。
    var isCase: Bool { (plan?.steps.count ?? 0) >= 3 }

    /// 「当前步骤」：顶栏气泡和流里那一行共用。
    var current: String {
        if let plan, live, !plan.active.isEmpty { return plan.active }
        if let group = groups.last, group.running { return group.liveText }
        if phase == "responding" || phase == "speaking" { return ["在组织回复", "开始写回复", "把结果理一理"][seed % 3] }
        if groups.isEmpty { return ["在想怎么办", "先理一理思路", "琢磨一下"][seed % 3] }
        return ["想想下一步", "接着往下做", "看看还缺什么"][(seed + groups.count) % 3]
    }
    var summary: String {
        let seconds = durationMS > 0 ? durationMS / 1000 : max(0, finishedAt - startedAt)
        if let plan { return (plan.title.isEmpty ? "" : plan.title + " · ") + "\(plan.done)/\(plan.steps.count) 步 · " + Self.duration(seconds) }
        return "做了 \(stepCount) 步 · 用时 " + Self.duration(seconds)
    }
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 1 { return "不到 1 秒" }
        if s < 60 { return "\(s) 秒" }
        return s % 60 == 0 ? "\(s / 60) 分钟" : "\(s / 60) 分 \(s % 60) 秒"
    }

    static let activeStatuses: Set<String> = ["queued", "sending", "running"]

    /// 从一条用户消息读出工作过程。没在跑、也没调用过工具的消息返回 nil（留白）。
    static func from(_ message: JSON) -> WorkProcess? {
        guard message["role"].string == "user" else { return nil }
        let live = activeStatuses.contains(message["status"].string)
        let steps: [WorkStep] = message["tasks"].array.compactMap { task in
            guard task["kind"].string == "tool" || task.id.hasPrefix("tool-") else { return nil }
            guard let kind = StepKind.of(task["tool"].string) else { return nil }
            return WorkStep(id: task.id, tool: task["tool"].string, kind: kind, status: task["status"].string,
                            startedAt: task["started_at"].double, finishedAt: task["finished_at"].double)
        }
        let plan = message["tasks"].array.first { $0["kind"].string == "plan" }.flatMap(TurnPlan.from)
        guard live || !steps.isEmpty || plan != nil else { return nil }
        var groups: [WorkGroup] = []
        for step in steps {
            if let last = groups.last, last.kind == step.kind { groups[groups.count - 1].steps.append(step) }
            else { groups.append(WorkGroup(kind: step.kind, steps: [step])) }
        }
        let start = message["received_at"].double > 0 ? message["received_at"].double : message["created_at"].double
        let end = steps.map(\.finishedAt).max() ?? 0
        return WorkProcess(groups: groups, live: live, phase: message["phase"].string,
                           startedAt: start, finishedAt: max(end, start), durationMS: message["summary"]["duration_ms"].double,
                           seed: message.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF },
                           plan: plan, messageID: message.id)
    }
}

// MARK: - 流里的一行

/// 助手一侧：在跑时一行实时步骤（点开看全部）；做完折成「做了 N 步 · 用时 X 秒」，可再点开。
struct WorkProcessRow: View {
    let process: WorkProcess
    /// 后台派活的事件（不是主对话的工具调用），展开时附在后面。
    var extra: [JSON] = []
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.selection()
                withAnimation(reduce ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { open.toggle() }
            } label: { header }
                .buttonStyle(.plain)
                .accessibilityIdentifier(process.live ? "work-process-live" : "work-process-summary")
                .accessibilityHint(open ? "收起步骤" : "展开全部步骤")
            if open {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if let plan = process.plan {
                        // todo 清单就是思考过程：每步在干嘛一目了然；工具细节不再露出来
                        TodoChecklist(steps: plan.steps, live: process.live)
                        if process.stepCount > 0 {
                            Text("动用了 \(process.stepCount) 次工具").font(.caption2).foregroundStyle(Palette.textTertiary).padding(.leading, 26)
                        }
                        if process.isCase {
                            Button { model.presentedCase = "turn:" + process.messageID } label: {
                                Label("在航程里回看", systemImage: "rectangle.stack").font(TypeScale.footnote.weight(.medium))
                            }
                            .buttonStyle(.plain).foregroundStyle(Palette.accentText).padding(.leading, 26).padding(.top, 2)
                            .accessibilityIdentifier("work-process-case")
                        }
                    } else {
                        ForEach(Array(process.groups.enumerated()), id: \.element.id) { index, group in
                            StepLine(group: group, live: process.live && index == process.groups.count - 1 && group.running)
                        }
                        if process.groups.isEmpty { Text("还没动用工具，先在想。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) }
                    }
                    ForEach(Array(extra.suffix(8).enumerated()), id: \.offset) { index, event in
                        StepRow(text: eventLabel(event), state: index < min(8, extra.count) - 1 ? .done : stepState(event), time: clockTime(event["at"].double))
                    }
                }
                .padding(.leading, 6).padding(.top, Space.sm).padding(.bottom, Space.xs)
                .transition(.opacity.combined(with: .offset(y: -4)))
                .accessibilityIdentifier("work-process-steps")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xs)
        // 做完自动折成一行；想看再点开。
        .onChange(of: process.live) { _, live in
            if !live { withAnimation(reduce ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { open = false } }
        }
    }
    @ViewBuilder private var header: some View {
        HStack(spacing: Space.sm) {
            if process.live {
                WorkPulse()
                if let plan = process.plan, !plan.title.isEmpty {
                    Text(plan.title).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary).lineLimit(1).layoutPriority(1)
                    Text("\(plan.done)/\(plan.steps.count)").font(.caption2.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                }
                Text(process.current)
                    .font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textPrimary)
                    .contentTransition(.opacity)
                    .animation(reduce ? nil : .smooth(duration: 0.3), value: process.current)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = process.startedAt > 0 ? context.date.timeIntervalSince1970 - process.startedAt : 0
                    if elapsed >= 3 && elapsed < 3600 {
                        Text(WorkProcess.duration(elapsed)).font(TypeScale.footnote).monospacedDigit().foregroundStyle(Palette.textTertiary)
                    }
                }
            } else {
                Image(systemName: process.isCase ? "rectangle.stack" : "checkmark.circle").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                Text(process.summary).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
    }
}

/// 展开后的一组：图标 + 合并说法 + 耗时（10-17 起不再露出原始工具名）。
private struct StepLine: View {
    let group: WorkGroup
    let live: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: group.kind.symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(live ? Palette.accentText : group.failures > 0 ? Palette.warning : Palette.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(live ? group.liveText : group.doneText).font(TypeScale.footnote.weight(live ? .semibold : .regular))
                    .foregroundStyle(group.failures > 0 ? Palette.warning : live ? Palette.textPrimary : Palette.textSecondary)
            }
            Spacer(minLength: 0)
            if let seconds = duration { Text(seconds).font(.caption2).monospacedDigit().foregroundStyle(Palette.textTertiary) }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
    private var duration: String? {
        guard !live, let start = group.steps.first?.startedAt, let end = group.steps.map(\.finishedAt).max(), start > 0, end > start else { return nil }
        return WorkProcess.duration(end - start)
    }
}

/// 一个会呼吸的小青柠点，取代转圈。
struct WorkPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(Palette.accent.opacity(0.45)).frame(width: 14, height: 14).scaleEffect(on ? 1 : 0.5).opacity(on ? 0 : 0.9)
            Circle().fill(Palette.accentText).frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
        .onAppear { guard !reduce else { return }; withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { on = true } }
        .accessibilityHidden(true)
    }
}
