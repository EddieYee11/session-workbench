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
    /// 标题下面那行灰字：「4 个日程」；节假日这类只是信息的日历不算日程。
    var todaySummary: String {
        if todayData.isNull && !isUITesting { return errors["/personal/today"] == nil ? "正在看今天的安排…" : "今天的安排暂时没读到" }
        let events = todayEntries.filter { $0.kind == .event && !$0.value["informational"].bool }.count
        return events > 0 ? "\(events) 个日程" : "今天没有日程"
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

    /// 「下一步」整理时写的 3–5 条要点（10-17）：身体 / 日程 / 事 / 资讯。今天页取日程建议，健康页取身体。
    var todayBrief: [JSON] { nextData["brief"].array.filter { !$0["text"].string.isEmpty } }
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

// MARK: - 今天（11-02 重做）
// 参考 Schedule 页：周条（今天高亮）+ 左侧时刻 / 右侧色条卡的竖向时间线。
// 只放今天的日程和日程建议；身体内容在「健康」页，简报、资讯、待办、下一件表盘不再放这里。

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        // 每分钟走一格：「现在」标记和已过去的卡片淡化跟着时间动。
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date.timeIntervalSince1970 + TodayClock.offset
            let rows = model.todayEntries.filter { $0.kind == .event || ($0.kind == .reminder && $0.start > 0) }
                .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
            ScreenScaffold(title: "今天") {
                TodayHeader(summary: model.todaySummary)
                    .modifier(EnterRise(on: shown, delay: 0))
                WeekStrip(now: now)
                    .modifier(EnterRise(on: shown, delay: 0.06))
                ScheduleTimeline(rows: rows, now: now)
                    .modifier(EnterRise(on: shown, delay: 0.12))
                ScheduleAdvice()
                    .modifier(EnterRise(on: shown, delay: 0.18))
                HotBoardCard()
                    .modifier(EnterRise(on: shown, delay: 0.24))
                let errors = model.todayData["errors"].object.filter { ["events", "reminders"].contains($0.key) }
                if !errors.isEmpty {
                    InlineNotice(text: "有来源没读到：" + errors.keys.sorted().map { ["events": "日程", "reminders": "提醒"][$0] ?? $0 }.joined(separator: "、"), tone: .neutral)
                }
            }
        }
        .refreshable { await model.refresh(.doing); _ = await model.load("/personal/next"); await model.refreshHot() }
        // 每次切回「今天」都重新走一遍进场；切走时复位。
        .onAppear { shown = true }
        .onDisappear { shown = false }
    }
}

/// 20-build-checklist 的「模糊上浮」：y+26→0、blur 10→0，各块错峰。
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

// MARK: 标题 + 周条

private struct TodayHeader: View {
    @Environment(AppModel.self) private var model
    let summary: String
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date().formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.textPrimary)
                Text(summary).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("today-summary")
            }
            Spacer(minLength: Space.sm)
            // 任务与目标：不常用，缩成一颗小按钮；有等你拍板的才挂个数。
            NavigationLink { TaskHubView() } label: {
                Image(systemName: "square.stack").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                    .frame(width: 40, height: 40).background(Palette.surface, in: .circle)
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
    }
}

/// 本周七天（周一起），今天高亮。只是看一眼今天落在这周哪天，后端只给今天的数据，所以其它天不能点。
private struct WeekStrip: View {
    let now: Double
    private static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }
    private var today: Date { Date(timeIntervalSince1970: now) }
    private var days: [Date] {
        let cal = Self.calendar
        let start = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? cal.startOfDay(for: today)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
    var body: some View {
        let cal = Self.calendar
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let on = cal.isDate(day, inSameDayAs: today)
                VStack(spacing: Space.sm) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))))
                        .font(TypeScale.caption).foregroundStyle(on ? Palette.textPrimary : Palette.textTertiary)
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(on ? TodayHue.mint.ink : Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(on ? TodayHue.mint.fill : .clear, in: .rect(cornerRadius: 12, style: .continuous))
                }
                .padding(.vertical, Space.sm)
                .frame(maxWidth: .infinity)
                .background { if on { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Palette.surface) } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((on ? "今天 " : "") + day.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityIdentifier("today-week")
    }
}

// MARK: 日程时间线

