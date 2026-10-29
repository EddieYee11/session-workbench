import SwiftUI
import ComCore

// 动态（2026-10-28）：替换原来的「航程」列表和「它做过的事」审计页，一页说清「Com 替我干了什么」。
// 审批已放宽到只拦不可逆删除（10-02），记账、外发、付款都没有执行前闸门——这一页就是事后核对的地方：
// 每条能看详情、标「做成了 / 没做成 / 做错了」，做错的一键回到对话让它改。
// 数据两路在客户端合并：/personal/activity（它做过的写操作，backend/activity.py）+ /personal/cases（航程进展）。
// 版式参考 Eddie 给的 activity-feed-replica.html（筛选滑标、今天/昨天分段、新动态药丸、全部已读级联），配色换成 Com 的青柠。

enum FeedFilter: String, CaseIterable, Identifiable {
    case all, ledger, schedule, outbound, work, check
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .ledger: "记账"
        case .schedule: "日程提醒"
        case .outbound: "外发"
        case .work: "电脑上的活"
        case .check: "待核对"
        }
    }
}

extension AppModel {
    static let feedPath = "/personal/activity?limit=150"
    var feedData: JSON { datasets[Self.feedPath] ?? activityData }
    /// 拉齐动态两路；返回各自是否成功，便于页内区分假空与真失败。
    @discardableResult
    func loadFeed() async -> (activity: Bool, cases: Bool) {
        async let a = load(Self.feedPath)
        async let c = load("/personal/cases")
        let activity = await a != nil
        let cases = await c != nil
        return (activity, cases)
    }
}

/// 一条动态：一次写操作、一组同类连续操作，或一段航程。
struct FeedItem: Identifiable, Equatable {
    enum Kind: Equatable { case effect, voyage }
    let id: String
    let kind: Kind
    let type: String          // ledger / schedule / outbound / work / other
    let title: String
    let subtitle: String
    let at: Double
    let state: String         // 操作：completed / failed / uncertain / confirmed / not_done / disputed；航程：running / waiting / done ...
    let entries: [JSON]       // 操作的原始行（合并组有多条）
    var caseID = ""
    var needsCheck: Bool {
        kind == .effect ? ["uncertain", "failed", "disputed"].contains(state) : ["waiting", "attention"].contains(state)
    }
    func matches(_ filter: FeedFilter) -> Bool {
        switch filter {
        case .all: true
        case .check: needsCheck
        default: type == filter.rawValue
        }
    }
    static func == (a: FeedItem, b: FeedItem) -> Bool { a.id == b.id && a.state == b.state && a.at == b.at && a.entries.count == b.entries.count && a.subtitle == b.subtitle }

    /// 两路数据 → 按时间倒序的动态。挂在航程下的操作不单列（航程详情里看步骤）；同一句话里连着的同类操作合成一条，免得刷屏。
    static func build(activity: [JSON], cases: [JSON]) -> [FeedItem] {
        var out: [FeedItem] = []
        var group: [JSON] = []
        func flush() {
            guard let first = group.first else { return }
            let type = first["type"].string.isEmpty ? "other" : first["type"].string
            let states = group.map { $0["state"].string }
            let state = states.first { ["failed", "disputed", "uncertain"].contains($0) } ?? first["state"].string
            let title = group.count == 1 ? first["summary"].string : Self.merged(first["tool"].string, group.count, first["summary"].string)
            let source = first["source"].string
            out.append(FeedItem(id: "e:" + first["key"].string, kind: .effect, type: type, title: title,
                                subtitle: source.isEmpty ? "" : "来自「" + String(source.prefix(28)) + "」", at: first["at"].double, state: state, entries: group))
            group = []
        }
        for row in activity {
            // 挂在航程下的步骤归航程；没记下动作也没有来源的老记录（10-25 之前）不进动态
            if !row["task_id"].string.isEmpty { continue }
            if row["tool"].string.isEmpty && row["source"].string.isEmpty { continue }
            if let last = group.last, last["tool"].string == row["tool"].string, last["message_id"].string == row["message_id"].string, !row["message_id"].string.isEmpty {
                group.append(row)
            } else { flush(); group = [row] }
        }
        flush()
        for c in cases {
            // 聊天里顺手进航程的多步轮次（14 天 65 段，交办只有 20 段）在聊天里就能回看，这里只收交办的；停下来等你的例外
            let chat = c["kind"].string == "turn" || c["source"].string == "chat"
            if chat && !["waiting", "attention"].contains(c["state"].string) { continue }
            let p = c["progress"]
            let step = p["total"].int > 0 ? " · \(p["done"].int)/\(p["total"].int) 步" : ""
            let waiting = ["waiting", "attention"].contains(c["state"].string)
            let line = waiting && !c["waiting"]["question"].string.isEmpty ? c["waiting"]["question"].string
                : !c["now"].string.isEmpty ? c["now"].string : c["result"].string
            // 等你 / 没做成由状态胶囊说，副标题不再重复
            let label = waiting || c["state"].string == "failed" ? "" : c["state_label"].string
            let parts = [label + step, line].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ·")) }.filter { !$0.isEmpty }
            out.append(FeedItem(id: "c:" + c.id, kind: .voyage, type: "work", title: "航程 · " + c["title"].string,
                                subtitle: parts.joined(separator: " · "),
                                at: max(c["updated_at"].double, c["created_at"].double), state: c["state"].string, entries: [], caseID: c.id))
        }
        return out.sorted { $0.at > $1.at }
    }
    static func merged(_ tool: String, _ n: Int, _ first: String) -> String {
        switch tool.lowercased() {
        case "bash": "跑了 \(n) 条命令"
        case "write", "edit": "改了 \(n) 个文件"
        case "bookkeeping": "记了 \(n) 笔账"
        case "remind": "定了 \(n) 个提醒"
        case "calendar_event": "动了 \(n) 个日程"
        default: first + " 等 \(n) 步"
        }
    }
}

