import SwiftUI
import ComCore

// 等 Eddie 拍板的事：统一成 PendingItem，在办页、Dock 徽标、顶栏角色都从这一份取数。
// 只收「派活待批准」和「停下来等你的任务」；邮件、日程这类主动建议归「下一步」页（NextView）。
// 数据全部来自现有接口（agency / proposals / tasks / connectors / finance），没有第二份账。

/// 一件等 Eddie 决定的事，不管它来自哪个后端表。
struct PendingItem: Identifiable, Equatable {
    enum Kind: Equatable { case proposal, task, matter, goal, project }
    let id: String
    let kind: Kind
    let value: JSON
    let title: String
    let detail: String
    let draft: String
    let source: String
    let symbol: String
    let stamp: String
    let tone: Tone
    let time: Double
    let primary: String
    var meta: String { [source, relativeTime(time), draft.isEmpty ? "" : "已写好下一步"].filter { !$0.isEmpty }.joined(separator: " · ") }
    /// 每一种都能左划：任务归档、派活先别、事项划掉（留到明天）。
    var dismissLabel: String {
        switch kind { case .task: "归档"; case .proposal: "先别"; case .goal: "暂停"; default: "划掉" }
    }
    /// 「全部稍后」只收事项、目标和项目；任务和派活要你亲自拍板。
    var canDismiss: Bool { kind == .matter || kind == .goal || kind == .project }
    var staysAfterPrimary: Bool { kind == .task }
    var group: String { kind == .matter ? source : id }
    /// 超过 7 天没动静的任务：多半已经不作数了，折叠起来一键归档。
    var stale: Bool { kind == .task && time > 0 && Date().timeIntervalSince1970 - time > 7 * 86400 }
}

extension AppModel {
    static let flowPaths: Set<String> = ["/personal/agency", "/personal/work/proposals?limit=20", "/personal/tasks", "/personal/connectors"]

    var proposals: [JSON] {
        let data = datasets["/personal/work/proposals?limit=20"]
        return (data?["items"].array ?? data?["proposals"].array ?? []).filter { ["proposed", "pending", "approval_required"].contains($0["status"].string) }
    }
    var tasks: [JSON] { datasets["/personal/tasks"]?["items"].array ?? [] }
    var agencyCards: [JSON] { datasets["/personal/agency"]?["cards"].array.filter { !["context", "finance"].contains($0["kind"].string) } ?? [] }
    var goals: [JSON] { datasets["/personal/agency"]?["goals"].array.filter { ["active", "blocked", "waiting_acceptance"].contains($0["status"].string) } ?? [] }
    /// 需要 Eddie 回应的任务：等你回应 / 等待批准 / 待验收 / 结果未知。
    var decisionTasks: [JSON] {
        // 手动会话（interactive）每轮都会「执行完」，那是聊天回合，不是等你验收的交付，不进清单。
        tasks.filter { !$0["interactive"].bool && (["waiting", "approval_required", "unknown", "paused"].contains($0["status"].string) || ($0["status"].string == "execution_finished" && !$0["acceptance_passed"].bool)) }
    }
    var runningTasks: [JSON] { tasks.filter { ["queued", "dispatching", "running", "cancel_requested"].contains($0["status"].string) } }
    /// 要你拍板的：派活 + 任务（不含折叠起来的旧任务）。
    var decisionCount: Int { flowItems.filter { ($0.kind == .proposal || $0.kind == .task) && !$0.stale }.count }
    var pendingCount: Int { flowItems.count }
    var pendingItems: [PendingItem] { flowItems }
    /// 一键归档的候选：超过 7 天的任务。
    var staleItems: [PendingItem] { flowItems.filter(\.stale) }
    /// 断掉的信源：只提邮件和日历；用户主动关闭的不算。
    var brokenSources: [JSON] {
        (datasets["/personal/connectors"]?["sources"].array ?? []).filter {
            ["gmail", "work_mail", "google_calendar", "apple_calendar"].contains($0["name"].string) && ["needs_connection", "unavailable"].contains($0["status"].string) && $0["enabled"] != .bool(false)
        }
    }

