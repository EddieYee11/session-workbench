import SwiftUI
import ComCore

// 「今天」tab：日程、提醒、行动台待办和等你拍板的事排成一条时间线。早上打开就知道今天怎么过。
// 数据：/personal/today（日程 + 提醒 + 待办，后端只读聚合）+ App 已有的 flowItems（派活待批准、停下来等你的任务）。
// 下面还保留事项详情、健康卡和几个来源口径的小工具。

/// 时间线上的一条。start 为 0 的是「全天」：没有具体时刻的待办和全天日程。
struct TodayEntry: Identifiable {
    enum Kind { case event, reminder, todo, decision }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let start: Double
    let end: Double
    let overdue: Bool
    let done: Bool
    let value: JSON
    var pending: PendingItem?
    /// 已经过去：日程看结束时间，提醒看到点时间；待办和等你的事没有「过去」。
    func isPast(_ now: Double) -> Bool {
        switch kind {
        case .event: start > 0 && (end > start ? end : start + 1800) < now
        case .reminder: done || (start > 0 && start < now && !overdue)
        default: false
        }
    }
}

extension AppModel {
    var todayData: JSON { datasets["/personal/today"] ?? .null }
    /// 「今天」的全部条目：日程、提醒、待办来自 /personal/today，等你决定的来自 flowItems（不含一周以上的旧任务）。
    var todayEntries: [TodayEntry] {
        var out: [TodayEntry] = []
        for e in todayData["events"].array {
            let allDay = e["all_day"].bool
            let place = [e["location"].string, sourceName(e["source"].string)].filter { !$0.isEmpty }.joined(separator: " · ")
            out.append(TodayEntry(id: "event:" + e.id, kind: .event, title: e["title"].string,
                                  subtitle: allDay ? place : [clockTime(e["start"].double) + (e["end"].double > e["start"].double ? "–" + clockTime(e["end"].double) : ""), e["location"].string].filter { !$0.isEmpty }.joined(separator: " · "),
                                  start: allDay ? 0 : e["start"].double, end: e["end"].double, overdue: false, done: false, value: e))
        }
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        for r in todayData["reminders"].array {
            // 刚打了勾、撤销窗口还没过的提醒：轮询回来的快照里它还是待提醒，照样按已完成算（r3-pages）。
            let done = r["status"].string == "done" || TodayChecks.settling.contains("reminder:" + r.id)
            // 和后端快照同一个口径：今天到点的，或者还没处理的过期提醒。过期的勾掉之后就不属于今天了，不再挂到时间线的昨天位置上。
            if done && r["at"].double < dayStart { continue }
            let overdue = r["overdue"].bool && !done
            out.append(TodayEntry(id: "reminder:" + r.id, kind: .reminder, title: r["title"].string,
                                  subtitle: overdue ? "过期没处理 · " + r["due"].string : done ? "已完成" : "提醒",
                                  start: overdue ? 0 : r["at"].double, end: 0, overdue: overdue, done: done, value: r))
        }
        for t in todayData["todos"].array where !TodayChecks.settling.contains("todo:" + t.id) {
            out.append(TodayEntry(id: "todo:" + t.id, kind: .todo, title: t["title"].string,
                                  subtitle: [t["overdue"].bool ? "已过期 · 计划 " + t["due"].string : t["due"].string.isEmpty ? "进行中" : "今天到期", t["next_step"].string].filter { !$0.isEmpty }.joined(separator: " · "),
                                  start: 0, end: 0, overdue: t["overdue"].bool, done: false, value: t))
        }
        for item in pendingItems where !item.stale {
            out.append(TodayEntry(id: "decision:" + item.id, kind: .decision, title: item.title, subtitle: [item.stamp, item.source].filter { !$0.isEmpty }.joined(separator: " · "),
                                  start: 0, end: 0, overdue: false, done: false, value: item.value, pending: item))
        }
        return out
    }
    /// 大日期下面那行灰字：「4 个日程 · 5 个待办」。待办 = 提醒 + 行动台待办 + 等你决定；节假日这类只是信息的日历不算日程。（轨道 r2-pages）
    var todaySummary: String {
        if todayData.isNull && !isUITesting { return errors["/personal/today"] == nil ? "正在看今天的安排…" : "今天的安排暂时没读到" }
        let entries = todayEntries
        let events = entries.filter { $0.kind == .event && !$0.value["informational"].bool }.count
        let todos = entries.filter { ($0.kind == .reminder && !$0.done) || $0.kind == .todo || $0.kind == .decision }.count
        if events == 0 && todos == 0 { return "今天没有安排" }
        return [events > 0 ? "\(events) 个日程" : "", todos > 0 ? "\(todos) 个待办" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// 动提醒：完成 / 晚 10 分钟 / 晚 1 小时 / 取消，写回 pi-gateway 的提醒记录，再回读一次。
    func reminderAction(_ reminder: JSON, _ action: String) async {
        #if DEBUG
        if isUITesting {
            var value = todayData
            value["reminders"] = .array(value["reminders"].array.compactMap { row in
                guard row.id == reminder.id else { return row }
                if action == "cancel" { return nil }
                var copy = row; if action == "confirm" { copy["status"] = .string("done"); copy["overdue"] = .bool(false) }; return copy
            })
            datasets["/personal/today"] = value; Haptics.success(); return
        }
        #endif
        do {
            _ = try await mutate("/personal/reminders/" + reminder.id.pathEncoded + "/action",
                                 fields: ["action": .string(action), "expected": .object(["due": reminder["due"], "status": reminder["status"]])])
            _ = await load("/personal/today"); Haptics.success()
        } catch { banner = error.localizedDescription }
    }

    /// 往后推：行动台待办把「计划结束」改到明天（只改那一行），提醒晚 1 小时。列表先收起，失败就回读一次放回来。
    func postponeTodayEntry(_ entry: TodayEntry) async {
        if entry.kind == .reminder { await reminderAction(entry.value, "snooze60"); return }
        guard entry.kind == .todo else { return }
        var data = todayData
        data["todos"] = .array(data["todos"].array.filter { $0.id != entry.value.id }); datasets["/personal/today"] = data
        #if DEBUG
        if isUITesting { Haptics.success(); return }
        #endif
        do { _ = try await mutate("/personal/today/todos/postpone", fields: ["path": entry.value["path"]]); Haptics.success() }
        catch { _ = await load("/personal/today") }
    }

    /// 今天页顶上那句简报：「下一步」整理时顺手写的（结合身体、日程和最要紧的事）。
    var todayHeadline: String { nextData["headline"].string }
    /// 简报展开后的 3–5 条要点（10-17）：身体 / 日程 / 事 / 资讯，资讯带原文链接。
    var todayBrief: [JSON] { nextData["brief"].array.filter { !$0["text"].string.isEmpty } }

    /// 资讯反馈：点开记「想看」；左滑记「不感兴趣」并先在本地收起那条。
    func newsFeedback(_ id: String, _ action: String) async {
        guard !id.isEmpty else { return }
        if action == "dismiss" {
            var value = nextData
            value["brief"] = .array(value["brief"].array.filter { $0["news_id"].string != id })
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { datasets["/personal/next"] = value }
        }
        #if DEBUG
        if isUITesting { return }
        #endif
        _ = try? await mutate("/personal/news/" + id.pathEncoded, fields: ["action": .string(action)])
    }

    /// 待办前面的圆点（轨道 r3-pages）：先在手机上划掉，列表立刻收起；行动台待办同时写回 vault（状态 → 已完成）。
    /// 提醒在 pi-gateway 那边没有「撤销完成」，所以先不写，撤销窗口过了再确认（settleTodayCheck）。
    func checkTodayEntry(_ entry: TodayEntry) -> TodayCheck? {
        let key = entry.kind == .todo ? "todos" : "reminders"
        var data = todayData
        var rows = data[key].array
        guard let index = rows.firstIndex(where: { $0.id == entry.value.id }) else { return nil }
        let check = TodayCheck(entry: entry, index: index)
        TodayChecks.settling.insert(entry.id)
        if entry.kind == .todo { rows.remove(at: index) } else { rows[index]["status"] = .string("done") }
        data[key] = .array(rows); datasets["/personal/today"] = data
        guard entry.kind == .todo else { return check }
        check.write = Task { [weak self] in
            defer { TodayChecks.settling.remove(entry.id) }
            guard let self else { return nil }
            #if DEBUG
            if self.isUITesting { return .object(["状态": .string("状态: 待处理"), "完成时间": .string("完成时间:")]) }
            #endif
            do { return try await self.mutate("/personal/today/todos/done", fields: ["path": entry.value["path"]])["undo"] }
            catch { _ = await self.load("/personal/today"); return nil }  // mutate 已经提示了；回读一次，它会回到列表里
        }
        return check
    }
    /// 撤销：放回原处；行动台待办再按打勾时记下的两行原文写回去（打勾那次请求还在路上就先等它回来）。
    func undoTodayCheck(_ check: TodayCheck) async {
        let entry = check.entry
        let key = entry.kind == .todo ? "todos" : "reminders"
        TodayChecks.settling.remove(entry.id)
        var data = todayData
        var rows = data[key].array
        if let i = rows.firstIndex(where: { $0.id == entry.value.id }) { rows[i] = entry.value } else { rows.insert(entry.value, at: min(check.index, rows.count)) }
        data[key] = .array(rows); datasets["/personal/today"] = data
        guard let write = check.write, let undo = await write.value, !undo.isNull else { return }
        #if DEBUG
        if isUITesting { return }
        #endif
        do { _ = try await mutate("/personal/today/todos/undo", fields: ["path": entry.value["path"], "undo": undo]) }
        catch { _ = await load("/personal/today") }
    }
    /// 撤销窗口过了：提醒这时才写回 pi-gateway；行动台待办打勾时已经写过了。
    func settleTodayCheck(_ check: TodayCheck) async {
        guard check.entry.kind == .reminder else { return }
        defer { TodayChecks.settling.remove(check.entry.id) }
        #if DEBUG
        if isUITesting { return }
        #endif
        let reminder = check.entry.value
        _ = try? await mutate("/personal/reminders/" + reminder.id.pathEncoded + "/action",
                              fields: ["action": .string("confirm"), "expected": .object(["due": reminder["due"], "status": reminder["status"]])])
        _ = await load("/personal/today")
    }
}

/// 打了勾、还在撤销窗口里的一条待办（轨道 r3-pages）。
@MainActor final class TodayCheck: Identifiable {
    let id = UUID()
    let entry: TodayEntry
    /// 在原数组里的位置，撤销时放回原处。
    let index: Int
    /// 行动台待办写回 vault 的那次请求；结果是撤销用的两行原文。提醒没有这一步。
    var write: Task<JSON?, Never>?
    init(entry: TodayEntry, index: Int) { self.entry = entry; self.index = index }
}

/// 打了勾、还没落定的条目。这期间 15 秒一次的轮询拿回来的旧快照里它还在，照样按已完成算，免得提示条还没消失它又冒回列表。
@MainActor enum TodayChecks { static var settling: Set<String> = [] }

/// 界面验收用的固定时钟（轨道 r3-pages）：带 --ui-r3-dense 启动时，「今天」页把现在当成 14:00，密集验收数据每次排出来都一样。
enum TodayClock {
    static let offset: Double = {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-r3-dense") else { return 0 }
        return Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 + 14 * 3600 - Date().timeIntervalSince1970
        #else
        return 0
        #endif
    }()
}

// MARK: - 今天（轨道 r2-pages 重做）
// 参考：Delivery App（大标题问候 + 深色胶囊提示条 + 甘特式时间线）、Salesforce Daily Operation（大数字统计 + 柔和分类色卡）、
// Ai OS（左上大日期 + 灰色第二行、彩色圆形事项图标、Next Task 弧形刻度大钟、Tasks 白卡与黄色大卡并排、横向柔色时间轴）。
// 顺序：大日期 → 深色提示条 → 四个数字 → 下一件（弧形刻度）→ 待办 | 等你决定 → 横向时间轴 → 任务与目标。
// 动效（全部取自动效库 work/内容生产/动效库/，并尊重「减弱动态效果」）：
// - 各块进场：20-build-checklist「标题模糊上浮 y+26→0、blur 10→0、power3.out，错峰 2 帧」；
// - 大日期两行：11-beam-text-reveal「横向运动模糊滑入清晰」；
// - 四个数字：13-leaderboard-counter「数字逐帧线性爬升到终值」；
// - 弧形进度：17-bar-chart-3d「柱子 ease-out 生长」，事项圆点 / 提示条：03-badge-stamp「从大到小旋转盖入」；
// - 时间轴卡片：11-beam-text-reveal 横向滑入 + 错峰；等你决定大卡里的数字同 13。

/// 柔和分类色：薄荷 / 薰衣草 / 奶油黄 / 樱粉 / 天蓝。fill 是卡底，ink 是卡上的字和图标。
enum TodayHue {
    case mint, lavender, butter, pink, sky
    var fill: Color {
        switch self {
        case .mint: todayColor(0xDDF4E8, 0x1D3A2D)
        case .lavender: todayColor(0xECE6FF, 0x2D2742)
        case .butter: todayColor(0xFFF0A6, 0x3A3216)
        case .pink: todayColor(0xFCE2EB, 0x3D2430)
        case .sky: todayColor(0xDDEBFF, 0x1E2D44)
        }
    }
    var ink: Color {
        switch self {
        case .mint: todayColor(0x1E7A52, 0x93E4BB)
        case .lavender: todayColor(0x5A3FC0, 0xC9B8FF)
        case .butter: todayColor(0x765A00, 0xFFD866)
        case .pink: todayColor(0xB23C68, 0xFFA8C6)
        case .sky: todayColor(0x2F5FB8, 0x9EC4FF)
        }
    }
}

private func todayColor(_ light: UInt32, _ dark: UInt32) -> Color {
    func ui(_ v: UInt32) -> UIColor { UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
    return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
}

extension TodayEntry {
    /// 分类色：工作日历薰衣草、个人 / 运动薄荷、提醒奶油黄、行动台待办樱粉、等你决定奶油黄，其余天蓝。
    var hue: TodayHue {
        switch kind {
        case .reminder, .decision: return .butter
        case .todo: return .pink
        case .event:
            let calendar = value["calendar"].string.lowercased()
            if ["工作", "work", "会议", "公司"].contains(where: calendar.contains) { return .lavender }
            if ["个人", "生活", "家", "personal", "home"].contains(where: calendar.contains) || ["跑", "健身", "攀岩", "运动", "骑"].contains(where: title.contains) { return .mint }
            return value["source"].string == "google_calendar" ? .lavender : .sky
        }
    }
    /// 圆形事项图标：按标题猜一个具体的，猜不到就用日历。
    var glyph: String {
        switch kind {
        case .reminder: return "bell.fill"
        case .todo: return "checklist"
        case .decision: return pending?.kind == .proposal ? "desktopcomputer" : "hand.raised.fill"
        case .event:
            for (keys, symbol) in [(["跑"], "figure.run"), (["攀岩"], "figure.climbing"), (["骑", "摩旅"], "figure.outdoor.cycle"), (["健身", "运动"], "dumbbell.fill"),
                                   (["饭", "餐", "咖啡"], "fork.knife"), (["航班", "飞", "高铁"], "airplane"), (["电话", "通话"], "phone.fill"),
                                   (["会", "评审", "讨论", "访谈", "面试"], "person.2.fill")] where keys.contains(where: title.contains) { return symbol }
            return "calendar"
        }
    }
    var timeRange: String { clockTime(start) + (end > start ? "–" + clockTime(end) : "") }
}

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    /// 刚打了勾的那条：底下的「已完成 · 撤销」提示条跟着它（r3-pages）。
    @State private var check: TodayCheck?
    @State private var checkTimer: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // 每分钟走一格：「现在」线、倒计时的大数和淡化跟着时间动；秒级倒计时只在那一行文字里自己走。
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date.timeIntervalSince1970 + TodayClock.offset
            let entries = model.todayEntries
            let timed = entries.filter { $0.start > 0 }.sorted { $0.start < $1.start }
            let events = timed.filter { $0.kind == .event && !$0.value["informational"].bool }
            let next = events.first { $0.start > now } ?? timed.first { $0.start > now && !$0.done }
            let todos = entries.filter { ($0.kind == .reminder || $0.kind == .todo) && !$0.done }
                .sorted { ($0.overdue ? 0 : 1, $0.start == 0 ? .greatestFiniteMagnitude : $0.start) < ($1.overdue ? 0 : 1, $1.start == 0 ? .greatestFiniteMagnitude : $1.start) }
            ScreenScaffold(title: "今天") {
                // 10-17 收拢成三张：简报（可展开）→ 下一件 + 身体横幅（各自点开表盘 / 身体详情）→ 待办 / 时间线分段卡。
                // 微信、拍板、一句话交代和任务入口拿掉：微信和拍板已在「下一步」，交代用全局语音，任务入口缩成标题旁的小按钮。
                TodayHeader(summary: model.todaySummary, shown: shown)
                TodayBrief()
                    .modifier(EnterRise(on: shown, delay: 0.08))
                NowBanner(next: next, timed: events, now: now, shown: shown)
                    .modifier(EnterRise(on: shown, delay: 0.14))
                TodayCasesStrip()  // 10-17：进行中的案例串到今天页，点开看到哪一步
                    .modifier(EnterRise(on: shown, delay: 0.17))
                TodayDeck(todos: todos, timed: timed, allDay: entries.filter { $0.kind == .event && $0.start == 0 }, now: now, shown: shown,
                          complete: complete, postpone: { entry in Task { await model.postponeTodayEntry(entry) } })
                    .modifier(EnterRise(on: shown, delay: 0.2))
                let errors = model.todayData["errors"].object.filter { $0.key != "wechat" }
                if !errors.isEmpty {
                    InlineNotice(text: "有来源没读到：" + errors.keys.sorted().map { ["events": "日程", "reminders": "提醒", "todos": "行动台"][$0] ?? $0 }.joined(separator: "、"), tone: .neutral)
                }
            }
            .animation(reduce ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: entries.map(\.id))
        }
        .refreshable { await model.refresh(.doing); _ = await model.load("/personal/next") }
        .overlay(alignment: .bottom) {
            if let check {
                UndoToast(title: check.entry.title, undo: undo)
                    .padding(.horizontal, Layout.margin).padding(.bottom, Space.sm)
                    .transition(reduce ? .opacity : .modifier(active: ToastRise(on: false), identity: ToastRise(on: true)))
            }
        }
        // 每次切回「今天」都重新走一遍进场；切走时复位。
        .onAppear { shown = true }
        .onDisappear { shown = false; settleCheck() }
        // 退到后台不等 4 秒：提醒这时就写回去。
        .onChange(of: scenePhase) { _, phase in if phase != .active { settleCheck() } }
    }

