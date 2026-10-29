import Foundation
import Security
import CryptoKit
import ComCore

struct AppCacheSnapshot: Sendable {
    let conversation: ConversationState
    let datasets: [String: JSON]
    let timestamps: [String: Date]
    let draft: String
    let attachments: [JSON]
}

/// Serialization, encryption and disk IO run on this actor, never the UI actor.
/// The outbox is deliberately excluded: its write-before-send barrier is synchronous.
actor AppCacheWriter {
    private var savedRevision = 0
    func save(_ snapshot: AppCacheSnapshot, revision: Int) throws {
        guard revision > savedRevision else { return }
        try SecureVault.save(snapshot.conversation, name: "conversation")
        try SecureVault.save(snapshot.datasets, name: "datasets")
        try SecureVault.save(snapshot.timestamps, name: "timestamps")
        try SecureVault.save(snapshot.draft, name: "draft")
        try SecureVault.save(snapshot.attachments, name: "draft-attachments")
        savedRevision = revision
    }
}

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
    /// 目录可读时返回条目；decode 失败条数单独计，避免「有文件却像空」假空态。
    struct RecordsLoad: Sendable {
        var items: [JSON]
        var decodeFailures: Int
        var directoryError: String?
    }
    static func loadRecords(prefix: String) -> RecordsLoad {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            return RecordsLoad(items: [], decodeFailures: 0, directoryError: error.localizedDescription)
        }
        let sealed = files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sealed" }
        var items: [JSON] = []
        var failed = 0
        for url in sealed {
            let name = url.deletingPathExtension().lastPathComponent
            if let row = try? load(JSON.self, name: name) {
                items.append(row)
            } else {
                failed += 1
            }
        }
        return RecordsLoad(items: items, decodeFailures: failed, directoryError: nil)
    }
    static func records(prefix: String) -> [JSON] { loadRecords(prefix: prefix).items }
    static func operationRecords() -> [JSON] { records(prefix: "operation-") }
    private static let keyLock = NSLock()
    private static func key() throws -> SymmetricKey {
        keyLock.lock(); defer { keyLock.unlock() }
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
