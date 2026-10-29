import SwiftUI
import ComCore

// 航程（2026-10-17）：一次「交给 Com」= 一个独立的 Pi 会话，能长时跟踪到了哪一步。
// 入口在下一步页右上角（二级，不进 Dock）；聊天里 3 步以上的复杂轮次也会进来，可回看。
// 后端：backend/cases.py（/personal/cases），明天建议 backend/tomorrow_plan.py（/personal/plan）。

extension AppModel {
    var casesData: JSON { datasets["/personal/cases"] ?? .null }
    var planData: JSON { datasets["/personal/plan"] ?? .null }

    /// 交给 Com：建航程。返回航程 id；`""` = 小事进主对话；`nil` = 失败（别把失败当成已进聊天）。
    func delegateNext(_ item: JSON) async -> String? {
        do {
            let result = try await mutate("/personal/next/" + item.id.pathEncoded, fields: ["action": .string("delegate")])
            // 已交接；列表没刷齐则乐观收卡 + 开口，别假装下一步/航程已是最新。
            if await load("/personal/next") == nil {
                var value = nextData
                value["items"] = .array(value["items"].array.filter { $0.id != item.id })
                datasets["/personal/next"] = value
                let err = errors["/personal/next"] ?? ""
                planOpenNote = err.isEmpty
                    ? "已交给我办，下一步列表没刷齐——可下拉再试。不会假装列表已是最新。"
                    : "已交给我办，下一步列表没刷齐：" + err + "——可下拉再试。不会假装列表已是最新。"
            }
            if await load("/personal/cases") == nil {
                let err = errors["/personal/cases"] ?? ""
                // 航程入口在下一步页；用 planOpenNote 同口，别叠第二条无关 note。
                if planOpenNote.isEmpty {
                    planOpenNote = err.isEmpty
                        ? "已接进航程，航程列表没刷上——可下拉开动态再看。不会假装航程已出现。"
                        : "已接进航程，航程列表没刷上：" + err + "——可再试。不会假装航程已出现。"
                }
            }
            if await load("/personal/waiting") == nil {
                let err = errors["/personal/waiting"] ?? ""
                if waitingOpenNote.isEmpty {
                    waitingOpenNote = err.isEmpty
                        ? "已交给我办，等你列表没刷齐——可再拉开等你。不会假装角标已更新。"
                        : "已交给我办，等你列表没刷齐：" + err + "——可再拉开等你。不会假装角标已更新。"
                }
            }
            Haptics.success()
            if result["mode"].string == "chat" {
                showWaiting = false
                tab = .chat
                await refresh(.chat)
                return ""
            }
            let id = result["task_id"].string
            return id.isEmpty ? nil : id
        } catch { banner = error.localizedDescription; return nil }
    }
    /// 加到待办：day 是 YYYY-MM-DD；remindAt 是 "YYYY-MM-DD HH:MM"（可选）。
    @discardableResult
    func nextToTodo(_ item: JSON, day: String, remindAt: String? = nil) async -> Bool {
        var fields: [String: JSON] = ["action": .string("todo"), "day": .string(day)]
        if let remindAt { fields["remind_at"] = .string(remindAt) }
        do {
            _ = try await mutate("/personal/next/" + item.id.pathEncoded, fields: fields)
            // 已加进待办；下一步没刷齐则乐观收卡；今天没刷上则 doingOpenNote，别假装待办已显示。
            if await load("/personal/next") == nil {
                var value = nextData
                value["items"] = .array(value["items"].array.filter { $0.id != item.id })
                datasets["/personal/next"] = value
                let err = errors["/personal/next"] ?? ""
                planOpenNote = err.isEmpty
                    ? "已加进待办，下一步列表没刷齐——可下拉再试。不会假装列表已是最新。"
                    : "已加进待办，下一步列表没刷齐：" + err + "——可下拉再试。不会假装列表已是最新。"
            }
            if await load("/personal/today") == nil {
                let err = errors["/personal/today"] ?? ""
                doingOpenNote = err.isEmpty
                    ? "已加进待办，今天页没刷上——可到「今天」下拉。不会假装待办已显示。"
                    : "已加进待办，今天页没刷上：" + err + "——可到「今天」下拉。不会假装待办已显示。"
            }
            Haptics.success()
            return true
        } catch { banner = error.localizedDescription; return false }
    }
    /// 返回航程 id；`""` = 进主对话；`nil` = 失败。
    func delegateTodo(_ path: String) async -> String? {
        do {
            let result = try await mutate("/personal/today/todos/delegate", fields: ["path": .string(path)])
            // 过期待办已交接；等你/今天没刷齐则开口，别假装角标与日程已齐（调用方已乐观藏卡）。
            if await load("/personal/waiting") == nil {
                let err = errors["/personal/waiting"] ?? ""
                waitingOpenNote = err.isEmpty
                    ? "已交给我办，等你列表没刷齐——可再拉开等你。不会假装角标已更新。"
                    : "已交给我办，等你列表没刷齐：" + err + "——可再拉开等你。不会假装角标已更新。"
            }
            if await load("/personal/cases") == nil {
                let err = errors["/personal/cases"] ?? ""
                if waitingOpenNote.isEmpty {
                    waitingOpenNote = err.isEmpty
                        ? "已接进航程，航程列表没刷上——可打开动态再看。不会假装航程已出现。"
                        : "已接进航程，航程列表没刷上：" + err + "——可再试。不会假装航程已出现。"
                }
            }
            if await load("/personal/today") == nil {
                let err = errors["/personal/today"] ?? ""
                doingOpenNote = err.isEmpty
                    ? "已交给我办，今天页没刷上——可到「今天」下拉。不会假装待办已离开。"
                    : "已交给我办，今天页没刷上：" + err + "——可到「今天」下拉。不会假装待办已离开。"
            }
            Haptics.success()
            if result["mode"].string == "chat" { tab = .chat; await refresh(.chat); return "" }
            let id = result["task_id"].string
            return id.isEmpty ? nil : id
        } catch { banner = error.localizedDescription; return nil }
    }
    /// 航程状态变了：等你角标 / 注意力条 / 动态里的航程数都要立刻跟上，不能只刷详情。
    /// - Returns: waiting / cases 是否拉齐；失败写 waitingOpenNote / activityOpenNote，别假装角标与列表已更新。
    @discardableResult
    func refreshAfterCaseChange(head: String = "航程已更新") async -> (waiting: Bool, cases: Bool) {
        async let waitingLoad = load("/personal/waiting")
        async let casesLoad = load("/personal/cases")
        let gotWaiting = await waitingLoad != nil
        let gotCases = await casesLoad != nil
        if gotWaiting {
            waitingOpenNote = ""
        } else {
            let err = errors["/personal/waiting"] ?? ""
            waitingOpenNote = err.isEmpty
                ? head + "，等你列表没刷齐——可再拉开等你。不会假装角标已更新。"
                : head + "，等你列表没刷齐：" + err + "——可再拉开等你。不会假装角标已更新。"
        }
        if gotCases {
            activityOpenNote = ""
        } else {
            let err = errors["/personal/cases"] ?? ""
            activityOpenNote = err.isEmpty
                ? head + "，航程列表没刷上——可打开动态或下拉再试。不会假装列表已更新。"
                : head + "，航程列表没刷上：" + err + "——可打开动态再试。不会假装列表已更新。"
        }
        return (gotWaiting, gotCases)
    }
    /// 列表刷失败时乐观改本地航程态，别让横幅/动态仍当它在跑。
    private func patchCaseListState(_ id: String, state: String, label: String) {
        var value = casesData
        value["items"] = .array(value["items"].array.map { row in
            guard row.id == id else { return row }
            var copy = row
            copy["state"] = .string(state)
            copy["state_label"] = .string(label)
            copy["now"] = .string("")
            return copy
        })
        let live: Set<String> = ["running", "queued", "waiting", "attention"]
        let items = value["items"].array
        value["active"] = .number(Double(items.filter { live.contains($0["state"].string) }.count))
        value["waiting"] = .number(Double(items.filter { ["waiting", "attention"].contains($0["state"].string) }.count))
        datasets["/personal/cases"] = value
    }
    func caseSend(_ id: String, _ text: String) async -> Bool {
        do {
            _ = try await mutate("/personal/cases/" + id.pathEncoded + "/send", fields: ["text": .string(text)])
            Haptics.selection()
            await refreshAfterCaseChange(head: "话已送上")
            return true
        } catch { banner = error.localizedDescription; return false }
    }
    @discardableResult
    func caseCancel(_ id: String) async -> Bool {
        guard await action("/personal/cases/" + id.pathEncoded + "/cancel") else { return false }
        let ok = await refreshAfterCaseChange(head: "已停止航程")
        if !ok.cases { patchCaseListState(id, state: "cancelled", label: "已取消") }
        return true
    }
    @discardableResult
    func caseResolve(_ id: String) async -> Bool {
        guard await action("/personal/cases/" + id.pathEncoded + "/resolve") else { return false }
        let ok = await refreshAfterCaseChange(head: "已标完成")
        if !ok.cases { patchCaseListState(id, state: "done", label: "完成") }
        return true
    }
    func applyPlan(day: String, selected: [String]) async -> JSON? {
        do {
            let result = try await mutate("/personal/plan/apply", fields: ["day": .string(day), "selected": .array(selected.map { JSON.string($0) })])
            // 已放进待办；plan/next/today 没刷齐则开口（plan 乐观收起），别假装列表已是最新。
            if await load("/personal/plan") == nil {
                var value = planData
                value["state"] = .string("closed")
                datasets["/personal/plan"] = value
                let err = errors["/personal/plan"] ?? ""
                planOpenNote = err.isEmpty
                    ? "已放进明天待办，计划卡没刷齐——可下拉再试。不会假装计划已收起。"
                    : "已放进明天待办，计划卡没刷齐：" + err + "——可下拉再试。不会假装计划已收起。"
            }
            if await load("/personal/next") == nil {
                let err = errors["/personal/next"] ?? ""
                if planOpenNote.isEmpty {
                    planOpenNote = err.isEmpty
                        ? "已放进明天待办，下一步列表没刷齐——可下拉再试。不会假装列表已是最新。"
                        : "已放进明天待办，下一步列表没刷齐：" + err + "——可下拉再试。不会假装列表已是最新。"
                }
            }
            if await load("/personal/today") == nil {
                let err = errors["/personal/today"] ?? ""
                doingOpenNote = err.isEmpty
                    ? "已放进明天待办，今天页没刷上——可到「今天」下拉。不会假装待办已显示。"
                    : "已放进明天待办，今天页没刷上：" + err + "——可到「今天」下拉。不会假装待办已显示。"
            }
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

// MARK: - 下一步页入口：航程大卡

/// 下一步页顶上的航程入口（10-18 重做：原来右上角一颗小胶囊，太容易漏掉）。
/// 有在跑 / 等你的航程时是一张反色大卡：最要紧的那段的标题、它此刻在做什么、进度条，点开进动态页的「电脑上的活」（10-28 航程列表并进动态）；
/// 没有在跑的但做过一些，缩成一行「航程 · 看做过的 N 段」；从来没有过就不占位（头像菜单里始终有入口）。
struct VoyageBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    private let casesPath = "/personal/cases"
    var body: some View {
        let items = model.casesData["items"].array
        let live = items.filter { activeStates.contains($0["state"].string) }
        VStack(alignment: .leading, spacing: Space.sm) {
            // 有停顿等你的航程时置顶那一段——别让「还在跑」盖住真正要你拍板的。
            if let top = live.first(where: { ["waiting", "attention"].contains($0["state"].string) }) ?? live.first {
                NavigationLink { ActivityFeedView(initial: .work) } label: { card(top: top, live: live) }
                    .buttonStyle(SoftPressStyle(scale: 0.985))
                    .accessibilityIdentifier("voyage-banner")
            } else if !items.isEmpty {
                NavigationLink { ActivityFeedView(initial: .work) } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "location.north.line").font(.system(size: 13, weight: .semibold))
                        Text("航程").font(TypeScale.subheadline.weight(.semibold))
                        Text("看做过的 \(items.count) 段").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Space.lg).frame(height: 44)
                    .background(Palette.surface, in: .rect(cornerRadius: Radius.md, style: .continuous))
                }
                .buttonStyle(SoftPressStyle(scale: 0.985))
                .accessibilityIdentifier("voyage-banner-quiet")
            } else if loading || !loadedOnce {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在拉齐航程…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                .accessibilityLabel("正在拉齐航程")
                .accessibilityIdentifier("voyage-banner-pulling")
            } else if !failNote.isEmpty {
                Text("航程还没读上——通了我再开口说哪段在跑、哪段等你。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    .accessibilityIdentifier("voyage-banner-empty-fail")
            }
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                Button(loading ? "重试中…" : "再试一次") {
                    guard !loading else { return }
                    Task { await refreshCases(force: true) }
                }
                .buttonStyle(.secondaryCompact)
                .disabled(loading)
                .accessibilityIdentifier("voyage-banner-retry")
            }
        }
        .modifier(EnterRise(on: shown, delay: 0.02, y: 12, blur: 5, animation: ComMotion.lift))
        .onAppear {
            if reduce { shown = true }
            else { withAnimation(ComMotion.lift) { shown = true } }
        }
        .task { await refreshCases(force: false) }
    }
    private func refreshCases(force: Bool) async {
        guard !loading else { return }
        // Next 页可能已拉过 cases——有缓存且非强制就不叠刷，但仍认已开口。
        if !force, !model.casesData.isNull {
            loadedOnce = true
            if model.errors[casesPath] == nil { failNote = ""; return }
        }
        loading = true
        if force { failNote = "" }
        defer {
            loading = false
            loadedOnce = true
        }
        if await model.load(casesPath) != nil {
            failNote = ""
            return
        }
        let err = model.errors[casesPath] ?? ""
        let had = !model.casesData["items"].array.isEmpty
        failNote = err.isEmpty
            ? (had ? "航程没刷新上——下面仍是上一版，可再试" : "航程没拉齐——检查配对或网络后再试")
            : (had ? "航程没刷新上：" + err + "——下面仍是上一版" : "航程没拉齐：" + err + "——可再试")
    }
    private func card(top: JSON, live: [JSON]) -> some View {
        let waiting = live.filter { ["waiting", "attention"].contains($0["state"].string) }.count
        let running = live.count - waiting
        let p = top["progress"]
        let paused = ["waiting", "attention"].contains(top["state"].string)
        let question = top["waiting"]["question"].string
        let line: String = {
            if paused {
                if question.isEmpty { return "停住了——要你点头才继续" }
                return "停住等你：" + question
            }
            return top["now"].string.isEmpty ? "正在准备" : top["now"].string
        }()
        return Card(.ink, padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "location.north.line").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.accent)
                    Text(paused ? "航程 · 等你" : "航程").font(TypeScale.subheadline.weight(.bold)).foregroundStyle(Palette.onInk)
                    Spacer(minLength: Space.sm)
                    if waiting > 0 { chip("\(waiting) 段等你", tone: Palette.warning) }
                    if running > 0 { chip("\(running) 段进行中", tone: Palette.accent) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(top["title"].string).font(TypeScale.headline).foregroundStyle(Palette.onInk).lineLimit(2)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if top["state"].string == "running" { WorkPulse() }
                        Text(line).font(TypeScale.subheadline).foregroundStyle(paused ? Palette.warning : Palette.onInkSecondary).lineLimit(2)
                    }
                }
                if p["total"].int > 0 {
                    HStack(spacing: Space.sm) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.onInk.opacity(0.16))
                                Capsule().fill(Palette.accent).frame(width: max(8, geo.size.width * CGFloat(p["done"].int) / CGFloat(max(1, p["total"].int))))
                                    .animation(ComMotion.reduced(reduce, ComMotion.settle), value: p["done"].int)
                            }
                        }.frame(height: 6)
                        Text("\(p["done"].int)/\(p["total"].int)").font(.caption.monospacedDigit()).foregroundStyle(Palette.onInkSecondary)
                            .contentTransition(.numericText())
                    }
                }
                HStack(spacing: 4) {
                    Text(live.count > 1 ? "还有 \(live.count - 1) 段 · 全部航程" : "全部航程").font(TypeScale.footnote.weight(.semibold))
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Palette.accent)
            }
        }
    }
    private func chip(_ text: String, tone: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(tone)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tone.opacity(0.18), in: .capsule)
    }
}

