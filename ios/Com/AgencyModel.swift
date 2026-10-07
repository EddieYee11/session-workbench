import SwiftUI
import ComCore

extension AppModel {
    func agencyAction(_ card: JSON, action: String) async throws -> JSON {
        #if DEBUG
        if isUITesting {
            var value = datasets["/personal/agency"] ?? .null
            if action == "prepare" {
                let pack: JSON = .object(["summary": .string("先确认今天的重点，再留出一段专注时间。"), "evidence": .array([.object(["label": .string("来源"), "value": .string("界面验收资料")])]), "limits": .string("这是界面验收数据。")])
                return .object(["status": .string("completed"), "result": pack])
            }
            if ["later", "handled", "mute"].contains(action) { value["cards"] = .array(value["cards"].array.filter { $0.id != card.id }) }
            if ["pause", "resume", "complete"].contains(action) {
                value["goals"] = .array(value["goals"].array.map { goal in
                    guard goal.id == card.id else { return goal }; var result = goal
                    result["status"] = .string(action == "pause" ? "paused" : action == "complete" ? "completed" : "active"); return result
                })
            }
            datasets["/personal/agency"] = value
            return .object(["status": .string("completed")])
        }
        #endif
        var fields: [String: JSON] = ["action": .string(action)]
        if !card["version"].isNull { fields["version"] = card["version"] }
        else if !card["updated_at"].isNull { fields["version"] = card["updated_at"] }
        let result = try await mutate("/personal/agency/actions/" + card.id.pathEncoded, fields: fields)
        _ = await load("/personal/agency")
        if action == "discuss" { await refresh(.chat) }
        return result
    }
    func createPersonalGoal(title: String, outcome: String, next: String) async throws -> JSON {
        let fields: [String: JSON] = ["title": .string(title), "completion_condition": .string(outcome), "next_step": .string(next)]
        #if DEBUG
        if isUITesting {
            var value = datasets["/personal/agency"] ?? .null
            let goal = JSON.object(fields.merging(["id": .string(UUID().uuidString), "status": .string("active")]) { _, b in b })
            value["goals"] = .array(value["goals"].array + [goal]); datasets["/personal/agency"] = value
            return .object(["status": .string("completed"), "goal": goal])
        }
        #endif
        let result = try await mutate("/personal/agency/goals", fields: fields)
        _ = await load("/personal/agency")
        return result
    }
    func saveAgencySettings(_ fields: [String: JSON]) async throws {
        #if DEBUG
        if isUITesting {
            var value = datasets["/personal/agency"] ?? .null; value["settings"] = .object(fields)
            datasets["/personal/agency"] = value; return
        }
        #endif
        _ = try await mutate("/personal/agency/settings", fields: fields)
        _ = await load("/personal/agency")
    }
}
