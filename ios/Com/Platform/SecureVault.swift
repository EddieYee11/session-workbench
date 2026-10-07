import Foundation
import Security
import CryptoKit
import ComCore

enum SecureVault {
    static let service = "work.eddie.com"
    static var directory: URL {
        let p = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Com", isDirectory: true)
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = p
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try? url.setResourceValues(resources)
        return p
    }
    static func secret(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    static func storeSecret(_ data: Data, account: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound { result = SecItemAdd(q.merging(attributes) { _, b in b } as CFDictionary, nil) }
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
    static func deleteSecret(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
    static func records(prefix: String) -> [JSON] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sealed" }.compactMap { try? load(JSON.self, name: $0.deletingPathExtension().lastPathComponent) }
    }
    static func operationRecords() -> [JSON] { records(prefix: "operation-") }
    private static func key() throws -> SymmetricKey {
        if let data = secret("cache-key") { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try storeSecret(key.withUnsafeBytes { Data($0) }, account: "cache-key"); return key
    }
    static func save<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        let sealed = try AES.GCM.seal(data, using: key())
        try sealed.combined!.write(to: directory.appendingPathComponent(name + ".sealed"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let p = directory.appendingPathComponent(name + ".sealed")
        guard FileManager.default.fileExists(atPath: p.path) else { return nil }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: p))
        return try JSONDecoder().decode(type, from: AES.GCM.open(sealed, using: key()))
    }
}
