import SwiftUI
import ComCore

// 主聊天「回来简报」：参考 x.com/craft_120/status/2117172944564896018（Tickr 蓝卡）。
// 离开一阵再回到 Com，顶栏下面垂下一张青柠色简报卡，一句话说清「你不在时发生了什么」；
// 卡下挂一颗把手胶囊，往上拖跟手收回顶栏，松手按位置 + 速度决定开合；收起后胶囊停在顶栏下一会儿，可再拉开。
// 顶栏往下拉玩偶也会拉开同一张卡（开合状态在 AppModel.briefProgress / briefExpanded）。
// 展现逻辑（真源在这里，别散到 ChatView）：
//   出现：进入主聊天 / 回到前台，且距上次看聊天 ≥ 30 分钟，且有「新回复 / 做完的航程 / 等你 / 4 小时内日程」之一。
//   收起：拖把手或卡片往上、点把手、点卡外、开始打字或发出消息、点卡里的去处。收起即记已读（seenAt）。
//   胶囊：收起后停 12 秒再淡出；离开主聊天或切后台时把 seenAt 记成此刻。

/// 简报内容：只用 App 已有的数据拼，不新增后端接口。
struct ChatBrief: Equatable {
    struct BriefItem: Identifiable, Equatable {
        enum Target: Equatable {
            case waiting
            case reply(String)
            case doing
            case next
            case work
            case finance
            case connectors
        }
        let id: String
        let symbol: String
        let tag: String
        let title: String
        let badge: String
        let target: Target
    }

    var away: TimeInterval = 0
    var manual = false
    var isRefreshing = false
    var replyIDs: [String] = []
    var proactive = 0
    var latestReplyID: String?
    var latestReplyPreview = ""
    var finished: [String] = []
    var waiting = 0
    var waitingTip: String?
    var running = 0
    var nextUrgent = 0
    var nextTip: String?
    var eventTime = ""
    var eventTitle = ""
    var monthSpendLabel = ""
    var items: [BriefItem] = []
    /// 保留字段兼容旧判断；下拉简报现统一展示高密度实时工作台速览。
    var quietFallback = false

    var hasNews: Bool { !quietFallback && (!replyIDs.isEmpty || !finished.isEmpty || waiting > 0 || !eventTitle.isEmpty) }

    static let awayThreshold: TimeInterval = 30 * 60

