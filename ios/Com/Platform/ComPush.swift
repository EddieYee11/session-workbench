import UIKit
import UserNotifications
import ComCore

@MainActor final class ComPushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        try? SecureVault.storeSecret(deviceToken, account: "apns-token")
        Task { await ComPush.registerToken() }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(false, forKey: "remoteNotificationsReady")
        UserDefaults.standard.set("系统推送尚未就绪，后台刷新仍会尝试读取新消息。", forKey: "notificationRefreshStatus")
    }
}

@MainActor enum ComPush {
    static var installationID: String {
        if let id = UserDefaults.standard.string(forKey: "notificationInstallationID") { return id }
        let id = UUID().uuidString.lowercased(); UserDefaults.standard.set(id, forKey: "notificationInstallationID"); return id
    }
    static func register() {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        // A push-enabled provisioning profile is required. Keep ordinary builds installable.
        let environment = Bundle.main.object(forInfoDictionaryKey: "ComAPNSEnvironment") as? String ?? ""
        guard ["development", "production"].contains(environment) else {
            UserDefaults.standard.set(false, forKey: "remoteNotificationsReady"); return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }
    static func registerToken() async {
        guard let data = SecureVault.secret("apns-token"),
              let auth = SecureVault.secret("token"), let token = String(data: auth, encoding: .utf8),
              let base = UserDefaults.standard.string(forKey: "base") else { return }
        let environment = Bundle.main.object(forInfoDictionaryKey: "ComAPNSEnvironment") as? String ?? ""
        guard ["development", "production"].contains(environment) else { return }
        do {
            let api = try APIClient(base: base, token: token)
            let result = try await api.request("/personal/notifications/devices", body: .object([
                "id": .string(installationID), "token": .string(data.map { String(format: "%02x", $0) }.joined()),
                "environment": .string(environment == "development" ? "sandbox" : "production")]))
            UserDefaults.standard.set(result["configured"].bool, forKey: "remoteNotificationsReady")
        } catch { UserDefaults.standard.set(false, forKey: "remoteNotificationsReady") }
    }
    static func disable(using api: APIClient) async {
        _ = try? await api.request("/personal/notifications/devices/" + installationID.pathEncoded + "/disable", body: .object([:]))
        UIApplication.shared.unregisterForRemoteNotifications()
        UserDefaults.standard.set(false, forKey: "remoteNotificationsReady")
    }
}
