import SwiftUI
import ComCore

private enum AgencyMotion {
    static func response(_ reduced: Bool) -> Animation { ComMotion.reduced(reduced, ComMotion.settle) }
    static func transition(_ reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .asymmetric(
            insertion: .modifier(active: BlurShift(y: 9, blur: 3, opacity: 0), identity: BlurShift()),
            removal: .scale(scale: 0.98).combined(with: .opacity))
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
    /// 整理/交给 Com 失败留页，勿假跳聊天。
    @State private var failNote = ""
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
                            guard !working else { return }
                            working = true
                            failNote = ""
                            Task {
                                do {
                                    let response = try await model.agencyAction(card, action: "prepare")
                                    withAnimation(AgencyMotion.response(reduce)) { pack = response["result"] }
                                    Haptics.success()
                                    // cards 没刷齐时 agencyCardsNote 已写；页内再露一句，别假成列表已齐。
                                    if !model.agencyCardsNote.isEmpty {
                                        failNote = model.agencyCardsNote
                                    }
                                } catch {
                                    failNote = "整理没成：" + error.localizedDescription + "——还可以再试。不会假装已整理好。"
                                }
                                working = false
                            }
                        } label: { HStack { Text(working ? "整理中…" : "整理现有资料"); if working { ProgressView() } else { Image(systemName: "doc.text.magnifyingglass") } } }
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
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                    .accessibilityIdentifier("agency-detail-fail")
            }
            Button("交给 Com 继续处理", systemImage: "bubble.left.and.bubble.right") {
                guard !working else { return }
                working = true
                failNote = ""
                Task {
                    do {
                        _ = try await model.agencyAction(card, action: "discuss")
                        model.showWaiting = false
                        model.tab = .chat
                        dismiss()
                    } catch {
                        failNote = "没交出去：" + error.localizedDescription + "——还可以再试。不会假装已交办。"
                    }
                    working = false
                }
            }.buttonStyle(.primaryFull).disabled(working).accessibilityIdentifier("agency-discuss")
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
    @State private var failNote = ""
    /// 列表里的最新状态（agency 拉齐后跟服务端走，别死盯入参快照）。
    private var current: JSON {
        model.datasets["/personal/agency"]?["goals"].array.first { $0.id == goal.id } ?? goal
    }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.md) {
                    IconBadge(symbol: current["status"].string == "completed" ? "checkmark.circle" : "scope", tone: current["status"].string == "completed" ? .success : .accent)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(current["title"].string).font(TypeScale.headline)
                        Text(current["completion_condition"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                }
                if !current["next_step"].string.isEmpty { Text("下一步 · " + current["next_step"].string).font(TypeScale.callout) }
                HStack {
                    StatusPill(text: current["status"].string == "paused" ? "已暂停" : current["status"].string == "completed" ? "已完成" : "持续跟进", tone: .neutral)
                    Spacer()
                    if current["status"].string != "completed" {
                        Menu {
                            Button(current["status"].string == "paused" ? "恢复跟进" : "暂停跟进") { act(current["status"].string == "paused" ? "resume" : "pause") }
                            Button("我已完成这个目标", systemImage: "checkmark") { act("complete") }
                        } label: { if working { ProgressView() } else { Image(systemName: "ellipsis").frame(width: 44, height: 32) } }.disabled(working)
                    }
                }
                if !failNote.isEmpty {
                    InlineNotice(text: failNote, tone: .danger)
                        .accessibilityIdentifier("goal-act-fail")
                }
            }
        }
    }
    private func act(_ action: String) {
        guard !working else { return }
        working = true
        failNote = ""
        Task {
            do {
                _ = try await model.agencyAction(current, action: action)
                Haptics.success()
                // 状态已改但列表没刷齐时 agencyGoalsNote 已写；行内再露一句。
                if !model.agencyGoalsNote.isEmpty {
                    failNote = model.agencyGoalsNote
                }
            } catch {
                let head = action == "complete" ? "标记完成没成"
                    : action == "pause" ? "暂停没成"
                    : "恢复没成"
                failNote = head + "：" + error.localizedDescription + "——还可以再试。不会假装状态已改。"
            }
            working = false
        }
    }
}

