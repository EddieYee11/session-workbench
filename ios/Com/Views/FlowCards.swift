import SwiftUI
import UIKit
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
    /// 统一「等你」角标：审批/待验收 + waiting API（航程停顿、微信待回、近 3 天过期待办）。
    var waitingInboxCount: Int { decisionCount + (waitingData["count"].int > 0 ? waitingData["count"].int : waitingData["items"].array.count) }
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

    /// 右划主操作。返回是否成功（导航类恒 true；批准/讨论失败为 false）。
    @discardableResult
    func pendingPrimary(_ item: PendingItem) async -> Bool {
        switch item.kind {
        case .proposal:
            return await action("/personal/work/proposals/" + item.value.id.pathEncoded + "/approve", fields: ["explicit_authorization": .bool(true)], refresh: .doing)
        case .task:
            selectedTask = item.value
            return true
        case .matter:
            return await pendingDiscuss(item)
        case .goal:
            tab = .doing
            return true
        case .project:
            tab = .work
            return true
        }
    }
    @discardableResult
    func pendingDiscuss(_ item: PendingItem) async -> Bool {
        guard item.kind == .matter || item.kind == .goal || item.kind == .project else {
            selectedTask = item.kind == .task ? item.value : nil
            return item.kind == .task
        }
        do {
            _ = try await agencyAction(item.value, action: "discuss")
            showWaiting = false
            tab = .chat
            Haptics.success()
            return true
        } catch {
            // 调用方用 completed / InlineNotice 开口；banner 仅兜底。
            return false
        }
    }
    /// 左划：任务归档、派活先别、目标暂停、事项留到明天再提（24 小时）。
    @discardableResult
    func pendingDismiss(_ item: PendingItem) async -> Bool {
        do {
            switch item.kind {
            case .task: try await dismissTask(item.value)
            case .proposal:
                guard await action("/personal/work/proposals/" + item.value.id.pathEncoded + "/reject", refresh: .doing) else { return false }
            case .goal: _ = try await agencyAction(item.value, action: "pause")
            default: _ = try await agencyAction(item.value, action: "later", extra: ["hours": .number(24)])
            }
            Haptics.selection()
            return true
        } catch {
            return false
        }
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
        // 已归档；列表没刷齐则乐观标 cancelled + 开口，别假装列表已是最新。
        if await load("/personal/tasks") == nil {
            var value = datasets["/personal/tasks"] ?? .object([:])
            value["items"] = .array(value["items"].array.map { row in
                guard row.id == task.id else { return row }
                var copy = row
                copy["status"] = .string("cancelled")
                return copy
            })
            datasets["/personal/tasks"] = value
            recomputeFlow()
            let err = errors["/personal/tasks"] ?? ""
            tasksOpenNote = err.isEmpty
                ? "已归档，列表没刷齐——可下拉再试。不会假装列表已是最新。"
                : "已归档，列表没刷齐：" + err + "——可下拉再试。不会假装列表已是最新。"
        } else {
            tasksOpenNote = ""
        }
    }
    /// 把超过 7 天的旧任务一口气归档。返回成功/失败件数；页内据件数开口，勿一律报全归档。
    @discardableResult
    func archiveStale() async -> (ok: Int, fail: Int) {
        var ok = 0
        var fail = 0
        for item in staleItems {
            do {
                try await dismissTask(item.value)
                ok += 1
            } catch {
                fail += 1
            }
        }
        if ok > 0 { Haptics.success() }
        return (ok, fail)
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
            if waitingInboxCount > 0 { return .ask }
            if !brokenSources.isEmpty { return .broken }
            if stage.state == .waiting { return .think }
            return .idle
        default: return stage.state.strip
        }
    }
    var stripCaption: String {
        if !isPaired { return "先连上 Mac mini，我才动得了" }
        // 10-17：这一轮有 todo 清单时，锁屏/灵动岛直接说「任务名 · 正在做的那步」
        if let plan = liveProcess?.plan, !plan.active.isEmpty { return plan.title.isEmpty ? plan.active : plan.title + " · " + plan.active }
        switch stage.state {
        case .offline: return "连不上 mini——我先歇着，连上再接着"
        case .failed: return "这步卡住了，看对话里怎么修"
        case .delivered: return "办完了，在下面"
        case .review: return "这一步要你点头"
        case .idle, .waiting:
            if waitingInboxCount > 0 {
                if let tip = ChatAttentionHint.topWaitingTitle(self) {
                    return waitingInboxCount == 1 ? "等你拍板：\(tip)" : "等你拍板：\(tip)（还有 \(waitingInboxCount - 1)）"
                }
                return "有 \(waitingInboxCount) 件在等你拍板"
            }
            if let broken = brokenSources.first { return "读不到 " + sourceName(broken["name"].string) + " 了" }
            if stage.state == .waiting { return "还在等新进展" }
            if nextUrgentCount > 0 {
                if let tip = ChatAttentionHint.topNextTitle(self) {
                    return "下一步：\(tip)"
                }
                return "有 \(nextUrgentCount) 件现在就该看"
            }
            if casesData["active"].int > 0 { return "\(casesData["active"].int) 段航程在跑，随时问我" }
            let hour = Calendar.current.component(.hour, from: Date())
            switch hour {
            case 5..<11: return "早，我在这儿"
            case 11..<14: return "在这儿，随时叫我"
            case 14..<18: return "还醒着，随时叫我"
            case 18..<23: return "晚上也在，随时叫我"
            default: return "夜深了，我还醒着"
            }
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
        case .offline: return "掉线了"
        case .failed: return "卡住了"
        default:
            if stage.state == .review || waitingInboxCount > 0 {
                // 举牌点名最要紧那件（牌面字少）：比空泛「等你」更像活人在催。
                if let tip = ChatAttentionHint.topWaitingTitle(self) {
                    let t = tip.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count <= 5 { return t }
                    return String(t.prefix(4)) + "…"
                }
                return "等你"
            }
            if let broken = brokenSources.first { return broken["name"].string.contains("calendar") ? "日历断了" : "邮箱断了" }
            return ""
        }
    }
    var stripOnRight: Bool { [.ask, .send, .broken, .done].contains(stripState) }
    var stripMachine: String { runningTasks.first?["host"].string ?? "" }

    // MARK: 下拉工作台

    func openStage() {
        showMenu = false
        let reduce = UIAccessibility.isReduceMotionEnabled
        withAnimation(ComMotion.reduced(reduce, ComMotion.rise)) { stageProgress = 1; stageExpanded = true }
    }
    func closeStage() {
        let reduce = UIAccessibility.isReduceMotionEnabled
        withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { stageProgress = 0; stageExpanded = false }
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
    /// 等你列表最上面那件：描边强调 +「先看这件」，一卡一动作的视觉重心。
    var lead: Bool = false
    var tilt: Double = 0
    var completed: (String) -> Void = { _ in }
    @State private var busy = false
    @State private var offset: CGFloat = 0
    @State private var showDetail = false
    @State private var landed = false
    private var focus: Bool { item.kind == .proposal }
    var body: some View {
        Card(lead || focus ? .highlighted(lead ? .warning : .accent) : .standard, padding: 0) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: item.symbol).font(.system(size: 14)).foregroundStyle(Palette.textTertiary)
                    Text([item.source, relativeTime(item.time)].filter { !$0.isEmpty }.joined(separator: " · ")).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    Spacer()
                    if lead { Stamp(text: "先看这件", tone: .warning) }
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
            guard !busy else { return }
            guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
            offset = max(-110, min(110, value.translation.width * 0.6))
        }.onEnded { value in
            let width = value.translation.width
            withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { offset = 0 }
            guard !busy else { return }
            if width < -80 { dismiss() }
            else if width > 80 { primarySwipe() }
        })
        .contextMenu {
            Button("和它聊这件事", systemImage: "bubble.left") {
                guard !busy else { return }
                busy = true
                Task {
                    if await model.pendingDiscuss(item) {
                        completed(item.draft.isEmpty ? "已接进主对话" : "草稿已带进主对话")
                    } else {
                        completed("没接进，还可以再试")
                    }
                    busy = false
                }
            }
            .disabled(busy)
            Button(item.dismissLabel, systemImage: item.kind == .task ? "archivebox" : "xmark") { dismiss() }
            if item.kind == .matter {
                Button("这件事已处理", systemImage: "checkmark") { act("handled", message: "已处理，停止重复提醒") }
                Button("不再关注这件事", systemImage: "bell.slash") { act("mute", message: "已停止关注这件事") }
            }
        }
        .sheet(isPresented: $showDetail) { detail }
        .scaleEffect(reduce || landed ? 1 : 0.97)
        .opacity(reduce || landed ? 1 : 0)
        .onAppear {
            if reduce { landed = true }
            else { withAnimation(ComMotion.pop) { landed = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-" + item.id)
    }
    @ViewBuilder private var actions: some View {
        HStack(spacing: Space.sm) {
            switch item.kind {
            case .proposal:
                Button("批准") {
                    guard !busy else { return }
                    busy = true
                    Task {
                        if await model.action("/personal/work/proposals/" + item.value.id.pathEncoded + "/approve", fields: ["explicit_authorization": .bool(true)], refresh: .doing) {
                            completed("已批准，去做了")
                        } else {
                            completed("批准没成，还可以再试")
                        }
                        busy = false
                    }
                }.buttonStyle(.primaryAccent).disabled(busy)
                Button("先别") {
                    guard !busy else { return }
                    busy = true
                    Task {
                        if await model.action("/personal/work/proposals/" + item.value.id.pathEncoded + "/reject", refresh: .doing) {
                            completed("先按兵不动")
                        } else {
                            completed("没成，还可以再试")
                        }
                        busy = false
                    }
                }.buttonStyle(.secondaryAction).disabled(busy)
            case .task:
                Button(item.primary) { model.selectedTask = item.value }.buttonStyle(.primaryFull)
                Button("归档") { dismiss() }.buttonStyle(.secondaryAction).disabled(busy)
            case .matter:
                Button(busy ? "接进中…" : (item.draft.isEmpty ? "交给我办" : "去聊")) {
                    guard !busy else { return }
                    busy = true
                    Task {
                        // 送达/建讨论失败别报「已接进」；留在等你开口可重试。
                        if await model.pendingDiscuss(item) {
                            completed(item.draft.isEmpty ? "已接进主对话——我在那儿等你开口" : "草稿已带进主对话")
                        } else {
                            completed("没接进，卡还在——还可以再试")
                        }
                        busy = false
                    }
                }.buttonStyle(.primaryFull).disabled(busy).accessibilityIdentifier("pending-discuss")
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
        guard !busy else { return }
        busy = true
        Task {
            // 写回失败别报「已划掉」；卡留在等你可再划。
            guard await model.pendingDismiss(item) else {
                busy = false
                completed("划掉没成，卡还在——可以再划")
                return
            }
            if item.kind == .task, !model.tasksOpenNote.isEmpty {
                completed(model.tasksOpenNote)
            } else if !model.agencyCardsNote.isEmpty {
                completed(model.agencyCardsNote)
            } else {
                completed(item.kind == .task ? "已归档，在「已结束」里还能恢复" : item.kind == .proposal ? "已回绝这次派活" : "已划掉，明天前不再提")
            }
            busy = false
        }
    }
    /// 右划：与按钮主操作同门控；批准/讨论失败留卡可重试。
    private func primarySwipe() {
        guard !busy else { return }
        busy = true
        Task {
            let ok = await model.pendingPrimary(item)
            switch item.kind {
            case .proposal:
                completed(ok ? "已批准，去做了" : "批准没成，还可以再试")
            case .matter:
                if ok {
                    completed(item.draft.isEmpty ? "已接进主对话——我在那儿等你开口" : "草稿已带进主对话")
                } else {
                    completed("没接进，还可以再试")
                }
            default:
                break
            }
            busy = false
        }
    }
    private func act(_ action: String, message: String) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                _ = try await model.agencyAction(item.value, action: action, extra: action == "later" ? ["hours": .number(24)] : [:])
                Haptics.success()
                // later/mute 后 cards 没刷齐时 agencyCardsNote 已写。
                if !model.agencyCardsNote.isEmpty {
                    completed(model.agencyCardsNote)
                } else {
                    completed(message)
                }
            } catch {
                completed("没成，卡还在——可以再试")
            }
            busy = false
        }
    }
    private func prepare() {
        guard !busy else { return }
        busy = true
        Task {
            do {
                _ = try await model.agencyAction(item.value, action: "prepare")
                Haptics.success()
                // cards 没刷齐时开口；整理结果已乐观写上，打开详情仍能看。
                if !model.agencyCardsNote.isEmpty {
                    completed(model.agencyCardsNote)
                } else {
                    completed("资料已整理，打开详情继续")
                }
            } catch {
                completed("整理没成，还可以再试")
            }
            busy = false
        }
    }
}