    @MainActor
    static func build(_ model: AppModel, since: Double, manual: Bool = false, now: Date = Date()) -> ChatBrief {
        var brief = ChatBrief()
        brief.manual = manual
        let nowTs = now.timeIntervalSince1970
        brief.away = since > 0 ? max(0, nowTs - since) : .infinity
        // 首次（从没记过）只看最近 12 小时，免得把整段历史当「新」。
        let floor = since > 0 ? since : nowTs - 12 * 3600
        let allAssistant = model.conversation.messages.filter {
            $0["role"].string == "assistant" && ($0["status"].string == "completed" || $0["status"].string.isEmpty)
        }
        let replies = allAssistant.filter { $0["created_at"].double > floor }
        brief.replyIDs = replies.map(\.id)
        brief.proactive = replies.filter { $0["request_id"].string.hasPrefix("task-result:") }.count
        if let latest = (replies.last ?? allAssistant.last) {
            brief.latestReplyID = latest.id
            brief.latestReplyPreview = cleanPreview(latest)
        }

        let cases = model.casesData["items"].array.filter { $0["kind"].string != "turn" }
        brief.finished = cases.filter { $0["state"].string == "done" && $0["updated_at"].double > floor }.map { $0["title"].string }.filter { !$0.isEmpty }
        let activeCases = cases.filter { ["running", "queued", "dispatching"].contains($0["state"].string) }
        brief.running = activeCases.count + model.runningTasks.count
        brief.waiting = model.waitingInboxCount
        brief.waitingTip = ChatAttentionHint.topWaitingTitle(model)
        brief.nextUrgent = model.nextUrgentCount
        brief.nextTip = ChatAttentionHint.topNextTitle(model)

        let rawEvents = model.todayData["events"].array.isEmpty
            ? (model.datasets["/personal/today"]?["events"].array ?? [])
            : model.todayData["events"].array
        let upcomingToday = rawEvents
            .filter { !$0["all_day"].bool && !$0["informational"].bool && $0["start"].double > nowTs }
            .sorted { $0["start"].double < $1["start"].double }
        if let soon = upcomingToday.first(where: { $0["start"].double < nowTs + 4 * 3600 }) ?? (manual ? upcomingToday.first : nil) {
            brief.eventTime = clockTime(soon["start"].double)
            brief.eventTitle = soon["title"].string
        }

        let money = model.datasets["/personal/finance"]?["currencies"].array.first ?? .null
        if !money.isNull, money["month_minor"].double > 0 {
            let month = Calendar.current.component(.month, from: now)
            let spent = (money["month_minor"].double / 100).formatted(.number.precision(.fractionLength(0)))
            brief.monthSpendLabel = "\(month)月 ¥\(spent)"
        }

        // 组装高密度速览条目（最多 4 行，点击直达）
        var rows: [BriefItem] = []

        // 1. 等你拍板（审批 / 待验收任务 / waiting 汇总）
        let activeFlow = model.flowItems.filter { !$0.stale }
        for item in activeFlow.prefix(2) {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            rows.append(BriefItem(
                id: "wait-\(item.id)",
                symbol: item.symbol,
                tag: "拍板",
                title: title,
                badge: item.stamp,
                target: .waiting
            ))
        }
        if rows.isEmpty, brief.waiting > 0 {
            let waitItems = model.waitingData["items"].array
            if let firstWait = waitItems.first, !firstWait["title"].string.isEmpty {
                rows.append(BriefItem(
                    id: "wait-api-0",
                    symbol: "hand.raised.fill",
                    tag: "等你",
                    title: firstWait["title"].string,
                    badge: brief.waiting > 1 ? "共 \(brief.waiting) 件" : "待处理",
                    target: .waiting
                ))
            } else if let tip = brief.waitingTip, !tip.isEmpty {
                rows.append(BriefItem(
                    id: "wait-tip",
                    symbol: "hand.raised.fill",
                    tag: "等你",
                    title: tip,
                    badge: "\(brief.waiting) 件",
                    target: .waiting
                ))
            }
        }

        // 2. 正在跑的任务 / 航程，或刚做完的交付
        if let firstTask = model.runningTasks.first, !firstTask["title"].string.isEmpty {
            rows.append(BriefItem(
                id: "run-task-\(firstTask.id)",
                symbol: "bolt.horizontal.circle.fill",
                tag: "在跑",
                title: firstTask["title"].string,
                badge: brief.running > 1 ? "\(brief.running) 项并行" : agentName(firstTask["agent"].string),
                target: .doing
            ))
        } else if let firstCase = activeCases.first, !firstCase["title"].string.isEmpty {
            rows.append(BriefItem(
                id: "run-case-\(firstCase.id)",
                symbol: "location.north.line.fill",
                tag: "航程",
                title: firstCase["title"].string,
                badge: brief.running > 1 ? "\(brief.running) 段在跑" : "进行中",
                target: .doing
            ))
        }
        if let firstDone = brief.finished.first, rows.count < 4 {
            rows.append(BriefItem(
                id: "done-0",
                symbol: "checkmark.circle.fill",
                tag: "刚完",
                title: firstDone,
                badge: brief.finished.count > 1 ? "等 \(brief.finished.count) 段" : "已完成",
                target: .doing
            ))
        }

        // 3. 今日下一档日程
        if let nextEv = upcomingToday.first, !nextEv["title"].string.isEmpty, rows.count < 4 {
            rows.append(BriefItem(
                id: "event-0",
                symbol: "calendar",
                tag: "日程",
                title: nextEv["title"].string,
                badge: clockTime(nextEv["start"].double),
                target: .doing
            ))
        }

        // 4. 下一步紧要事项 / 主动建议
        if rows.count < 4 {
            if let tip = brief.nextTip, !tip.isEmpty {
                rows.append(BriefItem(
                    id: "next-tip",
                    symbol: "arrow.right.circle.fill",
                    tag: "下一步",
                    title: tip,
                    badge: brief.nextUrgent > 0 ? "\(brief.nextUrgent) 件急" : "待办",
                    target: .next
                ))
            } else if let card = model.agencyCards.first, !card["title"].string.isEmpty {
                rows.append(BriefItem(
                    id: "agency-0",
                    symbol: "sparkles",
                    tag: "建议",
                    title: card["title"].string,
                    badge: "去看看",
                    target: .next
                ))
            }
        }

        // 5. 最新回复预览（方便一键跳回那条消息）
        if rows.count < 4, let replyID = brief.latestReplyID, !brief.latestReplyPreview.isEmpty {
            rows.append(BriefItem(
                id: "reply-latest",
                symbol: "bubble.left.fill",
                tag: brief.replyIDs.isEmpty ? "上条" : "新回",
                title: brief.latestReplyPreview,
                badge: brief.replyIDs.isEmpty ? "跳去读" : "\(brief.replyIDs.count) 条",
                target: .reply(replyID)
            ))
        }

        // 6. 信源告警或月度账本兜底，保证拉开卡片永远信息饱满
        if rows.count < 4, let broken = model.brokenSources.first {
            let name = sourceName(broken["name"].string)
            rows.append(BriefItem(
                id: "broken-0",
                symbol: "exclamationmark.triangle.fill",
                tag: "信源",
                title: "\(name)连接中断，点此重新授权",
                badge: "待修复",
                target: .connectors
            ))
        }
        if rows.count < 3, !brief.monthSpendLabel.isEmpty {
            let topCat = money["categories"].array.first
            let catDesc = topCat != nil && !topCat!["name"].string.isEmpty
                ? "最大头：\(topCat!["name"].string)"
                : "点此核对近期收支明细"
            rows.append(BriefItem(
                id: "finance-0",
                symbol: "creditcard.fill",
                tag: "账本",
                title: catDesc,
                badge: brief.monthSpendLabel,
                target: .finance
            ))
        }

        brief.items = Array(rows.prefix(4))
        return brief
    }

