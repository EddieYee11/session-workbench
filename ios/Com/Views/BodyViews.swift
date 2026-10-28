import SwiftUI
import Charts
import ComCore

// 身体卡：Garmin 的身体电量、睡眠、HRV、准备度、静息心率、压力、步数，今天 + 7 天迷你趋势。
// 数据来自 /personal/today 的 health 段（后端 personal_hub.health，只读 hub 里已同步的数据）。
// 今天没有 Garmin 时退回手机健康快照（HealthKit），再没有就只给一个去设置里读健康数据的入口。

extension AppModel {
    var health: JSON { todayData["health"] }
}

/// 一项身体指标：取值、显示、7 天序列。
struct BodyMetric: Identifiable, Sendable {
    let id: String
    let title: String
    let unit: String
    let hue: TodayHue
    /// 越高越好（准备度、HRV、睡眠）还是越低越好（静息心率、压力）：决定和一周均值比时用哪种颜色。
    let higherIsBetter: Bool
    let value: @Sendable (JSON) -> Double?
    func text(_ v: Double) -> String { id == "sleep" ? String(format: "%.1f", v) : String(Int(v.rounded())) }
}

enum BodyMetrics {
    static let all: [BodyMetric] = [
        BodyMetric(id: "sleep", title: "睡眠", unit: "h", hue: .lavender, higherIsBetter: true) { m in m["sleep_seconds"].isNull ? nil : m["sleep_seconds"].double / 3600 },
        BodyMetric(id: "hrv", title: "HRV", unit: "ms", hue: .mint, higherIsBetter: true) { m in m["hrv_last_night"].isNull ? nil : m["hrv_last_night"].double },
        BodyMetric(id: "readiness", title: "准备度", unit: "", hue: .sky, higherIsBetter: true) { m in m["readiness_score"].isNull ? nil : m["readiness_score"].double },
        BodyMetric(id: "rhr", title: "静息心率", unit: "bpm", hue: .pink, higherIsBetter: false) { m in m["resting_heart_rate"].isNull ? nil : m["resting_heart_rate"].double },
        BodyMetric(id: "stress", title: "压力", unit: "", hue: .butter, higherIsBetter: false) { m in m["avg_stress"].isNull ? nil : m["avg_stress"].double },
        BodyMetric(id: "steps", title: "步数", unit: "", hue: .mint, higherIsBetter: true) { m in m["steps"].isNull ? nil : m["steps"].double },
    ]
    static func series(_ days: [JSON], _ metric: BodyMetric) -> [(String, Double)] {
        days.compactMap { d in metric.value(d["measurements"]).map { (d["date"].string, $0) } }
    }
}

/// 身体电量的等级文字（Garmin 的划分：76+ 高、51–75 中、26–50 低、≤25 很低）。
func batteryWord(_ v: Double) -> String { v >= 76 ? "精力充沛" : v >= 51 ? "还行" : v >= 26 ? "偏低" : "快没电了" }

