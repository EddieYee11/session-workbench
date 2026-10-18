import SwiftUI
import ComCore

// 案例（2026-10-17）：一次「交给 Com」= 一个独立的 Pi 会话，能长时跟踪到了哪一步。
// 入口在下一步页右上角（二级，不进 Dock）；聊天里 3 步以上的复杂轮次也会进来，可回看。
// 后端：backend/cases.py（/personal/cases），明天建议 backend/tomorrow_plan.py（/personal/plan）。

extension AppModel {
    var casesData: JSON { datasets["/personal/cases"] ?? .null }
    var planData: JSON { datasets["/personal/plan"] ?? .null }

    /// 交给 Com：建案例，返回案例 id；Hermes 判断是一步就能办的小事时会回到主对话，返回 nil 并切到聊天。
    func delegateNext(_ item: JSON) async -> String? {
        do {
            let result = try await mutate("/personal/next/" + item.id.pathEncoded, fields: ["action": .string("delegate")])
            _ = await load("/personal/next"); _ = await load("/personal/cases")
            Haptics.success()
            if result["mode"].string == "chat" { tab = .chat; await refresh(.chat); return nil }
            return result["task_id"].string.isEmpty ? nil : result["task_id"].string
        } catch { banner = error.localizedDescription; return nil }
    }
    /// 加到待办：day 是 YYYY-MM-DD；remindAt 是 "YYYY-MM-DD HH:MM"（可选）。
    func nextToTodo(_ item: JSON, day: String, remindAt: String? = nil) async {
        var fields: [String: JSON] = ["action": .string("todo"), "day": .string(day)]
        if let remindAt { fields["remind_at"] = .string(remindAt) }
        do {
            _ = try await mutate("/personal/next/" + item.id.pathEncoded, fields: fields)
            _ = await load("/personal/next"); _ = await load("/personal/today")
            Haptics.success()
        } catch { banner = error.localizedDescription }
    }
    func delegateTodo(_ path: String) async -> String? {
        do {
            let result = try await mutate("/personal/today/todos/delegate", fields: ["path": .string(path)])
            _ = await load("/personal/cases")
            Haptics.success()
            if result["mode"].string == "chat" { tab = .chat; await refresh(.chat); return nil }
            return result["task_id"].string.isEmpty ? nil : result["task_id"].string
        } catch { banner = error.localizedDescription; return nil }
    }
    func caseSend(_ id: String, _ text: String) async -> Bool {
        do { _ = try await mutate("/personal/cases/" + id.pathEncoded + "/send", fields: ["text": .string(text)]); Haptics.selection(); return true }
        catch { banner = error.localizedDescription; return false }
    }
    func caseCancel(_ id: String) async { await action("/personal/cases/" + id.pathEncoded + "/cancel") }
    func caseResolve(_ id: String) async { await action("/personal/cases/" + id.pathEncoded + "/resolve") }
    func applyPlan(day: String, selected: [String]) async -> JSON? {
        do {
            let result = try await mutate("/personal/plan/apply", fields: ["day": .string(day), "selected": .array(selected.map { JSON.string($0) })])
            _ = await load("/personal/plan"); _ = await load("/personal/next"); _ = await load("/personal/today")
            Haptics.success(); return result
        } catch { banner = error.localizedDescription; return nil }
    }
    static func dayString(_ offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(byAdding: .day, value: offset, to: Date())!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

private func caseTone(_ state: String) -> Tone {
    switch state { case "running", "queued": .accent; case "waiting", "attention": .warning; case "failed": .danger; case "done": .success; default: .neutral }
}
private let activeStates: Set<String> = ["running", "queued", "waiting", "attention"]

// MARK: - 入口

/// 下一步页右上角：「案例 · 2 进行中」。有等你的就标出来。
struct CasesEntry: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let summary = model.nextData["cases"]
        NavigationLink { CasesListView() } label: {
            HStack(spacing: 6) {
                if summary["active"].int > 0 { WorkPulse() } else { Image(systemName: "rectangle.stack").font(.system(size: 12, weight: .semibold)) }
                Text(summary["waiting"].int > 0 ? "案例 · \(summary["waiting"].int) 等你" : summary["active"].int > 0 ? "案例 · \(summary["active"].int) 进行中" : "案例")
                    .font(TypeScale.footnote.weight(.semibold))
            }
            .foregroundStyle(summary["waiting"].int > 0 ? Palette.warning : Palette.textPrimary)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Palette.surface, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cases-entry")
    }
}

// MARK: - 列表

struct CasesListView: View {
    @Environment(AppModel.self) private var model
    private var items: [JSON] { model.casesData["items"].array }
    var body: some View {
        let active = items.filter { activeStates.contains($0["state"].string) }
        let finished = items.filter { !activeStates.contains($0["state"].string) }
        ScrollPage(spacing: Layout.sectionSpacing) {
            if items.isEmpty {
                EmptyState(title: "还没有案例", description: "在「下一步」或待办里点「交给 Com」，或者在聊天里让它办一件复杂的事，它会单独开一个案例，在这里看它一步步怎么做的。", symbol: "rectangle.stack")
            }
            if !active.isEmpty {
                GroupSection("进行中 · \(active.count)") { ForEach(active.map(RemoteRow.init)) { row in caseLink(row.value) } }
            }
            if !finished.isEmpty {
                GroupSection("做过的", footer: "简单的事不进这里，只留在聊天里。") { ForEach(finished.prefix(40).map(RemoteRow.init)) { row in caseLink(row.value) } }
            }
        }
        .navigationTitle("案例").navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .refreshable { _ = await model.load("/personal/cases") }
        .task {
            // 有进行中的就每 4 秒看一眼，离开页面自动停。
            while !Task.isCancelled {
                _ = await model.load("/personal/cases")
                try? await Task.sleep(for: .seconds(model.casesData["active"].int > 0 ? 4 : 20))
            }
        }
    }
    private func caseLink(_ item: JSON) -> some View {
        NavigationLink { CaseDetailView(id: item.id) } label: { CaseRow(item: item) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("case-" + item.id)
    }
}

struct CaseRow: View {
    let item: JSON
    var body: some View {
        Card(item["state"].string == "waiting" ? .highlighted(.warning) : .standard, padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(item["title"].string).font(TypeScale.headline).foregroundStyle(Palette.textPrimary).lineLimit(2)
                    Spacer(minLength: Space.sm)
                    Stamp(text: item["state_label"].string, tone: caseTone(item["state"].string))
                }
                let p = item["progress"]
                if p["total"].int > 0 { StepProgress(done: p["done"].int, total: p["total"].int, live: activeStates.contains(item["state"].string)) }
                HStack(spacing: 6) {
                    if item["state"].string == "running" { WorkPulse() }
                    Text(item["waiting"]["question"].string.isEmpty ? (item["now"].string.isEmpty ? item["source_label"].string + " · " + relativeTime(item["updated_at"].double) : item["now"].string) : "等你：" + item["waiting"]["question"].string)
                        .font(TypeScale.footnote).foregroundStyle(item["state"].string == "waiting" ? Palette.warning : Palette.textSecondary).lineLimit(2)
                }
            }
        }
    }
}

