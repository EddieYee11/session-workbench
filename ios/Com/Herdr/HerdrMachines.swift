import Foundation
import HerdrKit
import Security

/// 可连接的机器。地址由后端下发（`~/.session-workbench/herdr-machines.json`，不进仓库），本机缓存一份。
struct HerdrMachine: Identifiable, Equatable, Codable {
    struct Address: Equatable, Codable {
        /// 第一跳；`machine` 决定用哪台机器的主机指纹。
        struct Via: Equatable, Codable {
            var host: String
            var port: Int
            var machine: String
        }
        var label: String
        var host: String
        var port: Int
        var via: Via?
    }
    var id: String
    var label: String
    var username: String
    var addresses: [Address]
}

enum HerdrMachineCache {
    private static let key = "herdr.machines.cache"

    static func load() -> [HerdrMachine] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let machines = try? JSONDecoder().decode([HerdrMachine].self, from: data) else { return [] }
        return machines
    }

    static func save(_ machines: [HerdrMachine]) {
        guard let data = try? JSONEncoder().encode(machines) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// 这台手机自己的 SSH 身份：私钥只在 Keychain 里生成和保存，不离开设备，只把公钥交出去授权。
enum HerdrDeviceKey {
    private static let service = "work.eddie.com.herdr.ssh"
    private static let account = "device-ed25519"
    private static let legacyAccount = "ed25519-seed"
    private static let publicKeyDefaults = "herdr.device.publicKey"

    static func seed() throws -> Data {
        removeLegacyPastedKey()
        if let existing = read(account: account) { return existing }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw keychainError(status) }
        var add = query(account: account)
        add[kSecValueData as String] = bytes
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainError(added) }
        return bytes
    }

    static func publicLine() throws -> String {
        let line = try OpenSSHKey.publicLine(seed: try seed(), comment: "com-ios-herdr")
        UserDefaults.standard.set(line, forKey: publicKeyDefaults)
        return line
    }

    /// 早先的「粘贴私钥」入口可能把电脑的主私钥存进来过，这份不再使用，清掉。
    private static func removeLegacyPastedKey() {
        SecItemDelete(query(account: legacyAccount) as CFDictionary)
    }

    private static func read(account: String) -> Data? {
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: "HerdrDeviceKey", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain 写入失败（\(status)）"])
    }
}

/// 首次信任、之后固定：主机公钥按机器记一份，局域网 / Tailscale / 公网走的是同一台机器。
enum HerdrHostPins {
    private static func key(_ machine: String) -> String { "herdr.hostkey.\(machine)" }

    static func check(machine: String) -> @Sendable (String) -> Bool {
        let defaultsKey = key(machine)
        return { seen in
            let defaults = UserDefaults.standard
            if let pinned = defaults.string(forKey: defaultsKey) { return pinned == seen }
            defaults.set(seen, forKey: defaultsKey)
            return true
        }
    }

    static func forget(machine: String) {
        UserDefaults.standard.removeObject(forKey: key(machine))
    }
}
