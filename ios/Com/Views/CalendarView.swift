import SwiftUI
import ComCore

// 日历页（复刻 Kyo Calendar 的动效）：两天并列的小时网格 + 右侧拇指轨（月圆章 / 竖向日期轨 / 选中胶囊 / 融球）。
// 单一连续状态 dayOffset（0 = 进入时的起始日）同时驱动画布横移、列标题和日期轨竖移，不用 ScrollView 分页。
// 数据：/personal/calendar?start=&days=（后端按区间取日程），靠近已加载边缘 3 天内再拉下一段。

private enum Cal {
    static let hourHeight: CGFloat = 64
    static let timeW: CGFloat = 44
    static let railW: CGFloat = 64
    static let unit: CGFloat = 52          // 日期轨单元高
    static let trackH: CGFloat = 5 * 52
    static let stampD: CGFloat = 52
    static let gap0: CGFloat = 11
    static let headerH: CGFloat = 56
    static let paging = Animation.spring(response: 0.44, dampingFraction: 0.88)
    static let cal = Calendar.current
    static let keyFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar.current; f.timeZone = Calendar.current.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static let weekChars = Array("日一二三四五六")
    static var fuse: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--ui-calendar-fuse")
        #else
        false
        #endif
    }
}

/// 一条日程：把后端 JSON 变成「今天」页同一套 TodayEntry，点进去就是同一个详情页。
private struct CalEvent: Identifiable {
    let id: String
    let title: String
    let start: Double
    let end: Double
    let allDay: Bool
    let informational: Bool
    let entry: TodayEntry
    init(_ e: JSON) {
        id = e.id; title = e["title"].string; start = e["start"].double; end = e["end"].double
        allDay = e["all_day"].bool; informational = e["informational"].bool
        let place = [e["location"].string, sourceName(e["source"].string)].filter { !$0.isEmpty }.joined(separator: " · ")
        entry = TodayEntry(id: "event:" + e.id, kind: .event, title: title,
                           subtitle: allDay ? place : [clockTime(start) + (end > start ? "–" + clockTime(end) : ""), e["location"].string].filter { !$0.isEmpty }.joined(separator: " · "),
                           start: allDay ? 0 : start, end: end, overdue: false, done: false, value: e)
    }
}

/// 把三个会变的数一起交给 SwiftUI 插值：弹簧动画期间每一帧都用插值后的 dayOffset / tension / lag 重算内容。
private struct Driven<Content: View>: View, @preconcurrency Animatable {
    var offset: CGFloat
    var tension: CGFloat = 0
    var lag: CGFloat = 0
    let content: (CGFloat, CGFloat, CGFloat) -> Content
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(offset, .init(tension, lag)) }
        set { offset = newValue.first; tension = newValue.second.first; lag = newValue.second.second }
    }
    var body: some View { content(offset, tension, lag) }
}

struct CalendarView: View {
    let startDay: Date
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce

    @State private var dayOffset: CGFloat
    @State private var tension: CGFloat
    @State private var lag: CGFloat = 0
    @State private var canvasBase: CGFloat?
    @State private var canvasLock: Bool?
    @State private var railBase: CGFloat?
    @State private var lastHaptic = 0
    @State private var events: [String: CalEvent] = [:]
    @State private var byDay: [String: [CalEvent]] = [:]
    @State private var loaded: Range<Int>?
    @State private var loading = false
    @State private var failNote = ""
    @State private var scrollSlot: Int = 0
    @State private var scrollTick = 0
    @State private var settledInitialScroll = false
    @GestureState private var canvasDragging = false
    @GestureState private var railDragging = false

    init(startDay: Date) {
        self.startDay = startDay
        _dayOffset = State(initialValue: Cal.fuse ? 0.5 : 0)
        _tension = State(initialValue: Cal.fuse ? 1 : 0)
    }