/// 一条细进度条 + 「2/5」。
struct StepProgress: View {
    let done: Int
    let total: Int
    var live = false
    var body: some View {
        HStack(spacing: Space.sm) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.fill)
                    Capsule().fill(live ? Palette.accent : Palette.textTertiary.opacity(0.5))
                        .frame(width: max(6, geo.size.width * CGFloat(done) / CGFloat(max(1, total))))
                        .animation(.smooth(duration: 0.5), value: done)
                }
            }
            .frame(height: 6)
            Text("\(done)/\(total)").font(.caption2.monospacedDigit()).foregroundStyle(Palette.textTertiary)
        }
    }
}

// MARK: - 步骤清单（案例详情与聊天「思考过程」共用）

struct TodoStep: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    /// todo / doing / done / blocked / skipped
    let status: String
}

struct TodoChecklist: View {
    let steps: [TodoStep]
    var live = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    ZStack {
                        switch step.status {
                        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.textTertiary)
                        case "doing": if live { WorkPulse() } else { Image(systemName: "circle.dotted").foregroundStyle(Palette.textTertiary) }
                        case "blocked": Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning)
                        case "skipped": Image(systemName: "minus.circle").foregroundStyle(Palette.textTertiary)
                        default: Image(systemName: "circle").foregroundStyle(Palette.separator)
                        }
                    }
                    .font(.system(size: 13, weight: .medium)).frame(width: 18)
                    Text(step.text)
                        .font(TypeScale.footnote.weight(step.status == "doing" && live ? .semibold : .regular))
                        .foregroundStyle(step.status == "doing" && live ? Palette.textPrimary : step.status == "done" || step.status == "skipped" ? Palette.textTertiary : Palette.textSecondary)
                        .strikethrough(step.status == "skipped")
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .animation(reduce ? nil : .smooth(duration: 0.25), value: step.status)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 详情

