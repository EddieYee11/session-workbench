import SwiftUI
import AppIntents
import BackgroundTasks
import UserNotifications
import ComCore

@main struct ComApp: App {
    @UIApplicationDelegateAdaptor(ComPushDelegate.self) private var pushDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environment(model)
                .task { ComShortcuts.updateAppShortcutParameters(); ComNotifications.install(); ComLiveActivity.shared.start(model); await model.start(); if model.isPaired && !model.isUITesting { await ComNotifications.requestIfNeeded() } }
                .onChange(of: scenePhase) { _, phase in
                    // 灵动岛常驻（轨道 r3-memory）：要在 setActive(false) 断开连接之前，把这一刻的状态推上去。
                    ComLiveActivity.shared.scene(phase)
                    AppLock.shared.scene(phase, paired: model.isPaired)
                    // .inactive 只是短暂遮挡（控制中心、通知横幅、来电）。只有真正进后台或回到前台才重建连接。
                    guard phase != .inactive else { return }
                    Task { await model.setActive(phase == .active) }
                }
                .onOpenURL { url in
                    guard url.scheme == "com-eddie" else { return }
                    // today：灵动岛/旧链约定回主对话并刷 conversation；失败 todayOpenNote，不假装已读上。
                    if url.host == "today" { model.openTodayDeepLink() }
                    // tasks：小组件审批角标 → 统一等你（与通知 section=tasks 同路），别落到「今天」空页。
                    if url.host == "tasks" { model.openWaitingInbox() }
                    if url.host == "cases" {
                        // 航程/任务结果推送：打开动态「电脑上的活」；loadFeed 失败 activityOpenNote，不假装已读上。
                        model.openCasesDeepLink()
                    }
                    if url.host == "plan" {
                        model.openPlanDeepLink()
                    }
                    if url.host == "waiting" {
                        // 推送 / 深链进统一「等你」：与应用内入口共用 openWaitingInbox。
                        model.openWaitingInbox()
                    }
                    if url.host == "approval" { model.openApproval(url) }
                    if url.host == "pair" {
                        model.applyPairDeepLink(url)
                    }
                    if url.host == "voice" { model.openVoice(quick: true) }
                    if url.host == "share" {
                        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value
                        if let text, !text.isEmpty {
                            model.tab = .chat
                            model.draft = model.draft.isEmpty ? text : model.draft + "\n\n" + text
                            model.persistNow()
                        }
                        // 深链进分享：探测 App Group；坏容器时主聊/收件箱开口，不假装没有待处理分享。
                        model.openShareInbox()
                    }
                }
        }
        .backgroundTask(.appRefresh(ComNotifications.identifier)) { await ComNotifications.refresh() }
    }
}

struct ComShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenComVoice(), phrases: ["打开 \(.applicationName) 语音"], shortTitle: "Com 语音", systemImageName: "waveform")
    }
}