    func recomputeFlow() {
        var items: [PendingItem] = []
        for row in proposals {
            items.append(PendingItem(id: "proposal:" + row.id, kind: .proposal, value: row, title: row["title"].string, detail: row["prompt"].string, draft: "",
                                     source: "派活给 " + agentName(row["agent"].string.isEmpty ? "codex" : row["agent"].string), symbol: "desktopcomputer",
                                     stamp: "等待批准", tone: .warning, time: row["created_at"].double, primary: "批准"))
        }
        for row in decisionTasks.sorted(by: { $0["updated_at"].double > $1["updated_at"].double }) {
            let status = row["status"].string
            items.append(PendingItem(id: "task:" + row.id, kind: .task, value: row, title: row["title"].string, detail: row["completion_condition"].string, draft: "",
                                     source: agentName(row["agent"].string), symbol: "checkmark.square",
                                     stamp: stampLabel(status), tone: stampTone(status), time: row["updated_at"].double, primary: status == "execution_finished" ? "验收" : "看详情"))
        }
        if items != flowItems { flowItems = items }
    }

    func pendingPrimary(_ item: PendingItem) async {
        switch item.kind {
        case .proposal: await action("/personal/work/proposals/" + item.value.id.pathEncoded + "/approve", fields: ["explicit_authorization": .bool(true)], refresh: .doing)
        case .task: selectedTask = item.value
        case .matter: await pendingDiscuss(item)
        case .goal: tab = .doing
        case .project: tab = .work
        }
    }
    func pendingDiscuss(_ item: PendingItem) async {
        guard item.kind == .matter || item.kind == .goal || item.kind == .project else { selectedTask = item.kind == .task ? item.value : nil; return }
        do { _ = try await agencyAction(item.value, action: "discuss"); tab = .chat; Haptics.success() }
        catch { banner = error.localizedDescription }
    }
    /// 左划：任务归档、派活先别、目标暂停、事项留到明天再提（24 小时）。
    func pendingDismiss(_ item: PendingItem) async {
        do {
            switch item.kind {
            case .task: try await dismissTask(item.value)
            case .proposal: await action("/personal/work/proposals/" + item.value.id.pathEncoded + "/reject", refresh: .doing)
            case .goal: _ = try await agencyAction(item.value, action: "pause")
            default: _ = try await agencyAction(item.value, action: "later", extra: ["hours": .number(24)])
            }
            Haptics.selection()
        } catch { banner = error.localizedDescription }
    }
    /// 归档一项不再作数的任务：后端记一笔「在手机上归档」，不碰工作器，之后在「已结束」里还能恢复。
    func dismissTask(_ task: JSON) async throws {
        #if DEBUG
        if isUITesting {
            var value = datasets["/personal/tasks"] ?? .null
            value["items"] = .array(value["items"].array.map { row in guard row.id == task.id else { return row }; var copy = row; copy["status"] = .string("cancelled"); return copy })
            datasets["/personal/tasks"] = value; recomputeFlow(); return
        }
        #endif
        _ = try await mutate("/personal/tasks/" + task.id.pathEncoded + "/dismiss", fields: [:])
        _ = await load("/personal/tasks")
    }
    /// 把超过 7 天的旧任务一口气归档。
    func archiveStale() async {
        for item in staleItems { try? await dismissTask(item.value) }
        Haptics.success()
    }

    // MARK: 顶栏角色状态（真实事件驱动）

