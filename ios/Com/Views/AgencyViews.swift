import SwiftUI
import ComCore

private enum AgencyMotion {
    static func response(_ reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.84) }
    static func transition(_ reduced: Bool) -> AnyTransition { reduced ? .opacity : .asymmetric(insertion: .offset(y: 9).combined(with: .opacity), removal: .scale(scale: 0.98).combined(with: .opacity)) }
}

struct AgencyHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var selected: JSON?
    @State private var showSettings = false
    @State private var showGoals = false
    @State private var showAll = false
    @State private var result = ""
    private var data: JSON { model.datasets["/personal/agency"] ?? .null }
    private var cards: [JSON] { data["cards"].array.filter { !["context", "finance"].contains($0["kind"].string) } }
    private var goals: [JSON] { data["goals"].array.filter { $0["status"].string == "active" || $0["status"].string == "blocked" } }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Label(data["settings"]["paused"].bool ? "主动整理已暂停" : Date().formatted(.dateTime.month().day().weekday()), systemImage: data["settings"]["paused"].bool ? "pause.circle" : "sun.max")
                    Freshness(path: "/personal/agency")
                }.font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                    .buttonStyle(.quiet).accessibilityLabel("主动性设置")
            }
            FinanceHome()
            if let focus = cards.first {
                AgencyActionCard(card: focus, prominent: true, open: { selected = focus }, completed: { result = $0 })
                    .id(focus.id).transition(AgencyMotion.transition(reduce))
            } else {
                Card(.ink, padding: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("给重要的事，留一点空间。").font(TypeScale.title).foregroundStyle(Palette.onInk)
                        Text(model.errors["/personal/agency"] != nil ? "暂时没连上主动整理，下拉重试。" : "眼下没有待处理的事项。可以告诉我一个你想持续推进的目标。")
                            .font(TypeScale.callout).foregroundStyle(Palette.onInkSecondary)
                        Button("添加一个目标", systemImage: "plus") { showGoals = true }.buttonStyle(.primaryAction)
                    }
                }
            }
            if !result.isEmpty {
                Label(result, systemImage: "checkmark.circle.fill").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    .transition(AgencyMotion.transition(reduce)).accessibilityIdentifier("agency-action-result")
            }
            if cards.count > 1 {
                GroupSection("建议下一步") {
                    VStack(spacing: Space.md) {
                        ForEach((showAll ? Array(cards.dropFirst()) : Array(cards.dropFirst().prefix(2))).map(RemoteRow.init)) { row in
                            AgencyActionCard(card: row.value, open: { selected = row.value }, completed: { result = $0 })
                                .transition(AgencyMotion.transition(reduce))
                        }
                    }
                } trailing: {
                    if cards.count > 3 { Button(showAll ? "收起" : "全部 \(cards.count)") { withAnimation(AgencyMotion.response(reduce)) { showAll.toggle() } }.buttonStyle(.quiet) }
                }
            }
            GroupSection("近期目标") {
                if goals.isEmpty {
                    Button { showGoals = true } label: {
                        HStack(spacing: Space.md) {
                            IconBadge(symbol: "scope", tone: .accent)
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text("把一件在意的事交给我记挂").font(TypeScale.rowTitle)
                                Text("设定结果、下一步，持续跟进。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                            }
                            Spacer(); Image(systemName: "plus")
                        }.rowPadding()
                    }.buttonStyle(.row).background(Palette.surface, in: .rect(cornerRadius: Radius.lg))
                } else {
                    VStack(spacing: Space.md) { ForEach(goals.prefix(3).map(RemoteRow.init)) { row in GoalRow(goal: row.value) } }
                }
            } trailing: { Button("管理") { showGoals = true }.buttonStyle(.quiet) }
            if let report = data["reports"].array.first {
                GroupSection("最近为你整理") {
                    Button { Task { await model.locateMessage(report.id) } } label: {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(report["text"].string).font(TypeScale.callout).lineLimit(3).multilineTextAlignment(.leading)
                            Label("到聊天继续", systemImage: "arrow.up.right").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        }.rowPadding()
                    }.buttonStyle(.row).background(Palette.surface, in: .rect(cornerRadius: Radius.lg))
                }
            }
            let missing = data["sources"].array.filter { $0["status"].string != "connected" || $0["stale"].bool }
            if !missing.isEmpty {
                NavigationLink { ConnectionsView() } label: {
                    HStack {
                        Image(systemName: "link.badge.plus")
                        Text("\(missing.count) 项资料尚未就绪，建议仅基于已同步内容").font(TypeScale.footnote)
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.foregroundStyle(Palette.textSecondary)
                }.buttonStyle(.quiet)
            }
        }
        .animation(AgencyMotion.response(reduce), value: cards.map(\.id))
        .animation(AgencyMotion.response(reduce), value: result)
        .sheet(item: Binding(get: { selected.map(RemoteRow.init) }, set: { selected = $0?.value })) { AgencyDetail(card: $0.value) }
        .sheet(isPresented: $showSettings) { AgencySettings() }
        .sheet(isPresented: $showGoals) { GoalList() }
    }
}

