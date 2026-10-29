import UIKit
import UserNotifications
import ComCore

@MainActor final class ComPushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        do {
            try SecureVault.storeSecret(deviceToken, account: "apns-token")
            Task { _ = await ComPush.registerToken() }
        } catch {
            UserDefaults.standard.set(false, forKey: "remoteNotificationsReady")
            UserDefaults.standard.set(
                "本机没存上推送 token：\(error.localizedDescription)——通知权限可能已开，但远程推送未接通。可再点「开启新消息通知」。不会假装推送已通。",
                forKey: "notificationRefreshStatus"
            )
        }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(false, forKey: "remoteNotificationsReady")
        UserDefaults.standard.set(
            "系统没给到推送 token：\(error.localizedDescription)——通知权限可能已开，但远程推送未接通；后台刷新仍会试。不会假装推送已通。",
            forKey: "notificationRefreshStatus"
        )
    }
}

@MainActor enum ComPush {
    static let statusKey = "notificationRefreshStatus"
    static let readyKey = "remoteNotificationsReady"

    static var installationID: String {
        if let id = UserDefaults.standard.string(forKey: "notificationInstallationID") { return id }
        let id = UUID().uuidString.lowercased(); UserDefaults.standard.set(id, forKey: "notificationInstallationID"); return id
    }
    static func register() {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        // A push-enabled provisioning profile is required. Keep ordinary builds installable.
        let environment = Bundle.main.object(forInfoDictionaryKey: "ComAPNSEnvironment") as? String ?? ""
        guard ["development", "production"].contains(environment) else {
            UserDefaults.standard.set(false, forKey: readyKey)
            UserDefaults.standard.set(
                "这版安装没有远程推送通道——只能靠打开 App 或后台刷新。不会假装远程推送已通。",
                forKey: statusKey
            )
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }
    /// 把本机 APNs token 报到服务器。失败写 `notificationRefreshStatus` 供设置页开口，不假装已接通。
    @discardableResult
    static func registerToken() async -> Bool {
        guard let data = SecureVault.secret("apns-token"),
              let auth = SecureVault.secret("token"), let token = String(data: auth, encoding: .utf8),
              let base = UserDefaults.standard.string(forKey: "base") else {
            // 还没配对 / 系统还没回调 token：不算上报失败，别盖掉已有说明。
            return false
        }
        let environment = Bundle.main.object(forInfoDictionaryKey: "ComAPNSEnvironment") as? String ?? ""
        guard ["development", "production"].contains(environment) else {
            UserDefaults.standard.set(false, forKey: readyKey)
            UserDefaults.standard.set(
                "这版安装没有远程推送通道——只能靠打开 App 或后台刷新。不会假装远程推送已通。",
                forKey: statusKey
            )
            return false
        }
        do {
            let api = try APIClient(base: base, token: token)
            let result = try await api.request("/personal/notifications/devices", body: .object([
                "id": .string(installationID), "token": .string(data.map { String(format: "%02x", $0) }.joined()),
                "environment": .string(environment == "development" ? "sandbox" : "production")]))
            let ready = result["configured"].bool
            UserDefaults.standard.set(ready, forKey: readyKey)
            if ready {
                UserDefaults.standard.set("系统推送已接通", forKey: statusKey)
            } else {
                UserDefaults.standard.set(
                    "token 已报到服务器，但推送通道尚未配置好——后台刷新仍会试。不会假装远程推送已通。",
                    forKey: statusKey
                )
            }
            return ready
        } catch {
            UserDefaults.standard.set(false, forKey: readyKey)
            UserDefaults.standard.set(
                "推送 token 没报到服务器：\(error.localizedDescription)——通知权限可能已开，但远程推送未接通。可再点「开启新消息通知」或「再试一次上报」。不会假装推送已通。",
                forKey: statusKey
            )
            return false
        }
    }
    /// 注销本机推送。返回服务器是否收到禁用；本地 unregister 总会做。
    @discardableResult
    static func disable(using api: APIClient) async -> Bool {
        var remoteOk = true
        do {
            _ = try await api.request("/personal/notifications/devices/" + installationID.pathEncoded + "/disable", body: .object([:]))
        } catch {
            remoteOk = false
        }
        UIApplication.shared.unregisterForRemoteNotifications()
        UserDefaults.standard.set(false, forKey: readyKey)
        UserDefaults.standard.removeObject(forKey: statusKey)
        return remoteOk
    }
}