    // MARK: 待办打勾（r3-pages）
    private var toastAnimation: Animation { reduce ? .easeOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.9) }
    /// 圆点画完勾、行收起的那一刻调到这里：先落定上一条，再把这一条划掉、亮出 4 秒的撤销。
    private func complete(_ entry: TodayEntry) {
        settleCheck()
        guard let next = model.checkTodayEntry(entry) else { return }
        withAnimation(toastAnimation) { check = next }
        checkTimer = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { settleCheck() }
        }
    }
    private func undo() {
        checkTimer?.cancel()
        guard let current = check else { return }
        withAnimation(toastAnimation) { check = nil }
        Haptics.selection()
        Task { await model.undoTodayCheck(current) }
    }
    private func settleCheck() {
        checkTimer?.cancel()
        guard let current = check else { return }
        withAnimation(toastAnimation) { check = nil }
        Task { await model.settleTodayCheck(current) }
    }
}

// MARK: 简报 / 快速交代 / 建议（驾驶舱）

/// 今日简报：「下一步」每小时整理时让模型写的一句话（身体 + 日程松紧 + 最要紧的事）；没有就给个按钮现在整理。
private struct TodayBrief: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("today.brief.open") private var open = true
    var body: some View {
        let running = model.nextData["running"].bool
        let headline = model.todayHeadline
        let points = model.todayBrief
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.onAccent)
                    .frame(width: 30, height: 30).background(Palette.accent, in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    // 简报换新：旧句模糊淡出、新句从下面模糊上浮（和「下一步」的 blurLift 同一套语法）。
                    Text(headline.isEmpty ? (running ? "正在看今天…" : "今天还没整理") : headline)
                        .font(TypeScale.callout.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(headline)
                        .transition(reduce ? .opacity : .blurLift)
                        .accessibilityIdentifier("today-headline")
                        .opacity(running && !reduce ? 0.55 : 1)
                    HStack(spacing: 4) {
                        Text(running ? "重新整理中" : model.nextData["updated_at"].double > 0 ? "整理于 " + relativeTime(model.nextData["updated_at"].double) : "从日程、身体、行动台和资讯里看")
                        if !points.isEmpty {
                            Text("· \(points.count) 条要点")
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(open ? 180 : 0))
                        }
                    }
                    .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Button { Task { await model.refreshNext() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                        .symbolEffect(.rotate.byLayer, options: .repeating, isActive: running && !reduce)
                        .frame(width: 30, height: 30).background(Palette.fill, in: .circle)
                }
                .buttonStyle(.plain).disabled(running)
                .accessibilityLabel("重新整理今天").accessibilityIdentifier("today-brief-refresh")
            }
            .contentShape(.rect)
            .onTapGesture {
                guard !points.isEmpty else { return }
                Haptics.selection()
                withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)) { open.toggle() }
            }
            // 先自成一个容器再挂标识，不然标识会盖掉里面「today-headline」这些子元素的。
            .accessibilityElement(children: .contain)
            .accessibilityHint(points.isEmpty ? "" : open ? "点一下收起要点" : "点一下展开要点")
            .accessibilityIdentifier("today-brief-toggle")
            if open && !points.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(Array(points.sorted { BriefPoint.order($0["kind"].string) < BriefPoint.order($1["kind"].string) }.enumerated()), id: \.element["text"].string) { index, point in
                        BriefPoint(point: point, index: index)
                    }
                }
                .padding(.top, Space.md)
                .transition(.opacity)
            }
        }
        .padding(Space.lg)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
        .clipShape(.rect(cornerRadius: Radius.lg, style: .continuous))
        .animation(reduce ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: headline)
        .animation(reduce ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: points.map { $0["text"].string })
        .animation(.smooth(duration: 0.3), value: running)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-brief")
    }
}