struct AgencyActionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let card: JSON
    var prominent = false
    var open: () -> Void
    var completed: (String) -> Void
    @State private var busy = false
    private var symbol: String {
        switch card["kind"].string { case "meeting": "calendar"; case "finance": "creditcard"; case "goal": "scope"; case "delivery", "project": "desktopcomputer"; default: "tray.full" }
    }
    private var foreground: Color { prominent ? Palette.onInk : Palette.textPrimary }
    var body: some View {
        Card(prominent ? .ink : .standard, padding: prominent ? Space.xl : Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Label(prominent ? "今天先做这件事" : card["source_label"].string, systemImage: symbol)
                        .font(TypeScale.footnote.weight(.medium)).foregroundStyle(prominent ? Palette.onAccent : Palette.textSecondary)
                        .padding(.horizontal, prominent ? 10 : 0).padding(.vertical, prominent ? 6 : 0)
                        .background(prominent ? Palette.accent : .clear, in: .capsule)
                    Spacer()
                    if !card["preparation"].isNull { Image(systemName: "doc.text").foregroundStyle(prominent ? Palette.onInkSecondary : Palette.textTertiary).accessibilityLabel("资料已整理") }
                }
                Button(action: open) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(card["title"].string).font(prominent ? TypeScale.title : TypeScale.headline).foregroundStyle(foreground).lineLimit(3)
                        if !(card["next_step"].string.isEmpty && card["why"].string.isEmpty) {
                            Text(card["next_step"].string == "结合资料分析并提出下一步" || card["next_step"].string.isEmpty ? card["why"].string : card["next_step"].string)
                                .font(TypeScale.callout).foregroundStyle(prominent ? Palette.onInkSecondary : Palette.textSecondary).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }.buttonStyle(.plain)
                HStack(spacing: Space.sm) {
                    Button { open() } label: { Label(card["preparation"].isNull ? "看下一步" : "查看已整理材料", systemImage: "arrow.up.right") }.buttonStyle(.primaryAction)
                    Button { act("later", message: "已留到稍后，届时再跟进") } label: {
                        if busy { ProgressView() } else { Text("晚点") }
                    }.buttonStyle(.secondaryAction).disabled(busy)
                    Menu {
                        if card["kind"].string == "goal" { Button("暂停这个目标") { act("pause", message: "目标已暂停") } }
                        else {
                            Button("这件事已处理", systemImage: "checkmark") { act("handled", message: "已处理，停止重复提醒") }
                            if card["kind"].string != "project" { Button("不再关注这件事", systemImage: "bell.slash") { act("mute", message: "已停止关注这件事") } }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(foreground) }.disabled(busy)
                }
            }
        }
    }
    private func act(_ action: String, message: String) {
        busy = true
        Task {
            do {
                _ = try await model.agencyAction(card, action: action)
                withAnimation(AgencyMotion.response(reduce)) { completed(message) }
                Haptics.success()
            } catch { model.banner = error.localizedDescription }
            busy = false
        }
    }
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
