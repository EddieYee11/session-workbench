import Foundation
import Security
import SwiftUI
import ComCore

private enum HerdrKeychain {
    static let service = "work.eddie.herdr.token"
    static let account = "token"

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        return token
    }

    static func saveToken(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, b in b } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func deleteToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

@Observable @MainActor
public final class HeaderModel: HerdrBackend {
    public static let defaultBase = "https://pi.eddiegao.work:8443/sessions"
    private static let baseKey = "herdr.base"

    public var base: String {
        didSet {
            UserDefaults.standard.set(base, forKey: Self.baseKey)
            rebuildAPI()
        }
    }
    public var isPaired: Bool = false
    public var banner: String = ""
    public var isBusy: Bool = false

    private var api: APIClient?
    private var token: String?

    public init() {
        let savedBase = UserDefaults.standard.string(forKey: Self.baseKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBase = (savedBase != nil && !savedBase!.isEmpty) ? savedBase! : Self.defaultBase
        self.base = resolvedBase

        if let loadedToken = HerdrKeychain.loadToken() {
            self.token = loadedToken
            self.isPaired = true
            self.api = try? APIClient(base: resolvedBase, token: loadedToken)
        }
    }

    private func rebuildAPI() {
        guard let token else {
            api = nil
            return
        }
        api = try? APIClient(base: base, token: token)
    }

    public func pair(code: String) async throws {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw APIError(status: 0, detail: "请输入配对码")
        }
        isBusy = true
        defer { isBusy = false }

        let client = try APIClient(base: base, token: "")
        let data = try await client.request("/pair", body: .object(["code": .string(trimmedCode)]), auth: false)
        let receivedToken = data["token"].string
        guard !receivedToken.isEmpty else {
            throw APIError(status: 0, detail: "配对未返回凭据")
        }
        try HerdrKeychain.saveToken(receivedToken)
        self.token = receivedToken
        self.isPaired = true
        self.api = try APIClient(base: base, token: receivedToken)
        self.banner = "配对成功"
    }

    public func unpair() {
        HerdrKeychain.deleteToken()
        self.token = nil
        self.isPaired = false
        self.api = nil
        self.banner = "已解除配对"
    }

    @discardableResult
    public func mutate(_ path: String, fields: [String: JSON] = [:]) async throws -> JSON {
        guard let api else {
            throw APIError(status: 0, detail: "尚未配对或连接后端")
        }
        let requestId = UUID().uuidString.lowercased()
        let body = JSON.object(fields.merging(["request_id": .string(requestId)]) { a, _ in a })
        return try await api.request(path, body: body)
    }

    public func applyPairDeepLink(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let rawBase = items?.first(where: { $0.name == "base" })?.value ?? ""
        let rawCode = items?.first(where: { $0.name == "code" })?.value ?? ""
        let baseTrim = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeTrim = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)

        if isPaired {
            banner = "设备已配对。如需重新配对，请先解绑。"
            return
        }
        if !baseTrim.isEmpty {
            self.base = baseTrim
        }
        if !codeTrim.isEmpty {
            Task {
                do {
                    try await pair(code: codeTrim)
                } catch {
                    banner = "深链配对失败：" + error.localizedDescription
                }
            }
        }
    }
}
