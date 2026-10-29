import SwiftUI
import ComCore

/// 工作页像 ChatGPT / Claude App（r3-work）：打开是空白新对话，底下输入框直接派活；发出去后这一页原地变成聊天——
/// 首页淡出、我的话从输入框飞上去成右侧气泡、Agent 的回复在左边流出来。历史在左边侧栏（RootView 那一层，占满整屏高度），
/// 点哪段就在这一页原地打开，不推二级页。MacBook 上的会话是同步过来的只读快照，派出去的活由 Mac mini 执行。
struct WorkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("work.lastAgent") private var lastAgent = "codex"
    @AppStorage("work.surface") private var surfaceRaw = WorkSurface.sessions.rawValue
    @State private var frames: [String: CGRect] = [:]
    @State private var flights: [String: OutgoingFlight] = [:]
    private var work: WorkSessionModel { model.work }
    /// 当前派给谁：新对话是选中的 Agent，会话里是那段会话的。
    private var agent: String { work.mode == .home ? lastAgent : work.agent }
    private var surface: Binding<WorkSurface> {
        Binding(
            get: { WorkSurface(rawValue: surfaceRaw) ?? .sessions },
            set: { surfaceRaw = $0.rawValue }
        )
    }
    private var onRemote: Bool { surface.wrappedValue == .remote }

    var body: some View {
        VStack(spacing: 0) {
            if !model.approvalDeepLinkNote.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    InlineNotice(text: model.approvalDeepLinkNote, tone: .danger)
                    Button("打开等你") { model.openWaitingInbox() }
                        .buttonStyle(.secondaryCompact)
                        .accessibilityIdentifier("work-approval-deeplink-waiting")
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .accessibilityIdentifier("work-approval-deeplink-fail")
            }
            if !model.workOpenNote.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    InlineNotice(text: model.workOpenNote, tone: .danger)
                    Button("再拉侧栏") {
                        Task { await model.refresh(.work) }
                    }
                    .buttonStyle(.secondaryCompact)
                    .accessibilityIdentifier("work-sidebar-refresh")
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .accessibilityIdentifier("work-open-fail")
            }
            WorkSurfacePicker(surface: surface)
            ZStack {
                if onRemote {
                    WorkRemoteSurface()
                        .transition(reduce ? .opacity : .asymmetric(
                            insertion: .modifier(active: BlurShift(y: 10, blur: 5, opacity: 0), identity: BlurShift()),
                            removal: .opacity))
                } else if work.mode == .home {
                    NewWorkChat().transition(Self.homeTransition(reduce))
                } else {
                    WorkChat(flying: Set(flights.keys)).id(work.generation).transition(Self.chatTransition(reduce))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduce ? .easeOut(duration: 0.2) : ComMotion.crossfade, value: onRemote)
        }
        // 动效库 20-build-checklist：标题模糊上浮（y+26→0、blur 10→0、power3.out）/ 整块模糊上浮离场（y−30、blur 8）。
        .animation(reduce ? .easeOut(duration: 0.2) : ReplyMotion.rise, value: work.generation)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !onRemote { WorkComposer() }
        }
        // 轨道 r2-memory：当前 Agent 让页面顶部轻轻染上它的品牌浅底，换人时 0.5s 渐变过去。
        .background {
            ZStack(alignment: .top) {
                Palette.background
                if !onRemote {
                    LinearGradient(colors: [agentBrand(agent)?.wash ?? .clear, Palette.background.opacity(0)], startPoint: .top, endPoint: .center)
                        .opacity(0.9)
                }
            }
            .ignoresSafeArea()
            .animation(reduce ? .easeOut(duration: 0.2) : .smooth(duration: 0.5), value: agent)
        }
        .toolbar(.hidden, for: .navigationBar)
        // 发出去的那句从输入框飞到右侧气泡的位置（和主聊天同一套：ChatMotion 的 OutgoingBubbleFlight）。
        .coordinateSpace(name: "chat-stage")
        .onPreferenceChange(ChatFramePreference.self) { values in
            if frames != values { frames = values }
            for key in Array(flights.keys) where flights[key]?.layoutReady == true && flights[key]?.destination == nil {
                if let target = values[key] { flights[key]?.destination = target }
            }
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(flights.values)) { flight in OutgoingBubbleFlight(flight: flight) { flights.removeValue(forKey: flight.id) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).allowsHitTesting(false)
        }
        .onChange(of: work.outgoing.last?.requestID) { _, id in fly(id) }
        .task(id: work.pollKey) {
            guard !onRemote, work.mode != .home else { return }
            await work.refresh(model)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if model.active && model.isShown(.work) && !onRemote { await work.refresh(model) }
            }
        }
        .task(id: agent) { guard !onRemote else { return }; await work.loadModels(for: agent, model) }
        // 进页拉齐侧栏：与 refresh(.work) 同路，失败 workOpenNote，别假装历史已齐。
        .task { await model.refresh(.work) }
    }

    private func fly(_ id: String?) {
        guard let id, !reduce, let item = work.outgoing.last, let origin = frames["composer"], origin.width > 0 else { return }
        let key = "request:" + id
        flights[key] = OutgoingFlight(id: key, text: item.text, origin: origin.insetBy(dx: -18, dy: -7))
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(60))
            flights[key]?.layoutReady = true
            flights[key]?.destination = frames[key]
            // 落不了地（换页、切后台）也绝不让真气泡一直藏着。
            try? await Task.sleep(for: .milliseconds(900))
            flights.removeValue(forKey: key)
        }
    }

    static func homeTransition(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .modifier(active: BlurShift(y: 14, blur: 6, opacity: 0), identity: BlurShift()),
                                        removal: .modifier(active: BlurShift(y: -30, blur: 8, opacity: 0), identity: BlurShift()))
    }
    static func chatTransition(_ reduce: Bool) -> AnyTransition {
        // 进场不带位移：首页发出时气泡要量出落点，聊天流本身不能还在挪。
        reduce ? .opacity : .asymmetric(insertion: .modifier(active: BlurShift(blur: 4, opacity: 0), identity: BlurShift()),
                                        removal: .modifier(active: BlurShift(y: -12, blur: 6, opacity: 0), identity: BlurShift()))
    }
}