/// 待批准的派活：完整要求 + 操作范围。
struct ProposalDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let proposal: JSON
    @State private var busy = false
    @State private var failNote = ""
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
                    if !failNote.isEmpty {
                        InlineNotice(text: failNote, tone: .danger)
                            .accessibilityIdentifier("proposal-detail-fail")
                    }
                    HStack(spacing: Space.sm) {
                        Button(busy ? "提交中…" : "批准这项工作") {
                            guard !busy else { return }
                            busy = true
                            failNote = ""
                            Task {
                                if await model.action("/personal/work/proposals/" + proposal.id.pathEncoded + "/approve", fields: ["explicit_authorization": .bool(true)], refresh: .doing) {
                                    dismiss()
                                } else {
                                    failNote = "批准没成——页还在，还可以再试。不会假装已批准。"
                                }
                                busy = false
                            }
                        }.buttonStyle(.primaryAction).disabled(busy)
                        Button("先别") {
                            guard !busy else { return }
                            busy = true
                            failNote = ""
                            Task {
                                if await model.action("/personal/work/proposals/" + proposal.id.pathEncoded + "/reject", refresh: .doing) {
                                    dismiss()
                                } else {
                                    failNote = "回绝没成——页还在，还可以再试。不会假装已回绝。"
                                }
                                busy = false
                            }
                        }.buttonStyle(.secondaryAction).disabled(busy)
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
    /// 跳转前拉新进行中，防连点叠开。
    @State private var opening = false
    /// 拉现况失败开口；别假开配置页。
    @State private var openFail = ""
    private var name: String { sourceName(source["name"].string) }
    var body: some View {
        Card(.highlighted(.danger)) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)); Text("信源断了" + (source["updated_at"].double > 0 ? " · " + relativeTime(source["updated_at"].double) : ""))
                }.font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.danger)
                Text("我读不到 \(name) 了" + (source["status"].string == "needs_connection" ? "——授权过期了。你先重新授权，我才能继续盯新内容；其它事仍可跟我说。" : "。连上前我看不到这边的新内容，其它事仍可跟我说。")).font(TypeScale.headline).lineSpacing(3)
                if !openFail.isEmpty {
                    InlineNotice(text: openFail, tone: .danger)
                        .accessibilityIdentifier("source-broken-open-fail")
                }
                Button(opening ? "打开中…" : "去把 \(name) 接上") {
                    guard !opening else { return }
                    opening = true
                    openFail = ""
                    Task {
                        // 先拉现况再开详情，别带着过期「已断」快照进配置页；拉失败留卡可再试。
                        if await model.load("/personal/connectors") == nil {
                            let err = model.errors["/personal/connectors"] ?? ""
                            openFail = err.isEmpty
                                ? "信源现况没拉上——还可以再点。不会假装已打开配置。"
                                : "信源现况没拉上：" + err + "——还可以再点。"
                            opening = false
                            return
                        }
                        let key = source["name"].string
                        let fresh = model.datasets["/personal/connectors"]?["sources"].array.first { $0["name"].string == key } ?? source
                        model.selectedConnector = fresh
                        opening = false
                    }
                }
                .buttonStyle(.primaryAction)
                .disabled(opening)
                .accessibilityIdentifier("source-broken-open-" + source["name"].string)
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
        let opening = model.financeOpening
        let openFail = !opening && !model.financeOpenNote.isEmpty
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                guard !opening else { return }
                model.openFinance()
            } label: {
                HStack(spacing: Space.md) {
                    IconBadge(symbol: "creditcard", tone: .accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(opening ? "账本 · 打开中…" : (finance["stale"].bool ? "账本 · 上次快照" : "账本"))
                            .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                        Text(ledgerLine(day: day, money: money, top: top))
                            .font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary).lineSpacing(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    if opening { ProgressView().controlSize(.small) } else { Chevron() }
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.md + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .noteSurface()
                .opacity(opening ? 0.72 : 1)
            }
            .buttonStyle(.plain)
            .disabled(opening)
            .accessibilityIdentifier("ledger-note")
            .accessibilityLabel(opening ? "账本，正在打开" : "账本，看明细")
            if openFail {
                InlineNotice(text: model.financeOpenNote, tone: .danger)
                    .accessibilityIdentifier("ledger-open-fail")
            }
        }
    }
    private func yuan(_ minor: JSON) -> String { "¥" + (minor.double / 100).formatted(.number.precision(.fractionLength(0))) }
    private func monthLabel() -> String { "\(Calendar.current.component(.month, from: Date()))月" }
    private func ledgerLine(day: Int, money: JSON, top: JSON) -> String {
        let spent = yuan(money["month_minor"])
        if top.isNull { return "\(monthLabel())过了 \(day) 天，已花 \(spent)。" }
        return "\(monthLabel())过了 \(day) 天，已花 \(spent)，\(top["name"].string) \(yuan(top["amount_minor"])) 最多。"
    }
}