    private static func cleanPreview(_ msg: JSON) -> String {
        let raw = [msg["text"].string, msg["content"].string, msg["summary"].string]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 34 { return oneLine }
        return String(oneLine.prefix(33)) + "…"
    }

    var awayLabel: String {
        if away == .infinity { return "有一阵" }
        let minutes = Int(away / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时" }
        return "\(hours / 24) 天"
    }
}

/// 参考卡底那条点状分隔线。
private struct BriefDots: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// 卡片 + 把手 + 背后的压暗。progress 由 AppModel.briefProgress 驱动。
struct ChatBriefOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("chat.brief.seenAt") private var seenAt: Double = 0
    @State private var docked = false
    @State private var cardHeight: CGFloat = 220
    @State private var dragStart: CGFloat?
    /// 手势被系统取消（手指拖出把手范围、来电等）时不会走 onEnded；靠它复位后照常结算开合。
    @GestureState private var dragging = false
    @State private var dockTask: Task<Void, Never>?
    @State private var evalTask: Task<Void, Never>?

    private var p: CGFloat { max(0, model.briefProgress) }
    private var shown: CGFloat { min(1, p) }
    private var visibleHeight: CGFloat { cardHeight * p }
    private var brief: ChatBrief { model.chatBrief }
    private var expanded: Bool { model.briefExpanded }

