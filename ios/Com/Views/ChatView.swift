import SwiftUI
import ComCore
import Textual
import UniformTypeIdentifiers
import PhotosUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    private var reduce: Bool { systemReduce || (model.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-reduce-motion")) }
    @State private var atBottom = true
    @State private var historyLoading = false
    /// 「更早的对话」拉网失败时页内提示（本地扩窗不算失败）。
    @State private var historyFailNote = ""
    @State private var frames: [String: CGRect] = [:]
    @State private var flights: [String: OutgoingFlight] = [:]
    @State private var unread: Set<String> = []
    @State private var knownAssistants: Set<String> = []
    @State private var followKeyboard = false
    @State private var composing = false
    @State private var manuallyReading = false
    @State private var interacting = false
    @State private var followLatest = true
    @State private var timeline: [ChatTimelineRow] = []
    /// 分页按字符预算而不是条数：一屏长回复和十条短句不该占同样的内存。
    @State private var historyBudget = ChatPage.standardBudget
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var positioned = false
    @State private var viewport = ChatViewport()
    /// r2-chat：点过的建议卡所在消息（点完立刻收起，不等服务端回执）。
    @State private var usedSuggestions: String?
    /// 全部中断进行中，防连点。
    @State private var interruptingAll = false
    private var rows: [ChatTimelineRow] { ChatPage.window(timeline, budget: historyBudget) }
    private var assistants: Set<String> { Set(model.conversation.messages.filter { $0["role"].string == "assistant" }.map(\.id)) }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
            ZStack(alignment: .top) {
            VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Space.xl) {
                    if (rows.count < timeline.count || model.moreHistory) && !model.conversation.messages.isEmpty {
                        VStack(spacing: Space.sm) {
                            Button(historyLoading ? "正在读取…" : "更早的对话") {
                                guard !historyLoading else { return }
                                followLatest = false; manuallyReading = true
                                let anchor = rows.first(where: { viewport.visibleRows.contains($0.id) })?.id
                                historyLoading = true
                                historyFailNote = ""
                                Task {
                                    if rows.count < timeline.count {
                                        historyBudget += ChatPage.standardBudget
                                    } else {
                                        let ok = await model.loadHistory()
                                        if ok {
                                            historyBudget += ChatPage.standardBudget
                                        } else {
                                            historyFailNote = "更早的对话没读上——可再点一次"
                                        }
                                    }
                                    await Task.yield()
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                    historyLoading = false
                                }
                            }
                            .buttonStyle(.secondaryAction)
                            .disabled(historyLoading)
                            .accessibilityIdentifier("chat-load-history")
                            if !historyFailNote.isEmpty {
                                Label(historyFailNote, systemImage: "exclamationmark.circle")
                                    .font(TypeScale.footnote.weight(.medium))
                                    .foregroundStyle(Palette.danger)
                                    .accessibilityIdentifier("chat-history-fail")
                            }
                        }
                    }
                    if model.conversation.messages.isEmpty && rows.isEmpty {
                        ChatEmptyPresence()
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let isAgent = row.message["role"].string == "assistant"
                        let previousIsAgent = index > 0 ? rows[index - 1].message["role"].string == "assistant" : false
                        let isConsecutiveAgent = isAgent && previousIsAgent

                        // 连续的主动消息（晨晚报、提醒、回执）折成一条「N 条主动消息」，只展开最新那条，不让它们堆成一整屏字。
                        let foldsIntoNext = ProactiveMessage.matches(row.message) && index + 1 < rows.count && ProactiveMessage.matches(rows[index + 1].message)
                        let runStart = foldsIntoNext && !(index > 0 && ProactiveMessage.matches(rows[index - 1].message))
                        Group {
                            if runStart {
                                ProactiveStack(run: ProactiveMessage.run(in: rows, from: index))
                            } else if foldsIntoNext {
                                EmptyView()
                            } else {
                                MessageView(message: row.message, layoutID: row.id, flying: flights[row.id] != nil, pending: row.pending, isConsecutiveAgent: isConsecutiveAgent)
                                    .equatable()
                            }
                        }
                            .id(row.id)
                            .transition(.asymmetric(
                                insertion: reduce ? .opacity : .scale(scale: 0.96).combined(with: .offset(y: 8)).combined(with: .opacity),
                                removal: .opacity
                            ))

                    }
                    if let latest = suggestionHost, latest.id != usedSuggestions {
                        let options = ReplyOptions.options(for: latest)
                        if !options.isEmpty {
                            SuggestionChips(messageID: latest.id, options: options) { option in
                                // 先亮一下再发；送达成功才收起整组；失败芯片回弹可重试。
                                if !reduce { try? await Task.sleep(for: .milliseconds(200)) }
                                let ok = await model.send(textOverride: option)
                                if ok {
                                    withAnimation(reduce ? nil : .smooth(duration: 0.28)) { usedSuggestions = latest.id }
                                }
                                return ok
                            }
                            .id(latest.id)  // r2-chat 验收修正：新回复换一组卡片时重建状态，重新播弹入
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))))
                        }
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.scrollTargetLayout().padding(.horizontal, Layout.margin).padding(.top, Space.md).padding(.bottom, Space.md)
            }
            .accessibilityIdentifier("chat-timeline-scroll")
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .scrollPosition($scrollPosition)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.1) { viewport.visibleRows = $0 }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY < 70 } action: { _, near in
                atBottom = near
                if near {
                    unread = []
                }
            }
            .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { old, new in
                if followLatest && !interacting && old.height != new.height {
                    Task { @MainActor in
                        await Task.yield()
                        guard followLatest && !interacting else { return }
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating || phase == .animating { viewport.frames.start() }
                else if phase == .idle { viewport.frames.stop() }
                interacting = phase == .tracking || phase == .interacting || phase == .decelerating
                if phase == .tracking || phase == .interacting {
                    manuallyReading = true; followKeyboard = false; followLatest = false
                }
                if phase == .idle && atBottom { followLatest = true; manuallyReading = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                guard !manuallyReading else { return }
                followKeyboard = composing || followKeyboard || atBottom
                guard followKeyboard else { return }
                let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                Task { @MainActor in
                    await Task.yield()
                    guard followKeyboard && !manuallyReading && !interacting else { return }
                    withAnimation(.easeOut(duration: duration)) { scrollPosition.scrollTo(edge: .bottom) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                if followKeyboard {
                    Task { @MainActor in
                        await Task.yield()
                        guard !manuallyReading && !interacting && followLatest else { return }
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
                followKeyboard = false
            }
            .onChange(of: model.conversation.revision) { _, _ in
                let new = assistants.subtracting(knownAssistants)
                knownAssistants = assistants
                if !historyLoading && !atBottom { unread.formUnion(new) }
                if followLatest && !interacting && !historyLoading {
                    Task { @MainActor in
                        await Task.yield()
                        guard followLatest && !interacting && !historyLoading else { return }
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }
            .onChange(of: model.lastSubmittedID) { _, id in
                guard let id, let entry = model.pending.first(where: { $0.id == id }) else { return }
                let key = "request:" + id
                if !reduce, let origin = frames["composer"], origin.width > 0 {
                    flights[key] = OutgoingFlight(id: key, text: entry.text, origin: origin.insetBy(dx: -18, dy: -7))
                }
                unread = []; atBottom = true; manuallyReading = false; followLatest = true; interacting = false
                Task { @MainActor in
                    await Task.yield()
                    scrollPosition.scrollTo(edge: .bottom)
                    // Resolve the landing after the scroll/layout transaction,
                    // rather than targeting the row's old offscreen position.
                    try? await Task.sleep(for: .milliseconds(50))
                    flights[key]?.layoutReady = true
                    flights[key]?.destination = frames[key]
                    // A background/rotation or offscreen row must never stay hidden.
                    try? await Task.sleep(for: .milliseconds(800))
                    flights.removeValue(forKey: key)
                }
            }
            .onChange(of: model.jumpMessage) { _, id in
                guard let id else { return }
                followLatest = false; manuallyReading = true
                rebuildTimeline()
                if let index = timeline.firstIndex(where: { $0.message.id == id }) {
                    historyBudget = max(historyBudget, ChatPage.weight(of: Array(timeline[index...])))
                }
                let target = timeline.first(where: { $0.message.id == id })?.id ?? id
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(reduce ? nil : .smooth(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
                }
                model.jumpMessage = nil
            }
            .onAppear {
                knownAssistants = assistants
                if !positioned {
                    positioned = true
                    Task { @MainActor in
                        await Task.yield()
                        guard followLatest && !interacting else { return }
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }
            .onChange(of: model.conversation.messages, initial: true) { _, _ in rebuildTimeline() }
            .onChange(of: model.pending) { _, _ in rebuildTimeline() }
                if !atBottom {
                    Button {
                        manuallyReading = false; followLatest = true; interacting = false
                        // This sibling button sits outside text selection and scroll hit testing.
                        // Animate the measured edge of this fully laid-out page.
                        Task { @MainActor in
                            await Task.yield()
                            withAnimation(reduce ? nil : .easeInOut(duration: 0.48)) {
                                scrollPosition.scrollTo(edge: .bottom)
                            }
                        }
                    } label: {
                        HStack(spacing: Space.sm) { if !unread.isEmpty { Text("\(unread.count) 条新回复").font(TypeScale.footnote.weight(.semibold)) }; Image(systemName: "arrow.down").font(TypeScale.footnote.weight(.semibold)) }
                            .foregroundStyle(Palette.textPrimary)
                            .frame(minWidth: 44, minHeight: 44).padding(.horizontal, Space.sm)
                            .floatingGlass(.capsule)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(SoftPressStyle(scale: 0.94)).zIndex(1).padding(Space.lg).accessibilityIdentifier("chat-jump-latest").accessibilityLabel(unread.isEmpty ? "回到最新消息" : "\(unread.count) 条新回复，回到最新消息")
                }
            }
            if !model.locateNote.isEmpty {
                InlineNotice(text: model.locateNote, tone: .danger)
                    .padding(.horizontal, Space.lg)
                    .accessibilityIdentifier("chat-locate-fail")
            }
            if !model.todayOpening, !model.todayOpenNote.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    InlineNotice(text: model.todayOpenNote, tone: .danger)
                    Button(model.todayOpening ? "刷新中…" : "再刷主聊") {
                        guard !model.todayOpening else { return }
                        model.openTodayDeepLink()
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(model.todayOpening)
                    .accessibilityIdentifier("chat-today-refresh")
                }
                .padding(.horizontal, Space.lg)
                .accessibilityIdentifier("chat-today-open-fail")
            }
            if !model.financeOpening, !model.financeOpenNote.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    InlineNotice(text: model.financeOpenNote, tone: .warning)
                    Button(model.financeOpening ? "打开中…" : "打开账本") {
                        guard !model.financeOpening else { return }
                        model.openFinance()
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(model.financeOpening)
                    .accessibilityIdentifier("chat-finance-open")
                }
                .padding(.horizontal, Space.lg)
                .accessibilityIdentifier("chat-finance-refresh-fail")
            }
            // SSE 断线：HTTP 拉齐成功也不清；勿假装实时已恢复。
            if !model.streamNote.isEmpty {
                InlineNotice(text: model.streamNote, tone: .danger)
                    .padding(.horizontal, Space.lg)
                    .accessibilityIdentifier("chat-stream-fail")
            }
            // agent 忙碌时显示中断按钮
            if model.stage.state.isBusy || !model.interruptNote.isEmpty {
                VStack(spacing: Space.sm) {
                    if !model.interruptNote.isEmpty {
                        InlineNotice(text: model.interruptNote, tone: .danger)
                            .padding(.horizontal, Space.lg)
                            .accessibilityIdentifier("chat-interrupt-fail")
                    }
                    if model.stage.state.isBusy {
                        HStack {
                            Spacer()
                            Button {
                                guard !interruptingAll else { return }
                                Haptics.selection()
                                interruptingAll = true
                                model.interruptNote = ""
                                Task {
                                    _ = await model.interrupt()
                                    interruptingAll = false
                                }
                            } label: {
                                HStack(spacing: Space.xs) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(interruptingAll ? "正在中断…" : (model.activeRuns.count > 1 ? "全部中断 · \(model.activeRuns.count) 件在并行" : "中断"))
                                        .font(TypeScale.callout.weight(.semibold))
                                }
                                .foregroundStyle(Palette.coral)
                                .padding(.horizontal, Space.md)
                                .padding(.vertical, Space.sm)
                                .background(Palette.coral.opacity(0.12), in: .capsule)
                                .overlay(Capsule().strokeBorder(Palette.coral.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(SoftPressStyle(scale: 0.96))
                            .disabled(interruptingAll)
                            .accessibilityLabel("中断当前操作")
                            .accessibilityIdentifier("chat-interrupt-all")
                            Spacer()
                        }
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.xs)
                    }
                }
                .transition(.asymmetric(
                    insertion: reduce ? .opacity : .scale(scale: 0.92).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(ComMotion.reduced(reduce, ComMotion.settle), value: model.stage.state.isBusy)
                .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: model.interruptNote.isEmpty)
            }
            // 有对话时仍提示「等你 / 下一步」，保持 Muse 式对话重心。
            if !model.conversation.messages.isEmpty || !rows.isEmpty {
                ChatAttentionStrip()
            }
            // 输入区独占一整行；功能 Dock 在它下面（RootView 统一挂，打字时让位）。
            ComposerView(focusChanged: { focused in
                composing = focused
                followKeyboard = focused || atBottom
                if focused && atBottom { manuallyReading = false; followLatest = true }
            }).padding(.horizontal, Space.lg).padding(.top, Space.xs).padding(.bottom, Space.xs)
            }
            }
            .clipped()
            }
        }
        .background(Palette.background)
        .navigationTitle("Com")
        .toolbar(.hidden, for: .navigationBar)
        .coordinateSpace(name: "chat-stage")
        .onPreferenceChange(ChatFramePreference.self) { values in
            if frames != values { frames = values }
            for key in Array(flights.keys) {
                if flights[key]?.layoutReady == true && flights[key]?.destination == nil, let target = values[key] { flights[key]?.destination = target }
            }
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(flights.values)) { flight in OutgoingBubbleFlight(flight: flight) { flights.removeValue(forKey: flight.id) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).allowsHitTesting(false)
        }
        .onDisappear { viewport.frames.stop() }
        .onChange(of: model.active) { _, active in if !active { flights = [:]; viewport.frames.stop() } }
        .onChange(of: reduce) { _, enabled in if enabled { flights = [:] } }
        .refreshable { await model.refresh(.chat) }
        #if DEBUG
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-incoming-control") {
                Button("模拟新回复") { model.simulateIncomingPreview() }.font(TypeScale.footnote)
            }
        }
        #endif
    }
    /// 只有最后一条是已完成的助手回复时，才在它下面挂建议卡；历史消息不挂。
    private var suggestionHost: JSON? {
        guard let last = rows.last, last.pending == nil, last.message["role"].string == "assistant",
              !["streaming", "running", "failed", "unknown"].contains(last.message["status"].string) else { return nil }
        return last.message
    }
    private func rebuildTimeline() {
        let next = ChatTimeline.rows(messages: model.conversation.messages, pending: model.pending)
        if next != timeline {
            // A new reply must not evict the first rendered row and shift the reader.
            // Grow this mounted page from its stable first identity; older pages load explicitly.
            if let first = rows.first?.id, let index = next.firstIndex(where: { $0.id == first }) {
                historyBudget = max(historyBudget, ChatPage.weight(of: Array(next[index...])))
            }
            timeline = next
        }
    }
}

@MainActor private final class ChatViewport {
    var visibleRows: [String] = []
    let frames = ScrollFrameMonitor()
}

/// 空流里的三个提示：胶囊按钮。
private struct PromptChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Space.lg - 2).frame(height: 40)
            .background(Palette.surface, in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Wraps chips onto new lines.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

struct MessageView: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.sourceSession == rhs.sourceSession &&
        lhs.layoutID == rhs.layoutID && lhs.flying == rhs.flying && lhs.pending == rhs.pending &&
        lhs.isConsecutiveAgent == rhs.isConsecutiveAgent
    }
    @Environment(AppModel.self) private var model
    let message: JSON
    var sourceSession = "personal-main"
    var layoutID: String?
    var flying = false
    var pending: PendingMessage?
    var isConsecutiveAgent = false
    /// 「查回执」进行中：防连点叠查。
    @State private var checkingReceipt = false
    /// 单条中断进行中。
    @State private var interrupting = false
    var user: Bool { message["role"].string == "user" }
    var text: String {
        let raw = textContent(message["text"].isNull ? message["content"] : message["text"])
        // r2-chat：选项标记（完整或流式半截）不进正文。
        return user ? raw : ReplyOptions.split(raw).0
    }
    /// 这条话之后它做了什么：在跑时实时一行，做完折成一行。显示在助手一侧。
    private var process: WorkProcess? { WorkProcess.from(message) }
    /// 后台派活的事件（主对话自己的工具调用已在 process 里，不重复）。
    private var taskEvents: [JSON] { message["work_events"].array.filter { !$0.id.hasPrefix("tool-") && !["think", "reply"].contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            column
            if let process {
                WorkProcessRow(process: process, extra: taskEvents).padding(.trailing, 20)
                    .transition(.opacity)
            }
        }
    }
    private var column: some View {
        VStack(alignment: user ? .trailing : .leading, spacing: Space.sm) {
            if !message["reference"].isNull {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(message["reference"]["author"].string).font(TypeScale.footnote.weight(.semibold))
                    Text(message["reference"]["text"].string).font(TypeScale.footnote).lineLimit(3).foregroundStyle(Palette.textSecondary)
                }.padding(Space.md)
                    .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3).padding(.vertical, Space.sm).padding(.leading, 6) }
            }
            if !user && !message["answering"].string.isEmpty {
                // 并行：这条回复对应的是更早那个问题。
                Label("回复：" + message["answering"].string.split(separator: "\n").joined(separator: " "), systemImage: "arrowshape.turn.up.left")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    .padding(.horizontal, Space.sm + 2).padding(.vertical, Space.xs + 1).background(Palette.fill, in: .capsule)
                    .onTapGesture { model.jumpMessage = message["parent_id"].string }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("agent-answering-" + message.id)
            }
            if user {
                // 我的话：反色气泡。
                Text(text).font(TypeScale.callout).textSelection(.enabled).userBubble()
                    .chatFrame(layoutID ?? message.id, enabled: flying).opacity(flying ? 0 : 1)
                    .accessibilityIdentifier("chat-bubble-" + message.id)
            } else {
                // 它的回复：加浅色气泡区分连续消息，靠标题层级、粗体重点和段落呼吸分层。
                // 记账快通道回执（「已记 -35 餐饮…」）加一条轻标签；刚到的 3 秒内补一次成功触感。
                VStack(alignment: .leading, spacing: Space.xs) {
                    if text.hasPrefix("已记") {
                        Label("已记账", systemImage: "yensign.circle.fill")
                            .font(TypeScale.caption.weight(.semibold))
                            .foregroundStyle(Palette.success)
                            .accessibilityIdentifier("chat-bookkeep-receipt-" + message.id)
                            .onAppear {
                                let age = Date().timeIntervalSince1970 - message["created_at"].double
                                if age >= 0, age < 3 { Haptics.success() }
                            }
                    }
                    ClampedWhenProactive(proactive: ProactiveMessage.matches(message), text: text) {
                        ReplyText(text: text, motionID: message.id, createdAt: message["created_at"].double)
                    }
                    .foregroundStyle(Palette.textPrimary)
                }
                .agentBubble()
                .overlay(alignment: .leading) {
                    if text.hasPrefix("已记") {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.success.opacity(0.85))
                            .frame(width: 3).padding(.vertical, Space.sm).padding(.leading, 4)
                    }
                }
                .accessibilityIdentifier("agent-bubble-" + message.id)
            }
            if !message["attachments"].array.isEmpty {
                ForEach(message["attachments"].array.map(RemoteRow.init)) { row in
                    Label(row.value["name"].string, systemImage: "paperclip").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, Space.sm + 2).padding(.vertical, Space.xs + 1).background(Palette.fill, in: .capsule)
                }
            }
            if user { deliveryStatus }
            if user && model.activeRuns.count > 1 && ["sending", "running"].contains(message["status"].string) {
                // 并行时每件可以单独停，不影响另外在跑的。
                VStack(alignment: .trailing, spacing: Space.xs) {
                    Button {
                        guard !interrupting else { return }
                        interrupting = true
                        model.interruptNote = ""
                        Task {
                            _ = await model.interrupt(messageID: message.id)
                            interrupting = false
                        }
                    } label: {
                        Label(interrupting ? "正在停下…" : "停下这件", systemImage: "stop.circle").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.coral)
                    }.buttonStyle(.plain).disabled(interrupting).accessibilityIdentifier("chat-stop-" + message.id)
                    if !model.interruptNote.isEmpty {
                        InlineNotice(text: model.interruptNote, tone: .danger)
                            .frame(maxWidth: 280, alignment: .trailing)
                            .accessibilityIdentifier("chat-stop-fail-" + message.id)
                    }
                }
            }
            if !message["error"].string.isEmpty { InlineNotice(text: message["error"].string) }
            ForEach(message["linked_tasks"].array.map(RemoteRow.init)) { row in
                Button { model.selectedTask = row.value } label: { TaskSummary(task: row.value) }.buttonStyle(.plain).detailSource("task-" + row.id)
            }
            if process == nil && !taskEvents.isEmpty {
                let events = Array(taskEvents.suffix(12))
                DisclosureGroup("工作过程 · \(taskEvents.count)") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                            StepRow(text: eventLabel(event), state: index < events.count - 1 ? .done : stepState(event), time: clockTime(event["at"].double))
                        }
                    }.padding(.top, Space.sm)
                }.font(TypeScale.footnote.weight(.medium)).tint(Palette.textSecondary).foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
                    .noteSurface()
            }
            if !message["artifacts"].array.isEmpty { ArtifactList(artifacts: message["artifacts"].array, chips: true) }  // 10-25 附件片，与航程详情同款
        }
        .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
        .padding(user ? .leading : .trailing, user ? 48 : 20)
        .contextMenu {
            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            if pending == nil {
                Button("回复", systemImage: "arrowshape.turn.up.left") {
                    model.reference = .object(["id": .string(message.id), "source_session_id": .string(sourceSession), "mode": .string("reply"), "author": .string(user ? "你" : "Com"), "text": .string(String(text.prefix(2000)))])
                }
            }
            ShareLink(item: text) { Label("分享文字", systemImage: "square.and.arrow.up") }
        }
    }
    @ViewBuilder private var deliveryStatus: some View {
        if let pending {
            HStack(spacing: Space.sm) {
                if pending.state == .checking { ProgressView().controlSize(.mini) }
                Text(pending.state == .delivered ? "已受理 · 正在同步" : pending.note).font(TypeScale.footnote).foregroundStyle(pending.state == .rejected ? Palette.danger : Palette.textSecondary)
                if pending.state == .uncertain || checkingReceipt {
                    if checkingReceipt { ProgressView().controlSize(.mini) }
                    Button(checkingReceipt ? "查询中…" : "查回执") {
                        guard !checkingReceipt else { return }
                        checkingReceipt = true
                        let id = pending.id
                        Task {
                            let state = await model.deliver(id)
                            let after = model.pending.first(where: { $0.id == id })
                            let detail = after?.note ?? ""
                            if state == .delivered {
                                model.chatComposerNote = ""
                            } else if state == .rejected {
                                model.chatComposerNote = detail.isEmpty
                                    ? "没送出去——可点「回到草稿」再试。不会假装已核实。"
                                    : "没送出去：" + detail + "——可点「回到草稿」再试。"
                            } else {
                                // 仍 uncertain/checking 或查失败：Composer 开口，别只靠气泡灰字。
                                model.chatComposerNote = detail.isEmpty
                                    ? "回执仍待核实——不会重复提交；可再点「查回执」或到设置→发送记录。别当成已发出。"
                                    : "回执仍待核实：" + detail + "——不会重复提交；可再查。别当成已发出。"
                            }
                            checkingReceipt = false
                        }
                    }
                    .buttonStyle(.quiet)
                    .font(TypeScale.footnote.weight(.semibold))
                    .disabled(checkingReceipt || model.sending)
                    .accessibilityIdentifier("chat-check-receipt")
                }
                if pending.state == .rejected && model.draft.isEmpty && model.attachments.isEmpty { Button("回到草稿") { model.restoreRejected(pending.id) }.buttonStyle(.quiet).font(TypeScale.footnote.weight(.semibold)) }
            }
        } else if !message["status"].string.isEmpty && !(process?.live == true && ["sending", "running"].contains(message["status"].string)) {
            // 在跑时由下面的「工作过程」一行说明，不再重复「已送达 · 执行中」。
            let status = message["status"].string
            Label(["queued": "收到了 · 我先排上", "sending": "收到了 · 我在接", "running": "我在办", "completed": "办完了", "failed": "这轮没办成", "unknown": "结果还不清楚", "approval_required": "要你批准这一步", "cancelled": "已停下"][status] ?? "收到了", systemImage: status == "failed" || status == "unknown" ? "exclamationmark.circle" : "checkmark")
                .font(TypeScale.footnote).foregroundStyle(status == "failed" || status == "unknown" ? Palette.warning : Palette.textTertiary)
        }
    }

}

