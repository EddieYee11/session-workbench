import Foundation

public struct AttachedContextItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var kind: String // "next" | "today" | "sohu" | "drop"

    public init(id: String, title: String, summary: String, kind: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.kind = kind
    }
}

public struct LiveToolChip: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var tool: String
    public var title: String
    public var status: String // "running" | "completed" | "failed"
    public var durationMs: Int?

    public init(id: String, tool: String, title: String, status: String, durationMs: Int? = nil) {
        self.id = id
        self.tool = tool
        self.title = title
        self.status = status
        self.durationMs = durationMs
    }
}

public enum BubbleType: String, Codable, Equatable, Sendable {
    case text = "text"
    case attachment = "attachment"
    case widget = "widget"
    case secretRequest = "secret-request"

    public init(rawOrFallback raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "attachment": self = .attachment
        case "widget": self = .widget
        case "secret-request", "secret_request": self = .secretRequest
        default: self = .text
        }
    }
}

public struct BubbleImageRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var url: String
    public var scheme: String
    public var name: String
    public var mime: String
    public var size: Int
    public var artifactID: String
    public var downloadPath: String

    public init(
        id: String,
        url: String,
        scheme: String = "https",
        name: String = "",
        mime: String = "image/jpeg",
        size: Int = 0,
        artifactID: String = "",
        downloadPath: String = ""
    ) {
        self.id = id
        self.url = url
        self.scheme = scheme
        self.name = name
        self.mime = mime
        self.size = size
        self.artifactID = artifactID
        self.downloadPath = downloadPath
    }
}

public struct SendMessageBubble: Equatable, Sendable {
    public var type: BubbleType
    public var payload: JSON
    public var content: String
    public var images: [BubbleImageRef]
    public var suggestions: [String]
    // Attachment fields
    public var url: String
    public var scheme: String
    public var caption: String
    public var name: String
    public var mime: String
    public var size: Int
    public var sha256: String
    public var artifactID: String
    public var downloadPath: String
    // Widget fields
    public var blocking: Bool
    public var widget: JSON
    // Secret-request fields
    public var secretName: String
    public var reason: String
    public var targetEnv: String
    public var placeholder: String
    public var masked: Bool