    var stripState: StripState {
        if !isPaired { return .idle }
        switch stage.state {
        case .offline: return .broken
        case .failed: return .broken
        case .review: return .ask
        case .delivered: return .done
        case .idle, .waiting:
            if decisionCount > 0 { return .ask }
            if !brokenSources.isEmpty { return .broken }
            if stage.state == .waiting { return .think }
            return .idle
        default: return stage.state.strip
        }
    }
    var stripCaption: String {
        if !isPaired { return "先连上 Mac mini" }
        switch stage.state {
        case .offline: return "正在恢复连接"
        case .failed: return "遇到了问题，看流里的说明"
        case .delivered: return "已送达，在下面"
        case .review: return "这一步等你点头"
        case .idle, .waiting:
            if decisionCount > 0 { return "\(decisionCount) 件等你点头" }
            if let broken = brokenSources.first { return "读不到 " + sourceName(broken["name"].string) + " 了" }
            if stage.state == .waiting { return "还在等新进展" }
            if nextUrgentCount > 0 { return "有 \(nextUrgentCount) 件现在就该做" }
            return "在这儿，随时叫我"
        case .searching: return "在翻找相关资料"
        case .remembering: return "在想之前记下的事"
        case .calendar: return "在看你的日程"
        case .handoff: return "交给电脑上的伙伴"
        case .thinking: return "在想怎么帮你办"
        case .working, .writing: return runningTasks.isEmpty ? "正在处理这件事" : "正在处理 · \(runningTasks.count) 件在跑"
        }
    }
    var stripSign: String {
        switch stage.state {
        case .offline: return "连不上"
        case .failed: return "出错了"
        default:
            if stage.state == .review || decisionCount > 0 { return "等你点头" }
            if let broken = brokenSources.first { return broken["name"].string.contains("calendar") ? "日历断了" : "邮箱断了" }
            return ""
        }
    }
    var stripOnRight: Bool { [.ask, .send, .broken, .done].contains(stripState) }
    var stripMachine: String { runningTasks.first?["host"].string ?? "" }

    // MARK: 下拉工作台

    func openStage() {
        showMenu = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { stageProgress = 1; stageExpanded = true }
    }
    func closeStage() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { stageProgress = 0; stageExpanded = false }
    }
    /// 拖动中：跟手，拉过头有橡皮筋阻尼。
    func dragStage(to raw: CGFloat) {
        let clamped: CGFloat
        if raw < 0 { clamped = 0 }
        else if raw > 1 { clamped = 1 + (raw - 1) * 0.25 }
        else { clamped = raw }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { stageProgress = clamped }
    }
    /// 松手：按预测落点决定开合。
    func settleStage(predicted: CGFloat) {
        if predicted > 0.3 { openStage() } else { closeStage() }
    }
}

func sourceSymbol(_ source: String) -> String {
    switch source {
    case "gmail", "work_mail": "envelope"
    case "github": "chevron.left.forwardslash.chevron.right"
    case "apple_calendar", "google_calendar", "phone_calendar": "calendar"
    case "phone_health", "garmin": "heart"
    case "accounting": "creditcard"
    case "com_task": "checkmark.square"
    case "goal": "scope"
    case "project_board": "desktopcomputer"
    default: "tray"
    }
}