/// 位移 + 模糊 + 透明度一起收（20-build-checklist 的模糊上浮 / 离场）。
struct BlurShift: ViewModifier {
    var y: CGFloat = 0
    var blur: CGFloat = 0
    var opacity: Double = 1
    func body(content: Content) -> some View { content.opacity(opacity).offset(y: y).blur(radius: blur) }
}

/// 空白的新对话：居中一个头像和一句话。点头像换 Agent（顶栏标题也能换）。
private struct NewWorkChat: View {
    @AppStorage("work.lastAgent") private var lastAgent = "codex"
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 问候按上海时区，和工作外的伙伴口吻对齐。
    private var hour: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal.component(.hour, from: Date())
    }
    private var companion: String {
        let name = agentName(lastAgent)
        switch hour {
        case 5..<11: return "新开一段。说清楚要改什么、落在哪个目录——我派给 \(name)。"
        case 11..<14: return "空白画布。一句话就能派活；复杂的会拆成航程，不会闷头瞎跑。"
        case 14..<18: return "我在岗。丢一句需求就行——终端 SSH 另页探测，这里只派会话。"
        case 18..<23: return "晚上也接活。说目标与边界，\(name) 接手后你可去干别的。"
        default: return "夜深了也行。短任务直接派；长任务我会拆开给你看步骤。"
        }
    }
    var body: some View {
        VStack(spacing: Space.lg) {
            Menu {
                ForEach(["hermes", "pi", "claude", "codex"], id: \.self) { item in
                    Button { lastAgent = item } label: { Label { Text(agentName(item)) } icon: { Image(agentBrand(item)?.mark ?? "") } }
                }
            } label: {
                AgentAvatar(agent: lastAgent, size: 64)
                    .padding(6)
                    .background(Circle().fill(agentBrand(lastAgent)?.wash ?? Palette.fill).opacity(0.55))
            }
            .accessibilityLabel("当前是 " + agentName(lastAgent) + "，点按更换")
            VStack(spacing: Space.sm) {
                Text("让 \(agentName(lastAgent)) 做点什么")
                    .font(TypeScale.section)
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.opacity)
                Text(companion)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, Space.xl)
                    .contentTransition(.opacity)
                    .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: companion)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Space.xxxl)
        .animation(.smooth(duration: 0.2), value: lastAgent)
        .accessibilityIdentifier("work-new-chat")
    }
}

/// 工作页的历史侧栏（r3-work）：挂在 RootView 那一层，从左滑进来占满整屏高度（连原来 Dock 那一截），
/// 主内容连同 Dock 被推到右边、压暗；点右边那一条、往左划、点 ✕ 都能收起。
struct WorkSidebarLayer: View {
    /// 侧栏宽：右边留 64pt 露出被推走的主内容（点它收起）。
    static func width(for screen: CGFloat) -> CGFloat { max(280, (screen > 0 ? screen : 402) - 64) }
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("work.host") private var host = "mini"
    @AppStorage("work.agent") private var agent = ""
    @State private var showBoard = false
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    let width: CGFloat
    private var board: JSON { model.datasets["/personal/projects"] ?? .null }
    private var sessionsMissing: Bool { model.datasets["/sessions"] == nil }
    var body: some View {
        let work = model.work
        let waiting = loading || (!loadedOnce && board.isNull && sessionsMissing)
        WorkSidebar(host: $host, agent: $agent, threads: WorkThread.build(board: board, sessions: model.datasets["/sessions"]?["sessions"].array ?? []),
                    hosts: board["hosts"].array, loading: waiting, failNote: failNote,
                    retrying: loading, onRetry: { Task { await refreshSidebar() } },
                    current: work.mode == .session ? work.sessionID : work.mode == .snapshot ? work.snapshot.id : "",
                    showBoard: $showBoard, close: { model.closeWorkSidebar(reduce: reduce) }) { open($0) }
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.background.ignoresSafeArea())
            .compositingGroup()
            .shadow(color: .black.opacity(0.14), radius: 18, x: 4)
            // 往左划收起：跟手，松手按速度和位置决定。
            .simultaneousGesture(DragGesture(minimumDistance: 14).onChanged { value in
                guard model.showWorkSidebar, value.translation.width < 0, abs(value.translation.width) > abs(value.translation.height) else { return }
                model.dragWorkSidebar(max(-width, value.translation.width))
            }.onEnded { value in
                guard model.workSidebarDrag != 0 else { return }
                let predicted = value.predictedEndTranslation.width
                DispatchQueue.main.async { model.settleWorkSidebar(predicted: predicted, width: width, reduce: reduce) }
            })
            .sheet(isPresented: $showBoard) { BoardSheet(host: host) }
            .task { await refreshSidebar() }
    }
    /// 能续接的在这一页原地聊；只有进展快照的（MacBook 上的 Pi/Codex）原地打开只读摘录。
    /// 对不上的项留在侧栏开口，别关栏假装已打开。
    private func open(_ thread: WorkThread) {
        Haptics.selection()
        if let session = thread.session {
            guard !session.id.isEmpty else {
                failNote = "这条会话对不上——可再拉齐侧栏后点一次。不会假装已打开。"
                return
            }
            model.work.open(session)
        } else if let item = thread.item {
            guard !item.id.isEmpty else {
                failNote = "这条进展摘录对不上——可再拉齐侧栏后点一次。不会假装已打开。"
                return
            }
            model.work.openSnapshot(item)
        } else {
            failNote = "点开没成——缺会话或摘录。可再试拉齐侧栏。"
            return
        }
        failNote = ""
        model.closeWorkSidebar(reduce: reduce)
    }
    private func refreshSidebar() async {
        guard !loading else { return }
        loading = true
        failNote = ""
        defer {
            loading = false
            loadedOnce = true
        }
        async let projects = model.load("/personal/projects")
        async let sessions = model.load("/sessions")
        let gotProjects = await projects != nil
        let gotSessions = await sessions != nil
        if gotProjects && gotSessions { return }
        let projectErr = model.errors["/personal/projects"] ?? ""
        let sessionErr = model.errors["/sessions"] ?? ""
        if !gotProjects && !gotSessions {
            let err = [projectErr, sessionErr].first { !$0.isEmpty } ?? ""
            failNote = err.isEmpty
                ? "项目和会话都没拢上——检查配对或网络后再试"
                : "侧栏没拢上：" + err + "——可再试"
        } else if !gotProjects {
            failNote = projectErr.isEmpty
                ? "项目看板没读上——会话若在仍可先点；可再试"
                : "项目看板没读上：" + projectErr + "——可再试"
        } else {
            failNote = sessionErr.isEmpty
                ? "会话列表没读上——项目若在仍可先点；可再试"
                : "会话列表没读上：" + sessionErr + "——可再试"
        }
    }
}