    public static func parse(from message: JSON) -> SendMessageBubble {
        let decodedPayload = Self.extractPayload(from: message)
        let explicitType = message["bubble_type"].string
        let payloadType = decodedPayload["type"].string
        let resolvedType = BubbleType(rawOrFallback: explicitType.isEmpty ? payloadType : explicitType)

        let fallbackText = message["text"].string
        let rawContent = decodedPayload["content"].string
        let content: String = {
            switch resolvedType {
            case .text:
                return rawContent.isEmpty ? fallbackText : rawContent
            case .widget:
                return rawContent
            case .attachment, .secretRequest:
                return ""
            }
        }()

        let parsedImages: [BubbleImageRef] = decodedPayload["images"].array.enumerated().compactMap { idx, item in
            if case .string(let str) = item, !str.isEmpty {
                let scheme = str.lowercased().hasPrefix("file://") ? "file" : "https"
                let name = URL(string: str)?.lastPathComponent ?? "图片 \(idx + 1)"
                return BubbleImageRef(id: "\(idx):\(str)", url: str, scheme: scheme, name: name)
            }
            let url = item["url"].string
            let dl = item["download_path"].string
            let artID = item["artifact_id"].string
            guard !url.isEmpty || !dl.isEmpty || !artID.isEmpty else { return nil }
            let scheme = item["scheme"].string.isEmpty
                ? (url.lowercased().hasPrefix("file://") ? "file" : "https")
                : item["scheme"].string
            let name = item["name"].string.isEmpty ? "图片 \(idx + 1)" : item["name"].string
            let mime = item["mime"].string.isEmpty ? "image/jpeg" : item["mime"].string
            return BubbleImageRef(
                id: artID.isEmpty ? "\(idx):\(url)" : artID,
                url: url,
                scheme: scheme,
                name: name,
                mime: mime,
                size: item["size"].int,
                artifactID: artID,
                downloadPath: dl
            )
        }

        let payloadSuggestions = decodedPayload["suggestions"].array.map(\.string).filter { !$0.isEmpty }
        let messageSuggestions = message["suggestions"].array.map(\.string).filter { !$0.isEmpty }
        let suggestions = payloadSuggestions.isEmpty ? messageSuggestions : payloadSuggestions

        let firstArtifact = message["artifacts"].array.first ?? .null
        let url = decodedPayload["url"].string
        let scheme = decodedPayload["scheme"].string.isEmpty
            ? (url.lowercased().hasPrefix("https://") ? "https" : (url.lowercased().hasPrefix("file://") ? "file" : ""))
            : decodedPayload["scheme"].string
        let name: String = {
            if !decodedPayload["name"].string.isEmpty { return decodedPayload["name"].string }
            if !firstArtifact["name"].string.isEmpty { return firstArtifact["name"].string }
            if let parsedURL = URL(string: url), !parsedURL.lastPathComponent.isEmpty, parsedURL.lastPathComponent != "/" {
                return parsedURL.lastPathComponent
            }
            return "附件"
        }()
        let caption = decodedPayload["caption"].string
        let mime = decodedPayload["mime"].string.isEmpty ? firstArtifact["mime"].string : decodedPayload["mime"].string
        let size = decodedPayload["size"].int != 0 ? decodedPayload["size"].int : firstArtifact["size"].int
        let sha256 = decodedPayload["sha256"].string
        let artifactID = decodedPayload["artifact_id"].string.isEmpty ? firstArtifact["id"].string : decodedPayload["artifact_id"].string
        let downloadPath = decodedPayload["download_path"].string.isEmpty ? firstArtifact["download_path"].string : decodedPayload["download_path"].string

        let widgetObj: JSON = {
            if case .object = decodedPayload["widget"] { return decodedPayload["widget"] }
            if let firstWidget = message["widgets"].array.first, case .object = firstWidget { return firstWidget }
            return .object([:])
        }()
        let blocking: Bool = {
            if case .bool(let b) = decodedPayload["blocking"] { return b }
            if case .bool(let b) = widgetObj["blocking"] { return b }
            return true
        }()

        let secretName = decodedPayload["secret_name"].string
        let reason = decodedPayload["reason"].string
        let targetEnv = decodedPayload["target_env"].string
        let placeholder = decodedPayload["placeholder"].string
        let masked: Bool = {
            if case .bool(let m) = decodedPayload["masked"] { return m }
            return true
        }()

        return SendMessageBubble(
            type: resolvedType,
            payload: decodedPayload,
            content: content,
            images: parsedImages,
            suggestions: suggestions,
            url: url,
            scheme: scheme,
            caption: caption,
            name: name,
            mime: mime,
            size: size,
            sha256: sha256,
            artifactID: artifactID,
            downloadPath: downloadPath,
            blocking: blocking,
            widget: widgetObj,
            secretName: secretName,
            reason: reason,
            targetEnv: targetEnv,
            placeholder: placeholder,
            masked: masked
        )
    }

    private static func extractPayload(from message: JSON) -> JSON {
        if case .object = message["bubble"] {
            return message["bubble"]
        }
        if case .object = message["bubble_payload"] {
            return message["bubble_payload"]
        }
        if case .string(let raw) = message["bubble_payload"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = raw.data(using: .utf8),
           let parsed = try? JSON.decode(data),
           case .object = parsed {
            return parsed
        }
        return .object([
            "type": .string("text"),
            "content": .string(message["text"].string)
        ])
    }
}

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

    public mutating func replaceChannelSnapshot(_ data: JSON) {
        messages = Self.merge([], data["messages"].array)
        tasks = data["tasks"].array
        runs = data["runs"].array
        revision = data["revision"].int
    }

    public mutating func prependHistory(_ page: JSON) { messages = Self.merge(messages, page["messages"].array) }
    public static func merge(_ old: [JSON], _ new: [JSON]) -> [JSON] {
        var rows = Dictionary(old.filter { !$0.id.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
    public init(text: String, path: String = "/personal/conversation/messages", extra: [String: JSON] = [:], requestID: String? = nil) {
        id = requestID ?? UUID().uuidString.lowercased(); self.text = text; self.path = path
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
