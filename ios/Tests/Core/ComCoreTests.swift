import XCTest
@testable import ComCore
final class ComCoreTests: XCTestCase {
    func testRecoveryStreamingAndTransportContracts() throws { XCTAssertGreaterThan(try CoreChecks.run(), 50) }
    func testReceiptKeepsOneStableRowAcrossDelayedSnapshot() {
        var pending = PendingMessage(text: "同一条消息")
        pending.state = .delivered
        let before = ChatTimeline.rows(messages: [], pending: [pending])
        XCTAssertEqual(before.count, 1, "Accepted messages must stay visible until the snapshot catches up")
        let remote = JSON.object(["id": .string("server-id"), "request_id": .string(pending.id), "role": .string("user"), "text": .string(pending.text), "created_at": .number(pending.createdAt.timeIntervalSince1970)])
        let after = ChatTimeline.rows(messages: [remote], pending: [pending])
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(before.first?.id, after.first?.id)
        XCTAssertNil(after.first?.pending)
        XCTAssertEqual(after.first?.message.id, "server-id")
    }
    func testIdenticalMessagesRemainSeparateRequests() {
        let first = PendingMessage(text: "记账 20 元")
        var second = PendingMessage(text: first.text)
        second.state = .uncertain
        let rows = ChatTimeline.rows(messages: [], pending: [first, second])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        XCTAssertTrue(rows.contains { $0.pending?.state == .uncertain })
    }
}