/// 侧栏内容：电脑 → Agent 分区，下面按天分组的对话。
private struct WorkSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Binding var host: String
    @Binding var agent: String
    let threads: [WorkThread]
    let hosts: [JSON]
    let loading: Bool
    var failNote: String = ""
    var retrying: Bool = false
    var onRetry: (() -> Void)? = nil
    /// 正在聊的那段（会话 id 或快照 id），在列表里高亮。
    let current: String
    @Binding var showBoard: Bool
    let close: () -> Void
    let open: (WorkThread) -> Void
    @State private var limit = 40
    @Namespace private var partition
    private var hostThreads: [WorkThread] { threads.filter { $0.host == host } }
    private var shown: [WorkThread] { hostThreads.filter { agent.isEmpty || $0.agent == agent } }
    private var agents: [String] {
        let present = Set(hostThreads.map(\.agent))
        return ["hermes", "pi", "claude", "codex"].filter { present.contains($0) || host == "mini" }
    }
    var body: some View {
        let rows = shown
        VStack(spacing: 0) {
            HStack {
                Text("历史对话").font(TypeScale.section)
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.textSecondary).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).accessibilityLabel("收起历史对话").accessibilityIdentifier("work-sidebar-close")
            }
            .padding(.horizontal, Layout.margin).padding(.top, Space.md)
            PartitionBar(host: $host, agent: $agent, agents: agents, threads: threads, hosts: hosts, space: partition, showBoard: $showBoard)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !failNote.isEmpty {
                        InlineNotice(text: failNote, tone: .danger)
                            .padding(.top, Space.md)
                        if let onRetry {
                            Button(retrying ? "重试中…" : "再试一次") {
                                guard !retrying else { return }
                                onRetry()
                            }
                            .buttonStyle(.secondaryCompact)
                            .disabled(retrying)
                            .padding(.top, Space.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("work-sidebar-retry")
                        }
                    }
                    if rows.isEmpty {
                        Text(loading ? "正在把两台电脑上的会话拢到一起…" : !failNote.isEmpty ? "先重试拉齐；通了才会出现历史。" : host == "macbook" ? "MacBook 的会话大约每 15 分钟同步一次；急用可到那台机器上先开。" : "这边还空着。回去在输入框说一句，或从项目看板点进来——我帮你开一段。")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.top, Space.lg).padding(.horizontal, Space.xs)
                    }
                    ForEach(WorkThread.days(rows.prefix(limit)), id: \.title) { day in
                        Text(day.title).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                            .padding(.top, Space.lg).padding(.bottom, Space.xs).padding(.horizontal, Space.xs)
                        ForEach(day.items) { thread in
                            ThreadRow(thread: thread, showAgent: agent.isEmpty, current: !current.isEmpty && (thread.session?.id == current || thread.item?.id == current)) { open(thread) }
                        }
                    }
                    if rows.count > limit {
                        Button("再看更早的 \(rows.count - limit) 段") {
                            withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { limit += 60 }
                        }
                            .buttonStyle(.quiet).font(TypeScale.footnote.weight(.semibold)).padding(.top, Space.lg).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, Space.md).padding(.bottom, Space.xl)
            }
            .scrollIndicators(.hidden)
        }
        .onChange(of: host) { _, _ in limit = 40; if !agents.contains(agent) { agent = "" } }
        .onChange(of: agent) { _, _ in limit = 40 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work-sidebar-panel")
    }
}

