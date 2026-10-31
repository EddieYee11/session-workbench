import Foundation
import Security

/// A separate Keychain group shares only counts; the widget cannot read API credentials.
struct StatusWidgetSnapshot: Codable {
    let reviewCount: Int
    let briefingCount: Int
    let updatedAt: Date
    /// 一眼文案（等你/下一步/下一档日程）；旧快照没有此字段时为空。
    var headline: String
    /// 点开深链：waiting / plan / today。
    var deepLink: String
    static let kind = "work.eddie.com.status"

    enum CodingKeys: String, CodingKey { case reviewCount, briefingCount, updatedAt, headline, deepLink }

    init(reviewCount: Int, briefingCount: Int, updatedAt: Date, headline: String = "", deepLink: String = "today") {
        self.reviewCount = reviewCount; self.briefingCount = briefingCount
        self.updatedAt = updatedAt; self.headline = headline; self.deepLink = deepLink
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewCount = try c.decode(Int.self, forKey: .reviewCount)
        briefingCount = try c.decode(Int.self, forKey: .briefingCount)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        deepLink = try c.decodeIfPresent(String.self, forKey: .deepLink) ?? "today"
    }
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
