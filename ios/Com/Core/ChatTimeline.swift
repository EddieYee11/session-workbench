import Foundation

/// A receipt must replace its local row without dropping or duplicating it.
/// Identity is request-based, never text-based: identical sends can be distinct.
public struct ChatTimelineRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let message: JSON
    public let pending: PendingMessage?
}
public enum ChatTimeline {
    public static func rows(messages: [JSON], pending: [PendingMessage]) -> [ChatTimelineRow] {
        let requests = Set(messages.filter { $0["role"].string == "user" }.map { $0["request_id"].string }.filter { !$0.isEmpty })
        var result = messages.map { message in
            let request = message["request_id"].string
            return ChatTimelineRow(id: message["role"].string == "user" && !request.isEmpty ? "request:" + request : message.id, message: message, pending: nil)
        }
        for entry in pending where entry.path == "/personal/conversation/messages" && !requests.contains(entry.id) {
            let attachments = entry.body["attachment_ids"].array.enumerated().map { index, value in
                JSON.object(["id": value, "name": .string("附件 \(index + 1)")])
            }
            let message = JSON.object(["id": .string("request:" + entry.id), "role": .string("user"), "text": .string(entry.text),
                "created_at": .number(entry.createdAt.timeIntervalSince1970), "reference": entry.body["reference"], "attachments": .array(attachments)])
            result.append(ChatTimelineRow(id: "request:" + entry.id, message: message, pending: entry))
        }
        return result.sorted {
            let a = $0.message["created_at"].double, b = $1.message["created_at"].double
            return a == b ? $0.id < $1.id : a < b
        }
    }
}
