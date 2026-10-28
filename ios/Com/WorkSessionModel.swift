import SwiftUI
import ComCore

/// r3-work：工作页里正打开的那段对话。像 ChatGPT / Claude App：侧栏点会话、首页发出去，都在同一页原地变成聊天，
/// 不再推二级页。一份状态三处用：工作页的聊天流和输入框、顶栏标题菜单（停止 / 置顶 / 结束）、侧栏里的当前高亮。
@MainActor @Observable final class WorkSessionModel {
    enum Mode: Equatable { case home, session, snapshot }
    static let defaultDirectory = "/Users/eddiegao/AI_Work_System"

    private(set) var mode: Mode = .home
    /// 每换一段对话 +1：聊天流按它整体换一次（淡出旧的、淡入新的），不逐行乱动。
    private(set) var generation = 0
    private(set) var sessionID = ""
    /// 会话元数据：先用列表里那份，拉到 /sessions/{id} 后换成带 capabilities 的完整版。
    private(set) var metadata: JSON = .null
    /// MacBook 上的只读进展快照（没有能续接的会话）。
    private(set) var snapshot: JSON = .null
    private(set) var history: [JSON] = []
    private(set) var live: JSON = .null
    /// 发出去、还没等到服务器回声的消息：右侧气泡先上来，回声带同一个 request_id 时原地接替。
    private(set) var outgoing: [Outgoing] = []
    private(set) var loaded = false
    var note = ""
    var models: [JSON] = []
    var selection = ""
    var effort = ""
    /// 首页（新对话）的项目目录；原来在输入框右边设置按钮的派活页里选，现在在输入框左边「+」里。
    var directory = WorkSessionModel.defaultDirectory
    var homeDraft = ""
    var sessionDraft = "" {
        didSet { if mode == .session, !sessionID.isEmpty { try? SecureVault.save(sessionDraft, name: "work-draft-" + sessionID.pathEncoded) } }
    }

    struct Outgoing: Equatable {
        let requestID: String
        let text: String
        let createdAt: Double
        /// 发出时服务器里同样文字的用户消息有几条：多出来一条就是回声到了（回声没带 request_id 时的兜底）。
        let baseline: Int
        var state = "sending"
        var note = ""
    }

