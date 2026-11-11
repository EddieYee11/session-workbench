import SwiftUI
import AVFoundation
import CryptoKit
import UIKit
import ComCore

// 聊天轨道（chat）：顶栏气泡、频道切换、跨页吸附胶囊、剪贴板投递、Live 工具胶囊与边干边报语音。

@MainActor
final class ComVoiceNarrator: NSObject {
    static let shared = ComVoiceNarrator()
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenMessageID: String = ""

    private override init() {
        super.init()
    }

    func speak(_ rawText: String, messageID: String = "") {
        if !messageID.isEmpty, messageID == lastSpokenMessageID { return }
        let cleaned = Self.cleanSpeechText(rawText)
        guard !cleaned.isEmpty else { return }
        if !messageID.isEmpty { lastSpokenMessageID = messageID }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true, options: [])

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.02
        utterance.volume = 0.9
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private static func cleanSpeechText(_ text: String) -> String {
        var out = text
        // Strip Markdown links [label](url) -> label, bare URLs, headings, bold/code markers
        out = out.replacingOccurrences(of: #"\[\[选项:[^\]]*\]\]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[#*`>_~]+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > 110 {
            let prefix = String(out.prefix(100))
            return prefix + "。详情请看屏幕。"
        }
        return out
    }
}

extension AppModel {
    /// 正在跑的那条用户消息的工作过程（没有就是 nil）。
    var liveProcess: WorkProcess? {
        conversation.messages.last { $0["role"].string == "user" && WorkProcess.activeStatuses.contains($0["status"].string) }
            .flatMap(WorkProcess.from)
    }
    /// 顶栏人物旁手绘气泡里的字；空字符串 = 空闲，气泡收起。
    var workBubble: String {
        if let runningChip = activeLiveToolChips.last(where: { $0.status == "running" }) {
            return runningChip.title
        }
        if let process = liveProcess { return process.current }
        guard stage.state.isBusy else { return "" }
        return stripCaption
    }

    /// 当前活跃轮次（或最近一条用户消息）对应的实时工具胶囊列表。
    var activeLiveToolChips: [LiveToolChip] {
        if let activeUser = conversation.messages.last(where: { $0["role"].string == "user" && WorkProcess.activeStatuses.contains($0["status"].string) }),
           let chips = liveToolChips[activeUser.id], !chips.isEmpty {
            return chips
        }
        if let recentUser = conversation.messages.last(where: { $0["role"].string == "user" }),
           let chips = liveToolChips[recentUser.id], !chips.isEmpty {
            let age = Date().timeIntervalSince1970 - recentUser["created_at"].double
            if age < 90 || chips.contains(where: { $0.status == "running" }) {
                return chips
            }
        }
        if let fallback = liveToolChips["active"], !fallback.isEmpty {
            return fallback
        }
        return []
    }

    // MARK: - 与 @ios-surfaces 对齐的精确共享方法契约

    /// 切换对话频道（personal | work | bookkeeping），异步同步后端并刷新对应频道会话快照。
    func switchChannel(_ channel: String) {
        let raw = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = ["personal", "work", "bookkeeping"].contains(raw) ? raw : "personal"
        let changed = (activeChannel != normalized)
        activeChannel = normalized
        UserDefaults.standard.set(normalized, forKey: "chat.activeChannel")
        if changed { Haptics.selection() }
        Task { @MainActor in
            await performSwitchChannel(normalized)
        }
    }

    private func performSwitchChannel(_ channel: String) async {
        #if DEBUG
        if isUITesting { return }
        #endif
        guard let api = client else { return }
        _ = try? await api.request("/personal/channels/select", body: .object(["channel": .string(channel)]))
        let path = "/personal/conversation?channel=" + channel.queryEncoded
        guard let data = try? await api.request(path) else { return }
        guard activeChannel == channel else { return }
        conversation.replaceChannelSnapshot(data)
        reconcileLiveToolChips(with: conversation.messages)
        todayOpenNote = ""
        persistSoon()
    }