/// 简报的一条要点：前面一个小色点标类型（身体 / 日程 / 事 / 资讯）。
/// 资讯那条点开跳原文（顺手记一笔「想看」），左滑过 90pt 记「不感兴趣」并收起——下回挑资讯时避开同类。
/// 进场：一条条错峰 0.05s 模糊上浮（和「下一步」的 blurLift 同语法）；左滑跟手，松手不够远就弹回。
private struct BriefPoint: View {
    let point: JSON
    let index: Int
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var drag: CGFloat = 0
    @State private var shown = false
    private var news: Bool { point["kind"].string == "news" }
    private var style: (String, String, TodayHue) {
        switch point["kind"].string {
        case "health": ("heart.fill", "身体", .pink)
        case "event": ("calendar", "日程", .sky)
        case "news": ("newspaper.fill", "资讯", .butter)
        default: ("flag.fill", "要事", .mint)
        }
    }
    /// 简报要点的类目顺序：身体 → 日程 → 要事 → 资讯。
    static func order(_ kind: String) -> Int { ["health": 0, "event": 1, "note": 2, "news": 3][kind] ?? 2 }
    var body: some View {
        let (symbol, label, hue) = style
        // 10-17 二版：每条一块浅色小卡，左上角标类目，卡与卡之间留缝——不再是一串粘在一起的字。
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(hue.ink)
                .frame(width: 28, height: 28).background(Palette.surface, in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label).font(.caption.weight(.bold)).foregroundStyle(hue.ink)
                    if news { Text("左滑不感兴趣").font(.caption2).foregroundStyle(Palette.textTertiary) }
                }
                Text(point["text"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if news {
                    HStack(spacing: 4) {
                        Text(point["site"].string.isEmpty ? "原文" : point["site"].string)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.accentText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(hue.fill.opacity(0.55), in: .rect(cornerRadius: Radius.md, style: .continuous))
        .contentShape(.rect)
        .offset(x: drag)
        .background(alignment: .trailing) {
            if news && drag < 0 {
                Label("不感兴趣", systemImage: "hand.thumbsdown.fill").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    .opacity(min(1, Double(-drag) / 90))
            }
        }
        .onTapGesture {
            guard news, let url = URL(string: point["url"].string) else { return }
            Task { await model.newsFeedback(point["news_id"].string, "open") }
            openURL(url)
        }
        .simultaneousGesture(news ? swipe : nil)
        .opacity(shown ? 1 : 0)
        .blur(radius: shown || reduce ? 0 : 6)
        .offset(y: shown || reduce ? 0 : 10)
        .onAppear { withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86).delay(0.04 + Double(index) * 0.05)) { shown = true } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(news ? .isLink : [])
        .accessibilityAction(named: "不感兴趣") { if news { dismiss() } }
        .accessibilityIdentifier("today-brief-point-\(index)")
    }
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = min(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width < -90 && abs(value.translation.width) > abs(value.translation.height) { dismiss() }
                else { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 } }
            }
    }
    private func dismiss() {
        Haptics.selection()
        withAnimation(reduce ? .easeOut(duration: 0.2) : .easeIn(duration: 0.2)) { drag = -420 }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            await model.newsFeedback(point["news_id"].string, "dismiss")
        }
    }
}

// MARK: 下一件 + 身体（一条横幅，两半各自点开）

/// 左半：下一件的时刻、标题、倒计时，点开在横幅里展开半圈表盘；右半：身体电量小环 + 睡眠 / HRV，点开展开身体卡。
/// 同一时刻只展开一边，展开哪边记住（today.now.open）。展开收起走同一条 spring（0.42 / 0.86），箭头跟着转。
private struct NowBanner: View {
    let next: TodayEntry?
    let timed: [TodayEntry]
    let now: Double
    let shown: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("today.now.open") private var openRaw = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Space.md) {
                Button { toggle("dial") } label: { nextSide }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today-next-toggle")
                Rectangle().fill(Palette.separator).frame(width: 0.5).padding(.vertical, Space.xs)
                Button { toggle("body") } label: { bodySide }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today-body-toggle")
            }
            .padding(Space.lg)
            if openRaw == "dial" {
                NextUpCard(next: next, timed: timed, now: now, shown: shown, embedded: true)
                    .padding([.horizontal, .bottom], Space.lg)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            } else if openRaw == "body" {
                BodyCard(shown: shown, embedded: true)
                    .padding([.horizontal, .bottom], Space.lg)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .background(Palette.surface, in: .rect(cornerRadius: Radius.xl, style: .continuous))
        .clipShape(.rect(cornerRadius: Radius.xl, style: .continuous))
        .elevation(.raised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-now-banner")
    }
    private func toggle(_ side: String) {
        Haptics.selection()
        withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)) { openRaw = openRaw == side ? "" : side }
    }
    private func caret(_ side: String) -> some View {
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textTertiary)
            .rotationEffect(.degrees(openRaw == side ? 180 : 0))
    }
    private var nextSide: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(next == nil ? "现在" : "下一件").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                caret("dial")
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(clockTime(next?.start ?? now))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText())
                if let next {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(countdown(next.start - context.date.timeIntervalSince1970 - TodayClock.offset))
                            .font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.accentText)
                    }
                }
            }
            Text(next?.title ?? "今天之后没有日程了").font(TypeScale.subheadline.weight(.medium))
                .foregroundStyle(next == nil ? Palette.textSecondary : Palette.textPrimary).lineLimit(1)
                .accessibilityIdentifier("today-next-title")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
    private var bodySide: some View {
        let health = model.health
        let m = health["today"]["measurements"]
        let phone = health["phone"]
        let battery: Double? = m["body_battery"].isNull ? nil : m["body_battery"].double
        let sleep = !m["sleep_seconds"].isNull ? m["sleep_seconds"].double / 3600 : phone["sleep_hours"].isNull ? nil : phone["sleep_hours"].double
        let third: String? = !m["hrv_last_night"].isNull ? "HRV \(m["hrv_last_night"].int)" : !phone["steps"].isNull ? "\(phone["steps"].int) 步" : nil
        return HStack(spacing: Space.sm) {
            MiniRing(value: battery, shown: shown)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("身体").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                    caret("body")
                }
                Text(sleep.map { "睡 " + $0.formatted(.number.precision(.fractionLength(1))) + "h" } ?? "未同步")
                    .font(TypeScale.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.textPrimary)
                if let third { Text(third).font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.textSecondary) }
            }
        }
        .fixedSize()
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-body-summary")
    }
    private func countdown(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? "\(s / 3600) 小时 \(s % 3600 / 60) 分后" : String(format: "%02d:%02d 后", s / 60, s % 60)
    }
}

/// 横幅里的小电量环：和身体卡的大环同一个配色和生长（0.9s ease-out）。
private struct MiniRing: View {
    let value: Double?
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let v = value ?? 0
        ZStack {
            Circle().stroke(Palette.fill, lineWidth: 5)
            Circle().trim(from: 0, to: shown || reduce ? v / 100 : 0)
                .stroke(batteryColor(v), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduce ? nil : .easeOut(duration: 0.9).delay(0.2), value: shown)
            Text(value.map { "\(Int($0))" } ?? "—").font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(Palette.textPrimary)
        }
        .frame(width: 46, height: 46)
        .accessibilityLabel("身体电量 " + (value.map { String(Int($0)) } ?? "未知"))
    }
}

// MARK: 待办 / 时间线（一张卡，分段切换）

/// 两段：待办（能打勾）和时间线（横向时间轴）。青柠胶囊滑到选中那段（matchedGeometry，和表盘窗口切换同一组 spring），
/// 内容按方向横移 + 淡入：往右切从右边进，往左切从左边进。选哪段记住；默认有待办先看待办。
private struct TodayDeck: View {
    let todos: [TodayEntry]
    let timed: [TodayEntry]
    let allDay: [TodayEntry]
    let now: Double
    let shown: Bool
    let complete: (TodayEntry) -> Void
    let postpone: (TodayEntry) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("today.deck") private var pageRaw = "todo"
    @Namespace private var space
    var body: some View {
        let timeline = pageRaw == "timeline"
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: 4) {
                segment("todo", "待办", todos.count)
                segment("timeline", "时间线", timed.count + allDay.count)
            }
            .padding(3)
            .background(Palette.fill, in: .capsule)
            ZStack(alignment: .topLeading) {
                if timeline {
                    TodayTimeline(entries: timed, allDay: allDay, now: now, shown: shown, embedded: true)
                        .transition(slide(from: .trailing))
                } else {
                    TodoCard(todos: todos, shown: shown, complete: complete, postpone: postpone, embedded: true)
                        .transition(slide(from: .leading))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(Space.lg)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.xl, style: .continuous))
        .clipShape(.rect(cornerRadius: Radius.xl, style: .continuous))
        .elevation(.raised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-deck")
    }
    private func slide(from edge: HorizontalEdge) -> AnyTransition {
        reduce ? .opacity : .opacity.combined(with: .offset(x: edge == .leading ? -28 : 28))
    }
    private func segment(_ id: String, _ title: String, _ count: Int) -> some View {
        let on = pageRaw == id
        return Button {
            guard !on else { return }
            Haptics.selection()
            withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.84)) { pageRaw = id }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(TypeScale.footnote.weight(.semibold))
                Text("\(count)").font(TypeScale.footnote.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
                    .opacity(0.6)
            }
            .foregroundStyle(on ? Palette.onAccent : Palette.textSecondary)
            .padding(.horizontal, Space.md).padding(.vertical, 6)
            .background { if on { Capsule().fill(Palette.accent).matchedGeometryEffect(id: "deck", in: space) } }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("today-deck-" + id)
    }
}

