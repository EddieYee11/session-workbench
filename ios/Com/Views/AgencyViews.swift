import SwiftUI
import ComCore

private enum AgencyMotion {
    static func response(_ reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.84) }
    static func transition(_ reduced: Bool) -> AnyTransition { reduced ? .opacity : .asymmetric(insertion: .offset(y: 9).combined(with: .opacity), removal: .scale(scale: 0.98).combined(with: .opacity)) }
}

struct AgencyDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    let card: JSON
    @State private var working = false
    @State private var pack: JSON = .null
    @State private var showSource = false
    var body: some View {
        DetailPage(title: "下一步") {
            DetailHeader(title: card["title"].string, subtitle: card["why"].string) {
                StatusPill(text: card["source_label"].string, tone: .accent)
            }
            if pack.isNull {
                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text(card["next_step"].string).font(TypeScale.headline)
                        Text("把已同步资料、当前进展和需要确认的问题放在一起。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary)
                        Button {
                            working = true
                            Task {
                                do { let response = try await model.agencyAction(card, action: "prepare"); withAnimation(AgencyMotion.response(reduce)) { pack = response["result"] }; Haptics.success() }
                                catch { model.banner = error.localizedDescription }
                                working = false
                            }
                        } label: { HStack { Text("整理现有资料"); if working { ProgressView() } else { Image(systemName: "doc.text.magnifyingglass") } } }
                            .buttonStyle(.primaryAction).disabled(working).accessibilityIdentifier("agency-prepare")
                    }
                }
            } else {
                Card(.highlighted(.accent)) {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        Label("资料已整理", systemImage: "checkmark.circle.fill").font(TypeScale.headline)
                        Text(pack["summary"].string).font(TypeScale.callout)
                        ForEach(Array(pack["evidence"].array.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(item["label"].string).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                                Text(item["value"].string).font(TypeScale.callout).textSelection(.enabled)
                            }
                        }
                        if !pack["questions"].array.isEmpty {
                            Text("还需要确认").font(TypeScale.headline)
                            ForEach(pack["questions"].array.map(\.string), id: \.self) { Text("• " + $0).font(TypeScale.callout) }
                        }
                        Text(pack["limits"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    }
                }.transition(AgencyMotion.transition(reduce))
            }
            Button("交给 Com 继续处理", systemImage: "bubble.left.and.bubble.right") {
                working = true
                Task {
                    do { _ = try await model.agencyAction(card, action: "discuss"); model.tab = .chat; dismiss() }
                    catch { model.banner = error.localizedDescription }
                    working = false
                }
            }.buttonStyle(.primaryFull).disabled(working)
            if card["kind"].string == "project" {
                Button("到工作看板查看", systemImage: "rectangle.3.group") { model.tab = .work; dismiss() }.buttonStyle(.quiet)
            } else if card["kind"].string != "goal" {
                Button("查看来源与原始事项", systemImage: "link") { showSource = true }.buttonStyle(.quiet)
            }
        }.onAppear { pack = card["preparation"] }
        .sheet(isPresented: $showSource) { MatterDetailView(matter: card) }
    }
}

struct GoalRow: View {
    @Environment(AppModel.self) private var model
    let goal: JSON
    @State private var working = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.md) {
                    IconBadge(symbol: goal["status"].string == "completed" ? "checkmark.circle" : "scope", tone: goal["status"].string == "completed" ? .success : .accent)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(goal["title"].string).font(TypeScale.headline)
                        Text(goal["completion_condition"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                }
                if !goal["next_step"].string.isEmpty { Text("下一步 · " + goal["next_step"].string).font(TypeScale.callout) }
                HStack {
                    StatusPill(text: goal["status"].string == "paused" ? "已暂停" : goal["status"].string == "completed" ? "已完成" : "持续跟进", tone: .neutral)
                    Spacer()
                    if goal["status"].string != "completed" {
                        Menu {
                            Button(goal["status"].string == "paused" ? "恢复跟进" : "暂停跟进") { act(goal["status"].string == "paused" ? "resume" : "pause") }
                            Button("我已完成这个目标", systemImage: "checkmark") { act("complete") }
                        } label: { if working { ProgressView() } else { Image(systemName: "ellipsis").frame(width: 44, height: 32) } }.disabled(working)
                    }
                }
            }
        }
    }
    private func act(_ action: String) {
        working = true
        Task { do { _ = try await model.agencyAction(goal, action: action); Haptics.success() } catch { model.banner = error.localizedDescription }; working = false }
    }
}

struct GoalList: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    var body: some View {
        DetailPage(title: "我的目标") {
            GoalsContent(adding: $adding)
        }.sheet(isPresented: $adding) { GoalEditor() }
    }
}

struct GoalsContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Binding var adding: Bool
    var body: some View {
        let goals = model.datasets["/personal/agency"]?["goals"].array ?? []
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("把在意的事，慢慢做成。").font(TypeScale.headline)
                    Text("明确下一步，在晨报和周复盘里持续跟进。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button { adding = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.buttonStyle(.quiet).accessibilityLabel("添加目标")
            }
            if goals.isEmpty { EmptyState(title: "从一个目标开始", description: "写下想要的结果，以及眼下能做的一小步。", symbol: "scope") }
            ForEach(goals.map(RemoteRow.init)) { row in GoalRow(goal: row.value).transition(AgencyMotion.transition(reduce)) }
        }.animation(AgencyMotion.response(reduce), value: goals.map { $0.id + $0["status"].string })
    }
}

