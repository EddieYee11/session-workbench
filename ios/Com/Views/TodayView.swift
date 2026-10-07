import SwiftUI
import ComCore

struct TodayView: View {
    @Environment(AppModel.self) private var model
    private var briefing: JSON { model.datasets["/personal/briefing"] ?? .null }
    private var overview: JSON { model.datasets["/personal/overview"] ?? .null }
    var body: some View {
        PageCanvas {
            VStack(alignment: .leading, spacing: Space.sm) {
                PageHeading(title: "今天", subtitle: "")
                HStack { Text(Date().formatted(.dateTime.month(.wide).day().weekday(.wide))).font(TypeScale.footnote).foregroundStyle(.secondary); Spacer(); Freshness(path: "/personal/briefing") }
            }
            if briefing["cards"].array.isEmpty {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        Text("你好，小野").font(TypeScale.sectionTitle)
                        Text(model.errors["/personal/briefing"] == nil ? "这里会整理你的日程、消息与值得留意的变化。当前没有待看的事项，我们随时可以聊。" : "暂时没有连上简报来源。你可以下拉重试，或先继续聊天。")
                            .font(TypeScale.chat).foregroundStyle(.secondary).lineSpacing(5)
                        Button("聊一聊", systemImage: "bubble.left") { model.tab = .chat }.buttonStyle(.limeProminent)
                    }
                }
            }
            if let focus = briefing["cards"].array.first {
                Button { model.selectedMatter = focus } label: { TodayFocusCard(matter: focus) }.buttonStyle(.plain).detailSource("matter-" + focus.id)
            }
            if briefing["cards"].array.count > 1 { Eyebrow(text: "值得留意") }
            ForEach(briefing["cards"].array.dropFirst().map(RemoteRow.init)) { row in
                Button { model.selectedMatter = row.value } label: {
                    RowCard {
                        HStack(alignment: .top, spacing: Space.lg) {
                            IconBadge(symbol: sourceSymbol(row.value["source"].string))
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text(row.value["title"].string).font(TypeScale.chat.weight(.semibold)).foregroundStyle(.primary)
                                let summary = row.value["why"].string.isEmpty ? row.value["next_step"].string : row.value["why"].string
                                if !summary.isEmpty { Text(summary).font(TypeScale.footnote).foregroundStyle(.secondary).lineLimit(3) }
                                HStack(spacing: Space.sm) {
                                    Text(sourceName(row.value["source"].string))
                                    Spacer()
                                    Label("查看", systemImage: "arrow.up.right")
                                }.font(TypeScale.footnote).foregroundStyle(.tertiary).padding(.top, Space.xs)
                            }
                        }
                    }
                }.buttonStyle(.plain).detailSource("matter-" + row.id)
            }
            if overview["calendar"]["available"].bool {
                Eyebrow(text: "日程")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        if overview["calendar"]["items"].array.isEmpty { Text("已连接日历，当前范围内没有日程").font(TypeScale.chat).foregroundStyle(.secondary) }
                        ForEach(overview["calendar"]["items"].array.map(RemoteRow.init)) { row in
                            HStack(alignment: .top, spacing: Space.md) {
                                RoundedRectangle(cornerRadius: 2).fill(Palette.cyan).frame(width: 3)
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Text(row.value["title"].string).font(TypeScale.chat.weight(.semibold))
                                    Text(calendarTime(row.value["start"])).font(TypeScale.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        Text(overview["calendar"]["source"].string + " · 未来 14 天").font(TypeScale.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if overview["finance"]["available"].bool {
                Eyebrow(text: "账务")
                ForEach(overview["finance"]["totals"].object.keys.sorted(), id: \.self) { currency in
                    let totals = overview["finance"]["totals"][currency]
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: Space.md) {
                            Text("今日支出 · \(currency)").font(TypeScale.footnote).foregroundStyle(.secondary)
                            Text(money(totals["today_expense_minor"], currency: currency)).font(TypeScale.display.weight(.medium)).contentTransition(.numericText())
                            HStack { Text("本月支出"); Spacer(); Text(money(totals["expense_minor"], currency: currency)) }.font(TypeScale.chat)
                            Text("原账本 · \(overview["finance"]["month"].string)\(overview["finance"]["stale"].bool ? " · 缓存数据" : "")").font(TypeScale.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Eyebrow(text: "身体与状态")
            SurfaceCard {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack { Label("Apple 健康", systemImage: "heart").font(TypeScale.chat.weight(.semibold)); Spacer(); Button("读取") { Task { await model.devices.readHealth() } }.buttonStyle(.quiet) }
                    if model.localHealth.isNull {
                        Text("在设置中选择健康权限后，可以读取最近 24 小时的活动、心率与睡眠。").font(TypeScale.chat).foregroundStyle(.secondary)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Space.xl) { healthValue("步数", key: "steps", unit: ""); healthValue("心率", key: "heart_rate_average", unit: "bpm"); healthValue("睡眠", key: "sleep_hours", unit: "h") }
                            VStack(alignment: .leading, spacing: Space.lg) { healthValue("步数", key: "steps", unit: ""); healthValue("心率", key: "heart_rate_average", unit: "bpm"); healthValue("睡眠", key: "sleep_hours", unit: "h") }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Space.xl) { healthValue("活动能量", key: "active_energy_kcal", unit: "kcal"); healthValue("静息心率", key: "resting_heart_rate", unit: "bpm") }
                            VStack(alignment: .leading, spacing: Space.lg) { healthValue("活动能量", key: "active_energy_kcal", unit: "kcal"); healthValue("静息心率", key: "resting_heart_rate", unit: "bpm") }
                        }
                        let workouts = model.localHealth["workouts"].array
                        if !workouts.isEmpty {
                            ForEach(workouts.map(RemoteRow.init)) { row in
                                LabeledContent("运动记录", value: calendarTime(row.value["start"]) + " · " + (row.value["duration_seconds"].double / 60).formatted(.number.precision(.fractionLength(0))) + " 分钟").font(TypeScale.footnote)
                            }
                        }
                        Text("Apple HealthKit · 更新于 " + model.localHealth["updated_at"].string).font(TypeScale.footnote).foregroundStyle(.tertiary)
                        DisclosureGroup("更多数据说明") {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text("采集区间：" + model.localHealth["start"].string + " 至 " + model.localHealth["end"].string)
                                if workouts.isEmpty { Text("采集区间内无可用运动记录") }
                                if !model.localHealth["missing_reason"].string.isEmpty { Text(model.localHealth["missing_reason"].string) }
                                Text("健康数据默认留在本机；同步到 mini 可在设置中开启。")
                            }.font(TypeScale.footnote).foregroundStyle(.secondary).padding(.top, Space.sm)
                        }.font(TypeScale.footnote).tint(.secondary)
                    }
                }
            }
            Eyebrow(text: "数据连接")
            VStack(alignment: .leading, spacing: Space.sm) {
                let sources = briefing["source_status"]["sources"].array
                ForEach(Array(sources.enumerated()), id: \.offset) { index, status in
                    HStack(alignment: .top) {
                        Text(sourceName(status["name"].string)).font(TypeScale.footnote.weight(.semibold))
                        Spacer()
                        Text(status["status"].string.isEmpty ? status["error"].string : status["status"].string).font(TypeScale.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    if index < sources.count - 1 { Divider() }
                }
                if !overview["calendar"]["available"].bool { Label("日历：" + sourceFailure(overview["calendar"]["error_code"].string), systemImage: "calendar.badge.exclamationmark").font(TypeScale.footnote).foregroundStyle(.secondary) }
                if !overview["finance"]["available"].bool { Label("账务：" + sourceFailure(overview["finance"]["error_code"].string), systemImage: "exclamationmark.circle").font(TypeScale.footnote).foregroundStyle(.secondary) }
                Button("管理连接") { model.showSettings = true }.buttonStyle(.quiet).padding(.top, Space.xs)
            }
        }.refreshable { await model.refresh(.today) }
    }
    private func healthValue(_ title: String, key: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(TypeScale.footnote).foregroundStyle(.secondary)
            Text(model.localHealth[key].isNull ? "—" : model.localHealth[key].double.formatted(.number.precision(.fractionLength(key == "sleep_hours" ? 1 : 0))) + (unit.isEmpty ? "" : " " + unit)).font(TypeScale.chat.weight(.semibold)).monospacedDigit()
        }
    }
}

struct MatterDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let matter: JSON
    @State private var correction = ""
    @State private var goal = ""
    var body: some View {
        DetailPage(title: "事项") {
            VStack(alignment: .leading, spacing: Space.md) {
                Pill(text: sourceName(matter["source"].string), color: Palette.cyan)
                Text(matter["title"].string).font(TypeScale.sectionTitle)
                if !matter["what"].string.isEmpty { Text(matter["what"].string).font(TypeScale.footnote).foregroundStyle(.secondary) }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextField("想如何处理这件事？", text: $goal, axis: .vertical).lineLimit(2...6)
                    Button("交给 Com 继续处理", systemImage: "arrow.up.right") {
                        Task {
                            do { _ = try await model.mutate("/personal/matters/" + matter.id.pathEncoded + "/action", fields: ["goal": .string(goal.isEmpty ? "分析这件事并给出下一步" : goal)]); dismiss(); model.tab = .chat; await model.refresh(.chat) }
                            catch { model.banner = error.localizedDescription }
                        }
                    }.buttonStyle(.limeProminent)
                    ViewThatFits {
                        HStack(spacing: Space.lg) { feedback("关注", "follow"); feedback("稍后", "later"); feedback("已处理", "handled") }
                        VStack(alignment: .leading, spacing: Space.sm) { feedback("关注", "follow"); feedback("稍后", "later"); feedback("已处理", "handled") }
                    }
                    TextField("纠正来源中的事实", text: $correction, axis: .vertical).lineLimit(2...5)
                    HStack {
                        Button("保存纠正") { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string("correct"), "text": .string(correction)], refresh: .today) } }.buttonStyle(.quiet).disabled(correction.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        feedback("不再提醒", "mute")
                    }
                }
            }
            if !matter["why"].string.isEmpty {
                DisclosureGroup("背景说明") {
                    RichText(text: matter["why"].string).padding(.top, Space.sm)
                }.font(TypeScale.chat).tint(.primary)
            }
            if !matter["next_step"].string.isEmpty {
                DisclosureGroup("下一步建议") {
                    RichText(text: matter["next_step"].string).padding(.top, Space.sm)
                }.font(TypeScale.chat).tint(.primary)
            }
            RawDetails(title: "查看来源事实", value: matter["facts"])
            if !matter["action_context"].isNull { RawDetails(title: "关联背景", value: matter["action_context"]) }
            Button("解除事项关联") { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/unlink", refresh: .today) } }.buttonStyle(.quiet)
        }
    }
    private func feedback(_ title: String, _ action: String) -> some View {
        Button(title) { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string(action)], refresh: .today); if action != "follow" { dismiss() } } }.buttonStyle(.quiet)
    }
}