/// 一件等你决定的事：来源行 → 标题/摘要 → 草稿 → 操作。左划归档/划掉，右划直接做，长按聊。
struct PendingNote: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let item: PendingItem
    var tilt: Double = 0
    var completed: (String) -> Void = { _ in }
    @State private var busy = false
    @State private var offset: CGFloat = 0
    @State private var showDetail = false
    private var focus: Bool { item.kind == .proposal }
    var body: some View {
        Card(focus ? .highlighted(.accent) : .standard, padding: 0) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: item.symbol).font(.system(size: 14)).foregroundStyle(Palette.textTertiary)
                    Text([item.source, relativeTime(item.time)].filter { !$0.isEmpty }.joined(separator: " · ")).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    Spacer()
                    Stamp(text: item.stamp, tone: item.tone, dashed: item.stamp == "结果未知")
                }
                Button { showDetail = true } label: {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(item.title).font(TypeScale.headline).foregroundStyle(Palette.textPrimary).lineLimit(3)
                        if !item.detail.isEmpty && item.detail != item.title { Text(item.detail).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(item.kind == .proposal ? 4 : 2) }
                    }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }.buttonStyle(.plain)
                if !item.draft.isEmpty { LinedText(text: item.draft) }
                if item.kind == .proposal { ApprovalScopeView(action: item.value["actual_action"]).font(TypeScale.footnote) }
                actions
            }
            .padding(Space.lg)
        }
        .offset(x: offset)
        .background(alignment: offset < 0 ? .trailing : .leading) {
            if abs(offset) > 24 {
                Text(offset < 0 ? item.dismissLabel : item.primary).font(TypeScale.footnote.weight(.semibold))
                    .foregroundStyle(offset < 0 ? Palette.danger : Palette.accentText)
                    .padding(.horizontal, Space.lg)
            }
        }
        .gesture(DragGesture(minimumDistance: 24).onChanged { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
            offset = max(-110, min(110, value.translation.width * 0.6))
        }.onEnded { value in
            let width = value.translation.width
            withAnimation(reduce ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
            if width < -80 { dismiss() }
            else if width > 80 { Task { await model.pendingPrimary(item) } }
        })
        .contextMenu {
            Button("和它聊这件事", systemImage: "bubble.left") { Task { await model.pendingDiscuss(item) } }
            Button(item.dismissLabel, systemImage: item.kind == .task ? "archivebox" : "xmark") { dismiss() }
            if item.kind == .matter {
                Button("这件事已处理", systemImage: "checkmark") { act("handled", message: "已处理，停止重复提醒") }
                Button("不再关注这件事", systemImage: "bell.slash") { act("mute", message: "已停止关注这件事") }
            }
        }
        .sheet(isPresented: $showDetail) { detail }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-" + item.id)
    }
    @ViewBuilder private var actions: some View {
        HStack(spacing: Space.sm) {
            switch item.kind {
            case .proposal:
                Button("批准") { Task { await model.action("/personal/work/proposals/" + item.value.id.pathEncoded + "/approve", fields: ["explicit_authorization": .bool(true)], refresh: .doing) } }.buttonStyle(.primaryAccent).disabled(busy)
                Button("先别") { Task { await model.action("/personal/work/proposals/" + item.value.id.pathEncoded + "/reject", refresh: .doing) } }.buttonStyle(.secondaryAction).disabled(busy)
            case .task:
                Button(item.primary) { model.selectedTask = item.value }.buttonStyle(.primaryFull)
                Button("归档") { dismiss() }.buttonStyle(.secondaryAction).disabled(busy)
            case .matter:
                Button(item.draft.isEmpty ? "交给 Com" : "去聊") { Task { await model.pendingDiscuss(item) } }.buttonStyle(.primaryFull).disabled(busy).accessibilityIdentifier("pending-discuss")
                if item.value["preparation"].isNull {
                    Button(busy ? "整理中…" : "先整理资料") { prepare() }.buttonStyle(.secondaryAction).disabled(busy).accessibilityIdentifier("agency-prepare")
                } else {
                    Button("晚点") { act("later", message: "已留到稍后，届时再跟进") }.buttonStyle(.secondaryAction).disabled(busy)
                }
            case .goal:
                Button("看进展") { model.tab = .doing }.buttonStyle(.secondaryAction)
                Spacer(minLength: 0)
                Button("暂停跟进") { act("pause", message: "目标已暂停") }.buttonStyle(.quiet).disabled(busy)
            case .project:
                Button("去看") { model.tab = .work }.buttonStyle(.secondaryAction)
                Spacer(minLength: 0)
                Button("晚点") { act("later", message: "已留到稍后") }.buttonStyle(.quiet).disabled(busy)
            }
        }
    }
    @ViewBuilder private var detail: some View {
        switch item.kind {
        case .task: TaskDetailView(task: item.value)
        case .proposal: ProposalDetail(proposal: item.value)
        default: AgencyDetail(card: item.value)
        }
    }
    private func dismiss() {
        busy = true
        Task {
            await model.pendingDismiss(item)
            completed(item.kind == .task ? "已归档，在「已结束」里还能恢复" : item.kind == .proposal ? "已回绝这次派活" : "已划掉，明天前不再提")
            busy = false
        }
    }
    private func act(_ action: String, message: String) {
        busy = true
        Task {
            do { _ = try await model.agencyAction(item.value, action: action, extra: action == "later" ? ["hours": .number(24)] : [:]); completed(message); Haptics.success() }
            catch { model.banner = error.localizedDescription }
            busy = false
        }
    }
    private func prepare() {
        busy = true
        Task {
            do { _ = try await model.agencyAction(item.value, action: "prepare"); Haptics.success() }
            catch { model.banner = error.localizedDescription }
            busy = false
        }
    }
}

