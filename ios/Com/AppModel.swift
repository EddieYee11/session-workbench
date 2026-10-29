import SwiftUI
import WidgetKit
import ComCore

/// 四个 tab：对话 / 下一步（它主动整理的建议）/ 在办（真正在跑和等你拍板的任务）/ 工作。
/// 记忆、账本、连接器、设置都在点角色打开的菜单里。
enum SectionTab: String, CaseIterable, Identifiable {
    case chat = "Com", next = "下一步", doing = "今天", health = "健康", work = "工作"  // 轨道 pages：.doing 现在是「今天」时间线，case 名保留免得牵动其他文件
    var id: String { rawValue }
    /// 底栏四页（10-15 Eddie：今天页塞太多，「下一步」拆回独立一页）。
    static let dock: [SectionTab] = [.chat, .next, .doing, .health, .work]  // 10-17：身体数据单独一页「健康」
    /// 双栏右栏的页面：去掉常驻左栏的 Com 主对话。
    static let workspace: [SectionTab] = [.next, .doing, .health, .work]
    /// 底部有输入框的页：键盘弹起时 Dock 让位。
    static let typing: Set<SectionTab> = [.chat, .work]
    var symbol: String {
        switch self { case .chat: "face.smiling"; case .next: "shoeprints.fill"; case .doing: "calendar.day.timeline.left"; case .health: "heart.text.square"; case .work: "square.grid.2x2" }  // 轨道 r2-pages：next 仅系统兜底，Dock 画自绘靴印
    }
}

