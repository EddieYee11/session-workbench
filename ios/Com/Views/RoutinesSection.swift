import SwiftUI
import ComCore

// 已排程：Com 所有主动行为（主动消息、临近提醒、下一步整理、固定任务、Hermes 定时）列在一处，能暂停的可单项暂停，也可以一键全部暂停。
// 后端不给暂停入口的项（controllable=false）只读，标「只读」，不假装可控。

extension AppModel {
    var routinesData: JSON { datasets["/personal/routines"] ?? .null }

    /// 单项或全部（id == "_all"）暂停 / 恢复。失败返回原因，调用方回弹并提示。
    func routineSet(_ id: String, pause: Bool) async -> String? {
        let action = pause ? "pause" : "resume"
        #if DEBUG
        if isUITesting {
            var value = routinesData
            if id == "_all" { value["paused"] = .bool(pause) }
            else {
                value["items"] = .array(value["items"].array.map { row in
                    var copy = row
                    if row["id"].string == id { copy["enabled"] = .bool(!pause) }
                    return copy
                })
            }
            datasets["/personal/routines"] = value
            return nil
        }
        #endif
        do {
            _ = try await mutate("/personal/routines/" + id.pathEncoded, fields: ["action": .string(action)])
            _ = await load("/personal/routines")
            Haptics.selection()
            return nil
        } catch { return error.localizedDescription }
    }

    #if DEBUG
    func seedRoutinesPreview() {
        let now = Date().timeIntervalSince1970
        func iso(_ offset: Double) -> JSON { .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: now + offset))) }
        func row(_ id: String, _ group: String, _ title: String, _ trigger: String, controllable: Bool, enabled: Bool = true, note: String = "", next: JSON = .null, last: JSON = .null, status: JSON = .null) -> JSON {
            .object(["id": .string(id), "group": .string(group), "title": .string(title), "trigger": .string(trigger), "next_run_at": next, "last_run_at": last,
                     "last_status": status, "enabled": .bool(enabled), "controllable": .bool(controllable), "note": .string(note)])
        }
        datasets["/personal/routines"] = .object(["paused": .bool(false), "items": .array([
            row("proactive:morning-briefing", "主动消息", "每日晨报", "每天 09:00", controllable: true, next: iso(5400)),
            row("proactive:evening-review", "主动消息", "晚间复盘", "每天 21:00", controllable: true, next: iso(40000)),
            row("nudges", "临近提醒", "日程前 15 分钟、提醒到期、订阅到期", "到点触发", controllable: false, note: "跟随全部暂停"),
            row("next-steps", "下一步整理", "下一步整理", "每小时（08–23 点）", controllable: false, note: "每小时一轮（08–23 点），无独立暂停入口", last: iso(-1800), status: .string("失败：模型超时")),
            row("tomorrow-plan", "固定任务", "明天计划", "每天 21:30", controllable: false, note: "只读，无暂停入口", next: iso(41000)),
            row("cron:j1", "Hermes 定时", "健康同步", "*/30 * * * *", controllable: true, next: iso(900), last: iso(-900), status: .string("ok"))
        ])])
    }
    #endif
}

private func routineDate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: value) { return date }
    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    // 微秒（6 位小数）：截成秒再解析
    if let dot = value.firstIndex(of: "."), let tz = value[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        return plain.date(from: String(value[..<dot]) + String(value[tz...]))
    }
    return nil
}

private func routineClock(_ date: Date) -> String { date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().locale(Locale(identifier: "zh_CN"))) }
private func routineWhen(_ date: Date) -> String {
    Calendar.current.isDateInToday(date) ? routineClock(date) : date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
}

struct RoutinesSection: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var note = ""
    @State private var busy: Set<String> = []

    private var data: JSON { model.routinesData }
    private var items: [JSON] { data["items"].array }
    private var paused: Bool { data["paused"].bool }
    private var groups: [(String, [JSON])] {
        var order: [String] = []
        for item in items where !order.contains(item["group"].string) { order.append(item["group"].string) }
        return order.map { group in (group, items.filter { $0["group"].string == group }) }
    }
    private var summary: String {
        var text = "已排程 · \(items.count) 项"
        if paused { return text + " · 全部暂停中" }
        let upcoming = items.compactMap { row -> (Date, String)? in
            guard row["enabled"].bool, let date = routineDate(row["next_run_at"].string), date > Date() else { return nil }
            return (date, row["title"].string)
        }.min { $0.0 < $1.0 }
        if let upcoming { text += " · 下一次 \(routineClock(upcoming.0)) \(upcoming.1)" }
        return text
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "clock.badge.checkmark").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        Text(summary).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Image(systemName: "chevron.down").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.vertical, Space.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("routines-expand")
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                if expanded { details }
            }
            .task { _ = await model.load("/personal/routines") }
        }
    }

    @ViewBuilder private var details: some View {
        if !note.isEmpty { InlineNotice(text: note, tone: .danger) }
        Card(.standard, padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.lg) {
                Toggle(isOn: Binding(get: { paused }, set: { value in set("_all", pause: value) })) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("全部暂停").font(TypeScale.rowTitle)
                        Text("暂停后主动消息和临近提醒都不再发").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    }
                }
                .disabled(busy.contains("_all"))
                .accessibilityIdentifier("routines-pause-all")
                ForEach(groups, id: \.0) { group, rows in
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text(group).font(TypeScale.stamp).foregroundStyle(Palette.textTertiary)
                        ForEach(rows, id: \.["id"].string) { row in routineRow(row) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func routineRow(_ row: JSON) -> some View {
        let id = row["id"].string
        let controllable = row["controllable"].bool
        HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(row["title"].string).font(TypeScale.rowTitle).foregroundStyle(row["enabled"].bool ? Palette.textPrimary : Palette.textSecondary)
                if !row["trigger"].string.isEmpty { Text(row["trigger"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary) }
                if let line = timeLine(row) { Text(line).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary) }
                let status = row["last_status"].string
                if status.hasPrefix("失败") { Text("上次" + status).font(TypeScale.footnote).foregroundStyle(Palette.danger) }
                if !row["note"].string.isEmpty { Text(row["note"].string).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) }
            }
            Spacer(minLength: Space.sm)
            if controllable {
                Toggle("", isOn: Binding(get: { row["enabled"].bool }, set: { value in set(id, pause: !value) }))
                    .labelsHidden()
                    .disabled(busy.contains(id))
                    .accessibilityLabel(row["title"].string)
                    .accessibilityIdentifier("routine-toggle-" + id)
            } else {
                Stamp(text: "只读", tone: .neutral)
            }
        }
    }

    private func timeLine(_ row: JSON) -> String? {
        var parts: [String] = []
        if let next = routineDate(row["next_run_at"].string) { parts.append("下次 " + routineWhen(next)) }
        if let last = routineDate(row["last_run_at"].string) { parts.append("上次 " + routineWhen(last)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func set(_ id: String, pause: Bool) {
        busy.insert(id); note = ""
        Task {
            // 失败时数据没变，Toggle 自然回弹到原状态；这里只补一条说明，不假装成功。
            if let error = await model.routineSet(id, pause: pause) { note = "没能" + (pause ? "暂停" : "恢复") + "：" + error }
            busy.remove(id)
        }
    }
}
