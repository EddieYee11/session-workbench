import XCTest
@testable import ComCore

final class AgentStageMachineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)
    private func activity(_ kind: String) -> JSON { .object(["kind": .string(kind)]) }
    private func receipt(_ id: String) -> JSON { .object(["message_id": .string(id), "preview": .string("真实回复")]) }
    func testDeliveryPlaysOnceThenReturnsToIdle() {
        var machine = AgentStageMachine()
        machine.receive(name: "task.progress", data: activity("idle"), now: now)
        machine.receive(name: "agent.push", data: receipt("new"), now: now)
        XCTAssertEqual(machine.state, .delivered)
        machine.tick(now: now.addingTimeInterval(3))
        XCTAssertEqual(machine.state, .idle)
        machine.receive(name: "agent.push", data: receipt("new"), now: now.addingTimeInterval(4))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.deliveryPreview, "真实回复")
    }
    func testSnapshotsDoNotReenactHistoricalAnswers() {
        var machine = AgentStageMachine()
        let data: JSON = .object(["activity": activity("idle"), "messages": .array([.object(["id": .string("old"), "role": .string("assistant"), "status": .string("completed")])])])
        machine.receive(name: "snapshot", data: data, now: now)
        machine.receive(name: "agent.push", data: receipt("old"), now: now)
        XCTAssertEqual(machine.state, .idle)
    }
    func testHeartbeatIsNotWorkAndLostTransportStopsAnimation() {
        var machine = AgentStageMachine()
        machine.receive(name: "task.progress", data: activity("working"), now: now)
        machine.receive(name: "heartbeat", data: .object([:]), now: now.addingTimeInterval(31))
        XCTAssertEqual(machine.state, .waiting)
        machine.tick(now: now.addingTimeInterval(67))
        XCTAssertEqual(machine.state, .offline)
        machine.receive(name: "task.progress", data: activity("searching"), now: now.addingTimeInterval(68))
        XCTAssertEqual(machine.state, .searching)
        machine.receive(name: "task.progress", data: activity("thinking"), now: now.addingTimeInterval(68.1))
        XCTAssertEqual(machine.state, .thinking)
    }
    func testReviewTakesPriorityAndRetriesAreNeverInvented() {
        var machine = AgentStageMachine()
        machine.receive(name: "task.review", data: activity("review"), now: now)
        machine.receive(name: "agent.push", data: receipt("other"), now: now)
        XCTAssertEqual(machine.state, .review)
        XCTAssertNil(machine.retryCount)
        machine.receive(name: "task.progress", data: activity("failed"), now: now.addingTimeInterval(4))
        XCTAssertEqual(machine.state, .failed)
        machine.receive(name: "task.progress", data: .object(["kind": .string("working"), "retry_count": .number(2)]), now: now.addingTimeInterval(5))
        XCTAssertEqual(machine.retryCount, 2)
    }
}