// MARK: - 列表（10-25：收件箱式，参考 Mailio inbox——搜索、筛选胶囊、按来源分组的白卡、超过 3 条收起）


/// 头像：标题首字 + 按标题算出的浅色底（参考图里的彩色首字母圆）。
struct CaseAvatar: View {
    let title: String
    var size: CGFloat = 38
    private static let hues: [Color] = [Color(red: 0.42, green: 0.62, blue: 0.95), Color(red: 0.93, green: 0.45, blue: 0.55), Color(red: 0.62, green: 0.45, blue: 0.93),
                                        Color(red: 0.30, green: 0.72, blue: 0.55), Color(red: 0.96, green: 0.62, blue: 0.30), Color(red: 0.35, green: 0.70, blue: 0.85)]
    var body: some View {
        let hue = Self.hues[abs(title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Self.hues.count]
        Text(String(title.trimmingCharacters(in: .whitespaces).prefix(1)))
            .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(hue, in: .circle)
            .accessibilityHidden(true)
    }
}

/// 一行航程：等你的左边一颗点 · 头像 · 标题和时间 · 状态行（状态色）· 一句在做什么 / 等你的问题。
struct CaseRow: View {
    let item: JSON
    var body: some View {
        let state = item["state"].string
        let waiting = ["waiting", "attention"].contains(state)
        let p = item["progress"]
        let status = item["state_label"].string + (p["total"].int > 0 ? " · \(p["done"].int)/\(p["total"].int) 步" : "") + (item["source_label"].string.isEmpty ? "" : " · 来自" + item["source_label"].string)
        let preview = waiting && !item["waiting"]["question"].string.isEmpty ? "停住等你：" + item["waiting"]["question"].string
            : !item["now"].string.isEmpty ? item["now"].string : relativeTime(item["created_at"].double) + "开始"
        HStack(alignment: .top, spacing: Space.sm) {
            Circle().fill(waiting ? Palette.warning : state == "running" ? Palette.info : .clear).frame(width: 7, height: 7).padding(.top, 16)
            CaseAvatar(title: item["title"].string)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(item["title"].string).font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    Spacer(minLength: Space.sm)
                    Text(relativeTime(item["updated_at"].double)).font(.caption.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                }
                HStack(spacing: 5) {
                    if state == "running" { WorkPulse() }
                    Text(status).font(TypeScale.footnote.weight(.medium)).foregroundStyle(caseTone(state).color)
                }
                Text(preview).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
        }
        .padding(.vertical, Space.md).padding(.trailing, Space.md).padding(.leading, Space.sm)
        .contentShape(.rect)
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

// MARK: - 步骤（聊天「思考过程」的时间轴见 WorkProcess.swift 的 TodoTimeline）

struct TodoStep: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    /// todo / doing / done / blocked / skipped
    let status: String
    /// 后端 turn_planner 10-28 起每步记的时间戳（秒）；老消息没有就是 0。
    var startedAt: Double = 0
    var doneAt: Double = 0
}

// MARK: - 详情

struct CaseDetailView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var draft = ""
    @State private var sending = false
    @State private var confirmCancel = false
    @State private var showTimeline = false
    @State private var shown = false
    /// 停顿卡拍板 / 标完成 / 停止：失败留页可重试，勿连点叠发。
    @State private var acting = false
    @State private var actFail = ""
    @State private var pollFail = ""
    @State private var loadedOnce = false
    @State private var retrying = false
    @FocusState private var focused: Bool
    private var data: JSON { model.datasets["/personal/cases/" + id] ?? .null }
    private var casePath: String { "/personal/cases/" + id }
    private var locked: Bool { sending || acting }
    var body: some View {
        ScrollPage(spacing: Space.xl) {
            if data.isNull {
                if !loadedOnce {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Space.xxl)
                        .accessibilityLabel("正在对齐航程")
                } else {
                    VStack(alignment: .leading, spacing: Space.md) {
                        if !pollFail.isEmpty {
                            InlineNotice(text: pollFail, tone: .danger)
                        } else {
                            InlineNotice(text: "还没读到这趟航程——可再试，或回上一级看看列表。", tone: .danger)
                        }
                        Button(retrying ? "重试中…" : "再试一次") {
                            guard !retrying else { return }
                            Task { await refreshCase(manual: true) }
                        }
                        .buttonStyle(.secondaryCompact)
                        .disabled(retrying)
                        .accessibilityIdentifier("case-poll-retry")
                    }
                    .padding(.top, Space.lg)
                }
            } else {
                if !pollFail.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        InlineNotice(text: pollFail, tone: .danger)
                        Button(retrying ? "重试中…" : "再试一次") {
                            guard !retrying else { return }
                            Task { await refreshCase(manual: true) }
                        }
                        .buttonStyle(.secondaryCompact)
                        .disabled(retrying)
                        .accessibilityIdentifier("case-poll-retry")
                    }
                }
                header
                    .modifier(EnterRise(on: shown, delay: 0, y: 14, blur: 6, animation: ComMotion.pop))
                ThreadStrip(key: "case:" + id)  // 10-18 线索：从哪来、去了哪
                    .modifier(EnterRise(on: shown, delay: 0.05, y: 10, blur: 4, animation: ComMotion.rise))
                if data["state"].string == "waiting" {
                    waitingCard
                        .modifier(EnterRise(on: shown, delay: 0.08, y: 12, blur: 5, animation: ComMotion.pop))
                }
                if data["state"].string == "failed" {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        InlineNotice(
                            text: data["outcome"]["reason"].string.isEmpty
                                ? "这趟航程没办成。下面说说怎么改，或标完成收尾。"
                                : "没办成：" + data["outcome"]["reason"].string + "——跟我说怎么改，我接着试。",
                            tone: .warning)
                        if canReply {
                            Button("跟我说怎么改") { focused = true }
                                .buttonStyle(.secondaryCompact)
                                .accessibilityIdentifier("case-failed-retry")
                        }
                    }
                }
                letter
                    .modifier(EnterRise(on: shown, delay: 0.1, y: 12, blur: 5, animation: ComMotion.rise))
                if !actFail.isEmpty && data["state"].string != "waiting" {
                    Text(actFail).font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("case-act-fail")
                }
                actions
                    .modifier(EnterRise(on: shown, delay: 0.14, y: 8, blur: 3, animation: ComMotion.pop))
                // 10-28 验收工作台：完成条件逐条看证据，缺的能一键让它补；送达失败留页可重试。
                AcceptancePanel(data: data["acceptance"], canAsk: canReply, locked: locked) { text in
                    await actSend(text)
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
                timeline
                if canReply { composer }
            }
        }
        .confirmationDialog("停止后 Pi 会中断当前这一步，已经做的不会撤回。", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("停止", role: .destructive) {
                Task { await actCancel() }
            }
        }
        .navigationTitle("航程").navigationBarTitleDisplayMode(.inline)  // 标题已在正文第一行（来信式），导航栏不再重复
        .toolbarBackground(Palette.background, for: .navigationBar)
        .refreshable { await refreshCase(manual: true) }
        .onAppear {
            if reduce { shown = true }
            else { withAnimation(ComMotion.rise) { shown = true } }
        }
        .task {
            while !Task.isCancelled {
                await refreshCase(manual: false)
                let live = activeStates.contains(data["state"].string) && data["state"].string != "waiting"
                try? await Task.sleep(for: .seconds(live ? 3 : 15))
            }
        }
    }
    private func refreshCase(manual: Bool) async {
        if manual {
            guard !retrying else { return }
            retrying = true
        }
        defer { if manual { retrying = false } }
        if await model.load(casePath) != nil {
            pollFail = ""
            loadedOnce = true
            return
        }
        loadedOnce = true
        let err = model.errors[casePath] ?? ""
        pollFail = err.isEmpty
            ? (data.isNull
                ? "航程没对齐——检查配对或网络后再试"
                : "航程没刷新上——下面仍是上一版，可再试")
            : (data.isNull
                ? "航程没对齐：" + err + "——可再试"
                : "航程没刷新上：" + err + "——下面仍是上一版")
    }
    private var canReply: Bool { data["can_send"].bool || data["state"].string == "done" && data["kind"].string != "turn" }
    private var live: Bool { activeStates.contains(data["state"].string) }
    /// 标题行（参考图：主题 + 右上角星标）：这里右上角是状态章。
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(data["title"].string).font(TypeScale.title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            Stamp(text: data["state_label"].string, tone: caseTone(data["state"].string))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    /// 10-25 来信卡（参考 Mailio 邮件详情）：谁在办、从哪来、多久前 → 目标 → 此刻 → 编号步骤 → 结果 → 附件片。
    private var letter: some View {
        let agent = ["pi": "Pi", "codex": "Codex", "claude": "Claude", "hermes": "Hermes"][data["agent"].string] ?? "Com"
        let steps = data["steps"].array
        let p = data["progress"]
        let artifacts = data["artifacts"].array.filter { !$0["path"].string.isEmpty }
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                CaseAvatar(title: agent, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent).font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                    Text("来自" + data["source_label"].string + " · 交给 Com · " + relativeTime(data["created_at"].double))
                        .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(Palette.separator)
            if !data["goal"].string.isEmpty {
                Text(data["goal"].string).font(TypeScale.body).foregroundStyle(Palette.textPrimary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            if !data["now"].string.isEmpty && live {
                HStack(spacing: 6) { WorkPulse(); Text(data["now"].string).font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textPrimary) }
            }
            if p["total"].int > 0 { StepProgress(done: p["done"].int, total: p["total"].int, live: live) }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in numberedStep(index + 1, step) }
                }
            }
            if !data["result"].string.isEmpty { ReplyText(text: data["result"].string) }
            if !artifacts.isEmpty { ArtifactList(artifacts: artifacts, chips: true) }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.8))
    }
    /// 步骤写成编号清单（参考图里的「1. Design Review — October 28」），右边一个状态小记号。
    private func numberedStep(_ n: Int, _ step: JSON) -> some View {
        let status = step["status"].string
        return HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text("\(n).").font(TypeScale.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.textSecondary).frame(width: 22, alignment: .leading)
            Text(step["title"].string).font(TypeScale.subheadline.weight(status == "doing" && live ? .semibold : .regular))
                .foregroundStyle(status == "done" || status == "skipped" ? Palette.textTertiary : Palette.textPrimary)
                .strikethrough(status == "skipped")
            Spacer(minLength: Space.sm)
            Group {
                switch status {
                case "done": Image(systemName: "checkmark").foregroundStyle(Palette.success)
                case "doing": if live { WorkPulse() } else { Image(systemName: "circle.dotted").foregroundStyle(Palette.textTertiary) }
                case "blocked": Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning)
                default: EmptyView()
                }
            }
            .font(.system(size: 12, weight: .semibold))
        }
    }
    /// 底部一排动作胶囊（参考图 Reply / Move / Edit）：接着说 · 打开会话 · 标完成 / 停止。
    @ViewBuilder private var actions: some View {
        let session = data["session_id"].string
        HStack(spacing: Space.sm) {
            if canReply { pill("接着说", "arrowshape.turn.up.left") { focused = true } }
            if !session.isEmpty {
                pill("打开会话", "terminal") { model.openThreadNode(.object(["kind": .string("session"), "id": data["session_id"], "agent": data["agent"]])) }
                    .accessibilityIdentifier("case-open-session")
            }
            if data["can_cancel"].bool {
                pill("停止", "stop.circle", destructive: true) { confirmCancel = true }
            } else if live {
                pill("标完成", "checkmark.circle") { Task { await actResolve() } }
            }
        }
    }
    private func pill(_ title: String, _ symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            guard !locked else { return }
            action()
        } label: {
            HStack(spacing: 6) { Text(title); Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                .font(TypeScale.footnote.weight(.medium)).foregroundStyle(destructive ? Palette.danger : Palette.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Palette.surface, in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 0.8))
                .opacity(locked ? 0.55 : 1)
        }
        .buttonStyle(SoftPressStyle(scale: 0.97))
        .disabled(locked)
    }
    private var waitingCard: some View {
        let question = data["waiting"]["question"].string
        let deleteish = ["删", "清理", "移除", "清空"].contains { question.contains($0) }
        return Card(.highlighted(.warning), padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("航程停住了").font(TypeScale.headline)
                Text("没你点头我不会往下动——看清这一步再选。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                Text(question.isEmpty ? "它停在一个需要你批准的操作上。" : question)
                    .font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !actFail.isEmpty {
                    Text(actFail).font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("case-act-fail")
                }
                HStack(spacing: Space.sm) {
                    if deleteish {
                        Button("可以删，继续") {
                            Task { await actSend("同意，按你说的删，继续做完。") }
                        }.buttonStyle(.primaryCompact).disabled(locked)
                        Button("不用删") {
                            Task { await actSend("不要删，跳过这一步，把其余的做完。") }
                        }.buttonStyle(.secondaryCompact).disabled(locked)
                    } else {
                        Button("可以，继续") {
                            Task { await actSend("同意，按你说的继续做完。") }
                        }.buttonStyle(.primaryCompact).disabled(locked)
                        Button("先别，改做法") {
                            Task { await actSend("先不要按这个做，等我说清楚再继续。") }
                        }.buttonStyle(.secondaryCompact).disabled(locked)
                    }
                    Spacer(minLength: 0)
                    Button("算了，标完成") {
                        Task { await actResolve() }
                    }.buttonStyle(.quiet).disabled(locked)
                }
            }
        }
        .accessibilityIdentifier("case-waiting-card")
    }
    @discardableResult
    private func actSend(_ text: String) async -> Bool {
        guard !locked else { return false }
        acting = true
        actFail = ""
        let ok = await model.caseSend(id, text)
        if ok {
            // 送达成功但详情没刷上：别假装页上已是最新现况。
            if await model.load("/personal/cases/" + id) == nil {
                actFail = "话已送出，航程现况没刷上——可下拉再试。不会假装页面已是最新。"
            }
        } else {
            actFail = "没送出去，还可以再点"
        }
        acting = false
        return ok
    }
    private func actResolve() async {
        guard !locked else { return }
        acting = true
        actFail = ""
        if await model.caseResolve(id) {
            if await model.load("/personal/cases/" + id) == nil {
                actFail = "已标完成，航程现况没刷上——可下拉再试。不会假装页面已是最新。"
            }
        } else {
            actFail = "标完成没成，还可以再试"
        }
        acting = false
    }
    private func actCancel() async {
        guard !locked else { return }
        acting = true
        actFail = ""
        if await model.caseCancel(id) {
            if await model.load("/personal/cases/" + id) == nil {
                actFail = "已停止，航程现况没刷上——可下拉再试。不会假装页面已是最新。"
            }
        } else {
            actFail = "停止没成，还可以再试"
        }
        acting = false
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
                guard !text.isEmpty, !locked else { return }
                sending = true
                actFail = ""
                Task {
                    if await model.caseSend(id, text) {
                        draft = ""; focused = false
                        // 话已送上；详情没刷上则开口，别假装新一句已显示。
                        if await model.load("/personal/cases/" + id) == nil {
                            let err = model.errors["/personal/cases/" + id] ?? ""
                            actFail = err.isEmpty
                                ? "话已送上，详情没刷上——可下拉再试。不会假装新一句已显示。"
                                : "话已送上，详情没刷上：" + err + "——可再试。不会假装新一句已显示。"
                        }
                    } else {
                        actFail = "没送出去，草稿还在"
                    }
                    sending = false
                }
            } label: { Image(systemName: sending ? "ellipsis" : "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40) }
                .buttonStyle(.primaryCompact).disabled(locked || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("case-send")
        }
    }
}