struct BodyCard: View {
    @Environment(AppModel.self) private var model
    let shown: Bool
    /// 嵌在今天页横幅里展开时：底色和内边距交给横幅（10-17）。
    var embedded = false
    /// 六格指标：健康页自己有指标方格，那边不再重复画一遍。
    var showTiles = true
    var body: some View {
        let health = model.health
        let today = health["today"]["measurements"]
        if !health["today"].isNull {
            NavigationLink { HealthDetailView() } label: { garmin(today, days: health["days"].array) }
                .buttonStyle(CardPressStyle())
                .accessibilityIdentifier("today-body")
        } else if !health["phone"].isNull {
            phone(health["phone"])
        } else {
            NavigationLink { HealthSettingsPage() } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "heart.text.square").font(.system(size: 18, weight: .medium)).foregroundStyle(TodayHue.pink.ink)
                        .frame(width: 36, height: 36).background(TodayHue.pink.fill, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("身体状态还没同步").font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary)
                        Text(sourceNote(health)).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Chevron()
                }
                .padding(Space.lg)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-body-empty")
        }
    }

    private func sourceNote(_ health: JSON) -> String {
        let garmin = health["sources"]["garmin"]
        if !garmin["error"].string.isEmpty { return "Garmin：" + garmin["error"].string }
        return "Garmin 每半小时同步一次；也可以在这里读手机健康数据"
    }

    private func garmin(_ m: JSON, days: [JSON]) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .center, spacing: Space.lg) {
                BatteryRing(value: m["body_battery"].isNull ? nil : m["body_battery"].double, shown: shown)
                VStack(alignment: .leading, spacing: 4) {
                    Text("身体电量").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    if !m["body_battery"].isNull {
                        Text(batteryWord(m["body_battery"].double)).font(TypeScale.headline).foregroundStyle(Palette.textPrimary)
                    }
                    Text(batteryLine(m)).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            let curve = model.health["today"]["body_battery_curve"].array
            if curve.count > 2 { BatteryCurve(points: curve).frame(height: 54).modifier(DrawIn(on: shown, delay: 0.3, duration: 1.1)) }
            if !m["sleep_seconds"].isNull { SleepBar(m: m, shown: shown) }
            if showTiles {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 3), spacing: Space.sm) {
                    ForEach(Array(BodyMetrics.all.filter { $0.value(m) != nil }.enumerated()), id: \.element.id) { index, metric in
                        BodyTile(metric: metric, value: metric.value(m)!, series: BodyMetrics.series(days, metric), shown: shown)
                            .modifier(TileRise(on: shown, delay: 0.45 + Double(index) * 0.05))
                    }
                }
            }
        }
        .padding(embedded ? 0 : Space.lg)
        .background(embedded ? .clear : Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
        .contentShape(.rect)
    }

    private func batteryLine(_ m: JSON) -> String {
        var parts: [String] = []
        if !m["body_battery_at_wake"].isNull { parts.append("起床时 \(m["body_battery_at_wake"].int)") }
        if !m["body_battery_charged"].isNull { parts.append("充了 \(m["body_battery_charged"].int)") }
        if !m["body_battery_drained"].isNull { parts.append("用了 \(m["body_battery_drained"].int)") }
        return parts.joined(separator: " · ")
    }

    private func phone(_ p: JSON) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("手机健康 · 最近 7 天").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 3), spacing: Space.sm) {
                ForEach([("步数", "steps", ""), ("睡眠", "sleep_hours", "h"), ("静息心率", "resting_heart_rate", "bpm")], id: \.1) { title, key, unit in
                    MetricTile(title: title, value: p[key].isNull ? "—" : p[key].double.formatted(.number.precision(.fractionLength(key == "sleep_hours" ? 1 : 0))) + (unit.isEmpty ? "" : " " + unit))
                }
            }
            Text("今天还没有 Garmin 数据，先看手机健康。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
        }
        .padding(embedded ? 0 : Space.lg)
        .background(embedded ? .clear : Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityIdentifier("today-body-phone")
    }
}

/// 身体电量大圆环：数字从 0 数上来，环跟着长。
private struct BatteryRing: View {
    let value: Double?
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let v = value ?? 0
        ZStack {
            Circle().stroke(Palette.fill, lineWidth: 9)
            Circle().trim(from: 0, to: shown || reduce ? v / 100 : 0)
                .stroke(batteryColor(v), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduce ? nil : .easeOut(duration: 0.9).delay(0.15), value: shown)
            Group {
                if let value { RollingNumber(value: shown || reduce ? value : 0).animation(reduce ? nil : .easeOut(duration: 0.9).delay(0.15), value: shown) } else { Text("—") }
            }
            .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Palette.textPrimary)
        }
        .frame(width: 76, height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("身体电量 " + (value.map { String(Int($0)) } ?? "未知"))
    }
}

func batteryColor(_ v: Double) -> Color { v >= 51 ? TodayHue.mint.ink : v >= 26 ? TodayHue.butter.ink : Palette.danger }

