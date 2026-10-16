import Foundation
import Security

/// A separate Keychain group shares only counts; the widget cannot read API credentials.
struct StatusWidgetSnapshot: Codable {
    let reviewCount: Int
    let briefingCount: Int
    let updatedAt: Date
    static let kind = "work.eddie.com.status"
    private static var query: [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ComWidgetAccessGroup") as? String,
              !group.contains("$(") else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: kind,
                kSecAttrAccount as String: "counts", kSecAttrAccessGroup as String: group]
    }
    static func read() -> Self? {
        guard var query else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    static func clear() { if let query { SecItemDelete(query as CFDictionary) } }
    func save() -> Bool {
        guard var query = Self.query, let data = try? JSONEncoder().encode(self) else { return false }
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        query.merge(values) { _, new in new }
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