/// 从聊天、今天页、推送打开的航程：sheet 里带一个导航栈。
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

// MARK: - 明天建议

/// 每晚 21:30 生成的明天清单：勾选后一键放进行动台。日程和进行中的航程只做参考。
struct TomorrowPlanCard: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var seeded = ""
    @State private var busy = false
    @State private var hidden = false
    @State private var loading = false
    @State private var failNote = ""
    @State private var applyFail = ""
    @State private var loadedOnce = false
    private var plan: JSON { model.planData }
    private var planOpen: Bool {
        !hidden && plan["state"].string == "open" && plan["day"].string >= AppModel.dayString(0) && !plan["items"].array.isEmpty
    }
    var body: some View {
        let items = plan["items"].array
        let checkable = items.filter { $0["checkable"].bool }
        VStack(alignment: .leading, spacing: Space.md) {
            // Next 页可能已拉过 plan——有开口计划就不闪「正在拉齐」；真在拉或尚无缓存才露 busy。
            if (loading || !loadedOnce) && !planOpen {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在拉齐明天计划…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                .accessibilityLabel("正在拉齐明天计划")
                .accessibilityIdentifier("tomorrow-plan-pulling")
            }
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                Button(loading ? "重试中…" : "再试一次") {
                    guard !loading else { return }
                    Task { await refreshPlan(force: true) }
                }
                .buttonStyle(.secondaryCompact)
                .disabled(loading)
                .accessibilityIdentifier("tomorrow-plan-retry")
            }
            if planOpen {
                Card(.highlighted(.accent), padding: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("明天（周\(plan["weekday"].string)）").font(TypeScale.headline)
                            Spacer(minLength: 0)
                            Button { withAnimation(.smooth(duration: 0.25)) { hidden = true } } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                                .buttonStyle(.plain).foregroundStyle(Palette.textTertiary).accessibilityLabel("先不看")
                        }
                        Text(plan["headline"].string.isEmpty ? "我把明天值得先动的事理了一下——勾上要放进待办的。" : plan["headline"].string)
                            .font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(items.map(RemoteRow.init)) { row in planRow(row.value) }
                        }
                        if !applyFail.isEmpty {
                            InlineNotice(text: applyFail, tone: .danger)
                                .accessibilityIdentifier("tomorrow-plan-apply-fail")
                        }
                        if !checkable.isEmpty {
                            Button {
                                guard !busy else { return }
                                busy = true
                                applyFail = ""
                                Task {
                                    // 成功才本地收起；失败留卡可重试（applyPlan 已拉新 plan）。
                                    if await model.applyPlan(day: plan["day"].string, selected: Array(selected)) != nil {
                                        withAnimation(.smooth(duration: 0.25)) { hidden = true }
                                    } else {
                                        applyFail = "没放进明天待办——还可以再试，别连点"
                                    }
                                    busy = false
                                }
                            } label: {
                                HStack { Text(busy ? "放进去…" : (selected.isEmpty ? "都不用，收起" : "放进明天的待办（\(selected.count)）")); Spacer(); if busy { ProgressView() } else { Image(systemName: "arrow.right") } }
                            }
                            .buttonStyle(.primaryCompact).disabled(busy)
                            .accessibilityIdentifier("plan-apply")
                        }
                    }
                }
                .onAppear { seed(items) }
                .onChange(of: plan["day"].string) { _, _ in seed(items) }
                .accessibilityIdentifier("tomorrow-plan")
            } else if loadedOnce && !loading && !failNote.isEmpty && plan.isNull {
                Text("明天计划还没读上——先重试；通了我再开口说该先动哪几件。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    .accessibilityIdentifier("tomorrow-plan-empty-fail")
            }
        }
        .task { await refreshPlan(force: false) }
    }
    private func refreshPlan(force: Bool) async {
        guard !loading else { return }
        loading = true
        if force { failNote = "" }
        defer {
            loading = false
            loadedOnce = true
        }
        let path = "/personal/plan"
        let ok: Bool
        // 与 openPlanDeepLink 同路：入口已在拉则等它结束，避免叠刷。
        if model.planOpening && !force {
            while model.planOpening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
            }
            ok = model.errors[path] == nil && model.datasets[path] != nil
        } else {
            ok = await model.load(path) != nil
        }
        if ok {
            failNote = ""
            model.planOpenNote = ""
            return
        }
        let err = model.errors[path] ?? ""
        let hadOpen = plan["state"].string == "open" && !plan["items"].array.isEmpty
        failNote = err.isEmpty
            ? (hadOpen ? "明天计划没刷新上——下面仍是上一版，可再试" : "明天计划没拉齐——检查配对或网络后再试")
            : (hadOpen ? "明天计划没刷新上：" + err + "——下面仍是上一版" : "明天计划没拉齐：" + err + "——可再试")
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
                    // 日程和进行中的航程只做参考：字号小一号、次要色，不像可勾的待办
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

