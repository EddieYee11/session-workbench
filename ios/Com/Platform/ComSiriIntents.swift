import AppIntents
import Intents
import Foundation
import ComCore

// MARK: - Siri & 快捷指令统一后端客户端（后台直连 Mac mini，无需打开 App）

enum ComIntentClient {
    static func api() throws -> APIClient {
        guard let key = SecureVault.secret("token"),
              let token = String(data: key, encoding: .utf8),
              !token.isEmpty else {
            throw APIError(status: 401, detail: "Com 还没配对 Mac mini，请先打开 Com 完成配对。")
        }
        let base = UserDefaults.standard.string(forKey: "base") ?? "https://pi.eddiegao.work:8443/sessions"
        return try APIClient(base: base, token: token)
    }

    /// 向 Com 主会话发送文字消息（与在 Com 聊天框点发送完全同路：自动保存聊天记录、触发快通道记账或交由 Hermes 处理），
    /// 并轮询回执最多 timeoutSeconds 秒，拿到真实回复直接回传给 Siri 朗读。
    static func sendMessageAndWait(text: String, timeoutSeconds: Double = 12.0) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "消息内容为空，没有发送。"
        }
        let client = try api()
        let requestID = "siri-" + UUID().uuidString.lowercased()
        let response = try await client.request(
            "/personal/conversation/messages",
            body: .object([
                "request_id": .string(requestID),
                "content": .string(trimmed),
                "text": .string(trimmed),
                "wait": .bool(true),
                "timeout": .number(timeoutSeconds)
            ])
        )
        let directReply = response["reply"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directReply.isEmpty {
            return directReply
        }
        let messageID = response["message_id"].string

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if let receipt = try? await client.request("/personal/conversation/receipts/" + requestID.pathEncoded) {
                let status = receipt["status"].string
                let reply = receipt["reply"].string.trimmingCharacters(in: .whitespacesAndNewlines)
                let err = receipt["error"].string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty && (status == "completed" || status == "unknown" || status == "approval_required") {
                    return reply
                }
                if status == "failed" {
                    return err.isEmpty ? "Com 处理失败，请打开 Com 查看详情。" : "Com 处理失败：\(err)"
                }
                if status == "completed", !messageID.isEmpty {
                    break
                }
            }
        }

        // 若 receipt 尚未带 reply（或刚完成），兜底从会话快照里按 parent_id 取最新一条 assistant 回复
        if !messageID.isEmpty,
           let convo = try? await client.request("/personal/conversation") {
            let messages = convo["messages"].array
            if let assistant = messages.last(where: { $0["parent_id"].string == messageID && $0["role"].string == "assistant" }) {
                let reply = assistant["text"].string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty { return reply }
            }
        }
        return "已发送给 Com（\(trimmed)），正在后台处理，完成后会推送通知给你。"
    }
}

// MARK: - 1. 给 Com 发文字消息（万能入口：聊天、交办、设提醒、加日程、记账全走主对话）