@MainActor @Observable final class AppModel {
    var tab: SectionTab = .chat { didSet { if tab != .chat { rightTab = tab } } }
    /// 展开的折叠屏（宽屏）双栏：左栏常驻 Com 主对话，右栏显示这一页；任何「跳到某页」仍然只写 tab。
    var rightTab: SectionTab = .next  // 10-25：展开后右栏先给下一步（用得最多）
    var splitView = false
    /// 这一页此刻在屏幕上：单栏时是当前 tab，双栏时是左栏的聊天和右栏的 rightTab。
    func isShown(_ page: SectionTab) -> Bool { splitView ? (page == .chat || page == rightTab) : tab == page }
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
    /// 主聊 SSE 断线开口；仅真正收到 snapshot/update 才清。HTTP 快照拉齐不得清（假「已恢复」）。
    var streamNote = ""
    /// 灵动岛开启失败 / 系统关闭实时活动：设置「平台能力」开口，不假装岛上还在跳。
    var liveActivityNote = ""
    /// 小组件 Keychain 写入失败：不 reload 成假新鲜，设置页开口。
    var widgetUpdateNote = ""
    /// 主聊 AppCache（含草稿）落盘/恢复失败：作曲器旁开口，不假装已落盘或已恢复。
    var cachePersistNote = ""
    /// 前台探测分享收件箱：App Group 失败时开口，勿用空列表假装「没有分享」。
    var shareInboxNote = ""
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
    var showActivity = false  // 10-25 活动日志：它替你做过的写操作
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
    /// 正在用语音回答的审批：{id, params}，由审批卡上的「用语音说」设置。
    var pendingApproval: JSON?
    /// 审批双路径（卡片 / 语音）共享失败开口：关语音窗后卡上仍能看见，勿只靠 banner。
    var approvalFailNote = ""
    var approvalFailID = ""
    /// 审批深链缺 sid / 对不准时工作页开口，不假装已对准会话。
    var approvalDeepLinkNote = ""
    /// 未配对时被语音等入口拦住：留在配对页（不只靠 banner alert）。
    var pairGateNote = ""
    /// 审批推送的深链：有 sid 开工作会话；仅有审批 id（Bark `approval?id=`）进「等你」，别假装开了会话。
    func openApproval(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let sid = items?.first(where: { $0.name == "sid" })?.value ?? ""
        let approvalID = items?.first(where: { $0.name == "id" })?.value ?? ""
        let sidTrim = sid.trimmingCharacters(in: .whitespacesAndNewlines)
        let idTrim = approvalID.trimmingCharacters(in: .whitespacesAndNewlines)
        if sidTrim.isEmpty, !idTrim.isEmpty {
            // 推送常带审批号、会话可能未写入——进统一「等你」找待批，不硬开空工作页。
            openWaitingInbox()
            approvalDeepLinkNote = "审批链接只有审批号、没有会话——已打开「等你」找待批。点卡批准；不会假装已对准工作会话。"
            return
        }
        openApproval(sid: sidTrim)
    }
    func openApproval(sid: String) {
        tab = .work
        let trimmed = sid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            approvalDeepLinkNote = "审批链接少了会话——对不准要拍板的那一段。可打开「等你」找待批，或从通知再进一次。不会假装已对准。"
            return
        }
        approvalDeepLinkNote = ""
        work.open(.object(["id": .string(trimmed), "agent": .string("codex")]))
        Task { await work.refresh(self) }
    }
    /// 10-17 航程：要打开的航程 id（聊天里的航程卡、今天页、推送深链都走这里，RootView 用 sheet 接住）；showCases 打开航程列表。
    var presentedCase: String?
    var showCases = false
    /// 10-18 统一「等你」收件箱：审批 + 等你批准的航程 + 微信在等回话 + 过期待办。
    var showWaiting = false
    var localHealth: JSON = .null
    var banner = ""
    /// 主聊 Composer 发送失败开口（别只靠气泡旁注或 banner alert）。
    var chatComposerNote = ""
    /// 主聊打断失败开口（别只靠 banner alert）。
    var interruptNote = ""
    /// 定位某条消息失败开口（搜索/线索/推送；别只靠 banner alert）。
    var locateNote = ""
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
            // 今天页记住的展开状态每次验收都从默认开始；要先展开表盘 / 时间线的用例带 --ui-today-dial / --ui-today-timeline。
            let args = ProcessInfo.processInfo.arguments, defaults = UserDefaults.standard
            ["today.brief.open", "today.now.open", "today.deck", "health.done", "health.span"].forEach(defaults.removeObject(forKey:))
            if args.contains("--ui-today-dial") { defaults.set("dial", forKey: "today.now.open") }
            if args.contains("--ui-today-timeline") { defaults.set("timeline", forKey: "today.deck") }
            // 双栏验收：--ui-tab=下一步 / 今天 / 健康 / 工作，启动就停在那一页（折叠屏右栏逐页截图用）。
            if let flag = args.first(where: { $0.hasPrefix("--ui-tab=") }), let page = SectionTab(rawValue: String(flag.dropFirst("--ui-tab=".count))) { tab = page }
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
            for i in pending.indices { pending[i].recoverAfterRestart() }
            if let key = SecureVault.secret("token"), let token = String(data: key, encoding: .utf8), !token.isEmpty {
                api = try APIClient(base: base, token: token); isPaired = true
            }
        } catch { banner = "本地恢复失败：" + error.localizedDescription }
        // 草稿单独恢复：失败别并进总 catch 后静默空框，像「没写过」。
        do {
            draft = try SecureVault.load(String.self, name: "draft") ?? ""
            attachments = try SecureVault.load([JSON].self, name: "draft-attachments") ?? []
            cachePersistNote = ""
        } catch {
            draft = ""
            attachments = []
            cachePersistNote = "上次主聊草稿没读上：\(error.localizedDescription)——输入框是空的，不代表你没写过。不会假装已恢复。"
        }
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
        pairGateNote = ""
        await setActive(true)
    }
    /// 深链 `com-eddie://pair?base=&code=`：无码/无地址/已配对都开口，不静默吞、不假装已配对。
    func applyPairDeepLink(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let rawBase = items?.first(where: { $0.name == "base" })?.value ?? ""
        let rawCode = items?.first(where: { $0.name == "code" })?.value ?? ""
        let baseTrim = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeTrim = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.removeObject(forKey: "pendingPairNote")
        if isPaired {
            // 已配对：不写 pendingPairCode，避免解除配对后误用旧扫码。
            banner = "这台设备已经配对；要换服务器，请先在设置里解除配对。不会用这条链接改配对。"
            return
        }
        if !baseTrim.isEmpty { base = baseTrim }
        if codeTrim.isEmpty {
            let note = baseTrim.isEmpty
                ? "配对链接不完整——少了服务地址和配对码。请用完整二维码，或在配对页手动填。不会假装已配对。"
                : "配对链接少了码——地址已填上，请补一次性配对码再连。不会假装已配对。"
            UserDefaults.standard.set(note, forKey: "pendingPairNote")
            banner = note
            return
        }
        UserDefaults.standard.set(codeTrim, forKey: "pendingPairCode")
        if baseTrim.isEmpty {
            let note = "配对链接少了服务地址——码已填上，请补 HTTPS 地址再连。不会假装已配对。"
            UserDefaults.standard.set(note, forKey: "pendingPairNote")
            banner = note
        }
    }
    func setActive(_ value: Bool) async {
        if isUITesting { active = value; return }
        lifecycle += 1; let currentLifecycle = lifecycle
        active = value; streaming = false
        if !value { streamNote = "" }  // 进后台断流是预期，别留下「假恢复」告警
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
        refreshShareInboxPresence()
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
                if self.splitView {
                    if !self.streaming { await self.refresh(.chat) }
                    await self.refresh(self.rightTab)
                    continue
                }
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
            // 流式断线提示不因 HTTP 拉齐清掉：拉齐成功 ≠ SSE 已恢复。
            if let existing = errors[path] {
                let keepStream = path.hasPrefix("/personal/conversation") && isStreamDisconnectNote(existing)
                if !keepStream { errors[path] = nil }
            }
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
    private func isStreamDisconnectNote(_ text: String) -> Bool {
        text.contains("实时连接") || text.contains("正在恢复") || text.contains("正在重连") || text.contains("不会假装已恢复")
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
        if StatusWidgetSnapshot(reviewCount: reviews, briefingCount: count, updatedAt: updated).save() {
            widgetUpdateNote = ""
            WidgetCenter.shared.reloadTimelines(ofKind: StatusWidgetSnapshot.kind)
        } else {
            // 写入失败不 reload：旧数还在 Keychain 里，别假装小组件已是本次结果。
            widgetUpdateNote = "小组件数量没写上——锁屏/主屏还是上次成功同步的数。回到前台再刷一次；不会假装这次已更新。"
        }
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
    /// 流里的便签和顶栏角色用到的一切：事项卡、待批准、任务、账本、信源、统一「等你」。
    func refreshFlow() async {
        await withTaskGroup(of: Void.self) { group in
            for path in ["/personal/agency", "/personal/work/proposals?limit=20", "/personal/tasks", "/personal/finance", "/personal/connectors", "/personal/waiting"] {
                group.addTask { _ = await self.load(path) }
            }
        }
    }
    /// 打开统一「等你」：收起冲突 sheet，并立刻拉 waiting + flow（与深链/推送同路径），避免空壳或过期角标。
    /// 菜单入口拉新进行中的 key，防连点叠刷同一入口。
    private var menuOpening: Set<String> = []
    /// 菜单/入口拉新中（LedgerNote、菜单行、舞台芯片、sheet 顶栏可据此 busy）。
    var financeOpening: Bool { menuOpening.contains("finance") }
    /// 菜单/账本卡打开时拉 finance 失败开口（明细页也会有 failNote）。
    var financeOpenNote = ""
    /// 菜单打开记忆时拉列表/待确认失败开口（记忆页也会有 failNote）。
    var memoryOpenNote = ""
    /// 菜单打开连接器时拉 sources 失败开口（连接器页也会有 failNote）。
    var connectorsOpenNote = ""
    /// 菜单/深链打开动态时 loadFeed 失败开口（动态页也会有 feedFail）。
    var activityOpenNote = ""
    /// 深链 plan 拉 next/plan 失败开口（下一步页 / 明天计划卡也会有 failNote）。
    var planOpenNote = ""
    /// 深链 today 刷主聊 conversation 失败开口（主聊页 InlineNotice）。
    var todayOpenNote = ""
    /// 菜单/深链打开「等你」时拉 waiting 失败开口（等你页也会有 failNote）。
    var waitingOpenNote = ""
    /// 打开搜索时拉 artifacts 失败开口（搜索页也会有 artifactsFail）。
    var searchOpenNote = ""
    /// 菜单打开设置时拉 /status 失败开口（设置页也会有 statusFail）。
    var settingsOpenNote = ""
    /// 目标已建上但 agency 列表没刷齐开口（目标页 InlineNotice）。
    var agencyGoalsNote = ""
    /// prepare 已整理但 agency cards 没刷齐开口（等你整理回执 / 详情 failNote）。
    var agencyCardsNote = ""
    /// 任务已归档但 tasks 列表没刷齐开口（任务页 / 等你划掉回执）。
    var tasksOpenNote = ""
    /// 工作页 projects/sessions 拉齐失败开口（派活后 / 菜单刷新 / 进页）。
    var workOpenNote = ""
    /// 健康页 range/insight 拉齐或重新评估失败开口（菜单 refresh / insight refresh）。
    var healthOpenNote = ""
    /// 今天页菜单 refresh(.doing) 拉齐失败开口（today 为主；flow/automations 一并拉）。
    var doingOpenNote = ""
    /// 今天页下拉 / 热点拉齐失败开口（HotBoardCard 也显示）。
    var hotOpenNote = ""
    /// 今天页下拉 / 进页拉 next（今日简报）失败开口（ScheduleAdvice 显示）。
    var todayNextOpenNote = ""
    var memoryOpening: Bool { menuOpening.contains("memory") }
    var connectorsOpening: Bool { menuOpening.contains("connectors") }
    var waitingOpening: Bool { menuOpening.contains("waiting") }
    var activityOpening: Bool { menuOpening.contains("activity") }
    var planOpening: Bool { menuOpening.contains("plan") }
    var todayOpening: Bool { menuOpening.contains("today") }
    var settingsOpening: Bool { menuOpening.contains("settings") }
    var searchOpening: Bool { menuOpening.contains("search") }
    /// 前台探测分享收件箱。用 `loadAll` 而非 `all()`：App Group 失败时开口，不假装没有分享。
    func refreshShareInboxPresence() {
        let batch = ShareInbox.loadAll()
        if let err = batch.error, !err.isEmpty {
            shareInboxNote = "分享收件箱没读上：\(err)——可能有待处理分享。可点「打开收件箱」再试。不会假装没有。"
            // 有可读条目仍自动打开；纯错误不硬弹 sheet，靠主聊开口。
            showShareInbox = !batch.items.isEmpty
            return
        }
        shareInboxNote = batch.decodeFailures > 0
            ? "有 \(batch.decodeFailures) 条分享解不开——能读的\(batch.items.isEmpty ? "没有" : "在收件箱里")。可打开收件箱核对。"
            : ""
        showShareInbox = !batch.items.isEmpty
    }
    /// 打开设置：立刻刷 /status，审批数/运行中别停在旧快照。
    func openSettings() {
        showSettings = true
        settingsOpenNote = ""
        guard menuOpening.insert("settings").inserted else { return }
        Task {
            defer { menuOpening.remove("settings") }
            if await load("/status") == nil {
                let err = errors["/status"] ?? ""
                let hadCache = datasets["/status"] != nil
                settingsOpenNote = err.isEmpty
                    ? (hadCache ? "服务器状态没刷新上——下面仍可能是上一版。可再从菜单打开。不会假装已读上。" : "服务器状态还没拉齐——可再打开设置重试。不会假装已读上。")
                    : "服务器状态没拉齐：" + err + "——可再打开设置重试。不会假装已读上。"
            }
        }
    }
    /// 打开搜索与成果：立刻刷 artifacts，空态成果列表别停在旧快照。
    func openSearch() {
        showSearch = true
        searchOpenNote = ""
        guard menuOpening.insert("search").inserted else { return }
        Task {
            defer { menuOpening.remove("search") }
            if await load("/personal/artifacts") == nil {
                let err = errors["/personal/artifacts"] ?? ""
                let hadCache = !(datasets["/personal/artifacts"]?["items"].array ?? []).isEmpty
                searchOpenNote = err.isEmpty
                    ? (hadCache ? "成果没刷新上——下面仍可能是上一版。可再打开搜索。不会假装已读上。" : "成果还没拉齐——可再打开搜索重试。不会假装已读上。")
                    : "成果没拉齐：" + err + "——可再打开搜索重试。不会假装已读上。"
            }
        }
    }
    func openWaitingInbox(closeStage: Bool = false) {
        if closeStage { self.closeStage() }
        showCases = false
        presentedCase = nil
        showActivity = false
        showWaiting = true
        waitingOpenNote = ""
        guard menuOpening.insert("waiting").inserted else { return }
        Task {
            defer { menuOpening.remove("waiting") }
            let ok = await load("/personal/waiting") != nil
            await refreshFlow()
            if ok {
                waitingOpenNote = ""
                return
            }
            let err = errors["/personal/waiting"] ?? ""
            let hadCache = !(datasets["/personal/waiting"]?["items"].array ?? []).isEmpty
            waitingOpenNote = err.isEmpty
                ? (hadCache ? "等你清单没刷新上——下面仍可能是上一版。可再从菜单打开。不会假装已读上。" : "等你清单还没拉齐——可再打开重试。不会假装已读上。")
                : "等你清单没拉齐：" + err + "——可再打开重试。不会假装已读上。"
        }
    }
    /// 打开动态（航程+写操作）：立刻 loadFeed，避免菜单里「有航程停顿」点进去却是旧列表。
    func openActivityFeed(closeStage: Bool = false) {
        if closeStage { self.closeStage() }
        showActivity = true
        beginActivityFeedLoad()
    }
    /// 深链 `com-eddie://cases`：打开动态「电脑上的活」并 loadFeed；失败写 activityOpenNote，不假装已读上。
    func openCasesDeepLink() {
        tab = .next
        showWaiting = false
        showActivity = false
        showCases = true
        beginActivityFeedLoad()
    }
    /// 深链 `com-eddie://today`：回主对话并刷 conversation（灵动岛/旧链约定）；失败写 todayOpenNote，不假装已读上。
    func openTodayDeepLink() {
        tab = .chat
        todayOpenNote = ""
        guard menuOpening.insert("today").inserted else { return }
        Task {
            defer { menuOpening.remove("today") }
            if let data = await load("/personal/conversation") {
                conversation.apply(data, snapshot: true)
                ComNotifications.observe(conversation.messages)
                todayOpenNote = ""
                return
            }
            let err = errors["/personal/conversation"] ?? ""
            let hadCache = !conversation.messages.isEmpty
            todayOpenNote = err.isEmpty
                ? (hadCache ? "主聊没刷新上——下面仍可能是上一版。可下拉再试。不会假装已读上。" : "主聊还没拉齐——可再点灵动岛/链接重试。不会假装已读上。")
                : "主聊没拉齐：" + err + "——可再试。不会假装已读上。"
        }
    }
    /// 深链 `com-eddie://plan`：进下一步并拉 next + plan；失败写 planOpenNote，不假装已读上。
    func openPlanDeepLink() {
        tab = .next
        planOpenNote = ""
        guard menuOpening.insert("plan").inserted else { return }
        Task {
            defer { menuOpening.remove("plan") }
            async let next = load("/personal/next")
            async let plan = load("/personal/plan")
            let gotNext = await next != nil
            let gotPlan = await plan != nil
            if gotNext && gotPlan {
                planOpenNote = ""
                return
            }
            let nextErr = errors["/personal/next"] ?? ""
            let planErr = errors["/personal/plan"] ?? ""
            let hadNext = !(datasets["/personal/next"]?["items"].array ?? []).isEmpty
            let hadPlan = (datasets["/personal/plan"]?["state"].string == "open")
                && !(datasets["/personal/plan"]?["items"].array ?? []).isEmpty
            if !gotNext && !gotPlan {
                let err = [nextErr, planErr].first { !$0.isEmpty } ?? ""
                planOpenNote = err.isEmpty
                    ? ((hadNext || hadPlan) ? "下一步与明天计划没刷新上——下面仍可能是上一版。可下拉再试。不会假装已读上。" : "下一步与明天计划还没拉齐——可再打开重试。不会假装已读上。")
                    : "下一步/计划没拉齐：" + err + "——可再试。不会假装已读上。"
            } else if !gotPlan {
                planOpenNote = planErr.isEmpty
                    ? (hadPlan ? "明天计划没刷新上——下一步若在仍可先看。可再试。" : "明天计划没读上——下一步若在仍可先看。可再试。")
                    : "明天计划没读上：" + planErr + "——可再试。"
            } else {
                planOpenNote = nextErr.isEmpty
                    ? (hadNext ? "下一步没刷新上——明天计划若在仍可先看。可再试。" : "下一步没读上——明天计划若在仍可先看。可再试。")
                    : "下一步没读上：" + nextErr + "——可再试。"
            }
        }
    }
    private func beginActivityFeedLoad() {
        activityOpenNote = ""
        guard menuOpening.insert("activity").inserted else { return }
        Task {
            defer { menuOpening.remove("activity") }
            applyActivityOpenNote(from: await loadFeed())
        }
    }
    private func applyActivityOpenNote(from result: (activity: Bool, cases: Bool)) {
        if result.activity && result.cases {
            activityOpenNote = ""
            return
        }
        let actErr = errors[Self.feedPath] ?? errors["/personal/activity"] ?? ""
        let caseErr = errors["/personal/cases"] ?? ""
        let hadCache = !(datasets[Self.feedPath]?["items"].array ?? activityData["items"].array ?? []).isEmpty
            || !(datasets["/personal/cases"]?["items"].array ?? []).isEmpty
        if !result.activity && !result.cases {
            let err = [actErr, caseErr].first { !$0.isEmpty } ?? ""
            activityOpenNote = err.isEmpty
                ? (hadCache ? "动态没刷新上——下面仍可能是上一版。可再从菜单打开。不会假装已读上。" : "动态还没拉齐——可再打开重试。不会假装已读上。")
                : "动态没拉齐：" + err + "——可再打开重试。不会假装已读上。"
        } else if !result.cases {
            activityOpenNote = caseErr.isEmpty
                ? "航程列表没读上——写操作若在仍可先看。可再打开。"
                : "航程列表没读上：" + caseErr + "——可再打开。"
        } else {
            activityOpenNote = actErr.isEmpty
                ? "写操作动态没读上——航程若在仍可先看。可再打开。"
                : "写操作动态没读上：" + actErr + "——可再打开。"
        }
    }
    /// 打开记忆：立刻拉列表 + 待确认收件箱，避免点进去还是旧纸片。
    func openMemory() {
        showMemory = true
        memoryOpenNote = ""
        guard menuOpening.insert("memory").inserted else { return }
        Task {
            defer { menuOpening.remove("memory") }
            async let mem = load("/personal/memory")
            await loadMemoryInbox()
            let gotMem = await mem != nil
            let inboxPath = Self.memoryInboxPath
            let gotInbox = errors[inboxPath] == nil && datasets[inboxPath] != nil
            if gotMem && gotInbox {
                memoryOpenNote = ""
                return
            }
            let memErr = errors["/personal/memory"] ?? ""
            let inboxErr = errors[inboxPath] ?? ""
            let hadCache = !(datasets["/personal/memory"]?["items"].array ?? []).isEmpty
            if !gotMem && !gotInbox {
                let err = [memErr, inboxErr].first { !$0.isEmpty } ?? ""
                memoryOpenNote = err.isEmpty
                    ? (hadCache ? "记忆没刷新上——下面仍可能是上一版。可再从菜单打开。不会假装已读上。" : "记忆还没拉齐——可再打开重试。不会假装已读上。")
                    : "记忆没拉齐：" + err + "——可再打开重试。不会假装已读上。"
            } else if !gotMem {
                memoryOpenNote = memErr.isEmpty
                    ? "记忆列表没读上——可再打开。不会假装已读上。"
                    : "记忆列表没读上：" + memErr + "——可再打开。"
            } else {
                memoryOpenNote = inboxErr.isEmpty
                    ? "待确认收件箱没读上——长期记忆若在仍可先看。可再打开。"
                    : "待确认没读上：" + inboxErr + "——可再打开。"
            }
        }
    }
    /// 打开分享收件箱：先探测 App Group；坏容器时 shareInboxNote + sheet 内 listFail，不假装没有分享。
    func openShareInbox() {
        refreshShareInboxPresence()
        showShareInbox = true
    }
    /// 打开账本：立刻拉 finance（与「已记」刷账本同路）。
    func openFinance() {
        showFinance = true
        financeOpenNote = ""
        guard menuOpening.insert("finance").inserted else { return }
        Task {
            defer { menuOpening.remove("finance") }
            if await load("/personal/finance") == nil {
                let err = errors["/personal/finance"] ?? ""
                financeOpenNote = err.isEmpty
                    ? "账本没拉齐——明细若空可再从菜单打开。不会假装已读上。"
                    : "账本没拉齐：" + err + "——可再打开重试。"
            }
        }
    }
    /// 打开连接器：立刻拉 sources，信源断了点进去应是现况。
    func openConnectors(closeStage: Bool = false) {
        if closeStage { self.closeStage() }
        showConnectors = true
        connectorsOpenNote = ""
        guard menuOpening.insert("connectors").inserted else { return }
        Task {
            defer { menuOpening.remove("connectors") }
            if await load("/personal/connectors") == nil {
                let err = errors["/personal/connectors"] ?? ""
                let hadCache = !(datasets["/personal/connectors"]?["sources"].array ?? []).isEmpty
                connectorsOpenNote = err.isEmpty
                    ? (hadCache ? "连接器没刷新上——下面仍可能是上一版。可再从菜单打开。不会假装已读上。" : "连接器还没拉齐——可再打开重试。不会假装已读上。")
                    : "连接器没拉齐：" + err + "——可再打开重试。不会假装已读上。"
            }
        }
    }
    func refresh(_ tab: SectionTab) async {
        _ = await load("/personal/waiting")  // 10-18：「等你」角标全局可见
        _ = await load("/personal/cases")    // 10-18：航程入口在头像菜单和下一步页，哪一页都要有最新数，每次刷新都带上
        switch tab {
        case .chat:
            // 下拉/各处 refresh(.chat)：conversation 失败写 todayOpenNote，别假装主聊已读上。
            if let data = await load("/personal/conversation") {
                conversation.apply(data, snapshot: true)
                ComNotifications.observe(conversation.messages)
                todayOpenNote = ""
            } else {
                let err = errors["/personal/conversation"] ?? ""
                let hadCache = !conversation.messages.isEmpty
                todayOpenNote = err.isEmpty
                    ? (hadCache
                       ? "主聊没刷上——下面仍可能是上一版。可下拉再试。不会假装已读上。"
                       : "主聊还没拉齐——可下拉再试。不会假装已读上。")
                    : "主聊没刷上：" + err + "——可下拉再试。不会假装已读上。"
            }
        case .next:
            // 菜单刷新 / 各处 refresh(.next)：next+plan 失败写 planOpenNote，别假装下一步已读上。
            async let next = load("/personal/next")
            async let connectors = load("/personal/connectors")
            async let finance = load("/personal/finance")
            async let plan = load("/personal/plan")
            let gotNext = await next != nil
            let gotPlan = await plan != nil
            _ = await connectors
            _ = await finance
            if gotNext && gotPlan {
                planOpenNote = ""
            } else {
                let nextErr = errors["/personal/next"] ?? ""
                let planErr = errors["/personal/plan"] ?? ""
                let hadNext = !(datasets["/personal/next"]?["items"].array ?? []).isEmpty
                let hadPlan = (datasets["/personal/plan"]?["state"].string == "open")
                    && !(datasets["/personal/plan"]?["items"].array ?? []).isEmpty
                if !gotNext && !gotPlan {
                    let err = [nextErr, planErr].first { !$0.isEmpty } ?? ""
                    planOpenNote = err.isEmpty
                        ? ((hadNext || hadPlan) ? "下一步与明天计划没刷上——下面仍可能是上一版。可下拉再试。不会假装已读上。" : "下一步与明天计划还没拉齐——可再试。不会假装已读上。")
                        : "下一步/计划没刷上：" + err + "——可再试。不会假装已读上。"
                } else if !gotPlan {
                    planOpenNote = planErr.isEmpty
                        ? (hadPlan ? "明天计划没刷上——下一步若在仍可先看。可再试。" : "明天计划没读上——下一步若在仍可先看。可再试。")
                        : "明天计划没读上：" + planErr + "——可再试。"
                } else {
                    planOpenNote = nextErr.isEmpty
                        ? (hadNext ? "下一步没刷上——明天计划若在仍可先看。可再试。" : "下一步没读上——明天计划若在仍可先看。可再试。")
                        : "下一步没读上：" + nextErr + "——可再试。"
                }
            }
        case .doing:
            // 菜单刷新：flow + today + automations；today 失败写 doingOpenNote，别假装日程已齐。
            await refreshFlow()
            async let today = load("/personal/today")
            async let autos = load("/personal/automations")
            let gotToday = await today != nil
            let gotAutos = await autos != nil
            if gotToday && gotAutos {
                doingOpenNote = ""
            } else if gotToday {
                let err = errors["/personal/automations"] ?? ""
                doingOpenNote = err.isEmpty
                    ? "定时工作没刷上——日程若在仍可先看。可再试。不会假装已是最新。"
                    : "定时工作没刷上：" + err + "——日程若在仍可先看。可再试。"
            } else {
                let err = errors["/personal/today"] ?? ""
                let had = !(datasets["/personal/today"]?["events"].array ?? []).isEmpty
                    || !(datasets["/personal/today"]?["reminders"].array ?? []).isEmpty
                doingOpenNote = err.isEmpty
                    ? (had ? "今天的日程/提醒没刷上——下面仍可能是上一版。可再试。不会假装已是最新。" : "今天的日程和提醒还没拉齐——可再试。不会假装已是最新。")
                    : (had ? "今天没刷上：" + err + "——下面仍可能是上一版。不会假装已是最新。" : "今天没拉齐：" + err + "——可再试。不会假装已是最新。")
            }
        case .health:
            // 菜单刷新：range+insight 失败写 healthOpenNote，别假装健康页已齐。
            let rangePath = "/personal/health?days=30"
            let insightPath = "/personal/health/insight"
            async let range = load(rangePath)
            async let insight = load(insightPath)
            let gotRange = await range != nil
            let gotInsight = await insight != nil
            if gotRange && gotInsight {
                healthOpenNote = ""
            } else {
                let rangeErr = errors[rangePath] ?? errors["/personal/health"] ?? ""
                let insightErr = errors[insightPath] ?? ""
                let hadRange = !(datasets[rangePath]?["days"].array ?? []).isEmpty
                    || !(datasets[rangePath]?["today"]["measurements"].isNull ?? true)
                let hadInsight = !(datasets[insightPath]?.isNull ?? true)
                if !gotRange && !gotInsight {
                    let err = [rangeErr, insightErr].first { !$0.isEmpty } ?? ""
                    healthOpenNote = err.isEmpty
                        ? (hadRange || hadInsight ? "健康曲线和评估都没刷上——下面仍可能是上一版。可再试。不会假装已是最新。" : "健康曲线和评估还没拉齐——可再试。不会假装已是最新。")
                        : "健康没刷上：" + err + "——可再试。不会假装已是最新。"
                } else if !gotRange {
                    healthOpenNote = rangeErr.isEmpty
                        ? (hadRange ? "健康曲线没刷上——评估若在仍可先看；可再试。" : "健康曲线没读上——可再试。")
                        : "健康曲线没读上：" + rangeErr + "——可再试。"
                } else {
                    healthOpenNote = insightErr.isEmpty
                        ? (hadInsight ? "身体评估没刷上——下面仍可能是上一版。可再试。不会假装已写好。" : "身体评估没拉齐——可再试。不会假装已写好。")
                        : "身体评估没拉齐：" + insightErr + "——可再试。不会假装已写好。"
                }
            }
        case .work:
            // 派活后 / 菜单刷新 / 进页：侧栏 projects+sessions 失败写 workOpenNote，别假装历史已齐。
            async let projects = load("/personal/projects")
            async let sessions = load("/sessions")
            let gotProjects = await projects != nil
            let gotSessions = await sessions != nil
            if gotProjects && gotSessions {
                workOpenNote = ""
            } else {
                let projectErr = errors["/personal/projects"] ?? ""
                let sessionErr = errors["/sessions"] ?? ""
                let hadProjects = datasets["/personal/projects"] != nil
                let hadSessions = !(datasets["/sessions"]?["sessions"].array ?? []).isEmpty
                if !gotProjects && !gotSessions {
                    let err = [projectErr, sessionErr].first { !$0.isEmpty } ?? ""
                    workOpenNote = err.isEmpty
                        ? ((hadProjects || hadSessions) ? "项目和会话都没刷上——侧栏仍可能是上一版。可再拉。不会假装已是最新。" : "项目和会话还没拢上——检查配对或网络后再试。不会假装已是最新。")
                        : "侧栏没刷上：" + err + "——可再拉。不会假装已是最新。"
                } else if !gotProjects {
                    workOpenNote = projectErr.isEmpty
                        ? (hadProjects ? "项目看板没刷上——会话若在仍可先点；可再拉。" : "项目看板没读上——会话若在仍可先点；可再拉。")
                        : "项目看板没读上：" + projectErr + "——可再拉。"
                } else {
                    workOpenNote = sessionErr.isEmpty
                        ? (hadSessions ? "会话列表没刷上——项目若在仍可先点；可再拉。不会假装新会话已出现。" : "会话列表没读上——项目若在仍可先点；可再拉。不会假装新会话已出现。")
                        : "会话列表没读上：" + sessionErr + "——可再拉。不会假装新会话已出现。"
                }
            }
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
                    // 字节流正常结束也算断线：勿保持 streaming=true，否则轮询以为还在线、假成功。
                    if Task.isCancelled { return }
                    failures += 1
                    self.markStreamDown(attempt: failures)
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    failures += 1
                    self.markStreamDown(attempt: failures)
                }
                try? await Task.sleep(for: .seconds(min(30, 1 << min(failures, 5))))
            }
        }
    }
    /// SSE 断开：舞台离线 + 页内开口；HTTP 拉齐不得冒充已恢复。
    private func markStreamDown(attempt: Int) {
        streaming = false
        stage.disconnect()
        let message = attempt >= 3
            ? "实时连接一直没接上（已重试多次）——仍在重连；这会儿是缓存，新回复可能晚到。不会假装已恢复。"
            : "实时连接断了，正在重连——这会儿是缓存，新回复可能晚到。不会假装已恢复。"
        streamNote = message
        errors["/personal/conversation"] = message
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
            let fresh = value["messages"].array.filter { $0["role"].string == "assistant" && $0["status"].string == "completed" && !before.contains($0.id) }
            if !fresh.isEmpty { Haptics.success() }
            // 快记账回执到了就立刻刷账本；失败开口，别让「已记」气泡配着旧明细假装已更新。
            if fresh.contains(where: { $0["text"].string.hasPrefix("已记") }) {
                Task {
                    if await self.load("/personal/finance") == nil {
                        let err = self.errors["/personal/finance"] ?? ""
                        self.financeOpenNote = err.isEmpty
                            ? "记账回执到了，账本没刷上——可打开账本再拉。不会假装明细已更新。"
                            : "记账回执到了，账本没刷上：" + err + "——可打开账本再拉。不会假装明细已更新。"
                    } else {
                        self.financeOpenNote = ""
                    }
                }
            }
        }
        // 只有真正收到对话事件才算恢复；心跳不算。
        streaming = true
        streamNote = ""
        errors["/personal/conversation"] = nil
        fetchedAt["/personal/conversation"] = Date()
        diagnose("stream:" + event.name)
        persistSoon()
    }
    /// 拉更早对话。false = 请求失败（调用方页内提示，勿假装已读完）。
    @discardableResult
    func loadHistory() async -> Bool {
        guard moreHistory, let first = conversation.messages.first else { return true }
        if let page = await load("/personal/conversation/history?before=" + first.id.queryEncoded + "&limit=60") {
            conversation.prependHistory(page); moreHistory = page["has_more"].bool; persistSoon()
            return true
        }
        return false
    }
    /// 定位到某条消息；找不到则不跳聊天（调用方留页提示）。返回是否已对准。
    /// 失败写 `locateNote`：区分历史没拉上 vs 对不上，勿一律「没找到」。
    @discardableResult
    func locateMessage(_ id: String) async -> Bool {
        locateNote = ""
        guard !id.isEmpty else {
            locateNote = "消息编号空了，没法对准。"
            return false
        }
        if !conversation.messages.contains(where: { $0.id == id }) {
            let path = "/personal/conversation/history?around=" + id.queryEncoded + "&limit=60"
            guard let page = await load(path) else {
                let err = errors[path] ?? ""
                locateNote = err.isEmpty
                    ? "历史没拉上——检查配对或网络后再试对准。不会假装已跳到那条。"
                    : "历史没拉上：" + err + "——可再试对准。不会假装已跳到那条。"
                return false
            }
            conversation.prependHistory(page)
        }
        guard conversation.messages.contains(where: { $0.id == id }) else {
            locateNote = "消息没对上——可能已归档或不在这趟对话。可去搜索换一条，或直接在主对话里找。"
            return false
        }
        locateNote = ""
        tab = .chat
        jumpMessage = id
        return true
    }
    /// 返回是否已送达受理。下一步记账/加日程靠它决定要不要标「做完」——失败别把卡划掉。
    @discardableResult
    func send(voiceMessage: Bool = false, matter: String? = nil, textOverride: String? = nil) async -> Bool {
        let text = (textOverride ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, (!sending || voiceMessage) else { return false }
        chatComposerNote = ""
        var extra: [String: JSON] = [:]
        if let reference { extra["reference"] = reference }
        if !attachments.isEmpty { extra["attachment_ids"] = .array(attachments.map { .string($0.id) }) }
        if let matter { extra["matter_id"] = .string(matter) }
        let voiceID = voiceMessage ? "voice-" + voice.captureID : nil
        if let voiceID, pending.contains(where: { $0.id == voiceID }) { return false }
        let entry = PendingMessage(text: text, path: "/personal/conversation/messages", extra: extra, requestID: voiceID)
        pending.append(entry)
        #if DEBUG
        if isUITesting {
            lastSubmittedID = entry.id
            if voiceMessage { voice.cancel(); showQuickVoice = false }
            if textOverride == nil { draft = "" }; reference = nil; attachments = []
            if ProcessInfo.processInfo.arguments.contains("--ui-send-rejected") {
                pending[pending.count - 1].state = .rejected; pending[pending.count - 1].note = "测试中的发送未被受理"
                chatComposerNote = "没送出去：测试中的发送未被受理——可点「回到草稿」再试"
                return false
            }
            try? await Task.sleep(for: .milliseconds(600))
            if let index = pending.firstIndex(where: { $0.id == entry.id }) { pending[index].state = .delivered }
            try? await Task.sleep(for: .milliseconds(600))
            let message = JSON.object(["id": .string("server-" + entry.id), "request_id": .string(entry.id), "role": .string("user"), "text": .string(text), "status": .string("completed"), "created_at": .number(entry.createdAt.timeIntervalSince1970)])
            conversation.messages.append(message); conversation.revision += 1
            return true
        }
        #endif
        // 未配对别清空草稿再假装发出去（UI 测试已在上面返回）。
        guard isPaired, api != nil else {
            pending.removeAll { $0.id == entry.id }
            chatComposerNote = "还没连上 mini——草稿还在，先配对再发。不会假装已发出。"
            banner = "请先连接 Mac mini"
            return false
        }
        do { try SecureVault.save(pending, name: "outbox") }
        catch {
            pending.removeAll { $0.id == entry.id }
            chatComposerNote = "发送记录保存失败，草稿已保留——可再试。别当成已发出。"
            banner = "发送记录保存失败，草稿已保留"
            return false
        }
        lastSubmittedID = entry.id
        if textOverride == nil { draft = "" }; reference = nil; attachments = []; persistNow()
        await deliver(entry.id)
        let state = pending.first(where: { $0.id == entry.id })?.state
        let detail = pending.first(where: { $0.id == entry.id })?.note ?? ""
        let ok = state == .delivered
        if ok {
            chatComposerNote = ""
        } else if state == .rejected {
            chatComposerNote = detail.isEmpty
                ? "没送出去——可点气泡下「回到草稿」再试"
                : "没送出去：" + detail + "——可点「回到草稿」再试"
        } else {
            chatComposerNote = detail.isEmpty
                ? "送达待核实——别当成已发出；可点「查回执」"
                : "送达待核实：" + detail + "——别当成已发出"
        }
        if voiceMessage {
            // 送达成功或明确拒收才清录音；不确定/失败保留转写，方便重试（别先 cancel 再发现没发出去）。
            if ok || state == .rejected {
                voice.cancel(); showQuickVoice = false
            } else if !ok {
                voice.error = chatComposerNote
                voice.phase = .failed
            }
        }
        return ok
    }
    /// 发送 / 查回执。返回最终态；未配对或查不清时写 uncertain + note，调用方开口，勿假装已核实。
    @discardableResult
    func deliver(_ id: String) async -> DeliveryState? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        if pending[index].state == .delivered { return .delivered }
        guard !issuing.contains(id) else { return pending[index].state }
        guard let api else {
            updatePending(id) { $0.state = .uncertain }
            updatePending(id) { $0.note = "还没连上 mini——回执没查上，配对后再查。不会假装已核实。" }
            return .uncertain
        }
        issuing.insert(id); sending = true
        diagnose("deliver-start:" + id)
        defer { issuing.remove(id); sending = !issuing.isEmpty; persistNow() }
        let entry = pending[index]
        do {
            if entry.state != .queued {
                do {
                    let receipt = try await api.request(entry.receiptPath)
                    if receipt["status"].string == "unknown" {
                        updatePending(id) { $0.state = .uncertain }
                        updatePending(id) { $0.note = "服务端结果待核实，不会重复提交" }
                        return .uncertain
                    }
                    updatePending(id) { $0.state = .delivered }; updatePending(id) { $0.note = "已受理" }
                    await refresh(.chat)
                    return .delivered
                } catch let error as APIError where error.status == 404 {
                    // A main-message submission is transactionally idempotent by request_id.
                    guard entry.path.hasPrefix("/personal/") else {
                        updatePending(id) { $0.state = .uncertain }
                        updatePending(id) { $0.note = "未查到工作回执，请检查会话。不会假装已核实。" }
                        return .uncertain
                    }
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
        return pending.first(where: { $0.id == id })?.state
    }
    func recoverOutbox() async {
        for entry in pending where entry.state == .queued || entry.state == .uncertain || entry.state == .checking {
            if entry.path.hasPrefix("/sessions") { _ = await deliverWork(entry.id) } else { await deliver(entry.id) }
        }
    }
    /// 语音回答审批：只接受明确的 accept/decline；复杂问题与密码仍回卡片。
    /// 失败保留 pendingApproval，并写共享 approvalFailNote + 语音窗 error，卡片/语音双路径都能留页再试。
    @discardableResult
    func answerApproval(_ approval: JSON, decision: String) async -> Bool {
        guard let api else {
            rememberApprovalFail(
                id: approval.id,
                message: "还没连上 mini——审批没发出去。可回卡片再点，或配对后再说。不会假装已批/已拒。"
            )
            return false
        }
        do {
            _ = try await api.request("/approvals/" + approval.id.pathEncoded, body: .object(["decision": .string(decision)]))
            pendingApproval = nil
            clearApprovalFail()
            banner = decision == "accept" ? "已批准这次操作。" : "已拒绝这次操作。"
            await work.refresh(self)
            return true
        } catch {
            // 失败别清 pendingApproval：还要回卡片或再说一次。
            rememberApprovalFail(
                id: approval.id,
                message: "审批没送达：" + error.localizedDescription + "——还可再说一次，或回卡片点。不会假装已批/已拒。"
            )
            return false
        }
    }
    func rememberApprovalFail(id: String, message: String) {
        approvalFailID = id
        approvalFailNote = message
        voice.error = message
        voice.phase = .failed
        banner = message
    }
    func clearApprovalFail() {
        approvalFailNote = ""
        approvalFailID = ""
    }
    /// 打断当前或指定消息上的运行。成功 true；失败写 `interruptNote` 留页开口，勿假装已停。
    @discardableResult
    func interrupt(messageID: String? = nil) async -> Bool {
        guard stage.state.isBusy || messageID != nil else { return false }
        interruptNote = ""
        guard let api else {
            interruptNote = "还没连上 mini——中断没发出去，可再试。不会假装已停下。"
            return false
        }
        do {
            _ = try await api.request("/personal/conversation/interrupt", body: .object(messageID.map { ["message_id": .string($0)] } ?? [:]))
            if messageID == nil || activeRuns.count <= 1 { stage.receive("task.progress", .object(["kind": .string("idle")])) }
            interruptNote = ""
            banner = messageID == nil ? "已中断" : "已停下这件，其它的照常进行"
            return true
        } catch {
            interruptNote = messageID == nil
                ? "中断没成：" + error.localizedDescription + "——还在办，可再点「中断」。别当成已经停了。"
                : "停下这件没成：" + error.localizedDescription + "——还在跑，可再试。其它并行的不受影响。"
            return false
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
    /// 工作出站 / 查回执。未配对写 note；失败返回 nil 且态为 uncertain，勿假装已核实。
    func deliverWork(_ id: String) async -> JSON? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        if pending[index].state == .delivered {
            return .object(["status": .string("accepted")])
        }
        guard !issuing.contains(id) else { return nil }
        guard let api else {
            updatePending(id) { $0.state = .uncertain }
            updatePending(id) { $0.note = "还没连上 mini——回执没查上，配对后再查。不会假装已核实。" }
            return nil
        }
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
    /// 解除本机配对。`unpaired` 本地一定清掉；`pushCleared` 表示服务器推送注销是否成功（失败仍解绑，设置页可开口）。
    @discardableResult
    func disconnect() async -> (unpaired: Bool, pushCleared: Bool) {
        var pushCleared = true
        if let api {
            pushCleared = await ComPush.disable(using: api)
        }
        await setActive(false)
        StatusWidgetSnapshot.clear(); WidgetCenter.shared.reloadTimelines(ofKind: StatusWidgetSnapshot.kind)
        liveActivityNote = ""
        widgetUpdateNote = ""
        cachePersistNote = ""
        shareInboxNote = ""
        memoryOpenNote = ""
        financeOpenNote = ""
        connectorsOpenNote = ""
        activityOpenNote = ""
        planOpenNote = ""
        todayOpenNote = ""
        waitingOpenNote = ""
        searchOpenNote = ""
        settingsOpenNote = ""
        agencyGoalsNote = ""
        agencyCardsNote = ""
        approvalDeepLinkNote = ""
        pairGateNote = ""
        SecureVault.deleteSecret("token")
        api = nil
        isPaired = false
        streaming = false
        return (true, pushCleared)
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
        chatComposerNote = "草稿已收回输入框——改完再发。刚才那条没有发出去。"
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
    @discardableResult
    func action(_ path: String, fields: [String: JSON] = [:], refresh section: SectionTab? = nil) async -> Bool {
        do {
            _ = try await mutate(path, fields: fields)
            if let section { await refresh(section) }
            Haptics.selection()
            return true
        } catch {
            banner = error.localizedDescription
            return false
        }
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
        guard isPaired else {
            // 未配对时 Root 停在配对页：页内 note + banner，别只弹窗一闪像没事。
            let note = "要先配对才能用语音——连上 Mac mini 后再说。不会假装已开麦。"
            pairGateNote = note
            banner = note
            return
        }
        pairGateNote = ""
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
        // Never overwrite an unsubmitted capture when the entry opens again；starting 中也不叠启。
        guard !voice.starting, !voice.hasCapture, voice.phase != .transcribing, voice.phase != .recording else { return }
        Task { await voice.start(using: api) }
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
            guard let api else {
                // 失败开口留在语音窗；勿只 banner 后像没事。
                voice.error = "还没连上 mini——录音已保留，配对后再转写。"
                if voice.hasCapture { voice.phase = .failed }
                banner = "请先连接 Mac mini"
                return
            }
            await voice.transcribe(using: api)
        }
        #else
        guard let api else {
            voice.error = "还没连上 mini——录音已保留，配对后再转写。"
            if voice.hasCapture { voice.phase = .failed }
            banner = "请先连接 Mac mini"
            return
        }
        await voice.transcribe(using: api)
        #endif
        guard voice.phase == .ready, voice.captureID == capture, !voice.transcript.isEmpty else { return }
        // 口述“停/取消”只结束这次说话，不进消息队列；录音随后清掉，避免下次呼出又带出旧话。
        if VoiceCommands.isStop(voice.transcript) {
            voice.cancel(); showQuickVoice = false
            banner = "已按语音指令停止。"
            return
        }
        // 审批模式：这句话是批准/拒绝，不再当作聊天内容发出去。
        if let approval = pendingApproval, let decision = VoiceCommands.decision(voice.transcript) {
            // 送达成功才关语音窗；失败保留转写与审批上下文，卡上共享 fail note。
            if await answerApproval(approval, decision: decision) {
                voice.cancel(); showQuickVoice = false
            }
            return
        }
        if let approval = pendingApproval {
            rememberApprovalFail(
                id: approval.id,
                message: "没听清。请说「批准」或「拒绝」；复杂问题回卡片回答。不会假装已批。"
            )
            return
        }
        // Show the glyph reveal before entering the same durable text-message outbox.
        let text = voice.transcript
        // Auto-send is the quick 记账 path: a shorter reveal keeps the round trip snappy.
        try? await Task.sleep(for: .milliseconds(voice.autoSend ? 500 : 1200))
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
            do {
                try await cacheWriter.save(snapshot, revision: revision)
                // 落盘成功：清掉存/读失败开口（盘可用，当前草稿已在缓存里）。
                self?.cachePersistNote = ""
            } catch {
                let msg = "主聊草稿和本地缓存没存上：\(error.localizedDescription)——杀掉 App 可能丢未发的字。再改一字会重试。不会假装已落盘。"
                self?.cachePersistNote = msg
                self?.banner = "本地保存失败：" + error.localizedDescription
            }
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
            "week": .object(["shown": .number(6), "acted": .number(3), "dismissed": .number(1), "resolved": .number(2), "precision": .number(0.75),
                             "reasons": .object(["别人在负责": .number(1)])]),
            "items": .array([
                .object(["id": .string("next-reply"), "title": .string("回复王总的排期邮件"), "why": .string("王总上午问 Q4 排期，今天下班前要给答复。"), "urgency": .string("now"), "score": .number(90),
                         "phase": .string("new"), "action": .object(["type": .string("reply_mail"), "to": .string("wang@example.com"), "to_name": .string("王总"), "subject": .string("Re: Q4 排期确认"),
                                                                         "draft": .string("王总，Q4 排期我今晚整理好，明早 10 点前发您；有两处要跟您确认，见附件标黄部分。")]),
                         "prompt": .string("起草一封回复王总排期邮件的草稿给我确认。"), "evidence": .array([.object(["ref": .string("mail:m1"), "label": .string("工作邮箱 · Q4 排期确认"), "kind": .string("mail")]), .object(["ref": .string("event:m3"), "label": .string("日程 · 排期评审"), "kind": .string("event")])])]),
                .object(["id": .string("next-wechat"), "title": .string("回小倩展车进场时间"), "why": .string("小倩在筹备群问秦MAX展车几点进场，等你一句话。"), "urgency": .string("today"), "score": .number(75),
                         "phase": .string("waiting"), "history": .array([.object(["at": .number(Date().timeIntervalSince1970 - 1800), "text": .string("老马说车 7 点从 4S 店出发"), "phase": .string("waiting")])]),
                         "action": .object(["type": .string("reply_wechat"), "to": .string("大有可攀筹备群"), "draft": .string("展车 7 点从 4S 店出发，预计 8 点前到北顶，到了我在群里说。")]),
                         "prompt": .string("回小倩"), "evidence": .array([.object(["ref": .string("wechat:m9:g1"), "label": .string("微信 · 大有可攀筹备群"), "kind": .string("wechat")])])]),
                .object(["id": .string("next-meeting"), "title": .string("会前过一遍周会议题"), "why": .string("11:00 周会，上周的两个待办还没收尾。"), "urgency": .string("today"), "score": .number(70),
                         "prompt": .string("帮我准备 11 点的周会。"), "evidence": .array([.object(["ref": .string("event:m3"), "label": .string("日程 · 周会"), "kind": .string("event")])])]),
                .object(["id": .string("next-project"), "title": .string("推进 Com 语音小窗验收"), "why": .string("光效和入口已完成，还差一次真机录音。"), "urgency": .string("week"), "score": .number(50),
                         "prompt": .string("提醒我用操作按钮录一次音并检查发送结果。"), "evidence": .array([.object(["ref": .string("project:p1"), "label": .string("项目 · Com · 个人 Agent"), "kind": .string("project")])])])
            ])])
        datasets["/personal/activity"] = .object([
            "uncertain": .array([.object(["key": .string("eff-1"), "summary": .string("记账 ¥38 餐饮 午饭"), "at": .number(Date().timeIntervalSince1970 - 3600), "source": .string("午饭 38 记一下")])]),
            "items": .array({
                // 10-28 动态页验收：带 tool / type / detail / message_id，含一组同一句话里连着的命令（应合成一条）
                let now = Date().timeIntervalSince1970
                func eff(_ key: String, _ tool: String, _ type: String, _ summary: String, _ state: String, _ ago: Double, _ source: String, _ msg: String, _ detail: [String: String] = [:]) -> JSON {
                    .object(["key": .string(key), "tool": .string(tool), "type": .string(type), "summary": .string(summary), "state": .string(state), "at": .number(now - ago),
                             "source": .string(source), "message_id": .string(msg), "detail": .object(detail.mapValues { JSON.string($0) }), "seq": .number(100 - ago / 60)])
                }
                return [
                    eff("eff-0", "wechat_send", "outbound", "发微信给「大有可攀筹备群」", "completed", 240, "跟群里说展车 7 点出发", "m0", ["to": "大有可攀筹备群", "text": "展车 7 点从 4S 店出发，预计 8 点前到北顶"]),
                    eff("eff-1", "bookkeeping", "ledger", "记账 ¥38 餐饮 午饭", "uncertain", 3600, "午饭 38 记一下", "m1", ["action": "add", "amount": "38", "category": "餐饮", "note": "午饭"]),
                    eff("eff-2", "calendar_event", "schedule", "日程新建「周会」2026-10-27 10:00", "completed", 7200, "周一十点周会加一下", "m2", ["action": "add", "title": "周会", "start": "2026-10-27 10:00"]),
                    eff("eff-3a", "bash", "work", "运行命令 ls work/航程产出", "completed", 9000, "把航程产出整理一下", "m3", ["command": "ls work/航程产出"]),
                    eff("eff-3b", "bash", "work", "运行命令 mkdir -p work/航程产出/归档", "completed", 9010, "把航程产出整理一下", "m3", ["command": "mkdir -p work/航程产出/归档"]),
                    eff("eff-3c", "bash", "work", "运行命令 mv 旧产出 归档/", "failed", 9020, "把航程产出整理一下", "m3", ["command": "mv 旧产出 归档/"]),
                    eff("eff-4", "remind", "schedule", "提醒新建「交八月报销」明天 10:30", "confirmed", 90000, "明天提醒我交报销", "m4", ["action": "add", "title": "交八月报销", "at": "10:30"]),
                    eff("eff-5", "bookkeeping", "ledger", "记账 ¥72.3 其他收入 手机壳退款", "completed", 100000, "手机壳退款到了 72.3", "m5", ["action": "add", "amount": "72.3", "category": "其他收入"]),
                ]
            }()),
            "wechat": .array([.object(["key": .string("next:a"), "text": .string("【Com】现在该做：回复王总的排期邮件"), "at": .number(Date().timeIntervalSince1970 - 1200), "state": .string("sent")])])])
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
        case "share": openShareInbox()
        case "activity": openActivityFeed()
        case "task": selectedTask = datasets["/personal/tasks"]?["items"].array.first
        default: break
        }
        seedPagesPreview()  // 轨道 pages：今天时间线与依据详情的验收数据
        if ProcessInfo.processInfo.arguments.contains("--ui-r3-work") { seedR3WorkPreview() }  // r3-work：工作页原地聊天
        if ProcessInfo.processInfo.arguments.contains("--ui-cases") { seedCasesPreview() }  // 10-17：航程 / 明天建议 / 对话 todo 清单验收
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