enum StepState { case done, current, pending, blocked }
func stepState(_ event: JSON) -> StepState {
    let kind = event["kind"].string.isEmpty ? event["type"].string : event["kind"].string
    let status = event["status"].string
    if kind.hasSuffix(".failed") || status == "failed" { return .blocked }
    if ["approval_required", "awaiting_review", "task.review"].contains(kind) || ["approval_required", "awaiting_review"].contains(status) { return .blocked }
    if kind.hasSuffix(".completed") || ["completed", "done", "execution_finished"].contains(status) { return .done }
    return .current
}

/// 步骤行：做完的划线勾掉，正在做的实心方块，等你的朱砂框，没到的淡框。
struct StepRow: View {
    let text: String
    let state: StepState
    var time = ""
    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            ZStack {
                switch state {
                case .done: Circle().fill(Palette.success); Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                case .current: Circle().strokeBorder(Palette.accentText, lineWidth: 1.6); Circle().fill(Palette.accent).frame(width: 8, height: 8)
                case .blocked: Circle().strokeBorder(Palette.warning, lineWidth: 1.6); Circle().fill(Palette.warning).frame(width: 6, height: 6)
                case .pending: Circle().strokeBorder(Palette.separator, lineWidth: 1.6)
                }
            }.frame(width: 16, height: 16)
            Text(text).font(state == .current ? TypeScale.rowTitle : TypeScale.body)
                .foregroundStyle(state == .blocked ? Palette.warning : state == .done || state == .pending ? Palette.textTertiary : Palette.textPrimary)
                .strikethrough(state == .done, color: Palette.textTertiary.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            if !time.isEmpty { Text(time).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) }
        }.frame(minHeight: 30).accessibilityElement(children: .combine)
    }
}

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @FocusState private var focused: Bool
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    var focusChanged: (Bool) -> Void = { _ in }
    var body: some View {
        @Bindable var model = model
        VStack(spacing: Space.sm) {
            if !model.chatComposerNote.isEmpty {
                InlineNotice(text: model.chatComposerNote, tone: .danger)
                    .padding(.horizontal, Space.xs)
                    .accessibilityIdentifier("chat-composer-fail")
            }
            if !model.cachePersistNote.isEmpty {
                InlineNotice(text: model.cachePersistNote, tone: .warning)
                    .padding(.horizontal, Space.xs)
                    .accessibilityIdentifier("chat-cache-persist-fail")
            }
            if !model.shareInboxNote.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    InlineNotice(text: model.shareInboxNote, tone: .warning)
                    Button("打开收件箱") { model.openShareInbox() }
                        .buttonStyle(.secondaryCompact)
                        .accessibilityIdentifier("chat-share-inbox-open")
                }
                .padding(.horizontal, Space.xs)
                .accessibilityIdentifier("chat-share-inbox-fail")
            }
            if !model.searchOpenNote.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    InlineNotice(text: model.searchOpenNote, tone: .warning)
                    Button(model.searchOpening ? "打开中…" : "打开搜索") {
                        guard !model.searchOpening else { return }
                        model.openSearch()
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(model.searchOpening)
                    .accessibilityIdentifier("chat-search-open")
                }
                .padding(.horizontal, Space.xs)
                .accessibilityIdentifier("chat-search-open-fail")
            }
            if !model.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.attachments.map(RemoteRow.init)) { row in
                            HStack(spacing: Space.xs + 2) { Label(row.value["name"].string, systemImage: "paperclip").lineLimit(1); Button { model.attachments.removeAll { $0.id == row.id }; model.persistNow() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary) }.accessibilityLabel("移除附件") }
                                .font(TypeScale.footnote).padding(.horizontal, Space.md).padding(.vertical, Space.sm).background(Palette.surface, in: .capsule)
                                .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 0.5))
                        }
                    }
                }.scrollIndicators(.hidden).padding(.horizontal, Space.xs)
            }
            if let reference = model.reference {
                HStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: Space.xs) { Text("回复 \(reference["author"].string)").font(TypeScale.footnote.weight(.semibold)); Text(reference["text"].string).font(TypeScale.footnote).lineLimit(2).foregroundStyle(Palette.textSecondary) }
                    Spacer(); Button { model.reference = nil } label: { Image(systemName: "xmark").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary) }.accessibilityLabel("取消引用")
                }.fixedSize(horizontal: false, vertical: true).padding(Space.md).composerSurface()
            }
            ZStack(alignment: .bottom) {

                if model.voice.phase != .idle && !model.showQuickVoice {
                    VoiceSessionPanel()
                } else {
                    // 输入区布局不动：左加号、中间文本、右麦克风。
                    HStack(alignment: .bottom, spacing: Space.sm) {
                        Menu {
                            Button("选择文件", systemImage: "doc") { importing = true }
                            PhotosPicker(selection: $photo, matching: .images) { Label("选择照片", systemImage: "photo") }
                            Button(model.searchOpening ? "打开中…" : "查看成果", systemImage: model.searchOpening ? "hourglass" : "tray.full") {
                                guard !model.searchOpening else { return }
                                model.openSearch()
                            }
                            .disabled(model.searchOpening)
                        } label: {
                            Image(systemName: uploading ? "hourglass" : "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.textPrimary)
                                .frame(width: 44, height: 44).background(Palette.fill, in: .circle)
                        }.disabled(uploading).accessibilityLabel("附件与成果")
                        TextField("发消息", text: $model.draft, axis: .vertical).font(TypeScale.callout).lineLimit(1...6).focused($focused).padding(.vertical, Space.md).accessibilityIdentifier("message-input").chatFrame("composer")
                        if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                guard !model.voice.starting else { return }
                                focused = false
                                model.openVoice()
                            } label: {
                                Image(systemName: model.voice.starting ? "hourglass" : "mic")
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(Palette.textPrimary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(SoftPressStyle(scale: 0.92))
                            .contentShape(Rectangle())
                            .disabled(model.voice.starting)
                            .accessibilityIdentifier("chat-voice-start")
                            .accessibilityLabel(model.voice.starting ? "正在开麦" : "开始语音")
                        } else {
                            CircleActionButton(symbol: model.sending ? "hourglass" : "arrow.up", label: model.sending ? "发送中" : "发送消息", filled: true, size: 40) {
                                // 按下即反馈，受理成功后再 Haptics.sent（AppModel.send）——快路径体感更跟手。
                                guard !model.sending else { return }
                                Haptics.selection()
                                model.chatComposerNote = ""
                                let fromVoice = model.voice.phase == .ready
                                Task { await model.send(voiceMessage: fromVoice); if fromVoice && model.pending.last?.state == .delivered { model.voice.cancel() } }
                            }.disabled(model.sending).padding(.trailing, 2)
                            .accessibilityIdentifier("chat-send")
                        }
                    }.padding(.leading, Space.sm).padding(.trailing, Space.sm).padding(.vertical, Space.sm)
                }
            }
            .composerSurface()
            .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: model.voice.phase)

        }
        .onChange(of: model.draft) { _, _ in model.persistSoon() }
        .onChange(of: focused) { _, value in focusChanged(value) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): Task { await upload(url: url) }
            case .failure(let error):
                // 窗内开口，别只靠 banner alert。
                model.chatComposerNote = "文件没选上：" + error.localizedDescription + "——可再点「+」选一次。"
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                model.chatComposerNote = ""
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        model.chatComposerNote = "这张照片读不出来——换一张，或用「选择文件」。不会假装已挂上。"
                        photo = nil
                        return
                    }
                    let type = item.supportedContentTypes.first
                    await upload(data: data, name: "照片-\(Date().formatted(.iso8601.year().month().day()))." + (type?.preferredFilenameExtension ?? "jpg"), mime: type?.preferredMIMEType ?? "image/jpeg")
                } catch {
                    model.chatComposerNote = "照片没读上：" + error.localizedDescription + "——可再选一次。"
                }
                photo = nil
            }
        }
    }
    private func upload(url: URL) async {
        model.chatComposerNote = ""
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20 * 1024 * 1024 else { throw APIError(status: 413, detail: "附件超过 20 MB") }
            await upload(data: try Data(contentsOf: url), name: url.lastPathComponent, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
        } catch {
            model.chatComposerNote = "附件没挂上：" + error.localizedDescription + "——可再点「+」重试。不会假装已附上。"
        }
    }
    private func upload(data: Data, name: String, mime: String) async {
        guard let client = model.client else {
            // 未配对 / 无 client：别静默吞掉，人会以为附件已挂上。
            model.chatComposerNote = model.isPaired
                ? "连不上 mini，附件没传上——稍后再点「+」重试。不会假装已挂上。"
                : "先连接 Mac mini，再加附件。现在不会假装已挂上。"
            return
        }
        guard model.attachments.count < 8 else {
            model.chatComposerNote = "每条最多八个附件——先去掉一个再加。"
            return
        }
        uploading = true
        model.chatComposerNote = ""
        defer { uploading = false }
        do {
            let value = try await client.uploadAttachment(data, name: name, mime: mime, id: UUID().uuidString.lowercased())
            model.attachments.append(value)
            model.persistNow()
            model.chatComposerNote = ""
        } catch {
            model.chatComposerNote = "附件没传上：" + error.localizedDescription + "——可再点「+」重试。不会假装已挂上。"
        }
    }
}