#if DEBUG
extension AppModel {
    /// `--ui-cases`：航程列表 / 详情、明天建议卡、已在待办标记、对话 todo 清单的验收数据。COM_PREVIEW_SHEET=case 直接打开详情。
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
        let more: [JSON] = [("整理周报素材", "next", "下一步", 2.0), ("核对八月报销", "todo", "待办", 26.0), ("导出大有可攀签到表", "next", "下一步", 30.0),
                            ("回复斐凡换电脑尺寸", "next", "下一步", 50.0), ("清理旧素材草稿", "todo", "待办", 240.0), ("查华为三折叠重量", "chat", "对话", 3.0)]
            .enumerated().map { n, row in .object(["id": .string("case:more\(n)"), "title": .string(row.0), "source": .string(row.1), "source_label": .string(row.2),
                "state": .string(n == 4 ? "failed" : "done"), "state_label": .string(n == 4 ? "没做成" : "完成"), "kind": .string(row.1 == "chat" ? "turn" : "task"), "now": .string(""),
                "progress": .object(["done": .number(2), "total": .number(3)]), "created_at": .number(now - row.3 * 3600 - 600), "updated_at": .number(now - row.3 * 3600), "waiting": .null]) }
        datasets["/personal/cases"] = .object(["items": .array([waiting, running, turn] + more), "active": .number(2), "waiting": .number(1)])
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
        detail["artifacts"] = .array([.object(["id": .string("art_demo1"), "name": .string("Q4排期回复草稿.md"), "path": .string("/tmp/Q4排期回复草稿.md"), "size": .number(12_800), "availability": .string("available")]), .object(["id": .string("art_demo2"), "name": .string("排期对照.pdf"), "path": .string("/tmp/排期对照.pdf"), "size": .number(2_460_000), "availability": .string("available")])]); detail["result"] = .string(""); detail["tool_calls"] = .number(7)
        detail["can_send"] = .bool(true); detail["can_cancel"] = .bool(true); detail["evidence"] = .array([])
        // 10-28 验收工作台验收数据：一条有证据、一条缺、一条要现场确认，评审说要补
        func crit(_ id: String, _ text: String, _ state: String, _ ref: String = "") -> JSON {
            .object(["id": .string(id), "text": .string(text), "state": .string(state), "covered": .bool(state == "covered"),
                     "evidence": .array(ref.isEmpty ? [] : [.object(["reference": .string(ref), "check": .string("file_exists")])])])
        }
        detail["acceptance"] = .object(["completion": .string("回复草稿能直接发，排期和 Q4 日程对得上"), "status": .string("unverified"),
            "criteria": .array([crit("c1", "草稿写进 work/航程产出", "covered", "work/航程产出/Q4排期回复草稿.md"),
                                crit("c2", "三个里程碑日期与日程一致", "missing"), crit("c3", "发出前给 Eddie 现场确认措辞", "manual")]),
            "reported": .array([.string("Q4排期回复草稿.md")]),
            "review": .object(["verdict": .string("revise"), "reason": .string("草稿在，但没有核对日程的记录。"), "gaps": .array([.string("缺里程碑日期与日历的对照")]), "next_steps": .array([])])])
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
        // 对话：一轮带 todo 清单（3 步，进了航程）
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
        if ProcessInfo.processInfo.environment["COM_PREVIEW_MENU"] == "1" { Task { try? await Task.sleep(for: .seconds(1)); showMenu = true } }
    }
}
#endif