struct CaseDetailView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var sending = false
    @State private var confirmCancel = false
    @State private var showTimeline = false
    @FocusState private var focused: Bool
    private var data: JSON { model.datasets["/personal/cases/" + id] ?? .null }
    var body: some View {
        ScrollPage(spacing: Space.xl) {
            if data.isNull {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Space.xxl)
            } else {
                header
                ThreadStrip(key: "case:" + id)  // 10-18 线索：从哪来、去了哪
                if !data["session_id"].string.isEmpty {
                    Button { model.openThreadNode(.object(["kind": .string("session"), "id": data["session_id"], "agent": data["agent"]])) } label: {
                        Label("在工作页打开执行会话", systemImage: "terminal").font(TypeScale.footnote.weight(.medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accentText)
                    .accessibilityIdentifier("case-open-session")
                }
                if data["state"].string == "waiting" { waitingCard }
                if !data["outcome"]["reason"].string.isEmpty && data["state"].string == "failed" {
                    InlineNotice(text: "没做成：" + data["outcome"]["reason"].string, tone: .warning)
                }
                let steps = data["steps"].array.enumerated().map { TodoStep(id: String($0.offset), text: $0.element["title"].string, status: $0.element["status"].string) }
                if !steps.isEmpty {
                    GroupSection("步骤") { Card(padding: Space.md) { TodoChecklist(steps: steps, live: activeStates.contains(data["state"].string)) } }
                }
                if !data["result"].string.isEmpty {
                    GroupSection("结果") { Card(padding: Space.lg) { ReplyText(text: data["result"].string) } }
                }
                let assumptions = data["assumptions"].array
                if !assumptions.isEmpty {
                    GroupSection("它自己拿主意的地方", footer: "信息不够时它选了最稳妥的做法继续；不对的话在下面直接说。") {
                        Card(.inset, padding: Space.md) {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                ForEach(Array(assumptions.enumerated()), id: \.offset) { _, a in
                                    Label(a["text"].string, systemImage: "lightbulb").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                                }
                            }
                        }
                    }
                }
                let artifacts = data["artifacts"].array.map(\.string).filter { !$0.isEmpty }
                if !artifacts.isEmpty {
                    GroupSection("产出") {
                        GroupedCard { ForEach(artifacts, id: \.self) { path in ListRow(symbol: path.hasPrefix("http") ? "link" : "doc", title: (path as NSString).lastPathComponent, subtitle: path, subtitleLines: 1) {}.rowPadding() } }
                    }
                }
                timeline
                if data["can_send"].bool || data["state"].string == "done" && data["kind"].string != "turn" { composer }
                if data["can_cancel"].bool {
                    Button("停止这个案例", role: .destructive) { confirmCancel = true }
                        .buttonStyle(.quiet).frame(maxWidth: .infinity)
                        .confirmationDialog("停止后 Pi 会中断当前这一步，已经做的不会撤回。", isPresented: $confirmCancel, titleVisibility: .visible) {
                            Button("停止", role: .destructive) { Task { await model.caseCancel(id); _ = await model.load("/personal/cases/" + id) } }
                        }
                }
            }
        }
        .navigationTitle(data["title"].string.isEmpty ? "案例" : data["title"].string).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .refreshable { _ = await model.load("/personal/cases/" + id) }
        .task {
            while !Task.isCancelled {
                _ = await model.load("/personal/cases/" + id)
                let live = activeStates.contains(data["state"].string) && data["state"].string != "waiting"
                try? await Task.sleep(for: .seconds(live ? 3 : 15))
            }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Stamp(text: data["state_label"].string, tone: caseTone(data["state"].string))
                Text(data["source_label"].string + " · " + relativeTime(data["created_at"].double)).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
            Text(data["title"].string).font(TypeScale.title).fixedSize(horizontal: false, vertical: true)
            if !data["goal"].string.isEmpty { Text(data["goal"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineSpacing(2) }
            if !data["now"].string.isEmpty && activeStates.contains(data["state"].string) {
                HStack(spacing: 6) { WorkPulse(); Text(data["now"].string).font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textPrimary) }
            }
            let p = data["progress"]
            if p["total"].int > 0 { StepProgress(done: p["done"].int, total: p["total"].int, live: activeStates.contains(data["state"].string)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var waitingCard: some View {
        Card(.highlighted(.warning), padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("等你批准").font(TypeScale.headline)
                Text(data["waiting"]["question"].string.isEmpty ? "它停在一个需要你批准的操作上。" : data["waiting"]["question"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary)
                HStack(spacing: Space.sm) {
                    Button("可以删，继续") { Task { if await model.caseSend(id, "同意，按你说的删，继续做完。") { _ = await model.load("/personal/cases/" + id) } } }.buttonStyle(.primaryCompact)
                    Button("不用删") { Task { if await model.caseSend(id, "不要删，跳过这一步，把其余的做完。") { _ = await model.load("/personal/cases/" + id) } } }.buttonStyle(.secondaryCompact)
                    Spacer(minLength: 0)
                    Button("算了，标完成") { Task { await model.caseResolve(id); _ = await model.load("/personal/cases/" + id) } }.buttonStyle(.quiet)
                }
            }
        }
    }
    @ViewBuilder private var timeline: some View {
        let rows = data["timeline"].array
        if !rows.isEmpty {
            GroupSection("过程", footer: data["tool_calls"].int > 0 ? "Pi 一共动用了 \(data["tool_calls"].int) 次工具。" : "") {
                Card(.inset, padding: Space.md) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array((showTimeline ? rows : Array(rows.suffix(6))).enumerated()), id: \.offset) { _, e in
                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                Text(clockTime(e["at"].double)).font(.caption2.monospacedDigit()).foregroundStyle(Palette.textTertiary).frame(width: 40, alignment: .leading)
                                Text(timelineText(e)).font(TypeScale.footnote).foregroundStyle(e["kind"].string == "you" ? Palette.textPrimary : Palette.textSecondary).lineLimit(3)
                            }
                        }
                        if rows.count > 6 {
                            Button(showTimeline ? "收起" : "看全部 \(rows.count) 条") { withAnimation(.smooth(duration: 0.25)) { showTimeline.toggle() } }
                                .font(TypeScale.footnote).buttonStyle(.plain).foregroundStyle(Palette.accentText)
                        }
                    }
                }
            }
        }
    }
    private func timelineText(_ e: JSON) -> String {
        let text = e["text"].string
        switch e["kind"].string {
        case "step_doing": return "开始：" + text
        case "step_done": return "完成：" + text
        case "assumption": return "拿了个主意：" + text
        case "waiting": return "停下等你：" + text
        case "you": return "你说：" + text
        case "failed": return "没做成：" + text
        default: return text
        }
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: Space.sm) {
            TextField(data["state"].string == "done" ? "还要它接着做什么？" : "插一句：补充要求、改方向…", text: $draft, axis: .vertical)
                .font(TypeScale.callout).lineLimit(1...5).focused($focused)
                .padding(.horizontal, Space.md).padding(.vertical, 10)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.md, style: .continuous))
                .accessibilityIdentifier("case-composer")
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                sending = true
                Task {
                    if await model.caseSend(id, text) { draft = ""; focused = false; _ = await model.load("/personal/cases/" + id) }
                    sending = false
                }
            } label: { Image(systemName: sending ? "ellipsis" : "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40) }
                .buttonStyle(.primaryCompact).disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("case-send")
        }
    }
}