    /// 把卡片/日程/事项吸附到输入框上方上下文胶囊（双栏不切走右栏，绝不伪造假消息气泡）。
    func attachToChat(_ item: AttachedContextItem, switchIfCompact: Bool = true) {
        attachedContext = item
        Haptics.selection()
        if !splitView && switchIfCompact {
            tab = .chat
        }
    }

    /// 万能投递口 POST /personal/drop（auto_chat: true），清空剪贴板候选胶囊并刷新对话。
    func submitDrop(url: String? = nil, text: String? = nil, title: String? = nil) {
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanURL.isEmpty {
            rememberHandledClipboardURL(cleanURL)
        }
        clipboardDropCandidate = nil
        Haptics.selection()
        Task { @MainActor in
            await performSubmitDrop(url: cleanURL, text: cleanText, title: cleanTitle)
        }
    }

    @discardableResult
    func performSubmitDrop(url: String, text: String, title: String) async -> Bool {
        guard !url.isEmpty || !text.isEmpty else { return false }
        #if DEBUG
        if isUITesting {
            let preview = !url.isEmpty ? "已收到链接：\(url)" : "已收到投递：\(text)"
            conversation.messages.append(.object([
                "id": .string("drop-" + UUID().uuidString.lowercased()),
                "role": .string("assistant"),
                "text": .string(preview),
                "status": .string("completed"),
                "created_at": .number(Date().timeIntervalSince1970)
            ]))
            conversation.revision += 1
            return true
        }
        #endif
        guard let api = client else {
            chatComposerNote = "还没连上 mini——投递没发出去，先配对再试。"
            banner = "请先连接 Mac mini"
            return false
        }
        var fields: [String: JSON] = [
            "auto_chat": .bool(true),
            "source": .string("ios_app"),
            "channel": .string(activeChannel)
        ]
        if !url.isEmpty { fields["url"] = .string(url) }
        if !text.isEmpty { fields["text"] = .string(text) }
        if !title.isEmpty { fields["title"] = .string(title) }
        do {
            _ = try await api.request("/personal/drop", body: .object(fields))
            chatComposerNote = ""
            Haptics.success()
            await refresh(.chat)
            return true
        } catch {
            chatComposerNote = "投递没送达：" + error.localizedDescription
            banner = chatComposerNote
            Haptics.error()
            return false
        }
    }

    // MARK: - SSE 游标记录、Live 工具胶囊与语音边干边报

    func recordSSECursor(_ rawID: String) {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastEventIDRaw = trimmed
        if let seq = Int(trimmed), seq > 0 {
            lastEventID = max(lastEventID, seq)
        }
    }

