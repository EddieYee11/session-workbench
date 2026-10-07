import SwiftUI
import ComCore

enum SectionTab: String, CaseIterable, Identifiable {
    case chat = "聊天", today = "今天", tasks = "任务", memory = "记忆", work = "工作"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .chat: "bubble.left"; case .today: "newspaper"; case .tasks: "checkmark.square"; case .memory: "sparkles"; case .work: "square.grid.2x2" }
    }
}

@MainActor @Observable final class AppModel {
    var tab: SectionTab = .chat
    var base = UserDefaults.standard.string(forKey: "base") ?? "https://pi.eddiegao.work:8443/sessions"
    var isPaired = false
    var conversation = ConversationState()
    var datasets: [String: JSON] = [:]
    var fetchedAt: [String: Date] = [:]
    var errors: [String: String] = [:]
    var pending: [PendingMessage] = []
    var draft = ""
    var reference: JSON?
    var attachments: [JSON] = []
    var sending = false
    var lastSubmittedID: String?
    var streaming = false
    var active = false
    var showSettings = false
    var showSearch = false
    var showShareInbox = false
    var showQuickVoice = false
    var jumpMessage: String?
    var selectedTask: JSON?
    var selectedMemory: JSON?
    var selectedMatter: JSON?
    var workJumpMessage: String?
    var selectedSession: JSON?
    var localHealth: JSON = .null
    var banner = ""
    var moreHistory = true
    var voice = VoiceRecorder()
    var devices: DeviceBridge!
    private var api: APIClient?
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var lifecycle = 0
    private var started = false
    private var issuing: Set<String> = []

