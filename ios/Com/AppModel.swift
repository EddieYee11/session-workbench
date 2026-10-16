import SwiftUI
import WidgetKit
import ComCore

/// 四个 tab：对话 / 下一步（它主动整理的建议）/ 在办（真正在跑和等你拍板的任务）/ 工作。
/// 记忆、账本、连接器、设置都在点角色打开的菜单里。
enum SectionTab: String, CaseIterable, Identifiable {
    case chat = "Com", next = "下一步", doing = "今天", work = "工作"  // 轨道 pages：.doing 现在是「今天」时间线，case 名保留免得牵动其他文件
    var id: String { rawValue }
    /// 底栏四页（10-15 Eddie：今天页塞太多，「下一步」拆回独立一页）。
    static let dock: [SectionTab] = [.chat, .next, .doing, .work]
    /// 底部有输入框的页：键盘弹起时 Dock 让位。
    static let typing: Set<SectionTab> = [.chat, .work]
    var symbol: String {
        switch self { case .chat: "face.smiling"; case .next: "shoeprints.fill"; case .doing: "calendar.day.timeline.left"; case .work: "square.grid.2x2" }  // 轨道 r2-pages：next 仅系统兜底，Dock 画自绘靴印
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
    let stage = AgentStageModel()
    private var stageWatchTask: Task<Void, Never>?
    var active = false
    var showSettings = false
    var showSearch = false
    var showShareInbox = false
    var showQuickVoice = false
    var showMenu = false
    var stageExpanded = false
    /// 下拉工作台的展开进度（0 收起 … 1 展开，拖动时跟手，可略超 1）。
    var stageProgress: CGFloat = 0
    /// 等 Eddie 决定的事，按 datasets 变化重算一次，页面直接读，不每帧重算。
    var flowItems: [PendingItem] = []
    var showMemory = false
    var showFinance = false
    var showConnectors = false
    var showNewWork = false
    var showWorkSidebar = false // 工作页历史侧栏，顶栏左上按钮开（r3-work）
    /// 拖侧栏时手指走了多远（往右正、往左负）；松手归零。
    var workSidebarDrag: CGFloat = 0
    /// 侧栏在不在视图树里：开着、拖着、收起动画没走完都在；收完才拿掉（关着的侧栏不留在无障碍树里）。
    var workSidebarMounted = false
    /// 工作页里正打开的那段对话（r3-work：原地聊天，不再弹 WorkDetailView）。
    let work = WorkSessionModel()
    var selectedConnector: JSON?
    var jumpMessage: String?
    var selectedTask: JSON?
    var selectedMatter: JSON?
    var workJumpMessage: String?
    /// 别处（任务详情、项目看板、派活页）要打开的会话：RootView 接住，切到工作页原地打开。
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
    private let cacheWriter = AppCacheWriter()
    private var cacheWriteTask: Task<Void, Never>?
    private var cacheRevision = 0
    private var lifecycle = 0
    private var started = false
    private var issuing: Set<String> = []
    #if DEBUG
    private var connectionStages: [[String: JSON]] = []
    #endif

    // Debug-only, device-readable diagnostics. Never record message text or credentials.
    private func diagnose(_ stage: String, error: Error? = nil) {
        #if DEBUG
        guard !isUITesting else { return }
        var entry: [String: JSON] = ["stage": .string(stage), "at": .number(Date().timeIntervalSince1970)]
        if let error {
            let ns = error as NSError
            entry["error_code"] = .number(Double((error as? APIError)?.status ?? ns.code))
            entry["error_domain"] = .string(ns.domain)
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                entry["underlying_code"] = .number(Double(underlying.code))
                entry["underlying_domain"] = .string(underlying.domain)
                for key in ["_kCFStreamErrorCodeKey", "_kCFStreamErrorDomainKey"] {
                    if let number = underlying.userInfo[key] as? NSNumber { entry[key] = .number(number.doubleValue) }
                }
            }
        }
        connectionStages.append(entry)
        connectionStages = Array(connectionStages.suffix(80))
        let data = JSON.object([
            "active": .bool(active), "paired": .bool(isPaired), "streaming": .bool(streaming),
            "messages": .number(Double(conversation.messages.count)),
            "outbox": .array(pending.map { .object(["id": .string($0.id), "state": .string($0.state.rawValue)]) }),
            "stages": .array(connectionStages.map(JSON.object))
        ])
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: SecureVault.directory.appendingPathComponent("connection-diagnostics.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        #endif
    }

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
            stage.receive("snapshot", .object(["messages": .array(conversation.messages), "activity": .object(["kind": .string("idle")])]))
            if let fixture = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-stage=") }) {
                let kind = String(fixture.dropFirst("--ui-stage=".count))
                stage.receive("task.progress", .object(["kind": .string(kind)]))
                if kind == "delivered" {
                    stage.receive("agent.push", .object(["message_id": .string("stage-fixture-delivery"), "preview": .string("资料整理好了，点开查看。")]))
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-next-building") {
                tab = .next
                Task { [weak self] in try? await Task.sleep(for: .seconds(1)); await self?.refreshNext() }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-r3-cycle") { runR3StageCycle() }  // r3-work：顶栏姿态轮换录屏
            if ProcessInfo.processInfo.arguments.contains("--ui-stage-demo") {
                Task { [weak self] in
                    for kind in ["thinking", "searching", "working", "review", "delivered", "idle"] {
                        guard let self else { return }
                        self.stage.receive("task.progress", .object(["kind": .string(kind == "delivered" ? "idle" : kind)]))
                        if kind == "delivered" { self.stage.receive("agent.push", .object(["message_id": .string("stage-demo-delivery"), "preview": .string("资料整理好了，点开查看。")])) }
                        try? await Task.sleep(for: .seconds(kind == "delivered" ? 3 : 2))
                        self.stage.tick()
                    }
                }
            }
            return
        }
        #endif
        do {
            conversation = try SecureVault.load(ConversationState.self, name: "conversation") ?? ConversationState()
            datasets = try SecureVault.load([String: JSON].self, name: "datasets") ?? [:]
            recomputeFlow()
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
        diagnose("initialized")
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
        stageWatchTask?.cancel(); stageWatchTask = nil
        if value {
            stageWatchTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.stage.tick()
                }
            }
        } else { stage.disconnect() }
        diagnose(value ? "foreground" : "background")
        streamTask?.cancel(); streamTask = nil
        pollTask?.cancel(); pollTask = nil
        devices.stop()
        if !value {
            if voice.phase == .recording { voice.finishRecording() }
            persistNow(); await cacheWriteTask?.value; ComNotifications.schedule(); return
        }
        showShareInbox = !ShareInbox.all().isEmpty
        if UserDefaults.standard.bool(forKey: "openVoiceIntent") { UserDefaults.standard.set(false, forKey: "openVoiceIntent"); openVoice(quick: true) }
        guard isPaired else { return }
        // 先把聊天拉回来并立刻打开实时流，再去拉其余页面：回到前台第一眼就是最新对话，舞台不再先显示离线。
        await refresh(.chat)
        guard active, currentLifecycle == lifecycle else { return }
        startStream()
        await recoverOutbox()
        diagnose("outbox-recovered")
        guard active, currentLifecycle == lifecycle else { return }
        async let rest: Void = refreshOthers()
        await devices.connect()
        diagnose("device-connected")
        await rest
        diagnose("refresh-all-finished")
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.active else { return }
                ticks += 1
                // 流里的便签（事项、待批准、信源状态）每分钟补一次，不随 SSE。
                if ticks % 4 == 0 { await self.refreshFlow(); _ = await self.load("/personal/next") }
                // 聊天页由 SSE 推送；只有流断开时才用快照补拉，避免每 15 秒重复下载整份对话。
                if self.tab == .chat && self.streaming { continue }
                await self.refresh(self.tab)
            }
        }
    }
    func load(_ path: String) async -> JSON? {
        #if DEBUG
        if isUITesting { return datasets[path] }
        #endif
        guard let api else { return nil }
        let route = String(path.split(separator: "?", maxSplits: 1)[0])
        diagnose("load-start:" + route)
        do {
            let data = try await api.request(path)
            let changed = path.hasPrefix("/personal/conversation") || datasets[path] != data
            if changed && !path.hasPrefix("/personal/conversation") { datasets[path] = data; if AppModel.flowPaths.contains(path) { recomputeFlow() } }
            if errors[path] != nil { errors[path] = nil }
            // 内容没变时不刷新时间戳、不落盘：避免每 15 秒让所有读 datasets 的页面重算一遍。
            if changed || fetchedAt[path] == nil { fetchedAt[path] = Date(); updateStatusWidget(); persistSoon() }
            diagnose("load-finished:" + route)
            return data
        } catch {
            diagnose("load-failed:" + route, error: error)
            if !(error is CancellationError) { errors[path] = error.localizedDescription }
            return nil
        }
    }
    private func updateStatusWidget() {
        guard !isUITesting,
              let proposals = datasets["/personal/work/proposals?limit=20"],
              let agency = datasets["/personal/agency"] else { return }
        let reviews = proposals["items"].array.filter { ["proposed", "awaiting_review", "approval_required"].contains($0["status"].string) }.count
        let count = agency["cards"].array.count
        let updated = min(fetchedAt["/personal/work/proposals?limit=20"] ?? .distantPast, fetchedAt["/personal/agency"] ?? .distantPast)
        let old = StatusWidgetSnapshot.read()
        // Token-stream updates never trigger widget reloads.
        guard old?.reviewCount != reviews || old?.briefingCount != count || Date().timeIntervalSince(old?.updatedAt ?? .distantPast) > 900 else { return }
        if StatusWidgetSnapshot(reviewCount: reviews, briefingCount: count, updatedAt: updated).save() { WidgetCenter.shared.reloadTimelines(ofKind: StatusWidgetSnapshot.kind) }
    }
    func refreshAll() async {
        await refresh(.chat)
        await refreshOthers()
    }
    /// 聊天以外的页面与状态接口，全部并发拉取。
    func refreshOthers() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshFlow() }
            group.addTask { await self.refresh(.work) }
            group.addTask { _ = await self.load("/personal/next") }
            for path in ["/health", "/status", "/personal/memory", "/personal/automations"] { group.addTask { _ = await self.load(path) } }
        }
    }
    /// 流里的便签和顶栏角色用到的一切：事项卡、待批准、任务、账本、信源。
    func refreshFlow() async {
        await withTaskGroup(of: Void.self) { group in
            for path in ["/personal/agency", "/personal/work/proposals?limit=20", "/personal/tasks", "/personal/finance", "/personal/connectors"] { group.addTask { _ = await self.load(path) } }
        }
    }
    func refresh(_ tab: SectionTab) async {
        switch tab {
        case .chat:
            if let data = await load("/personal/conversation") { conversation.apply(data, snapshot: true); ComNotifications.observe(conversation.messages) }
        case .next:
            _ = await load("/personal/next"); _ = await load("/personal/connectors"); _ = await load("/personal/finance")
        case .doing:
            await refreshFlow(); _ = await load("/personal/today"); _ = await load("/personal/automations")  // 轨道 pages：今天时间线
        case .work: _ = await load("/personal/projects"); _ = await load("/sessions")
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
                    self.streaming = false; self.stage.disconnect(); self.errors["/personal/conversation"] = "实时连接中断，正在恢复"
                    failures += 1
                }
                try? await Task.sleep(for: .seconds(min(30, 1 << min(failures, 5))))
            }
        }
    }
    private func receive(_ event: SSEEvent) {
        guard let data = event.data.data(using: .utf8), let value = try? JSON.decode(data) else { return }
        if ["heartbeat", "task.progress", "task.review", "agent.push"].contains(event.name) {
            stage.receive(event.name, value)
            if event.name == "agent.push" || event.name == "task.review" {
                ComNotifications.receiveLive(event.name, value, show: !active || tab != .chat)
            }
            return
        }
        guard event.name == "snapshot" || event.name == "update" else { return }
        stage.receive(event.name, value)
        let before = Set(conversation.messages.filter { $0["status"].string == "completed" }.map(\.id))
        let previousRevision = conversation.revision
        conversation.apply(value, snapshot: event.name == "snapshot")
        ComNotifications.observe(conversation.messages)
        if streaming && event.name == "update" && previousRevision > 0 {
            let fresh = value["messages"].array.contains { $0["role"].string == "assistant" && $0["status"].string == "completed" && !before.contains($0.id) }
            if fresh { Haptics.success() }
        }
        streaming = true; errors["/personal/conversation"] = nil; fetchedAt["/personal/conversation"] = Date()
        diagnose("stream:" + event.name)
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
    func send(voiceMessage: Bool = false, matter: String? = nil, textOverride: String? = nil) async {
        let text = (textOverride ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, (!sending || voiceMessage) else { return }
        var extra: [String: JSON] = [:]
        if let reference { extra["reference"] = reference }
        if !attachments.isEmpty { extra["attachment_ids"] = .array(attachments.map { .string($0.id) }) }
        if let matter { extra["matter_id"] = .string(matter) }
        let voiceID = voiceMessage ? "voice-" + voice.captureID : nil
        if let voiceID, pending.contains(where: { $0.id == voiceID }) { return }
        let entry = PendingMessage(text: text, path: "/personal/conversation/messages", extra: extra, requestID: voiceID)
        pending.append(entry)
        #if DEBUG
        if isUITesting {
            lastSubmittedID = entry.id
            if voiceMessage { voice.cancel(); showQuickVoice = false }
            if textOverride == nil { draft = "" }; reference = nil; attachments = []
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
        if voiceMessage { voice.cancel(); showQuickVoice = false }
        if textOverride == nil { draft = "" }; reference = nil; attachments = []; persistNow()
        await deliver(entry.id)
    }
    func deliver(_ id: String) async {
        guard !issuing.contains(id), let api, let index = pending.firstIndex(where: { $0.id == id }), pending[index].state != .delivered else { return }
        issuing.insert(id); sending = true
        diagnose("deliver-start:" + id)
        defer { issuing.remove(id); sending = !issuing.isEmpty; persistNow() }
        let entry = pending[index]
        do {
            if entry.state != .queued {
                do {
                    let receipt = try await api.request(entry.receiptPath)
                    if receipt["status"].string == "unknown" { updatePending(id) { $0.note = "服务端结果待核实，不会重复提交" }; return }
                    updatePending(id) { $0.state = .delivered }; updatePending(id) { $0.note = "已受理" }
                    await refresh(.chat); return
                } catch let error as APIError where error.status == 404 {
                    // A main-message submission is transactionally idempotent by request_id.
                    guard entry.path.hasPrefix("/personal/") else { updatePending(id) { $0.note = "未查到工作回执，请检查会话" }; return }
                }
            }
            updatePending(id) { $0.state = .checking }; updatePending(id) { $0.note = "正在发送" }
            try SecureVault.save(pending, name: "outbox")
            let receipt = try await api.request(entry.path, body: entry.body)
            diagnose("deliver-receipt:" + receipt["status"].string)
            if receipt["status"].string == "unknown" {
                updatePending(id) { $0.state = .uncertain }; updatePending(id) { $0.note = "送达待核实" }
            } else if receipt["status"].string == "rejected" {
                updatePending(id) { $0.state = .rejected }; updatePending(id) { $0.note = receipt["error"].string }
            } else {
                updatePending(id) { $0.state = .delivered }; updatePending(id) { $0.note = "已受理" }; Haptics.sent()
            }
            await refresh(.chat)
        } catch {
            diagnose("deliver-failed:" + id, error: error)
            if let e = error as? APIError, (400..<500).contains(e.status), e.status != 408, e.status != 429 {
                updatePending(id) { $0.state = .rejected }
            } else { updatePending(id) { $0.state = .uncertain } }
            updatePending(id) { $0.note = error.localizedDescription }
        }
    }
    func recoverOutbox() async {
        for entry in pending where entry.state == .queued || entry.state == .uncertain || entry.state == .checking {
            if entry.path.hasPrefix("/sessions") { _ = await deliverWork(entry.id) } else { await deliver(entry.id) }
        }
    }
    func interrupt() async {
        guard let api, stage.state.isBusy else { return }
        do {
            _ = try await api.request("/personal/conversation/interrupt", body: .object([:]))
            stage.receive("task.progress", .object(["kind": .string("idle")]))
            banner = "已中断"
        } catch {
            banner = "中断失败: \(error.localizedDescription)"
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
                updatePending(id) { $0.state = .checking }
                try SecureVault.save(pending, name: "outbox")
                receipt = try await api.request(entry.path, body: entry.body)
            } else {
                // Missing or unknown work receipts require inspection; never recreate a worker.
                receipt = try await api.request(entry.receiptPath)
            }
            switch receipt["status"].string {
            case "accepted": updatePending(id) { $0.state = .delivered }; updatePending(id) { $0.note = "已受理" }
            case "rejected": updatePending(id) { $0.state = .rejected }; updatePending(id) { $0.note = receipt["error"].string }
            default: updatePending(id) { $0.state = .uncertain }; updatePending(id) { $0.note = "结果待核实，不会重复提交" }
            }
            await refresh(.work)
            return receipt
        } catch {
            updatePending(id) { $0.state = .uncertain }; updatePending(id) { $0.note = error.localizedDescription }
            return nil
        }
    }
    func disconnect() async {
        if let api { await ComPush.disable(using: api) }
        await setActive(false)
        StatusWidgetSnapshot.clear(); WidgetCenter.shared.reloadTimelines(ofKind: StatusWidgetSnapshot.kind)
        SecureVault.deleteSecret("token"); api = nil; isPaired = false; streaming = false
    }
    private func updatePending(_ id: String, _ edit: (inout PendingMessage) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        edit(&pending[index])
    }
    func removeRejected(_ id: String) { pending.removeAll { $0.id == id && $0.state == .rejected }; persistNow() }
    func restoreRejected(_ id: String) {
        guard draft.isEmpty, attachments.isEmpty, let entry = pending.first(where: { $0.id == id && $0.state == .rejected }) else { return }
        draft = entry.text
        reference = entry.body["reference"].isNull ? nil : entry.body["reference"]
        attachments = entry.body["attachment_ids"].array.enumerated().map { index, value in
            .object(["id": value, "name": .string("附件 \(index + 1)")])
        }
        removeRejected(id)
    }
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

    // MARK: 工作页侧栏（r3-work）：主内容连同 Dock 一起往右推走，侧栏占满整屏高度

    /// 动效库 04-screenshot-cascade：卡片「指数减速」滑入、同一条曲线；手机上用临界阻尼弹簧，拖到一半松手也接得上速度。
    static let sidebarMotion = Animation.spring(response: 0.42, dampingFraction: 0.9)
    func openWorkSidebar(reduce: Bool = false) {
        withAnimation(reduce ? .easeOut(duration: 0.2) : Self.sidebarMotion) { workSidebarMounted = true; showWorkSidebar = true; workSidebarDrag = 0 }
    }
    /// 收起：侧栏和主内容沿同一条曲线回去（侧栏右边缘一直贴着主内容左边缘），走完再从视图树里拿掉。
    func closeWorkSidebar(reduce: Bool = false) {
        withAnimation(reduce ? .easeOut(duration: 0.2) : Self.sidebarMotion) { showWorkSidebar = false; workSidebarDrag = 0 } completion: { [weak self] in
            guard let self, !self.showWorkSidebar, self.workSidebarDrag == 0 else { return }
            self.workSidebarMounted = false
        }
    }
    /// 拖动中跟手（不带动画）。
    func dragWorkSidebar(_ translation: CGFloat) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { workSidebarMounted = true; workSidebarDrag = translation }
    }
    /// 松手：按预测落点过不过一半决定开合。
    func settleWorkSidebar(predicted: CGFloat, width: CGFloat, reduce: Bool = false) {
        let base: CGFloat = showWorkSidebar ? width : 0
        if base + predicted > width / 2 { openWorkSidebar(reduce: reduce) } else { closeWorkSidebar(reduce: reduce) }
    }
    func openVoice(quick: Bool = false) {
        guard isPaired else { banner = "先连接 Mac mini，再打开 Com 语音。"; return }
        tab = .chat
        if quick { showQuickVoice = true }
        #if DEBUG
        if isUITesting {
            if ProcessInfo.processInfo.arguments.contains("--ui-voice-during-send") { sending = true }
            voice.captureID = UUID().uuidString.lowercased()
            voice.phase = .recording; voice.seconds = 8; voice.level = 0.8
            voice.levels = (0..<40).map { 0.08 + abs(sin(Double($0) * 0.6)) * 0.75 }
            return
        }
        #endif
        // Never overwrite an unsubmitted capture when the entry opens again.
        if !voice.hasCapture && voice.phase != .transcribing { Task { await voice.start(using: api) } }
    }
    func transcribeVoice() async {
        guard voice.phase != .transcribing && voice.phase != .ready else { return }
        let capture = voice.captureID
        #if DEBUG
        if isUITesting {
            voice.phase = .transcribing
            try? await Task.sleep(for: .milliseconds(300))
            guard voice.captureID == capture, voice.phase == .transcribing else { return }
            voice.transcript = "帮我整理今天的安排，再留一点时间去攀岩。"
            voice.phase = .ready
        } else {
            guard let api else { banner = "请先连接 Mac mini"; return }
            await voice.transcribe(using: api)
        }
        #else
        guard let api else { banner = "请先连接 Mac mini"; return }
        await voice.transcribe(using: api)
        #endif
        guard voice.phase == .ready, voice.captureID == capture, !voice.transcript.isEmpty else { return }
        // Show the glyph reveal before entering the same durable text-message outbox.
        let text = voice.transcript
        try? await Task.sleep(for: .milliseconds(1200))
        guard !Task.isCancelled, voice.phase == .ready, voice.captureID == capture else { return }
        await send(voiceMessage: true, textOverride: text)
        if voice.phase == .ready {
            voice.error = "发送暂未进入队列，录音已保留，请稍后重试。"
            voice.phase = .failed
        }
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
        do { try SecureVault.save(pending, name: "outbox") }
        catch { banner = "发送记录保存失败：" + error.localizedDescription }
        cacheRevision += 1
        let revision = cacheRevision
        let snapshot = AppCacheSnapshot(conversation: conversation,
            datasets: datasets.filter { !$0.key.hasPrefix("/personal/conversation") },
            timestamps: fetchedAt, draft: draft, attachments: attachments)
        cacheWriteTask = Task { [weak self, cacheWriter] in
            do { try await cacheWriter.save(snapshot, revision: revision) }
            catch { self?.banner = "本地保存失败：" + error.localizedDescription }
        }
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
        tab = .chat
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
            {"id":"task-3","title":"完成项目进度整理","status":"completed","acceptance_passed":true,"updated_at":1},
            {"id":"task-old","title":"核对上个月的报销单","status":"unknown","completion_condition":"确认报销单是否已提交","updated_at":2}
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
        if ProcessInfo.processInfo.arguments.contains("--ui-stress-chat") {
            conversation.messages = (0..<301).map { i in
                let text = i % 3 == 1 ? "## 回复 \(i)\n\n" + String(repeating: "这一段包含**重点**、上下文与核验说明。长消息也应顺畅阅读。\n\n", count: 12) : "历史消息 \(i)。保持阅读位置，回到最新可可靠到达。"
                return .object(["id": .string("stress-\(i)"), "role": .string(i % 2 == 0 ? "user" : "assistant"), "text": .string(text), "created_at": .number(Double(i)), "status": .string("completed")])
            }
        }
        datasets["/personal/work/proposals?limit=20"] = .object(["items": .array([])])
        if ProcessInfo.processInfo.arguments.contains("--ui-rich-reply") {
            conversation.messages = [.object(["id": .string("rich-preview"), "role": .string("assistant"), "text": .string("## 今日重点\n\n**先完成核心任务**，再处理零散事项。\n\n### 下一步\n\n- 梳理项目资料\n- 确认交付时间\n\n> 来源与建议分开核对。")])]
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-work-process") { seedWorkProcessPreview() }  // chat 轨道：工作过程验收
        if ProcessInfo.processInfo.arguments.contains("--ui-reply-layout") { seedReplyLayoutPreview() }  // r2-chat：排版 + 建议卡验收
        // 聊天机制类的验收（长对话、压力、发送失败、语音）不铺流里的便签，免得把最新一条气泡顶出屏幕。
        let chatOnly = ["--ui-long-chat", "--ui-stress-chat", "--ui-send-rejected", "--ui-reduce-motion", "--ui-voice-during-send", "--ui-quick-voice"].contains { ProcessInfo.processInfo.arguments.contains($0) }
        datasets["/personal/connectors"] = .object(["sources": .array([
            .object(["name": .string("gmail"), "status": .string("needs_connection")]),
            .object(["name": .string("github"), "status": .string("connected")]),
            .object(["name": .string("garmin"), "status": .string("needs_connection")])
        ])])
        // 前三条任务用「现在」附近的时间戳，第四条留在远古：验收旧任务折叠归档。
        let now = Date().timeIntervalSince1970
        datasets["/personal/tasks"] = .object(["items": .array(fixture["tasks"].array.enumerated().map { index, task in
            var copy = task; if task.id != "task-old" { copy["updated_at"] = .number(now - Double(index) * 60) }; return copy
        })])
        datasets["/personal/memory"] = .object(["items": fixture["memories"], "categories": .array([.string("工作"), .string("兴趣"), .string("关于我")])])
        datasets["/sessions"] = .object(["sessions": fixture["sessions"]])
        if !chatOnly { datasets["/personal/agency"] = .object([
            "cards": .array(fixture["cards"].array.map { card in
                var value = card; value["kind"] = .string("meeting"); value["source_label"] = .string("日历"); value["version"] = .string("preview-1")
                value["facts"] = .object(["安排": .string("确认今天的内容重点"), "来源": .string("界面验收资料")]); return value
            }),
            "goals": .array([]), "sources": .array([]), "working": .array(Array(fixture["tasks"].array.prefix(1))), "reports": .array([]),
            "settings": .object(["paused": .bool(false), "intensity": .string("balanced"), "items": .array([
                .object(["id": .string("morning-briefing"), "at": .string("09:00"), "enabled": .bool(true)]),
                .object(["id": .string("evening-review"), "at": .string("21:00"), "enabled": .bool(true)])])])]) }
        seedDashboardPreview(chatOnly: chatOnly)
        datasets["/personal/next"] = .object(["running": .bool(false), "updated_at": .number(Date().timeIntervalSince1970 - 600), "source": .string("model"),
            "week": .object(["shown": .number(6), "acted": .number(3), "dismissed": .number(1)]),
            "items": .array([
                .object(["id": .string("next-reply"), "title": .string("回复王总的排期邮件"), "why": .string("王总上午问 Q4 排期，今天下班前要给答复。"), "urgency": .string("now"), "score": .number(90),
                         "prompt": .string("起草一封回复王总排期邮件的草稿给我确认。"), "evidence": .array([.object(["ref": .string("mail:m1"), "label": .string("工作邮箱 · Q4 排期确认"), "kind": .string("mail")]), .object(["ref": .string("event:m3"), "label": .string("日程 · 排期评审"), "kind": .string("event")])])]),
                .object(["id": .string("next-meeting"), "title": .string("会前过一遍周会议题"), "why": .string("11:00 周会，上周的两个待办还没收尾。"), "urgency": .string("today"), "score": .number(70),
                         "prompt": .string("帮我准备 11 点的周会。"), "evidence": .array([.object(["ref": .string("event:m3"), "label": .string("日程 · 周会"), "kind": .string("event")])])]),
                .object(["id": .string("next-project"), "title": .string("推进 Com 语音小窗验收"), "why": .string("光效和入口已完成，还差一次真机录音。"), "urgency": .string("week"), "score": .number(50),
                         "prompt": .string("提醒我用操作按钮录一次音并检查发送结果。"), "evidence": .array([.object(["ref": .string("project:p1"), "label": .string("项目 · Com · 个人 Agent"), "kind": .string("project")])])])
            ])])
        // 验收用：COM_FIXTURE_DIR 里放后端真实返回（memory.json / sessions.json / projects.json），按真实数据量看排版。
        if let dir = ProcessInfo.processInfo.environment["COM_FIXTURE_DIR"] {
            for (file, path) in [("memory", "/personal/memory"), ("sessions", "/sessions"), ("projects", "/personal/projects")] {
                if let data = FileManager.default.contents(atPath: dir + "/" + file + ".json"), let value = try? JSONDecoder().decode(JSON.self, from: data) { datasets[path] = value }
            }
        }
        switch ProcessInfo.processInfo.environment["COM_PREVIEW_SHEET"] ?? "" {
        case "memory": showMemory = true
        case "settings": showSettings = true
        case "search": showSearch = true
        case "finance": showFinance = true
        case "connectors": showConnectors = true
        case "share": showShareInbox = true
        case "task": selectedTask = datasets["/personal/tasks"]?["items"].array.first
        default: break
        }
        seedPagesPreview()  // 轨道 pages：今天时间线与依据详情的验收数据
        if ProcessInfo.processInfo.arguments.contains("--ui-r3-work") { seedR3WorkPreview() }  // r3-work：工作页原地聊天
        for path in datasets.keys { fetchedAt[path] = Date() }
        recomputeFlow()
    }
}

// r3-work：工作页原地聊天、顶栏人物录屏的验收数据。
extension AppModel {
    /// `--ui-r3-work`：三段会话的详情（Codex 等你批准、Pi 正在跑、Claude 已结束可恢复）+ 模型目录 + 目录浏览。
    /// 加 `--ui-r3-open=<会话 id>` 启动就停在那段对话上。
    func seedR3WorkPreview() {
        // 每次启动从同一个起点验收：派给 Codex、看 Mac mini 的全部对话。
        for key in ["work.lastAgent", "work.host", "work.agent"] { UserDefaults.standard.removeObject(forKey: key) }
        let now = Date().timeIntervalSince1970
        func message(_ id: String, _ role: String, _ text: String, title: String = "", at: Double) -> JSON {
            .object(["id": .string(id), "role": .string(role), "title": .string(title), "text": .string(text), "time": .number(at)])
        }
        let capabilities: (Bool, Bool) -> JSON = { input, resume in .object(["history": .bool(true), "input": .bool(input), "resume": .bool(resume)]) }
        datasets["/sessions/" + "session-1".pathEncoded] = .object([
            "session": .object(["id": .string("session-1"), "title": .string("整理内容计划"), "agent": .string("codex"), "status": .string("waiting"), "cwd": .string("/preview/内容创作"), "capabilities": capabilities(true, false)]),
            "messages": .array([
                message("s1-u1", "user", "帮我把本周的选题和素材理一下，看看哪个可以先做", at: now - 1800),
                message("s1-t1", "tool", "rg -n \"选题\" work/内容生产/选题管理", title: "exec_command", at: now - 1790),
                message("s1-t2", "tool", "02-待发布/岩馆探馆/README.md", title: "read_file", at: now - 1785),
                message("s1-t3", "tool", "ls work/内容生产/素材", title: "exec_command", at: now - 1780),
                message("s1-a1", "assistant", "理完了，本周一共 **3 个选题**：\n\n- **岩馆探馆**：素材齐了，差一段开场口播\n- **AI 调色**：还缺两段对比镜头\n- **川西摩旅**：可以直接剪\n\n建议先做 **川西摩旅**，今天就能出初剪。", at: now - 1760),
                message("s1-u2", "user", "那先把川西的素材按天建好文件夹", at: now - 600),
                message("s1-t4", "tool", "mkdir -p 素材/川西/D1 素材/川西/D2", title: "exec_command", at: now - 590),
            ])])
        datasets["/sessions/" + "session-1".pathEncoded + "/live"] = .object(["status": .string("waiting"), "items": .array([]), "approvals": .array([
            .object(["id": .string("approval-1"), "params": .object(["reason": .string("要在素材目录里新建两个文件夹"), "command": .string("mkdir -p 素材/川西/D1 素材/川西/D2")])])
        ])])
        datasets["/sessions/" + "session-2".pathEncoded] = .object([
            "session": .object(["id": .string("session-2"), "title": .string("Com iOS 界面更新"), "agent": .string("pi"), "status": .string("running"), "cwd": .string("/preview/Com"), "capabilities": capabilities(true, false)]),
            "messages": .array([
                message("s2-u1", "user", "把工作页改成 ChatGPT 那样，点历史直接在一页里聊", at: now - 300),
                message("s2-a1", "assistant", "好，我先看一下现在工作页的结构。", at: now - 290),
            ])])
        datasets["/sessions/" + "session-2".pathEncoded + "/live"] = .object(["status": .string("running"), "approvals": .array([]), "items": .array([
            message("s2-t1", "tool", "rg -n \"WorkDetailView\" ios/Com", title: "bash · 已结束", at: now - 280),
            message("s2-t2", "tool", "ios/Com/Views/WorkHome.swift", title: "read · 执行中", at: now - 20),
        ])])
        datasets["/sessions/" + "session-3".pathEncoded] = .object([
            "session": .object(["id": .string("session-3"), "title": .string("回顾本周进展"), "agent": .string("claude"), "status": .string("ended"), "cwd": .string("/preview/Com"), "capabilities": capabilities(false, true)]),
            "messages": .array([
                message("s3-u1", "user", "回顾一下这周 Com 做了哪些事", at: now - 86400 * 2),
                message("s3-a1", "assistant", "这周 Com 主要做了三件事：\n\n1. **聊天页排版**：长回复分段、重点加粗\n2. **今天页**：日程和待办合成一条时间线\n3. **工作页**：历史收进侧栏", at: now - 86400 * 2 + 30),
            ])])
        datasets["/sessions/" + "session-3".pathEncoded + "/live"] = .object(["status": .string("ended"), "items": .array([]), "approvals": .array([])])
        datasets["/models?agent=codex"] = .object(["models": .array([
            .object(["id": .string("gpt-5.5"), "label": .string("GPT-5.5"), "efforts": .array([.string("low"), .string("medium"), .string("high")])]),
            .object(["id": .string("gpt-5.5-mini"), "label": .string("GPT-5.5 mini"), "efforts": .array([])])])])
        datasets["/models?agent=claude"] = .object(["models": .array([.object(["id": .string("claude-opus"), "label": .string("Claude Opus"), "efforts": .array([])])])])
        datasets["/models?agent=pi"] = .object(["models": .array([.object(["id": .string("deepseek/v4"), "label": .string("v4"), "efforts": .array([.string("off"), .string("high")])])])])
        datasets["/models?agent=hermes"] = .object(["models": .array([.object(["id": .string("deepseek-v4-flash"), "label": .string("DeepSeek"), "efforts": .array([])])])])
        let root = WorkSessionModel.defaultDirectory
        datasets["/directories?path=" + root.queryEncoded] = .object(["path": .string(root), "parent": .string("/Users/eddiegao"),
            "directories": .array(["_global", "projects", "work"].map { .string(root + "/" + $0) }), "recent": .array([.string(root + "/work/工具与效率")])])
        if let open = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-r3-open=") }).map({ String($0.dropFirst("--ui-r3-open=".count)) }),
           let session = datasets["/sessions"]?["sessions"].array.first(where: { $0.id == open }) {
            tab = .work; work.open(session)
        }
    }

    /// `--ui-r3-cycle`：顶栏姿态慢速轮换（每步 3 秒）：空闲 → 思考 → 翻资料 → 干活 → 等你点头 → 送达 → 空闲。
    func runR3StageCycle() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            for kind in ["thinking", "searching", "working", "review", "delivered", "idle"] {
                guard let self else { return }
                self.stage.receive("task.progress", .object(["kind": .string(kind == "delivered" ? "idle" : kind)]))
                if kind == "delivered" { self.stage.receive("agent.push", .object(["message_id": .string("r3-cycle-delivery"), "preview": .string("资料整理好了。")])) }
                try? await Task.sleep(for: .seconds(3))
                self.stage.tick()
            }
        }
    }
}
#endif
