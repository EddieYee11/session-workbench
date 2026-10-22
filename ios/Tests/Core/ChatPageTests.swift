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
}