struct ActivityFeedSheet: View {
    var initial: FeedFilter = .all
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ActivityFeedView(initial: initial)
                .toolbar {
                    if model.activityOpening {
                        ToolbarItem(placement: .topBarLeading) {
                            ProgressView().controlSize(.small).accessibilityLabel("正在拉齐动态")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                }
        }
    }
}

struct ActivityFeedView: View {
    var initial: FeedFilter = .all
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var filter: FeedFilter?
    @State private var open: String?
    /// 已读水位线：时间戳；比它新的算未读（本机记，换设备从头算）。
    @AppStorage("feed.seen") private var seen: Double = 0
    @State private var clearing = false
    @State private var sweep: CGFloat = -0.1
    /// 页面开着时新到的动态先攒着，弹药丸；点一下才插到顶上（不在你看的时候把列表往下推）。
    @State private var known: Set<String>?
    @State private var feedLanded = false
    @State private var feedLoading = false
    @State private var feedFail = ""
    @State private var feedLoadedOnce = false
    @Namespace private var filterSpace
    private var spring: Animation { ComMotion.reduced(reduce, ComMotion.pop) }
    private var feedPulling: Bool { model.activityOpening || feedLoading || !feedLoadedOnce }

    private var all: [FeedItem] { FeedItem.build(activity: model.feedData["items"].array, cases: model.casesData["items"].array) }
    private var current: FeedFilter { filter ?? initial }