func sourceName(_ source: String) -> String {
    ["gmail": "Gmail", "work_mail": "搜狐邮箱", "github": "GitHub", "apple_calendar": "苹果日历", "google_calendar": "Google 日历",
     "phone_calendar": "手机日历", "phone_health": "手机健康", "accounting": "账本", "garmin": "佳明", "com_task": "Com 任务"][source] ?? source
}
func calendarTime(_ value: JSON) -> String {
    let raw = value["dateTime"].string.isEmpty ? value["date"].string.isEmpty ? value.string : value["date"].string : value["dateTime"].string
    return ISO8601DateFormatter().date(from: raw)?.formatted(.dateTime.month().day().hour().minute()) ?? raw
}
func money(_ minor: JSON, currency: String) -> String { minor.isNull ? "—" : (minor.double / 100).formatted(.currency(code: currency)) }

func sourceFailure(_ code: String) -> String {
    ["source_unavailable": "来源尚未连接", "upstream_timeout": "来源连接超时", "upstream_unavailable": "来源服务暂不可达", "invalid_response": "来源数据暂不可解析"][code] ?? (code.isEmpty ? "暂未读取到来源状态" : code)
}

private func sourceSymbol(_ source: String) -> String {
    switch source {
    case "gmail", "work_mail": "envelope"
    case "github": "chevron.left.forwardslash.chevron.right"
    case "apple_calendar", "google_calendar", "phone_calendar": "calendar"
    case "phone_health", "garmin": "heart"
    case "accounting": "creditcard"
    case "com_task": "checkmark.square"
    default: "newspaper"
    }
}