    // MARK: 日期换算
    private var anchor: Date { Cal.cal.startOfDay(for: startDay) }
    private func date(_ i: Int) -> Date { Cal.cal.date(byAdding: .day, value: i, to: anchor) ?? anchor }
    private func key(_ i: Int) -> String { Cal.keyFormatter.string(from: date(i)) }
    private func index(of d: Date) -> Int { Cal.cal.dateComponents([.day], from: anchor, to: Cal.cal.startOfDay(for: d)).day ?? 0 }
    private var nowSeconds: Double { Date().timeIntervalSince1970 + TodayClock.offset }
    private var todayIndex: Int { index(of: Date(timeIntervalSince1970: nowSeconds)) }
    private func span(_ off: CGFloat) -> ClosedRange<Int> { let f = Int(floor(off)); return (f - 1)...(f + 3) }

    var body: some View {
        GeometryReader { geo in
            let colW = max(60, (geo.size.width - Cal.timeW - Cal.railW) / 2)
            ZStack(alignment: .topLeading) {
                Palette.background.ignoresSafeArea().accessibilityElement().accessibilityIdentifier("calendar-view")
                VStack(alignment: .leading, spacing: 0) {
                    header(colW)
                    statusRow
                    grid(colW)
                }
                // 隐形标记：当前左列日期，给 UI 测试读（列标题在弹簧里每帧都在动）。
                Color.clear.frame(width: 1, height: 1).accessibilityElement().accessibilityIdentifier("calendar-leftday")
                    .accessibilityLabel(key(Int(dayOffset.rounded())))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                upNext.padding(.leading, Space.lg).padding(.trailing, Cal.railW + Space.sm + 4).padding(.bottom, Space.sm)
            }
            .overlay(alignment: .bottomTrailing) {
                rail.padding(.trailing, Space.sm).padding(.bottom, Space.sm)
            }
            .onChange(of: canvasDragging) { _, now in if !now, canvasBase != nil { finishCanvas(nil, colW) } }
            .onChange(of: railDragging) { _, now in if !now, railBase != nil { finishRail(nil) } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { DockSpacer() }
        .background(Palette.background)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await firstLoad() }
        .onChange(of: dayOffset) { _, v in Task { await ensureLoaded(Int(v.rounded())) } }
    }

    // MARK: 顶部列标题
    private func header(_ colW: CGFloat) -> some View {
        Driven(offset: dayOffset) { off, _, _ in
            ZStack(alignment: .topLeading) {
                ForEach(span(off), id: \.self) { i in
                    headerCell(i)
                        .frame(width: colW, alignment: .leading)
                        .offset(x: (CGFloat(i) - off) * colW)
                }
            }
            .frame(width: 2 * colW, height: Cal.headerH, alignment: .topLeading)
            .clipped()
        }
        .padding(.leading, Cal.timeW)
        .frame(height: Cal.headerH, alignment: .topLeading)
    }

    private func headerCell(_ i: Int) -> some View {
        let isToday = i == todayIndex
        let allDay = (byDay[key(i)] ?? []).filter { $0.allDay }
        return VStack(alignment: .leading, spacing: 4) {
            Text(dayLabel(date(i)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isToday ? Palette.accentText : Palette.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier("calendar-col-" + key(i))
            HStack(spacing: 4) {
                ForEach(allDay.prefix(2)) { e in
                    NavigationLink { TodayDetail(entry: e.entry) } label: {
                        Text(e.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(e.entry.hue.ink)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(e.entry.hue.fill, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("calendar-event-" + e.id)
                }
                if allDay.count > 2 { Text("+\(allDay.count - 2)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.textTertiary) }
            }
            .frame(height: 20, alignment: .leading)
        }
        .padding(.leading, 8).padding(.top, 6)
    }

    @ViewBuilder private var statusRow: some View {
        if !failNote.isEmpty {
            InlineNotice(text: failNote, tone: .danger).padding(.horizontal, Space.lg).padding(.bottom, Space.xs)
                .accessibilityIdentifier("calendar-notice")
        } else if loading && events.isEmpty {
            Text("正在读取日程…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, Space.lg).padding(.bottom, Space.xs)
        }
    }

    // MARK: 主画布：时刻列 + 两天网格
    private func grid(_ colW: CGFloat) -> some View {
        let total = 24 * Cal.hourHeight
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<48, id: \.self) { Color.clear.frame(height: Cal.hourHeight / 2).id("slot-\($0)") }
                    }
                    ForEach(0..<24, id: \.self) { h in
                        Text("\(h):00")
                            .font(.caption2.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                            .frame(width: Cal.timeW - 6, alignment: .trailing)
                            .offset(y: CGFloat(h) * Cal.hourHeight - (h == 0 ? 0 : 7))
                    }
                    Driven(offset: dayOffset) { off, _, _ in
                        ZStack(alignment: .topLeading) {
                            hourLines
                            ForEach(span(off), id: \.self) { i in
                                dayColumn(i, colW).offset(x: (CGFloat(i) - off) * colW)
                            }
                        }
                        .frame(width: 2 * colW, height: total, alignment: .topLeading)
                        .clipped()
                    }
                    .offset(x: Cal.timeW)
                }
                .frame(width: Cal.timeW + 2 * colW, height: total + 150, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .frame(width: Cal.timeW + 2 * colW)
            .simultaneousGesture(canvasDrag(colW))
            .onChange(of: scrollTick) { _, _ in withAnimation(Cal.paging) { proxy.scrollTo("slot-\(scrollSlot)", anchor: .top) } }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("slot-\(initialSlot())", anchor: .top) } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar-canvas")
        }
    }

    private var hourLines: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...24, id: \.self) { h in
                Rectangle().fill(Palette.separator).frame(height: 1).offset(y: CGFloat(h) * Cal.hourHeight)
                if h < 24 { Rectangle().fill(Palette.separator.opacity(0.45)).frame(height: 1).offset(y: (CGFloat(h) + 0.5) * Cal.hourHeight) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private struct Placed: Identifiable { let e: CalEvent; let y: CGFloat; let h: CGFloat; let col: Int; var cols: Int; var id: String { e.id } }

    /// 当天的事件块：按起点排，重叠的并排分栏。
    private func placed(_ i: Int) -> [Placed] {
        let day = date(i).timeIntervalSince1970
        let next = (Cal.cal.date(byAdding: .day, value: 1, to: date(i)) ?? date(i)).timeIntervalSince1970
        let rows = (byDay[key(i)] ?? []).filter { !$0.allDay }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var out: [Placed] = []
        var cluster: [Int] = []          // out 里属于当前簇的下标
        var colEnds: [CGFloat] = []      // 各栏当前底边
        var clusterEnd: CGFloat = -1
        func close() { for k in cluster { out[k].cols = max(1, colEnds.count) }; cluster = []; colEnds = [] }
        for e in rows {
            let s = max(e.start, day), t = min(max(e.end, e.start), next)
            let y = CGFloat((s - day) / 3600) * Cal.hourHeight
            let h = max(22, CGFloat((t - s) / 3600) * Cal.hourHeight)
            if y >= clusterEnd, !cluster.isEmpty { close() }
            var col = colEnds.firstIndex { $0 <= y } ?? colEnds.count
            if col == colEnds.count { colEnds.append(0) }
            colEnds[col] = y + h
            col = min(col, colEnds.count - 1)
            clusterEnd = cluster.isEmpty ? y + h : max(clusterEnd, y + h)
            out.append(Placed(e: e, y: y, h: h, col: col, cols: 1))
            cluster.append(out.count - 1)
        }
        close()
        return out
    }

    private func dayColumn(_ i: Int, _ colW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.separator).frame(width: 1, height: 24 * Cal.hourHeight)
            ForEach(placed(i)) { p in eventBlock(p, colW) }
            if i == todayIndex { nowLine(day: date(i), colW) }
        }
        .frame(width: colW, height: 24 * Cal.hourHeight, alignment: .topLeading)
    }

    private func eventBlock(_ p: Placed, _ colW: CGFloat) -> some View {
        let w = (colW - 5) / CGFloat(p.cols)
        let hue = p.e.entry.hue
        return NavigationLink { TodayDetail(entry: p.e.entry) } label: {
            HStack(spacing: 0) {
                Rectangle().fill(hue.ink).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.e.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textPrimary).lineLimit(2)
                    if p.e.end - p.e.start > 30 * 60 {
                        Text(p.e.entry.timeRange).font(.system(size: 11)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                Spacer(minLength: 0)
            }
            .frame(width: w - 2, height: p.h - 1, alignment: .topLeading)
            .background(hue.fill)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 10, topTrailingRadius: 10))
        }
        .buttonStyle(.plain)
        .offset(x: 2 + CGFloat(p.col) * w, y: p.y + 0.5)
        .accessibilityIdentifier("calendar-event-" + p.e.id)
    }

    private func nowLine(day: Date, _ colW: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let y = CGFloat((nowSeconds - day.timeIntervalSince1970) / 3600) * Cal.hourHeight
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.accent).frame(width: colW, height: 1.5)
                Circle().fill(Palette.accent).frame(width: 7, height: 7).offset(x: -3)
            }
            .offset(y: y - 0.75)
            .allowsHitTesting(false)
        }
    }

    /// 进页先滚到哪：max(现在 - 1 小时, 起始日第一件事前 30 分钟)，没有事件就是现在 - 1 小时。
    private func initialSlot() -> Int {
        let day = anchor.timeIntervalSince1970
        let nowH = (nowSeconds - day) / 3600
        var target = (Cal.cal.isDate(anchor, inSameDayAs: Date(timeIntervalSince1970: nowSeconds)) ? nowH : 8) - 1
        if let first = (byDay[key(0)] ?? []).filter({ !$0.allDay }).map(\.start).min() { target = max(target, (first - day) / 3600 - 0.5) }
        return min(40, max(0, Int(target * 2)))
    }

    // MARK: 手势：画布横拖
    private func canvasDrag(_ colW: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($canvasDragging) { _, state, _ in state = true }
            .onChanged { v in
                if canvasLock == nil {
                    canvasLock = abs(v.translation.width) > abs(v.translation.height)
                    if canvasLock == true { canvasBase = dayOffset; lastHaptic = Int(dayOffset.rounded()) }
                }
                guard canvasLock == true, let base = canvasBase else { return }
                dayOffset = base - v.translation.width / colW
                tick()
            }
            .onEnded { v in finishCanvas(v.predictedEndTranslation.width, colW) }
    }

    private func finishCanvas(_ predicted: CGFloat?, _ colW: CGFloat) {
        defer { canvasBase = nil; canvasLock = nil }
        guard canvasLock == true, let base = canvasBase else { return }
        let origin = base.rounded()
        let projected = predicted.map { base - $0 / colW } ?? dayOffset
        let target = origin + min(3, max(-3, projected.rounded() - origin))
        settle(to: target)
    }

    private func settle(to target: CGFloat) {
        withAnimation(reduce ? .easeOut(duration: 0.2) : Cal.paging) { dayOffset = target }
        Task { await ensureLoaded(Int(target)) }
    }

    private func tick() {
        let d = Int(dayOffset.rounded())
        if d != lastHaptic { Haptics.selection(); lastHaptic = d }
    }

    // MARK: 右轨
    private var rail: some View {
        Driven(offset: dayOffset, tension: tension, lag: lag) { off, t, lag in
            railBody(off, t, lag)
        }
        .frame(width: Cal.railW, height: Cal.stampD + Cal.gap0 + Cal.trackH)
        .accessibilityElement(children: .contain)
    }

    private func railBody(_ off: CGFloat, _ t: CGFloat, _ lag: CGFloat) -> some View {
        let gap = Cal.gap0 - 15 * t
        let trackY = Cal.stampD + gap
        let x: CGFloat = (Cal.railW - 52) / 2
        let fused = t > 0.01
        let fill = Palette.surface
        return ZStack(alignment: .topLeading) {
            // 底色层：分离时是两个独立的形状；拖动时用 blur + alphaThreshold 融成一块（融球）。
            if fused {
                Canvas { ctx, size in
                    ctx.addFilter(.alphaThreshold(min: 0.5, color: fill))
                    ctx.addFilter(.blur(radius: 8 * t))
                    ctx.drawLayer { l in
                        l.fill(Path(ellipseIn: CGRect(x: 12 + x, y: 12, width: Cal.stampD, height: Cal.stampD)), with: .color(.black))
                        l.fill(Path(roundedRect: CGRect(x: 12 + x, y: 12 + trackY, width: 52, height: Cal.trackH), cornerRadius: 26), with: .color(.black))
                    }
                }
                .frame(width: Cal.railW + 24, height: Cal.stampD + Cal.gap0 + Cal.trackH + 24)
                .offset(x: -12, y: -12)
                .shadow(color: .black.opacity(0.12 * t), radius: 4, y: 1)
                .allowsHitTesting(false)
            } else {
                Circle().fill(fill).frame(width: Cal.stampD, height: Cal.stampD).offset(x: x)
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(fill).frame(width: 52, height: Cal.trackH).offset(x: x, y: trackY)
            }
            // 细描边：融合时淡出，换成上面的柔和阴影。
            Circle().strokeBorder(Palette.separator, lineWidth: 1).frame(width: Cal.stampD, height: Cal.stampD).offset(x: x)
                .opacity(1 - min(1, t * 3))
            RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Palette.separator, lineWidth: 1)
                .frame(width: 52, height: Cal.trackH).offset(x: x, y: trackY).opacity(1 - min(1, t * 3))

            stampView(off).frame(width: Cal.stampD, height: Cal.stampD).offset(x: x)
            track(off, lag).frame(width: 52, height: Cal.trackH).offset(x: x, y: trackY)
        }
        .frame(width: Cal.railW, height: Cal.stampD + Cal.gap0 + Cal.trackH, alignment: .topLeading)
    }

