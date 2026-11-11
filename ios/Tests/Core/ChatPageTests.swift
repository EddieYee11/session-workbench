import XCTest
@testable import ComCore

final class ChatPageTests: XCTestCase {
    private func row(_ index: Int, characters: Int = 100) -> ChatTimelineRow {
        ChatTimelineRow(id: "m\(index)", message: .object([
            "id": .string("m\(index)"), "role": .string("assistant"),
            "text": .string(String(repeating: "字", count: characters)),
            "created_at": .number(Double(index)),
        ]), pending: nil)
    }

    func testWindowKeepsAtLeastFourAndStaysWithinBudget() {
        let rows = (0..<40).map { row($0, characters: 1_000) }
        let window = ChatPage.window(rows, budget: 3_000)
        XCTAssertEqual(window.count, 4)
        XCTAssertEqual(window.last?.id, "m39")
        // 预算再小也会保底 4 条，避免一页只剩一轮对话。
        XCTAssertEqual(ChatPage.weight(of: window), 4 * ChatPage.weight(of: row(0, characters: 1_000)))
    }

    func testWindowCapsAtSixtyRows() {
        let rows = (0..<200).map { row($0, characters: 1) }
        XCTAssertEqual(ChatPage.window(rows, budget: 1_000_000).count, 60)
        XCTAssertEqual(ChatPage.window(rows, budget: 1_000_000).last?.id, "m199")
    }

    func testShortConversationIsReturnedWhole() {
        let rows = (0..<3).map { row($0) }
        XCTAssertEqual(ChatPage.window(rows, budget: 1).count, 3)
    }

    // MARK: ChatDisplay

    private func message(_ id: String, role: String = "assistant", request: String = "", at: Double = 1_790_000_000) -> ChatTimelineRow {
        ChatTimelineRow(id: id, message: .object([
            "id": .string(id), "role": .string(role), "text": .string(id),
            "request_id": .string(request), "created_at": .number(at),
        ]), pending: nil)
    }

    private var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testDisplayFoldsProactiveRunButKeepsLatestVisible() {
        let rows = [message("a", role: "user"), message("p1", request: "task-result:1"), message("p2", request: "task-result:2"), message("p3", request: "task-result:3"), message("b", role: "user")]
        let ids = ChatDisplay.rows(rows, calendar: shanghai).map(\.id)
        XCTAssertEqual(ids.filter { !$0.hasPrefix("day:") }, ["a", "stack:p1", "p3", "b"])
        let stack = ChatDisplay.rows(rows, calendar: shanghai).first { $0.id == "stack:p1" }
        XCTAssertEqual(stack?.contains(messageID: "p2"), true)
        XCTAssertEqual(stack?.contains(messageID: "p3"), false)
    }

    func testDisplayNeverFoldsProactiveMessageWithArtifact() {
        var withFile = message("p2", request: "task-result:2")
        if case .object(var fields) = withFile.message {
            fields["artifacts"] = .array([.object(["id": .string("art_1"), "name": .string("a.html")])])
            withFile = ChatTimelineRow(id: "p2", message: .object(fields), pending: nil)
        }
        let ids = ChatDisplay.rows([message("p1", request: "task-result:1"), withFile, message("p3", request: "task-result:3")], calendar: shanghai)
            .map(\.id).filter { !$0.hasPrefix("day:") }
        XCTAssertEqual(ids, ["p1", "p2", "p3"])
    }

    func testDisplayAddsOneAnchorPerDayAndSkipsFixtureTimestamps() {
        let day = 86_400.0
        let rows = [message("a", at: 1_790_000_000), message("b", role: "user", at: 1_790_000_100), message("c", at: 1_790_000_000 + day)]
        let days = ChatDisplay.rows(rows, calendar: shanghai).filter { $0.id.hasPrefix("day:") }
        XCTAssertEqual(days.count, 2)
        XCTAssertTrue(ChatDisplay.rows([message("x", at: 3)], calendar: shanghai).allSatisfy { !$0.id.hasPrefix("day:") })
    }

    func testDisplayMarksConsecutiveAgentOnlyAfterAgent() {
        let rows = [message("u", role: "user", at: 3), message("a1", at: 4), message("a2", at: 5)]
        let flags = ChatDisplay.rows(rows, calendar: shanghai).map { row -> Bool in
            if case .message(_, let consecutive) = row.kind { return consecutive }
            return false
        }
        XCTAssertEqual(flags, [false, false, true])
    }