/// 「已完成 · 撤销」：和顶上的提示条一个样子（深色胶囊），停 4 秒。
private struct UndoToast: View {
    let title: String
    let undo: () -> Void
    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.onAccent)
                .frame(width: 30, height: 30).background(Palette.accent, in: .circle)
            Text("已完成 · " + title).font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.onInk).lineLimit(1)
            Spacer(minLength: Space.sm)
            Button(action: undo) {
                Text("撤销").font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                    .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-undo")
        }
        .padding(.leading, 7).padding(.trailing, Space.sm)
        .background(Palette.ink, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-undo-toast")
    }
}

/// 提示条进出：20-build-checklist 的「上浮」（y+26→0，弹簧近似 power3.out），出去原路下沉，开合对称；不加模糊，小字糊了像闪。
private struct ToastRise: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { content.opacity(on ? 1 : 0).offset(y: on ? 0 : 26) }
}

/// 20-build-checklist 的「模糊上浮」：y+26→0、blur 10→0、power3.out（这里用临界阻尼弹簧近似），各块错峰。
private struct EnterRise: ViewModifier {
    let on: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || reduce ? 0 : 26)
            .blur(radius: on || reduce ? 0 : 10)
            .animation(reduce ? .easeOut(duration: 0.2) : on ? .spring(response: 0.55, dampingFraction: 0.9).delay(delay) : nil, value: on)
    }
}

/// 11-beam-text-reveal 的横向滑入：从右边 +offset、带模糊滑进来变清晰。
private struct BeamReveal: ViewModifier {
    let on: Bool
    let delay: Double
    var distance: CGFloat = 36
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(x: on || reduce ? 0 : distance)
            .blur(radius: on || reduce ? 0 : 8)
            .animation(reduce ? .easeOut(duration: 0.2) : on ? .spring(response: 0.5, dampingFraction: 0.88).delay(delay) : nil, value: on)
    }
}

/// 03-badge-stamp：从大到小、带一点旋转盖下来，back.out 回弹。
private struct StampIn: ViewModifier {
    let on: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .scaleEffect(on || reduce ? 1 : 1.6)
            .rotationEffect(.degrees(on || reduce ? 0 : -14))
            .animation(reduce ? .easeOut(duration: 0.2) : on ? .spring(response: 0.42, dampingFraction: 0.58).delay(delay) : nil, value: on)
    }
}

/// 13-leaderboard-counter：数字从 0 一档一档爬到终值（Animatable，每帧只重画这一个 Text）。
private struct CountUp: View, @MainActor Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text("\(Int(value.rounded()))").monospacedDigit() }
}

// MARK: 大日期

private struct TodayHeader: View {
    @Environment(AppModel.self) private var model
    let summary: String
    let shown: Bool
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date().formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(Palette.textPrimary)
                    .modifier(BeamReveal(on: shown, delay: 0))
                Text(summary)
                    .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .modifier(BeamReveal(on: shown, delay: 0.06))
                    .accessibilityIdentifier("today-summary")
            }
            Spacer(minLength: Space.sm)
            HStack(spacing: Space.sm) {
                Text(Date().formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                    .font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Space.md).padding(.vertical, 6)
                    .background(Palette.surface, in: .capsule)
                // 任务与目标：不常用，缩成一颗小按钮；有等你拍板的才挂个数。
                NavigationLink { TaskHubView() } label: {
                    Image(systemName: "square.stack").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                        .frame(width: 30, height: 30).background(Palette.surface, in: .circle)
                        .overlay(alignment: .topTrailing) {
                            if model.decisionCount > 0 {
                                Text("\(model.decisionCount)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(Palette.onAccent)
                                    .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16).background(Palette.accent, in: .capsule).offset(x: 5, y: -5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("任务与目标").accessibilityIdentifier("today-task-hub")
            }
            .padding(.top, 10)
        }
    }
}

// MARK: 下一件（Ai OS 的弧形刻度大钟）

/// r3-pages：卡片不再整张是一个链接——表盘上挤在一起的那一摞要能单独点开。中间的大时间和底下那行照旧点进「下一件」。
private struct NextUpCard: View {
    let next: TodayEntry?
    let timed: [TodayEntry]
    let now: Double
    let shown: Bool
    /// 嵌在横幅里展开时：不再自带底色、内边距和阴影（10-17）。
    var embedded = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 点开的那一摞（存 id，分钟刷新重排之后照样认得）。
    @State private var opened: [String] = []
    @AppStorage("today.dial.span") private var spanRaw = DialSpan.near.rawValue
    private var span: DialSpan { DialSpan(rawValue: spanRaw) ?? .near }
    var body: some View {
        let stack = opened.compactMap { id in timed.first { $0.id == id } }
        VStack(spacing: Space.md) {
            spanPicker
            ZStack(alignment: .bottom) {
                TodayDial(timed: timed, next: next, shown: shown, opened: opened, span: span) { ids in
                    withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.82)) { opened = opened == ids ? [] : ids }
                }
                if let next {
                    NavigationLink { TodayDetail(entry: next) } label: { center }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("today-next-time")
                } else {
                    center
                }
            }
            if !stack.isEmpty {
                StackList(entries: stack, now: now)
                    .transition(reduce ? .opacity : .opacity.combined(with: .offset(y: -10)))
            }
            if let next {
                NavigationLink { TodayDetail(entry: next) } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: next.glyph).font(.system(size: 15, weight: .semibold)).foregroundStyle(next.hue.ink)
                            .frame(width: 36, height: 36).background(next.hue.fill, in: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.title).font(TypeScale.headline).foregroundStyle(Palette.textPrimary).lineLimit(1)
                            Text([next.timeRange, next.value["location"].string].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Chevron()
                    }
                    .padding(.horizontal, Space.xs)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-next-row")
            }
        }
        .padding(embedded ? 0 : Space.lg)
        .background(embedded ? .clear : Palette.surface, in: .rect(cornerRadius: Radius.xl, style: .continuous))
        .elevation(embedded ? .flat : .raised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-next-card")
    }
    /// 窗口切换：眼前 / 半天 / 全天，选中的那颗青柠胶囊滑过去。
    @Namespace private var spanSpace
    private var spanPicker: some View {
        HStack(spacing: 4) {
            ForEach(DialSpan.allCases) { item in
                Button {
                    Haptics.selection()
                    withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.82)) { spanRaw = item.rawValue; opened = [] }
                } label: {
                    Text(item.rawValue).font(TypeScale.footnote.weight(.semibold))
                        .foregroundStyle(span == item ? Palette.onAccent : Palette.textSecondary)
                        .padding(.horizontal, Space.md).padding(.vertical, 6)
                        .background { if span == item { Capsule().fill(Palette.accent).matchedGeometryEffect(id: "span", in: spanSpace) } }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-dial-span-" + item.rawValue)
            }
        }
        .padding(3)
        .background(Palette.fill, in: .capsule)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    private var center: some View {
        VStack(spacing: 2) {
            Text(next == nil ? "现在" : "下一件").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
            Text(clockTime(next?.start ?? now))
                .font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                .contentTransition(.numericText())
            if let next {
                // 秒级倒计时只在这一行文字里走，整张卡不跟着每秒重画。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("还有 " + countdown(next.start - context.date.timeIntervalSince1970 - TodayClock.offset))
                        .font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.textSecondary)
                }
            } else {
                Text("今天之后没有日程了").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.bottom, 4)
        .padding(.horizontal, Space.md)
        .contentShape(.rect)
    }
    private func countdown(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }
}

/// 点开的那一摞：几件挤在一起的日程排成几行，点哪行进哪件的详情。
/// 动效：一行行错峰 2 帧上浮（20-build-checklist 的「上浮、错峰 2 帧」），卡片跟着长高（和依据袋同一条 spring 0.4/0.82）。
private struct StackList: View {
    let entries: [TodayEntry]
    let now: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("这一段挤了 \(entries.count) 件").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, Space.xs).padding(.bottom, Space.xs)
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                NavigationLink { TodayDetail(entry: entry) } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: entry.glyph).font(.system(size: 12, weight: .bold)).foregroundStyle(entry.hue.ink)
                            .frame(width: 28, height: 28).background(entry.hue.fill, in: .circle)
                        Text(entry.timeRange).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(Palette.textSecondary)
                        Text(entry.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Spacer(minLength: 0)
                        Chevron()
                    }
                    .padding(.horizontal, Space.xs)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                    .opacity(entry.isPast(now) ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-stack-row-" + entry.id)
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduce ? 0 : 18)
                .animation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86).delay(0.04 + Double(index) * 0.066), value: shown)
            }
        }
        .padding(.vertical, Space.sm)
        .background(Palette.fill.opacity(0.6), in: .rect(cornerRadius: Radius.md, style: .continuous))
        .onAppear { shown = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-stack-list")
    }
}

/// 表盘的时间窗：眼前 4 小时（1 小时前到 3 小时后，跟着时间滚动）/ 半天 12 小时（滚动）/ 全天（0–24 点固定，只有「现在」在走）。
enum DialSpan: String, CaseIterable, Identifiable {
    case near = "眼前", half = "半天", day = "全天"
    var id: String { rawValue }
    var before: Double { switch self { case .near: 3600; case .half: 3 * 3600; case .day: 0 } }
    var length: Double { switch self { case .near: 4 * 3600; case .half: 12 * 3600; case .day: 24 * 3600 } }
    /// 刻度上标时间的间隔（小时）。
    var labelEvery: Double { switch self { case .near: 1; case .half: 3; case .day: 6 } }
    var minorEvery: Double { switch self { case .near: 900; case .half: 3600; case .day: 3600 } }
}

