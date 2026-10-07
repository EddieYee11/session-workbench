import Foundation

public struct ConversationState: Codable, Sendable, Equatable {
    public var revision = 0
    public var messages: [JSON] = []
    public var tasks: [JSON] = []
    public var runs: [JSON] = []
    public init() {}

    public mutating func apply(_ data: JSON, snapshot: Bool) {
        let next = data["revision"].int
        guard next >= revision else { return }
        // A fresh snapshot must not discard separately loaded older pages.
        messages = Self.merge(messages, data["messages"].array)
        tasks = snapshot ? data["tasks"].array : Self.merge(tasks, data["changed_tasks"].array)
        runs = data["runs"].array
        revision = next
    }
    public mutating func prependHistory(_ page: JSON) { messages = Self.merge(messages, page["messages"].array) }
    public static func merge(_ old: [JSON], _ new: [JSON]) -> [JSON] {
        var rows = Dictionary(old.filter { !$0.id.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for row in new where !row.id.isEmpty {
            if let previous = rows[row.id], previous["revision"].int > row["revision"].int { continue }
            rows[row.id] = row
        }
        return rows.values.sorted {
            let a = $0["created_at"].double, b = $1["created_at"].double
            return a == b ? $0.id < $1.id : a < b
        }
    }
}

public enum DeliveryState: String, Codable, Sendable { case queued, checking, uncertain, rejected, delivered }

public struct PendingMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var path: String
    public var body: JSON
    public var state: DeliveryState
    public var note: String
    public var createdAt: Date
    public init(text: String, path: String = "/personal/conversation/messages", extra: [String: JSON] = [:]) {
        id = UUID().uuidString.lowercased(); self.text = text; self.path = path
        body = .object(extra.merging(["request_id": .string(id), "text": .string(text)]) { _, b in b })
        state = .queued; note = "等待发送"; createdAt = Date()
    }
    public var receiptPath: String {
        if path == "/personal/quick-voice/messages" { return "/personal/quick-voice/receipts/" + id.pathEncoded }
        if path == "/personal/conversation/messages" { return "/personal/conversation/receipts/" + id.pathEncoded }
        return "/receipts/" + id.pathEncoded
    }
    public mutating func recoverAfterRestart() {
        if state == .checking { state = .uncertain; note = "上次送达待核实，先查询回执" }
    }
}