/// 待批准的派活：完整要求 + 操作范围。
struct ProposalDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let proposal: JSON
    var body: some View {
        DetailPage(title: "派活") {
            DetailHeader(title: proposal["title"].string, subtitle: "派给 " + agentName(proposal["agent"].string.isEmpty ? "codex" : proposal["agent"].string)) { Stamp(text: "等待批准", tone: .warning) }
            Card(.highlighted(.accent)) {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("要你决定").font(TypeScale.section)
                    RichText(text: proposal["prompt"].string)
                    ApprovalScopeView(action: proposal["actual_action"])
                    if proposal["expires_at"].double > 0 {
                        Text("请在 " + clockTime(proposal["expires_at"].double) + " 前确认；过期不会执行。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    }
                    HStack(spacing: Space.sm) {
                        Button("批准这项工作") { Task { await model.action("/personal/work/proposals/" + proposal.id.pathEncoded + "/approve", fields: ["explicit_authorization": .bool(true)], refresh: .doing); dismiss() } }.buttonStyle(.primaryAction)
                        Button("先别") { Task { await model.action("/personal/work/proposals/" + proposal.id.pathEncoded + "/reject", refresh: .doing); dismiss() } }.buttonStyle(.secondaryAction)
                    }
                }
            }.padding(.top, Space.sm)
        }
    }
}

/// 信源断了：流里一张带警示描边的卡。
struct SourceBrokenNote: View {
    @Environment(AppModel.self) private var model
    let source: JSON
    private var name: String { sourceName(source["name"].string) }
    var body: some View {
        Card(.highlighted(.danger)) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)); Text("信源断了" + (source["updated_at"].double > 0 ? " · " + relativeTime(source["updated_at"].double) : ""))
                }.font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.danger)
                Text("我读不到 \(name) 了" + (source["status"].string == "needs_connection" ? "，授权已过期。重新授权前，我看不到新的内容。" : "。重新连接前，我看不到新的内容。")).font(TypeScale.headline).lineSpacing(3)
                Button("重新授权 " + name) { model.selectedConnector = source }.buttonStyle(.primaryAction)
            }
        }
        .accessibilityIdentifier("source-broken-" + source["name"].string)
    }
}

/// 月度账本：一行判断 + 看明细。
struct LedgerNote: View {
    @Environment(AppModel.self) private var model
    let finance: JSON
    var body: some View {
        let money = finance["currencies"].array.first ?? .null
        let top = money["categories"].array.first ?? .null
        let day = Calendar.current.component(.day, from: Date())
        Button { model.showFinance = true } label: {
            HStack(spacing: Space.md) {
                IconBadge(symbol: "creditcard", tone: .accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("账本" + (finance["stale"].bool ? " · 上次快照" : "")).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    (Text("\(monthLabel())过了 \(day) 天，已花 ") + Text(yuan(money["month_minor"])).fontWeight(.semibold) + Text(top.isNull ? "。" : "，\(top["name"].string) \(yuan(top["amount_minor"])) 最多。"))
                        .font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary).lineSpacing(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Chevron()
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .noteSurface()
        }.buttonStyle(.plain).accessibilityIdentifier("ledger-note").accessibilityLabel("账本，看明细")
    }
    private func yuan(_ minor: JSON) -> String { "¥" + (minor.double / 100).formatted(.number.precision(.fractionLength(0))) }
    private func monthLabel() -> String { "\(Calendar.current.component(.month, from: Date()))月" }
}
