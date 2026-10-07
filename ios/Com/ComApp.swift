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
                .task { ComShortcuts.updateAppShortcutParameters(); ComNotifications.install(); await model.start(); if model.isPaired && !model.isUITesting { await ComNotifications.requestIfNeeded() } }
                .onChange(of: scenePhase) { _, phase in Task { await model.setActive(phase == .active) } }
                .onOpenURL { url in
                    guard url.scheme == "com-eddie" else { return }
                    if url.host == "voice" { model.openVoice(quick: true) }
                    if url.host == "share", let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value {
                        model.tab = .chat; model.draft = model.draft.isEmpty ? text : model.draft + "\n\n" + text; model.persistNow()
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
    static func install() { UNUserNotificationCenter.current().delegate = shared }
    static func requestIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined { _ = await enable() }
        else if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            UserDefaults.standard.set(true, forKey: enabledKey); ComPush.register(); schedule()
        }
    }
    static func enable() async -> Bool {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UserDefaults.standard.set(allowed, forKey: enabledKey)
            if allowed { ComPush.register(); schedule() }
            return allowed
        } catch { return false }
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
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["comMessageID"] as? String
        await MainActor.run { NotificationCenter.default.post(name: .comOpenMessage, object: id) }
    }
}
extension Notification.Name { static let comOpenMessage = Notification.Name("com.open.message") }
