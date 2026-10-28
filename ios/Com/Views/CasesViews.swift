import SwiftUI
import ComCore

// 航程（2026-10-17）：一次「交给 Com」= 一个独立的 Pi 会话，能长时跟踪到了哪一步。
// 入口在下一步页右上角（二级，不进 Dock）；聊天里 3 步以上的复杂轮次也会进来，可回看。
// 后端：backend/cases.py（/personal/cases），明天建议 backend/tomorrow_plan.py（/personal/plan）。

extension AppModel {
    var casesData: JSON { datasets["/personal/cases"] ?? .null }
    var planData: JSON { datasets["/personal/plan"] ?? .null }

    /// 交给 Com：建航程，返回航程 id；Hermes 判断是一步就能办的小事时会回到主对话，返回 nil 并切到聊天。
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

// MARK: - 下一步页入口：航程大卡

/// 下一步页顶上的航程入口（10-18 重做：原来右上角一颗小胶囊，太容易漏掉）。
/// 有在跑 / 等你的航程时是一张反色大卡：最要紧的那段的标题、它此刻在做什么、进度条，点开进列表；
/// 没有在跑的但做过一些，缩成一行「航程 · 看做过的 N 段」；从来没有过就不占位（头像菜单里始终有入口）。
struct VoyageBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let items = model.casesData["items"].array
        let live = items.filter { activeStates.contains($0["state"].string) }
        if let top = live.first {
            NavigationLink { CasesListView() } label: { card(top: top, live: live) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voyage-banner")
        } else if !items.isEmpty {
            NavigationLink { CasesListView() } label: {
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
            .buttonStyle(.plain)
            .accessibilityIdentifier("voyage-banner-quiet")
        }
    }
    private func card(top: JSON, live: [JSON]) -> some View {
        let waiting = live.filter { $0["state"].string == "waiting" }.count
        let running = live.count - waiting
        let p = top["progress"]
        let line = top["state"].string == "waiting" ? "等你：" + top["waiting"]["question"].string : (top["now"].string.isEmpty ? "正在准备" : top["now"].string)
        return Card(.ink, padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "location.north.line").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.accent)
                    Text("航程").font(TypeScale.subheadline.weight(.bold)).foregroundStyle(Palette.onInk)
                    Spacer(minLength: Space.sm)
                    if running > 0 { chip("\(running) 段进行中", tone: Palette.accent) }
                    if waiting > 0 { chip("\(waiting) 段等你", tone: Palette.warning) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(top["title"].string).font(TypeScale.headline).foregroundStyle(Palette.onInk).lineLimit(2)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if top["state"].string == "running" { WorkPulse() }
                        Text(line).font(TypeScale.subheadline).foregroundStyle(top["state"].string == "waiting" ? Palette.warning : Palette.onInkSecondary).lineLimit(2)
                    }
                }
                if p["total"].int > 0 {
                    HStack(spacing: Space.sm) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.onInk.opacity(0.16))
                                Capsule().fill(Palette.accent).frame(width: max(8, geo.size.width * CGFloat(p["done"].int) / CGFloat(max(1, p["total"].int))))
                                    .animation(.smooth(duration: 0.5), value: p["done"].int)
                            }
                        }.frame(height: 6)
                        Text("\(p["done"].int)/\(p["total"].int)").font(.caption.monospacedDigit()).foregroundStyle(Palette.onInkSecondary)
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

/// 10-25 Eddie：航程一多就乱（14 天里对话顺手进来的 65 段、交办的只有 20 段）。
/// 所以：进行中 / 等你的永远置顶；历史按时间分段、每段露 3 条，「更早」默认整段收起；
/// 筛选按来源分「交办」（下一步 / 待办 / 每周……）和「对话」，默认看交办；搜索时不看筛选，搜全部。
private let caseFilters: [(key: String, title: String)] = [("delegated", "交办"), ("chat", "对话"), ("failed", "没做成"), ("all", "全部")]

private func caseIsChat(_ item: JSON) -> Bool { item["kind"].string == "turn" || item["source"].string == "chat" }

private func caseFilterMatch(_ item: JSON, _ key: String) -> Bool {
    switch key {
    case "delegated": return !caseIsChat(item)
    case "chat": return caseIsChat(item)
    case "failed": return ["failed", "cancelled"].contains(item["state"].string)
    default: return true
    }
}

/// 历史分段：今天 / 昨天 / 本周（7 天内）/ 更早。
private func caseBucket(_ at: Double) -> String {
    let calendar = Calendar.current
    let date = Date(timeIntervalSince1970: at)
    if calendar.isDateInToday(date) { return "今天" }
    if calendar.isDateInYesterday(date) { return "昨天" }
    return Date().timeIntervalSince(date) < 7 * 86400 ? "本周" : "更早"
}

