import SwiftUI
import ComCore

struct TodayView: View {
    @Environment(AppModel.self) private var model
    private var briefing: JSON { model.datasets["/personal/briefing"] ?? .null }
    private var overview: JSON { model.datasets["/personal/overview"] ?? .null }
    var body: some View {
        PageCanvas {
            VStack(alignment: .leading, spacing: 6) {
                PageHeading(title: "今天", subtitle: "")
                HStack { Text(Date().formatted(.dateTime.month(.wide).day().weekday(.wide))).font(.caption).foregroundStyle(.secondary); Spacer(); Freshness(path: "/personal/briefing") }
            }
            if briefing["cards"].array.isEmpty {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("你好，小野").font(.title2.weight(.semibold))
                        Text(model.errors["/personal/briefing"] == nil ? "这里会整理你的日程、消息与值得留意的变化。当前没有待看的事项，我们随时可以聊。" : "暂时没有连上简报来源。你可以下拉重试，或先继续聊天。")
                            .foregroundStyle(.secondary).lineSpacing(5)
                        Button("聊一聊", systemImage: "bubble.left") { model.tab = .chat }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                }
            }
            if let focus = briefing["cards"].array.first {
                Button { model.selectedMatter = focus } label: { TodayFocusCard(matter: focus) }.buttonStyle(.plain).detailSource("matter-" + focus.id)
            }
            if briefing["cards"].array.count > 1 { Eyebrow(text: "值得留意") }
            ForEach(briefing["cards"].array.dropFirst().map(RemoteRow.init)) { row in
                Button { model.selectedMatter = row.value } label: {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: sourceSymbol(row.value["source"].string))
                            .font(.system(size: 25)).foregroundStyle(Palette.cyan)
                            .frame(width: 40, height: 46)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(row.value["title"].string).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            let summary = row.value["why"].string.isEmpty ? row.value["next_step"].string : row.value["why"].string
                            if !summary.isEmpty { Text(summary).font(.body).foregroundStyle(.secondary).lineSpacing(4).lineLimit(5) }
                            HStack(spacing: 8) {
                                Text(sourceName(row.value["source"].string)).font(.caption)
                                Spacer()
                                Label("查看", systemImage: "arrow.up.right").font(.caption)
                            }.foregroundStyle(.secondary).padding(.top, 5)
                        }
                    }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Palette.surface, in: .rect(cornerRadius: 22))
                }.buttonStyle(.plain).detailSource("matter-" + row.id)
            }
            if overview["calendar"]["available"].bool {
                Eyebrow(text: "日程")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 18) {
                        if overview["calendar"]["items"].array.isEmpty { Text("已连接日历，当前范围内没有日程").foregroundStyle(.secondary).font(.subheadline) }
                        ForEach(overview["calendar"]["items"].array.map(RemoteRow.init)) { row in
                            HStack(alignment: .top, spacing: 15) {
                                RoundedRectangle(cornerRadius: 2).fill(Palette.cyan).frame(width: 3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.value["title"].string).font(.subheadline.weight(.medium))
                                    Text(calendarTime(row.value["start"])).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        Text(overview["calendar"]["source"].string + " · 未来 14 天").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if overview["finance"]["available"].bool {
                Eyebrow(text: "账务")
                ForEach(overview["finance"]["totals"].object.keys.sorted(), id: \.self) { currency in
                    let totals = overview["finance"]["totals"][currency]
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("今日支出 · \(currency)").font(.caption).foregroundStyle(.secondary)
                            Text(money(totals["today_expense_minor"], currency: currency)).font(.largeTitle.weight(.medium)).contentTransition(.numericText())
                            HStack { Text("本月支出"); Spacer(); Text(money(totals["expense_minor"], currency: currency)) }.font(.subheadline)
                            Text("原账本 · \(overview["finance"]["month"].string)\(overview["finance"]["stale"].bool ? " · 缓存数据" : "")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Eyebrow(text: "身体与状态")
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Label("Apple 健康", systemImage: "heart").font(.headline); Spacer(); Button("读取") { Task { await model.devices.readHealth() } }.font(.caption) }
                    if model.localHealth.isNull { Text("在设置中选择健康权限后，可以读取最近 24 小时的活动、心率与睡眠。").font(.subheadline).foregroundStyle(.secondary) }
                    else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 24) { healthValue("步数", key: "steps", unit: ""); healthValue("心率", key: "heart_rate_average", unit: "bpm"); healthValue("睡眠", key: "sleep_hours", unit: "h") }
                            VStack(alignment: .leading, spacing: 18) { healthValue("步数", key: "steps", unit: ""); healthValue("心率", key: "heart_rate_average", unit: "bpm"); healthValue("睡眠", key: "sleep_hours", unit: "h") }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 24) { healthValue("活动能量", key: "active_energy_kcal", unit: "kcal"); healthValue("静息心率", key: "resting_heart_rate", unit: "bpm") }
                            VStack(alignment: .leading, spacing: 18) { healthValue("活动能量", key: "active_energy_kcal", unit: "kcal"); healthValue("静息心率", key: "resting_heart_rate", unit: "bpm") }
                        }
                        if model.localHealth["workouts"].array.isEmpty { Text("采集区间内无可用运动记录").font(.caption).foregroundStyle(.secondary) }
                        else {
                            ForEach(model.localHealth["workouts"].array.map(RemoteRow.init)) { row in
                                LabeledContent("运动记录", value: calendarTime(row.value["start"]) + " · " + (row.value["duration_seconds"].double / 60).formatted(.number.precision(.fractionLength(0))) + " 分钟").font(.caption)
                            }
                        }
                        if !model.localHealth["missing_reason"].string.isEmpty { Text(model.localHealth["missing_reason"].string).font(.caption).foregroundStyle(.secondary) }
                        Text("采集区间：" + model.localHealth["start"].string + " 至 " + model.localHealth["end"].string).font(.caption).foregroundStyle(.secondary)
                        Text("Apple HealthKit · 更新于 " + model.localHealth["updated_at"].string).font(.caption).foregroundStyle(.secondary)
                        Text("健康数据默认留在本机；同步到 mini 可在设置中开启。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("数据连接").font(.headline)
                    ForEach(Array(briefing["source_status"]["sources"].array.enumerated()), id: \.offset) { _, status in
                        let source = status["name"].string
                        HStack(alignment: .top) { Text(sourceName(source)); Spacer(); Text(status["status"].string.isEmpty ? status["error"].string : status["status"].string).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }.font(.caption)
                    }
                    if !overview["calendar"]["available"].bool { Label("日历：" + sourceFailure(overview["calendar"]["error_code"].string), systemImage: "calendar.badge.exclamationmark").font(.caption).foregroundStyle(.secondary) }
                    if !overview["finance"]["available"].bool { Label("账务：" + sourceFailure(overview["finance"]["error_code"].string), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }
                    Button("管理连接") { model.showSettings = true }.font(.subheadline)
                }
            }
        }.refreshable { await model.refresh(.today) }
    }
    private func healthValue(_ title: String, key: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(model.localHealth[key].isNull ? "—" : model.localHealth[key].double.formatted(.number.precision(.fractionLength(key == "sleep_hours" ? 1 : 0))) + (unit.isEmpty ? "" : " " + unit)).font(.title3.weight(.semibold)).monospacedDigit()
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
        NavigationStack {
            PageCanvas {
                Pill(text: sourceName(matter["source"].string), color: Palette.cyan)
                PageHeading(title: matter["title"].string, subtitle: matter["what"].string)
                if !matter["why"].string.isEmpty { RichText(text: matter["why"].string) }
                if !matter["next_step"].string.isEmpty { SurfaceCard { RichText(text: matter["next_step"].string) } }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("想如何处理这件事？", text: $goal, axis: .vertical).lineLimit(2...6)
                        Button("交给 Com 继续处理", systemImage: "arrow.up.right") {
                            Task {
                                do { _ = try await model.mutate("/personal/matters/" + matter.id.pathEncoded + "/action", fields: ["goal": .string(goal.isEmpty ? "分析这件事并给出下一步" : goal)]); dismiss(); model.tab = .chat; await model.refresh(.chat) }
                                catch { model.banner = error.localizedDescription }
                            }
                        }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        ViewThatFits {
                            HStack { feedback("关注", "follow"); feedback("稍后", "later"); feedback("已处理", "handled") }
                            VStack(alignment: .leading) { feedback("关注", "follow"); feedback("稍后", "later"); feedback("已处理", "handled") }
                        }
                        TextField("纠正来源中的事实", text: $correction, axis: .vertical).lineLimit(2...5)
                        Button("保存纠正") { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string("correct"), "text": .string(correction)], refresh: .today) } }.disabled(correction.trimmingCharacters(in: .whitespaces).isEmpty)
                        feedback("不再提醒", "mute")
                    }
                }
                RawDetails(title: "查看来源事实", value: matter["facts"])
                if !matter["action_context"].isNull { RawDetails(title: "关联背景", value: matter["action_context"]) }
                Button("解除事项关联") { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/unlink", refresh: .today) } }.font(.caption)
            }.navigationTitle("事项").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
    private func feedback(_ title: String, _ action: String) -> some View {
        Button(title) { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string(action)], refresh: .today); if action != "follow" { dismiss() } } }.buttonStyle(.bordered).buttonBorderShape(.capsule)
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
