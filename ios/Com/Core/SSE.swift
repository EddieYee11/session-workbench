import Foundation

public struct SSEEvent: Sendable, Equatable {
    public var id: String = ""
    public var name: String = "message"
    public var data: String = ""
    public init() {}
}

/// Parses bytes rather than chunks of String so split UTF-8 scalars remain intact.
public struct SSEParser: Sendable {
    public static let reconnectSchedule: [Double] = [0.5, 1.0, 2.0, 5.0]
    public static func reconnectDelay(attempt: Int) -> Double {
        let index = max(0, min(reconnectSchedule.count - 1, attempt - 1))
        return reconnectSchedule[index]
    }

    private var buffer = Data()
    private var event = SSEEvent()
    private var lines: [String] = []
    public private(set) var lastEventID: String = ""
    public init() {}
    public mutating func feed(_ bytes: Data) -> [SSEEvent] {
        buffer.append(bytes)
        var result: [SSEEvent] = []
        while let end = buffer.firstIndex(of: 10) {
            var line = buffer.subdata(in: buffer.startIndex..<end)
            buffer.removeSubrange(buffer.startIndex...end)
            if line.last == 13 { line.removeLast() }
            if let item = consume(String(decoding: line, as: UTF8.self)) { result.append(item) }
        }
        return result
    }
    public mutating func consume(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { event = SSEEvent(); lines = [] }
            guard !lines.isEmpty else { return nil }
            if event.id.isEmpty && !lastEventID.isEmpty {
                event.id = lastEventID
            }
            event.data = lines.joined(separator: "\n"); return event
        }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts[0]); var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch key {
        case "id":
            if !value.contains("\0") {
                lastEventID = value
                event.id = value
            }
        case "event": event.name = value
        case "data": lines.append(value)
        default: break
        }
        return nil
    }
}