/// 半圈刻度表（10-15 重做）：会动、带时间、能点能拖。
/// - 跟着时间走：表盘自己每秒取一次「现在」，眼前 / 半天两档的窗口跟着滚，刻度、时间标签和日程一起往左漂；全天档窗口固定，只有「现在」沿弧走；
/// - 外圈整点标时间（间隔随窗口变），内圈一条条彩色带是日程从开始到结束，过去的变淡；黑弧走到「现在」，现在点有一圈呼吸光；
/// - 点日程圆点进详情；挤在一起的并成一摞，点开在卡片里展开；手指沿半圈拖，读出那一刻的时间和正在那个时间的日程。
/// 碰撞避让沿用 DialLayout。弧的生长仍是 trim 动画（17-bar-chart-3d 的 ease-out 生长），圆点盖章落下（03-badge-stamp）。
private struct TodayDial: View {
    let timed: [TodayEntry]
    let next: TodayEntry?
    let shown: Bool
    let opened: [String]
    let span: DialSpan
    let open: ([String]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 手指沿弧拖到的比例（nil = 没在拖）。
    @State private var scrub: Double?
    @State private var breathe = false

    var body: some View {
        // 每秒一帧：4 小时铺半圈，一秒只挪 0.0125°，看上去是连续漂移。
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.timeIntervalSince1970 + TodayClock.offset
            GeometryReader { geo in
                // 两端留 44pt 给弧外的时间标签（「17:00」不被卡片边裁掉）。
                let radius: CGFloat = min(geo.size.width / 2 - 44, 150)
                let center = CGPoint(x: geo.size.width / 2, y: radius + 30)
                let start = windowStart(now)
                ZStack(alignment: .topLeading) {
                    Path { p in p.addArc(center: center, radius: radius - 30, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false); p.closeSubpath() }
                        .fill(Palette.fill)
                    bands(center: center, radius: radius, start: start, now: now)
                    ticks(center: center, radius: radius, start: start)
                    progress(center: center, radius: radius, start: start, now: now)
                    markers(center: center, radius: radius, start: start, now: now)
                    nowDot(center: center, radius: radius, start: start, now: now)
                    if let scrub { scrubber(center: center, radius: radius, f: scrub, start: start) }
                }
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let f = angleFraction(value.location, center: center)
                        if scrub == nil { Haptics.selection() }
                        scrub = f
                    }
                    .onEnded { _ in withAnimation(.easeOut(duration: 0.25)) { scrub = nil } })
            }
        }
        .frame(height: 196)
        .onAppear { breathe = true }
        .accessibilityElement(children: .contain)
    }

    private func windowStart(_ now: Double) -> Double {
        if span == .day { return Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970 }
        return now - span.before
    }
    private func fraction(_ t: Double, _ start: Double) -> Double { (t - start) / span.length }
    private func clamp(_ f: Double) -> Double { min(1, max(0, f)) }
    private func point(_ center: CGPoint, _ radius: CGFloat, _ f: Double) -> CGPoint {
        let angle = Angle.degrees(180 + 180 * f).radians
        return CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
    }
    /// 手指位置 → 弧上比例（只认上半圈，下面的按两端算）。
    private func angleFraction(_ p: CGPoint, center: CGPoint) -> Double {
        var a = atan2(Double(p.y - center.y), Double(p.x - center.x))  // -π…π，上半圈是 -π…0
        if a > 0 { a = p.x < center.x ? -Double.pi : 0 }
        return clamp((a + Double.pi) / Double.pi)
    }

    /// 内圈日程带：开始到结束一段弧，各用自己的颜色；过去的淡、正在进行的实。
    private func bands(center: CGPoint, radius: CGFloat, start: Double, now: Double) -> some View {
        let r = radius - 20
        return ForEach(timed.filter { $0.end > start && $0.start < start + span.length }) { entry in
            let a = clamp(fraction(entry.start, start)), b = clamp(fraction(max(entry.end, entry.start + 300), start))
            DialArc(center: center, radius: r)
                .trim(from: a, to: shown || reduce ? max(a + 0.004, b) : a)
                .stroke(entry.hue.ink.opacity(entry.end < now ? 0.22 : entry.start <= now ? 0.9 : 0.55), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .animation(reduce ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(0.4), value: shown)
                .accessibilityHidden(true)
        }
    }

    /// 刻度 + 外圈时间：整点粗、刻度细；每隔 labelEvery 小时标一个「14:00」。
    private func ticks(center: CGPoint, radius: CGFloat, start: Double) -> some View {
        let minor = span.minorEvery, label = span.labelEvery * 3600, length = span.length
        let first = ceil(start / minor) * minor
        let zone = TimeZone.current.secondsFromGMT()
        return Canvas { context, _ in
            var t = first
            while t <= start + length + 1 {
                let f = (t - start) / length
                let local = t + Double(zone)
                let major = Int(local.truncatingRemainder(dividingBy: 3600)) == 0
                let labelled = Int(local.truncatingRemainder(dividingBy: label)) == 0
                var tick = Path()
                tick.move(to: point(center, radius - (labelled ? 14 : major ? 11 : 8), f))
                tick.addLine(to: point(center, radius - 4, f))
                context.stroke(tick, with: .color(labelled ? .primary.opacity(0.7) : major ? .secondary : .secondary.opacity(0.35)),
                               style: StrokeStyle(lineWidth: labelled ? 2 : 1.5, lineCap: .round))
                if labelled && f > -0.001 && f < 1.001 {
                    let text = Text(clockTime(t)).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    context.draw(text, at: point(center, radius + 21, f))
                }
                t += minor
            }
        }
        .accessibilityHidden(true)
    }

    private func progress(center: CGPoint, radius: CGFloat, start: Double, now: Double) -> some View {
        let end: Double = shown || reduce ? clamp(fraction(now, start)) : 0
        let curve: Animation? = reduce ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1).delay(0.25)
        return DialArc(center: center, radius: radius + 4)
            .trim(from: 0, to: end)
            .stroke(Palette.textPrimary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .animation(curve, value: shown)
            .animation(reduce ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: span)
            .accessibilityHidden(true)
    }

    /// 日程圆点：单个点进详情，挤着的并成一摞点开展开。
    private func markers(center: CGPoint, radius: CGFloat, start: Double, now: Double) -> some View {
        let inWindow = timed.filter { $0.start >= start && $0.start <= start + span.length }
        let slots = DialLayout.place(inWindow.map { ($0, fraction($0.start, start), $0.id == next?.id ? 28 : 22) },
                                     now: clamp(fraction(now, start)), nowSize: 12, arc: Double.pi * Double(radius + 4))
        return ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
            Group {
                if slot.entries.count > 1 {
                    Button { open(slot.entries.map(\.id)) } label: {
                        DialStack(entries: slot.entries, isNext: slot.entries.contains { $0.id == next?.id }, opened: opened == slot.entries.map(\.id), past: slot.entries.allSatisfy { $0.isPast(now) })
                            .frame(width: 44, height: 44).contentShape(.circle)
                    }
                    .buttonStyle(DialPress())
                    .accessibilityLabel("\(slot.entries.count) 件挤在一起：" + slot.entries.map { clockTime($0.start) + " " + $0.title }.joined(separator: "，"))
                    .accessibilityIdentifier("today-dial-stack")
                } else if let entry = slot.entries.first {
                    NavigationLink { TodayDetail(entry: entry) } label: {
                        // 圆点按原大小画（避让按这个尺寸算），点按热区往外扩到约 44pt。
                        DialMarker(entry: entry, isNext: entry.id == next?.id, past: entry.isPast(now))
                            .contentShape(Circle().inset(by: entry.id == next?.id ? -8 : -11))
                    }
                    .buttonStyle(DialPress())
                    .accessibilityLabel(clockTime(entry.start) + " " + entry.title)
                    .accessibilityValue(entry.id == next?.id ? "下一件" : "")
                    .accessibilityIdentifier("today-dial-" + entry.id)
                }
            }
            .modifier(StampIn(on: shown, delay: 0.45 + Double(index) * 0.066))
            .position(point(center, radius + 4, slot.f))
            .animation(reduce ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: span)
        }
    }

    /// 「现在」：弧的末端一颗青柠点，外面一圈慢慢呼吸的光。
    private func nowDot(center: CGPoint, radius: CGFloat, start: Double, now: Double) -> some View {
        ZStack {
            Circle().fill(Palette.accent.opacity(0.45))
                .frame(width: 26, height: 26)
                .scaleEffect(breathe && !reduce ? 1.25 : 0.7).opacity(breathe && !reduce ? 0 : 0.9)
                .animation(reduce ? nil : .easeOut(duration: 1.8).repeatForever(autoreverses: false), value: breathe)
            Circle().fill(Palette.accent).overlay(Circle().strokeBorder(Palette.textPrimary, lineWidth: 2))
                .frame(width: 12, height: 12)
        }
        .position(point(center, radius + 4, clamp(fraction(now, start))))
        .animation(reduce ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: span)
        .opacity(shown || reduce ? 1 : 0)
        .animation(reduce ? nil : .easeOut(duration: 0.3).delay(1.1), value: shown)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("现在 " + clockTime(now))
        .accessibilityIdentifier("today-dial-now")
    }

    /// 拖动时：一根指针从圆心指到弧上，弧外一枚胶囊写着那一刻的时间，以及那个时间正在进行的日程。
    private func scrubber(center: CGPoint, radius: CGFloat, f: Double, start: Double) -> some View {
        let t = start + f * span.length
        let hit = timed.first { $0.start <= t && t < max($0.end, $0.start + 300) }
        let tip = point(center, radius + 4, f)
        return ZStack {
            Path { p in p.move(to: point(center, radius - 34, f)); p.addLine(to: tip) }
                .stroke(Palette.textPrimary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
            Circle().strokeBorder(Palette.textPrimary, lineWidth: 2).background(Circle().fill(Palette.surface)).frame(width: 14, height: 14).position(tip)
            VStack(spacing: 1) {
                Text(clockTime(t)).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                Text(hit?.title ?? "空闲").font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Palette.ink, in: .capsule)
            .fixedSize()
            .position(x: tip.x, y: max(18, tip.y - 34))
            .contentTransition(.numericText())
        }
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 表盘上的圆点按下去缩一下。
private struct DialPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.86 : 1).animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// 表盘上的避让排布（r3-pages）。位置都用 0…1 的弧上比例（和 TodayDial.fraction 同一把尺）。
/// 1. 按时间排好，相邻两颗挨得比「两半径 + 4pt」还近就算挤；一串挤着的超过两颗，并成一摞（摆在这串最早那颗的位置）；
/// 2. 剩下的连同「现在」那颗点，从左到右合并成簇：簇内按最小间距排开、整体对准各自原位的平均（含「现在」的簇对准「现在」，它不动）；
///    簇之间还挤就继续合并，直到谁都不压谁；
/// 3. 最后收进弧的两端。
enum DialLayout {
    struct Slot: Identifiable {
        let entries: [TodayEntry]
        let f: Double
        var id: String { entries.map(\.id).joined(separator: "|") }
    }
    private struct Node { let entries: [TodayEntry]; let want: Double; let size: Double; let fixed: Bool }

    static func place(_ items: [(TodayEntry, Double, CGFloat)], now: Double, nowSize: Double, arc: Double, gap: Double = 4) -> [Slot] {
        let sorted = items.sorted { $0.1 < $1.1 }
        func sep(_ a: Double, _ b: Double) -> Double { (a / 2 + b / 2 + gap) / arc }
        // 1. 并摞
        var nodes: [Node] = []
        var run: [(TodayEntry, Double, CGFloat)] = []
        func flush() {
            // 一摞连后面两层边和数字章，占的地方按 40pt 算。
            if run.count > 2 { nodes.append(Node(entries: run.map(\.0), want: run[0].1, size: 40, fixed: false)) }
            else { nodes += run.map { Node(entries: [$0.0], want: $0.1, size: Double($0.2), fixed: false) } }
            run = []
        }
        for item in sorted {
            if let last = run.last, item.1 - last.1 >= sep(Double(last.2), Double(item.2)) { flush() }
            run.append(item)
        }
        flush()
        // 2. 连同「现在」合并成簇
        nodes.append(Node(entries: [], want: now, size: nowSize, fixed: true))
        nodes.sort { $0.want < $1.want || ($0.want == $1.want && $0.fixed && !$1.fixed) }
        var clusters: [[Node]] = nodes.map { [$0] }
        func offsets(_ c: [Node]) -> [Double] {
            var out = [0.0]
            for i in 1..<max(1, c.count) { out.append(out[i - 1] + sep(c[i - 1].size, c[i].size)) }
            return out
        }
        func start(_ c: [Node]) -> Double {
            let off = offsets(c)
            if let j = c.firstIndex(where: \.fixed) { return c[j].want - off[j] }
            let s = zip(c, off).map { $0.want - $1 }.reduce(0, +) / Double(c.count)
            // 收进弧的两端（半个圆点的宽度留在弧上）
            let lo = c[0].size / 2 / arc, hi = 1 - c[c.count - 1].size / 2 / arc - off[c.count - 1]
            return min(max(s, lo), max(lo, hi))
        }
        var merged = true
        while merged {
            merged = false
            var i = 0
            while i < clusters.count - 1 {
                let a = clusters[i], b = clusters[i + 1]
                let endA = start(a) + offsets(a)[a.count - 1]
                if endA + sep(a[a.count - 1].size, b[0].size) > start(b) + 1e-9 {
                    clusters[i] = a + b; clusters.remove(at: i + 1); merged = true
                } else { i += 1 }
            }
        }
        // 3. 落位（「现在」那颗不输出，它自己画）
        var slots: [Slot] = []
        for c in clusters {
            let s = start(c), off = offsets(c)
            for (node, o) in zip(c, off) where !node.fixed { slots.append(Slot(entries: node.entries, f: min(1, max(0, s + o)))) }
        }
        return slots
    }
}

private struct DialMarker: View {
    let entry: TodayEntry
    let isNext: Bool
    let past: Bool
    var body: some View {
        let size: CGFloat = isNext ? 28 : 22
        Image(systemName: entry.glyph).font(.system(size: isNext ? 12 : 10, weight: .bold)).foregroundStyle(entry.hue.ink)
            .frame(width: size, height: size)
            .background(entry.hue.fill, in: .circle)
            .overlay(Circle().strokeBorder(isNext ? entry.hue.ink : Palette.surface, lineWidth: isNext ? 1.5 : 2))
            .opacity(past ? 0.45 : 1)
    }
}

/// 一摞：最早那件的图标在最上面，后面露出两层边，右上角一枚数字章（03-badge-stamp 盖进来）。
private struct DialStack: View {
    let entries: [TodayEntry]
    let isNext: Bool
    let opened: Bool
    let past: Bool
    var body: some View {
        let first = entries[0]
        ZStack {
            ForEach(0..<2, id: \.self) { layer in
                Circle().fill(entries[min(entries.count - 1, 2 - layer)].hue.fill)
                    .overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2))
                    .frame(width: 26, height: 26)
                    .offset(x: CGFloat(2 - layer) * 3, y: CGFloat(2 - layer) * -3)
            }
            Image(systemName: first.glyph).font(.system(size: 11, weight: .bold)).foregroundStyle(first.hue.ink)
                .frame(width: 26, height: 26)
                .background(first.hue.fill, in: .circle)
                .overlay(Circle().strokeBorder(isNext || opened ? first.hue.ink : Palette.surface, lineWidth: isNext || opened ? 1.5 : 2))
            Text("\(entries.count)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Palette.onAccent)
                .frame(minWidth: 16, minHeight: 16).background(Palette.accent, in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.surface, lineWidth: 1.5))
                .offset(x: 13, y: -13)
        }
        .opacity(past ? 0.45 : 1)
    }
}

