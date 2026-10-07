import Foundation
import ComCore

enum CoreChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    static func run() throws -> Int {
        var checks = 0
        // Real SSE frames split at every byte boundary, including UTF-8 and CRLF.
        let frame = Data(": heartbeat\r\nid: 27\r\nevent: update\r\ndata: {\"text\":\"你好🦀\"}\r\ndata: second\r\n\r\n".utf8)
        for split in 0...frame.count {
            var parser = SSEParser()
            let events = parser.feed(frame.prefix(split)) + parser.feed(frame.suffix(frame.count - split))
            try require(events.count == 1, "SSE frame lost at split \(split)")
            try require(events[0].id == "27" && events[0].name == "update", "SSE identity lost")
            try require(events[0].data == "{\"text\":\"你好🦀\"}\nsecond", "SSE UTF-8/multiline damaged")
            checks += 1
        }
        func row(_ id: String, _ revision: Int, _ text: String, _ at: Double) -> JSON { .object(["id": .string(id), "revision": .number(Double(revision)), "text": .string(text), "created_at": .number(at)]) }
        var state = ConversationState()
        state.prependHistory(.object(["messages": .array([row("old", 1, "older history", 1)])]))
        state.apply(.object(["revision": .number(10), "messages": .array([row("new", 10, "stream", 2)]), "tasks": .array([row("task", 1, "running", 2)])]), snapshot: true)
        state.apply(.object(["revision": .number(9), "messages": .array([row("new", 9, "stale", 2)])]), snapshot: true)
        try require(state.messages.count == 2 && state.messages.last?["text"].string == "stream", "Reconnection discarded history or rewound reply")
        state.apply(.object(["revision": .number(11), "messages": .array([row("new", 11, "complete", 2)]), "changed_tasks": .array([row("task", 2, "done", 2)])]), snapshot: false)
        try require(state.tasks.count == 1 && state.tasks[0]["text"].string == "done", "Task update duplicated a card")
        try require(state.messages.count == 2, "Streaming updates duplicated messages")
        let restored = try JSONDecoder().decode(ConversationState.self, from: JSONEncoder().encode(state))
        try require(restored == state, "Restart lost cached state")
        var entry = PendingMessage(text: "please do this once", extra: ["attachment_ids": .array([.string("file")])])
        entry.state = .checking
        var reopened = try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(entry))
        reopened.recoverAfterRestart()
        try require(reopened.id == entry.id && reopened.body == entry.body && reopened.state == .uncertain, "Restart recreated an operation or lost its attachments")
        try require(reopened.receiptPath.hasSuffix(entry.id.pathEncoded), "Recovery did not query original request")
        let work = PendingMessage(text: "work", path: "/sessions", extra: ["prompt": .string("work")])
        try require(work.receiptPath == "/receipts/" + work.id.pathEncoded, "Work receipt routed incorrectly")
        let api = try APIClient(base: "https://example.invalid/sessions", token: "fixture-only")
        let request = try api.makeRequest("/personal/conversation/messages", body: reopened.body)
        try require(request.httpMethod == "POST" && request.url?.path == "/sessions/personal/conversation/messages", "Proxy prefix lost")
        try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only", "Bearer missing")
        for base in ["http://example.invalid", "https://user:pass@example.invalid", "https://example.invalid?token=a"] {
            do { _ = try APIClient(base: base, token: ""); throw Failure(description: "Unsafe base accepted") } catch is APIError { checks += 1 }
        }
        do { _ = try api.makeRequest("//attacker.invalid"); throw Failure(description: "Off-origin path accepted") } catch is APIError { checks += 1 }
        let anonymous = try api.makeRequest("/pair", auth: false)
        try require(anonymous.value(forHTTPHeaderField: "Authorization") == nil, "Pairing leaked prior credentials")
        return checks + 10
    }
}
