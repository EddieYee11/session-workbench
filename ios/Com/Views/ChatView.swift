import SwiftUI
import ComCore
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
    private var rows: [ChatTimelineRow] { ChatTimeline.rows(messages: model.conversation.messages, pending: model.pending) }
    private var assistants: Set<String> { Set(model.conversation.messages.filter { $0["role"].string == "assistant" }.map(\.id)) }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if model.moreHistory && !model.conversation.messages.isEmpty {
                        Button(historyLoading ? "正在读取…" : "更早的对话") {
                            historyLoading = true; Task { await model.loadHistory(); historyLoading = false }
                        }.font(.caption).foregroundStyle(.secondary).disabled(historyLoading)
                    }
                    if model.conversation.messages.isEmpty && rows.isEmpty {
                        VStack(spacing: 6) {
                            Text("你好，小野").font(.system(size: 28, weight: .semibold))
                            Text("说说今天，或者交给我一件事。").foregroundStyle(.secondary).font(.subheadline)
                        }.padding(.vertical, 24)
                    }
                    ForEach(rows) { row in
                        MessageView(message: row.message, layoutID: row.id, flying: flights[row.id] != nil, pending: row.pending)
                            .id(row.id)
                            .transition(.asymmetric(insertion: .offset(y: 10).combined(with: .opacity), removal: .opacity))
                    }
                    if model.busy {
                        HStack(spacing: 8) { ProgressView().controlSize(.mini); Text(model.activeRuns.first?["phase"].string ?? "处理中").font(.caption).foregroundStyle(.secondary); Spacer() }
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentSize.height - g.visibleRect.maxY < 70 } action: { _, near in
                atBottom = near
                if near { unread = [] }
            }
            .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { old, new in
                if !manuallyReading && (followKeyboard || composing) && old.height != new.height { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting { manuallyReading = true; followKeyboard = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                guard !manuallyReading else { return }
                followKeyboard = composing || followKeyboard || atBottom
                guard followKeyboard else { return }
                let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.easeOut(duration: duration)) { proxy.scrollTo("latest", anchor: .bottom) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                if followKeyboard {
                    Task { @MainActor in await Task.yield(); proxy.scrollTo("latest", anchor: .bottom) }
                }
                followKeyboard = false
            }
            .onChange(of: model.conversation.revision) { _, _ in
                let new = assistants.subtracting(knownAssistants)
                knownAssistants = assistants
                if !historyLoading && !atBottom { unread.formUnion(new) }
                if atBottom && !historyLoading { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: model.lastSubmittedID) { _, id in
                guard let id, let entry = model.pending.first(where: { $0.id == id }) else { return }
                let key = "request:" + id
                if !reduce, let origin = frames["composer"], origin.width > 0 {
                    flights[key] = OutgoingFlight(id: key, text: entry.text, origin: origin.insetBy(dx: -18, dy: -7))
                }
                unread = []; atBottom = true; manuallyReading = false
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo("latest", anchor: .bottom)
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
                let target = rows.first(where: { $0.message.id == id })?.id ?? id
                withAnimation(reduce ? nil : .smooth(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
                model.jumpMessage = nil
            }
            .onAppear { knownAssistants = assistants; proxy.scrollTo("latest", anchor: .bottom) }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        unread = []; manuallyReading = false
                        withAnimation(reduce ? nil : .spring(duration: 0.28, bounce: 0.06)) { proxy.scrollTo("latest", anchor: .bottom) }
                    } label: {
                        HStack(spacing: 6) { if !unread.isEmpty { Text("\(unread.count) 条新回复").font(.caption.weight(.medium)) }; Image(systemName: "arrow.down") }.padding(12)
                    }.background(Palette.surface, in: .capsule).shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                        .buttonStyle(MessagePressStyle()).padding(12).accessibilityLabel(unread.isEmpty ? "回到最新消息" : "\(unread.count) 条新回复，回到最新消息")
                }
            }
            ComposerView(focusChanged: { focused in
                composing = focused; followKeyboard = focused || atBottom
                if focused { manuallyReading = false }
            }).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .background(Palette.canvas)
        .coordinateSpace(name: "chat-stage")
        .onPreferenceChange(ChatFramePreference.self) { values in
            frames = values
            for key in Array(flights.keys) {
                if flights[key]?.layoutReady == true && flights[key]?.destination == nil, let target = values[key] { flights[key]?.destination = target }
            }
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(flights.values)) { flight in OutgoingBubbleFlight(flight: flight) { flights.removeValue(forKey: flight.id) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).allowsHitTesting(false)
        }
        .onChange(of: model.active) { _, active in if !active { flights = [:] } }
        .onChange(of: reduce) { _, enabled in if enabled { flights = [:] } }
        .refreshable { await model.refresh(.chat) }
        #if DEBUG
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-incoming-control") {
                Button("模拟新回复") { model.simulateIncomingPreview() }.font(.caption)
            }
        }
        #endif
    }
}

