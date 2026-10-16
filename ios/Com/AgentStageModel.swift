import Foundation
import Observation
import ComCore

@MainActor @Observable final class AgentStageModel {
    private(set) var state: AgentStageState = .offline
    private(set) var changedAt = Date()
    private(set) var deliveryID = ""
    private(set) var preview = ""
    private(set) var retryCount: Int?
    @ObservationIgnored private var machine = AgentStageMachine()
    func receive(_ name: String, _ data: JSON) {
        machine.receive(name: name, data: data, now: Date()); publish()
    }
    func tick() { machine.tick(now: Date()); publish() }
    func disconnect() { machine.disconnected(); publish() }
    private func publish() {
        if state != machine.state || deliveryID != machine.deliveryID { changedAt = Date() }
        if state != machine.state { state = machine.state }
        if deliveryID != machine.deliveryID { deliveryID = machine.deliveryID }
        if preview != machine.deliveryPreview { preview = machine.deliveryPreview }
        if retryCount != machine.retryCount { retryCount = machine.retryCount }
    }
}