/// 左边时刻、右边色条卡；「现在」插在最近一件未开始的日程前面。全天的排最前，时刻位置写「全天」。
private struct ScheduleTimeline: View {
    let rows: [TodayEntry]
    let now: Double
    private static let timeWidth: CGFloat = 44
    var body: some View {
        if rows.isEmpty {
            Text("今天没有日程").font(TypeScale.subheadline).foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                .accessibilityIdentifier("today-empty")
        } else {
            let nowIndex = rows.firstIndex { $0.start > now } ?? (rows.contains { $0.start > 0 } ? rows.count : nil)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                    if index == nowIndex { nowMarker }
                    HStack(alignment: .top, spacing: Space.md) {
                        Text(entry.start > 0 ? clockTime(entry.start) : "全天")
                            .font(TypeScale.footnote.weight(.medium).monospacedDigit()).foregroundStyle(Palette.textSecondary)
                            .frame(width: Self.timeWidth, alignment: .trailing).padding(.top, Space.lg)
                        NavigationLink { TodayDetail(entry: entry) } label: { ScheduleCard(entry: entry, past: entry.isPast(now)) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("today-" + entry.id)
                    }
                    .padding(.bottom, Space.md)
                }
                if nowIndex == rows.count { nowMarker }
            }
            .background(alignment: .leading) {
                Rectangle().fill(Palette.separator).frame(width: 1).padding(.leading, Self.timeWidth + Space.md / 2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today-timeline")
        }
    }
    private var nowMarker: some View {
        HStack(spacing: Space.md) {
            Text("现在 " + clockTime(now)).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Palette.accent, in: .capsule)
                .fixedSize()
            Rectangle().fill(Palette.accentText.opacity(0.5)).frame(height: 1)
        }
        .padding(.bottom, Space.md)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-now")
    }
}

private struct ScheduleCard: View {
    let entry: TodayEntry
    let past: Bool
    var body: some View {
        let hue = entry.hue
        let category: String = entry.kind == .reminder ? "提醒"
            : [entry.value["calendar"].string, entry.value["location"].string].filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: entry.glyph).font(.system(size: 16, weight: .semibold)).foregroundStyle(hue.ink)
                .frame(width: 40, height: 40).background(hue.fill, in: .rect(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary).lineLimit(2)
                    .multilineTextAlignment(.leading).strikethrough(entry.done)
                if !category.isEmpty { Text(category).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1) }
                if entry.start > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 11))
                        Text(entry.timeRange).monospacedDigit()
                    }
                    .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md).padding(.leading, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .overlay(alignment: .leading) { Rectangle().fill(hue.ink).frame(width: 4) }
        .clipShape(.rect(cornerRadius: Radius.lg, style: .continuous))
        .elevation(.raised)
        .opacity(past ? 0.55 : 1)
        .contentShape(.rect)
    }
}

// MARK: 日程建议

/// 「下一步」整理时顺手写的、关于日程松紧和安排的几条建议（简报里 kind = event 的要点）；没有就给个按钮现在整理。
private struct ScheduleAdvice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let running = model.nextData["running"].bool
        let tips = model.todayBrief.filter { $0["kind"].string == "event" }
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("日程建议").font(TypeScale.section).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { Task { await model.refreshNext() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                        .symbolEffect(.rotate.byLayer, options: .repeating, isActive: running && !reduce)
                        .frame(width: 30, height: 30).background(Palette.fill, in: .circle)
                }
                .buttonStyle(.plain).disabled(running)
                .accessibilityLabel("重新整理日程建议").accessibilityIdentifier("today-advice-refresh")
            }
            if tips.isEmpty {
                Text(running ? "正在看今天的安排…" : "还没有日程建议，点右上角让 Com 看一眼今天。")
                    .font(TypeScale.subheadline).foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
            } else {
                ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                    HStack(alignment: .top, spacing: Space.md) {
                        Image(systemName: "lightbulb.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(TodayHue.butter.ink)
                            .frame(width: 36, height: 36).background(TodayHue.butter.fill, in: .rect(cornerRadius: 12, style: .continuous))
                        Text(tip["text"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(Space.md)
                    .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                    .elevation(.raised)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("today-advice-\(index)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-advice")
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
        .safeAreaInset(edge: .bottom, spacing: 0) { DockSpacer() }
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


/// 10-25 当日流程表：焦点项目活动前一天 / 当天自动出一张可勾选的流程表（航程产出里的 HTML）；没出就给个「现在排一张」。
private struct RunSheetEntry: View {
    @Environment(AppModel.self) private var model
    let project: JSON
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        let sheet = project["runsheet"]
        let days = project["days_left"].isNull ? -1 : project["days_left"].int
        VStack(alignment: .leading, spacing: 6) {
            if !sheet.isNull {
                ArtifactList(artifacts: [.object(["id": .string("runsheet-" + sheet["name"].string), "name": sheet["name"], "path": sheet["path"],
                                                  "availability": .string("available"), "mime": .string("text/html")])])
            } else if (0...1).contains(days) {
                Button {
                    busy = true; error = ""
                    Task {
                        do { _ = try await model.mutate("/personal/runsheet", fields: ["project": project["title"]]); _ = await model.load("/personal/next") }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                } label: {
                    Label(busy ? "正在排…" : "排一张当日流程表", systemImage: "list.bullet.clipboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryCompact).disabled(busy)
            }
            if !error.isEmpty { Text(error).font(TypeScale.footnote).foregroundStyle(Palette.warning) }
        }
    }
}