/// 今天的身体电量曲线（15 分钟一点）。今天页身体卡和健康页共用。
struct BatteryCurve: View {
    let points: [JSON]
    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { _, p in
            AreaMark(x: .value("时间", Date(timeIntervalSince1970: p.array.first?.double ?? 0)), y: .value("电量", p.array.last?.double ?? 0))
                .foregroundStyle(LinearGradient(colors: [TodayHue.mint.ink.opacity(0.28), TodayHue.mint.ink.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("时间", Date(timeIntervalSince1970: p.array.first?.double ?? 0)), y: .value("电量", p.array.last?.double ?? 0))
                .foregroundStyle(TodayHue.mint.ink).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartYAxis(.hidden)
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
        .accessibilityLabel("今天的身体电量曲线")
    }
}

/// 睡眠：几点到几点、几分，下面一条深 / 浅 / REM / 清醒的比例条。
struct SleepBar: View {
    let m: JSON
    var shown = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let stages: [(String, Double, Color)] = [("深睡", m["deep_seconds"].double, TodayHue.lavender.ink), ("浅睡", m["light_seconds"].double, TodayHue.lavender.ink.opacity(0.55)),
                                                 ("REM", m["rem_seconds"].double, TodayHue.sky.ink), ("清醒", m["awake_seconds"].double, TodayHue.butter.ink)]
        let total = max(1, stages.reduce(0) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.sm) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 13)).foregroundStyle(TodayHue.lavender.ink)
                Text("睡了 " + duration(m["sleep_seconds"].double)).font(TypeScale.subheadline.weight(.semibold))
                if !m["sleep_score"].isNull { Text("\(m["sleep_score"].int) 分").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary) }
                Spacer(minLength: 0)
                Text(clock(m["sleep_start"].string) + "–" + clock(m["sleep_end"].string)).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    // 深 → 浅 → REM → 清醒依次从左边长出来（每段晚 80ms）。
                    ForEach(Array(stages.filter { $0.1 > 0 }.enumerated()), id: \.element.0) { index, stage in
                        RoundedRectangle(cornerRadius: 3).fill(stage.2)
                            .frame(width: max(2, (geo.size.width - 6) * stage.1 / total))
                            .scaleEffect(x: shown || reduce ? 1 : 0, anchor: .leading)
                            .animation(reduce ? nil : .spring(response: 0.55, dampingFraction: 0.85).delay(0.35 + Double(index) * 0.08), value: shown)
                    }
                }
            }
            .frame(height: 8)
            HStack(spacing: Space.md) {
                ForEach(stages.filter { $0.1 > 0 }, id: \.0) { name, seconds, color in
                    HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(name + " " + duration(seconds)) }
                }
            }
            .font(.caption2).foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
    private func clock(_ iso: String) -> String { iso.count >= 16 ? String(iso.dropFirst(11).prefix(5)) : "" }
}

func duration(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 > 0 ? "\(minutes % 60)m" : "")" : "\(minutes)m"
}

/// 一格指标：今天的数 + 7 天迷你线，和一周均值比好坏上色。
private struct BodyTile: View {
    let metric: BodyMetric
    let value: Double
    let series: [(String, Double)]
    var shown = true
    /// 今天以外那几天的均值。
    private var avg: Double? {
        let others = series.dropLast().map(\.1)
        return others.isEmpty ? nil : others.reduce(0, +) / Double(others.count)
    }
    private var spoken: String {
        let week: String = avg.map { "，一周均值 " + metric.text($0) } ?? ""
        return metric.title + " " + metric.text(value) + metric.unit + week
    }
    var body: some View {
        let avg = self.avg
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(metric.text(value)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                if !metric.unit.isEmpty { Text(metric.unit).font(.caption2).foregroundStyle(Palette.textTertiary) }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            if series.count > 1 { Sparkline(values: series.map(\.1), color: metric.hue.ink).frame(height: 18).modifier(DrawIn(on: shown, delay: 0.6, duration: 0.8)) }
        }
        .padding(Space.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(avg).opacity(0.5), in: .rect(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
    private func tint(_ avg: Double?) -> Color {
        guard let avg, avg > 0 else { return Palette.fill }
        let better = metric.higherIsBetter ? value >= avg * 0.95 : value <= avg * 1.05
        let worse = metric.higherIsBetter ? value < avg * 0.85 : value > avg * 1.15
        return worse ? TodayHue.pink.fill : better ? Palette.fill : TodayHue.butter.fill
    }
}

/// 数字从 0 数上来（和今天页四个数字同一种 CountUp）。
private struct RollingNumber: View, @MainActor Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text("\(Int(value.rounded()))").monospacedDigit() }
}

/// 从左往右画出来：曲线、迷你线用遮罩露出（Chart 没法 trim）。
struct DrawIn: ViewModifier {
    let on: Bool
    let delay: Double
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.mask(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().frame(width: on || reduce ? geo.size.width : 0)
                    .animation(reduce ? nil : .timingCurve(0.45, 0, 0.2, 1, duration: duration).delay(delay), value: on)
            }
        }
    }
}