    func handleLiveToolEvent(name: String, value: JSON) {
        let rawTool = value["tool"].string.isEmpty ? value["name"].string : value["tool"].string
        let shortTool = rawTool.lowercased().split(separator: "__").last.map(String.init) ?? rawTool.lowercased()
        if ["send_message", "sendmessage", "think", "react_to_user_message"].contains(shortTool) {
            return
        }
        let messageID: String = {
            let explicit = value["message_id"].string
            if !explicit.isEmpty { return explicit }
            if let activeUser = conversation.messages.last(where: { $0["role"].string == "user" && WorkProcess.activeStatuses.contains($0["status"].string) }) {
                return activeUser.id
            }
            return "active"
        }()
        let chipID: String = {
            for key in ["tool_id", "call_id", "id"] {
                let v = value[key].string
                if !v.isEmpty { return v }
            }
            return "\(messageID)-\(shortTool.isEmpty ? "tool" : shortTool)"
        }()
        let status: String = {
            if name == "tool.started" { return "running" }
            if name == "tool.failed" || value["status"].string == "failed" || value["status"].string == "error" {
                return "failed"
            }
            return "completed"
        }()
        let durationMs: Int? = {
            guard status != "running" else { return nil }
            let direct = value["duration_ms"].int
            if direct > 0 { return direct }
            let started = value["started_at"].double
            let finished = value["finished_at"].double
            if started > 0 && finished >= started {
                return Int(((finished - started) * 1000).rounded())
            }
            return nil
        }()
        let title: String = {
            let rawTitle = value["title"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawTitle.isEmpty && !rawTitle.hasPrefix("正在使用 ") {
                return rawTitle
            }
            if let kind = StepKind.of(rawTool) {
                return status == "running" ? (kind.live.first ?? "处理中") : kind.done(1)
            }
            return rawTitle.isEmpty ? (shortTool.isEmpty ? "调用工具" : shortTool) : rawTitle
        }()

        var list = liveToolChips[messageID] ?? []
        let updated = LiveToolChip(
            id: chipID,
            tool: shortTool.isEmpty ? rawTool : shortTool,
            title: title,
            status: status,
            durationMs: durationMs
        )
        if let idx = list.firstIndex(where: { $0.id == chipID }) {
            list[idx] = updated
        } else if status != "running", let runIdx = list.lastIndex(where: { $0.tool == updated.tool && $0.status == "running" }) {
            list[runIdx] = LiveToolChip(
                id: list[runIdx].id,
                tool: updated.tool,
                title: title,
                status: status,
                durationMs: durationMs
            )
        } else {
            list.append(updated)
            if list.count > 12 { list = Array(list.suffix(12)) }
        }
        liveToolChips[messageID] = list

        if status == "running" {
            stage.receive("task.progress", .object(["kind": .string("working")]))
        }
    }

    func reconcileLiveToolChips(with messages: [JSON]) {
        guard !liveToolChips.isEmpty else { return }
        let statuses = Dictionary(
            messages.filter { $0["role"].string == "user" && !$0.id.isEmpty }
                .map { ($0.id, $0["status"].string) },
            uniquingKeysWith: { first, _ in first }
        )
        for (mid, chips) in liveToolChips {
            guard let msgStatus = statuses[mid],
                  !WorkProcess.activeStatuses.contains(msgStatus) else { continue }
            if chips.contains(where: { $0.status == "running" }) {
                liveToolChips[mid] = chips.map { chip in
                    guard chip.status == "running" else { return chip }
                    return LiveToolChip(id: chip.id, tool: chip.tool, title: chip.title, status: "completed", durationMs: chip.durationMs)
                }
            }
        }
    }

    func narrateAssistantMessage(_ message: JSON) {
        guard voiceNarrationEnabled, voice.phase != .recording else { return }
        let parsed = SendMessageBubble.parse(from: message)
        let spoken: String = {
            switch parsed.type {
            case .text:
                return parsed.content
            case .attachment:
                return parsed.caption.isEmpty ? "已生成文件 \(parsed.name)" : parsed.caption
            case .widget:
                let title = parsed.widget["title"].string
                let lead = parsed.content
                if !lead.isEmpty { return lead }
                return title.isEmpty ? "有一项操作需要你确认" : title
            case .secretRequest:
                return "需要你安全填写密钥 \(parsed.secretName)"
            }
        }()
        ComVoiceNarrator.shared.speak(spoken, messageID: message.id)
    }

    func stopVoiceNarration() {
        ComVoiceNarrator.shared.stop()
    }

    // MARK: - 剪贴板新链接轻量探测（防重复打扰，仅存 SHA-256 摘要）

    func probeClipboardForDrop() {
        #if DEBUG
        if isUITesting {
            if let mockURL = ProcessInfo.processInfo.environment["COM_UI_CLIPBOARD_URL"], !mockURL.isEmpty {
                let digest = Self.sha256Hex(mockURL)
                if digest != lastClipboardHash { clipboardDropCandidate = mockURL }
            }
            return
        }
        #endif
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasURLs else { return }
        let currentCount = pasteboard.changeCount
        guard currentCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = currentCount

        let candidateURL: URL? = {
            if let direct = pasteboard.url { return direct }
            if let raw = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = URL(string: raw) {
                return parsed
            }
            return nil
        }()
        guard let url = candidateURL,
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else { return }

        let urlString = url.absoluteString
        let digest = Self.sha256Hex(urlString)
        guard digest != lastClipboardHash else { return }
        clipboardDropCandidate = urlString
    }

    func dismissClipboardDropCandidate() {
        if let candidate = clipboardDropCandidate, !candidate.isEmpty {
            rememberHandledClipboardURL(candidate)
        }
        clipboardDropCandidate = nil
    }

    func rememberHandledClipboardURL(_ urlString: String) {
        let digest = Self.sha256Hex(urlString)
        lastClipboardHash = digest
        UserDefaults.standard.set(digest, forKey: "chat.lastClipboardHash")
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SecretEntryBubble 安全凭据直投（绝不进聊天历史或操作台账）

    func submitSecretEntry(
        messageID: String,
        secretName: String,
        targetEnv: String,
        secretValue: String
    ) async -> (ok: Bool, note: String) {
        let trimmedValue = secretValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return (false, "请先输入密钥内容")
        }
        #if DEBUG
        if isUITesting {
            resolvedWidgetStates["secret:" + messageID] = .object(["submitted": .bool(true)])
            return (true, "")
        }
        #endif
        guard let api = client else {
            return (false, "还没连上 Mac mini，密钥未发出")
        }
        // 1. 加密落入本机 Keychain 安全保险箱，同时经 TLS 直投后端凭据接口（不经 mutate 留明文台账）
        try? SecureVault.storeSecret(Data(trimmedValue.utf8), account: "secret." + secretName)
        var deliveredToServer = false
        do {
            _ = try await api.request("/personal/secrets", body: .object([
                "secret_name": .string(secretName),
                "target_env": .string(targetEnv),
                "value": .string(trimmedValue)
            ]))
            deliveredToServer = true
        } catch let apiErr as APIError where apiErr.status == 404 {
            // 若后端未单独挂载 /personal/secrets，尝试匹配连接器安全配置端点
            let connector = targetEnv.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !connector.isEmpty && !connector.contains("/") {
                _ = try? await api.request("/personal/connectors/" + connector.pathEncoded, body: .object([
                    secretName: .string(trimmedValue)
                ]))
            }
            deliveredToServer = true
        } catch {
            return (false, "安全提交失败：" + error.localizedDescription)
        }

        guard deliveredToServer else {
            return (false, "安全通道未确认接收")
        }
        // 2. 持久化该气泡已脱敏收敛态，并发送不含任何明文密钥的唤醒回执恢复 awaiting_user 轮次
        let stateKey = "secret:" + messageID
        let statePayload: JSON = .object(["submitted": .bool(true), "secret_name": .string(secretName)])
        resolvedWidgetStates[stateKey] = statePayload
        _ = try? await api.request("/personal/artifact-state/" + stateKey.pathEncoded, body: .object(["state": statePayload]))
        _ = await send(textOverride: "已安全配置密钥 \(secretName)，请继续")
        Haptics.success()
        return (true, "")
    }

    /// TurnPlanner 思考步骤一键沉淀为待办事项（调用 POST /personal/matters/from_step）
    @discardableResult
    func createMatterFromStep(
        stepId: String = "",
        messageId: String = "",
        stepIndex: Int = 0,
        title: String,
        initialStatus: String = "todo",
        obsidianFlow: String = "任务"
    ) async -> JSON? {
        let requestId = "req-step-\(UUID().uuidString.prefix(8).lowercased())"
        let msgId = messageId.isEmpty ? (conversation.messages.last?.id ?? "msg-current") : messageId
        let sId = stepId.isEmpty ? "step-\(stepIndex)" : stepId
        let fields: [String: JSON] = [
            "request_id": .string(requestId),
            "conversation_id": .string("conv-default"),
            "message_id": .string(msgId),
            "step_id": .string(sId),
            "step_index": .number(Double(stepIndex)),
            "title": .string(title),
            "initial_status": .string(initialStatus),
            "obsidian_flow": .string(obsidianFlow)
        ]
        do {
            let result = try await mutate("/personal/matters/from_step", fields: fields)
            banner = "已转为待办事项：\(title)"
            Haptics.success()
            Task { @MainActor in
                _ = await self.load(Self.boardPath)
            }
            return result
        } catch {
            banner = "转待办失败: \(error.localizedDescription)"
            Haptics.error()
            return nil
        }
    }
}

#if DEBUG
extension AppModel {
    /// `--ui-work-process`：一条做完的（折叠成一行）+ 一条正在做的（实时一行 + 顶栏气泡），并按脚本往前走。
    func seedWorkProcessPreview() {
        let now = Date().timeIntervalSince1970
        func step(_ n: Int, _ tool: String, _ status: String, at: Double, took: Double = 1.2) -> JSON {
            .object(["id": .string("tool-\(n)"), "kind": .string("tool"), "tool": .string(tool), "title": .string("正在使用 " + tool),
                     "status": .string(status), "started_at": .number(at), "finished_at": .number(status == "running" ? 0 : at + took)])
        }
        let reply = """
        上周（10 月 1 日–7 日）在攀岩上一共花了 **¥1,326**，比前一周多了 **¥410**，主要是多去了两次岩馆。

        ## 明细

        - **岩馆门票** ¥580 · 4 次，其中周六两次
        - **装备** ¥466 · 新换了一双攀岩鞋
        - **交通** ¥280 · 打车往返

        ## 今天这笔

        岩馆月卡 **¥480** 已经记进「运动 · 攀岩」，日期是今天。按这个月剩下的次数算，月卡比单次票便宜大约 ¥220。

        > 如果月卡要跟朋友 AA，告诉我一声，我把这笔拆开记。
        """
        // 10-28 todo 时间轴验收：第三步进行中，它下面挂着从 now-12 起的工具
        func todo(_ id: String, _ text: String, _ status: String, _ start: Double = 0, _ done: Double = 0) -> JSON {
            .object(["id": .string(id), "content": .string(text), "active": .string("正在" + text), "status": .string(status),
                     "started_at": .number(start), "done_at": .number(done)])
        }
        let wpPlan: JSON = .object(["id": .string("plan"), "kind": .string("plan"), "title": .string("查聊天页排版"), "todos": .array([
            todo("1", "找到聊天页代码", "completed", now - 30, now - 18),
            todo("2", "翻排版相关样式", "completed", now - 18, now - 12),
            todo("3", "定位挤的原因", "in_progress", now - 12),
            todo("4", "核对改法会不会误伤", "pending"),
            todo("5", "写结论给你", "pending")])])
        conversation.messages = [
            .object(["id": .string("wp-0"), "role": .string("assistant"), "text": .string("早上好。今天日程不多，下午三点有个会。"), "status": .string("completed"), "created_at": .number(now - 900)]),
            .object(["id": .string("wp-1"), "role": .string("user"), "text": .string("上周在攀岩上花了多少钱？顺便帮我记一笔今天的岩馆月卡 480"), "status": .string("completed"),
                     "created_at": .number(now - 600), "received_at": .number(now - 600),
                     "tasks": .array([step(1, "memory_recall", "done", at: now - 599), step(2, "bookkeeping_search", "done", at: now - 597), step(3, "bookkeeping_search", "done", at: now - 595),
                                      step(4, "bookkeeping_search", "done", at: now - 593), step(5, "bookkeeping", "done", at: now - 590, took: 2)]),
                     "summary": .object(["duration_ms": .number(14_000)])]),
            .object(["id": .string("wp-2"), "role": .string("assistant"), "parent_id": .string("wp-1"), "text": .string(reply), "status": .string("completed"), "created_at": .number(now - 585)]),
            .object(["id": .string("wp-3"), "role": .string("user"), "text": .string("帮我看看 Com 聊天页的代码，排版为什么这么挤"), "status": .string("running"), "phase": .string("executing"),
                     "created_at": .number(now - 20), "received_at": .number(now - 20),
                     "tasks": .array([wpPlan] + (1...6).map { step($0, $0 % 2 == 0 ? "find" : "grep", "done", at: now - 19 + Double($0) * 1.5) } + [step(7, "read", "running", at: now - 6)])])
        ]
        conversation.runs = [.object(["message_id": .string("wp-3"), "status": .string("running"), "phase": .string("executing"), "active_tool": .string("read")])]
        // init 在 seed 之后会用 idle 快照打底，等它跑完再告诉舞台她在翻资料。
        Task { [weak self] in await Task.yield(); self?.stage.receive("task.progress", .object(["kind": .string("searching")])) }
        guard ProcessInfo.processInfo.arguments.contains("--ui-work-process-live") else { return }
        // 往前走：读完 → 跑命令 → 改文件 → 写回复 → 完成。
        let script: [(String, String)] = [("read", "done"), ("read", "running"), ("read", "done"), ("bash", "running"), ("bash", "done"), ("edit", "running"), ("edit", "done"), ("", "responding"), ("", "completed")]
        Task { [weak self] in
            for (tool, status) in script {
                try? await Task.sleep(for: .seconds(2.2))
                guard let self, let index = self.conversation.messages.firstIndex(where: { $0.id == "wp-3" }) else { return }
                var message = self.conversation.messages[index]
                var tasks = message["tasks"].array
                let at = Date().timeIntervalSince1970
                if status == "done", let last = tasks.indices.last { tasks[last]["status"] = .string("done"); tasks[last]["finished_at"] = .number(at) }
                else if status == "running" { tasks.append(step(tasks.count + 1, tool, "running", at: at)) }
                else if status == "responding" { message["phase"] = .string("responding") }
                else {
                    message["status"] = .string("completed")
                    self.conversation.runs = []
                    self.conversation.messages.append(.object(["id": .string("wp-4"), "role": .string("assistant"), "parent_id": .string("wp-3"), "status": .string("completed"), "created_at": .number(at),
                        "text": .string("挤的原因有两个：\n\n1. **行距用的是默认值**，中文长段落贴得很紧\n2. **段落之间只有一行空白**，列表项之间几乎没有间距\n\n我已经把行距和段落间距都放宽了。")]))
                    self.stage.receive("task.progress", .object(["kind": .string("idle")]))
                }
                message["tasks"] = .array(tasks)
                self.conversation.messages[index] = message
                self.conversation.revision += 1
                if status == "running" { self.stage.receive("task.progress", .object(["kind": .string(tool == "bash" ? "working" : tool == "edit" ? "writing" : "searching")])) }
            }
        }
    }
}
#endif

#if DEBUG
// r2-chat：主聊天排版 + 建议卡的验收数据。
extension AppModel {
    /// `--ui-reply-layout`：三条 mini 上常见的整段纯文本回复，最后一条末行带选项标记。
    /// 加 `--ui-reply-legacy` 看改版前的渲染（前后对比截图用）；加 `--ui-reply-live` 1.5 秒后再来一条新回复，看进场动效。
    func seedReplyLayoutPreview() {
        let now = Date().timeIntervalSince1970
        func message(_ id: String, _ role: String, _ text: String, at: Double, extra: [String: JSON] = [:]) -> JSON {
            .object(["id": .string(id), "role": .string(role), "text": .string(text), "status": .string("completed"), "created_at": .number(at)].merging(extra) { $1 })
        }
        conversation.messages = [
            message("rl-1", "user", "上周攀岩花了多少？顺便把今天的岩馆月卡480记一下", at: now - 900),
            message("rl-2", "assistant", "上周你在攀岩上一共花了1326元，比前一周多了410元，主要是多去了两次岩馆。明细是这样的：岩馆门票580元，一共4次；装备466元，换了一双攀岩鞋；交通280元，基本都是打车。今天的岩馆月卡480元我已经记进运动攀岩分类了，日期是今天。按这个月剩下的次数算，月卡比单次票大概便宜220元，挺划算的。如果要跟朋友AA的话告诉我一声，我把这笔拆开记。", at: now - 880),
            message("rl-3", "user", "明天要准备什么", at: now - 600),
            message("rl-4", "assistant", "明天日程不算满，但有三件事要提前准备。首先，上午10:30跟搜狐的同事开选题会，你上次说要带三个备选题，目前行动台里只有两个。其次，下午3点要去岩馆拍探馆素材，记得带上GoPro和备用电池。最后，晚上8点之前要把极限勇士挑战赛的物料清单发给供应商，这个昨天已经催过一次了。我建议今晚先把第三个选题补上，明早就不用赶。", at: now - 580),
            message("rl-5", "user", "Com 刚才怎么连不上", at: now - 120),
            message("rl-6", "assistant", "查完了，mini 上的 Com 服务是正常的，刚才连不上是因为 Magpie 网关重启了一次，大概断了40秒。现在接口都能通，最近一小时没有新的报错。另外我顺手看了下磁盘，还剩86GB，不用管。如果你还遇到连不上，先下拉刷新一下，还不行就告诉我，我去看日志。\n[[选项: 帮我盯着日志 | 先不管 | 看看详情]]", at: now - 100),
        ]
        // `--ui-reply-only=N`：只留第 N 组问答（截图对比用）。
        if let only = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-reply-only=") }).flatMap({ Int($0.split(separator: "=").last ?? "") }), (1...3).contains(only) {
            conversation.messages = Array(conversation.messages[(only - 1) * 2 ..< only * 2])
        }
        guard ProcessInfo.processInfo.arguments.contains("--ui-reply-live") else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.conversation.messages.append(message("rl-7", "user", "明早提醒我带电池", at: Date().timeIntervalSince1970))
            self.conversation.messages.append(message("rl-8", "assistant", "**记好了，明早 8:00 提醒你带 GoPro 备用电池。**\n\n### 顺手看了下\n\n- 下午 **3 点**岩馆拍摄，电池要 **2 块**\n- 充电器在书房抽屉\n\n要不要连充电器也一起提醒？", at: Date().timeIntervalSince1970,
                                                       extra: ["suggestions": .array([.string("一起提醒"), .string("不用了"), .string("改到7点半")])]))
            self.conversation.revision += 1
        }
    }

    /// `--ui-her-demo`：三段 Her 式对话（打车信息+建议+确认 / 用户「好 叫吧」/ 回执 / 间隔 40 分钟后的快递提醒）。
    /// 加 `--ui-her-confirm` 停在第一条待确认回复，展示快捷回复确认词胶囊实色填充。
    func seedHerDemoPreview() {
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let t1 = dayStart + 9 * 3600 + 5 * 60 + 30
        let t2 = dayStart + 9 * 3600 + 6 * 60
        let t3 = dayStart + 9 * 3600 + 6 * 60 + 15
        let t4 = t3 + 40 * 60
        func message(_ id: String, _ role: String, _ text: String, at: Double, extra: [String: JSON] = [:]) -> JSON {
            .object(["id": .string(id), "role": .string(role), "text": .string(text), "status": .string("completed"), "created_at": .number(at)].merging(extra) { $1 })
        }
        let m1Text = """
        - **目的地**：搜狐媒体大厦
        - **路程**：约 7 公里，18 分钟
        - **价格**：惊喜特价 ¥10 · 快车 ¥16 · 专车 ¥27

        我建议叫**快车 ¥16**。特价要等拼单匹配，可能多等一会儿，你赶着上班就别省这几块了。

        你手机定位是昨晚 21:45 更新的，显示在酒店。你现在还在酒店吧？

        最后一天了，出差辛苦 😄 没问题回我一句「叫」就发单。
        [[选项: 叫 | 再想想]]
        """
        let m3Text = """
        叫到了，司机大概 **2 分钟**到，下楼吧：

        - **车**：黑色比亚迪秦 PLUS · 京A·D83921
        - **司机**：王师傅（4.9 分）
        - **上车点**：酒店正门落客区
        """
        let m4Text = """
        德亚希腊酸奶在派送了，今天注意收一下。

        【顺丰速运】您的快件 SF1429803126 正在由派件员张师傅派送中，请保持电话畅通。
        """
        ReplyMotion.played.formUnion(["her-1", "her-3", "her-4"])
        let all = [
            message("her-1", "assistant", m1Text, at: t1),
            message("her-2", "user", "好 叫吧", at: t2),
            message("her-3", "assistant", m3Text, at: t3, extra: ["parent_id": .string("her-2")]),
            message("her-4", "assistant", m4Text, at: t4, extra: [
                "request_id": .string("task-result:nudge:express-1"),
                "metadata": .object(["kind": .string("nudge")]),
            ]),
        ]
        if ProcessInfo.processInfo.arguments.contains("--ui-her-confirm") {
            conversation.messages = [all[0]]
        } else {
            conversation.messages = all
        }
    }
}
#endif