    func testMixedLegacyZeroSeqAndNewSeqMessagesKeepChronologicalOrderAndUniqueDayIDs() {
        let day = 86_400.0
        let base = 1_793_980_800.0 // real timestamp
        let mLegacyDay1: JSON = .object(["id": .string("m1"), "role": .string("user"), "text": .string("旧消息1"), "message_seq": .number(0), "created_at": .number(base)])
        let mLegacyDay2: JSON = .object(["id": .string("m2"), "role": .string("assistant"), "text": .string("旧消息2"), "message_seq": .number(0), "created_at": .number(base + day)])
        let mLegacyDay3Early: JSON = .object(["id": .string("m3"), "role": .string("user"), "text": .string("旧消息3"), "message_seq": .number(0), "created_at": .number(base + 2 * day)])
        let mNewDay3Late: JSON = .object(["id": .string("m4"), "role": .string("user"), "text": .string("新消息4"), "message_seq": .number(1), "created_at": .number(base + 2 * day + 3600)])
        let mNewDay4: JSON = .object(["id": .string("m5"), "role": .string("assistant"), "text": .string("新消息5"), "message_seq": .number(2), "created_at": .number(base + 3 * day)])

        let timeline = ChatTimeline.rows(messages: [mNewDay3Late, mNewDay4, mLegacyDay1, mLegacyDay2, mLegacyDay3Early], pending: [])
        XCTAssertEqual(timeline.map(\.id), ["m1", "m2", "m3", "m4", "m5"])

        let display = ChatDisplay.rows(timeline, calendar: shanghai)
        let displayIDs = display.map(\.id)
        XCTAssertEqual(displayIDs.count, Set(displayIDs).count, "ChatDisplay Row IDs must be strictly unique")
    }

    func testDisplayInsertsTimeSeparatorAfterTenMinutesAndFormatsRelativeDates() {
        let now = Date(timeIntervalSince1970: 1_794_290_000) // 2026-11-10 in Asia/Shanghai
        let cal = shanghai
        let todayMorning = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9, minute: 6))!
        let todayFiveMinLater = todayMorning.addingTimeInterval(300)
        let todayFortyMinLater = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9, minute: 46))!
        let yesterdayNight = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 21, minute: 45))!
        let earlierThisYear = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9, minute: 0))!
        let lastYear = cal.date(from: DateComponents(year: 2025, month: 11, day: 8, hour: 9, minute: 0))!

        XCTAssertEqual(ChatDisplay.formatTime(todayFortyMinLater, now: now, calendar: cal), "9:46")
        XCTAssertEqual(ChatDisplay.formatTime(yesterdayNight, now: now, calendar: cal), "昨天 21:45")
        XCTAssertEqual(ChatDisplay.formatTime(earlierThisYear, now: now, calendar: cal), "11月8日 09:00")
        XCTAssertEqual(ChatDisplay.formatTime(lastYear, now: now, calendar: cal), "2025年11月8日 09:00")

        let rows = [
            message("m1", at: todayMorning.timeIntervalSince1970),
            message("m2", role: "user", at: todayFiveMinLater.timeIntervalSince1970),
            message("m3", at: todayFortyMinLater.timeIntervalSince1970),
        ]
        let display = ChatDisplay.rows(rows, calendar: cal, now: now)
        let times = display.compactMap { row -> String? in
            if case .time(let label) = row.kind { return label }
            return nil
        }
        XCTAssertEqual(times, ["9:46"])
    }

    func testNudgeMetadataIsNotFoldedIntoProactiveStack() {
        func nudge(_ id: String, at: Double) -> ChatTimelineRow {
            ChatTimelineRow(id: id, message: .object([
                "id": .string(id), "role": .string("assistant"), "text": .string(id),
                "request_id": .string("task-result:nudge:\(id)"),
                "metadata": .object(["kind": .string("nudge")]),
                "created_at": .number(at),
            ]), pending: nil)
        }
        let rows = [nudge("n1", at: 1_790_000_000), nudge("n2", at: 1_790_000_100), nudge("n3", at: 1_790_000_200)]
        let ids = ChatDisplay.rows(rows, calendar: shanghai).map(\.id).filter { !$0.hasPrefix("day:") }
        XCTAssertEqual(ids, ["n1", "n2", "n3"])
    }
}
