import Foundation

/// Forward-compatible values: the existing API evolves without losing source fields.
public enum JSON: Codable, Sendable, Equatable, Hashable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSON {
        get { if case .object(let o) = self { return o[key] ?? .null }; return .null }
        set { var o = object; o[key] = newValue; self = .object(o) }
    }
    public var object: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
    public var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    public var string: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return v.rounded() == v ? String(format: "%.0f", v) : String(v)
        case .bool(let v): return v ? "true" : "false"
        default: return ""
        }
    }
    public var double: Double { if case .number(let v) = self { return v }; return Double(string) ?? 0 }
    public var int: Int { Int(double) }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
    public var isNull: Bool { self == .null }
    public var id: String { self["id"].string }
    public var pretty: String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: e.encode(self), encoding: .utf8)) ?? ""
    }
    public static func decode(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
}

public extension String {
    var pathEncoded: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    var queryEncoded: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
}

public struct RemoteRow: Identifiable, Sendable, Hashable {
    public let value: JSON
    public var id: String { value.id }
    public init(_ value: JSON) { self.value = value }
}
