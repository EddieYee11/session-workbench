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
}
