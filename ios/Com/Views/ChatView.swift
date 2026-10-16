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
    @State private var historyWindow = 30
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var positioned = false
    @State private var viewport = ChatViewport()
    /// r2-chat：点过的建议卡所在消息（点完立刻收起，不等服务端回执）。
    @State private var usedSuggestions: String?
    private var rows: [ChatTimelineRow] { Array(timeline.suffix(historyWindow)) }
    private var assistants: Set<String> { Set(model.conversation.messages.filter { $0["role"].string == "assistant" }.map(\.id)) }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
            ZStack(alignment: .top) {
            VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Space.xl) {
                    if (historyWindow < timeline.count || model.moreHistory) && !model.conversation.messages.isEmpty {
                        Button(historyLoading ? "正在读取…" : "更早的对话") {
                            followLatest = false; manuallyReading = true
                            let anchor = rows.first(where: { viewport.visibleRows.contains($0.id) })?.id
                            historyLoading = true
                            Task {
                                if historyWindow < timeline.count {
                                    historyWindow += 30
                                } else {
                                    let count = timeline.count
                                    await model.loadHistory()
                                    historyWindow += max(0, model.conversation.messages.count - count)
                                }
                                await Task.yield()
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                historyLoading = false
                            }
                        }.buttonStyle(.secondaryAction).disabled(historyLoading)
                    }
                    if model.conversation.messages.isEmpty && rows.isEmpty {
                        VStack(alignment: .leading, spacing: Space.lg) {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text("今天还没有要你管的事").font(TypeScale.title)
                                Text("邮件、日历、群消息和两台电脑我都在看。有变化，我会先整理好放到这里。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary).lineSpacing(4)
                            }
                            FlowLayout(spacing: Space.sm + 2) {
                                ForEach(["明天要准备什么", "这个月花了多少", "Codex 跑完了吗"], id: \.self) { prompt in
                                    Button(prompt) { Task { await model.send(textOverride: prompt) } }.buttonStyle(PromptChipStyle())
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.xxxl).padding(.horizontal, Space.xs)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let isAgent = row.message["role"].string == "assistant"
                        let previousIsAgent = index > 0 ? rows[index - 1].message["role"].string == "assistant" : false
                        let isConsecutiveAgent = isAgent && previousIsAgent

                        MessageView(message: row.message, layoutID: row.id, flying: flights[row.id] != nil, pending: row.pending, isConsecutiveAgent: isConsecutiveAgent)
                            .equatable()
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
                                // 先让被点的那张亮一下（≈0.2s），再收起其余卡片并把这句发出去。
                                Task { @MainActor in
                                    if !reduce { try? await Task.sleep(for: .milliseconds(200)) }
                                    withAnimation(reduce ? nil : .smooth(duration: 0.28)) { usedSuggestions = latest.id }
                                    await model.send(textOverride: option)
                                }
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
                    historyWindow = max(historyWindow, timeline.count - index)
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
                        .buttonStyle(.plain).zIndex(1).padding(Space.lg).accessibilityIdentifier("chat-jump-latest").accessibilityLabel(unread.isEmpty ? "回到最新消息" : "\(unread.count) 条新回复，回到最新消息")
                }
            }
            // agent 忙碌时显示中断按钮
            if model.stage.state.isBusy {
                HStack {
                    Spacer()
                    Button {
                        Task { await model.interrupt() }
                    } label: {
                        HStack(spacing: Space.xs) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("中断")
                                .font(TypeScale.callout.weight(.semibold))
                        }
                        .foregroundStyle(Palette.coral)
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)
                        .background(Palette.coral.opacity(0.12), in: .capsule)
                        .overlay(Capsule().strokeBorder(Palette.coral.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("中断当前操作")
                    Spacer()
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.xs)
                .transition(.asymmetric(
                    insertion: reduce ? .opacity : .scale(scale: 0.92).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(reduce ? .linear(duration: 0.12) : .spring(response: 0.35, dampingFraction: 0.82), value: model.stage.state.isBusy)
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
                historyWindow = max(historyWindow, next.count - index)
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
            if user {
                // 我的话：反色气泡。
                Text(text).font(TypeScale.callout).textSelection(.enabled).userBubble()
                    .chatFrame(layoutID ?? message.id, enabled: flying).opacity(flying ? 0 : 1)
                    .accessibilityIdentifier("chat-bubble-" + message.id)
            } else {
                // 它的回复：加浅色气泡区分连续消息，靠标题层级、粗体重点和段落呼吸分层。
                ReplyText(text: text, motionID: message.id, createdAt: message["created_at"].double)
                    .foregroundStyle(Palette.textPrimary)
                    .agentBubble()
                    .accessibilityIdentifier("agent-bubble-" + message.id)
            }
            if !message["attachments"].array.isEmpty {
                ForEach(message["attachments"].array.map(RemoteRow.init)) { row in
                    Label(row.value["name"].string, systemImage: "paperclip").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, Space.sm + 2).padding(.vertical, Space.xs + 1).background(Palette.fill, in: .capsule)
                }
            }
            if user { deliveryStatus }
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
            if !message["artifacts"].array.isEmpty { ArtifactList(artifacts: message["artifacts"].array) }
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
                if pending.state == .uncertain { Button("查回执") { Task { await model.deliver(pending.id) } }.buttonStyle(.quiet).font(TypeScale.footnote.weight(.semibold)) }
                if pending.state == .rejected && model.draft.isEmpty && model.attachments.isEmpty { Button("回到草稿") { model.restoreRejected(pending.id) }.buttonStyle(.quiet).font(TypeScale.footnote.weight(.semibold)) }
            }
        } else if !message["status"].string.isEmpty && !(process?.live == true && ["sending", "running"].contains(message["status"].string)) {
            // 在跑时由下面的「工作过程」一行说明，不再重复「已送达 · 执行中」。
            let status = message["status"].string
            Label(["queued": "已送达 · 排队中", "sending": "已送达 · 正在处理", "running": "已送达 · 执行中", "completed": "已送达", "failed": "本轮失败", "unknown": "结果未知", "approval_required": "等待批准", "cancelled": "已停止"][status] ?? "已送达", systemImage: status == "failed" || status == "unknown" ? "exclamationmark.circle" : "checkmark")
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
                            Button("查看成果", systemImage: "tray.full") { model.showSearch = true }
                        } label: {
                            Image(systemName: uploading ? "hourglass" : "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.textPrimary)
                                .frame(width: 44, height: 44).background(Palette.fill, in: .circle)
                        }.disabled(uploading).accessibilityLabel("附件与成果")
                        TextField("发消息", text: $model.draft, axis: .vertical).font(TypeScale.callout).lineLimit(1...6).focused($focused).padding(.vertical, Space.md).accessibilityIdentifier("message-input").chatFrame("composer")
                        if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button { focused = false; model.openVoice() } label: { Image(systemName: "mic").font(.system(size: 20, weight: .regular)).foregroundStyle(Palette.textPrimary).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).contentShape(Rectangle()).accessibilityIdentifier("chat-voice-start").accessibilityLabel("开始语音")
                        } else {
                            CircleActionButton(symbol: "arrow.up", label: "发送消息", filled: true, size: 40) {
                                let fromVoice = model.voice.phase == .ready
                                Task { await model.send(voiceMessage: fromVoice); if fromVoice && model.pending.last?.state == .delivered { model.voice.cancel() } }
                            }.disabled(model.sending).padding(.trailing, 2)
                        }
                    }.padding(.leading, Space.sm).padding(.trailing, Space.sm).padding(.vertical, Space.sm)
                }
            }
            .composerSurface()
            .animation(reduce ? .linear(duration: 0.12) : .spring(response: 0.4, dampingFraction: 0.86), value: model.voice.phase)

        }
        .onChange(of: model.draft) { _, _ in model.persistSoon() }
        .onChange(of: focused) { _, value in focusChanged(value) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await upload(url: url) } }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let type = item.supportedContentTypes.first
                    await upload(data: data, name: "照片-\(Date().formatted(.iso8601.year().month().day()))." + (type?.preferredFilenameExtension ?? "jpg"), mime: type?.preferredMIMEType ?? "image/jpeg")
                } catch { model.banner = error.localizedDescription }
                photo = nil
            }
        }
    }
    private func upload(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20 * 1024 * 1024 else { throw APIError(status: 413, detail: "附件超过 20 MB") }
            await upload(data: try Data(contentsOf: url), name: url.lastPathComponent, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
        }
        catch { model.banner = error.localizedDescription }
    }
    private func upload(data: Data, name: String, mime: String) async {
        guard let client = model.client else { return }
        guard model.attachments.count < 8 else { model.banner = "每条消息最多八个附件"; return }
        uploading = true; defer { uploading = false }
        do {
            let value = try await client.uploadAttachment(data, name: name, mime: mime, id: UUID().uuidString.lowercased())
            model.attachments.append(value)
            model.persistNow()
        } catch { model.banner = error.localizedDescription }
    }
}