// MARK: - 数据

struct WorkThread: Identifiable {
    let id: String
    let host: String
    let agent: String
    let title: String
    let project: String
    let summary: String
    let nextStep: String
    let status: String
    let updated: Double
    var session: JSON?
    var item: JSON?

    /// 看板（两台电脑、整理过的进展）和 mini 上能续接的会话合成一份：同一段会话只出现一次。
    static func build(board: JSON, sessions: [JSON]) -> [WorkThread] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [WorkThread] = []
        for project in board["projects"].array {
            for item in project["items"].array {
                let native = item["native_id"].string
                let key = item["host"].string + ":" + native
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                // Claude 的历史两台机器同步，MacBook 上的那段在 mini 也能打开。
                let session = byID[native]
                out.append(WorkThread(id: item.id, host: item["host"].string, agent: item["agent"].string,
                                      title: cleanTitle(item["title"].string, fallback: [item["summary"].string, project["title"].string]),
                                      project: project["title"].string, summary: item["summary"].string == "等待下一轮整理" ? "" : item["summary"].string,
                                      nextStep: item["next_step"].string, status: item["status"].string, updated: item["updated_at"].double,
                                      session: session, item: item))
                if session != nil { seen.insert("mini:" + native) }
            }
        }
        for session in sessions where !seen.contains("mini:" + session.id) {
            let title = session["display_title"].string.isEmpty ? session["title"].string : session["display_title"].string
            out.append(WorkThread(id: "session:" + session.id, host: "mini", agent: session["agent"].string,
                                  title: cleanTitle(title, fallback: [session["snippet"].string, URL(fileURLWithPath: session["cwd"].string).lastPathComponent]),
                                  project: URL(fileURLWithPath: session["cwd"].string).lastPathComponent, summary: session["snippet"].string,
                                  nextStep: "", status: session["status"].string, updated: session["updated"].double, session: session, item: nil))
        }
        return out.sorted { $0.updated > $1.updated }
    }

    /// 会话标题经常是命令回显（<local-command-caveat>…）：换成摘要或项目名。
    static func cleanTitle(_ title: String, fallback: [String]) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("Caveat") { return t }
        let first = fallback.first { !$0.isEmpty && $0 != "等待下一轮整理" } ?? "未命名对话"
        let line = first.split(whereSeparator: { "。；\n".contains($0) }).first.map(String.init) ?? first
        return line.count > 30 ? String(line.prefix(29)) + "…" : line
    }

    var tone: Tone {
        switch status {
        case "active", "running", "working": .success
        case "pending", "waiting", "approval_required", "interrupted": .warning
        default: .neutral
        }
    }
    var statusLabel: String {
        switch tone { case .success: "进行中"; case .warning: "未收尾"; default: status == "completed" ? "已完成" : "" }
    }

    struct Day { let title: String; let items: [WorkThread] }
    static func days<S: Sequence>(_ threads: S) -> [Day] where S.Element == WorkThread {
        let calendar = Calendar.current
        var groups: [(String, [WorkThread])] = []
        for thread in threads {
            let date = Date(timeIntervalSince1970: thread.updated)
            let title = calendar.isDateInToday(date) ? "今天" : calendar.isDateInYesterday(date) ? "昨天"
                : Date().timeIntervalSince(date) < 7 * 86400 ? "这一周" : "更早"
            if groups.last?.0 == title { groups[groups.count - 1].1.append(thread) } else { groups.append((title, [thread])) }
        }
        return groups.map { Day(title: $0.0, items: $0.1) }
    }
}

// 轨道 r2-memory：Agent 用各家的真实图标（来源见 ios/scripts/agent-logos/NOTES.md），
// 底色以品牌色为基准降饱和——Claude 暖陶土、Codex 冷灰、Hermes Nous 浅靛、Pi 浅薄荷。
private func agentDynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    func ui(_ v: UInt32) -> UIColor { UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
    return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
}
struct AgentBrand {
    /// Assets.xcassets 里的单色蒙版（template）。
    let mark: String
    /// 图标与强调用的品牌色（已降饱和）。
    let ink: Color
    /// 头像底、页面氛围用的浅底。
    let wash: Color
    /// 图标在圆里的留白比例：线稿头像要更满，几何标要留气口。
    let inset: CGFloat
}
func agentBrand(_ agent: String) -> AgentBrand? {
    switch agent {
    case "claude": AgentBrand(mark: "AgentClaude", ink: agentDynamic(0xC15F3C, 0xE59A7C), wash: agentDynamic(0xF7EAE3, 0x3A2620), inset: 0.22)
    case "codex": AgentBrand(mark: "AgentCodex", ink: agentDynamic(0x23262B, 0xE6E8EB), wash: agentDynamic(0xEBECEF, 0x2A2C31), inset: 0.22)
    case "hermes": AgentBrand(mark: "AgentHermes", ink: agentDynamic(0x3F3A8F, 0xC6C1FF), wash: agentDynamic(0xECEAFA, 0x272442), inset: 0.10)
    case "pi": AgentBrand(mark: "AgentPi", ink: agentDynamic(0x1F6B57, 0x9BDFC5), wash: agentDynamic(0xE2F2EA, 0x1C302A), inset: 0.27)
    default: nil
    }
}
func agentTint(_ agent: String) -> Color { agentBrand(agent)?.ink ?? Palette.textSecondary }