// MARK: 主动消息（晨晚报 / 提醒 / 任务回执）折叠

enum ProactiveMessage {
    /// 不是被我问出来的、由后台主动写进对话的助手消息（回执通道 task_receipt 的 request_id 都以此开头）。
    static func matches(_ message: JSON) -> Bool {
        message["role"].string == "assistant" && message["request_id"].string.hasPrefix("task-result:")
    }
    /// 从 start 起连续的主动消息，最后一条（最新）不在内——它单独完整显示。
    static func run(in rows: [ChatTimelineRow], from start: Int) -> [ChatTimelineRow] {
        var out: [ChatTimelineRow] = []
        var i = start
        while i + 1 < rows.count, matches(rows[i].message), matches(rows[i + 1].message) { out.append(rows[i]); i += 1 }
        return out
    }
    /// 折叠行里的一句话：去掉 markdown 标记，取第一行。
    static func preview(_ text: String) -> String {
        let line = text.split(separator: "\n").map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
        return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// N 条连续的主动消息折成一行；点开在原位展开，再点收起。
struct ProactiveStack: View {
    let run: [ChatTimelineRow]
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                Haptics.selection()
                withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { open.toggle() }
            } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "bell.badge").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(run.count) 条更早的主动消息").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                        if !open, let last = run.last {
                            Text(ProactiveMessage.preview(textContent(last.message["text"]))).font(TypeScale.footnote)
                                .foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, Space.md).padding(.vertical, Space.sm + 2)
                .background(Palette.fill, in: .rect(cornerRadius: Radius.md, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(SoftPressStyle(scale: 0.98))
            .accessibilityIdentifier("proactive-stack")
            if open {
                ForEach(run) { row in
                    MessageView(message: row.message, layoutID: row.id, flying: false, pending: row.pending, isConsecutiveAgent: false)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// 主动消息超过约 6 行时收起，底部渐隐 +「展开」；普通对话回复原样不动。
struct ClampedWhenProactive<Content: View>: View {
    let proactive: Bool
    let text: String
    @ViewBuilder var content: () -> Content
    @State private var open = false
    private var long: Bool { proactive && (text.count > 150 || text.filter { $0 == "\n" }.count >= 5) }
    var body: some View {
        if long && !open {
            content()
                .frame(maxHeight: 132, alignment: .top)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottomLeading) {
                    Button("展开全文") { withAnimation(ComMotion.settle) { open = true } }
                        .font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.accentText)
                        .accessibilityIdentifier("proactive-expand")
                }
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                content()
                if long {
                    Button("收起") { withAnimation(ComMotion.settle) { open = false } }
                        .font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }
}