/// 指标格错峰上浮：下方 10pt、4pt 模糊淡入。
private struct TileRise: ViewModifier {
    let on: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.opacity(on || reduce ? 1 : 0).blur(radius: on || reduce ? 0 : 4).offset(y: on || reduce ? 0 : 10)
            .animation(reduce ? nil : .spring(response: 0.45, dampingFraction: 0.85).delay(delay), value: on)
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { point in
            LineMark(x: .value("天", point.offset), y: .value("值", point.element))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1).animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// 7 天明细：每项一张图，下面逐日列表。
struct HealthDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var data: JSON = .null
    /// 柱子从 0 长到实际值（Swift Charts 在动画事务里改数据就会补间）。
    @State private var grown = false
    var body: some View {
        let source = data.isNull ? model.health : data
        let days = source["days"].array
        DetailPage(title: "身体状态") {
            if let today = days.last, !today["measurements"]["sleep_seconds"].isNull {
                Card { SleepBar(m: today["measurements"]) }
            }
            ForEach(BodyMetrics.all + [battery]) { metric in
                let series = BodyMetrics.series(days, metric)
                if !series.isEmpty {
                    GroupSection(metric.title + (metric.unit.isEmpty ? "" : "（\(metric.unit)）")) {
                        Card {
                            Chart(series, id: \.0) { day, v in
                                BarMark(x: .value("日期", String(day.suffix(5))), y: .value(metric.title, grown ? v : 0))
                                    .foregroundStyle(day == series.last?.0 ? metric.hue.ink : metric.hue.ink.opacity(0.35))
                                    .cornerRadius(4)
                                    .annotation(position: .top) { Text(metric.text(v)).font(.caption2).foregroundStyle(Palette.textSecondary) }
                            }
                            .chartYAxis(.hidden)
                            .frame(height: 120)
                        }
                    }
                }
            }
            let sources = source["sources"]
            Text("来源：Garmin Connect" + (sources["garmin"]["updated_at"].double > 0 ? " · 同步于 " + relativeTime(sources["garmin"]["updated_at"].double) : "") + "。手表数据在醒来、同步后才补齐。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.xs)
        }
        .task {
            if reduce { grown = true } else { withAnimation(.spring(response: 0.7, dampingFraction: 0.82).delay(0.15)) { grown = true } }
            if let fresh = await model.load("/personal/health?days=7") { data = fresh }
        }
        .accessibilityIdentifier("health-detail")
    }
    private var battery: BodyMetric {
        BodyMetric(id: "battery", title: "起床时身体电量", unit: "", hue: .mint, higherIsBetter: true) { m in m["body_battery_at_wake"].isNull ? nil : m["body_battery_at_wake"].double }
    }
}

/// 没有 Garmin 也没有手机快照时：把原来埋在设置里的 HealthKit 读取卡搬到这里。
private struct HealthSettingsPage: View {
    var body: some View {
        DetailPage(title: "身体状态") {
            GroupSection("本机健康数据", footer: "读取留在本机；同步到 mini 在设置里单独开启。Garmin 在「数据连接」里接。") { HealthCard() }
        }
    }
}