struct CasesListView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: String?
    @State private var expanded: Set<String> = []
    private var items: [JSON] { model.casesData["items"].array }
    /// 默认看交办；一段交办都没有时退回全部。
    private var current: String { filter ?? (items.contains { !caseIsChat($0) } ? "delegated" : "all") }
    private var live: [JSON] { items.filter { activeStates.contains($0["state"].string) }.sorted { rank($0) < rank($1) } }
    private var history: [JSON] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { !activeStates.contains($0["state"].string) }
            .filter { q.isEmpty ? caseFilterMatch($0, current) : [$0["title"], $0["now"], $0["result"], $0["source_label"]].contains { $0.string.localizedCaseInsensitiveContains(q) } }
            .sorted { $0["updated_at"].double > $1["updated_at"].double }
    }
    private func rank(_ item: JSON) -> Int { ["waiting", "attention"].contains(item["state"].string) ? 0 : 1 }
    var body: some View {
        ScrollPage(spacing: Space.lg) {
            if items.isEmpty {
                EmptyState(title: "还没有航程", description: "在「下一步」或待办里点「交给 Com」，或者在聊天里让它办一件复杂的事，它会单独开一段航程，在这里看它一步步怎么做的。", symbol: "rectangle.stack")
            } else {
                SearchField(text: $query, prompt: "搜全部航程：标题、在做的事、结果")
                if !live.isEmpty && query.isEmpty { section("正在办 · \(live.count)", symbol: "bolt.horizontal", rows: live, limit: .max) }
                if query.isEmpty { filterBar }
                let buckets = ["今天", "昨天", "本周", "更早"].compactMap { name -> (String, [JSON])? in
                    let rows = history.filter { caseBucket($0["updated_at"].double) == name }
                    return rows.isEmpty ? nil : (name, rows)
                }
                if buckets.isEmpty {
                    Text(query.isEmpty ? "这一类里还没有做过的航程。" : "没有搜到「\(query)」。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
                }
                ForEach(buckets, id: \.0) { name, rows in
                    // 搜索时全展开；「更早」默认整段收起，只露标题和条数
                    section(name, symbol: name == "更早" ? "archivebox" : "clock", rows: rows, limit: !query.isEmpty ? .max : name == "更早" ? 0 : 3)
                }
                if query.isEmpty && current != "chat" && items.contains(where: caseIsChat) {
                    Text("聊天里顺手办的多步任务收在「对话」里。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.xs)
                }
            }
        }
        .navigationTitle("航程").navigationBarTitleDisplayMode(.large)
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
    /// 筛选胶囊：选中的一颗描边加深；「没做成」的数字用警示色角标（参考图里 All E-mail 的红点数字）。只管下面的历史，正在办的始终在上面。
    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.sm) {
                ForEach(caseFilters, id: \.key) { f in
                    let count = items.filter { !activeStates.contains($0["state"].string) && caseFilterMatch($0, f.key) }.count
                    let on = current == f.key
                    Button { withAnimation(.snappy(duration: 0.25)) { filter = f.key; expanded = [] } } label: {
                        HStack(spacing: 6) {
                            Text(f.title).font(TypeScale.footnote.weight(on ? .semibold : .regular))
                            if count > 0 {
                                Text("\(count)").font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(f.key == "failed" ? .white : Palette.textSecondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(f.key == "failed" ? Palette.danger : Palette.fill, in: .capsule)
                            }
                        }
                        .foregroundStyle(on ? Palette.textPrimary : Palette.textSecondary)
                        .padding(.horizontal, Space.md).padding(.vertical, 8)
                        .background(Palette.surface, in: .capsule)
                        .overlay(Capsule().strokeBorder(on ? Palette.textPrimary.opacity(0.75) : Palette.separator, lineWidth: on ? 1.2 : 0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("cases-filter-" + f.key)
                }
            }
            .padding(.horizontal, 1).padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }
    /// 一段：标题行 + 一张白卡（行间细线），超过 limit 条收起，底部「查看全部（N）」。
    private func section(_ title: String, symbol: String, rows: [JSON], limit: Int) -> some View {
        let open = expanded.contains(title) || rows.count <= limit
        let shown = open ? rows : Array(rows.prefix(limit))
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(TypeScale.subheadline)
                if limit != .max { Text("\(rows.count)").font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.textTertiary) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.textSecondary).padding(.horizontal, Space.xs)
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Palette.separator).padding(.leading, 64) }
                    NavigationLink { CaseDetailView(id: item.id) } label: { CaseRow(item: item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("case-" + item.id)
                }
                if !open || expanded.contains(title) && rows.count > limit {
                    if !shown.isEmpty { Divider().overlay(Palette.separator) }
                    Button { withAnimation(.snappy(duration: 0.3)) { if open { expanded.remove(title) } else { expanded.insert(title) } } } label: {
                        HStack(spacing: 4) {
                            Text(open ? "收起" : "查看全部（\(rows.count)）")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                        }
                        .font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.info)
                        .frame(maxWidth: .infinity).padding(.vertical, Space.md)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.8))
        }
    }
}

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
        let preview = waiting && !item["waiting"]["question"].string.isEmpty ? "等你：" + item["waiting"]["question"].string
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
                if data["state"].string == "waiting" { waitingCard }
                if !data["outcome"]["reason"].string.isEmpty && data["state"].string == "failed" {
                    InlineNotice(text: "没做成：" + data["outcome"]["reason"].string, tone: .warning)
                }
                letter
                actions
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
            Button("停止", role: .destructive) { Task { await model.caseCancel(id); _ = await model.load("/personal/cases/" + id) } }
        }
        .navigationTitle("航程").navigationBarTitleDisplayMode(.inline)  // 标题已在正文第一行（来信式），导航栏不再重复
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
                pill("标完成", "checkmark.circle") { Task { await model.caseResolve(id); _ = await model.load("/personal/cases/" + id) } }
            }
        }
    }
    private func pill(_ title: String, _ symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Text(title); Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                .font(TypeScale.footnote.weight(.medium)).foregroundStyle(destructive ? Palette.danger : Palette.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Palette.surface, in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
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

/// 每晚 21:30 生成的明天清单：勾选后一键放进行动台。日程和进行中的航程只做参考。
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
