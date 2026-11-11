import SwiftUI
import ComCore

@MainActor
public protocol HerdrBackend: AnyObject, Sendable {
    @discardableResult
    func mutate(_ path: String, fields: [String: JSON]) async throws -> JSON
}

private struct HerdrBackendKey: EnvironmentKey {
    static let defaultValue: (any HerdrBackend)? = nil
}

extension EnvironmentValues {
    public var herdrBackend: (any HerdrBackend)? {
        get { self[HerdrBackendKey.self] }
        set { self[HerdrBackendKey.self] = newValue }
    }
}