/// 从聊天、今天页、推送打开的案例：sheet 里带一个导航栈。
struct CaseSheet: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CaseDetailView(id: id)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }
}

struct CasesSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CasesListView()
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 明天建议

/// 每晚 21:30 生成的明天清单：勾选后一键放进行动台。日程和进行中的案例只做参考。
struct TomorrowPlanCard: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var seeded = ""
    @State private var busy = false
    @State private var hidden = false
    private var plan: JSON { model.planData }
    var body: some View {
        let items = plan["items"].array
        let checkable = items.filter { $0["checkable"].bool }
        if !hidden && plan["state"].string == "open" && plan["day"].string >= AppModel.dayString(0) && !items.isEmpty {
            Card(.highlighted(.accent), padding: Space.lg) {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("明天（周\(plan["weekday"].string)）").font(TypeScale.headline)
                        Spacer(minLength: 0)
                        Button { withAnimation(.smooth(duration: 0.25)) { hidden = true } } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(Palette.textTertiary).accessibilityLabel("先不看")
                    }
                    Text(plan["headline"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items.map(RemoteRow.init)) { row in planRow(row.value) }
                    }
                    if !checkable.isEmpty {
                        Button {
                            busy = true
                            Task {
                                _ = await model.applyPlan(day: plan["day"].string, selected: Array(selected))
                                busy = false
                            }
                        } label: {
                            HStack { Text(selected.isEmpty ? "都不用，收起" : "放进明天的待办（\(selected.count)）"); Spacer(); Image(systemName: "arrow.right") }
                        }
                        .buttonStyle(.primaryCompact).disabled(busy)
                        .accessibilityIdentifier("plan-apply")
                    }
                }
            }
            .onAppear { seed(items) }
            .onChange(of: plan["day"].string) { _, _ in seed(items) }
            .accessibilityIdentifier("tomorrow-plan")
        }
    }
    private func seed(_ items: [JSON]) {
        guard seeded != plan["day"].string else { return }
        seeded = plan["day"].string
        selected = Set(items.filter { $0["checkable"].bool && $0["checked"].bool }.map(\.id))
    }
    @ViewBuilder private func planRow(_ item: JSON) -> some View {
        let symbol = ["todo": "checklist", "next": "sparkles", "event": "calendar", "case": "rectangle.stack"][item["kind"].string] ?? "circle"
        let on = selected.contains(item.id)
        Button {
            guard item["checkable"].bool else { if item["kind"].string == "case" { model.presentedCase = item["case_id"].string }; return }
            Haptics.selection()
            if on { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(alignment: .top, spacing: Space.sm) {
                Image(systemName: item["checkable"].bool ? (on ? "checkmark.square.fill" : "square") : symbol)
                    .font(.system(size: item["checkable"].bool ? 15 : 12)).foregroundStyle(item["checkable"].bool && on ? Palette.accentText : Palette.textTertiary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    // 日程和进行中的案例只做参考：字号小一号、次要色，不像可勾的待办
                    Text(item["title"].string).font(item["checkable"].bool ? TypeScale.subheadline : TypeScale.footnote)
                        .foregroundStyle(item["checkable"].bool ? Palette.textPrimary : Palette.textSecondary).lineLimit(2)
                    if !item["why"].string.isEmpty { Text(item["why"].string).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 今天页：进行中的案例

/// 今天页的一条：Com 正在替你办的事（只在有进行中的案例时出现），点一条直接打开。
struct TodayCasesStrip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let active = model.casesData["items"].array.filter { activeStates.contains($0["state"].string) }
        if !active.isEmpty {
            Card(padding: Space.md) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack {
                        Text("Com 正在办").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: 0)
                        Button("全部") { model.showCases = true }.font(TypeScale.footnote).buttonStyle(.plain).foregroundStyle(Palette.accentText)
                    }
                    ForEach(active.prefix(3).map(RemoteRow.init)) { row in
                        Button { model.presentedCase = row.id } label: {
                            HStack(spacing: Space.sm) {
                                if row.value["state"].string == "running" { WorkPulse() } else { Image(systemName: "hand.raised").font(.system(size: 12)).foregroundStyle(Palette.warning).frame(width: 14) }
                                Text(row.value["title"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary).lineLimit(1)
                                Spacer(minLength: Space.sm)
                                let p = row.value["progress"]
                                Text(row.value["state"].string == "waiting" ? "等你" : p["total"].int > 0 ? "\(p["done"].int)/\(p["total"].int)" : row.value["state_label"].string)
                                    .font(.caption.monospacedDigit()).foregroundStyle(row.value["state"].string == "waiting" ? Palette.warning : Palette.textTertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .accessibilityIdentifier("today-cases")
        }
    }
}

#if DEBUG
extension AppModel {
    /// `--ui-cases`：案例列表 / 详情、明天建议卡、已在待办标记、对话 todo 清单的验收数据。COM_PREVIEW_SHEET=case 直接打开详情。
    func seedCasesPreview() {
        let now = Date().timeIntervalSince1970
        func step(_ t: String, _ s: String) -> JSON { .object(["title": .string(t), "status": .string(s)]) }
        let running: JSON = .object(["id": .string("task_demo_running"), "title": .string("起草王总排期回复"), "source": .string("next"), "source_label": .string("下一步"),
            "state": .string("running"), "state_label": .string("进行中"), "agent": .string("pi"), "now": .string("在对照 Q4 日程写回复草稿"),
            "progress": .object(["done": .number(2), "total": .number(4)]), "created_at": .number(now - 300), "updated_at": .number(now - 20), "waiting": .null])
        let turn: JSON = .object(["id": .string("turn:demo"), "title": .string("查后天日程和饭钱"), "source": .string("chat"), "source_label": .string("对话"),
            "state": .string("done"), "state_label": .string("完成"), "kind": .string("turn"), "now": .string(""),
            "progress": .object(["done": .number(3), "total": .number(3)]), "created_at": .number(now - 3600), "updated_at": .number(now - 3500), "waiting": .null])
        let waiting: JSON = .object(["id": .string("task_demo_wait"), "title": .string("清理旧素材草稿"), "source": .string("todo"), "source_label": .string("待办"),
            "state": .string("waiting"), "state_label": .string("等你"), "now": .string(""), "progress": .object(["done": .number(1), "total": .number(3)]),
            "created_at": .number(now - 7200), "updated_at": .number(now - 600), "waiting": .object(["question": .string("删掉 3 份已过期的旧草稿？")])])
        datasets["/personal/cases"] = .object(["items": .array([waiting, running, turn]), "active": .number(2), "waiting": .number(1)])
        var detail = running.object
        detail["goal"] = .string("给王总一份 Q4 排期回复草稿，周五前能直接发。")
        detail["steps"] = .array([step("读王总的排期邮件", "done"), step("对照 Q4 日程和项目进度", "done"), step("起草回复", "doing"), step("给你确认", "todo")])
        detail["assumptions"] = .array([.object(["text": .string("按周五交付写，邮件里没说具体日期"), "at": .number(now - 120)])])
        detail["timeline"] = .array([
            .object(["at": .number(now - 300), "kind": .string("created"), "text": .string("交给 Com · 下一步")]),
            .object(["at": .number(now - 290), "kind": .string("started"), "text": .string("Pi 开始处理")]),
            .object(["at": .number(now - 250), "kind": .string("step_done"), "text": .string("读王总的排期邮件")]),
            .object(["at": .number(now - 120), "kind": .string("assumption"), "text": .string("按周五交付写，邮件里没说具体日期")]),
            .object(["at": .number(now - 60), "kind": .string("step_doing"), "text": .string("起草回复")])])
        detail["artifacts"] = .array([]); detail["result"] = .string(""); detail["tool_calls"] = .number(7)
        detail["can_send"] = .bool(true); detail["can_cancel"] = .bool(true); detail["evidence"] = .array([])
        datasets["/personal/cases/task_demo_running"] = .object(detail)
        datasets["/personal/plan"] = .object(["day": .string(AppModel.dayString(1)), "weekday": .string("日"), "state": .string("open"), "headline": .string("明天 2 个日程，建议做 3 件事"),
            "items": .array([
                .object(["id": .string("todo:a"), "kind": .string("todo"), "title": .string("交八月打车报销"), "why": .string("已过期（10-15），勾上改到明天"), "checked": .bool(true), "checkable": .bool(true)]),
                .object(["id": .string("next:b"), "kind": .string("next"), "title": .string("敲定奖牌供应商并下单"), "why": .string("10-19 定稿下单才赶得上 10-25 活动"), "checked": .bool(true), "checkable": .bool(true)]),
                .object(["id": .string("next:c"), "kind": .string("next"), "title": .string("处理合同平台待审批单"), "why": .string("两条提醒卡在你这里"), "checked": .bool(false), "checkable": .bool(true)]),
                .object(["id": .string("event:d"), "kind": .string("event"), "title": .string("【AI德州扑克】预赛"), "why": .string("全天"), "checked": .bool(false), "checkable": .bool(false)]),
                .object(["id": .string("case:e"), "kind": .string("case"), "title": .string("起草王总排期回复"), "why": .string("进行中 · 在写回复草稿"), "checked": .bool(false), "checkable": .bool(false), "case_id": .string("task_demo_running")])])])
        var next = nextData.object
        next["cases"] = .object(["active": .number(2), "waiting": .number(1), "total": .number(3)])
        var items = nextData["items"].array
        if items.count > 1, case .object(var o) = items[1] { o["in_todo"] = .object(["name": .string("会前过一遍周会议题"), "due": .string(AppModel.dayString(1))]); items[1] = .object(o) }
        next["items"] = .array(items)
        datasets["/personal/next"] = .object(next)
        // 对话：一轮带 todo 清单（3 步，进了案例）
        let plan: JSON = .object(["id": .string("plan"), "kind": .string("plan"), "title": .string("查后天日程和饭钱"), "todos": .array([
            .object(["id": .string("1"), "content": .string("读后天日历安排"), "active": .string("正在看日程"), "status": .string("completed")]),
            .object(["id": .string("2"), "content": .string("统计本月餐饮花销"), "active": .string("正在翻账本"), "status": .string("completed")]),
            .object(["id": .string("3"), "content": .string("提炼后天注意事项"), "active": .string("正在写总结"), "status": .string("completed")])])])
        let tools: [JSON] = (1...4).map { n in .object(["id": .string("tool-\(n)"), "kind": .string("tool"), "tool": .string(n < 3 ? "calendar_read" : "business_operation"), "status": .string("done"), "started_at": .number(now - 80 + Double(n) * 5), "finished_at": .number(now - 78 + Double(n) * 5)]) }
        conversation.messages.append(.object(["id": .string("demo"), "role": .string("user"), "text": .string("看看我后天有哪些日程，再查一下这个月吃饭花了多少钱"), "status": .string("completed"),
                                              "created_at": .number(now - 90), "received_at": .number(now - 90), "tasks": .array([plan] + tools)]))
        conversation.messages.append(.object(["id": .string("demo-reply"), "role": .string("assistant"), "parent_id": .string("demo"), "status": .string("completed"), "created_at": .number(now - 55),
                                              "text": .string("**后天（10-20）日程是空的**，可以当自由日。本月吃饭一共 **56 笔、1659 块**。")]))
        conversation.revision += 1
        seedThreadsPreview()
        tab = ProcessInfo.processInfo.environment["COM_PREVIEW_TAB"] == "chat" ? .chat : ProcessInfo.processInfo.environment["COM_PREVIEW_TAB"] == "today" ? .doing : .next
        if ProcessInfo.processInfo.environment["COM_PREVIEW_SHEET"] == "case" { presentedCase = "task_demo_running" }
        if ProcessInfo.processInfo.environment["COM_PREVIEW_SHEET"] == "cases" { showCases = true }
    }
}
#endif