private struct DialArc: Shape {
    let center: CGPoint
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path { p in p.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false) }
    }
}

// MARK: 待办 | 等你决定

private struct TodoCard: View {
    let todos: [TodayEntry]
    let shown: Bool
    let complete: (TodayEntry) -> Void
    var postpone: (TodayEntry) -> Void = { _ in }
    /// 嵌在分段卡里：标题和数字由分段胶囊给，卡片底色和最小高度也交给外面（10-17）。
    var embedded = false
    private var limit: Int { embedded ? 5 : 4 }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !embedded {
                HStack(alignment: .firstTextBaseline) {
                    Text("待办").font(TypeScale.headline).foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(todos.count)").font(TypeScale.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.textTertiary)
                        .contentTransition(.numericText())
                }
            }
            if todos.isEmpty {
                Text("没有要办的").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
            // 每行 44pt 高、行间不留缝：圆点的热区上下挨着但不重叠；收起时整行高度收成 0，下面的行顺着补上。
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(todos.prefix(limit).enumerated()), id: \.element.id) { index, entry in
                    TodoRow(entry: entry, complete: { complete(entry) }, postpone: { postpone(entry) })
                        .modifier(BeamReveal(on: shown, delay: 0.3 + Double(index) * 0.066, distance: 18))
                        .transition(.modifier(active: RowCollapse(progress: 0), identity: RowCollapse(progress: 1)))
                }
            }
            .padding(.top, embedded ? -Space.xs : -Space.sm)
            if !embedded { Spacer(minLength: 0) }
            if todos.count > limit {
                NavigationLink { TodayList(title: "今天的待办", entries: todos) } label: {
                    Text("全部 \(todos.count) 件").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.accentText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(embedded ? 0 : Space.lg)
        .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity, alignment: .topLeading)
        .frame(minHeight: embedded ? 0 : 196)
        .background(embedded ? .clear : Palette.surface, in: .rect(cornerRadius: Radius.xl, style: .continuous))
        .elevation(embedded ? .flat : .raised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-todo-card")
    }
}

/// 待办一行（r3-pages）：点前面的圆点打勾，点字进详情。圆点热区 44×44，和字的热区挨着不重叠，点圆点不会进详情。
/// 打勾动效：
/// - 圆点填满 + 勾 = 20-build-checklist「打勾，back.out 弹入」：spring(0.35s, bounce 0.45)，和「下一步」构建卡的勾同一组；勾线晚 2 帧画出；
/// - 划线 = 05-tweet-highlight「荧光笔从左扫入」：10 帧（0.33s），实测曲线拟合成 cubic-bezier(0.35, 0.05, 0.25, 1)，硬边；
/// - 划完停一拍（0.56s）交给列表：整行高度收成 0 再离开（RowCollapse），撤销时原路展开。
private struct TodoRow: View {
    let entry: TodayEntry
    let complete: () -> Void
    var postpone: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var checked = false
    private var tint: Color { entry.overdue ? Palette.warning : entry.hue.ink }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: check) {
                ZStack {
                    Circle().strokeBorder(tint.opacity(entry.overdue ? 1 : 0.6), lineWidth: 1.5)
                    Circle().fill(tint)
                        .scaleEffect(checked ? 1 : 0.3).opacity(checked ? 1 : 0)
                        .animation(reduce ? nil : .spring(duration: 0.35, bounce: 0.45), value: checked)
                    CheckMark().trim(from: 0, to: checked ? 1 : 0)
                        .stroke(Palette.surface, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 8, height: 6)
                        .animation(reduce ? nil : .easeOut(duration: 0.2).delay(0.066), value: checked)
                }
                .frame(width: 18, height: 18)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(checked)
            .accessibilityLabel("完成：" + entry.title)
            .accessibilityIdentifier("today-check-" + entry.id)
            NavigationLink { TodayDetail(entry: entry) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.system(size: 14, weight: .medium)).foregroundStyle(checked ? Palette.textTertiary : Palette.textPrimary).lineLimit(1)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Palette.textTertiary).frame(height: 1.5)
                                .scaleEffect(x: checked ? 1 : 0, anchor: .leading)
                                .animation(reduce ? nil : .timingCurve(0.35, 0.05, 0.25, 1, duration: 0.333).delay(0.1), value: checked)
                        }
                        .animation(reduce ? nil : .easeOut(duration: 0.2), value: checked)
                    Text(entry.overdue ? "过期" : entry.start > 0 ? clockTime(entry.start) : entry.kind == .todo ? "行动台" : "提醒")
                        .font(.system(size: 11)).foregroundStyle(entry.overdue ? Palette.warning : Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(checked)
            .accessibilityIdentifier("today-" + entry.id)
        }
        // 圆点看上去还贴着卡片左边（和原来一样），热区往卡片内边距里多伸 13pt。
        .padding(.leading, -13)
        // 长按往后推：行动台待办改到明天，提醒晚 1 小时。
        .contextMenu {
            if !checked {
                Button(entry.kind == .todo ? "改到明天" : "晚 1 小时", systemImage: "arrow.uturn.forward") { postpone() }
                Button("完成", systemImage: "checkmark.circle") { check() }
                // 10-17：待办也能交给 Com，走同一套案例，跑完自动打勾。
                if entry.kind == .todo && !entry.value["path"].string.isEmpty {
                    Button("交给 Com", systemImage: "paperplane") {
                        Task { if let id = await model.delegateTodo(entry.value["path"].string) { model.presentedCase = id } }
                    }
                }
            }
        }
    }
    private func check() {
        guard !checked else { return }
        Haptics.selection()
        if reduce { checked = true; complete(); return }
        checked = true
        Task { try? await Task.sleep(for: .milliseconds(560)); complete() }
    }
}