    private func stampView(_ off: CGFloat) -> some View {
        let left = Int(off.rounded())
        let isToday = left == todayIndex
        return Button {
            Haptics.selection()
            settle(to: CGFloat(todayIndex))
        } label: {
            VStack(spacing: 0) {
                Text("\(Cal.cal.component(.month, from: date(left)))月").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.textTertiary)
                Text(isToday ? "今" : "\(Cal.cal.component(.day, from: date(left)))")
                    .font(.system(size: 20, weight: .medium, design: .rounded)).foregroundStyle(Palette.textPrimary)
            }
            .frame(width: Cal.stampD, height: Cal.stampD)
            .contentShape(Circle())
        }
        .buttonStyle(SoftPressStyle(scale: 0.94))
        .accessibilityLabel("回到今天").accessibilityIdentifier("calendar-month")
    }

    private func cells(_ off: CGFloat, weekday: Color, day: Color) -> some View {
        let f = Int(floor(off))
        return ZStack(alignment: .topLeading) {
            ForEach((f - 2)...(f + 5), id: \.self) { i in
                let d = date(i)
                VStack(spacing: 1) {
                    Text(String(Cal.weekChars[Cal.cal.component(.weekday, from: d) - 1])).font(.system(size: 9.5, weight: .bold)).foregroundStyle(weekday)
                    Text("\(Cal.cal.component(.day, from: d))").font(.system(size: 18, weight: .regular, design: .rounded).monospacedDigit()).foregroundStyle(day)
                }
                .frame(width: 52, height: Cal.unit)
                .offset(y: (CGFloat(i) - off + 1) * Cal.unit)
            }
        }
        .frame(width: 52, height: Cal.trackH, alignment: .topLeading)
    }

    /// 日期轨：底层常规色文字；顶层同一套文字用 onAccent 色，只在选中胶囊的形状里露出——数字跨过边界时一半深一半浅。
    private func track(_ off: CGFloat, _ lag: CGFloat) -> some View {
        let pillY = Cal.unit + 4 + lag
        return ZStack(alignment: .topLeading) {
            Capsule().fill(Palette.accent).frame(width: 40, height: 2 * Cal.unit - 8).offset(x: 6, y: pillY)
                .accessibilityElement().accessibilityIdentifier("calendar-pill")
            cells(off, weekday: Palette.textTertiary, day: Palette.textPrimary)
            cells(off, weekday: Palette.onAccent.opacity(0.7), day: Palette.onAccent)
                .mask(alignment: .topLeading) { Capsule().frame(width: 40, height: 2 * Cal.unit - 8).offset(x: 6, y: pillY) }
        }
        .frame(width: 52, height: Cal.trackH, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .gesture(railDrag)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-rail")
    }

    private var railDrag: some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($railDragging) { _, state, _ in state = true }
            .onChanged { v in
                if railBase == nil {
                    railBase = dayOffset; lastHaptic = Int(dayOffset.rounded())
                    if !reduce && !Cal.fuse { withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { tension = 1 } }
                }
                guard let base = railBase else { return }
                dayOffset = base - v.translation.height / Cal.unit
                tick()
                if !reduce { withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.8)) { lag = min(8, max(-8, v.velocity.height / 80)) } }
            }
            .onEnded { v in finishRail(v.predictedEndTranslation.height) }
    }

    private func finishRail(_ predicted: CGFloat?) {
        defer { railBase = nil }
        guard let base = railBase else { return }
        let origin = dayOffset.rounded()
        let projected = predicted.map { base - $0 / Cal.unit } ?? dayOffset
        let target = origin + min(3, max(-3, ((projected + dayOffset) / 2).rounded() - origin))
        settle(to: target)
        if !Cal.fuse {
            withAnimation(reduce ? nil : .spring(response: 0.32, dampingFraction: 0.78)) { tension = 0; lag = 0 }
        }
    }

    // MARK: 「下一件」
    private var upNext: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let now = nowSeconds
            if let e = events.values.filter({ !$0.allDay && !$0.informational && $0.start > now }).min(by: { $0.start < $1.start }) {
                Button { goTo(e) } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: "calendar").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.onAccent)
                            .frame(width: 40, height: 40).background(Palette.accent, in: .circle)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("下一件 · " + Self.until(e.start - now)).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                            Text(e.title).font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 6).padding(.trailing, Space.lg).padding(.vertical, 6)
                    .floatingGlass(.capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(SoftPressStyle(scale: 0.97))
                .accessibilityIdentifier("calendar-upnext")
            }
        }
    }

    private static func until(_ s: Double) -> String {
        let m = max(1, Int(s / 60))
        if m < 60 { return "还有 \(m) 分钟" }
        if m < 24 * 60 { return "还有 \(m / 60) 小时" + (m % 60 > 0 ? " \(m % 60) 分" : "") }
        return "还有 \(m / 1440) 天" + (m % 1440 >= 60 ? " \(m % 1440 / 60) 小时" : "")
    }

    private func goTo(_ e: CalEvent) {
        Haptics.selection()
        let d = Date(timeIntervalSince1970: e.start)
        settle(to: CGFloat(index(of: d)))
        let hour = (e.start - Cal.cal.startOfDay(for: d).timeIntervalSince1970) / 3600
        scrollSlot = min(40, max(0, Int(hour * 2) - 1)); scrollTick += 1
    }

    // MARK: 数据
    private func firstLoad() async {
        guard loaded == nil, !loading else { return }
        await fetch(lo: -7, count: 35)
        if !settledInitialScroll { settledInitialScroll = true; scrollSlot = initialSlot(); scrollTick += 1 }
    }

    private func ensureLoaded(_ idx: Int) async {
        guard let r = loaded, !loading else { return }
        if idx - 3 < r.lowerBound { await fetch(lo: r.lowerBound - 28, count: 28) }
        else if idx + 5 > r.upperBound { await fetch(lo: r.upperBound, count: 28) }
    }

    private func fetch(lo: Int, count: Int) async {
        loading = true
        defer { loading = false }
        let path = "/personal/calendar?start=\(key(lo))&days=\(count)"
        var json: JSON?
        #if DEBUG
        if model.isUITesting {
            if model.datasets["/personal/calendar"] == nil { model.seedCalendarPreview() }
            json = model.datasets["/personal/calendar"]
        } else { json = await model.load(path) }
        #else
        json = await model.load(path)
        #endif
        guard let json else {
            let err = model.errors[path] ?? ""
            failNote = err.isEmpty ? "日程没读到——不会假装已齐，滑回来或稍后再试" : "日程没读到：" + err
            return
        }
        failNote = ""
        for e in json["events"].array { events[e.id] = CalEvent(e) }
        rebuild()
        loaded = loaded.map { min($0.lowerBound, lo)..<max($0.upperBound, lo + count) } ?? lo..<(lo + count)
    }

    private func rebuild() {
        var out: [String: [CalEvent]] = [:]
        for e in events.values {
            let first = index(of: Date(timeIntervalSince1970: e.start))
            let last = e.allDay || e.end > e.start ? index(of: Date(timeIntervalSince1970: max(e.start, e.end - 1))) : first
            for i in first...max(first, min(last, first + 62)) { out[key(i), default: []].append(e) }
        }
        byDay = out
    }
}

