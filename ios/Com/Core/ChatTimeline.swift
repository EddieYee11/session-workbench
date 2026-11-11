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
        let sorted = result.sorted {
            if $0.pending == nil && $1.pending == nil {
                let sA = $0.message["message_seq"].int
                let seqA = sA != 0 ? sA : $0.message["seq"].int
                let sB = $1.message["message_seq"].int
                let seqB = sB != 0 ? sB : $1.message["seq"].int
                if seqA > 0 && seqB > 0 && seqA != seqB {
                    return seqA < seqB
                }
            }
            let a = $0.message["created_at"].double, b = $1.message["created_at"].double
            if a != b { return a < b }
            return $0.id < $1.id
        }
        return answering(sorted)
    }

    /// 并行（10-28）：一条回复前面隔着别的消息时，给它带上 answering = 原问题，界面上标「回复：…」。
    /// 多气泡模式（11-11）：同一 parent_id 连续发出的 assistant 气泡只在首条（或真正跨轮交错后）挂一次，不重复刷标签。
    static func answering(_ rows: [ChatTimelineRow]) -> [ChatTimelineRow] {
        let questions = Dictionary(rows.filter { $0.message["role"].string == "user" }.map { ($0.message.id, $0.message["text"].string) }, uniquingKeysWith: { first, _ in first })
        return rows.enumerated().map { index, row in
            let parent = row.message["parent_id"].string
            guard row.message["role"].string == "assistant", !parent.isEmpty, let question = questions[parent],
                  index > 0 else { return row }
            let previous = rows[index - 1].message
            let followsParentDirectly = previous.id == parent
            let followsSameTurnBubble = previous["role"].string == "assistant" && previous["parent_id"].string == parent
            guard !followsParentDirectly, !followsSameTurnBubble,
                  case .object(var fields) = row.message else { return row }
            fields["answering"] = .string(question)
            return ChatTimelineRow(id: row.id, message: .object(fields), pending: row.pending)
        }
    }
}


/// 长会话的页：按字符预算取最近的若干行，最少 4 条、最多 60 条。
/// 与 Redde 的 TranscriptPage 同一思路——内存和每次流式重排的成本跟着页面内容走，而不是条数。
public enum ChatPage {
    public static let standardBudget = 30_000
    public static let minimumRows = 4
    public static let maximumRows = 60

    public static func weight(of row: ChatTimelineRow) -> Int {
        row.message["text"].string.utf8.count + 250 + row.message["attachments"].array.count * 1_500
    }

    public static func weight(of rows: [ChatTimelineRow]) -> Int { rows.reduce(0) { $0 + weight(of: $1) } }

    public static func window(_ rows: [ChatTimelineRow], budget: Int = standardBudget) -> [ChatTimelineRow] {
        guard rows.count > minimumRows else { return rows }
        var used = 0, count = 0
        for row in rows.reversed() {
            used += weight(of: row); count += 1
            if count >= maximumRows { break }
            if used >= budget && count >= minimumRows { break }
        }
        return Array(rows.suffix(count))
    }
}

/// 一行真正要画的东西。折叠进主动消息堆的行不再占位，日期条也是一行，列表层只管摆放。
public struct ChatDisplayRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case day(String)
        case time(String)
        case message(ChatTimelineRow, consecutiveAgent: Bool)
        case proactiveStack([ChatTimelineRow])
    }
    public let id: String
    public let kind: Kind

    /// 这一行是否画了某条消息（跳转定位用：消息可能折在主动消息堆里）。
    public func contains(messageID: String) -> Bool {
        switch kind {
        case .day, .time: return false
        case .message(let row, _): return row.message.id == messageID || row.id == messageID
        case .proactiveStack(let run): return run.contains { $0.message.id == messageID || $0.id == messageID }
        }
    }
}

