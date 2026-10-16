import Foundation

/// Deterministic reducer: snapshots establish a baseline, deliveries are transient,
/// heartbeat proves transport only; it never invents progress or completion.
public struct AgentStageMachine: Sendable {
    public private(set) var state: AgentStageState = .offline
    public private(set) var deliveryID = ""
    public private(set) var deliveryPreview = ""
    public private(set) var retryCount: Int? = nil
    private var activity: AgentStageState = .idle
    private var baselined = false
    private var seen: [String] = []
    private var lastTraffic = Date.distantPast
    private var lastProgress = Date.distantPast
    private var deliveryStarted = Date.distantPast
    public init() {}
    public mutating func receive(name: String, data: JSON, now: Date) {
        lastTraffic = now
        if name == "snapshot" || name == "update" {
            if name == "snapshot" || !baselined {
                baselined = true
                seen = Array(data["messages"].array.filter { $0["role"].string == "assistant" && $0["status"].string == "completed" }.map(\.id).suffix(200))
            }
            if !data["activity"].isNull { apply(data["activity"], now: now) }
        } else if name == "task.progress" || name == "task.review" {
            apply(data, now: now)
        } else if name == "agent.push" {
            let id = data["message_id"].string
            guard !id.isEmpty, !seen.contains(id) else { return }
            seen = Array((seen + [id]).suffix(200))
            deliveryID = id; deliveryPreview = data["preview"].string
            deliveryStarted = now
        }
        tick(now: now)
    }
    private mutating func apply(_ data: JSON, now: Date) {
        activity = AgentStageState(rawValue: data["kind"].string) ?? .working
        retryCount = data["retry_count"].isNull ? nil : data["retry_count"].int
        lastProgress = now
    }
    public mutating func disconnected() { state = .offline }
    public mutating func tick(now: Date) {
        if now.timeIntervalSince(lastTraffic) > 35 { state = .offline }
        else if activity == .review { state = .review }
        else if now.timeIntervalSince(deliveryStarted) < 2.8 { state = .delivered }
        else if activity.isBusy && now.timeIntervalSince(lastProgress) > 30 { state = .waiting }
        else { state = activity }
    }
}
