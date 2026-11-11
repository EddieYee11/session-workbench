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
        // Voice streaming: partials land while the user is still speaking, the final
        // closes the utterance, and audio leaves as clamped 16 kHz little-endian PCM.
        try require(VoiceStream.event(from: Data(#"{"type":"partial","text":"记账","definite":false}"#.utf8)) == .partial("记账"), "Partial transcript lost")
        try require(VoiceStream.event(from: Data(#"{"type":"final","text":"记账，午饭35。","definite":true}"#.utf8)) == .final("记账，午饭35。"), "Final transcript lost")
        try require(VoiceStream.event(from: Data(#"{"type":"error","message":"录音太短"}"#.utf8)) == .failure("录音太短"), "Error frame lost")
        try require(VoiceStream.event(from: Data(#"{"type":"error"}"#.utf8)) == .failure("语音识别中断"), "Bare error frame lost its fallback text")
        try require(VoiceStream.event(from: Data("not json".utf8)) == nil, "Garbage frame accepted")
        try require(VoiceStream.event(from: Data(#"{"type":"partial"}"#.utf8)) == .partial(""), "Empty partial rejected")
        try require(VoiceStream.event(from: Data(VoiceStream.end.utf8)) == nil, "End frame echoed back as a transcript")
        let pcm = VoiceStream.pcm16([0, 0.5, -1, 1, 4, -4])
        try require(pcm.count == 12, "PCM width wrong")
        try require(Array(pcm[0..<2]) == [0x00, 0x00], "Silence encoded wrong")
        try require(Array(pcm[2..<4]) == [0xFF, 0x3F], "0.5 encoded wrong")
        try require(Array(pcm[4..<6]) == [0x01, 0x80], "-1 encoded wrong")
        try require(Array(pcm[6..<8]) == [0xFF, 0x7F], "+1 encoded wrong")
        try require(Array(pcm[8..<10]) == [0xFF, 0x7F] && Array(pcm[10..<12]) == [0x01, 0x80], "Out-of-range samples wrapped instead of clamping")

        // SSE cursor retention, backoff schedule (0.5 -> 1 -> 2 -> 5), and Last-Event-ID request header.
        try require(SSEParser.reconnectDelay(attempt: 1) == 0.5, "Attempt 1 backoff should be 0.5s")
        try require(SSEParser.reconnectDelay(attempt: 2) == 1.0, "Attempt 2 backoff should be 1.0s")
        try require(SSEParser.reconnectDelay(attempt: 3) == 2.0, "Attempt 3 backoff should be 2.0s")
        try require(SSEParser.reconnectDelay(attempt: 4) == 5.0 && SSEParser.reconnectDelay(attempt: 9) == 5.0, "Backoff cap should clamp at 5.0s")
        var idParser = SSEParser()
        let idEvents = idParser.feed(Data("id: 41\n\nevent: tool.started\ndata: {\"tool\":\"search\"}\n\n".utf8))
        try require(idParser.lastEventID == "41" && idEvents.count == 1 && idEvents[0].id == "41", "SSEParser did not retain lastEventID across frames")
        let streamReq = try api.makeStreamRequest(after: 41, lastEventID: "evt-42")
        try require(streamReq.value(forHTTPHeaderField: "Last-Event-ID") == "evt-42", "Stream request dropped explicit Last-Event-ID")
        try require(streamReq.url?.query?.contains("after=41") == true, "Stream request missing after query cursor")
        checks += 7

        // Shared contracts: AttachedContextItem & LiveToolChip Codable round-trips.
        let ctxItem = AttachedContextItem(id: "m1", title: "周报核对", summary: "周五前交", kind: "next")
        let decodedCtx = try JSONDecoder().decode(AttachedContextItem.self, from: JSONEncoder().encode(ctxItem))
        try require(decodedCtx == ctxItem, "AttachedContextItem round-trip failed")
        let toolChip = LiveToolChip(id: "t1", tool: "calendar_list", title: "查询日历", status: "completed", durationMs: 184)
        let decodedChip = try JSONDecoder().decode(LiveToolChip.self, from: JSONEncoder().encode(toolChip))
        try require(decodedChip == toolChip && decodedChip.durationMs == 184, "LiveToolChip round-trip failed")
        checks += 2

        // SendMessage 4-type bubble parsing + legacy fallback + JSON-string bubble_payload compatibility.
        let legacyMsg: JSON = .object(["id": .string("m_leg"), "role": .string("assistant"), "text": .string("普通旧消息")])
        let legacyBubble = SendMessageBubble.parse(from: legacyMsg)
        try require(legacyBubble.type == .text && legacyBubble.content == "普通旧消息", "Legacy text fallback broken")

        let attachMsg: JSON = .object([
            "id": .string("m_att"),
            "role": .string("assistant"),
            "bubble_type": .string("attachment"),
            "bubble_payload": .string(#"{"type":"attachment","url":"file:///tmp/weekly.pdf","scheme":"file","caption":"周报已生成","name":"weekly.pdf","mime":"application/pdf","size":84210,"artifact_id":"art_99","download_path":"/personal/artifacts/art_99"}"#)
        ])
        let attachBubble = SendMessageBubble.parse(from: attachMsg)
        try require(attachBubble.type == .attachment && attachBubble.name == "weekly.pdf" && attachBubble.artifactID == "art_99" && attachBubble.caption == "周报已生成", "Attachment bubble_payload string parse failed")

        let stagingMsg: JSON = .object([
            "id": .string("m_stg"),
            "role": .string("assistant"),
            "bubble_type": .string("widget"),
            "bubble": .object([
                "type": .string("widget"),
                "content": .string("已填好劳务单，请复核"),
                "blocking": .bool(true),
                "widget": .object([
                    "kind": .string("staging_review"),
                    "title": .string("搜狐劳务报酬待提交"),
                    "summary": .string("实收 ¥1,500 · 已停在提交按钮前"),
                    "action_type": .string("labor_submit"),
                    "confirm_label": .string("打开页面我去点"),
                    "cancel_label": .string("打回重改"),
                    "target_url": .string("https://pr.sohu.com/review/1")
                ])
            ])
        ])
        let stagingBubble = SendMessageBubble.parse(from: stagingMsg)
        try require(stagingBubble.type == .widget && stagingBubble.widget["kind"].string == "staging_review" && stagingBubble.blocking, "Staging widget bubble parse failed")

        let secretMsg: JSON = .object([
            "id": .string("m_sec"),
            "role": .string("assistant"),
            "bubble_type": .string("secret-request"),
            "bubble": .object([
                "type": .string("secret-request"),
                "secret_name": .string("SOHU_COOKIE"),
                "reason": .string("用于拉取关注流后台统计"),
                "target_env": .string("sohu"),
                "masked": .bool(true)
            ])
        ])
        let secretBubble = SendMessageBubble.parse(from: secretMsg)
        try require(secretBubble.type == .secretRequest && secretBubble.secretName == "SOHU_COOKIE" && secretBubble.masked, "Secret-request bubble parse failed")
        checks += 4

        // Multi-bubble ChatTimeline.answering deduplication + message_seq ordering.
        func chatRow(_ id: String, role: String, text: String, seq: Int, parent: String = "") -> JSON {
            .object([
                "id": .string(id),
                "role": .string(role),
                "text": .string(text),
                "message_seq": .number(Double(seq)),
                "created_at": .number(Double(1_794_356_400 + seq)),
                "parent_id": .string(parent)
            ])
        }
        let directTimeline = ChatTimeline.rows(messages: [
            chatRow("u1", role: "user", text: "帮我查今天日程", seq: 1),
            chatRow("a1", role: "assistant", text: "收到，先查日历", seq: 2, parent: "u1"),
            chatRow("a2", role: "assistant", text: "已找到 3 个会议", seq: 3, parent: "u1"),
            chatRow("a3", role: "assistant", text: "下午三点有选题会", seq: 4, parent: "u1")
        ], pending: [])
        try require(directTimeline.allSatisfy { $0.message["answering"].string.isEmpty }, "Consecutive bubbles directly under parent should not show answering chip")

        let interleavedTimeline = ChatTimeline.rows(messages: [
            chatRow("u1", role: "user", text: "查日程", seq: 10),
            chatRow("u2", role: "user", text: "顺便记午饭35", seq: 11),
            chatRow("a1", role: "assistant", text: "先查日程", seq: 12, parent: "u1"),
            chatRow("a2", role: "assistant", text: "日程查完了", seq: 13, parent: "u1"),
            chatRow("b1", role: "assistant", text: "午饭35已记账", seq: 14, parent: "u2"),
            chatRow("a3", role: "assistant", text: "补充：晚上无安排", seq: 15, parent: "u1")
        ], pending: [])
        try require(interleavedTimeline[2].message["answering"].string == "查日程", "First bubble after interleaved user msg must carry answering")
        try require(interleavedTimeline[3].message["answering"].string.isEmpty, "Second consecutive bubble of same parent must NOT repeat answering")
        try require(interleavedTimeline[4].message["answering"].string == "顺便记午饭35", "First bubble of u2 after u1 bubbles must carry answering")
        try require(interleavedTimeline[5].message["answering"].string == "查日程", "Re-interleaved bubble after another turn must re-attach answering")

        state.replaceChannelSnapshot(.object(["revision": .number(11), "messages": .array([row("work_1", 11, "工作频道消息", 5)])]))
        try require(state.messages.count == 1 && state.messages[0].id == "work_1", "Channel switch snapshot did not isolate channel messages")
        checks += 6

        return checks + 12
    }
}