    // UI test data never reads credentials, calls the server, or persists to the user's cache.
    var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        false
        #endif
    }
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            devices = DeviceBridge(model: self)
            seedUIPreview()
            return
        }
        #endif
        do {
            conversation = try SecureVault.load(ConversationState.self, name: "conversation") ?? ConversationState()
            datasets = try SecureVault.load([String: JSON].self, name: "datasets") ?? [:]
            fetchedAt = try SecureVault.load([String: Date].self, name: "timestamps") ?? [:]
            pending = try SecureVault.load([PendingMessage].self, name: "outbox") ?? []
            draft = try SecureVault.load(String.self, name: "draft") ?? ""
            attachments = try SecureVault.load([JSON].self, name: "draft-attachments") ?? []
            for i in pending.indices { pending[i].recoverAfterRestart() }
            if let key = SecureVault.secret("token"), let token = String(data: key, encoding: .utf8), !token.isEmpty {
                api = try APIClient(base: base, token: token); isPaired = true
            }
        } catch { banner = "本地恢复失败：" + error.localizedDescription }
        devices = DeviceBridge(model: self)
    }
    var client: APIClient? { api }
    var activeRuns: [JSON] { conversation.runs.filter { ["queued", "sending", "running"].contains($0["status"].string) } }
    var busy: Bool { !activeRuns.isEmpty }
    var roleState: String {
        if voice.phase == .recording { return "倾听" }
        if voice.phase == .transcribing { return "转写" }
        if sending { return "发送" }
        return busy ? "思考" : "陪伴"
    }
    func start() async {
        guard !started else { return }; started = true
        await setActive(true)
    }
    func pair(code: String) async throws {
        let candidate = try APIClient(base: base, token: "")
        let data = try await candidate.request("/pair", body: .object(["code": .string(code)]), auth: false)
        let token = data["token"].string
        guard !token.isEmpty else { throw APIError(status: 0, detail: "配对未返回凭据") }
        try SecureVault.storeSecret(Data(token.utf8), account: "token")
        UserDefaults.standard.set(base, forKey: "base")
        api = try APIClient(base: base, token: token); isPaired = true
        await setActive(true)
    }
    func setActive(_ value: Bool) async {
        if isUITesting { active = value; return }
        lifecycle += 1; let currentLifecycle = lifecycle
        active = value; streaming = false
        streamTask?.cancel(); streamTask = nil
        pollTask?.cancel(); pollTask = nil
        devices.stop()
        if !value {
            if voice.phase == .recording { voice.finishRecording() }
            persistNow(); return
        }
        showShareInbox = !ShareInbox.all().isEmpty
        if UserDefaults.standard.bool(forKey: "openVoiceIntent") { UserDefaults.standard.set(false, forKey: "openVoiceIntent"); openVoice(quick: true) }
        guard isPaired else { return }
        await refreshAll()
        guard active, currentLifecycle == lifecycle else { return }
        await recoverOutbox()
        guard active, currentLifecycle == lifecycle else { return }
        startStream()
        await devices.connect()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.active else { return }
                await self.refresh(self.tab)
            }
        }
    }
    func load(_ path: String) async -> JSON? {
        guard let api else { return nil }
        do {
            let data = try await api.request(path)
            datasets[path] = data; fetchedAt[path] = Date(); errors[path] = nil; persistSoon()
            return data
        } catch {
            if !(error is CancellationError) { errors[path] = error.localizedDescription }
            return nil
        }
    }
    func refreshAll() async {
        await refresh(.chat)
        await withTaskGroup(of: Void.self) { group in
            for tab in [SectionTab.today, .tasks, .memory, .work] { group.addTask { await self.refresh(tab) } }
        }
        _ = await load("/health"); _ = await load("/status"); _ = await load("/personal/connectors")
    }
    func refresh(_ tab: SectionTab) async {
        switch tab {
        case .chat:
            if let data = await load("/personal/conversation") { conversation.apply(data, snapshot: true) }
        case .today:
            _ = await load("/personal/briefing"); _ = await load("/personal/overview")
        case .tasks:
            _ = await load("/personal/tasks"); _ = await load("/personal/work/proposals?limit=20")
            _ = await load("/personal/automations")
        case .memory: _ = await load("/personal/memory")
        case .work: _ = await load("/sessions")
        }
    }
    private func startStream() {
        guard let api else { return }
        streamTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.active else { return }
                do {
                    try await api.stream(after: self.conversation.revision > 0 ? self.conversation.revision : nil) { [weak self] event in
                        await self?.receive(event)
                    }
                    failures = 0
                } catch {
                    if Task.isCancelled { return }
                    self.streaming = false; self.errors["/personal/conversation"] = "实时连接中断，正在恢复"
                    failures += 1
                }
                try? await Task.sleep(for: .seconds(min(30, 1 << min(failures, 5))))
            }
        }
    }
    private func receive(_ event: SSEEvent) {
        guard let data = event.data.data(using: .utf8), let value = try? JSON.decode(data) else { return }
        guard event.name == "snapshot" || event.name == "update" else { return }
        let before = Set(conversation.messages.filter { $0["status"].string == "completed" }.map(\.id))
        let previousRevision = conversation.revision
        conversation.apply(value, snapshot: event.name == "snapshot")
        if streaming && event.name == "update" && previousRevision > 0 {
            let fresh = value["messages"].array.contains { $0["role"].string == "assistant" && $0["status"].string == "completed" && !before.contains($0.id) }
            if fresh { Haptics.success() }
        }
        streaming = true; errors["/personal/conversation"] = nil; fetchedAt["/personal/conversation"] = Date()
        persistSoon()
    }
    func loadHistory() async {
        guard moreHistory, let first = conversation.messages.first else { return }
        if let page = await load("/personal/conversation/history?before=" + first.id.queryEncoded + "&limit=60") {
            conversation.prependHistory(page); moreHistory = page["has_more"].bool; persistSoon()
        }
    }
    func locateMessage(_ id: String) async {
        if !conversation.messages.contains(where: { $0.id == id }),
           let page = await load("/personal/conversation/history?around=" + id.queryEncoded + "&limit=60") {
            conversation.prependHistory(page)
        }
        tab = .chat; jumpMessage = id
    }
    func send(voiceMessage: Bool = false, matter: String? = nil) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        var extra: [String: JSON] = [:]
        if let reference { extra["reference"] = reference }
        if !attachments.isEmpty { extra["attachment_ids"] = .array(attachments.map { .string($0.id) }) }
        if let matter { extra["matter_id"] = .string(matter) }
        let entry = PendingMessage(text: text, path: "/personal/conversation/messages", extra: extra)
        pending.append(entry)
        #if DEBUG
        if isUITesting {
            lastSubmittedID = entry.id
            draft = ""; reference = nil; attachments = []
            if ProcessInfo.processInfo.arguments.contains("--ui-send-rejected") {
                pending[pending.count - 1].state = .rejected; pending[pending.count - 1].note = "测试中的发送未被受理"
                return
            }
            try? await Task.sleep(for: .milliseconds(600))
            if let index = pending.firstIndex(where: { $0.id == entry.id }) { pending[index].state = .delivered }
            try? await Task.sleep(for: .milliseconds(600))
            let message = JSON.object(["id": .string("server-" + entry.id), "request_id": .string(entry.id), "role": .string("user"), "text": .string(text), "status": .string("completed"), "created_at": .number(entry.createdAt.timeIntervalSince1970)])
            conversation.messages.append(message); conversation.revision += 1
            return
        }
        #endif
        do { try SecureVault.save(pending, name: "outbox") }
        catch { pending.removeAll { $0.id == entry.id }; banner = "发送记录保存失败，草稿已保留"; return }
        lastSubmittedID = entry.id
        draft = ""; reference = nil; attachments = []; persistNow()
        await deliver(entry.id)
    }
    func deliver(_ id: String) async {
        guard !issuing.contains(id), let api, let index = pending.firstIndex(where: { $0.id == id }), pending[index].state != .delivered else { return }
        issuing.insert(id); sending = true
        defer { issuing.remove(id); sending = !issuing.isEmpty; persistNow() }
        let entry = pending[index]
        do {
            if entry.state != .queued {
                do {
                    let receipt = try await api.request(entry.receiptPath)
                    if receipt["status"].string == "unknown" { pending[index].note = "服务端结果待核实，不会重复提交"; return }
                    pending[index].state = .delivered; pending[index].note = "已受理"
                    await refresh(.chat); return
                } catch let error as APIError where error.status == 404 {
                    // A main-message submission is transactionally idempotent by request_id.
                    guard entry.path.hasPrefix("/personal/") else { pending[index].note = "未查到工作回执，请检查会话"; return }
                }
            }
            pending[index].state = .checking; pending[index].note = "正在发送"
            try SecureVault.save(pending, name: "outbox")
            let receipt = try await api.request(entry.path, body: entry.body)
            if receipt["status"].string == "unknown" {
                pending[index].state = .uncertain; pending[index].note = "送达待核实"
            } else if receipt["status"].string == "rejected" {
                pending[index].state = .rejected; pending[index].note = receipt["error"].string
            } else {
                pending[index].state = .delivered; pending[index].note = "已受理"; Haptics.sent()
            }
            await refresh(.chat)
        } catch {
            if let e = error as? APIError, (400..<500).contains(e.status), e.status != 408, e.status != 429 {
                pending[index].state = .rejected
            } else { pending[index].state = .uncertain }
            pending[index].note = error.localizedDescription
        }
    }
    func recoverOutbox() async {
        for entry in pending where entry.state == .queued || entry.state == .uncertain || entry.state == .checking {
            if entry.path.hasPrefix("/sessions") { _ = await deliverWork(entry.id) } else { await deliver(entry.id) }
        }
    }
    func queueWork(path: String, text: String, fields: [String: JSON]) throws -> PendingMessage {
        guard !pending.contains(where: { $0.path == path && [.queued, .checking, .uncertain].contains($0.state) }) else {
            throw APIError(status: 409, detail: "此会话还有送达待核实的请求，请先在发送记录查询回执")
        }
        let entry = PendingMessage(text: text, path: path, extra: fields)
        pending.append(entry)
        do { try SecureVault.save(pending, name: "outbox") }
        catch { pending.removeAll { $0.id == entry.id }; throw error }
        return entry
    }
    func deliverWork(_ id: String) async -> JSON? {
        guard !issuing.contains(id), let api, let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        issuing.insert(id)
        defer { issuing.remove(id); persistNow() }
        let entry = pending[index]
        do {
            let receipt: JSON
            if entry.state == .queued {
                pending[index].state = .checking
                try SecureVault.save(pending, name: "outbox")
                receipt = try await api.request(entry.path, body: entry.body)
            } else {
                // Missing or unknown work receipts require inspection; never recreate a worker.
                receipt = try await api.request(entry.receiptPath)
            }
            switch receipt["status"].string {
            case "accepted": pending[index].state = .delivered; pending[index].note = "已受理"
            case "rejected": pending[index].state = .rejected; pending[index].note = receipt["error"].string
            default: pending[index].state = .uncertain; pending[index].note = "结果待核实，不会重复提交"
            }
            await refresh(.work)
            return receipt
        } catch {
            pending[index].state = .uncertain; pending[index].note = error.localizedDescription
            return nil
        }
    }
    func disconnect() async {
        await setActive(false)
        SecureVault.deleteSecret("token"); api = nil; isPaired = false; streaming = false
    }
    func removeRejected(_ id: String) { pending.removeAll { $0.id == id && $0.state == .rejected }; persistNow() }
    func mutate(_ path: String, fields: [String: JSON] = [:]) async throws -> JSON {
        guard let api else { throw APIError(status: 0, detail: "请先连接 Mac mini") }
        let body = JSON.object(fields.merging(["request_id": .string(UUID().uuidString.lowercased())]) { a, _ in a })
        let key = "operation-" + body["request_id"].string
        try SecureVault.save(JSON.object(["path": .string(path), "body": body, "status": .string("unknown")]), name: key)
        do {
            let result = try await api.request(path, body: body)
            try SecureVault.save(JSON.object(["path": .string(path), "body": body, "status": .string("received"), "result": result]), name: key)
            return result
        } catch { banner = "操作未确认：" + error.localizedDescription + "。先刷新核对结果。"; throw error }
    }
    func action(_ path: String, fields: [String: JSON] = [:], refresh section: SectionTab? = nil) async {
        do { _ = try await mutate(path, fields: fields); if let section { await refresh(section) }; Haptics.selection() }
        catch { banner = error.localizedDescription }
    }
    func openVoice(quick: Bool = false) {
        guard isPaired else { banner = "先连接 Mac mini，再打开 Com 语音。"; return }
        tab = .chat
        if quick { showQuickVoice = true }
        #if DEBUG
        if isUITesting {
            voice.phase = .recording; voice.seconds = 8; voice.level = 0.8
            voice.levels = (0..<40).map { 0.08 + abs(sin(Double($0) * 0.6)) * 0.75 }
            return
        }
        #endif
        // Never overwrite an unsubmitted capture when the entry opens again.
        if !voice.hasCapture && voice.phase != .transcribing { Task { await voice.start() } }
    }
    func transcribeVoice() async {
        #if DEBUG
        if isUITesting {
            voice.phase = .transcribing
            try? await Task.sleep(for: .milliseconds(300))
            voice.transcript = "帮我整理今天的安排，再留一点时间去攀岩。"
            draft = voice.transcript; voice.phase = .ready
            return
        }
        #endif
        guard let api else { banner = "请先连接 Mac mini"; return }
        await voice.transcribe(using: api)
        if !voice.transcript.isEmpty { draft = voice.transcript; persistNow() }
    }
    func persistSoon() {
        cacheTask?.cancel()
        cacheTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }; self?.persistNow()
        }
    }
    func persistNow() {
        guard !isUITesting else { return }
        do {
            try SecureVault.save(conversation, name: "conversation")
            try SecureVault.save(datasets, name: "datasets")
            try SecureVault.save(fetchedAt, name: "timestamps")
            try SecureVault.save(pending, name: "outbox")
            try SecureVault.save(draft, name: "draft")
            try SecureVault.save(attachments, name: "draft-attachments")
        } catch { banner = "本地保存失败：" + error.localizedDescription }
    }
}