struct SendComMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "给 Com 发消息"
    static let description = IntentDescription("无需打开 App，直接通过 Siri 或快捷指令给 Com 发送文字消息（记账、设提醒、查日程、交办任务），并朗读 Com 的回复。")
    static let openAppWhenRun = false

    @Parameter(
        title: "消息内容",
        description: "要发给 Com 的话，例如：午饭花了35、明天早上9点提醒我开周会",
        requestValueDialog: IntentDialog("你要跟 Com 说什么？")
    )
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("给 Com 发消息：\(\.$text)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let reply = try await ComIntentClient.sendMessageAndWait(text: text)
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

// MARK: - 2. 用 Com 记账（无感发文字进 Com 主会话，由 Com 快通道/Hermes 记账并留痕）

struct BookComExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "用 Com 记账"
    static let description = IntentDescription("直接跟 Siri 说花销或收入，通过 Com 发送记账文字并自动写入统一账本（支持单笔快通道与多笔/复杂花销），无需打开 App。")
    static let openAppWhenRun = false

    @Parameter(
        title: "记账内容",
        description: "例如：午饭 35、打车花了 28、发红包 88+88+52",
        requestValueDialog: IntentDialog("这笔账花了多少、是什么用途？")
    )
    var expenseText: String

    static var parameterSummary: some ParameterSummary {
        Summary("用 Com 记账：\(\.$expenseText)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let raw = expenseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            let msg = "还没说记账内容。"
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
        let triggerWords = ["记账", "记一笔", "记一下", "记下", "记录", "花了", "花的", "花费", "消费", "支出", "用了", "付了", "到账", "收入", "收到", "报销"]
        let hasTrigger = triggerWords.contains { raw.contains($0) }
        let normalized = hasTrigger ? raw : "记账 " + raw
        let reply = try await ComIntentClient.sendMessageAndWait(text: normalized)
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

// MARK: - 3. 查 Com 下一步建议（/personal/next）

struct QueryComNextIntent: AppIntent {
    static let title: LocalizedStringResource = "问 Com 下一步做什么"
    static let description = IntentDescription("读取 Com 归纳的「下一步」简报与当前最值得做的事。")
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("问 Com 下一步做什么")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let client = try ComIntentClient.api()
        let data = try await client.request("/personal/next")
        let headline = data["headline"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = data["items"].array
        var parts: [String] = []
        if !headline.isEmpty {
            parts.append(headline)
        }
        let top = items.prefix(3).compactMap { item -> String? in
            let title = item["title"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let urgency = item["urgency"].string == "now" ? "【现在】" : ""
            return "\(urgency)\(title)"
        }
        if !top.isEmpty {
            parts.append("建议推进：" + top.joined(separator: "；"))
        }
        let summary = parts.isEmpty ? "当前没有紧急的下一步建议。" : parts.joined(separator: "\n")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - 4. 查 Com 今日日程、提醒与待办（/personal/today）

struct QueryComTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "查 Com 今日日程与待办"
    static let description = IntentDescription("查看 Com 里今天的日历行程、系统提醒和待办事项。")
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("查 Com 今日日程与待办")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let client = try ComIntentClient.api()
        let data = try await client.request("/personal/today")
        let events = data["events"].array
        let reminders = data["reminders"].array.filter { $0["status"].string != "completed" }
        let todos = data["todos"].array

        var lines: [String] = []
        if !events.isEmpty {
            let titles = events.prefix(4).map { $0["title"].string }.filter { !$0.isEmpty }
            lines.append("今日日程 \(events.count) 项：" + titles.joined(separator: "、"))
        } else {
            lines.append("今天没有日历行程")
        }
        if !reminders.isEmpty {
            let titles = reminders.prefix(4).map { $0["title"].string }.filter { !$0.isEmpty }
            lines.append("待办提醒 \(reminders.count) 项：" + titles.joined(separator: "、"))
        }
        if !todos.isEmpty {
            let titles = todos.prefix(3).map { $0["title"].string }.filter { !$0.isEmpty }
            lines.append("行动台待办 \(todos.count) 项：" + titles.joined(separator: "、"))
        }
        let summary = lines.joined(separator: "；") + "。"
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - 5. 查 Com 账本今日与本月花销（/personal/finance）

struct QueryComFinanceIntent: AppIntent {
    static let title: LocalizedStringResource = "查 Com 账本开销"
    static let description = IntentDescription("查询 Com 账本里今天和本月的累计支出与最近消费。")
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("查 Com 账本开销")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let client = try ComIntentClient.api()
        let data = try await client.request("/personal/finance")
        guard data["available"].bool else {
            let msg = data["note"].string.isEmpty ? "暂时读不到账本数据。" : data["note"].string
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
        let items = data["items"].array
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let todayStr = f.string(from: Date())

        let cnyItems = items.filter { $0["currency"].string == "CNY" || $0["currency"].string.isEmpty }
        let monthTotal = cnyItems.reduce(0.0) { $0 + $1["amount_minor"].double } / 100.0
        let todayItems = cnyItems.filter { $0["date"].string == todayStr }
        let todayTotal = todayItems.reduce(0.0) { $0 + $1["amount_minor"].double } / 100.0

        let monthStr = String(format: "%.2f", monthTotal)
        let todayAmountStr = String(format: "%.2f", todayTotal)
        var summary = "今日支出 ¥\(todayAmountStr)（\(todayItems.count) 笔），本月累计支出 ¥\(monthStr)（\(cnyItems.count) 笔）。"
        if let latest = cnyItems.first {
            let amt = String(format: "%.2f", latest["amount_minor"].double / 100.0)
            let cat = latest["category"].string
            let comment = latest["comment"].string
            let detail = comment.isEmpty ? cat : "\(cat)·\(comment)"
            summary += "最近一笔：\(detail) ¥\(amt)。"
        }
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - 6. 查 Com 等我拍板的事（/personal/waiting）

struct QueryComWaitingIntent: AppIntent {
    static let title: LocalizedStringResource = "查 Com 等我拍板的事"
    static let description = IntentDescription("查看 Com「等你」收件箱里有哪些待审批、待回复或过期待办。")
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("查 Com 等我拍板的事")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let client = try ComIntentClient.api()
        let data = try await client.request("/personal/waiting")
        let items = data["items"].array
        guard !items.isEmpty else {
            let msg = "目前没有等你拍板或确认的事项。"
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
        let titles = items.prefix(4).map { $0["title"].string }.filter { !$0.isEmpty }
        let msg = "共有 \(items.count) 件事等你拍板：" + titles.joined(separator: "；") + "。"
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: - 7. 查 Com 身体电量与恢复评估（/personal/health/insight）

struct QueryComHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "查 Com 身体电量与恢复状态"
    static let description = IntentDescription("读取 Com 里的 Garmin 恢复评分、睡眠与今日身体状态评估。")
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("查 Com 身体电量与恢复状态")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let client = try ComIntentClient.api()
        let insight = try await client.request("/personal/health/insight")
        let score = insight["score"].int
        let headline = insight["headline"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryText = insight["summary"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if score > 0 { parts.append("今日恢复分 \(score) 分") }
        if !headline.isEmpty { parts.append(headline) }
        if !summaryText.isEmpty { parts.append(summaryText) }
        let result = parts.isEmpty ? "暂时还没有今天的健康评估数据。" : parts.joined(separator: "。")
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

// MARK: - 8. 在 Com 新建行动台待办（POST /personal/matters/from_step）

struct CreateComTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "在 Com 新建待办事项"
    static let description = IntentDescription("直接向 Com 行动台添加一张待办事项卡。")
    static let openAppWhenRun = false

    @Parameter(
        title: "待办标题",
        description: "例如：跑完回测上传策略、交八月打车报销",
        requestValueDialog: IntentDialog("你要在 Com 里记下什么待办？")
    )
    var titleText: String

    static var parameterSummary: some ParameterSummary {
        Summary("在 Com 新建待办：\(\.$titleText)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let msg = "待办标题为空，未创建。"
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
        let client = try ComIntentClient.api()
        _ = try await client.request(
            "/personal/matters/from_step",
            body: .object([
                "title": .string(trimmed),
                "source": .string("siri")
            ])
        )
        let msg = "已在 Com 行动台添加待办：\(trimmed)"
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: - 9. 用 Com 给电脑派活（POST /sessions 启动 Pi / Claude / Codex 会话）

enum ComAgentKind: String, AppEnum {
    case pi, claude, codex
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent 类型"
    static let caseDisplayRepresentations: [ComAgentKind: DisplayRepresentation] = [
        .pi: "Pi (主力快速任务)",
        .claude: "Claude Code",
        .codex: "Codex"
    ]
}

struct DispatchComSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "用 Com 给电脑派活"
    static let description = IntentDescription("后台在 Mac mini 上启动一个新的 Agent 工作会话（Pi / Claude / Codex）执行你交办的任务。")
    static let openAppWhenRun = false

    @Parameter(title: "Agent", default: .pi)
    var agent: ComAgentKind

    @Parameter(
        title: "任务指令",
        description: "要让电脑 Agent 执行的具体任务",
        requestValueDialog: IntentDialog("你要让电脑上的 Agent 做什么任务？")
    )
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("用 Com 让 \(\.$agent) 执行：\(\.$prompt)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let msg = "任务指令为空，未派发。"
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
        let client = try ComIntentClient.api()
        let reqID = "siri-session-" + UUID().uuidString.lowercased()
        let res = try await client.request(
            "/sessions",
            body: .object([
                "agent": .string(agent.rawValue),
                "cwd": .string("/Users/eddiegao/AI_Work_System"),
                "text": .string(trimmed),
                "request_id": .string(reqID)
            ])
        )
        let sid = res["id"].string
        let msg = sid.isEmpty
            ? "已派发给 \(agent.rawValue) 执行：\(trimmed)"
            : "已在电脑启动 \(agent.rawValue) 会话（\(sid.prefix(8))）：\(trimmed)"
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: - 10. 在 Com 批准或拒绝当前待确认操作（POST /approvals/{id}）

enum ComApprovalDecisionKind: String, AppEnum {
    case approve = "accept"
    case deny = "decline"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "审批决定"
    static let caseDisplayRepresentations: [ComApprovalDecisionKind: DisplayRepresentation] = [
        .approve: "批准",
        .deny: "拒绝"
    ]
}

struct DecideComApprovalIntent: AppIntent {
    static let title: LocalizedStringResource = "在 Com 批准或拒绝最新审批"
    static let description = IntentDescription("对 Com 里当前等待确认的最新一项 Agent 审批直接做出批准或拒绝决定。")
    static let openAppWhenRun = false

    @Parameter(title: "决定", default: .approve)
    var decision: ComApprovalDecisionKind

    static var parameterSummary: some ParameterSummary {
        Summary("在 Com \(\.$decision)最新审批")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let client = try ComIntentClient.api()
        let status = try await client.request("/status")
        let sessions = status["sessions"].array
        var pendingID = ""
        var pendingReason = ""
        for session in sessions {
            if let first = session["approvals"].array.first, !first.id.isEmpty {
                pendingID = first.id
                pendingReason = first["params"]["reason"].string
                break
            }
        }
        guard !pendingID.isEmpty else {
            let msg = "当前没有等待审批的 Agent 操作。"
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
        _ = try await client.request(
            "/approvals/" + pendingID.pathEncoded,
            body: .object(["decision": .string(decision.rawValue)])
        )
        let verb = decision == .approve ? "已批准" : "已拒绝"
        let msg = pendingReason.isEmpty ? "\(verb)操作（\(pendingID.prefix(8))）。" : "\(verb)：\(pendingReason)"
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: - 11. 停止 Com 当前正在运行的回复（POST /personal/conversation/interrupt）

struct InterruptComIntent: AppIntent {
    static let title: LocalizedStringResource = "停止 Com 当前运行"
    static let description = IntentDescription("中断 Com 主会话当前正在运行的任务或生成。")
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("停止 Com 当前运行")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let client = try ComIntentClient.api()
        _ = try await client.request("/personal/conversation/interrupt", body: .object([:]))
        return .result(dialog: "已通知 Com 停止当前运行。")
    }
}

// MARK: - 12. 打开 Com 指定页面或功能面板（openAppWhenRun = true）

enum ComPageDestination: String, AppEnum {
    case chat, next, today, health, work, finance, waiting, memory, activity, voice
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Com 页面"
    static let caseDisplayRepresentations: [ComPageDestination: DisplayRepresentation] = [
        .chat: "主对话",
        .next: "下一步",
        .today: "今天 (日程与待办)",
        .health: "健康",
        .work: "工作台 (Agent 会话)",
        .finance: "账本明细",
        .waiting: "等你拍板",
        .memory: "记忆库",
        .activity: "动态与航程",
        .voice: "语音速记小窗"
    ]
}

struct OpenComPageIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Com 指定页面"
    static let description = IntentDescription("打开 Com 并直接跳到指定页面（对话、下一步、今天、健康、工作、账本、等你、记忆、动态、语音小窗）。")
    static let openAppWhenRun = true

    @Parameter(title: "页面", default: .chat)
    var page: ComPageDestination

    static var parameterSummary: some ParameterSummary {
        Summary("打开 Com 的\(\.$page)")
    }

    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(page.rawValue, forKey: "openPageIntent")
        NotificationCenter.default.post(name: .comOpenPageIntent, object: page.rawValue)
        return .result()
    }
}

extension Notification.Name {
    static let comOpenPageIntent = Notification.Name("com.open.page.intent")
}

// MARK: - SiriKit 原生系统域处理器（解决 Siri 说「App Com 不支援此动作」：拦截发消息/记笔记/加待办/查账单全部转进 Com 后台）

final class ComSiriKitHandler: NSObject,
    INSendMessageIntentHandling,
    INCreateNoteIntentHandling,
    INAppendToNoteIntentHandling,
    INAddTasksIntentHandling,
    INSearchForNotebookItemsIntentHandling,
    INSearchForMessagesIntentHandling,
    INSearchForBillsIntentHandling,
    INSearchForAccountsIntentHandling,
    @unchecked Sendable
{
    static let shared = ComSiriKitHandler()

    // 1) 「给 Com 发消息 [任意内容]」/「跟 Com 说 [任意内容]」/「Tell Com [anything]」
    func resolveRecipients(for intent: INSendMessageIntent, with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void) {
        let person = INPerson(
            personHandle: INPersonHandle(value: "com", type: .unknown),
            nameComponents: nil,
            displayName: "Com",
            image: nil,
            contactIdentifier: nil,
            customIdentifier: "com"
        )
        completion([.success(with: person)])
    }

    func resolveContent(for intent: INSendMessageIntent, with completion: @escaping (INStringResolutionResult) -> Void) {
        if let content = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            completion(.success(with: content))
        } else {
            completion(.needsValue())
        }
    }

    func handle(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        let text = (intent.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        nonisolated(unsafe) let done = completion
        Task {
            let reply = (try? await ComIntentClient.sendMessageAndWait(text: text)) ?? "已发给 Com。"
            let response = INSendMessageIntentResponse(code: .success, userActivity: nil)
            let sender = INPerson(personHandle: INPersonHandle(value: "com", type: .unknown), nameComponents: nil, displayName: "Com", image: nil, contactIdentifier: nil, customIdentifier: "com")
            response.sentMessages = [
                INMessage(identifier: UUID().uuidString, conversationIdentifier: "personal-main", content: reply, dateSent: Date(), sender: sender, recipients: nil, groupName: nil, messageType: .text)
            ]
            done(response)
        }
    }

    // 2) 「在 Com 记一笔 [内容]」/「用 Com 记录 [内容]」/「Create a note in Com」
    func resolveContent(for intent: INCreateNoteIntent, with completion: @escaping (INNoteContentResolutionResult) -> Void) {
        if let content = intent.content {
            completion(.success(with: content))
        } else if let title = intent.title?.spokenPhrase, !title.isEmpty {
            completion(.success(with: INTextNoteContent(text: title)))
        } else {
            completion(.needsValue())
        }
    }

    func handle(intent: INCreateNoteIntent, completion: @escaping (INCreateNoteIntentResponse) -> Void) {
        let titleText = intent.title?.spokenPhrase ?? ""
        let bodyText = (intent.content as? INTextNoteContent)?.text ?? ""
        let combined = [titleText, bodyText].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        let payload = combined.isEmpty ? "记账" : (combined.range(of: #"\d"#, options: .regularExpression) != nil && !combined.contains("记") ? "记账 " + combined : combined)
        nonisolated(unsafe) let done = completion
        Task {
            let reply = (try? await ComIntentClient.sendMessageAndWait(text: payload)) ?? "已记录到 Com。"
            let response = INCreateNoteIntentResponse(code: .success, userActivity: nil)
            response.createdNote = INNote(
                title: INSpeakableString(spokenPhrase: reply),
                contents: [INTextNoteContent(text: reply)],
                groupName: nil,
                createdDateComponents: nil,
                modifiedDateComponents: nil,
                identifier: UUID().uuidString
            )
            done(response)
        }
    }

    func handle(intent: INAppendToNoteIntent, completion: @escaping (INAppendToNoteIntentResponse) -> Void) {
        let bodyText = (intent.content as? INTextNoteContent)?.text ?? ""
        nonisolated(unsafe) let done = completion
        Task {
            let reply = (try? await ComIntentClient.sendMessageAndWait(text: bodyText)) ?? "已追加到 Com。"
            let response = INAppendToNoteIntentResponse(code: .success, userActivity: nil)
            response.note = INNote(
                title: INSpeakableString(spokenPhrase: reply),
                contents: [INTextNoteContent(text: reply)],
                groupName: nil,
                createdDateComponents: nil,
                modifiedDateComponents: nil,
                identifier: UUID().uuidString
            )
            done(response)
        }
    }

    // 3) 「在 Com 加个待办 [内容]」/「用 Com 提醒我 [内容]」
    func handle(intent: INAddTasksIntent, completion: @escaping (INAddTasksIntentResponse) -> Void) {
        let titles = (intent.taskTitles ?? []).map(\.spokenPhrase).filter { !$0.isEmpty }
        let joined = titles.joined(separator: "、")
        nonisolated(unsafe) let done = completion
        Task {
            if !joined.isEmpty {
                _ = try? await ComIntentClient.sendMessageAndWait(text: joined)
            }
            let response = INAddTasksIntentResponse(code: .success, userActivity: nil)
            response.addedTasks = titles.map {
                INTask(title: INSpeakableString(spokenPhrase: $0), status: .notCompleted, taskType: .notCompletable, spatialEventTrigger: nil, temporalEventTrigger: nil, createdDateComponents: nil, modifiedDateComponents: nil, identifier: UUID().uuidString)
            }
            done(response)
        }
    }

    // 4) 「查看 Com 今日待办 / 笔记」
    func handle(intent: INSearchForNotebookItemsIntent, completion: @escaping (INSearchForNotebookItemsIntentResponse) -> Void) {
        nonisolated(unsafe) let done = completion
        Task {
            let summary = (try? await QueryComTodayIntent().perform().value) ?? "已读取 Com 今日安排。"
            let response = INSearchForNotebookItemsIntentResponse(code: .success, userActivity: nil)
            response.notes = [
                INNote(title: INSpeakableString(spokenPhrase: summary), contents: [INTextNoteContent(text: summary)], groupName: nil, createdDateComponents: nil, modifiedDateComponents: nil, identifier: UUID().uuidString)
            ]
            done(response)
        }
    }

    // 5) 「查看 Com 消息」
    func handle(intent: INSearchForMessagesIntent, completion: @escaping (INSearchForMessagesIntentResponse) -> Void) {
        nonisolated(unsafe) let done = completion
        Task {
            let summary = (try? await QueryComNextIntent().perform().value) ?? "已读取 Com 最新动态。"
            let response = INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
            let sender = INPerson(personHandle: INPersonHandle(value: "com", type: .unknown), nameComponents: nil, displayName: "Com", image: nil, contactIdentifier: nil, customIdentifier: "com")
            response.messages = [
                INMessage(identifier: UUID().uuidString, conversationIdentifier: "personal-main", content: summary, dateSent: Date(), sender: sender, recipients: nil, groupName: nil, messageType: .text)
            ]
            done(response)
        }
    }

    // 6) 「用 Com 查开销 / 查账单 / 查账户」
    func handle(intent: INSearchForBillsIntent, completion: @escaping (INSearchForBillsIntentResponse) -> Void) {
        nonisolated(unsafe) let done = completion
        Task {
            _ = try? await QueryComFinanceIntent().perform()
            let response = INSearchForBillsIntentResponse(code: .success, userActivity: nil)
            response.bills = []
            done(response)
        }
    }

    func handle(intent: INSearchForAccountsIntent, completion: @escaping (INSearchForAccountsIntentResponse) -> Void) {
        nonisolated(unsafe) let done = completion
        Task {
            let summary = (try? await QueryComFinanceIntent().perform().value) ?? "已读取 Com 账本。"
            let response = INSearchForAccountsIntentResponse(code: .success, userActivity: nil)
            response.accounts = [
                INPaymentAccount(nickname: INSpeakableString(spokenPhrase: summary), number: nil, accountType: .checking, organizationName: INSpeakableString(spokenPhrase: "Com 账本"), balance: nil, secondaryBalance: nil)
            ]
            done(response)
        }
    }
}