#if DEBUG
extension AppModel {
    /// 日历页 UI 测试数据：今天前后 10 天，每天 1–3 个事件，含一个全天，按「今天」固定排。
    func seedCalendarPreview() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let nowH = (Date().timeIntervalSince1970 - today.timeIntervalSince1970) / 3600
        let titles: [(String, String, String)] = [
            ("晨跑 5 公里", "个人", "奥森南门"), ("周会", "工作", "3F 会议室"), ("排期评审", "工作", ""), ("攀岩", "个人", "岩时攀岩馆"),
            ("和 Alice 吃午饭", "个人", "三里屯"), ("整理样片", "工作", ""), ("给妈妈回电话", "个人", ""), ("选题讨论", "工作", "线上"),
        ]
        var rows: [JSON] = []
        for d in -10...10 {
            let day = (cal.date(byAdding: .day, value: d, to: today) ?? today).timeIntervalSince1970
            func row(_ id: String, _ title: String, _ s: Double, _ e: Double, _ calendar: String, _ place: String, allDay: Bool = false) -> JSON {
                .object(["id": .string(id), "title": .string(title), "start": .number(day + s * 3600), "end": .number(day + e * 3600), "all_day": .bool(allDay),
                         "location": .string(place), "notes": .string(""), "source": .string(calendar == "工作" ? "google_calendar" : "apple_calendar"),
                         "calendar": .string(calendar), "informational": .bool(false), "link": .string("")])
            }
            if d % 4 == 0 { rows.append(row("cal-\(d)-ad", d == 0 ? "Eddie 生日周" : "全天 · 出差", 0, 24, "个人", "", allDay: true)) }
            let n = 1 + abs(d) % 3
            for k in 0..<n {
                let t = titles[(abs(d) * 3 + k * 2) % titles.count]
                let s = [9.0, 10.5, 13.0][k] + Double(abs(d) % 2) * 0.5
                rows.append(row("cal-\(d)-\(k)", t.0, s, s + [1.0, 0.5, 2.0][k], t.1, t.2))
            }
            if d == 0 { rows.append(row("cal-0-next", "下午茶", min(nowH + 3.33, 23), min(nowH + 4.33, 23.9), "个人", "")) }
        }
        datasets["/personal/calendar"] = .object(["start": .string(""), "days": .number(21), "events": .array(rows)])
    }
}
#endif