struct GoalList: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    var body: some View {
        DetailPage(title: "我的目标") {
            GoalsContent(adding: $adding, loading: loading || !loadedOnce, failNote: failNote, retrying: loading) {
                Task { await refreshGoals() }
            }
        }
        .task { await refreshGoals() }
        .sheet(isPresented: $adding) { GoalEditor() }
    }
    private func refreshGoals() async {
        guard !loading else { return }
        loading = true
        failNote = ""
        defer {
            loading = false
            loadedOnce = true
        }
        let path = "/personal/agency"
        if await model.load(path) != nil {
            model.agencyGoalsNote = ""
            return
        }
        let err = model.errors[path] ?? ""
        failNote = err.isEmpty
            ? "目标还没拉齐——检查配对或网络后再试"
            : "目标没拉齐：" + err + "——可再试"
    }
}

struct GoalsContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Binding var adding: Bool
    var loading: Bool = false
    var failNote: String = ""
    var retrying: Bool = false
    var onRetry: (() -> Void)? = nil
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
            if loading {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在拉齐目标…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                .accessibilityLabel("正在拉齐目标")
            }
            if !model.agencyGoalsNote.isEmpty {
                InlineNotice(text: model.agencyGoalsNote, tone: .danger)
                    .accessibilityIdentifier("agency-goals-create-reload-fail")
            }
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                if let onRetry {
                    Button(retrying ? "重试中…" : "再试一次") {
                        guard !retrying else { return }
                        onRetry()
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(retrying)
                    .accessibilityIdentifier("agency-goals-retry")
                }
            }
            if goals.isEmpty && !loading {
                EmptyState(title: failNote.isEmpty ? "还没有目标" : "目标还没读上",
                           description: failNote.isEmpty
                            ? "写下想做成的事，以及眼下能迈出的一小步——晨报和周复盘里我会跟着问进度。"
                            : "先重试拉齐；通了再写新目标，或稍后再看晨报跟进。",
                           symbol: "scope")
            }
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
    @State private var failNote = ""
    var body: some View {
        DetailPage(title: "添加目标") {
            Text("不需要一次想好全部，先确定结果和下一步。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary)
            GroupedCard {
                TextField("想做成什么", text: $title, axis: .vertical).lineLimit(1...3).rowPadding().accessibilityIdentifier("goal-title")
                TextField("做到怎样算完成", text: $outcome, axis: .vertical).lineLimit(2...4).rowPadding().accessibilityIdentifier("goal-outcome")
                TextField("眼下的下一小步", text: $next, axis: .vertical).lineLimit(2...4).rowPadding().accessibilityIdentifier("goal-next")
            }
            Text("Com 会定期核对进展、整理资料并给建议。你可以随时暂停。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                    .accessibilityIdentifier("goal-create-fail")
            }
            Button {
                guard !working else { return }
                working = true
                failNote = ""
                Task {
                    do {
                        _ = try await model.createPersonalGoal(title: title, outcome: outcome, next: next)
                        Haptics.success(); dismiss()
                    } catch {
                        failNote = "没建上：" + error.localizedDescription + "——还可以再试。表单还在，不会假装已建。"
                    }
                    working = false
                }
            } label: { HStack { Text(working ? "创建中…" : "开始跟进"); Spacer(); if working { ProgressView() } else { Image(systemName: "arrow.right") } } }
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
    /// 保存失败留页；成功才 dismiss。
    @State private var failNote = ""
    @State private var loading = false
    @State private var loadFail = ""
    @State private var loadedOnce = false
    private var settings: JSON { model.datasets["/personal/agency"]?["settings"] ?? .null }
    private var hasCachedSettings: Bool { !settings.isNull }
    var body: some View {
        DetailPage(title: "主动性") {
            if loading || !loadedOnce {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在拉齐主动性安排…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                .accessibilityLabel("正在拉齐主动性安排")
            }
            if !loadFail.isEmpty {
                InlineNotice(text: loadFail, tone: .danger)
                Button(loading ? "重试中…" : "再试一次") {
                    guard !loading else { return }
                    Task { await refreshSettings() }
                }
                .buttonStyle(.secondaryCompact)
                .disabled(loading)
                .accessibilityIdentifier("agency-settings-retry")
            }
            Card(.ink) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(paused ? "先安静一会儿。" : "有事记挂，适时来找你。").font(TypeScale.title).foregroundStyle(Palette.onInk)
                        .contentTransition(.opacity)
                    Text(loadFail.isEmpty || hasCachedSettings
                         ? "先替你整理，再说值得你关注的事。"
                         : "安排还没读上——下面是默认值，拉齐后再改更稳。").font(TypeScale.callout).foregroundStyle(Palette.onInkSecondary)
                }
            }
            GroupedCard {
                Toggle("暂停主动消息", isOn: $paused).rowPadding().disabled(loading && !hasCachedSettings)
                Picker("额外提醒", selection: $intensity) { Text("安静").tag("quiet"); Text("适中").tag("balanced"); Text("积极").tag("active") }.pickerStyle(.segmented).rowPadding().disabled(loading && !hasCachedSettings)
                Text(intensity == "quiet" ? "只保留固定简报，不额外打扰。" : intensity == "active" ? "每天最多 4 次额外主动提醒。" : "每天最多 2 次额外主动提醒。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).rowPadding()
            }
            GroupedCard {
                DatePicker("晨报", selection: $morning, displayedComponents: .hourAndMinute).rowPadding().disabled(loading && !hasCachedSettings)
                DatePicker("晚间复盘", selection: $evening, displayedComponents: .hourAndMinute).rowPadding().disabled(loading && !hasCachedSettings)
                Toggle("周日 20:30 周复盘", isOn: $weekly).rowPadding().disabled(loading && !hasCachedSettings)
                Text("周复盘替代当天晚报。23:00–08:00 为默认安静时段；时间按上海时区。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).rowPadding()
            }.environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            let notifications = model.datasets["/personal/agency"]?["notifications"] ?? .null
            Label(notifications["delivery"].string == "apns" ? "系统推送已接通" : "系统推送待接通，后台刷新可能延迟", systemImage: "bell")
                .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                    .accessibilityIdentifier("agency-settings-fail")
            }
            Button {
                guard !saving else { return }
                saving = true
                failNote = ""
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
                        let reloaded = try await model.saveAgencySettings(["paused": .bool(paused), "intensity": .string(intensity), "items": .array(items)])
                        Haptics.success()
                        if reloaded {
                            dismiss()
                        } else {
                            hydrate()
                            let err = model.errors["/personal/agency"] ?? ""
                            failNote = err.isEmpty
                                ? "安排已保存，页上没刷齐——可再拉或关掉重进。不会假装已拉齐。"
                                : "安排已保存，页上没刷齐：" + err + "——可再拉。不会假装已拉齐。"
                        }
                    } catch {
                        failNote = "保存没成：" + error.localizedDescription + "——还可以再试。不会假装已保存。"
                    }
                    saving = false
                }
            } label: { HStack { Text(saving ? "保存中…" : "保存安排"); Spacer(); if saving { ProgressView() } else { Image(systemName: "checkmark") } } }
                .buttonStyle(.primaryFull).disabled(saving || loading)
                .accessibilityIdentifier("agency-settings-save")
        }
        .animation(AgencyMotion.response(reduce), value: paused)
        .animation(AgencyMotion.response(reduce), value: intensity)
        .task { await refreshSettings() }
        .onAppear { hydrate() }
    }
    private func refreshSettings() async {
        guard !loading else { return }
        loading = true
        loadFail = ""
        defer {
            loading = false
            loadedOnce = true
        }
        let path = "/personal/agency"
        if await model.load(path) != nil {
            hydrate()
            return
        }
        let err = model.errors[path] ?? ""
        loadFail = err.isEmpty
            ? (hasCachedSettings
                ? "主动性安排没刷新上——下面仍是上一版，可再试"
                : "主动性安排没拉齐——下面是默认值，可再试")
            : (hasCachedSettings
                ? "安排没刷新上：" + err + "——下面仍是上一版"
                : "安排没拉齐：" + err + "——可再试")
        hydrate()
    }
    private func hydrate() {
        paused = settings["paused"].bool
        intensity = settings["intensity"].string.isEmpty ? "balanced" : settings["intensity"].string
        morning = time(settings["items"].array.first { $0.id == "morning-briefing" }?["at"].string ?? "09:00")
        evening = time(settings["items"].array.first { $0.id == "evening-review" }?["at"].string ?? "21:00")
        weekly = settings["items"].array.first { $0.id == "weekly-review" }?["enabled"].bool ?? true
    }
    private func time(_ value: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.date(from: value) ?? Date()
    }
}