    /// 聊天流里的一行：我的话 / 它的回复 / 折起来的工具步骤。
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case user, reply, steps }
        let id: String
        let kind: Kind
        var message: JSON = .null
        var steps: [JSON] = []
        var live = false
        /// 回复：这一轮第一条回复上面挂头像和名字。
        var header = false
        var outgoing: Outgoing?
        /// 10-28：这一轮 Agent 自己记的 todo 清单（Pi todo / Claude todo-card·TodoWrite / Codex update_plan），挂在这一轮最后一段步骤上，画成时间轴。
        var plan: TurnPlan?
        var planLive = false
        /// 这一轮动用的工具（不含记清单本身），时间轴上挂在进行中那一步下面。
        var planTools: [WorkGroup] = []
    }

    // MARK: 读

    var agent: String { mode == .snapshot ? snapshot["agent"].string : metadata["agent"].string }
    var title: String {
        if mode == .snapshot { return snapshot["title"].string }
        let display = metadata["display_title"].string
        return display.isEmpty ? metadata["title"].string : display
    }
    var status: String { live["status"].string.isEmpty ? metadata["status"].string : live["status"].string }
    var running: Bool { ["running", "active", "working", "starting"].contains(status) }
    var starting: Bool { mode == .session && sessionID.isEmpty }
    var canInput: Bool { metadata["capabilities"]["input"].bool }
    /// 不能直接输入时，发出去会走哪条路（后端预判）：injected 打进电脑上的终端 / resumed、adopted 先接上原会话 / forked 带前情开新会话。
    var dispatchMode: String { mode == .snapshot ? "forked" : canInput ? "input" : metadata["capabilities"]["dispatch_mode"].string }
    var pinned: Bool { metadata["pinned"].bool }
    var approvals: [JSON] { live["approvals"].array }
    /// 最近一轮的 token 用量；老会话或未上报时为 null。
    var usage: JSON { live["usage"] ?? .null }
    var folder: String { URL(fileURLWithPath: mode == .home ? directory : metadata["cwd"].string).lastPathComponent }
    /// 轮询的钥匙：换会话、拿到 sid 时重开。
    var pollKey: String { "\(mode)-\(sessionID)-\(snapshot.id)-\(generation)" }

    var rows: [Row] { Self.rows(merged: Self.merge(history, live["items"].array), outgoing: outgoing, running: running) }

    // MARK: 开 / 关

    func open(_ session: JSON) {
        mode = .session; sessionID = session.id; metadata = session; snapshot = .null
        reset()
        sessionDraft = (try? SecureVault.load(String.self, name: "work-draft-" + sessionID.pathEncoded)) ?? ""
    }
    func openSnapshot(_ item: JSON) {
        mode = .snapshot; sessionID = ""; metadata = .null; snapshot = item
        reset()
    }
    func newChat() {
        mode = .home; sessionID = ""; metadata = .null; snapshot = .null
        reset()
    }
    /// keepChoices：首页发出时保留刚在「+」里选的模型和推理强度，接着用在这段会话里。
    private func reset(keepChoices: Bool = false) {
        history = []; live = .null; outgoing = []; note = ""; loaded = false
        if !keepChoices { selection = ""; effort = "" }
        generation += 1
    }

    /// 首页发出：页面原地变成这段对话，右侧气泡先上来；拿到 sid 前状态是「starting」。
    func begin(agent: String, cwd: String, text: String, requestID: String) {
        mode = .session; sessionID = ""; snapshot = .null
        reset(keepChoices: true)
        metadata = .object(["agent": .string(agent), "cwd": .string(cwd), "title": .string(String(text.prefix(60))), "status": .string("starting")])
        outgoing = [Outgoing(requestID: requestID, text: text, createdAt: Date().timeIntervalSince1970, baseline: 0)]
        sessionDraft = ""
    }
    /// 回执到了：接上真正的会话 id，同一个聊天流继续（不换 generation，不重播进场）。
    func attach(_ sid: String) {
        guard mode == .session, sessionID.isEmpty else { return }
        sessionID = sid; metadata["id"] = .string(sid); metadata["status"] = .string("running")
        if let index = outgoing.indices.last { outgoing[index].state = "accepted" }
    }
    func failStart(_ message: String, rejected: Bool) {
        if let index = outgoing.indices.last { outgoing[index].state = rejected ? "rejected" : "uncertain"; outgoing[index].note = message }
        metadata["status"] = .string(rejected ? "failed" : "unknown")
    }
    /// 没送出去的那条拿回输入框；首页发的那条，页面回到首页。
    func restore(_ requestID: String) -> String? {
        guard let item = outgoing.first(where: { $0.requestID == requestID && $0.state == "rejected" }) else { return nil }
        if sessionID.isEmpty { newChat(); homeDraft = item.text; return item.text }
        outgoing.removeAll { $0.requestID == requestID }
        sessionDraft = item.text
        return item.text
    }

    // MARK: 拉取

    func refresh(_ model: AppModel) async {
        switch mode {
        case .home: return
        case .snapshot:
            let id = snapshot.id
            guard let data = await model.load("/personal/projects/sources/" + id.pathEncoded), mode == .snapshot, snapshot.id == id else { return }
            history = data["messages"].array; loaded = true
        case .session:
            guard !sessionID.isEmpty else { return }
            let id = sessionID
            do {
                let detail = try await fetch("/sessions/" + id.pathEncoded, model)
                let current = try await fetch("/sessions/" + id.pathEncoded + "/live", model)
                guard mode == .session, sessionID == id else { return }
                if !detail.isNull {
                    var session = detail["session"]
                    if session["title"].string.isEmpty { session["title"] = metadata["title"] }
                    metadata = session; history = detail["messages"].array
                }
                if !current.isNull {
                    live = current
                    // 不在工作页时，把新审批发到通知中心；同一张卡只提醒一次。
                    ComNotifications.approvalWaiting(current["approvals"].array, sessionID: id, show: !model.isShown(.work))
                }
                loaded = true; note = ""
            } catch {
                guard sessionID == id else { return }
                note = "历史缓存 · " + error.localizedDescription
            }
        }
    }
    func loadModels(for agent: String, _ model: AppModel) async {
        guard !agent.isEmpty else { models = []; return }
        let data = await model.load("/models?agent=" + agent)
        models = data?["models"].array ?? []
        if !models.contains(where: { $0.id == selection }) { selection = ""; effort = "" }
    }
    private func fetch(_ path: String, _ model: AppModel) async throws -> JSON {
        #if DEBUG
        if model.isUITesting { return model.datasets[path] ?? .null }
        #endif
        guard let api = model.client else { throw APIError(status: 0, detail: "请先连接 Mac mini") }
        return try await api.request(path)
    }

    // MARK: 动作（原 WorkDetailView 右上角菜单和底部输入框的能力）

    /// 已有会话里继续说。气泡先上来，回执不确定时在气泡下面说明。
    /// 能直接输入的走 /input；其余（电脑上开着的、被占着的、MacBook 上的、已经结束的）走 /dispatch，由后端挑路，回执里的 mode 说走了哪条。
    func submit(_ text: String, _ model: AppModel) async {
        guard mode == .snapshot || (mode == .session && !sessionID.isEmpty) else { return }
        let id = mode == .snapshot ? snapshot.id : sessionID
        let current = { self.mode == .snapshot ? self.snapshot.id : self.sessionID }
        var fields: [String: JSON] = ["model": .string(selection), "effort": .string(effort)]
        if let reference = model.reference, reference["source_session_id"].string == id { fields["reference"] = reference }
        let entry: PendingMessage
        do { entry = try model.queueWork(path: "/sessions/" + id.pathEncoded + (dispatchMode == "input" ? "/input" : "/dispatch"), text: text, fields: fields) }
        catch { note = error.localizedDescription; return }
        let baseline = Self.merge(history, live["items"].array).filter { $0["role"].string == "user" && $0["text"].string == text }.count
        outgoing.append(Outgoing(requestID: entry.id, text: text, createdAt: Date().timeIntervalSince1970, baseline: baseline))
        sessionDraft = ""; model.reference = nil
        let result = await deliver(entry.id, model)
        guard current() == id, let index = outgoing.firstIndex(where: { $0.requestID == entry.id }) else { return }
        let newSID = result?["sid"].string ?? ""
        switch result?["status"].string {
        case "accepted" where result?["mode"].string == "forked" && !newSID.isEmpty:
            continueIn(newSID, from: title, outgoing: outgoing[index]); await refresh(model)
        case "accepted" where ["resumed", "adopted"].contains(result?["mode"].string ?? "") && !newSID.isEmpty:
            sessionID = newSID; metadata["id"] = .string(newSID); metadata["capabilities"]["input"] = .bool(true)
            outgoing[index].state = "accepted"; await refresh(model)
        case "accepted" where result?["mode"].string == "injected":
            outgoing[index].state = "elsewhere"; outgoing[index].note = "已打进电脑上正在跑的终端"; await refresh(model)
        case "accepted": outgoing[index].state = "accepted"; await refresh(model)
        case "rejected": outgoing[index].state = "rejected"; outgoing[index].note = result?["error"].string ?? "没送出去"
        default: outgoing[index].state = "uncertain"; outgoing[index].note = "送达待核实，要求已保存"
        }
    }
    func deliver(_ id: String, _ model: AppModel) async -> JSON? {
        #if DEBUG
        if model.isUITesting { return await simulateDelivery(id, model) }
        #endif
        return await model.deliverWork(id)
    }
    func stop(_ model: AppModel) async {
        #if DEBUG
        if model.isUITesting { live["status"] = .string("completed"); return }
        #endif
        await model.action("/sessions/" + sessionID.pathEncoded + "/stop"); await refresh(model)
    }
    func togglePin(_ model: AppModel) async {
        #if DEBUG
        if model.isUITesting { metadata["pinned"] = .bool(!pinned); return }
        #endif
        await model.action("/sessions/" + sessionID.pathEncoded + "/labels", fields: ["pinned": .bool(!pinned)], refresh: .work); await refresh(model)
    }
    func end(_ model: AppModel) async {
        #if DEBUG
        if model.isUITesting { live["status"] = .string("ended"); metadata["capabilities"]["input"] = .bool(false); return }
        #endif
        await model.action("/sessions/" + sessionID.pathEncoded + "/end", refresh: .work); await refresh(model)
    }
    /// 原会话接不上，后端带着前情开了新会话：页面原地换成新会话，刚发的那条留在顶上，说明是接着哪段做的。
    private func continueIn(_ sid: String, from oldTitle: String, outgoing item: Outgoing) {
        let agent = self.agent, cwd = mode == .snapshot ? snapshot["cwd"].string : metadata["cwd"].string
        mode = .session; sessionID = sid; snapshot = .null
        reset(keepChoices: true)
        metadata = .object(["id": .string(sid), "agent": .string(agent), "cwd": .string(cwd), "title": .string(oldTitle), "status": .string("running")])
        var moved = item; moved.state = "elsewhere"; moved.note = "接不上原会话，带着《\(oldTitle)》的前情开了新会话"
        outgoing = [moved]
    }
    // MARK: 合并与分行

    /// 历史按服务器给的顺序；实时条目按 id 覆盖同一条，新的接在后面（不按 id 排序，免得打乱先后）。
    static func merge(_ history: [JSON], _ items: [JSON]) -> [JSON] {
        var out = history
        var index: [String: Int] = [:]
        for (i, message) in out.enumerated() where !message.id.isEmpty { index[message.id] = i }
        for item in items where !item.id.isEmpty {
            if let i = index[item.id] { out[i] = item } else { index[item.id] = out.count; out.append(item) }
        }
        return out
    }

    static func rows(merged: [JSON], outgoing: [Outgoing], running: Bool) -> [Row] {
        // 本地气泡和服务器回声用同一个身份：先认 request_id，没有再按「同样文字多出来的那一条」认。
        var aliases: [String: String] = [:]
        var echoed = Set<String>()
        let users = merged.filter { $0["role"].string == "user" }
        let requests = Set(users.map { $0["request_id"].string }.filter { !$0.isEmpty })
        for item in outgoing {
            if requests.contains(item.requestID) { echoed.insert(item.requestID); continue }
            let same = users.filter { $0["text"].string.trimmingCharacters(in: .whitespacesAndNewlines) == item.text.trimmingCharacters(in: .whitespacesAndNewlines) && $0["request_id"].string.isEmpty }
            if same.count > item.baseline { aliases[same[item.baseline].id] = "request:" + item.requestID; echoed.insert(item.requestID) }
        }
        var out: [Row] = []
        var group: [JSON] = []
        var lastSpeaker = ""
        func flush(live: Bool) {
            guard let first = group.first else { return }
            out.append(Row(id: "steps:" + first.id, kind: .steps, steps: group, live: live))
            group = []
        }
        for message in merged {
            switch message["role"].string {
            case "user":
                flush(live: false)
                let request = message["request_id"].string
                let key = aliases[message.id] ?? (request.isEmpty ? message.id : "request:" + request)
                out.append(Row(id: key, kind: .user, message: message, outgoing: outgoing.first { "request:" + $0.requestID == key }))
                lastSpeaker = "user"
            case "assistant":
                guard !textContent(message["text"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                flush(live: false)
                out.append(Row(id: message.id, kind: .reply, message: message, header: lastSpeaker != "assistant"))
                lastSpeaker = "assistant"
            default:
                guard !message.id.isEmpty else { continue }
                group.append(message)
            }
        }
        flush(live: running)
        attachPlans(&out, running: running)
        for item in outgoing where !echoed.contains(item.requestID) {
            out.append(Row(id: "request:" + item.requestID, kind: .user,
                           message: .object(["id": .string("request:" + item.requestID), "role": .string("user"), "text": .string(item.text), "time": .number(item.createdAt)]),
                           outgoing: item))
        }
        return out
    }

    // MARK: todo 清单 → 时间轴

    /// 按轮（两句我的话之间）回放 Agent 记清单的工具调用；这一轮动过清单，就把清单快照挂到这一轮最后一段步骤上。
    /// 清单状态跨轮延续（Pi 的 todo 是整段会话一份），只在动过它的那一轮露出来。
    static func attachPlans(_ rows: inout [Row], running: Bool) {
        var board = PlanBoard()
        var turnStart = 0
        func close(_ end: Int, last: Bool) {
            guard end > turnStart else { return }
            var touched = false, tools: [WorkGroup] = []
            for index in turnStart..<end where rows[index].kind == .steps {
                for step in rows[index].steps {
                    let name = step["title"].string.components(separatedBy: " · ").first ?? ""
                    if board.apply(name, step["text"].string, at: step["time"].double) { touched = true; continue }
                    guard step["role"].string == "tool", name != "工具输出", !PlanBoard.isPlanTool(name), let kind = StepKind.of(name) else { continue }
                    let item = WorkStep(id: step.id, tool: name, kind: kind, status: "done", startedAt: step["time"].double, finishedAt: step["time"].double)
                    if let tail = tools.last, tail.kind == kind { tools[tools.count - 1].steps.append(item) } else { tools.append(WorkGroup(kind: kind, steps: [item])) }
                }
            }
            guard touched, !board.items.isEmpty, let target = (turnStart..<end).last(where: { rows[$0].kind == .steps }) else { return }
            let live = last && running
            if live, let tail = tools.last, var step = tail.steps.last {
                step = WorkStep(id: step.id, tool: step.tool, kind: step.kind, status: "running", startedAt: step.startedAt, finishedAt: 0)
                tools[tools.count - 1].steps[tail.steps.count - 1] = step
            }
            rows[target].plan = board.plan(live: live)
            rows[target].planLive = live
            rows[target].planTools = tools
        }
        for index in rows.indices where rows[index].kind == .user {
            close(index, last: false)
            turnStart = index + 1
        }
        close(rows.count, last: true)
    }

    /// 回放清单工具调用的小状态机。认得三家的写法：
    /// Pi `todo` {action: add/start/complete/clear, id, text, activeForm}；Claude `mcp__todo-card__plan` {todos | updates} 与 `TodoWrite` {todos}；Codex `update_plan` {plan:[{step,status}]}。
    struct PlanBoard {
        struct Item { var id: String; var text: String; var active: String; var status: String; var added: Double; var startedAt = 0.0; var doneAt = 0.0 }
        var items: [Item] = []

        static func status(_ raw: String) -> String {
            ["completed": "done", "complete": "done", "done": "done", "in_progress": "doing", "doing": "doing", "blocked": "blocked", "skipped": "skipped"][raw] ?? "todo"
        }

        static func isPlanTool(_ tool: String) -> Bool {
            ["todo", "TodoWrite", "update_plan"].contains(tool) || (tool.contains("todo-card") && tool.hasSuffix("__plan"))
        }

        /// 是清单调用就吃下并返回 true（同名工具的输出行解析不出参数，返回 false）。
        mutating func apply(_ tool: String, _ arguments: String, at time: Double) -> Bool {
            guard Self.isPlanTool(tool), let data = arguments.data(using: .utf8), let args = try? JSON.decode(data), !args.object.isEmpty else { return false }
            let short = tool.split(separator: "__").last.map(String.init) ?? tool
            if short == "todo" {
                let id = args["id"].string
                switch args["action"].string {
                case "add":
                    let next = (items.compactMap { Int($0.id) }.max() ?? 0) + 1
                    items.append(Item(id: String(next), text: args["text"].string, active: args["activeForm"].string, status: "todo", added: time))
                case "start": set(id, "doing", at: time)
                case "complete": set(id, "done", at: time)
                case "clear": items = []
                case "list": break
                default: return false
                }
            } else if short == "update_plan" {
                let plan = args["plan"].array
                guard !plan.isEmpty else { return false }
                replace(plan.enumerated().map { index, p in (String(index + 1), p["step"].string, "", Self.status(p["status"].string)) }, at: time)
            } else if !args["todos"].array.isEmpty {
                replace(args["todos"].array.enumerated().map { index, t in
                    (t["id"].isNull ? String(index + 1) : t["id"].string, t["content"].string, t["activeForm"].string, Self.status(t["status"].string))
                }, at: time)
            } else if !args["updates"].array.isEmpty {
                for update in args["updates"].array { set(update["id"].string, Self.status(update["status"].string), at: time) }
            } else { return false }
            return true
        }

        private mutating func set(_ id: String, _ status: String, at time: Double) {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            mark(index, status, at: time)
        }

        /// 整张清单重写（Claude / Codex 的写法）：同一句话的条目保留它原来的起止时间。
        private mutating func replace(_ list: [(String, String, String, String)], at time: Double) {
            let old = items
            items = list.map { id, text, active, status in
                var item = old.first { $0.text == text } ?? Item(id: id, text: text, active: active, status: "todo", added: time)
                item.id = id; item.active = active
                return item
            }
            for (index, entry) in list.enumerated() { mark(index, entry.3, at: time) }
        }

        private mutating func mark(_ index: Int, _ status: String, at time: Double) {
            let before = items[index].status
            items[index].status = status
            if status == "doing" && before != "doing" { items[index].startedAt = time }
            if status == "done" && before != "done" {
                // Pi 常常不报 start：从上一步做完（或加进清单）算起
                if items[index].startedAt == 0 { items[index].startedAt = max(items[index].added, items.filter { $0.doneAt > 0 }.map(\.doneAt).max() ?? 0) }
                items[index].doneAt = time
            }
        }

        /// 当前快照。在跑但谁也没标「进行中」时，把下一条没做的当成进行中（Pi 不报 start 时也有动画）。
        func plan(live: Bool) -> TurnPlan {
            var list = items
            if live, !list.contains(where: { $0.status == "doing" }), let next = list.firstIndex(where: { $0.status == "todo" }) {
                list[next].status = "doing"
                list[next].startedAt = max(list[next].added, list.filter { $0.doneAt > 0 }.map(\.doneAt).max() ?? 0)
            }
            let steps = list.map { TodoStep(id: $0.id, text: $0.text, status: $0.status, startedAt: $0.startedAt, doneAt: $0.doneAt) }
            let active = list.first { $0.status == "doing" }.map { $0.active.isEmpty ? $0.text : $0.active } ?? ""
            return TurnPlan(title: "", steps: steps, active: active)
        }
    }
}

#if DEBUG
extension WorkSessionModel {
    /// 验收：没有服务器时模拟回执和一段流式回复（`--ui-testing`）。
    private func simulateDelivery(_ id: String, _ model: AppModel) async -> JSON? {
        try? await Task.sleep(for: .milliseconds(650))
        guard let entry = model.pending.first(where: { $0.id == id }) else { return nil }
        if entry.path == "/sessions" {
            let sid = "r3-new-" + String(id.prefix(6))
            Task { [weak self] in await self?.simulateReply(for: entry.text, sid: sid, request: id, model) }
            return .object(["status": .string("accepted"), "sid": .string(sid)])
        }
        if entry.path.hasSuffix("/resume") { return .object(["status": .string("accepted"), "sid": .string(sessionID)]) }
        let sid = sessionID
        Task { [weak self] in await self?.simulateReply(for: entry.text, sid: sid, request: id, model) }
        return .object(["status": .string("accepted")])
    }
    /// 回声先到，接着两步工具，最后回复一段段流出来。同一份也写进 datasets，3 秒一次的轮询读到的是同一个状态。
    private func simulateReply(for text: String, sid: String, request: String, _ model: AppModel) async {
        try? await Task.sleep(for: .milliseconds(500))
        guard sessionID == sid || sessionID.isEmpty else { return }
        if metadata["capabilities"].isNull { metadata["capabilities"] = .object(["input": .bool(true), "resume": .bool(false)]) }
        let path = "/sessions/" + sid.pathEncoded
        if model.datasets[path] == nil { model.datasets[path] = .object(["session": metadata, "messages": .array(history)]) }
        var base = (model.datasets[path + "/live"] ?? .null)["items"].array
        func publish(_ items: [JSON], status: String) {
            let value = JSON.object(["status": .string(status), "items": .array(items), "approvals": .array([])])
            model.datasets[path + "/live"] = value
            if sessionID == sid { live = value }
        }
        base.append(.object(["id": .string("echo-" + request), "role": .string("user"), "text": .string(text), "request_id": .string(request), "time": .number(Date().timeIntervalSince1970)]))
        publish(base, status: "running")
        var tools = [("rg", "rg -n \"选题\" work/内容生产"), ("read_file", "work/内容生产/选题管理/README.md")]
        // `--ui-work-plan`：Pi 式 todo 清单，验收工作页的时间轴（每步停久一点，方便截帧看动画）
        let planned = ProcessInfo.processInfo.arguments.contains("--ui-work-plan")
        if planned {
            tools = [("todo", #"{"action":"add","text":"盘点本周选题","activeForm":"盘点本周选题"}"#),
                     ("todo", #"{"action":"add","text":"核对每个选题的素材","activeForm":"核对素材"}"#),
                     ("todo", #"{"action":"add","text":"整理成一句话清单","activeForm":"整理清单"}"#),
                     ("todo", #"{"action":"start","id":1}"#), ("rg", "rg -n \"选题\" work/内容生产"),
                     ("todo", #"{"action":"complete","id":1}"#), ("todo", #"{"action":"start","id":2}"#),
                     ("read_file", "work/内容生产/选题管理/README.md"), ("ls", "ls work/内容生产/素材"),
                     ("todo", #"{"action":"complete","id":2}"#), ("todo", #"{"action":"start","id":3}"#)]
        }
        for (index, tool) in tools.enumerated() {
            try? await Task.sleep(for: .milliseconds(planned && tool.0 != "todo" ? 6000 : 700))
            base.append(.object(["id": .string("tool-\(request)-\(index)"), "role": .string("tool"), "title": .string(tool.0), "text": .string(tool.1), "time": .number(Date().timeIntervalSince1970)]))
            publish(base, status: "running")
        }
        if planned {
            try? await Task.sleep(for: .milliseconds(6000))
            base.append(.object(["id": .string("tool-\(request)-done"), "role": .string("tool"), "title": .string("todo"), "text": .string(#"{"action":"complete","id":3}"#), "time": .number(Date().timeIntervalSince1970)]))
            publish(base, status: "running")
        }
        let reply = "看完了。本周的选题一共 **3 个**，素材都已经在对应目录里：\n\n- **岩馆探馆**：素材齐了，差一段开场口播\n- **AI 调色**：还缺两段对比镜头\n- **川西摩旅**：可以直接剪\n\n要我先把探馆那支的口播稿写出来吗？"
        var shown = ""
        for chunk in reply.chunked(by: 9) {
            try? await Task.sleep(for: .milliseconds(90))
            shown += chunk
            publish(base + [.object(["id": .string("reply-" + request), "role": .string("assistant"), "text": .string(shown), "time": .number(Date().timeIntervalSince1970)])], status: "running")
        }
        publish(base + [.object(["id": .string("reply-" + request), "role": .string("assistant"), "text": .string(shown), "time": .number(Date().timeIntervalSince1970)])], status: "completed")
    }
}

private extension String {
    func chunked(by size: Int) -> [String] {
        var out: [String] = [], current = ""
        for character in self { current.append(character); if current.count == size { out.append(current); current = "" } }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
#endif