/// Agent 的真实图标（单色，按品牌色上色）。
struct AgentMark: View {
    let agent: String
    var body: some View {
        if let brand = agentBrand(agent) {
            Image(brand.mark).renderingMode(.template).resizable().interpolation(.high).scaledToFit().foregroundStyle(brand.ink)
        } else {
            Image(systemName: "square.grid.2x2").resizable().scaledToFit().foregroundStyle(Palette.textPrimary)
        }
    }
}

/// Agent 头像：品牌浅底的圆，里面是它的真实图标。
/// 换 Agent 时像贴纸一样「盖」上来——动效库 03-badge-stamp（徽章从 1.75 倍、-8.7° 旋转甩进来摊平贴住），
/// 手机上收成 1.3 倍 / -9° → 0.96 → 1 的三段弹簧，reduce motion 时只淡入。
struct AgentAvatar: View {
    let agent: String
    var size: CGFloat = 36
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let brand = agentBrand(agent)
        AgentMark(agent: agent)
            .padding(size * (brand?.inset ?? 0.28))
            .frame(width: size, height: size)
            .background(brand?.wash ?? Palette.fill, in: .circle)
            .overlay(Circle().strokeBorder((brand?.ink ?? Palette.textPrimary).opacity(0.10), lineWidth: 0.5))
            .clipShape(.circle)
            .modifier(AgentStampMotion(trigger: agent, reduce: reduce))
            .accessibilityHidden(true)
    }
}
struct AgentStampPose { var scale: CGFloat = 1; var angle: Double = 0 }

/// 把 reduce 作为普通 Bool 传入 keyframe 闭包，避免捕获 `@Environment` 主线程隔离属性。
private struct AgentStampMotion: ViewModifier {
    let trigger: String
    let reduce: Bool
    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: AgentStampPose(), trigger: trigger) { view, pose in
            view.scaleEffect(reduce ? 1 : pose.scale).rotationEffect(.degrees(reduce ? 0 : pose.angle))
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.3, duration: 0.001)
                SpringKeyframe(0.96, duration: 0.16, spring: .snappy)
                SpringKeyframe(1, duration: 0.24, spring: .bouncy)
            }
            KeyframeTrack(\.angle) {
                CubicKeyframe(-9, duration: 0.001)
                SpringKeyframe(2, duration: 0.16, spring: .snappy)
                SpringKeyframe(0, duration: 0.24, spring: .smooth)
            }
        }
    }
}

// MARK: - 分区栏