@MainActor enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func sent() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
}

#if DEBUG
extension AppModel {
    func simulateIncomingPreview() {
        guard isUITesting else { return }
        conversation.messages.append(.object(["id": .string(UUID().uuidString), "role": .string("assistant"), "text": .string("新的回复已经到达，阅读位置保留。"), "status": .string("completed"), "created_at": .number(Date().timeIntervalSince1970)]))
        conversation.revision += 1
    }
    private func seedUIPreview() {
        active = true
        isPaired = true
        moreHistory = false
        if ProcessInfo.processInfo.arguments.contains("--ui-quick-voice") { openVoice(quick: true) }
        if let value = ProcessInfo.processInfo.environment["COM_PREVIEW_TAB"], let selected = SectionTab(rawValue: value) { tab = selected }
        let payload = #"""
        {
          "messages": [
            {"id":"preview-1","role":"assistant","text":"你好，小野。\n\n今天的日程和待办已经整理好了。你可以先看简报，也可以把想做的事直接交给我。","created_at":1},
            {"id":"preview-2","role":"user","text":"帮我看看今天有哪些安排","created_at":2},
            {"id":"preview-3","role":"assistant","text":"上午留给内容创作，下午整理项目进度。\n\n我把需要留意的事放在「今天」，进行中的工作也可以随时在「任务」里查看。","created_at":3}
          ],
          "cards": [
            {"id":"brief-1","title":"给今天留一段专注时间","why":"把最需要思考的工作放在上午。整理素材、写下选题，再选一件值得先完成的事。","source":"google_calendar","next_step":"一起安排今天的工作"},
            {"id":"brief-2","title":"Com 的新界面，正在成形","why":"聊天、简报与工作记录连在一起，随时看看事情推进到了哪里。","source":"github"}
          ],
          "tasks": [
            {"id":"task-1","title":"整理本周内容计划","status":"running","completion_condition":"选出三个选题，整理素材与发布安排","updated_at":3},
            {"id":"task-2","title":"查看拍摄素材","status":"waiting","completion_condition":"等你确定这次使用的素材","updated_at":2},
            {"id":"task-3","title":"完成项目进度整理","status":"completed","acceptance_passed":true,"updated_at":1}
          ],
          "memories": [
            {"id":"memory-1","category":"工作","content":"内容创作时，先梳理叙事结构，再决定画面和剪辑节奏。","version":1},
            {"id":"memory-2","category":"兴趣","content":"喜欢攀岩、户外活动，也喜欢探索新工具。","version":1},
            {"id":"memory-3","category":"关于我","content":"沟通直接一点；重要的事情，用实际结果说明。","version":1},
            {"id":"doc-preview","title":"协作偏好 · 共享知识","category":"关于我","kind":"knowledge","read_only":true,"summary":"直接执行并验证结果，保留真实来源。","content":"# 协作偏好 · 共享知识\n\n直接执行并验证结果，保留真实来源。\n\n## 完整内容\n\n这里可以查看共享 Markdown 的完整内容。","version":1,"source":{"type":"shared_markdown","path":"_global/记忆库/知识/协作偏好_Agent工作方式.md","sha256":"preview-only"}}
          ],
          "sessions": [
            {"id":"session-1","title":"整理内容计划","snippet":"选题和素材已归纳，等待下一步安排","agent":"codex","status":"waiting","cwd":"/preview/内容创作"},
            {"id":"session-2","title":"Com iOS 界面更新","snippet":"调整聊天、今天和工作记录的阅读体验","agent":"pi","status":"running","cwd":"/preview/Com"},
            {"id":"session-3","title":"回顾本周进展","snippet":"已完成工作记录整理","agent":"claude","status":"ended","cwd":"/preview/Com"}
          ]
        }
        """#
        guard let data = payload.data(using: .utf8), let fixture = try? JSONDecoder().decode(JSON.self, from: data) else { return }
        conversation.messages = fixture["messages"].array
        if ProcessInfo.processInfo.arguments.contains("--ui-long-chat") {
            conversation.messages = (0..<35).map { i in .object(["id": .string("history-\(i)"), "role": .string(i % 2 == 0 ? "user" : "assistant"), "text": .string("历史消息 \(i)。保留阅读位置，也能顺畅查看新消息。"), "created_at": .number(Double(i)), "status": .string("completed")]) }
        }
        datasets["/personal/briefing"] = .object(["cards": fixture["cards"]])
        datasets["/personal/tasks"] = .object(["items": fixture["tasks"]])
        datasets["/personal/memory"] = .object(["items": fixture["memories"], "categories": .array([.string("工作"), .string("兴趣"), .string("关于我")])])
        datasets["/sessions"] = .object(["sessions": fixture["sessions"]])
        for path in datasets.keys { fetchedAt[path] = Date() }
    }
}
#endif