struct MessageView: View {
    @Environment(AppModel.self) private var model
    let message: JSON
    var sourceSession = "personal-main"
    var layoutID: String?
    var flying = false
    var pending: PendingMessage?
    var user: Bool { message["role"].string == "user" }
    var text: String { textContent(message["text"].isNull ? message["content"] : message["text"]) }
    var body: some View {
        VStack(alignment: user ? .trailing : .leading, spacing: 10) {
            if !message["reference"].isNull {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message["reference"]["author"].string).font(.caption.weight(.semibold))
                    Text(message["reference"]["text"].string).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                }.padding(12).background(Palette.canvas, in: .rect(cornerRadius: 16))
            }
            if user {
                Text(text).textSelection(.enabled).padding(.horizontal, 18).padding(.vertical, 14)
                    .foregroundStyle(.primary).background(Palette.surface, in: .rect(cornerRadius: 22))
                    .chatFrame(layoutID ?? message.id).opacity(flying ? 0 : 1)
                    .accessibilityIdentifier("chat-bubble-" + message.id)
            } else { RichText(text: text).padding(16).background(Palette.raised.opacity(0.70), in: .rect(cornerRadius: 22)) }
            if !message["attachments"].array.isEmpty {
                ForEach(message["attachments"].array.map(RemoteRow.init)) { row in
                    Label(row.value["name"].string, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                }
            }
            if user { deliveryStatus }
            if !message["error"].string.isEmpty { Text(message["error"].string).font(.caption).foregroundStyle(Palette.coral) }
            ForEach(message["linked_tasks"].array.map(RemoteRow.init)) { row in
                Button { model.selectedTask = row.value } label: { TaskSummary(task: row.value) }.buttonStyle(.plain).detailSource("task-" + row.id)
            }
            if !message["work_events"].array.isEmpty {
                DisclosureGroup("工作过程 · \(message["work_events"].array.count)") {
                    ForEach(Array(message["work_events"].array.suffix(12).enumerated()), id: \.offset) { _, event in
                        Text(eventLabel(event)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                    }
                }.font(.caption).tint(.secondary)
            }
            if !message["artifacts"].array.isEmpty { ArtifactList(artifacts: message["artifacts"].array) }
        }
        .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
        .padding(user ? .leading : .trailing, user ? 34 : 0)
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
            HStack(spacing: 6) {
                if pending.state == .checking { ProgressView().controlSize(.mini) }
                Text(pending.state == .delivered ? "已受理 · 正在同步" : pending.note).font(.caption2).foregroundStyle(.secondary)
                if pending.state == .uncertain { Button("查回执") { Task { await model.deliver(pending.id) } }.font(.caption) }
                if pending.state == .rejected && model.draft.isEmpty { Button("回到草稿") { model.draft = pending.text; model.reference = pending.body["reference"].isNull ? nil : pending.body["reference"]; model.removeRejected(pending.id) }.font(.caption) }
            }
        } else if !message["status"].string.isEmpty {
            let status = message["status"].string
            Label(["queued": "已送达 · 排队中", "sending": "已送达 · 正在处理", "running": "已送达 · 执行中", "completed": "已送达", "failed": "本轮失败", "unknown": "执行结果待核实", "approval_required": "等待你确认", "cancelled": "已停止"][status] ?? "已送达", systemImage: status == "failed" || status == "unknown" ? "exclamationmark.circle" : "checkmark")
                .font(.caption2).foregroundStyle(.secondary)
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
        VStack(spacing: 8) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.attachments.map(RemoteRow.init)) { row in
                            HStack { Label(row.value["name"].string, systemImage: "paperclip").lineLimit(1); Button { model.attachments.removeAll { $0.id == row.id }; model.persistNow() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("移除附件") }
                                .font(.caption).padding(10).background(Palette.canvas, in: .capsule)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            if let reference = model.reference {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) { Text("回复 \(reference["author"].string)").font(.caption.weight(.semibold)); Text(reference["text"].string).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                    Spacer(); Button { model.reference = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("取消引用")
                }.padding(12).background(Palette.canvas, in: .rect(cornerRadius: 16))
            }
            ZStack(alignment: .bottom) {

                if model.voice.phase != .idle && !model.showQuickVoice {
                    VoiceSessionPanel()
                } else {
                    HStack(alignment: .bottom, spacing: 10) {
                        Menu {
                            Button("选择文件", systemImage: "doc") { importing = true }
                            PhotosPicker(selection: $photo, matching: .images) { Label("选择照片", systemImage: "photo") }
                            Button("查看成果", systemImage: "tray.full") { model.showSearch = true }
                        } label: { Image(systemName: uploading ? "hourglass" : "plus").frame(width: 30, height: 38) }.tint(.primary).disabled(uploading).accessibilityLabel("附件与成果")
                        TextField("发消息", text: $model.draft, axis: .vertical).lineLimit(1...6).focused($focused).padding(.vertical, 8).accessibilityIdentifier("message-input").chatFrame("composer")
                        if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button { focused = false; model.openVoice() } label: { Image(systemName: "mic").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 36, height: 38) }.tint(.secondary).accessibilityLabel("开始语音")
                        } else {
                            Button {
                                let fromVoice = model.voice.phase == .ready
                                Task { await model.send(voiceMessage: fromVoice); if fromVoice && model.pending.last?.state == .delivered { model.voice.cancel() } }
                            } label: { Image(systemName: "arrow.up").font(.body.weight(.semibold)).foregroundStyle(Palette.onAccent).frame(width: 38, height: 38).background(Palette.accent, in: .circle) }
                                .disabled(model.sending).buttonStyle(MessagePressStyle()).accessibilityLabel("发送消息")
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 7)
                }
            }
            .background(Palette.surface, in: .rect(cornerRadius: 28))
            .shadow(color: .black.opacity(0.06), radius: 14, y: 5)
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