private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}

/// 行收起 / 展开：高度按比例收到 0（量的是这一行自己要的高度），同时淡出；横向不裁，圆点伸出去的热区还在。
private struct RowCollapse: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        CollapseLayout(progress: progress) { content }
            .clipShape(VerticalClip())
            .opacity(Double(progress * progress))
    }
}
/// 名字和设计系统里的 Layout（边距常量）撞了，这里写全 SwiftUI.Layout。
private struct CollapseLayout: SwiftUI.Layout {
    var progress: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard let row = subviews.first else { return .zero }
        let size = row.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height * max(0, progress))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard let row = subviews.first else { return }
        let size = row.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        row.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}
private struct VerticalClip: Shape {
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: -40, dy: 0)) }
}

/// 待办超过 4 件时的完整清单。
private struct TodayList: View {
    let title: String
    let entries: [TodayEntry]
    var body: some View {
        ScrollPage {
            GroupedCard(dividerInset: 56) {
                ForEach(entries) { entry in
                    NavigationLink { TodayDetail(entry: entry) } label: {
                        ListRow(symbol: entry.glyph, tone: entry.overdue ? .warning : .neutral, title: entry.title, titleLines: 1,
                                subtitle: entry.overdue ? "过期" : entry.start > 0 ? clockTime(entry.start) : entry.subtitle, subtitleLines: 1)
                    }
                    .buttonStyle(.row)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: ComDock.height) }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
    }
}

// MARK: 横向时间轴（Ai OS 右图 + Delivery App 的 Task Timeline）

private struct TodayTimeline: View {
    let entries: [TodayEntry]
    /// 全天的日程（含节假日这类信息日历）：没有时刻，不上时间轴，排在时间线标题下面一行（r3-pages）。
    let allDay: [TodayEntry]
    let now: Double
    let shown: Bool
    /// 嵌在分段卡里：「时间线」标题由分段胶囊给，这里不再重复（10-17）；打开时自己滚到「现在」。
    var embedded = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var position = ScrollPosition(edge: .leading)
    @State private var viewport: CGFloat = 0
    private static let hourWidth: CGFloat = 112
    private static let minCard: CGFloat = 124
    private static let laneHeight: CGFloat = 108
    /// 四道及以上换矮卡（图标 + 一行标题，下面时间），r2 的大卡最多三道（时间线最高也就是原来那么高）。
    private static let compactHeight: CGFloat = 62
    private static let ruler: CGFloat = 30
    private static let gap: CGFloat = 10
    /// 同一道里前后两张卡至少隔开这么多。
    private static let spacing: CGFloat = 8
    private static let pad: CGFloat = 4
    /// 「现在」胶囊大约的半宽，用来让开刻度上的时刻字。
    private static let nowHalf: CGFloat = 44

    private struct Slot: Identifiable { let entry: TodayEntry; let x: CGFloat; let width: CGFloat; let lane: Int; var id: String { entry.id } }

    private var dayStart: Double { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970 }
    private var hours: ClosedRange<Int> {
        let starts = entries.map(\.start) + [now]
        let ends = entries.map { max($0.end, $0.start + 1800) } + [now]
        var lo = Int(floor(((starts.min() ?? now) - dayStart) / 3600))
        var hi = Int(ceil(((ends.max() ?? now) - dayStart) / 3600))
        lo = max(0, lo); hi = min(24, max(hi, lo + 6))
        return lo...hi
    }
    private func x(_ t: Double) -> CGFloat { Self.pad + CGFloat((t - dayStart) / 3600 - Double(hours.lowerBound)) * Self.hourWidth }
    /// 分道（r3-pages）：按开始时间排（同一时刻长的在前），放进第一条放得下的道——前一张卡的右边 + 8pt 不超过这张的左边；
    /// 道数不设上限，卡片永远不叠。原来最多三道、放不下就叠在最早空出来的那道，挨得近的几件会压在一起。
    private var slots: [Slot] {
        let ordered = entries.sorted { ($0.start, -(max($0.end, $0.start) - $0.start)) < ($1.start, -(max($1.end, $1.start) - $1.start)) }
        var laneEnds: [CGFloat] = []
        var out: [Slot] = []
        for entry in ordered {
            let left = x(entry.start)
            let width = max(Self.minCard, entry.end > entry.start ? CGFloat((entry.end - entry.start) / 3600) * Self.hourWidth - 6 : 0)
            let lane = laneEnds.firstIndex { $0 + Self.spacing <= left } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(0) }
            laneEnds[lane] = left + width
            out.append(Slot(entry: entry, x: left, width: width, lane: lane))
        }
        return out
    }

    var body: some View {
        let layout = slots
        let lanes = max(1, (layout.map(\.lane).max() ?? 0) + 1)
        let compact = lanes >= 4
        let cardHeight = compact ? Self.compactHeight : Self.laneHeight
        let width = max(x(dayStart + Double(hours.upperBound) * 3600), (layout.map { $0.x + $0.width }.max() ?? 0)) + Self.pad
        let height = Self.ruler + CGFloat(lanes) * (cardHeight + Self.gap)
        let nowX = x(now)
        VStack(alignment: .leading, spacing: Space.md) {
            if !embedded { HStack(alignment: .firstTextBaseline) {
                Text("时间线").font(TypeScale.section).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { scrollToNow(animated: true) } label: {
                    Label("现在", systemImage: "scope").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.accentText)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-timeline-now")
            } }
            if !allDay.isEmpty { allDayRow }
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    // 刻度：每小时一根淡竖线 + 时刻；时刻字被「现在」胶囊盖住的那一个先藏起来（r3-pages）。
                    ForEach(Array(hours), id: \.self) { hour in
                        let hx = x(dayStart + Double(hour) * 3600)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(format: "%02d:00", hour)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Palette.textTertiary)
                                .opacity(hx + 36 > nowX - Self.nowHalf && hx < nowX + Self.nowHalf ? 0 : 1)
                            Rectangle().fill(Palette.separator).frame(width: 0.5)
                        }
                        .frame(height: height, alignment: .topLeading)
                        .offset(x: hx)
                    }
                    ForEach(Array(layout.enumerated()), id: \.element.id) { index, slot in
                        NavigationLink { TodayDetail(entry: slot.entry) } label: {
                            TimelineCard(entry: slot.entry, past: slot.entry.isPast(now), compact: compact)
                                .frame(width: slot.width, height: cardHeight)
                        }
                        .buttonStyle(CardPress())
                        .accessibilityIdentifier("today-" + slot.entry.id)
                        .offset(x: slot.x, y: Self.ruler + CGFloat(slot.lane) * (cardHeight + Self.gap))
                        .modifier(BeamReveal(on: shown, delay: 0.35 + Double(index) * 0.05))
                    }
                    NowLine(now: now, height: height)
                        .offset(x: nowX - 1)
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0; scrollToNow(animated: false) }
            .accessibilityIdentifier("today-timeline")
            if entries.isEmpty {
                Text("今天没有定时的安排").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.xs)
            }
        }
    }
    /// 全天的几件：一行胶囊，放不下就横着滑；点进详情。r4: 增强视觉层次 + 流畅进场动画。
    private var allDayRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.sm) {
                // 全天标签：更醒目的样式
                Text("全天")
                    .font(TypeScale.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.surface, in: .capsule)

                // 全天事件：带错峰动画的胶囊
                ForEach(Array(allDay.enumerated()), id: \.element.id) { index, entry in
                    NavigationLink { TodayDetail(entry: entry) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: entry.glyph)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(entry.hue.ink)
                                .frame(width: 20, height: 20)
                                .background(.white.opacity(0.7), in: .circle)
                            Text(entry.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(entry.hue.ink)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(entry.hue.fill, in: .capsule)
                        .opacity(entry.value["informational"].bool ? 0.75 : 1)
                        .shadow(color: entry.hue.fill.opacity(0.3), radius: 2, y: 1)
                    }
                    .buttonStyle(CardPress())
                    .accessibilityIdentifier("today-allday-" + entry.id)
                    .modifier(BeamReveal(on: shown, delay: 0.35 + Double(index) * 0.06))
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("today-allday")
    }
    /// 把「现在」放到可视区的三分之一处：前面能看到刚过去的，后面看到接下来的。
    private func scrollToNow(animated: Bool) {
        guard viewport > 0 else { return }
        let target = max(0, x(now) - viewport / 3)
        if animated && !reduce { withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { position.scrollTo(x: target) } }
        else { position.scrollTo(x: target) }
    }
}

/// 时间轴上的一张柔色卡：图标、标题、左侧色条 + 时间、地点。道多时用矮版：图标 + 一行标题，下面时间。
private struct TimelineCard: View {
    let entry: TodayEntry
    let past: Bool
    var compact = false
    var body: some View {
        let hue = entry.hue
        Group {
            if compact {
                // 124pt 宽里：图标 + 一行标题，下面整行给时间（「14:10–14:40」放得下）。
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.glyph).font(.system(size: 9, weight: .bold)).foregroundStyle(hue.ink)
                            .frame(width: 18, height: 18).background(.white.opacity(0.6), in: .circle)
                        Text(entry.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(hue.ink).lineLimit(1).strikethrough(entry.done)
                    }
                    Text(entry.timeRange).font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(hue.ink.opacity(0.85)).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Image(systemName: entry.glyph).font(.system(size: 11, weight: .bold)).foregroundStyle(hue.ink)
                            .frame(width: 24, height: 24).background(.white.opacity(0.6), in: .circle)
                        Spacer(minLength: 0)
                        Circle().strokeBorder(hue.ink.opacity(0.5), lineWidth: 1.5).frame(width: 10, height: 10)
                            .overlay { if past || entry.done { Circle().fill(hue.ink.opacity(0.5)).frame(width: 5, height: 5) } }
                    }
                    Text(entry.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(hue.ink).lineLimit(2)
                        .multilineTextAlignment(.leading).strikethrough(entry.done)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Capsule().fill(hue.ink).frame(width: 2.5, height: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.timeRange).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(hue.ink).lineLimit(1)
                            let place = entry.kind == .event ? entry.value["location"].string : entry.kind == .reminder ? "提醒" : ""
                            if !place.isEmpty { Text(place).font(.system(size: 10)).foregroundStyle(hue.ink.opacity(0.75)).lineLimit(1) }
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(hue.fill, in: .rect(cornerRadius: compact ? 14 : 18, style: .continuous))
        .opacity(past ? 0.5 : 1)
    }
}

private struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 「现在」：一根竖线，顶上一颗青柠胶囊写着时刻。
private struct NowLine: View {
    let now: Double
    let height: CGFloat
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Palette.accentText).frame(width: 2, height: height - 14).padding(.top, 14)
            Text("现在 " + clockTime(now)).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Palette.accent, in: .capsule)
                .fixedSize()
        }
        .frame(width: 2, height: height, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-now")
    }
}