public enum ChatDisplay {
    /// 顺口提醒（metadata.kind=nudge）：与普通助理消息同气泡，不加卡片框或标签。
    public static func isNudge(_ message: JSON) -> Bool {
        if message["metadata"]["kind"].string == "nudge" || message["kind"].string == "nudge" { return true }
        let rawMeta = message["metadata"].string
        if !rawMeta.isEmpty, let data = rawMeta.data(using: .utf8), let parsed = try? JSON.decode(data), parsed["kind"].string == "nudge" {
            return true
        }
        return false
    }

    /// 后台主动写进对话的助手消息（回执通道的 request_id 都以此开头）。
    public static func isProactive(_ message: JSON) -> Bool {
        message["role"].string == "assistant" && !isNudge(message) && message["request_id"].string.hasPrefix("task-result:")
    }

    /// 带附件或互动内容的主动消息要能直接点，不折进堆里。
    static func isFoldable(_ message: JSON) -> Bool {
        let btype = message["bubble_type"].string
        let isInteractiveBubble = btype == "attachment" || btype == "widget" || btype == "secret-request"
        return isProactive(message) && !isInteractiveBubble && message["artifacts"].array.isEmpty && message["widgets"].array.isEmpty
    }

    /// 早于这个时间戳的是测试夹具的小序号，不当真实日期。
    private static let earliestRealDate = 1_000_000_000.0
    /// 相邻两条消息间隔 ≥ 10 分钟时插时间分隔。
    private static let timeSeparatorThreshold = 600.0

    public static func formatTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "H:mm"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "昨天 HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }

    public static func rows(_ rows: [ChatTimelineRow], calendar: Calendar = .current, now: Date = Date()) -> [ChatDisplayRow] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日 EEE"
        var out: [ChatDisplayRow] = []
        out.reserveCapacity(rows.count + 16)
        var seenIDs = Set<String>()
        func uniqueID(_ base: String, fallbackIndex: Int) -> String {
            if seenIDs.insert(base).inserted { return base }
            var candidate = "\(base)#\(fallbackIndex)"
            var suffix = fallbackIndex + 1
            while !seenIDs.insert(candidate).inserted {
                candidate = "\(base)#\(suffix)"
                suffix += 1
            }
            return candidate
        }
        var lastDay: DateComponents?
        var lastStamp: Double?
        var index = 0
        while index < rows.count {
            let row = rows[index]
            let stamp = row.message["created_at"].double
            if stamp >= earliestRealDate {
                let date = Date(timeIntervalSince1970: stamp)
                let day = calendar.dateComponents([.year, .month, .day], from: date)
                if day != lastDay {
                    lastDay = day
                    let dayID = uniqueID("day:\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)", fallbackIndex: index)
                    out.append(ChatDisplayRow(id: dayID, kind: .day(formatter.string(from: date))))
                }
                if let prev = lastStamp, stamp - prev >= timeSeparatorThreshold {
                    let timeID = uniqueID("time:\(row.id)", fallbackIndex: index)
                    out.append(ChatDisplayRow(id: timeID, kind: .time(formatTime(date, now: now, calendar: calendar))))
                }
            }
            // 连续主动消息：除最新一条外折成一堆，最新那条照常显示。
            if isFoldable(row.message) {
                var end = index
                while end + 1 < rows.count, isFoldable(rows[end + 1].message) { end += 1 }
                if end > index {
                    let run = Array(rows[index..<end])
                    out.append(ChatDisplayRow(id: uniqueID("stack:" + row.id, fallbackIndex: index), kind: .proactiveStack(run)))
                    if let lastInRun = run.last {
                        let s = lastInRun.message["created_at"].double
                        if s >= earliestRealDate { lastStamp = s }
                    }
                    index = end
                    continue
                }
            }
            if stamp >= earliestRealDate {
                lastStamp = stamp
            }
            let previousIsAgent = index > 0 && rows[index - 1].message["role"].string == "assistant"
            let isAgent = row.message["role"].string == "assistant"
            out.append(ChatDisplayRow(id: uniqueID(row.id, fallbackIndex: index), kind: .message(row, consecutiveAgent: isAgent && previousIsAgent)))
            index += 1
        }
        return out
    }
}
