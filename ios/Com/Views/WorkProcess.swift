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
                     status: ["completed": "done", "in_progress": "doing", "blocked": "blocked", "skipped": "skipped"][t["status"].string] ?? "todo",
                     startedAt: t["started_at"].double, doneAt: t["done_at"].double)
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
    @State private var open: Bool
    init(process: WorkProcess, extra: [JSON] = []) {
        self.process = process
        self.extra = extra
        // 10-28：有 todo 清单时，思考执行中直接把时间轴摊开（外显），做完再折起
        _open = State(initialValue: process.live && process.plan != nil)
    }
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
                        TodoTimeline(steps: plan.steps, groups: process.groups, live: process.live)
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
        .onChange(of: process.plan != nil) { _, has in
            if has && process.live { withAnimation(reduce ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { open = true } }
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

// MARK: - todo 时间轴

/// 10-28 改版（参考 x.com/shedsgns「Agent work components」）：竖线串起每一步；
/// 做完 = 实心青柠勾 + 用时，正在做 = 浅底圆 + 中心点 + 外圈一段弧在转、「进行中」有高光扫过，它下面弯出这一步动用的工具（小点，一段亮光沿线往下流），
/// 没轮到 = 空心圈，没走通 = 警示色胶囊。
struct TodoTimeline: View {
    let steps: [TodoStep]
    var groups: [WorkGroup] = []
    var live = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    static let column: CGFloat = 22
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let last = index == steps.count - 1
                let doing = live && step.status == "doing"
                // 这一步到下一步之间那段线：走过了就是青柠色
                let lit = step.status == "done" && !last && steps[index + 1].status != "todo"
                let subs = doing ? substeps(for: step) : []
                VStack(alignment: .leading, spacing: 0) {
                    row(step, doing: doing)
                    if !subs.isEmpty {
                        SubstepBranch(groups: subs)
                    } else if !last {
                        Color.clear.frame(height: 8)
                    }
                }
                .background(alignment: .topLeading) {
                    if !last && subs.isEmpty {  // 有分支时由分支线接到下一步
                        Rectangle().fill(lit ? Palette.accent : Palette.separator)
                            .frame(width: 1.5).padding(.top, 19).padding(.bottom, -3)
                            .offset(x: Self.column / 2 - 0.75)
                    }
                }
                .animation(reduce ? nil : .smooth(duration: 0.3), value: step.status)
            }
        }
        .padding(.vertical, Space.md).padding(.horizontal, Space.md)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("todo-timeline")
    }

    private func row(_ step: TodoStep, doing: Bool) -> some View {
        HStack(spacing: Space.sm) {
            TimelineNode(status: step.status, live: live).frame(width: Self.column, height: 22)
            Text(step.text)
                .font(TypeScale.subheadline.weight(doing ? .medium : .regular))
                .foregroundStyle(doing ? Palette.textPrimary : step.status == "todo" ? Palette.textTertiary : Palette.textSecondary)
                .strikethrough(step.status == "skipped")
                .lineLimit(1)
            Spacer(minLength: Space.sm)
            trailing(step, doing: doing)
        }
    }

    @ViewBuilder private func trailing(_ step: TodoStep, doing: Bool) -> some View {
        if doing {
            ShimmerText(text: "进行中", font: TypeScale.footnote.weight(.medium), color: Palette.info)
        } else if step.status == "blocked" {
            Text("没走通").font(TypeScale.caption).foregroundStyle(Palette.warning)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Palette.warning.opacity(0.14), in: Capsule())
        } else if step.status == "done", step.startedAt > 0, step.doneAt > step.startedAt {
            Text(Self.short(step.doneAt - step.startedAt)).font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.textTertiary)
        }
    }

    /// 正在做的这一步下面挂它动用过的工具：从这一步开始之后的组，最多 3 组。
    private func substeps(for step: TodoStep) -> [WorkGroup] {
        let since = step.startedAt > 0 ? step.startedAt - 0.5 : 0
        return Array(groups.filter { ($0.steps.first?.startedAt ?? 0) >= since }.suffix(3))
    }

    static func short(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        return s < 60 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒"
    }
}

