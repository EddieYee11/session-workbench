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
    var away: TimeInterval = 0
    var replyIDs: [String] = []
    var proactive = 0
    var finished: [String] = []
    var waiting = 0
    var waitingTip: String?
    var running = 0
    var eventTime = ""
    var eventTitle = ""
    /// 手动下拉且无新动静时的一行兜底文案。
    var quietFallback = false

    var hasNews: Bool { !quietFallback && (!replyIDs.isEmpty || !finished.isEmpty || waiting > 0 || !eventTitle.isEmpty) }

    static let awayThreshold: TimeInterval = 30 * 60

    @MainActor
    static func build(_ model: AppModel, since: Double, now: Date = Date()) -> ChatBrief {
        var brief = ChatBrief()
        let nowTs = now.timeIntervalSince1970
        brief.away = since > 0 ? nowTs - since : .infinity
        // 首次（从没记过）只看最近 12 小时，免得把整段历史当「新」。
        let floor = since > 0 ? since : nowTs - 12 * 3600
        let replies = model.conversation.messages.filter {
            $0["role"].string == "assistant" && $0["status"].string == "completed" && $0["created_at"].double > floor
        }
        brief.replyIDs = replies.map(\.id)
        brief.proactive = replies.filter { $0["request_id"].string.hasPrefix("task-result:") }.count
        let cases = model.casesData["items"].array.filter { $0["kind"].string != "turn" }
        brief.finished = cases.filter { $0["state"].string == "done" && $0["updated_at"].double > floor }.map { $0["title"].string }.filter { !$0.isEmpty }
        brief.running = cases.filter { ["running", "queued"].contains($0["state"].string) }.count
        brief.waiting = model.waitingInboxCount
        brief.waitingTip = ChatAttentionHint.topWaitingTitle(model)
        let soon = model.todayData["events"].array
            .filter { !$0["all_day"].bool && !$0["informational"].bool && $0["start"].double > nowTs && $0["start"].double < nowTs + 4 * 3600 }
            .min { $0["start"].double < $1["start"].double }
        if let soon {
            brief.eventTime = clockTime(soon["start"].double)
            brief.eventTitle = soon["title"].string
        }
        return brief
    }

    var awayLabel: String {
        if away == .infinity { return "有一阵" }
        let minutes = Int(away / 60)
        if minutes < 60 { return "\(max(1, minutes)) 分钟" }
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
    @State private var cardHeight: CGFloat = 180
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
            // 把手下面一段渐进虚化 + 压暗（参考：贴着胶囊的两三行糊、暗，往下 120pt 就清楚了），跟着卡底边走。
            if p > 0.001 && !reduce { haze }

            if p > 0.001 { card }
            if p > 0.001 || docked { handle }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(expanded || docked)
        .onAppear { evaluate(after: .milliseconds(450)) }
        .onChange(of: model.active) { _, active in
            if active { evaluate(after: .milliseconds(700)) } else { markSeen(); reset() }
        }
        .onChange(of: model.tab) { old, new in
            // 双栏时左栏固定是主聊天，右栏换页不算离开。
            if model.splitView { return }
            if new == .chat { evaluate(after: .milliseconds(350)) }
            else if old == .chat { markSeen(); reset() }
        }
        .onChange(of: model.splitView) { _, _ in
            if !model.isChatBriefVisible { markSeen(); reset() }
            else if model.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-chat-brief") {
                evaluate(after: .milliseconds(250))
            }
        }
        .onChange(of: model.boardFocus) { _, _ in
            if !model.isChatBriefVisible { markSeen(); reset() }
        }
        .onChange(of: model.lastSubmittedID) { _, _ in if expanded || docked { collapse(dockAfter: false) } }
        .onChange(of: model.draft.isEmpty) { _, empty in if !empty && expanded { collapse() } }
        .onChange(of: dragging) { _, now in
            // 正常松手 onEnded 已把 dragStart 清掉；还留着说明手势被取消，按当前位置结算。
            guard !now, let start = dragStart else { return }
            dragStart = nil
            let threshold: CGFloat = start >= 0.5 ? 0.65 : 0.35
            DispatchQueue.main.async { model.briefProgress < threshold ? collapse() : expand() }
        }
        .onChange(of: model.briefProgress) { _, progress in
            if progress > 0 { evalTask?.cancel() }
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
        .onChange(of: cardHeight) { _, h in if h > 40 { model.briefDragHeight = h } }
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
        let band: CGFloat = 150
        return Rectangle().fill(.ultraThinMaterial)
            .overlay(Palette.background.opacity(0.55))
            .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
            .frame(height: band)
            .offset(y: max(0, visibleHeight - 24))
            .opacity(Double(shown))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let h = visibleHeight
        // 收到最后 140→90pt 才整体模糊淡出；之前字不动、不变淡，只被底边一行行吃掉。
        let fade = min(1, max(0, (h - 90) / 50))
        return content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 40 { cardHeight = $0 } }
            // 底边 18pt 柔边：碰到底边的那一行半截糊掉，上面几行保持清楚。
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle().frame(height: max(0, h - 18))
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    Spacer(minLength: 0)
                }
            }
            .blur(radius: reduce ? 0 : 10 * (1 - fade))
            .opacity(Double(fade))
            .frame(height: max(0, h), alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
            .clipShape(shape)
            .background(Palette.accent, in: shape)
            .shadow(color: .black.opacity(0.22 * Double(shown)), radius: 18, y: 10)
            // 收到最后 12% 时整卡淡掉，像被顶栏吸回去。
            .opacity(Double(min(1, p / 0.12)))
            .padding(.horizontal, Space.sm)
            .contentShape(shape)
            .gesture(drag)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-brief-card")
            .accessibilityAction(named: "收起简报") { collapse() }
    }

    private var content: some View {
        let lines = sentence
        return VStack(alignment: .leading, spacing: Space.md) {
            lines
                .font(.system(size: 20, weight: .semibold))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat-brief-text")
            if !brief.quietFallback {
                BriefDots().stroke(Palette.onAccent.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 4]))
                    .frame(height: 1.5)
                meta
            }
        }
        .padding(.horizontal, Space.lg + 2)
        .padding(.top, Space.md + 2)
        .padding(.bottom, Space.md + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一句话：灰的是铺垫，黑粗的是要点，图标夹在字里（参考里的头像 / 日历角标）。
    private var sentence: Text {
        if brief.quietFallback {
            return Text("这几个小时没什么新动静").foregroundStyle(Palette.onAccent).fontWeight(.semibold)
        }
        let ink = Palette.onAccent
        let soft = Palette.onAccent.opacity(0.5)
        func s(_ t: String) -> Text { Text(t).foregroundStyle(soft) }
        func b(_ t: String) -> Text { Text(t).foregroundStyle(ink).fontWeight(.bold) }
        func i(_ symbol: String) -> Text { Text(Image(systemName: symbol)).foregroundStyle(ink).font(.system(size: 16, weight: .bold)) }
        var parts: [Text] = [s("Eddie，你离开了 "), b(brief.awayLabel), s("。")]
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
        return parts.dropFirst().reduce(parts[0]) { Text("\($0)\($1)") }
    }

    /// 参考卡底部那行「3 hours ago · 📎12 · 💬7」：这里每个数都能点，点了先收卡再去。
    private var meta: some View {
        HStack(spacing: Space.md) {
            Text(brief.awayLabel + "前").font(TypeScale.footnote).foregroundStyle(Palette.onAccent.opacity(0.55))
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
            Spacer(minLength: 0)
        }
    }

    private func metaChip(_ symbol: String, _ text: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            collapse(dockAfter: false)
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(text).font(TypeScale.footnote.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, Space.sm).frame(height: 28)
            .background(Palette.onAccent.opacity(0.08), in: .capsule)
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

    private var dragDivisor: CGFloat { max(120, cardHeight) }

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
                DispatchQueue.main.async {
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
    }

    // MARK: 状态

    private func evaluate(after delay: Duration) {
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
            let next = ChatBrief.build(model, since: since)
            guard forced || (next.hasNews && next.away >= ChatBrief.awayThreshold), !model.conversation.messages.isEmpty || forced else { return }
            guard !Task.isCancelled, !expanded, model.briefProgress == 0, !dragging, dragStart == nil else { return }
            model.chatBrief = next
            expand()
            #if DEBUG
            // 截图验收用：展开 2.5s 后自动收起，看停靠态。
            if forced && ProcessInfo.processInfo.arguments.contains("--ui-chat-brief-collapse") {
                try? await Task.sleep(for: .milliseconds(2500))
                guard !Task.isCancelled else { return }
                collapse()
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