    var body: some View {
        let items = all
        let shown = items.filter { known == nil || known!.contains($0.id) }
        let pending = items.filter { known != nil && !known!.contains($0.id) }
        let visible = shown.filter { $0.matches(current) }
        let unread = shown.filter { $0.at > seen }.count
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header(unread: unread).id("top")
                    if feedPulling {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.small)
                            Text(current == .work ? "正在拉齐航程…" : "正在拉齐动态…")
                                .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                        }
                        .accessibilityLabel("正在拉齐动态")
                        .accessibilityIdentifier("activity-feed-pulling")
                    }
                    if !feedFail.isEmpty {
                        InlineNotice(text: feedFail, tone: .danger)
                        Button(feedLoading || model.activityOpening ? "重试中…" : "再试一次") {
                            guard !feedLoading, !model.activityOpening else { return }
                            Task { await refreshFeed(force: true) }
                        }
                        .buttonStyle(.secondaryCompact)
                        .disabled(feedLoading || model.activityOpening)
                        .accessibilityIdentifier("activity-feed-retry")
                    }
                    filterBar(shown)
                    if visible.isEmpty {
                        EmptyState(title: !feedFail.isEmpty
                                   ? (current == .work ? "航程还没读上" : "动态还没读上")
                                   : current == .all ? "眼下还没什么动静" : "这一类还是空的",
                                   description: !feedFail.isEmpty
                                   ? "先重试拉齐；通了会按时间列出来。"
                                   : current == .all
                                   ? "我记账、定提醒、改文件、跑航程，都会按时间列在这里；看错了可以直接标出来。"
                                   : "换个筛选，或稍后再来——有动静我会记下来。",
                                   symbol: "list.bullet.rectangle")
                            .padding(.top, Space.xl)
                            .enterRise(on: feedLanded, delay: 0.04, y: 14, blur: 6)
                    }
                    ForEach(sections(visible), id: \.0) { name, date, rows in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Space.sm) {
                                Text(name).font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                                Text(date).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                            }
                            .padding(.horizontal, Space.xs).padding(.bottom, 4)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index)
                                    .transition(reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -16)), removal: .opacity))
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.lg).padding(.bottom, Space.xxl)
                .overlay(alignment: .top) { sweepLine }
            }
            .overlay(alignment: .top) {
                if !pending.isEmpty {
                    NewPill(count: pending.count) {
                        withAnimation(reduce ? nil : spring) { known = Set(items.map(\.id)) }
                        withAnimation(reduce ? nil : spring) { proxy.scrollTo("top", anchor: .top) }
                    }
                    .padding(.top, Space.sm)
                    .transition(reduce ? .opacity : .scale(scale: 0.9).combined(with: .opacity).combined(with: .offset(y: -8)))
                }
            }
            .animation(reduce ? nil : spring, value: pending.count)
        }
        .background(Palette.background)
        .navigationTitle("动态").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .refreshable {
            await refreshFeed(force: true)
            withAnimation(reduce ? nil : spring) { known = Set(all.map(\.id)) }
        }
        .onAppear {
            if reduce { feedLanded = true }
            else { withAnimation(ComMotion.rise) { feedLanded = true } }
        }
        .task {
            while !Task.isCancelled {
                await refreshFeed(force: false)
                if known == nil { known = Set(all.map(\.id)) }
                try? await Task.sleep(for: .seconds(model.casesData["active"].int > 0 ? 4 : 15))
            }
        }
        .accessibilityIdentifier("activity-feed")
    }

    private func refreshFeed(force: Bool) async {
        if feedLoading { return }
        feedLoading = true
        if force { feedFail = "" }
        defer {
            feedLoading = false
            feedLoadedOnce = true
        }
        let result: (activity: Bool, cases: Bool)
        // 与 openActivityFeed 同路：入口已在拉则等它结束，避免叠刷。
        if model.activityOpening && !force {
            while model.activityOpening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
            }
            let actPath = AppModel.feedPath
            let actOk = model.errors[actPath] == nil && (model.datasets[actPath] != nil || !model.feedData.isNull)
            let caseOk = model.errors["/personal/cases"] == nil && model.datasets["/personal/cases"] != nil
            result = (actOk, caseOk)
        } else {
            result = await model.loadFeed()
        }
        if result.activity && result.cases {
            feedFail = ""
            model.activityOpenNote = ""
            return
        }
        let actErr = model.errors[AppModel.feedPath] ?? model.errors["/personal/activity"] ?? ""
        let caseErr = model.errors["/personal/cases"] ?? ""
        let hadCache = !all.isEmpty
        if !result.activity && !result.cases {
            let err = [actErr, caseErr].first { !$0.isEmpty } ?? ""
            feedFail = err.isEmpty
                ? (hadCache ? "动态与航程都没刷新上——下面仍是上一版，可再试" : "动态与航程都没拉齐——检查配对或网络后再试")
                : (hadCache ? "动态没刷新上：" + err + "——下面仍是上一版" : "动态没拉齐：" + err + "——可再试")
        } else if !result.cases {
            feedFail = caseErr.isEmpty
                ? (hadCache ? "航程列表没刷新上——写操作若在仍可先看；可再试" : "航程列表没读上——可再试")
                : "航程列表没读上：" + caseErr + "——可再试"
        } else {
            feedFail = actErr.isEmpty
                ? (hadCache ? "写操作动态没刷新上——航程若在仍可先看；可再试" : "写操作动态没读上——可再试")
                : "写操作动态没读上：" + actErr + "——可再试"
        }
    }

    // MARK: 顶部

    private func header(unread: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text("它替你做的事").font(TypeScale.title)
                    if model.activityOpening {
                        ProgressView().controlSize(.small).accessibilityLabel("正在拉齐动态")
                    } else if unread > 0 {
                        Text("\(unread)").font(TypeScale.section.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                            .contentTransition(.numericText())
                    }
                }
                Text(model.activityOpening ? "正在拉齐最新动静…" : "已经替你动过手的事都记在这；不对的点开标一下。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: Space.sm)
            Button { markAllRead() } label: {
                Label(unread == 0 ? "都看过了" : "全部已读", systemImage: unread == 0 ? "checkmark.circle.fill" : "checkmark")
                    .font(TypeScale.footnote.weight(.semibold))
                    .foregroundStyle(unread == 0 ? TodayHue.mint.ink : Palette.textPrimary)
                    .padding(.horizontal, Space.md).padding(.vertical, 7)
                    .background(unread == 0 ? TodayHue.mint.fill : Palette.surface, in: .rect(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(unread == 0 ? .clear : Palette.separator, lineWidth: 0.8))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain).disabled(unread == 0 || model.activityOpening)
            .animation(reduce ? nil : spring, value: unread == 0)
            .accessibilityIdentifier("feed-mark-read")
        }
        .padding(.top, Space.sm)
    }

    private func markAllRead() {
        Haptics.success()
        clearing = true
        if !reduce {
            sweep = -0.1
            withAnimation(.easeInOut(duration: 0.9)) { sweep = 1.1 }
        }
        // 未读点按行错峰消失（每行 60ms），最后一起落水位线
        Task {
            try? await Task.sleep(for: .milliseconds(reduce ? 0 : 700))
            withAnimation(reduce ? nil : spring) { seen = Date().timeIntervalSince1970; clearing = false }
        }
    }

    /// 「全部已读」时从上往下扫过的一道青柠光。
    @ViewBuilder private var sweepLine: some View {
        GeometryReader { geo in
            LinearGradient(colors: [Palette.accent.opacity(0), Palette.accent.opacity(0.9), Palette.accent.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 2).blur(radius: 0.5)
                .shadow(color: Palette.accent.opacity(0.8), radius: 6)
                .offset(y: geo.size.height * sweep)
                .opacity(sweep > 0 && sweep < 1 ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    // MARK: 筛选

    private func filterBar(_ items: [FeedItem]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(FeedFilter.allCases) { f in
                    let count = items.filter { $0.matches(f) }.count
                    let on = current == f
                    Button {
                        Haptics.selection()
                        withAnimation(ComMotion.reduced(reduce, ComMotion.pop)) { filter = f; open = nil }
                    } label: {
                        HStack(spacing: 5) {
                            Text(f.title).font(TypeScale.footnote.weight(on ? .semibold : .medium))
                            if count > 0 {
                                Text("\(count)").font(.caption2.weight(f == .check ? .bold : .regular).monospacedDigit())
                                    .foregroundStyle(f == .check ? Palette.warning : Palette.textTertiary)
                                    .contentTransition(.numericText())
                            }
                        }
                        .foregroundStyle(on ? Palette.textPrimary : Palette.textSecondary)
                        .padding(.horizontal, Space.md).padding(.vertical, 7)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface)
                                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "feed-filter", in: filterSpace)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("feed-filter-" + f.rawValue)
                }
            }
            .padding(3)
            .background(Palette.fill, in: .rect(cornerRadius: 12, style: .continuous))
        }
        .scrollIndicators(.hidden)
    }

    // MARK: 分段与行

    private func sections(_ items: [FeedItem]) -> [(String, String, [FeedItem])] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN"); df.timeZone = calendar.timeZone
        var out: [(String, String, [FeedItem])] = []
        for item in items {
            let date = Date(timeIntervalSince1970: item.at)
            let name: String
            if item.at <= 0 { name = "更早" }
            else if calendar.isDateInToday(date) { name = "今天" }
            else if calendar.isDateInYesterday(date) { name = "昨天" }
            else if Date().timeIntervalSince(date) < 6 * 86400 { df.dateFormat = "EEEE"; name = df.string(from: date) }
            else { name = "更早" }
            df.dateFormat = "M月d日"
            let label = name == "更早" ? "" : df.string(from: date)
            if let i = out.firstIndex(where: { $0.0 == name }) { out[i].2.append(item) } else { out.append((name, label, [item])) }
        }
        return out
    }

    @ViewBuilder private func row(_ item: FeedItem, index: Int) -> some View {
        let unread = item.at > seen && !clearing
        let expanded = open == item.id
        VStack(alignment: .leading, spacing: 0) {
            if item.kind == .voyage {
                NavigationLink { CaseDetailView(id: item.caseID) } label: { FeedRowLabel(item: item, unread: unread, index: index, chevron: true) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("feed-row-" + item.id)
            } else {
                Button {
                    Haptics.selection()
                    withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { open = expanded ? nil : item.id }
                } label: { FeedRowLabel(item: item, unread: unread, index: index, chevron: false) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("feed-row-" + item.id)
                if expanded {
                    FeedDetailCard(item: item) { open = nil }
                        .padding(.leading, 52).padding(.trailing, Space.sm).padding(.bottom, Space.sm)
                        .transition(reduce ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
        }
        .background(expanded ? Palette.surface : .clear, in: .rect(cornerRadius: Radius.md, style: .continuous))
    }
}

/// 头像（按类别上色的图标）· 标题 · 来源 · 时间 · 状态胶囊；左边青柠未读点。
private struct FeedRowLabel: View {
    let item: FeedItem
    let unread: Bool
    let index: Int
    let chevron: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            ZStack(alignment: .topLeading) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(hue.ink)
                    .frame(width: 38, height: 38).background(hue.fill, in: .circle)
                Circle().fill(Palette.accentText).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Palette.background, lineWidth: 2.5))
                    .offset(x: -2, y: -1)
                    .scaleEffect(unread ? 1 : 0.01).opacity(unread ? 1 : 0)
                    .animation(ComMotion.reduced(reduce, ComMotion.pop.delay(Double(index) * ComMotion.stagger)), value: unread)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(item.title).font(TypeScale.subheadline.weight(unread ? .semibold : .regular)).foregroundStyle(Palette.textPrimary).lineLimit(2)
                    Spacer(minLength: Space.sm)
                    Text(clock).font(.caption.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                }
                HStack(spacing: 6) {
                    if let chip { Text(chip.0).font(.caption2.weight(.semibold)).foregroundStyle(chip.1.color)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(chip.1.color.opacity(0.12), in: .capsule) }
                    if item.kind == .voyage && item.state == "running" { WorkPulse() }
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    if chevron { Spacer(minLength: 0); Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary) }
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, Space.sm)
        .contentShape(.rect)
    }
    private var hue: TodayHue {
        switch item.type {
        case "ledger": .butter
        case "schedule": .lavender
        case "outbound": .pink
        case "work": .sky
        default: .mint
        }
    }
    private var symbol: String {
        if item.kind == .voyage { return "location.north.line" }
        switch item.type {
        case "ledger": return "yensign"
        case "schedule": return item.entries.first?["tool"].string == "remind" ? "bell" : "calendar"
        case "outbound": return "paperplane"
        case "work": return item.entries.first?["tool"].string.lowercased() == "bash" ? "terminal" : "doc.text"
        default: return "sparkles"
        }
    }
    private var clock: String {
        guard item.at > 0 else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return Date().timeIntervalSince1970 - item.at < 60 ? "刚刚" : f.string(from: Date(timeIntervalSince1970: item.at))
    }
    /// 状态胶囊：只有要你留意的才出（Ready 不打扰）；外发一律标出来。
    private var chip: (String, Tone)? {
        if item.kind == .voyage {
            return ["waiting", "attention"].contains(item.state) ? ("等你", .warning) : item.state == "failed" ? ("没做成", .danger) : nil
        }
        switch item.state {
        case "failed": return ("失败", .danger)
        case "uncertain": return ("不确定", .warning)
        case "disputed": return ("你标了做错", .danger)
        case "not_done": return ("你说没做成", .neutral)
        case "confirmed": return ("你确认过", .success)
        default: return item.type == "outbound" ? ("已外发", .warning) : nil
        }
    }
}

/// 点开一条操作：参数明细、来源、每一步（合并组），以及「做成了 / 没做成 / 做错了」和「让它改」。
private struct FeedDetailCard: View {
    let item: FeedItem
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// 乐观选中；失败清掉回弹。服务器 verdict 到了也算点亮。
    @State private var pending: String?
    @State private var busy = false
    /// 核对失败开口（别只靠回弹无文案）。
    @State private var failNote = ""
    private static let labels = ["action": "动作", "amount": "金额", "category": "分类", "comment": "备注", "note": "备注", "date": "日期", "account": "账户", "type": "类型",
                                 "title": "标题", "summary": "标题", "start": "开始", "end": "结束", "location": "地点", "text": "内容", "at": "时间", "due": "到期",
                                 "list": "清单", "command": "命令", "path": "文件", "file_path": "文件", "name": "名字", "to": "发给", "target": "对象"]
    private static let actions = ["add": "新建", "create": "新建", "update": "修改", "adjust": "调整", "delete": "删除", "remove": "删除", "complete": "完成"]
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if item.entries.count > 1 {
                ForEach(Array(item.entries.enumerated()), id: \.offset) { _, e in
                    Label(e["summary"].string, systemImage: e["state"].string == "failed" ? "xmark.circle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(e["state"].string == "failed" ? Palette.danger : Palette.textSecondary).lineLimit(1)
                }
            } else if let e = item.entries.first {
                let detail = e["detail"].object.sorted { $0.key < $1.key }
                ForEach(detail, id: \.key) { k, v in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(Self.labels[k] ?? k).font(.caption).foregroundStyle(Palette.textTertiary).frame(width: 34, alignment: .leading)
                        Text(k == "action" ? Self.actions[v.string] ?? v.string : v.string).font(k == "command" ? TypeScale.code : .caption).foregroundStyle(Palette.textPrimary).lineLimit(3).textSelection(.enabled)
                    }
                }
                if detail.isEmpty { Text("这条较早，只记了一句摘要。").font(.caption).foregroundStyle(Palette.textTertiary) }
            }
            if let source = item.entries.first?["source"].string, !source.isEmpty {
                Text("你当时说：" + source).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(3)
            }
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                    .accessibilityIdentifier("feed-verdict-fail")
            }
            HStack(spacing: Space.sm) {
                verdict("做成了", "done", tone: .success)
                verdict("没做成", "not_done", tone: .neutral)
                verdict("做错了", "wrong", tone: .danger)
                Spacer(minLength: 0)
                Button {
                    // 标错 + 回对话改：草稿优先进 Com；标错失败也不挡改。
                    guard !busy else { return }
                    busy = true
                    failNote = ""
                    pending = "wrong"
                    Task {
                        for e in item.entries { _ = await model.activityVerdict(e["key"].string, "wrong") }
                        model.draft = "刚才「\(item.title)」做错了，"
                        model.tab = .chat
                        dismiss()
                        busy = false
                    }
                } label: { Label("让它改", systemImage: "arrow.uturn.backward").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.accentText)
                    .disabled(busy)
                    .accessibilityIdentifier("feed-fix")
            }
            .padding(.top, 2)
        }
        .padding(Space.md)
        .background(Palette.fill.opacity(0.6), in: .rect(cornerRadius: Radius.sm, style: .continuous))
    }
    private func verdict(_ title: String, _ value: String, tone: Tone) -> some View {
        let server = item.entries.first?["verdict"].string
        let on = pending == value || (pending == nil && server == value)
        return Button {
            guard !busy else { return }
            busy = true
            failNote = ""
            pending = value
            Task {
                var ok = true
                for e in item.entries {
                    if !(await model.activityVerdict(e["key"].string, value)) { ok = false }
                }
                // 全部失败才回弹 + 开口；部分成功保留选中，等 feed 双刷对齐。
                if !ok {
                    pending = nil
                    failNote = "核对没成——还可以再点。不会假装已标好。"
                }
                busy = false
            }
        } label: {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(on ? .white : tone.color)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(on ? tone.color : tone.color.opacity(0.1), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier("feed-verdict-" + value)
    }
}

/// 「N 条新动态 ↑」浮动药丸（页面开着时有新动态才出）。
private struct NewPill: View {
    let count: Int
    let action: () -> Void
    var body: some View {
        Button {
            Haptics.selection(); action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                Text("\(count) 条新动态").font(TypeScale.footnote.weight(.semibold)).contentTransition(.numericText())
            }
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, Space.md).padding(.vertical, 8)
            .background(Palette.accent, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("feed-new-pill")
    }
}