private struct TimelineNode: View {
    let status: String
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        ZStack {
            switch status {
            case "done":
                Circle().fill(Palette.accent).frame(width: 17, height: 17)
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Palette.onAccent)
            case "doing" where live:
                // 参考视频：浅底盘 + 实心中心点 + 外圈约 1/4 圈的弧，0.85 秒转一圈
                Circle().fill(Palette.accent.opacity(0.32)).frame(width: 18, height: 18)
                Circle().strokeBorder(Palette.accentText.opacity(0.18), lineWidth: 1.8).frame(width: 18, height: 18)
                Circle().fill(Palette.accentText).frame(width: 7, height: 7)
                TimelineView(.animation(paused: reduce)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.85) / 0.85
                    Circle().inset(by: 0.9).trim(from: 0, to: 0.28)
                        .stroke(Palette.accentText, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(reduce ? -90 : turn * 360 - 90))
                }
            case "doing":
                Image(systemName: "circle.dotted").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.textTertiary)
            case "blocked":
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 17)).foregroundStyle(Palette.warning)
            case "skipped":
                Image(systemName: "minus.circle").font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.textTertiary)
            default:
                Circle().fill(Palette.surface).frame(width: 15, height: 15)
                    .overlay(Circle().strokeBorder(Palette.separator, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 文字上一道高光从左扫到右（1.3 秒扫完，停 0.5 秒再来），参考视频里「Writing」的效果。
struct ShimmerText: View {
    let text: String
    let font: Font
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let label = Text(text).font(font)
        label.foregroundStyle(color)
            .overlay {
                if !reduce {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.3
                        GeometryReader { geo in
                            let band = max(18, geo.size.width * 0.7)
                            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.7), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + min(1, t) * (geo.size.width + band * 2))
                        }
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
            }
    }
}

/// 进行中那一步的分支：从圆环弯出去一条细线，挂着工具小点；一段青柠亮光沿线往下流。
private struct SubstepBranch: View {
    let groups: [WorkGroup]
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var flow: CGFloat = 0
    private static let rowHeight: CGFloat = 24
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                HStack(spacing: Space.sm) {
                    Circle().fill(group.running ? Palette.accentText : Palette.textTertiary.opacity(0.6))
                        .frame(width: group.running ? 5 : 4, height: group.running ? 5 : 4)
                        .frame(width: TodoTimeline.column, alignment: .trailing).padding(.trailing, 1)
                    Text(group.running ? group.liveText : group.doneText)
                        .font(TypeScale.footnote).foregroundStyle(group.running ? Palette.textSecondary : Palette.textTertiary)
                        .lineLimit(1).contentTransition(.opacity)
                }
                .frame(height: Self.rowHeight)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(.vertical, 4)
        .background(alignment: .topLeading) {
            GeometryReader { geo in
                let path = Branch(x0: TodoTimeline.column / 2, x1: TodoTimeline.column - 3.5)
                ZStack {
                    path.stroke(Palette.separator, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    if !reduce {
                        path.trim(from: flow, to: min(1, flow + 0.16))
                            .stroke(Palette.accentText, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                }
                .frame(width: TodoTimeline.column, height: geo.size.height + 8)
                .offset(y: -3)
            }
        }
        .animation(reduce ? nil : .smooth(duration: 0.3), value: groups.map(\.id))
        .onAppear {
            guard !reduce else { return }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { flow = 0.84 }
        }
    }
}

/// 主线 x0 → 弯到 x1 竖直往下 → 弯回 x0 接下一步的节点。
private struct Branch: Shape {
    let x0: CGFloat
    let x1: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let bend: CGFloat = 12
        p.move(to: CGPoint(x: x0, y: 0))
        p.addCurve(to: CGPoint(x: x1, y: bend), control1: CGPoint(x: x0, y: bend * 0.6), control2: CGPoint(x: x1, y: bend * 0.4))
        p.addLine(to: CGPoint(x: x1, y: rect.height - bend))
        p.addCurve(to: CGPoint(x: x0, y: rect.height), control1: CGPoint(x: x1, y: rect.height - bend * 0.4), control2: CGPoint(x: x0, y: rect.height - bend * 0.6))
        return p
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