/// 两级分区：电脑（滑块）→ Agent（胶囊，带条数和「在跑」点）。最后是项目看板入口。
/// r3-work：胶囊放不下就折到第二行（原来横向滚动，第 4 个 Claude 被侧栏边缘切成「Cl」）。
private struct PartitionBar: View {
    @Binding var host: String
    @Binding var agent: String
    let agents: [String]
    let threads: [WorkThread]
    let hosts: [JSON]
    let space: Namespace.ID
    @Binding var showBoard: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    private var motion: Animation { ComMotion.reduced(reduce, ComMotion.settle) }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: 4) {
                ForEach(["mini", "macbook"], id: \.self) { entry in machine(entry) }
            }
            .padding(4)
            .background(Palette.fill, in: .rect(cornerRadius: Radius.md, style: .continuous))
            FlowLayout(spacing: Space.sm) {
                chip("", label: "全部", count: threads.filter { $0.host == host }.count)
                ForEach(agents, id: \.self) { item in
                    chip(item, label: agentName(item).replacingOccurrences(of: " Code", with: ""), count: threads.filter { $0.host == host && $0.agent == item }.count)
                }
                Button { showBoard = true } label: {
                    Label("项目", systemImage: "rectangle.3.group").font(TypeScale.subheadline)
                        .padding(.horizontal, Space.md).padding(.vertical, Space.sm).foregroundStyle(Palette.textSecondary)
                }.buttonStyle(.plain).accessibilityIdentifier("work-board")
            }
        }
        .padding(.horizontal, Layout.margin).padding(.top, Space.sm).padding(.bottom, Space.md)
        .sensoryFeedback(.selection, trigger: host + agent)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 0.5) }
    }

    private func machine(_ entry: String) -> some View {
        let selected = host == entry
        let row = hosts.first { $0["host"].string == entry }
        let fresh = row.map { Date().timeIntervalSince1970 - $0["collected_at"].double < 3600 } ?? false
        let running = threads.filter { $0.host == entry && $0.tone == .success }.count
        return Button { withAnimation(motion) { host = entry } } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: entry == "mini" ? "macmini" : "laptopcomputer").font(.system(size: 16, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text(hostName(entry)).font(TypeScale.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        Circle().fill(fresh ? Palette.success : Palette.textTertiary.opacity(0.6)).frame(width: 5, height: 5)
                        Text(running > 0 ? "在跑 \(running)" : entry == "mini" ? "可派活" : "只读同步").lineLimit(1)
                    }.font(.caption2).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Palette.surface)
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "machine", in: space)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(SoftPressStyle(scale: 0.985))
        .accessibilityIdentifier("work-host-" + entry)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chip(_ id: String, label: String, count: Int) -> some View {
        let selected = agent == id
        let live = threads.contains { $0.host == host && (id.isEmpty || $0.agent == id) && $0.tone == .success }
        // 轨道 r2-memory：选中的 Agent 胶囊换成它的品牌浅底 + 品牌色字，「全部」仍是墨色。
        let brand = agentBrand(id)
        let selectedText = brand?.ink ?? Palette.onInk
        return Button { withAnimation(motion) { agent = id } } label: {
            HStack(spacing: 6) {
                if !id.isEmpty { AgentMark(agent: id).frame(width: 14, height: 14) }
                Text(label).font(TypeScale.subheadline.weight(selected ? .semibold : .regular))
                if count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(selected ? selectedText.opacity(0.68) : Palette.textTertiary) }
            }
            .foregroundStyle(selected ? selectedText : Palette.textPrimary)
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            .background {
                if selected {
                    Capsule().fill(brand?.wash ?? Palette.ink)
                        .overlay(Capsule().strokeBorder((brand?.ink ?? .clear).opacity(0.22), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "agent", in: space)
                }
                else { Capsule().fill(Palette.surface).overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 0.5)) }
            }
            .overlay(alignment: .topTrailing) { if live { Circle().fill(Palette.success).frame(width: 7, height: 7).overlay(Circle().stroke(Palette.background, lineWidth: 1.5)).offset(x: 1, y: -1) } }
        }
        .buttonStyle(SoftPressStyle(scale: 0.97))
        .accessibilityIdentifier("work-agent-" + (id.isEmpty ? "all" : id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 一段对话：头像、标题、一行摘要；右边时间和状态。
private struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let thread: WorkThread
    let showAgent: Bool
    /// 正在主区域聊的这段（r3-work）：浅底标出来。
    var current = false
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Space.md) {
                AgentAvatar(agent: thread.agent, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(thread.title).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(relativeTime(thread.updated)).font(.caption).foregroundStyle(Palette.textTertiary).fixedSize()
                    }
                    let detail = thread.summary.isEmpty ? thread.project : thread.summary
                    if !detail.isEmpty { Text(detail).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(2) }
                    HStack(spacing: Space.sm) {
                        if !thread.statusLabel.isEmpty {
                            HStack(spacing: 4) { Circle().fill(thread.tone.color).frame(width: 6, height: 6); Text(thread.statusLabel) }
                                .foregroundStyle(thread.tone == .neutral ? Palette.textTertiary : thread.tone.color)
                        }
                        if showAgent { Text(agentName(thread.agent)) }
                        if !thread.project.isEmpty && !thread.summary.isEmpty { Text(thread.project).lineLimit(1) }
                        if thread.session == nil { Label("只读", systemImage: "eye").labelStyle(.titleAndIcon) }
                    }.font(.caption).foregroundStyle(Palette.textTertiary)
                    // 10-18 会话↔航程互通：这段是某段航程的执行会话
                    if let title = thread.session?["case_title"].string, !title.isEmpty {
                        Label("航程 · " + title, systemImage: "rectangle.stack").font(.caption.weight(.medium)).foregroundStyle(Palette.accentText).lineLimit(1)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, Space.md).padding(.horizontal, Space.sm)
            .background(current ? Palette.fill : .clear, in: .rect(cornerRadius: Radius.md, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(ThreadPress())
        .contextMenu {
            if let caseID = thread.session?["case_id"].string, !caseID.isEmpty {
                Button("查看航程", systemImage: "rectangle.stack") { model.openThreadNode(.object(["kind": .string("case"), "id": .string(caseID)])) }
            }
        }
        .accessibilityIdentifier("work-thread-" + thread.id)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

private struct ThreadPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.fill : .clear, in: .rect(cornerRadius: Radius.md, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 输入框

/// 输入框（r3-work）：原来右边那颗设置按钮删了，里面的东西拆到别处——
/// 派给谁 → 顶栏标题（点开换人，见 WorkTitleMenu）和首页中间的头像；项目目录、模型、推理强度 → 左边「+」。
/// 右边：有字时发送；没字且会话在跑时是停止（ChatGPT 那样）。都在 Mac mini 上执行。
private struct WorkComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("work.lastAgent") private var lastAgent = "codex"
    @FocusState private var focused: Bool
    @State private var pickingDirectory = false
    @State private var sending = false
    private var work: WorkSessionModel { model.work }
    private var draft: Binding<String> {
        Binding(
            get: { work.mode == .home ? work.homeDraft : work.sessionDraft },
            set: { next in
                if work.mode == .home { work.homeDraft = next }
                else { work.sessionDraft = next } // didSet 落盘；失败 → draftPersistNote
            }
        )
    }
    private var empty: Bool { draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// 第一次往电脑上的终端里打字前问一句（可能和人在电脑前同时打字撞上），之后不再问。
    @AppStorage("work.injectConfirmed") private var injectConfirmed = false
    @State private var confirmingInject = false
    private var routeHint: (String, String)? {
        guard work.mode != .home, !work.starting else { return nil }
        switch work.dispatchMode {
        case "injected": return ("这段正开在电脑的终端里", "terminal")
        case "resumed", "adopted": return ("会先接上原会话", "arrow.clockwise")
        case "forked": return (work.mode == .snapshot ? "MacBook 上的会话 · 会在 mini 上接着做" : "原会话被占着 · 会带着前情开新会话", "arrow.triangle.branch")
        default: return nil
        }
    }
    /// 不能直接输入时的路由（后端预判），用占位文字说清楚发出去会怎样。
    private var placeholder: String {
        if work.mode == .home { return "让 \(agentName(lastAgent)) 做点什么" }
        switch work.dispatchMode {
        case "injected": return "会打进电脑上正在跑的终端"
        case "resumed", "adopted": return "发出去会先接上原会话"
        case "forked": return work.mode == .snapshot ? "接着这段，在 mini 上开新会话做" : "接不上原会话，会带着前情开新会话"
        default: return "继续这项工作"
        }
    }
    var body: some View {
        @Bindable var work = model.work
        VStack(alignment: .leading, spacing: Space.sm) {
            // 首页派活 / 会话续发失败都开口；勿只靠气泡旁注或灰 Caption。
            if !work.note.isEmpty {
                InlineNotice(text: work.note, tone: .danger)
                    .padding(.horizontal, Space.sm)
                    .accessibilityIdentifier("work-composer-fail")
            }
            if !work.draftPersistNote.isEmpty {
                InlineNotice(text: work.draftPersistNote, tone: .warning)
                    .padding(.horizontal, Space.sm)
                    .accessibilityIdentifier("work-draft-persist-fail")
            }
            if let reference = model.reference, work.mode == .session, !work.sessionID.isEmpty, reference["source_session_id"].string == work.sessionID {
                HStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: Space.xs) { Text("回复 \(reference["author"].string)").font(TypeScale.footnote.weight(.semibold)); Text(reference["text"].string).font(TypeScale.footnote).lineLimit(2).foregroundStyle(Palette.textSecondary) }
                    Spacer(); Button { model.reference = nil } label: { Image(systemName: "xmark").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary) }.accessibilityLabel("取消引用")
                }.fixedSize(horizontal: false, vertical: true).padding(Space.md).composerSurface()
            }
            // 接不上原会话时，输入框上面一枚小签说清楚这句会走哪条路；换会话、路由变了时模糊上浮换过去。
            if let route = routeHint {
                Label(route.0, systemImage: route.1)
                    .font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Space.md).padding(.vertical, 6)
                    .background(Palette.fill, in: .capsule)
                    .padding(.horizontal, Space.sm)
                    .id(route.0)
                    .transition(reduce ? .opacity : .blurLift)
                    .accessibilityIdentifier("work-route-hint")
            }
            field
                .confirmationDialog("打进电脑上的终端？", isPresented: $confirmingInject, titleVisibility: .visible) {
                    Button("打进去，以后不用问") { injectConfirmed = true; send() }
                    Button("取消", role: .cancel) {}
                } message: { Text("这段会话正开在 mini 的终端里。手机发的话会像你在电脑前打字一样送进去；如果此刻电脑前也有人在打字，两边会混在一起。") }
        }
        .padding(.horizontal, Space.lg).padding(.top, Space.xs).padding(.bottom, Space.sm)
        // 列表从输入框和 Dock 底下滑过时淡出，免得两者之间露出半行字。
        .background(alignment: .top) {
            LinearGradient(stops: [.init(color: Palette.background.opacity(0), location: 0), .init(color: Palette.background, location: 0.35)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -Space.xl).padding(.bottom, -ComDock.height - 60).allowsHitTesting(false)
        }
        .animation(.smooth(duration: 0.2), value: empty)
        .animation(ComMotion.reduced(reduce, ComMotion.settle), value: routeHint?.0)
        .sheet(isPresented: $pickingDirectory) { DirectoryPicker(path: $work.directory).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .onChange(of: work.selection) { _, _ in work.effort = "" }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Space.sm) {
            plus
            TextField(placeholder, text: draft, axis: .vertical)
                .font(TypeScale.callout).lineLimit(1...6).focused($focused).padding(.vertical, Space.md - 2)
                .contentTransition(.opacity)
                .accessibilityIdentifier("work-input")
                .chatFrame("composer")
            ZStack {
                if empty && work.mode == .session && work.running && !work.starting {
                    CircleActionButton(symbol: work.stopping ? "hourglass" : "stop.fill", label: work.stopping ? "正在停止" : "停止执行", size: 40) {
                        guard !work.stopping, !work.ending else { return }
                        Task { await work.stop(model) }
                    }
                        .disabled(work.stopping || work.ending)
                        .accessibilityIdentifier("work-stop")
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    CircleActionButton(symbol: sending ? "hourglass" : "arrow.up", label: work.mode == .home ? "派出去" : "发送", filled: true, size: 40) { send() }
                        .disabled(empty || sending || work.starting)
                        .opacity(empty ? 0.35 : 1)
                        .accessibilityIdentifier("work-send")
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(ComMotion.reduced(reduce, ComMotion.pop), value: empty && work.running)
        }
        .padding(Space.sm)
        .composerSurface()
    }

    /// 「+」：原来设置按钮里的项目目录、模型、推理强度。会话里目录已定，只显示。
    private var plus: some View {
        @Bindable var work = model.work
        let efforts = work.models.first { $0.id == work.selection }?["efforts"].array.map(\.string) ?? []
        let modelLabel = work.selection.isEmpty ? "执行器默认" : (work.models.first { $0.id == work.selection }?["label"].string).flatMap { $0.isEmpty ? nil : $0 } ?? work.selection
        return Menu {
            if work.mode == .home {
                Button { pickingDirectory = true } label: { Label("项目目录：" + work.folder, systemImage: "folder") }
            } else {
                Button {} label: { Label("项目目录：" + work.folder, systemImage: "folder") }.disabled(true)
            }
            Picker(selection: $work.selection) {
                Text("执行器默认").tag("")
                ForEach(work.models.map(RemoteRow.init)) { row in Text(row.value["label"].string.isEmpty ? row.id : row.value["label"].string).tag(row.id) }
            } label: { Label("模型：" + modelLabel, systemImage: "cpu") }
            .pickerStyle(.menu)
            if !efforts.isEmpty {
                Picker(selection: $work.effort) {
                    Text("默认").tag("")
                    ForEach(efforts, id: \.self) { Text($0).tag($0) }
                } label: { Label("推理强度：" + (work.effort.isEmpty ? "默认" : work.effort), systemImage: "gauge.with.dots.needle.50percent") }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.textPrimary)
                .frame(width: 40, height: 40).background(Palette.fill, in: .circle)
        }
        .accessibilityLabel("项目目录、模型和推理强度")
        .accessibilityIdentifier("work-composer-plus")
    }

    private func send() {
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, !work.starting else { return }
        Haptics.selection()
        work.note = ""
        if work.mode != .home && work.dispatchMode == "injected" && !injectConfirmed { confirmingInject = true; return }
        if work.mode == .home { start(text) } else { Task { sending = true; await work.submit(text, model); sending = false } }
    }
    /// 新对话：页面原地变成这段聊天（气泡先上来），回执到了接上真正的会话。
    private func start(_ text: String) {
        let agent = lastAgent, cwd = work.directory
        let entry: PendingMessage
        do {
            entry = try model.queueWork(path: "/sessions", text: text, fields: ["agent": .string(agent), "cwd": .string(cwd), "prompt": .string(text), "model": .string(work.selection), "effort": .string(work.effort), "sandbox": .string("danger-full-access")])
        } catch {
            // 草稿还在输入框；开口别只抛系统串。
            work.note = "没排进发送队列：" + error.localizedDescription + "——草稿还在，可再试派出去"
            return
        }
        work.homeDraft = ""
        work.begin(agent: agent, cwd: cwd, text: text, requestID: entry.id)
        Task {
            sending = true; defer { sending = false }
            let result = await work.deliver(entry.id, model)
            if let sid = result?["sid"].string, !sid.isEmpty {
                work.attach(sid)
                work.note = ""
                await model.refresh(.work)
            } else if result?["status"].string == "rejected" {
                work.failStart(result?["error"].string ?? "没派出去", rejected: true)
            } else {
                work.failStart("送达待核实。要求已保存，可在发送记录中查询回执。", rejected: false)
            }
        }
    }
}

/// 顶栏标题（工作页，r3-work）：新对话时是「派给谁」（原来输入框左边头像 / 设置按钮里的执行器）；
/// 打开的会话里是这段的状态和操作——原 WorkDetailView 右上角「…」菜单里的停止、置顶、结束。
struct WorkTitleMenu: View {
    @Environment(AppModel.self) private var model
    @AppStorage("work.lastAgent") private var lastAgent = "codex"
    var body: some View {
        let work = model.work
        Menu {
            switch work.mode {
            case .home:
                Picker(selection: $lastAgent) {
                    ForEach(["hermes", "pi", "claude", "codex"], id: \.self) { item in
                        Label { Text(agentName(item)) } icon: { Image(agentBrand(item)?.mark ?? "") }.tag(item)
                    }
                } label: { Text("派给谁") }
                .pickerStyle(.inline)
            case .session:
                Section(agentName(work.agent) + " · " + workStatusLabel(work.status)) {
                    if work.running && !work.starting {
                        Button(work.stopping ? "正在停止…" : "停止执行", systemImage: "stop.circle") {
                            guard !work.stopping, !work.ending else { return }
                            Task { await work.stop(model) }
                        }
                        .disabled(work.stopping || work.ending || work.pinning)
                    }
                    if !work.sessionID.isEmpty {
                        Button(work.pinning ? "处理中…" : (work.pinned ? "取消置顶" : "置顶"), systemImage: work.pinned ? "pin.slash" : "pin") {
                            guard !work.pinning, !work.ending else { return }
                            Task { await work.togglePin(model) }
                        }
                        .disabled(work.pinning || work.ending)
                        Button(work.ending ? "正在结束…" : "结束会话", systemImage: "xmark.circle", role: .destructive) {
                            guard !work.ending, !work.pinning else { return }
                            Task { await work.end(model) }
                        }
                        .disabled(work.ending || work.pinning)
                    }
                }
                Button("新对话", systemImage: "square.and.pencil") { model.work.newChat() }
            case .snapshot:
                Section(hostName(work.snapshot["host"].string) + " 上的只读摘录") {
                    Button("新对话", systemImage: "square.and.pencil") { model.work.newChat() }
                }
            }
        } label: {
            Color.clear.contentShape(Rectangle())
        }
        .accessibilityLabel(work.mode == .home ? "派给 " + agentName(lastAgent) + "，点开换人" : agentName(work.agent) + "，" + workStatusLabel(work.status) + "，点开会话菜单")
        .accessibilityIdentifier("work-title-menu")
    }
}

/// 会话状态的说法：后端的几个工作器状态补上中文（其余沿用 stampLabel）。
func workStatusLabel(_ status: String) -> String {
    switch status {
    case "starting": "正在派出"
    case "ready": "空闲"
    case "history": "历史"
    case "active", "working": "进行中"
    default: stampLabel(status)
    }
}

/// 项目看板挪进一张 sheet：分区栏右边的「项目」。
private struct BoardSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: String
    var body: some View {
        NavigationStack {
            ScrollPage { ProjectBoardHome(host: host) }
                .navigationTitle("项目看板").navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Palette.background, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}
