import SwiftUI
import ComCore

extension AppModel {
    func agencyAction(_ card: JSON, action: String, extra: [String: JSON] = [:]) async throws -> JSON {
        #if DEBUG
        if isUITesting {
            var value = datasets["/personal/agency"] ?? .null
            if action == "prepare" {
                let pack: JSON = .object(["summary": .string("先确认今天的重点，再留出一段专注时间。"), "evidence": .array([.object(["label": .string("来源"), "value": .string("界面验收资料")])]), "limits": .string("这是界面验收数据。")])
                value["cards"] = .array(value["cards"].array.map { row in guard row.id == card.id else { return row }; var copy = row; copy["preparation"] = pack; return copy })
                datasets["/personal/agency"] = value; recomputeFlow()
                return .object(["status": .string("completed"), "result": pack])
            }
            if action == "discuss" {
                conversation.messages.append(.object(["id": .string("discuss-" + card.id), "role": .string("user"), "text": .string("继续处理「" + card["title"].string + "」"), "status": .string("completed"), "created_at": .number(Date().timeIntervalSince1970)]))
                conversation.revision += 1
                value["cards"] = .array(value["cards"].array.filter { $0.id != card.id }); datasets["/personal/agency"] = value; recomputeFlow()
                return .object(["status": .string("completed")])
            }
            if ["later", "handled", "mute"].contains(action) { value["cards"] = .array(value["cards"].array.filter { $0.id != card.id }) }
            if ["pause", "resume", "complete"].contains(action) {
                value["goals"] = .array(value["goals"].array.map { goal in
                    guard goal.id == card.id else { return goal }; var result = goal
                    result["status"] = .string(action == "pause" ? "paused" : action == "complete" ? "completed" : "active"); return result
                })
            }
            datasets["/personal/agency"] = value; recomputeFlow()
            return .object(["status": .string("completed")])
        }
        #endif
        var fields: [String: JSON] = ["action": .string(action)].merging(extra) { a, _ in a }
        if !card["version"].isNull { fields["version"] = card["version"] }
        else if !card["updated_at"].isNull { fields["version"] = card["updated_at"] }
        let result = try await mutate("/personal/agency/actions/" + card.id.pathEncoded, fields: fields)
        // 动作已送达；拉齐失败则乐观改本地 + 开口，别假装列表已是最新。
        if await load("/personal/agency") == nil {
            var value = datasets["/personal/agency"] ?? .object([:])
            if ["pause", "resume", "complete"].contains(action) {
                value["goals"] = .array(value["goals"].array.map { goal in
                    guard goal.id == card.id else { return goal }
                    var copy = goal
                    copy["status"] = .string(action == "pause" ? "paused" : action == "complete" ? "completed" : "active")
                    return copy
                })
                datasets["/personal/agency"] = value
                recomputeFlow()
                let err = errors["/personal/agency"] ?? ""
                let head = action == "complete" ? "已标完成" : action == "pause" ? "已暂停" : "已恢复"
                agencyGoalsNote = err.isEmpty
                    ? head + "，列表没刷齐——可下拉再试。不会假装列表已是最新。"
                    : head + "，列表没刷齐：" + err + "——可下拉再试。不会假装列表已是最新。"
            } else if action == "prepare" {
                // 详情已用 result 亮 pack；cards 没刷上则写上 preparation，重开详情别丢整理。
                let pack = result["result"]
                if !pack.isNull {
                    value["cards"] = .array(value["cards"].array.map { row in
                        guard row.id == card.id else { return row }
                        var copy = row
                        copy["preparation"] = pack
                        return copy
                    })
                    datasets["/personal/agency"] = value
                    recomputeFlow()
                }
                let err = errors["/personal/agency"] ?? ""
                agencyCardsNote = err.isEmpty
                    ? "资料已整理，卡片列表没刷齐——可下拉等你或重开详情。不会假装列表已是最新。"
                    : "资料已整理，卡片列表没刷齐：" + err + "——可再试。不会假装列表已是最新。"
            } else if ["later", "handled", "mute", "discuss"].contains(action) {
                value["cards"] = .array(value["cards"].array.filter { $0.id != card.id })
                datasets["/personal/agency"] = value
                recomputeFlow()
                // later/mute/handled：卡已乐观收起；列表没刷齐则开口，别假装等你已是最新。
                if ["later", "handled", "mute"].contains(action) {
                    let err = errors["/personal/agency"] ?? ""
                    let head = action == "later" ? "已留到稍后" : action == "mute" ? "已先不提" : "已记下处理"
                    agencyCardsNote = err.isEmpty
                        ? head + "，卡片列表没刷齐——可再拉开等你。不会假装列表已是最新。"
                        : head + "，卡片列表没刷齐：" + err + "——可再拉开等你。不会假装列表已是最新。"
                    if waitingOpenNote.isEmpty {
                        waitingOpenNote = agencyCardsNote
                    }
                }
            }
        } else {
            if ["pause", "resume", "complete"].contains(action) { agencyGoalsNote = "" }
            if ["prepare", "later", "handled", "mute"].contains(action) { agencyCardsNote = "" }
        }
        if action == "discuss" {
            // 已交办；等你/航程/主聊没刷上分别开口，别假装角标与派活已齐。
            if await load("/personal/waiting") == nil {
                let err = errors["/personal/waiting"] ?? ""
                if waitingOpenNote.isEmpty {
                    waitingOpenNote = err.isEmpty
                        ? "已交给 Com，等你列表没刷齐——可再拉开等你。不会假装角标已更新。"
                        : "已交给 Com，等你列表没刷齐：" + err + "——可再拉开等你。不会假装角标已更新。"
                }
            }
            if await load("/personal/cases") == nil {
                let err = errors["/personal/cases"] ?? ""
                if activityOpenNote.isEmpty {
                    activityOpenNote = err.isEmpty
                        ? "已交给 Com，航程列表没刷上——可打开动态再试。不会假装列表已更新。"
                        : "已交给 Com，航程列表没刷上：" + err + "——可打开动态再试。不会假装列表已更新。"
                }
            }
            if let data = await load("/personal/conversation") {
                conversation.apply(data, snapshot: true)
                ComNotifications.observe(conversation.messages)
                todayOpenNote = ""
            } else {
                let err = errors["/personal/conversation"] ?? ""
                let hadCache = !conversation.messages.isEmpty
                todayOpenNote = err.isEmpty
                    ? (hadCache
                       ? "已交给 Com，主聊没刷上——下面仍可能是上一版。可下拉再试。不会假装派活已显示。"
                       : "已交给 Com，主聊还没拉齐——可下拉再试。不会假装派活已显示。")
                    : "已交给 Com，主聊没刷上：" + err + "——可下拉再试。不会假装派活已显示。"
            }
        }
        return result
    }
    func createPersonalGoal(title: String, outcome: String, next: String) async throws -> JSON {
        let fields: [String: JSON] = ["title": .string(title), "completion_condition": .string(outcome), "next_step": .string(next)]
        #if DEBUG
        if isUITesting {
            var value = datasets["/personal/agency"] ?? .null
            let goal = JSON.object(fields.merging(["id": .string(UUID().uuidString), "status": .string("active")]) { _, b in b })
            value["goals"] = .array(value["goals"].array + [goal]); datasets["/personal/agency"] = value; recomputeFlow()
            return .object(["status": .string("completed"), "goal": goal])
        }
        #endif
        let result = try await mutate("/personal/agency/goals", fields: fields)
        // 已建上；列表没刷齐则乐观并入 + 开口，别假装列表已是最新。
        if await load("/personal/agency") == nil {
            if !result["goal"].isNull {
                var value = datasets["/personal/agency"] ?? .object([:])
                let g = result["goal"]
                if !value["goals"].array.contains(where: { $0.id == g.id }) {
                    value["goals"] = .array([g] + value["goals"].array)
                    datasets["/personal/agency"] = value
                    recomputeFlow()
                }
            }
            let err = errors["/personal/agency"] ?? ""
            agencyGoalsNote = err.isEmpty
                ? "目标已建上，列表没刷齐——可下拉再试。不会假装列表已是最新。"
                : "目标已建上，列表没刷齐：" + err + "——可下拉再试。不会假装列表已是最新。"
        } else {
            agencyGoalsNote = ""
        }
        return result
    }
    /// - Returns: `true` 若保存后 agency 已拉齐；`false` 已保存但列表/安排没刷上（本地已乐观写入 settings）。
    @discardableResult
    func saveAgencySettings(_ fields: [String: JSON]) async throws -> Bool {
        #if DEBUG
        if isUITesting {
            var value = datasets["/personal/agency"] ?? .null; value["settings"] = .object(fields)
            datasets["/personal/agency"] = value; return true
        }
        #endif
        _ = try await mutate("/personal/agency/settings", fields: fields)
        // 已保存；拉齐失败则乐观写入 + 由页内开口，别假装已刷齐。
        if await load("/personal/agency") != nil { return true }
        var value = datasets["/personal/agency"] ?? .object([:])
        value["settings"] = .object(fields)
        datasets["/personal/agency"] = value
        return false
    }
}