/// 点时间线上的一条进来：日程、提醒、待办各有自己的动作；等你决定的直接放那张决策卡。
struct TodayDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: TodayEntry
    @State private var busy = false
    private var v: JSON { entry.value }
    var body: some View {
        ScrollPage(spacing: Space.xl) {
            switch entry.kind {
            case .event: event
            case .reminder: reminder
            case .todo: ThreadStrip(key: "todo:" + v["path"].string); todo  // 10-18 线索
            case .decision:
                if let item = entry.pending, let current = model.pendingItems.first(where: { $0.id == item.id }) {
                    PendingNote(item: current) { _ in }
                } else {
                    EmptyState(title: "这件事已经处理了", description: "", symbol: "checkmark.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: ComDock.height) }
        .navigationTitle(["日程", "提醒", "待办", "等你决定"][[TodayEntry.Kind.event, .reminder, .todo, .decision].firstIndex(of: entry.kind) ?? 0])
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
    }

    @ViewBuilder private var event: some View {
        let allDay = v["all_day"].bool
        DetailHeader(title: entry.title, subtitle: allDay ? "全天" : clockTime(v["start"].double) + (v["end"].double > v["start"].double ? " – " + clockTime(v["end"].double) : "")) {
            Stamp(text: sourceName(v["source"].string))
        }
        GroupedCard {
            if !v["location"].string.isEmpty { KeyValueRow(label: "地点", value: v["location"].string) }
            if !v["calendar"].string.isEmpty { KeyValueRow(label: "日历", value: v["calendar"].string) }
            KeyValueRow(label: "日期", value: dayLabel(Date(timeIntervalSince1970: v["start"].double)))
        }
        if !v["notes"].string.isEmpty { Card { RichText(text: v["notes"].string) } }
        Button("交给 Com 准备") { hand("帮我准备今天的「\(entry.title)」（\(allDay ? "全天" : clockTime(v["start"].double))\(v["location"].string.isEmpty ? "" : "，" + v["location"].string)）：列出要带的材料、要确认的问题，有相关邮件就一起看。") }
            .buttonStyle(.primaryFull).disabled(busy)
        if let url = URL(string: v["link"].string), !v["link"].string.isEmpty { Link("在日历里打开", destination: url).font(TypeScale.subheadline.weight(.semibold)).frame(maxWidth: .infinity) }
    }

    @ViewBuilder private var reminder: some View {
        let pending = v["status"].string == "pending"
        DetailHeader(title: entry.title, subtitle: v["due"].string + (v["repeat"].string.isEmpty || v["repeat"].string == "once" ? "" : " · 重复")) {
            Stamp(text: v["overdue"].bool ? "过期没处理" : pending ? "待提醒" : "已完成", tone: v["overdue"].bool ? .warning : pending ? .neutral : .success)
        }
        if pending {
            VStack(spacing: Space.sm) {
                Button("完成了") { act("confirm") }.buttonStyle(.primaryFull).disabled(busy).accessibilityIdentifier("reminder-confirm")
                HStack(spacing: Space.sm) {
                    Button("晚 10 分钟") { act("snooze10") }.buttonStyle(.secondaryAction).disabled(busy)
                    Button("晚 1 小时") { act("snooze60") }.buttonStyle(.secondaryAction).disabled(busy)
                }
                Button("取消这条提醒", role: .destructive) { act("cancel") }.buttonStyle(.quiet).disabled(busy)
            }
        }
        Text("来自 Pi 网关的提醒记录，改动会直接写回那里。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
    }

    @ViewBuilder private var todo: some View {
        DetailHeader(title: entry.title, subtitle: [v["start"].string.isEmpty ? "" : "开始 " + v["start"].string, v["due"].string.isEmpty ? "" : "截止 " + v["due"].string].filter { !$0.isEmpty }.joined(separator: " · ")) {
            if v["overdue"].bool { Stamp(text: "已过期", tone: .warning) } else { Stamp(text: "今天") }
        }
        if !v["next_step"].string.isEmpty {
            Card { VStack(alignment: .leading, spacing: Space.sm) {
                Text("下一步").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                LinedText(text: v["next_step"].string)
            } }
        }
        GroupedCard {
            if !v["project"].string.isEmpty { KeyValueRow(label: "项目", value: v["project"].string) }
            if !v["note"].string.isEmpty { KeyValueRow(label: "备注", value: v["note"].string) }
            KeyValueRow(label: "来源", value: "Obsidian 行动台")
        }
        Button("交给 Com") { hand("帮我推进待办「\(entry.title)」" + (v["next_step"].string.isEmpty ? "。" : "，下一步是：" + v["next_step"].string + "。") + "先告诉我你打算怎么做。") }
            .buttonStyle(.primaryFull).disabled(busy)
        Text(v["path"].string).font(TypeScale.code).foregroundStyle(Palette.textTertiary)
    }

    private func act(_ action: String) {
        busy = true
        Task { await model.reminderAction(v, action); busy = false; dismiss() }
    }
    /// 作为一条消息交给主对话，执行仍走原有批准流。
    private func hand(_ text: String) {
        busy = true
        Task { await model.send(textOverride: text); busy = false; model.tab = .chat }
    }
}

/// 本机健康数据（从设置页打开）。
struct HealthCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack {
                    Text("Apple 健康").font(TypeScale.headline)
                    Spacer()
                    Button(model.devices.readingHealth ? "读取中…" : "读取") { Task { await model.devices.readHealth() } }.buttonStyle(.secondaryCompact).disabled(model.devices.readingHealth)
                }
                if !model.devices.healthNote.isEmpty {
                    Text(model.devices.healthNote).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                }
                if model.localHealth.isNull {
                    Text("授权健康权限后，可以读取最近 24 小时的活动、心率与睡眠。").font(TypeScale.body).foregroundStyle(Palette.textSecondary)
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
                    if !model.localHealth["missing_reason"].string.isEmpty { Text(model.localHealth["missing_reason"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary) }
                }
            }
        }
    }
    private func healthValue(_ title: String, key: String, unit: String) -> some View {
        MetricTile(title: title, value: model.localHealth[key].isNull ? "—" : model.localHealth[key].double.formatted(.number.precision(.fractionLength(key == "sleep_hours" ? 1 : 0))) + (unit.isEmpty ? "" : " " + unit))
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
                Stamp(text: sourceName(matter["source"].string))
            }
            if !matter["next_step"].string.isEmpty && matter["next_step"].string != "结合资料分析并提出下一步" {
                Card { VStack(alignment: .leading, spacing: Space.sm) {
                    Text("它准备的下一步").font(TypeScale.section).foregroundStyle(Palette.textSecondary)
                    LinedText(text: matter["next_step"].string)
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
                    } label: { Text("交给 Com") }.buttonStyle(.primaryFull)
                    ViewThatFits {
                        HStack(spacing: Space.sm) { feedback("关注", "follow"); feedback("稍后", "later"); feedback("已处理", "handled") }
                        VStack(alignment: .leading, spacing: Space.sm) { feedback("关注", "follow"); feedback("稍后", "later"); feedback("已处理", "handled") }
                    }
                }
            }
            DisclosureGroup("纠正或关闭提醒") {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextField("更正事实", text: $correction, axis: .vertical).lineLimit(2...4).insetField()
                    Button("保存更正") { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string("correct"), "text": .string(correction)], refresh: .chat); await model.refreshFlow() } }.buttonStyle(.secondaryAction).disabled(correction.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("不再提醒") { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string("mute")]); await model.refreshFlow(); dismiss() } }.buttonStyle(.quiet)
                }.padding(.top, Space.md)
            }.font(TypeScale.body)
            GroupedCard {
                if !matter["why"].string.isEmpty {
                    DisclosureGroup("背景说明") { RichText(text: matter["why"].string).padding(.top, Space.sm) }
                        .font(TypeScale.body).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                }
                RawDetails(title: "查看来源事实", value: matter["facts"]).rowPadding()
                if !matter["action_context"].isNull { RawDetails(title: "关联背景", value: matter["action_context"]).rowPadding() }
            }
            Button("解除事项关联", role: .destructive) { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/unlink"); await model.refreshFlow() } }
                .buttonStyle(.quiet).frame(maxWidth: .infinity)
        }
    }
    private func feedback(_ title: String, _ action: String) -> some View {
        Button(title) { Task { await model.action("/personal/matters/" + matter.id.pathEncoded + "/feedback", fields: ["action": .string(action)]); await model.refreshFlow(); if action != "follow" { dismiss() } } }.buttonStyle(.secondaryCompact)
    }
}

func sourceName(_ source: String) -> String {
    ["gmail": "Gmail", "work_mail": "工作邮箱", "github": "GitHub", "apple_calendar": "Apple 日历", "google_calendar": "Google 日历",
     "phone_calendar": "手机日历", "phone_health": "手机健康", "accounting": "账本", "garmin": "Garmin", "com_task": "Com 任务", "goal": "个人目标", "project_board": "工作",
     "phone_reminders": "提醒事项", "sms": "短信", "plaud": "录音纪要", "weather": "天气"][source] ?? source
}
func calendarTime(_ value: JSON) -> String {
    let raw = value["dateTime"].string.isEmpty ? value["date"].string.isEmpty ? value.string : value["date"].string : value["dateTime"].string
    return ISO8601DateFormatter().date(from: raw)?.formatted(.dateTime.month().day().hour().minute()) ?? raw
}
func money(_ minor: JSON, currency: String) -> String { minor.isNull ? "—" : (minor.double / 100).formatted(.currency(code: currency)) }

func sourceFailure(_ code: String) -> String {
    ["source_unavailable": "来源尚未连接", "upstream_timeout": "来源连接超时", "upstream_unavailable": "来源服务暂不可达", "invalid_response": "来源数据暂不可解析"][code] ?? (code.isEmpty ? "暂未读取到来源状态" : code)
}