struct GoalEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var outcome = ""
    @State private var next = ""
    @State private var working = false
    var body: some View {
        DetailPage(title: "添加目标") {
            Text("不需要一次想好全部，先确定结果和下一步。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary)
            GroupedCard {
                TextField("想做成什么", text: $title, axis: .vertical).lineLimit(1...3).rowPadding().accessibilityIdentifier("goal-title")
                TextField("做到怎样算完成", text: $outcome, axis: .vertical).lineLimit(2...4).rowPadding().accessibilityIdentifier("goal-outcome")
                TextField("眼下的下一小步", text: $next, axis: .vertical).lineLimit(2...4).rowPadding().accessibilityIdentifier("goal-next")
            }
            Text("Com 会定期核对进展、整理资料并给建议。你可以随时暂停。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            Button {
                working = true
                Task {
                    do {
                        _ = try await model.createPersonalGoal(title: title, outcome: outcome, next: next)
                        Haptics.success(); dismiss()
                    } catch { model.banner = error.localizedDescription }
                    working = false
                }
            } label: { HStack { Text("开始跟进"); Spacer(); if working { ProgressView() } else { Image(systemName: "arrow.right") } } }
                .buttonStyle(.primaryFull).disabled(working || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || outcome.isEmpty || next.isEmpty)
        }
    }
}

struct AgencySettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var paused = false
    @State private var intensity = "balanced"
    @State private var morning = Date()
    @State private var evening = Date()
    @State private var weekly = true
    @State private var saving = false
    private var settings: JSON { model.datasets["/personal/agency"]?["settings"] ?? .null }
    var body: some View {
        DetailPage(title: "主动性") {
            Card(.ink) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(paused ? "先安静一会儿。" : "有事记挂，适时来找你。").font(TypeScale.title).foregroundStyle(Palette.onInk)
                        .contentTransition(.opacity)
                    Text("先替你整理，再说值得你关注的事。").font(TypeScale.callout).foregroundStyle(Palette.onInkSecondary)
                }
            }
            GroupedCard {
                Toggle("暂停主动消息", isOn: $paused).rowPadding()
                Picker("额外提醒", selection: $intensity) { Text("安静").tag("quiet"); Text("适中").tag("balanced"); Text("积极").tag("active") }.pickerStyle(.segmented).rowPadding()
                Text(intensity == "quiet" ? "只保留固定简报，不额外打扰。" : intensity == "active" ? "每天最多 4 次额外主动提醒。" : "每天最多 2 次额外主动提醒。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).rowPadding()
            }
            GroupedCard {
                DatePicker("晨报", selection: $morning, displayedComponents: .hourAndMinute).rowPadding()
                DatePicker("晚间复盘", selection: $evening, displayedComponents: .hourAndMinute).rowPadding()
                Toggle("周日 20:30 周复盘", isOn: $weekly).rowPadding()
                Text("周复盘替代当天晚报。23:00–08:00 为默认安静时段；时间按上海时区。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).rowPadding()
            }.environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            let notifications = model.datasets["/personal/agency"]?["notifications"] ?? .null
            Label(notifications["delivery"].string == "apns" ? "系统推送已接通" : "系统推送待接通，后台刷新可能延迟", systemImage: "bell")
                .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            Button {
                saving = true
                Task {
                    do {
                        var items = settings["items"].array.filter { !["morning-briefing", "evening-review", "weekly-review"].contains($0.id) }
                        @MainActor func item(_ id: String, _ title: String, _ date: Date, days: [JSON] = []) -> JSON {
                            let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
                            let old = settings["items"].array.first { $0.id == id } ?? .null
                            var fields: [String: JSON] = ["id": .string(id), "title": .string(title), "at": .string(f.string(from: date)), "enabled": .bool(id != "weekly-review" || weekly), "version": .number(Double(max(1, old["version"].int))), "focus": .string(id == "weekly-review" ? "核对真实目标的进展与阻塞，提出下周最重要的一小步。" : "只说最重要的事项、下一步与资料缺口。")]
                            if !days.isEmpty { fields["days"] = .array(days) }
                            return .object(fields)
                        }
                        items += [item("morning-briefing", "每日晨报", morning), item("evening-review", "晚间复盘", evening), item("weekly-review", "每周复盘", time("20:30"), days: [.number(6)])]
                        try await model.saveAgencySettings(["paused": .bool(paused), "intensity": .string(intensity), "items": .array(items)])
                        Haptics.success(); dismiss()
                    } catch { model.banner = error.localizedDescription }
                    saving = false
                }
            } label: { HStack { Text("保存安排"); Spacer(); if saving { ProgressView() } else { Image(systemName: "checkmark") } } }.buttonStyle(.primaryFull).disabled(saving)
        }
        .animation(AgencyMotion.response(reduce), value: paused)
        .animation(AgencyMotion.response(reduce), value: intensity)
        .onAppear {
            paused = settings["paused"].bool; intensity = settings["intensity"].string.isEmpty ? "balanced" : settings["intensity"].string
            morning = time(settings["items"].array.first { $0.id == "morning-briefing" }?["at"].string ?? "09:00")
            evening = time(settings["items"].array.first { $0.id == "evening-review" }?["at"].string ?? "21:00")
            weekly = settings["items"].array.first { $0.id == "weekly-review" }?["enabled"].bool ?? true
        }
    }
    private func time(_ value: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.date(from: value) ?? Date()
    }
}
