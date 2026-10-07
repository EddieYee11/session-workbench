import SwiftUI
import ComCore

struct TodayView: View {
    @Environment(AppModel.self) private var model
    private var briefing: JSON { model.datasets["/personal/briefing"] ?? .null }
    private var overview: JSON { model.datasets["/personal/overview"] ?? .null }
    var body: some View {
        ScreenScaffold(title: "今天", subtitle: Date().formatted(.dateTime.month(.wide).day().weekday(.wide)), freshness: "/personal/briefing") {
            // 1 · Focus: the one hero element of the screen.
            if let focus = briefing["cards"].array.first {
                Button { model.selectedMatter = focus } label: { TodayFocusCard(matter: focus) }.buttonStyle(MessagePressStyle()).detailSource("matter-" + focus.id)
            } else {
                Card(padding: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        HStack(alignment: .center, spacing: Space.md) {
                            CompanionPortrait(size: 44)
                            Text("你好，小野").font(TypeScale.title)
                        }
                        Text(model.errors["/personal/briefing"] == nil ? "这里会整理你的日程、消息与值得留意的变化。当前没有待看的事项，我们随时可以聊。" : "暂时没有连上简报来源。你可以下拉重试，或先继续聊天。")
                            .font(TypeScale.callout).foregroundStyle(Palette.textSecondary).lineSpacing(4)
                        Button("聊一聊", systemImage: "bubble.left") { model.tab = .chat }.buttonStyle(.primaryAction)
                    }
                }
            }
            // 2 · Worth noticing
            if briefing["cards"].array.count > 1 {
                GroupSection("值得留意") {
                    GroupedCard(dividerInset: Layout.rowInset) {
                        ForEach(briefing["cards"].array.dropFirst().map(RemoteRow.init)) { row in
                            let summary = row.value["why"].string.isEmpty ? row.value["next_step"].string : row.value["why"].string
                            Button { model.selectedMatter = row.value } label: {
                                ListRow(symbol: sourceSymbol(row.value["source"].string), title: row.value["title"].string,
                                        subtitle: summary, subtitleLines: 3, meta: sourceName(row.value["source"].string))
                            }.buttonStyle(.row).detailSource("matter-" + row.id)
                        }
                    }
                }
            }
            // 3 · Calendar
            if overview["calendar"]["available"].bool {
                GroupSection("日程", footer: overview["calendar"]["source"].string + " · 未来 14 天") {
                    GroupedCard(dividerInset: Space.lg + 16) {
                        if overview["calendar"]["items"].array.isEmpty {
                            Text("已连接日历，当前范围内没有日程").font(TypeScale.callout).foregroundStyle(Palette.textSecondary).rowPadding()
                        }
                        ForEach(overview["calendar"]["items"].array.map(RemoteRow.init)) { row in
                            HStack(alignment: .center, spacing: Space.md) {
                                Capsule().fill(Palette.accent).frame(width: 4, height: 34)
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text(row.value["title"].string).font(TypeScale.rowTitle)
                                    Text(calendarTime(row.value["start"])).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }.rowPadding()
                        }
                    }
                }
            }
            // 4 · Money
            if overview["finance"]["available"].bool {
                GroupSection("账务") {
                    ForEach(overview["finance"]["totals"].object.keys.sorted(), id: \.self) { currency in
                        let totals = overview["finance"]["totals"][currency]
                        Card {
                            VStack(alignment: .leading, spacing: Space.md) {
                                Text("今日支出 · \(currency)").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                                Text(money(totals["today_expense_minor"], currency: currency)).font(TypeScale.largeTitle.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                                Rectangle().fill(Palette.separator).frame(height: 0.5)
                                HStack { Text("本月支出"); Spacer(); Text(money(totals["expense_minor"], currency: currency)).monospacedDigit() }.font(TypeScale.callout)
                                Text("原账本 · \(overview["finance"]["month"].string)\(overview["finance"]["stale"].bool ? " · 缓存数据" : "")").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                            }
                        }
                    }
                }
            }
            // 5 · Body
            GroupSection("身体与状态") {
                Card {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        HStack {
                            Label("Apple 健康", systemImage: "heart").font(TypeScale.headline).symbolVariant(.fill).foregroundStyle(Palette.textPrimary)
                            Spacer()
                            Button(model.devices.readingHealth ? "读取中…" : "读取") { Task { await model.devices.readHealth() } }.buttonStyle(.secondaryAction).disabled(model.devices.readingHealth)
                        }
                        if !model.devices.healthNote.isEmpty {
                            Text(model.devices.healthNote).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        }
                        if model.localHealth.isNull {
                            Text("在设置中选择健康权限后，可以读取最近 24 小时的活动、心率与睡眠。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Space.sm)], alignment: .leading, spacing: Space.sm) {
                                healthValue("步数", key: "steps", unit: "")
                                healthValue("心率", key: "heart_rate_average", unit: "bpm")
                                healthValue("睡眠", key: "sleep_hours", unit: "h")
                                healthValue("活动能量", key: "active_energy_kcal", unit: "kcal")
                                healthValue("静息心率", key: "resting_heart_rate", unit: "bpm")
                            }
                            let workouts = model.localHealth["workouts"].array
                            if !workouts.isEmpty {
                                VStack(alignment: .leading, spacing: Space.sm) {
                                    ForEach(workouts.map(RemoteRow.init)) { row in
                                        LabeledContent("运动记录", value: calendarTime(row.value["start"]) + " · " + (row.value["duration_seconds"].double / 60).formatted(.number.precision(.fractionLength(0))) + " 分钟").font(TypeScale.footnote)
                                    }
                                }
                            }
                            Text("Apple HealthKit · 更新于 " + model.localHealth["updated_at"].string).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                            DisclosureGroup("更多数据说明") {
                                VStack(alignment: .leading, spacing: Space.sm) {
                                    Text("采集区间：" + model.localHealth["start"].string + " 至 " + model.localHealth["end"].string)
                                    if workouts.isEmpty { Text("采集区间内无可用运动记录") }
                                    if !model.localHealth["missing_reason"].string.isEmpty { Text(model.localHealth["missing_reason"].string) }
                                    Text("健康数据默认留在本机；同步到 mini 可在设置中开启。")
                                }.font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.sm)
                            }.font(TypeScale.footnote.weight(.medium)).tint(Palette.textSecondary).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
            // 6 · Sources
            GroupSection("数据连接") {
                ConnectionList()
            } trailing: {
                NavigationLink("管理连接") { ConnectionsView() }.buttonStyle(.quiet)
            }
        }.refreshable { await model.refresh(.today) }
    }
    private func healthValue(_ title: String, key: String, unit: String) -> some View {
        MetricTile(title: title, value: model.localHealth[key].isNull ? "—" : model.localHealth[key].double.formatted(.number.precision(.fractionLength(key == "sleep_hours" ? 1 : 0))) + (unit.isEmpty ? "" : " " + unit))
    }
}

/// The screen's focal element: inverted ink card for the first briefing item.
struct TodayFocusCard: View {
    let matter: JSON
    var body: some View {
        let summary = matter["why"].string.isEmpty ? matter["next_step"].string : matter["why"].string
        Card(.ink, padding: Space.xl) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.sm) {
                    Text("为你整理").font(TypeScale.caption).foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, Space.sm + 2).padding(.vertical, Space.xs + 1).background(Palette.accent, in: .capsule)
                    Text("今日焦点").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.onInkSecondary).padding(.top, Space.xs)
                    Spacer(minLength: 0)
                    CompanionPortrait(size: 52).rotationEffect(.degrees(-7))
                }
                Text(matter["title"].string).font(TypeScale.title).foregroundStyle(Palette.onInk).lineLimit(3)
                if !summary.isEmpty { Text(summary).font(TypeScale.subheadline).foregroundStyle(Palette.onInkSecondary).lineLimit(3) }
                HStack(alignment: .center) {
                    Label(sourceName(matter["source"].string), systemImage: sourceSymbol(matter["source"].string))
                        .font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.onInkSecondary)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.onAccent)
                        .frame(width: 44, height: 44).background(Palette.accent, in: .circle)
                }.padding(.top, Space.xs)
            }
        }
        .multilineTextAlignment(.leading)
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
            DetailHeader(title: matter["title"].string, subtitle: matter["what"].string) {
                StatusPill(text: sourceName(matter["source"].string), tone: .accent)
            }
            if !matter["next_step"].string.isEmpty {
                Card { VStack(alignment: .leading, spacing: Space.sm) {
                    Label("建议下一步", systemImage: "arrow.turn.down.right").font(TypeScale.headline)
                    RichText(text: matter["next_step"].string, font: TypeScale.callout)
                } }
            }
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextField("补充要求（可选）", text: $goal, axis: .vertical).lineLimit(1...3).insetField()
                    Button {
                        Task {
                            do { _ = try await model.mutate("/personal/matters/" + matter.id.pathEncoded + "/action", fields: ["goal": .string(goal.isEmpty ? "分析这件事并给出下一步" : goal)]); dismiss(); model.tab = .chat; await model.refresh(.chat) }
                            catch { model.banner = error.localizedDescription }
                        }
                    } label: { Label("交给 Com", systemImage: "arrow.up.right") }.buttonStyle(.primaryFull)
                    ViewThatFits {
                        HStack(spacing: Space.sm) { feedback("关注", "follow"); feedback("稍后", "later"); feedback("已处理", "handled") }
                        VStack(alignment: .leading, spacing: Space.sm) { feedback("关注", "follow"); feedback("稍后", "later"); feedback("已处理", "handled") }
                    }
                }
            }
            DisclosureGroup("纠正或关闭提醒") {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextField("更正事实", text: $correction, axis: .vertical).lineLimit(2...4).insetField()
                    Button("保存更正") { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string("correct"), "text": .string(correction)], refresh: .today) } }.buttonStyle(.secondaryAction).disabled(correction.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("不再提醒") { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string("mute")], refresh: .today); dismiss() } }.buttonStyle(.quiet)
                }.padding(.top, Space.md)
            }.font(TypeScale.callout)
            // Disclosure zone
            GroupedCard {
                if !matter["why"].string.isEmpty {
                    DisclosureGroup("背景说明") { RichText(text: matter["why"].string).padding(.top, Space.sm) }
                        .font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                }
                if !matter["next_step"].string.isEmpty {
                    DisclosureGroup("下一步建议") { RichText(text: matter["next_step"].string).padding(.top, Space.sm) }
                        .font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                }
                RawDetails(title: "查看来源事实", value: matter["facts"]).rowPadding()
                if !matter["action_context"].isNull { RawDetails(title: "关联背景", value: matter["action_context"]).rowPadding() }
            }
            Button("解除事项关联", role: .destructive) { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/unlink", refresh: .today) } }
                .buttonStyle(.quiet).frame(maxWidth: .infinity)
        }
    }
    private func feedback(_ title: String, _ action: String) -> some View {
        Button(title) { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string(action)], refresh: .today); if action != "follow" { dismiss() } } }.buttonStyle(.secondaryAction)
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