/// Fetches actual new server messages when iOS grants background runtime.
/// No scheduled placeholder pretends to be an already-generated briefing.
@MainActor final class ComNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ComNotifications()
    static let identifier = "work.eddie.com.messages"
    static let enabledKey = "messageNotifications"
    /// 审批通知：通知中心里就能批准/拒绝，不用先回工作页找那张卡。
    nonisolated static let approvalCategory = "COM_APPROVAL"
    nonisolated static let approveAction = "com.approval.approve"
    nonisolated static let denyAction = "com.approval.deny"
    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        let approve = UNNotificationAction(identifier: approveAction, title: "批准", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyAction, title: "拒绝", options: [.destructive, .authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: approvalCategory, actions: [approve, deny], intentIdentifiers: []),
        ])
    }
    /// 工作页轮询发现新审批：不在工作页时发本地通知；同一审批只发一次。
    static func approvalWaiting(_ approvals: [JSON], sessionID: String, show: Bool) {
        guard show, !ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              UserDefaults.standard.bool(forKey: enabledKey) else { return }
        var seen = UserDefaults.standard.stringArray(forKey: "notifiedApprovalIDs") ?? []
        for approval in approvals {
            let id = approval.id
            guard !id.isEmpty, !seen.contains(id) else { continue }
            let reason = approval["params"]["reason"].string
            seen.append(id)
            let content = UNMutableNotificationContent()
            content.title = "Com · 需要你决定"
            content.body = reason.isEmpty ? "Agent 停下来等你的决定。" : String(reason.prefix(140))
            content.sound = .default
            content.categoryIdentifier = approvalCategory
            content.userInfo = ["comApprovalID": id, "comSessionID": sessionID]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "approval-" + id, content: content, trigger: nil))
        }
        UserDefaults.standard.set(Array(seen.suffix(300)), forKey: "notifiedApprovalIDs")
    }
    /// 通知上的批准/拒绝：直接用已保存的连接执行，再让前台刷新。
    static func resolveApproval(_ id: String, decision: String) async {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run {
                NotificationCenter.default.post(name: .comApprovalResolved, object: id, userInfo: ["message": "审批通知少了编号——没法代你点。可打开工作页或「等你」再批。不会假装已批准。"])
            }
            return
        }
        guard let tokenData = SecureVault.secret("token"), let token = String(data: tokenData, encoding: .utf8),
              let base = UserDefaults.standard.string(forKey: "base"), !token.isEmpty else {
            // 未配对 / 无凭据：以前静默 return，通知动作像点了却没下文。
            await MainActor.run {
                NotificationCenter.default.post(name: .comApprovalResolved, object: trimmed, userInfo: ["message": "审批没送出——还没连上 mini 或凭据丢了。先配对再批；不会假装已批准。"])
            }
            return
        }
        do {
            let api = try APIClient(base: base, token: token)
            _ = try await api.request("/approvals/" + trimmed.pathEncoded, body: .object(["decision": .string(decision)]))
            let message = decision == "accept" ? "已批准这次操作。" : "已拒绝这次操作。"
            await MainActor.run {
                NotificationCenter.default.post(name: .comApprovalResolved, object: trimmed, userInfo: ["message": message])
            }
        } catch {
            await MainActor.run {
                NotificationCenter.default.post(name: .comApprovalResolved, object: trimmed, userInfo: ["message": "审批没有送达：" + error.localizedDescription + "——可打开工作页再批。不会假装已批准。"])
            }
        }
    }
    static func requestIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined { _ = await enable() }
        else if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            UserDefaults.standard.set(true, forKey: enabledKey); ComPush.register(); schedule()
            // 权限已有时也补报一次 token，失败写 status 供设置页开口。
            if SecureVault.secret("apns-token") != nil { _ = await ComPush.registerToken() }
        }
    }
    /// 开通知权限并尽量上报推送 token。`note` 给人看；权限开了但 token 上报失败时 allowed 仍为 true，note 说清不会假装推送已通。
    static func enable() async -> (allowed: Bool, note: String) {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UserDefaults.standard.set(allowed, forKey: enabledKey)
            guard allowed else {
                return (false, "未开启，请到系统设置允许通知。不会假装推送已通。")
            }
            ComPush.register()
            schedule()
            if SecureVault.secret("apns-token") != nil {
                if await ComPush.registerToken() {
                    return (true, "通知已开启，系统推送已接通。")
                }
                let status = UserDefaults.standard.string(forKey: ComPush.statusKey) ?? ""
                return (true, status.isEmpty
                        ? "通知权限已开，推送 token 还没报到服务器——可点「再试一次上报」。不会假装远程推送已通。"
                        : status)
            }
            return (true, "通知权限已开——正在向系统要推送通道；若稍后仍未接通，这里会说明。不会假装远程推送已通。")
        } catch {
            return (false, "没要到通知权限：\(error.localizedDescription)——可再到系统设置允许。不会假装推送已通。")
        }
    }
    static func schedule() {
        guard UserDefaults.standard.bool(forKey: enabledKey), !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard !UserDefaults.standard.bool(forKey: "remoteNotificationsReady") else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { UserDefaults.standard.set("后台刷新暂不可用：" + error.localizedDescription, forKey: "notificationRefreshStatus") }
    }
    static func receiveLive(_ name: String, _ value: JSON, show: Bool) {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        let id = name == "agent.push" ? value["id"].string : "review:" + value["source_id"].string
        guard !id.isEmpty, id != "review:" else { return }
        let key = "liveNotificationIDs"
        var seen = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !seen.contains(id) else { return }
        seen.append(id); UserDefaults.standard.set(Array(seen.suffix(200)), forKey: key)
        guard show, UserDefaults.standard.bool(forKey: enabledKey) else { return }
        Task {
            let content = UNMutableNotificationContent()
            content.title = name == "task.review" ? "Com · 这一步等你确认" : "Com · 有新的回复"
            content.body = name == "task.review" ? "打开任务页，查看具体操作后决定。" : "已经整理好了，打开 Com 查看。"
            content.sound = .default
            content.userInfo = ["comMessageID": value["message_id"].string, "comSection": name == "task.review" ? "waiting" : "chat"]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
    static func observe(_ messages: [JSON]) {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        let completed = messages.filter { $0["role"].string == "assistant" && $0["status"].string == "completed" }.map(\.id)
        let previous = UserDefaults.standard.stringArray(forKey: "notifiedMessageIDs") ?? []
        UserDefaults.standard.set(Array(Set(previous + completed)).sorted().suffix(1000).map { $0 }, forKey: "notifiedMessageIDs")
        UserDefaults.standard.set(true, forKey: "notificationBaselineReady")
    }
    static func refresh() async {
        defer { schedule() }
        guard !UserDefaults.standard.bool(forKey: "remoteNotificationsReady") else { return }
        guard UserDefaults.standard.bool(forKey: enabledKey),
              let tokenData = SecureVault.secret("token"), let token = String(data: tokenData, encoding: .utf8),
              let base = UserDefaults.standard.string(forKey: "base") else { return }
        do {
            let api = try APIClient(base: base, token: token)
            let data = try await api.request("/personal/conversation")
            let messages = data["messages"].array
            if !UserDefaults.standard.bool(forKey: "notificationBaselineReady") { observe(messages); return }
            let seen = Set(UserDefaults.standard.stringArray(forKey: "notifiedMessageIDs") ?? [])
            let new = messages.filter { $0["role"].string == "assistant" && $0["status"].string == "completed" && !seen.contains($0.id) && $0["created_at"].double > Date().timeIntervalSince1970 - 86400 }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let hour = calendar.component(.hour, from: Date())
            guard !new.isEmpty, hour >= 8, hour < 23, !Task.isCancelled else { return }
            let content = UNMutableNotificationContent()
            content.title = "Com 有新消息"
            content.body = new.count == 1 ? "新的回复或主动消息已到达，点击查看。" : "有 \(new.count) 条新消息，点击查看。"
            content.sound = .default
            content.userInfo = ["comMessageID": new.last!.id]
            let request = UNNotificationRequest(identifier: "message-" + new.last!.id, content: content, trigger: nil)
            try await UNUserNotificationCenter.current().add(request)
            observe(messages)
            UserDefaults.standard.set("已读取真实新消息", forKey: "notificationRefreshStatus")
        } catch { UserDefaults.standard.set("读取未完成，下次后台刷新再检查", forKey: "notificationRefreshStatus") }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let approvalID = info["comApprovalID"] as? String {
            if response.actionIdentifier == Self.approveAction { await Self.resolveApproval(approvalID, decision: "accept"); return }
            if response.actionIdentifier == Self.denyAction { await Self.resolveApproval(approvalID, decision: "decline"); return }
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
               let sid = info["comSessionID"] as? String, !sid.isEmpty {
                await MainActor.run { NotificationCenter.default.post(name: .comOpenApproval, object: nil, userInfo: ["sid": sid]) }
                return
            }
        }
        let id = info["comMessageID"] as? String
        let section = info["comSection"] as? String
        await MainActor.run { NotificationCenter.default.post(name: .comOpenMessage, object: id, userInfo: ["section": section ?? "chat"]) }
    }
}
extension Notification.Name {
    static let comOpenMessage = Notification.Name("com.open.message")
    static let comOpenApproval = Notification.Name("com.open.approval")
    static let comApprovalResolved = Notification.Name("com.approval.resolved")
}