    var body: some View {
        ZStack(alignment: .top) {
            // 卡外：点一下收起。只在展开时接触摸，收起后完全让给列表。
            Color.clear
                .contentShape(Rectangle())
                .allowsHitTesting(expanded)
                .onTapGesture { collapse() }
                .accessibilityHidden(true)
            // 卡底柔和暗影过渡（不用 ultraThinMaterial 高斯模糊层，避免竖屏下拉时对下方聊天产生模糊残影）。
            if p > 0.001 && !reduce { haze }

            if p > 0.001 { card }
            if p > 0.001 || docked { handle }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(expanded || docked)
        .onAppear { evaluate(after: .milliseconds(150)) }
        .onChange(of: model.active) { _, active in
            if active { evaluate(after: .milliseconds(250)) } else { markSeen(); reset() }
        }
        .onChange(of: model.tab) { old, new in
            // 双栏时左栏固定是主聊天，右栏换页不算离开。
            if model.splitView { return }
            if new == .chat { evaluate(after: .milliseconds(150)) }
            else if old == .chat { markSeen(); reset() }
        }
        .onChange(of: model.splitView) { _, _ in
            if !model.isChatBriefVisible { markSeen(); reset() }
            else if model.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-chat-brief") {
                evaluate(after: .milliseconds(150))
            }
        }
        .onChange(of: model.boardFocus) { _, _ in
            if !model.isChatBriefVisible { markSeen(); reset() }
        }
        .onChange(of: model.lastSubmittedID) { _, _ in if expanded || docked { collapse(dockAfter: false) } }
        .onChange(of: model.draft.isEmpty) { _, empty in if !empty && expanded { collapse() } }
        .onChange(of: model.waitingInboxCount) { _, _ in
            if expanded || p > 0.01 { model.rebuildChatBrief(manual: brief.manual) }
        }
        .onChange(of: model.conversation.messages.count) { _, _ in
            if expanded || p > 0.01 { model.rebuildChatBrief(manual: brief.manual) }
        }
        .onChange(of: model.flowItems.count) { _, _ in
            if expanded || p > 0.01 { model.rebuildChatBrief(manual: brief.manual) }
        }
        .onChange(of: model.nextUrgentCount) { _, _ in
            if expanded || p > 0.01 { model.rebuildChatBrief(manual: brief.manual) }
        }
        .onChange(of: dragging) { _, now in
            // SwiftUI 的 @GestureState 复位早于 .onEnded；延迟 50ms 仅在系统真正打断手势时兜底结算。
            guard !now else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard !dragging, let start = dragStart else { return }
                dragStart = nil
                let delta = (model.briefProgress - start) * dragDivisor
                model.settleBriefFromHandle(start: start, translation: delta, predictedEnd: delta)
            }
        }
        .onChange(of: model.briefProgress) { _, progress in
            if progress > 0, !expanded { evalTask?.cancel() }
        }
        .onChange(of: model.briefExpanded) { _, open in
            if open {
                dockTask?.cancel()
                docked = false
            } else {
                markSeen()
                startDock(model.briefDockAfterClose)
            }
        }
        .onChange(of: cardHeight) { _, h in if h > 50 { model.briefDragHeight = h } }
        .onDisappear {
            evalTask?.cancel()
            dockTask?.cancel()
            #if DEBUG
            // 折叠屏宽窄一切换会重建左栏，onDisappear 晚于新 onAppear 会把刚展开的验收简报清掉。
            if model.isUITesting,
               ProcessInfo.processInfo.arguments.contains("--ui-chat-brief"),
               !ProcessInfo.processInfo.arguments.contains("--ui-chat-brief-collapse") { return }
            #endif
            if expanded || p > 0 { markSeen() }
            reset()
        }
    }

    // MARK: 卡片

    private var haze: some View {
        let band: CGFloat = 56
        return LinearGradient(
            colors: [Palette.background.opacity(0.68), Palette.background.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: band)
        .offset(y: max(0, visibleHeight - 12))
        .opacity(Double(shown))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let h = visibleHeight
        // 用归一化进度 p 控制淡入/收起，且展开态或下拉 >= 45% 时严禁任何高斯模糊。
        let fade: CGFloat = (expanded || p >= 0.45) ? 1.0 : min(1, max(0, (p - 0.08) / 0.37))
        let blurRadius: CGFloat = (reduce || expanded || p >= 0.45) ? 0 : 5 * (1 - fade)
        let softEdge: CGFloat = (expanded || p >= 0.96) ? 0 : min(16, max(0, h))
        return content
            // 关键：先固定垂直理想尺寸再测高，防止下拉初段小 frame(height: h) 压扁 VStack 导致 cardHeight 锁死在 ~95pt。
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                if newHeight > 50 {
                    cardHeight = newHeight
                    model.briefDragHeight = newHeight
                }
            }
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle().frame(height: max(0, h - softEdge))
                    if softEdge > 0 {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: softEdge)
                    }
                    Spacer(minLength: 0)
                }
            }
            .blur(radius: blurRadius)
            .opacity(Double(fade))
            .frame(height: max(0, h), alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
            .clipShape(shape)
            .background(Palette.accent, in: shape)
            .shadow(color: .black.opacity(0.22 * Double(shown)), radius: 18, y: 10)
            // 收到最后 10% 时整卡淡掉，像被顶栏吸回去。
            .opacity(Double(min(1, p / 0.10)))
            .padding(.horizontal, Space.sm)
            .contentShape(shape)
            .gesture(drag)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-brief-card")
            .accessibilityAction(named: "收起简报") { collapse() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.sm + 2) {
            HStack(alignment: .top, spacing: Space.sm) {
                sentence
                    .font(.system(size: 16, weight: .semibold))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat-brief-text")
                refreshButton
            }
            if !brief.items.isEmpty {
                VStack(spacing: 5) {
                    ForEach(brief.items) { item in
                        briefRow(item)
                    }
                }
            }
            BriefDots().stroke(Palette.onAccent.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 4]))
                .frame(height: 1.5)
            meta
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .padding(.bottom, Space.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var refreshButton: some View {
        Button {
            Haptics.selection()
            model.rebuildChatBrief(manual: true)
            model.triggerBriefRefresh()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.onAccent.opacity(brief.isRefreshing ? 0.9 : 0.65))
                .rotationEffect(.degrees(brief.isRefreshing ? 360 : 0))
                .animation(
                    brief.isRefreshing && !reduce
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                    value: brief.isRefreshing
                )
                .frame(width: 26, height: 26)
                .background(Palette.onAccent.opacity(0.08), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(SoftPressStyle(scale: 0.92))
        .accessibilityLabel(brief.isRefreshing ? "正在刷新简报" : "刷新简报")
        .accessibilityIdentifier("chat-brief-refresh")
    }

    private func briefRow(_ item: ChatBrief.BriefItem) -> some View {
        Button {
            Haptics.selection()
            collapse(dockAfter: false)
            navigate(item.target)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 14)
                Text(item.tag)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Palette.onAccent.opacity(0.12), in: .capsule)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.onAccent)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.badge.isEmpty {
                    Text(item.badge)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Palette.onAccent.opacity(0.68))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.onAccent.opacity(0.45))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.onAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SoftPressStyle(scale: 0.97))
    }

    private func navigate(_ target: ChatBrief.BriefItem.Target) {
        switch target {
        case .waiting:
            model.openWaitingInbox()
        case .reply(let messageID):
            model.jumpMessage = messageID
        case .doing:
            model.tab = .doing
        case .next:
            model.tab = .next
        case .work:
            model.tab = .work
        case .finance:
            model.openFinance()
        case .connectors:
            model.openConnectors()
        }
    }

    /// 一句话：灰的是铺垫，黑粗的是要点，图标夹在字里（参考里的头像 / 日历角标）。
    private var sentence: Text {
        let ink = Palette.onAccent
        let soft = Palette.onAccent.opacity(0.55)
        func s(_ t: String) -> Text { Text(t).foregroundStyle(soft) }
        func b(_ t: String) -> Text { Text(t).foregroundStyle(ink).fontWeight(.bold) }
        func i(_ symbol: String) -> Text { Text(Image(systemName: symbol)).foregroundStyle(ink).font(.system(size: 14, weight: .bold)) }

        var parts: [Text] = brief.awayLabel == "刚刚"
            ? [s("Eddie，"), b("刚刚"), s("看过对话。")]
            : [s("Eddie，你离开了 "), b(brief.awayLabel), s("。")]

        if !brief.replyIDs.isEmpty {
            parts += [s("我回了 "), i("bubble.left.fill"), b(" \(brief.replyIDs.count) 条")]
            parts.append(s(brief.proactive > 0 ? "（\(brief.proactive) 条是我主动说的）。" : "。"))
        }
        if let first = brief.finished.first {
            parts += [s("航程 "), i("location.north.line.fill"), b(" 「\(clip(first, 14))」"), s(brief.finished.count > 1 ? " 等 \(brief.finished.count) 段做完了。" : " 做完了。")]
        }
        if brief.waiting > 0 {
            parts += [s("有 "), i("hand.raised.fill"), b(" \(brief.waiting) 件等你拍板")]
            parts.append(s(brief.waitingTip.map { "，先看「\(clip($0, 12))」。" } ?? "。"))
        }
        if !brief.eventTitle.isEmpty {
            parts += [b(brief.eventTime), s(" 有 "), i("calendar"), b(" 「\(clip(brief.eventTitle, 12))」"), s("。")]
        }
        if !brief.hasNews {
            if brief.running > 0 {
                parts += [s("后台有 "), i("bolt.horizontal.circle.fill"), b(" \(brief.running) 项"), s("正在推进。")]
            } else if brief.nextUrgent > 0 {
                parts += [s("「下一步」有 "), i("arrow.right.circle.fill"), b(" \(brief.nextUrgent) 件"), s("要紧事。")]
            } else {
                parts += [s("眼下无积压审批，点下方直达各模块。")]
            }
        }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0)\($1)") }
    }

    /// 参考卡底部那行「3 hours ago · 📎12 · 💬7」：这里每个数都能点，点了先收卡再去。
    private var meta: some View {
        HStack(spacing: Space.sm) {
            Text(brief.awayLabel == "刚刚" ? "实时" : brief.awayLabel + "前")
                .font(TypeScale.footnote)
                .foregroundStyle(Palette.onAccent.opacity(0.55))
            if !brief.replyIDs.isEmpty {
                metaChip("bubble.left", "\(brief.replyIDs.count)", id: "chat-brief-replies") {
                    if let first = brief.replyIDs.first { model.jumpMessage = first }
                }
            }
            if brief.waiting > 0 {
                metaChip("hand.raised", "\(brief.waiting)", id: "chat-brief-waiting") { model.openWaitingInbox() }
            }
            if brief.running > 0 {
                metaChip("play.circle", "\(brief.running)", id: "chat-brief-running") { model.tab = .doing }
            }
            if !brief.eventTitle.isEmpty {
                metaChip("calendar", brief.eventTime, id: "chat-brief-event") { model.tab = .doing }
            }
            if brief.nextUrgent > 0 {
                metaChip("arrow.right.circle", "\(brief.nextUrgent)", id: "chat-brief-next") { model.tab = .next }
            }
            if brief.replyIDs.isEmpty && brief.waiting == 0 && brief.running == 0 && brief.eventTitle.isEmpty {
                metaChip("arrow.right.circle", "下一步", id: "chat-brief-next") { model.tab = .next }
                metaChip("checklist", "在办", id: "chat-brief-doing") { model.tab = .doing }
            }
            Spacer(minLength: 0)
            if !brief.monthSpendLabel.isEmpty {
                metaChip("creditcard", brief.monthSpendLabel, id: "chat-brief-finance") { model.openFinance() }
            }
        }
    }

    private func metaChip(_ symbol: String, _ text: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            collapse(dockAfter: false)
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(text).font(TypeScale.footnote.weight(.semibold).monospacedDigit()).lineLimit(1)
            }
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, Space.sm).frame(height: 26)
            .background(Palette.onAccent.opacity(0.09), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(SoftPressStyle(scale: 0.94))
        .accessibilityIdentifier(id)
    }

    // MARK: 把手胶囊

    /// 左「简报」右「对话」，亮的那一格跟着开合滑过去；挂在卡下沿 10pt，收起后停在顶栏下。
    private var handle: some View {
        let open = p > 0.5
        return Button {
            Haptics.selection()
            if expanded { collapse() } else { expand() }
        } label: {
            HStack(spacing: 0) {
                glyph("text.alignleft", lit: open)
                glyph("bubble.left.fill", lit: !open)
            }
            .padding(3)
            .background(alignment: open ? .leading : .trailing) {
                Capsule().fill(Palette.textPrimary.opacity(0.12)).frame(width: 34).padding(3)
            }
            .floatingGlass(.capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(SoftPressStyle(scale: 0.92))
        .simultaneousGesture(drag)
        .offset(y: max(Space.xs, visibleHeight + 10))
        .opacity(docked || p > 0.04 ? 1 : 0)
        .animation(reduce ? nil : ComMotion.snap, value: open)
        .accessibilityLabel(expanded ? "收起简报" : "展开简报")
        .accessibilityIdentifier("chat-brief-handle")
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    private func glyph(_ symbol: String, lit: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(lit ? Palette.textPrimary : Palette.textTertiary)
            .frame(width: 34, height: 26)
    }

    // MARK: 手势：跟手 + 橡皮筋，松手按落点和速度

    private var dragDivisor: CGFloat { model.briefPullDistance }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                evalTask?.cancel()
                if dragStart == nil { dragStart = p; dockTask?.cancel() }
                let next = (dragStart ?? 0) + value.translation.height / dragDivisor
                model.dragBrief(to: max(0, next))
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                dragStart = nil
                model.settleBriefFromHandle(
                    start: start,
                    translation: value.translation.height,
                    predictedEnd: value.predictedEndTranslation.height
                )
                if !model.briefExpanded && docked {
                    startDock(true)
                }
            }
    }

    // MARK: 状态

    private func evaluate(after delay: Duration) {
        guard !expanded else { return }
        evalTask?.cancel()
        evalTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  model.isChatBriefVisible,
                  model.active || model.isUITesting,
                  !expanded,
                  model.briefProgress == 0,
                  !dragging,
                  dragStart == nil else { return }
            let forced = model.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-chat-brief")
            let since = forced ? Date().timeIntervalSince1970 - 3 * 3600 : seenAt
            let next = ChatBrief.build(model, since: since, manual: forced)
            guard forced || (next.hasNews && next.away >= ChatBrief.awayThreshold), !model.conversation.messages.isEmpty || forced else { return }
            guard !Task.isCancelled, !expanded, model.briefProgress == 0, !dragging, dragStart == nil else { return }
            model.chatBrief = next
            expand()
            #if DEBUG
            // 截图验收用：展开 2.5s 后自动收起，看停靠态。
            if forced && ProcessInfo.processInfo.arguments.contains("--ui-chat-brief-collapse") {
                evalTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(2500))
                    guard !Task.isCancelled, expanded else { return }
                    collapse()
                }
            }
            #endif
        }
    }

    private func expand() {
        evalTask?.cancel()
        dockTask?.cancel()
        docked = false
        model.openBrief()
    }

    private func startDock(_ dockAfter: Bool) {
        dockTask?.cancel()
        docked = dockAfter
        guard dockAfter else { return }
        dockTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, !expanded else { return }
            withAnimation(ComMotion.reduced(reduce, ComMotion.crossfade)) { docked = false }
        }
    }

    private func collapse(dockAfter: Bool = true) {
        evalTask?.cancel()
        markSeen()
        startDock(dockAfter)
        model.closeBrief(dockAfter: dockAfter)
    }

    private func reset() {
        evalTask?.cancel()
        dockTask?.cancel()
        docked = false
        model.briefExpanded = false
        model.briefProgress = 0
    }

    private func markSeen() { seenAt = Date().timeIntervalSince1970 }

    private func clip(_ text: String, _ n: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }
}
