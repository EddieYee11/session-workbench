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
    private var rows: [ChatTimelineRow] { Array(timeline.suffix(historyWindow)) }
    private var assistants: Set<String> { Set(model.conversation.messages.filter { $0["role"].string == "assistant" }.map(\.id)) }
    var body: some View {
        ScrollViewReader { proxy in
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
                        VStack(spacing: Space.md) {
                            Companion().frame(width: 150, height: 150)
                            Text("你好，小野").font(TypeScale.largeTitle)
                            Text("说说今天，或者交给我一件事。").foregroundStyle(Palette.textSecondary).font(TypeScale.callout)
                        }.frame(maxWidth: .infinity).padding(.vertical, Space.xxxl)
                    }
                    ForEach(rows) { row in
                        MessageView(message: row.message, layoutID: row.id, flying: flights[row.id] != nil, pending: row.pending)
                            .equatable()
                            .id(row.id)
                            .transition(.asymmetric(
                                insertion: reduce ? .opacity : .scale(scale: 0.96).combined(with: .offset(y: 8)).combined(with: .opacity),
                                removal: .opacity
                            ))

                    }
                    if model.busy {
                        LoadingState(text: model.activeRuns.first?["phase"].string ?? "处理中")
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.scrollTargetLayout().padding(.horizontal, Layout.margin).padding(.top, Space.sm).padding(.bottom, Space.md)
            }
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
                            .background(.regularMaterial, in: Capsule())
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain).zIndex(1).padding(Space.lg).accessibilityIdentifier("chat-jump-latest").accessibilityLabel(unread.isEmpty ? "回到最新消息" : "\(unread.count) 条新回复，回到最新消息")
                }
            }
            ComposerView(focusChanged: { focused in
                composing = focused; followKeyboard = focused || atBottom
                if focused && atBottom { manuallyReading = false; followLatest = true }
            }).padding(.horizontal, Space.md).padding(.top, Space.xs).padding(.bottom, Space.sm)
            }
        }
        .background(Palette.background)
        .navigationTitle("聊天")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { CompanionTitle() } }
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

struct MessageView: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.sourceSession == rhs.sourceSession &&
        lhs.layoutID == rhs.layoutID && lhs.flying == rhs.flying && lhs.pending == rhs.pending
    }
    @Environment(AppModel.self) private var model
    let message: JSON
    var sourceSession = "personal-main"
    var layoutID: String?
    var flying = false
    var pending: PendingMessage?
    var user: Bool { message["role"].string == "user" }
    var text: String { textContent(message["text"].isNull ? message["content"] : message["text"]) }
    var body: some View {
        VStack(alignment: user ? .trailing : .leading, spacing: Space.sm) {
            if !message["reference"].isNull {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(message["reference"]["author"].string).font(TypeScale.footnote.weight(.semibold))
                    Text(message["reference"]["text"].string).font(TypeScale.footnote).lineLimit(3).foregroundStyle(Palette.textSecondary)
                }.padding(Space.md)
                    .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(alignment: .leading) { Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, Space.sm) }
            }
            if user {
                Text(text).font(TypeScale.callout).textSelection(.enabled).userBubble()
                    .chatFrame(layoutID ?? message.id, enabled: flying).opacity(flying ? 0 : 1)
                    .accessibilityIdentifier("chat-bubble-" + message.id)
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Label("Com", systemImage: "sparkle").font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    RichText(text: text, font: TypeScale.callout)
                }
                .padding(Space.lg)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.lg).stroke(Palette.separator, lineWidth: 0.5) }
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
            if !message["work_events"].array.isEmpty {
                DisclosureGroup("工作过程 · \(message["work_events"].array.count)") {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(Array(message["work_events"].array.suffix(12).enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                StatusDot(tone: .neutral, size: 4)
                                Text(eventLabel(event)).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, Space.xxs)
                        }
                    }.padding(.top, Space.sm)
                }.font(TypeScale.footnote.weight(.medium)).tint(Palette.textSecondary).foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Space.md).padding(.vertical, Space.sm + 2)
                    .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
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
        } else if !message["status"].string.isEmpty {
            let status = message["status"].string
            Label(["queued": "已送达 · 排队中", "sending": "已送达 · 正在处理", "running": "已送达 · 执行中", "completed": "已送达", "failed": "本轮失败", "unknown": "执行结果待核实", "approval_required": "等待你确认", "cancelled": "已停止"][status] ?? "已送达", systemImage: status == "failed" || status == "unknown" ? "exclamationmark.circle" : "checkmark")
                .font(TypeScale.footnote).foregroundStyle(status == "failed" || status == "unknown" ? Palette.warning : Palette.textTertiary)
        }
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
                    Capsule().fill(Palette.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: Space.xs) { Text("回复 \(reference["author"].string)").font(TypeScale.footnote.weight(.semibold)); Text(reference["text"].string).font(TypeScale.footnote).lineLimit(2).foregroundStyle(Palette.textSecondary) }
                    Spacer(); Button { model.reference = nil } label: { Image(systemName: "xmark").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary) }.accessibilityLabel("取消引用")
                }.fixedSize(horizontal: false, vertical: true).padding(Space.md).composerSurface()
            }
            ZStack(alignment: .bottom) {

                if model.voice.phase != .idle && !model.showQuickVoice {
                    VoiceSessionPanel()
                } else {
                    HStack(alignment: .bottom, spacing: Space.sm) {
                        Menu {
                            Button("选择文件", systemImage: "doc") { importing = true }
                            PhotosPicker(selection: $photo, matching: .images) { Label("选择照片", systemImage: "photo") }
                            Button("查看成果", systemImage: "tray.full") { model.showSearch = true }
                        } label: {
                            Image(systemName: uploading ? "hourglass" : "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                                .frame(width: 36, height: 36).background(Palette.fill, in: .circle)
                        }.disabled(uploading).accessibilityLabel("附件与成果")
                        TextField("发消息", text: $model.draft, axis: .vertical).font(TypeScale.callout).lineLimit(1...6).focused($focused).padding(.vertical, Space.sm).accessibilityIdentifier("message-input").chatFrame("composer")
                        if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button { focused = false; model.openVoice() } label: { Image(systemName: "mic").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.textSecondary).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).contentShape(Rectangle()).accessibilityIdentifier("chat-voice-start").accessibilityLabel("开始语音")
                        } else {
                            CircleActionButton(symbol: "arrow.up", label: "发送消息", filled: true, size: 36) {
                                let fromVoice = model.voice.phase == .ready
                                Task { await model.send(voiceMessage: fromVoice); if fromVoice && model.pending.last?.state == .delivered { model.voice.cancel() } }
                            }.disabled(model.sending)
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