// MARK: - 验收工作台

/// 航程做完算不算真的做完：每条完成条件 → 有证据（文件 / 测试）/ 缺证据 / 要你现场确认；下面是语义评审的结论和缺口。
/// 证据只来自后端真实检查（verification.py）和 Pi 报的 evidence，不认它自己说「做好了」。数据：/personal/cases/{id} 的 acceptance。
struct AcceptancePanel: View {
    let data: JSON
    let canAsk: Bool
    /// 航程详情正在发送/拍板时一并禁用，避免叠发。
    var locked: Bool = false
    /// 送达成功才算补问出去；失败由面板留提示。
    let ask: (String) async -> Bool
    @State private var asking = false
    @State private var failNote = ""
    private var busy: Bool { locked || asking }
    var body: some View {
        let criteria = data["criteria"].array
        let reported = data["reported"].array
        let review = data["review"]
        if !criteria.isEmpty || !data["completion"].string.isEmpty || !review.isNull {
            let covered = criteria.filter { $0["state"].string == "covered" }.count
            let missing = criteria.filter { $0["state"].string == "missing" }
            GroupSection("验收", footer: criteria.isEmpty ? "这段航程没有拆完成条件，只能对照「完成标准」和评审看。" : "证据只认真实的文件和测试检查，不认它自己说做好了。") {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: statusSymbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(statusTone.color)
                        Text(statusText).font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("case-acceptance")
                    if !criteria.isEmpty { StepProgress(done: covered, total: criteria.count) }
                    if !data["completion"].string.isEmpty {
                        Label(data["completion"].string, systemImage: "flag.checkered").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(Array(criteria.enumerated()), id: \.offset) { _, c in criterion(c) }
                    if !reported.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("它报的产出").font(.caption.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                            ForEach(Array(reported.enumerated()), id: \.offset) { _, r in
                                Label(r.string, systemImage: "doc").font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(2)
                            }
                        }
                    }
                    if !review.isNull && !review["verdict"].string.isEmpty { reviewBox(review) }
                    if !failNote.isEmpty {
                        InlineNotice(text: failNote, tone: .danger)
                            .accessibilityIdentifier("acceptance-ask-fail")
                    }
                    if canAsk && (!missing.isEmpty || !review["gaps"].array.isEmpty) {
                        let asks = missing.map { $0["text"].string } + review["gaps"].array.map(\.string)
                        Button {
                            guard !busy else { return }
                            Haptics.selection()
                            asking = true
                            failNote = ""
                            let prompt = "请补齐验收证据（文件路径或测试输出），逐条对应：\n" + asks.prefix(6).map { "- " + $0 }.joined(separator: "\n")
                            Task {
                                if !(await ask(prompt)) {
                                    failNote = "补问没送出去——还可以再点。不会假装已催它补证据。"
                                }
                                asking = false
                            }
                        } label: {
                            Label(asking ? "补问中…" : "让它补证据", systemImage: "arrow.clockwise").font(TypeScale.footnote.weight(.semibold))
                                .foregroundStyle(Palette.onAccent).padding(.horizontal, Space.md).padding(.vertical, 8)
                                .background(Palette.accent.opacity(busy ? 0.55 : 1), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .accessibilityIdentifier("acceptance-ask")
                    }
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.8))
            }
        }
    }
    private var statusText: String {
        switch data["status"].string {
        case "passed": "验收通过"
        case "pending": "还在做，做完再验"
        case "failed": "验收没过"
        case "uncertain": "结果不确定，要核实"
        default: data["criteria"].array.contains { $0["state"].string == "missing" } ? "还有条件没证据" : "等你看一眼"
        }
    }
    private var statusTone: Tone {
        switch data["status"].string {
        case "passed": .success
        case "pending": .info
        case "failed": .danger
        default: .warning
        }
    }
    private var statusSymbol: String {
        switch data["status"].string {
        case "passed": "checkmark.seal.fill"
        case "pending": "hourglass"
        case "failed": "xmark.octagon"
        default: "exclamationmark.triangle"
        }
    }
    private func criterion(_ c: JSON) -> some View {
        let state = c["state"].string
        let (symbol, tone, label): (String, Tone, String) = state == "covered" ? ("checkmark.circle.fill", .success, "有证据")
            : state == "manual" ? ("person.crop.circle.badge.questionmark", .info, "要你现场确认") : ("circle.dashed", .warning, "缺证据")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tone.color).frame(width: 18)
                Text(c["text"].string).font(TypeScale.footnote).foregroundStyle(Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.sm)
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(tone.color)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(tone.color.opacity(0.12), in: .capsule)
            }
            ForEach(Array(c["evidence"].array.enumerated()), id: \.offset) { _, e in
                Text((e["check"].string == "tests" ? "测试：" : "文件：") + e["reference"].string)
                    .font(TypeScale.code).foregroundStyle(Palette.textTertiary).lineLimit(2).padding(.leading, 26).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private func reviewBox(_ r: JSON) -> some View {
        let verdict = r["verdict"].string
        let tone: Tone = verdict == "pass" ? .success : verdict == "revise" ? .warning : .neutral
        return VStack(alignment: .leading, spacing: 4) {
            Text("评审：" + (verdict == "pass" ? "通过" : verdict == "revise" ? "要补" : "判断不了")).font(.caption.weight(.semibold)).foregroundStyle(tone.color)
            if !r["reason"].string.isEmpty { Text(r["reason"].string).font(.caption).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true) }
            ForEach(Array(r["gaps"].array.enumerated()), id: \.offset) { _, g in
                Label(g.string, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Palette.warning)
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.08), in: .rect(cornerRadius: Radius.sm, style: .continuous))
    }
}
