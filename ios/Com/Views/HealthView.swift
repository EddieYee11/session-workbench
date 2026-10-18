import SwiftUI
import Charts
import ComCore

// 健康页（10-17）：身体数据的综合评估、今天的行动建议，下面按「电量 → 睡眠 → HRV → 心率与压力 → 负荷与活动」看趋势。
// 版式参考 GitHub 上的 garmin-health-dashboard（Recovery / HRV / Sleep / Body Battery 分区）和 garmin-grafana 的 HRV 基线带；
// 数据：/personal/health?days=30（hub 里 Garmin 每天一条，python-garminconnect 拉的）、/personal/health/insight（模型写的评估，恢复分是 Garmin 准备度）。

extension AppModel {
    var healthRange: JSON { datasets["/personal/health?days=30"] ?? health }
    var healthInsight: JSON { datasets["/personal/health/insight"] ?? .null }
    func refreshHealthInsight() async {
        #if DEBUG
        if isUITesting { return }
        #endif
        _ = try? await mutate("/personal/health/insight/refresh")
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(3))
            if let data = await load("/personal/health/insight"), !data["running"].bool { return }
        }
    }
}

/// 趋势的时间窗：7 / 14 / 30 天。
private enum HealthSpan: Int, CaseIterable, Identifiable {
    case week = 7, fortnight = 14, month = 30
    var id: Int { rawValue }
    var title: String { "\(rawValue) 天" }
}

struct HealthView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    @Namespace private var zoom
    var body: some View {
        let source = model.healthRange
        let all = source["days"].array
        let today = source["today"].isNull ? all.last ?? .null : source["today"]
        let m = today["measurements"]
        // 10-17 二版：一级界面只放图形和能点的东西——恢复环 + 四个维度小环、建议卡堆、六格指标、最近活动；
        // 解释文字、趋势图都收进点开以后（参考 Originkit 的 Swipe Stack / Flip Gallery / Interactive Grid）。
        ScreenScaffold(title: "健康") {
            if m.isNull || m.object.isEmpty {
                InlineNotice(text: "还没有今天的 Garmin 数据：手表同步后这里会出评估。", tone: .neutral)
            }
            HealthHero(insight: model.healthInsight, m: m, shown: shown)
                .modifier(HealthRise(on: shown, delay: 0.04))
            ActionStack(actions: model.healthInsight["actions"].array)
                .modifier(HealthRise(on: shown, delay: 0.12))
            MetricGrid(today: today, days: all, shown: shown, zoom: zoom)
                .modifier(HealthRise(on: shown, delay: 0.2))
            ActivityStrip(days: all)
                .modifier(HealthRise(on: shown, delay: 0.28))
        }
        .refreshable { await model.refresh(.health); await model.refreshHealthInsight() }
        .onAppear { shown = true }
        .onDisappear { shown = false }
        .accessibilityIdentifier("health-page")
    }
}

// MARK: 评估

/// 顶部：恢复分大环 + 一句话；四个维度是一排小环（颜色 = 好 / 一般 / 偏低），点哪个在下面冒一个气泡说一句；
/// 教练的整段解释收在「为什么」后面，点开才展开。
private struct HealthHero: View {
    let insight: JSON
    let m: JSON
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var picked: String?
    @State private var why = false
    var body: some View {
        let score: Double? = insight["score"].isNull ? (m["readiness_score"].isNull ? nil : m["readiness_score"].double) : insight["score"].double
        let running = insight["running"].bool
        let dims = insight["dimensions"].array
        let motion: Animation = reduce ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8)
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .center, spacing: Space.lg) {
                ScoreRing(value: score, shown: shown)
                VStack(alignment: .leading, spacing: 6) {
                    Text(insight["headline"].string.isEmpty ? (running ? "正在看你的身体…" : "还没有评估") : insight["headline"].string)
                        .font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(insight["headline"].string)
                        .transition(reduce ? .opacity : .blurLift)
                        .accessibilityIdentifier("health-headline")
                    if !insight["summary"].string.isEmpty {
                        Button { Haptics.selection(); withAnimation(motion) { why.toggle() } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "text.bubble.fill").font(.system(size: 11))
                                Text(why ? "收起" : "为什么")
                            }
                            .font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.accentText)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Palette.accent.opacity(0.22), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("health-why")
                    }
                }
                Spacer(minLength: 0)
            }
            if why {
                Text(insight["summary"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.fill.opacity(0.7), in: .rect(cornerRadius: Radius.md, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    .accessibilityIdentifier("health-summary")
            }
            if !dims.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(dims.enumerated()), id: \.offset) { index, dim in
                        DimensionGauge(dim: dim, selected: picked == dim["key"].string, shown: shown, delay: 0.3 + Double(index) * 0.06) {
                            Haptics.selection()
                            withAnimation(motion) { picked = picked == dim["key"].string ? nil : dim["key"].string }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                if let picked, let dim = dims.first(where: { $0["key"].string == picked }) {
                    let hue = dimHue(dim["level"].string)
                    HStack(spacing: Space.sm) {
                        Image(systemName: dimStyle(picked).1).font(.system(size: 12, weight: .bold)).foregroundStyle(hue.ink)
                        Text(dim["note"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                    .background(hue.fill.opacity(0.7), in: .rect(cornerRadius: Radius.md, style: .continuous))
                    .id(picked)
                    .transition(reduce ? .opacity : .blurLift)
                    .accessibilityIdentifier("health-dim-note")
                }
            }
        }
        .padding(Space.lg)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.xl, style: .continuous))
        .elevation(.raised)
        .animation(reduce ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: insight["headline"].string)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health-hero")
    }
}

private func dimStyle(_ key: String) -> (String, String) {
    switch key { case "sleep": ("睡眠", "moon.zzz.fill"); case "recovery": ("恢复", "waveform.path.ecg"); case "load": ("负荷", "figure.climbing"); default: ("压力", "brain.head.profile") }
}
private func dimHue(_ level: String) -> TodayHue { level == "good" ? .mint : level == "low" ? .pink : .butter }

/// 一个维度的小环：好 = 满环青绿、一般 = 2/3 黄、偏低 = 1/3 粉；选中时环变粗、图标弹一下（03-badge-stamp 的落位）。
private struct DimensionGauge: View {
    let dim: JSON
    let selected: Bool
    let shown: Bool
    let delay: Double
    let tap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let (name, symbol) = dimStyle(dim["key"].string)
        let level = dim["level"].string
        let hue = dimHue(level)
        let fill = level == "good" ? 1.0 : level == "low" ? 0.34 : 0.67
        Button(action: tap) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().stroke(Palette.fill, lineWidth: selected ? 6 : 4.5)
                    Circle().trim(from: 0, to: shown || reduce ? fill : 0)
                        .stroke(hue.ink, style: StrokeStyle(lineWidth: selected ? 6 : 4.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduce ? nil : .easeOut(duration: 0.8).delay(delay), value: shown)
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(hue.ink)
                        .scaleEffect(selected ? 1.15 : 1)
                }
                .frame(width: 50, height: 50)
                .background(selected ? hue.fill : .clear, in: .circle)
                Text(name).font(.caption.weight(selected ? .bold : .medium)).foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name + (level == "good" ? "好" : level == "low" ? "偏低" : "一般") + "，" + dim["note"].string)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("health-dim-" + dim["key"].string)
    }
}

/// 恢复分环：环从 0 长到分数（0.9s ease-out），数字跟着数上来；颜色分三档。
private struct ScoreRing: View {
    let value: Double?
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let v = value ?? 0
        let color = v >= 70 ? TodayHue.mint.ink : v >= 45 ? TodayHue.butter.ink : Palette.danger
        ZStack {
            Circle().stroke(Palette.fill, lineWidth: 10)
            Circle().trim(from: 0, to: shown || reduce ? v / 100 : 0)
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * v / 100)),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduce ? nil : .easeOut(duration: 0.9).delay(0.15), value: shown)
            VStack(spacing: 0) {
                Group {
                    if let value { HealthCount(value: shown || reduce ? value : 0).animation(reduce ? nil : .easeOut(duration: 0.9).delay(0.15), value: shown) } else { Text("—") }
                }
                .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.textPrimary)
                Text(v >= 70 ? "恢复充足" : v >= 45 ? "恢复一般" : value == nil ? "恢复" : "恢复优先").font(.caption2.weight(.semibold)).foregroundStyle(color)
            }
        }
        .frame(width: 96, height: 96)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("恢复分 " + (value.map { String(Int($0)) } ?? "未知"))
        .accessibilityIdentifier("health-score")
    }
}

private struct HealthCount: View, @MainActor Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text("\(Int(value.rounded()))").monospacedDigit() }
}

// MARK: 行动建议：卡堆

/// 今天的建议叠成一摞（Originkit「Swipe Stack」+「Flip Gallery」的手势，换成原生弹簧）：
/// - 最上面那张：大图标 + 标题 + 时段；点一下绕竖轴翻面看为什么（rotation3D，0.5s 弹簧）；
/// - 往右甩 = 做完（卡片带着转角飞出、底下打勾计数 +1），往左甩 = 稍后（塞回最底下）；拖不够远就弹回；
/// - 下面几张错开缩小露个边，跟着顶上那张的拖动距离往上补位。做完记在本机（今天有效）。
private struct ActionStack: View {
    let actions: [JSON]
    @AppStorage("health.done") private var doneRaw = ""
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var order: [String] = []
    @State private var drag: CGSize = .zero
    @State private var flipped = false
    private var today: String { Date().formatted(.iso8601.year().month().day()) }
    private var done: Set<String> { Set(doneRaw.split(separator: "\n").map(String.init).filter { $0.hasPrefix(today) }) }
    private func key(_ a: JSON) -> String { today + ":" + a["title"].string }
    var body: some View {
        let pending = arranged.filter { !done.contains(key($0)) }
        let finished = actions.count - pending.count
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("今天这样做").font(TypeScale.section).accessibilityAddTraits(.isHeader)
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                            Circle().fill(done.contains(key(a)) ? TodayHue.mint.ink : Palette.separator).frame(width: 7, height: 7)
                        }
                    }
                    .accessibilityLabel("完成 \(finished) / \(actions.count)")
                    .accessibilityIdentifier("health-actions-progress")
                }
                .padding(.horizontal, Space.xs)
                ZStack {
                    if pending.isEmpty {
                        VStack(spacing: Space.sm) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(TodayHue.mint.ink)
                                .symbolEffect(.bounce, value: finished)
                            Text("今天的都做完了").font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary)
                            Button("重来") { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { doneRaw = "" } }
                                .font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.accentText)
                        }
                        .frame(maxWidth: .infinity).frame(height: 168)
                        .background(Palette.surface, in: .rect(cornerRadius: Radius.xl, style: .continuous))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    ForEach(Array(pending.prefix(3).enumerated()).reversed(), id: \.element["title"].string) { depth, action in
                        card(action, depth: depth, top: depth == 0)
                    }
                }
                .frame(height: 184, alignment: .top)
                Text("点卡片看原因 · 右滑做完 · 左滑稍后").font(.caption2).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity)
            }
            .onAppear { if order.isEmpty { order = actions.map { $0["title"].string } } }
            .onChange(of: actions.map { $0["title"].string }) { _, titles in order = titles }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("health-actions")
        }
    }
    private var arranged: [JSON] {
        let byTitle = Dictionary(actions.map { ($0["title"].string, $0) }, uniquingKeysWith: { a, _ in a })
        let known = order.compactMap { byTitle[$0] }
        return known.count == actions.count ? known : actions
    }
    private func style(_ kind: String) -> (String, TodayHue, String) {
        switch kind {
        case "sleep": ("bed.double.fill", .lavender, "睡眠"); case "train": ("figure.climbing", .mint, "训练"); case "stress": ("wind", .sky, "减压")
        case "eat": ("fork.knife", .butter, "饮食"); default: ("figure.walk", .pink, "活动")
        }
    }
    @ViewBuilder private func card(_ a: JSON, depth: Int, top: Bool) -> some View {
        let (symbol, hue, kind) = style(a["kind"].string)
        let progress = min(1, abs(drag.width) / 140)
        let lift = top ? 0 : Double(depth) - progress  // 顶上那张拖开时，后面的往前补
        ZStack {
            // 正面
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(hue.ink)
                        .frame(width: 48, height: 48).background(Palette.surface.opacity(0.85), in: .circle)
                    Spacer()
                    if !a["when"].string.isEmpty {
                        Label(a["when"].string, systemImage: "clock").font(.caption.weight(.semibold)).foregroundStyle(hue.ink)
                            .padding(.horizontal, 9).padding(.vertical, 5).background(Palette.surface.opacity(0.85), in: .capsule)
                    }
                }
                Spacer(minLength: 0)
                Text(kind).font(.caption.weight(.bold)).foregroundStyle(hue.ink)
                Text(a["title"].string).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Palette.textPrimary).lineLimit(2)
            }
            .opacity(flipped && top ? 0 : 1)
            // 背面：为什么
            VStack(alignment: .leading, spacing: Space.sm) {
                Label("为什么", systemImage: "lightbulb.fill").font(.caption.weight(.bold)).foregroundStyle(hue.ink)
                Text(a["detail"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            .opacity(flipped && top ? 1 : 0)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 168)
        .background(hue.fill, in: .rect(cornerRadius: Radius.xl, style: .continuous))
        .overlay {
            if top && drag.width != 0 {
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                    .strokeBorder(drag.width > 0 ? TodayHue.mint.ink : Palette.textTertiary, lineWidth: 2)
                    .overlay(alignment: drag.width > 0 ? .topLeading : .topTrailing) {
                        Text(drag.width > 0 ? "做完" : "稍后").font(.caption.weight(.heavy)).foregroundStyle(drag.width > 0 ? TodayHue.mint.ink : Palette.textSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Palette.surface, in: .capsule).padding(Space.md)
                            .rotationEffect(.degrees(drag.width > 0 ? -8 : 8))
                    }
                    .opacity(progress)
            }
        }
        .rotation3DEffect(.degrees(flipped && top ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .scaleEffect(1 - 0.05 * lift)
        .offset(y: 10 * lift)
        .offset(top ? drag : .zero)
        .rotationEffect(.degrees(top ? Double(drag.width) / 18 : 0), anchor: .bottom)
        .elevation(top ? .raised : .flat)
        .zIndex(Double(10 - depth))
        .allowsHitTesting(top)
        .onTapGesture {
            Haptics.selection()
            withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.78)) { flipped.toggle() }
        }
        .gesture(top ? swipe(a) : nil)
        .transition(.asymmetric(insertion: .opacity, removal: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "做完") { finish(a) }
        .accessibilityAction(named: "稍后") { later(a) }
        .accessibilityIdentifier(top ? "health-action-top" : "health-action-\(depth)")
    }
    private func swipe(_ a: JSON) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag = CGSize(width: $0.translation.width, height: $0.translation.height * 0.25) }
            .onEnded { value in
                let w = value.translation.width + value.predictedEndTranslation.width * 0.2
                if w > 120 { fling(1) { finish(a) } } else if w < -120 { fling(-1) { later(a) } }
                else { withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) { drag = .zero } }
            }
    }
    /// 甩出去：先顺着方向飞出屏幕（0.25s），再把它从堆里拿走，拖动归零给下一张。
    private func fling(_ direction: CGFloat, then: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.22)) { drag = CGSize(width: direction * 520, height: drag.height + 30) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { drag = .zero; flipped = false }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { then() }
        }
    }
    private func finish(_ a: JSON) {
        Haptics.success()
        var set = done; set.insert(key(a)); doneRaw = set.sorted().joined(separator: "\n")
    }
    private func later(_ a: JSON) {
        Haptics.selection()
        var titles = arranged.map { $0["title"].string }
        titles.removeAll { $0 == a["title"].string }; titles.append(a["title"].string)
        order = titles
    }
}

// MARK: 指标方格

/// 六格：电量、睡眠、HRV、静息心率、压力、负荷。每格只有图标、一个大数、一条 14 天迷你线，和自己均值比好坏上色；
/// 点开用 zoom 转场推进到那一项的趋势页（iOS 18 navigationTransition，格子放大成页面）。
private struct MetricGrid: View {
    let today: JSON
    let days: [JSON]
    let shown: Bool
    let zoom: Namespace.ID
    struct Item: Identifiable { let id: String; let title: String; let symbol: String; let hue: TodayHue; let key: String; let unit: String; let higher: Bool; let scale: Double }
    static let items: [Item] = [
        Item(id: "battery", title: "身体电量", symbol: "bolt.heart.fill", hue: .mint, key: "body_battery_at_wake", unit: "", higher: true, scale: 1),
        Item(id: "sleep", title: "睡眠", symbol: "moon.zzz.fill", hue: .lavender, key: "sleep_seconds", unit: "h", higher: true, scale: 1.0 / 3600),
        Item(id: "hrv", title: "HRV", symbol: "waveform.path.ecg", hue: .sky, key: "hrv_last_night", unit: "ms", higher: true, scale: 1),
        Item(id: "rhr", title: "静息心率", symbol: "heart.fill", hue: .pink, key: "resting_heart_rate", unit: "bpm", higher: false, scale: 1),
        Item(id: "stress", title: "压力", symbol: "brain.head.profile", hue: .butter, key: "avg_stress", unit: "", higher: false, scale: 1),
        Item(id: "load", title: "训练负荷", symbol: "figure.climbing", hue: .butter, key: "load_acute", unit: "", higher: true, scale: 1),
    ]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.md), GridItem(.flexible(), spacing: Space.md)], spacing: Space.md) {
            ForEach(Array(Self.items.enumerated()), id: \.element.id) { index, item in
                NavigationLink {
                    HealthMetricPage(item: item)
                        .navigationTransition(.zoom(sourceID: item.id, in: zoom))
                } label: {
                    tile(item, index: index)
                }
                .buttonStyle(TilePress())
                .matchedTransitionSource(id: item.id, in: zoom) { $0.clipShape(.rect(cornerRadius: Radius.xl, style: .continuous)) }
                .accessibilityIdentifier("health-tile-" + item.id)
            }
        }
    }
    private func tile(_ item: Item, index: Int) -> some View {
        let series = days.suffix(14).compactMap { d in d["measurements"][item.key].isNull ? nil : d["measurements"][item.key].double * item.scale }
        // 电量格显示「现在」，其余显示今天的值。
        let m = today["measurements"]
        let now: Double? = item.id == "battery" && !m["body_battery"].isNull ? m["body_battery"].double : series.last
        let mean = series.count > 1 ? series.dropLast().reduce(0, +) / Double(series.count - 1) : nil
        let trend: Double = (now != nil && mean != nil && mean! > 0) ? (now! - mean!) / mean! : 0
        let good = item.higher ? trend >= -0.05 : trend <= 0.05
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Image(systemName: item.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(item.hue.ink)
                    .frame(width: 32, height: 32).background(item.hue.fill, in: .circle)
                Spacer()
                if mean != nil && abs(trend) >= 0.03 {
                    Image(systemName: trend > 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(good ? TodayHue.mint.ink : Palette.danger)
                        .frame(width: 22, height: 22).background((good ? TodayHue.mint.fill : TodayHue.pink.fill), in: .circle)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(now.map { item.id == "sleep" ? $0.formatted(.number.precision(.fractionLength(1))) : "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText())
                if !item.unit.isEmpty { Text(item.unit).font(.caption).foregroundStyle(Palette.textTertiary) }
            }
            Text(item.title).font(.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
            if series.count > 1 {
                MiniTrend(values: series, color: item.hue.ink).frame(height: 26)
                    .modifier(DrawIn(on: shown, delay: 0.35 + Double(index) * 0.05, duration: 0.8))
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.xl, style: .continuous))
        .elevation(.raised)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title + " " + (now.map { String(Int($0)) } ?? "无数据") + item.unit)
        .accessibilityAddTraits(.isButton)
    }
}

private struct MiniTrend: View {
    let values: [Double]
    let color: Color
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("天", point.offset), y: .value("值", point.element))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.monotone)
            LineMark(x: .value("天", point.offset), y: .value("值", point.element)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8)).interpolationMethod(.monotone)
            if point.offset == values.count - 1 { PointMark(x: .value("天", point.offset), y: .value("值", point.element)).foregroundStyle(color).symbolSize(28) }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

/// 按下时格子微缩、松手弹回（和 Dock 的按压同一组弹簧）。
private struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 最近两周的活动：一排圆形徽章（运动图标 + 分钟），横着滑；点开看那次的心率、热量。
private struct ActivityStrip: View {
    let days: [JSON]
    @State private var picked: Int?
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let acts = Array(days.suffix(14).reversed().flatMap { d in d["activities"].array.map { (String(d["date"].string.suffix(5)), $0) } }.prefix(8))
        if !acts.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("最近活动").font(TypeScale.section).accessibilityAddTraits(.isHeader).padding(.horizontal, Space.xs)
                ScrollView(.horizontal) {
                    HStack(spacing: Space.md) {
                        ForEach(Array(acts.enumerated()), id: \.offset) { index, item in
                            let (date, a) = item
                            Button {
                                Haptics.selection()
                                withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.78)) { picked = picked == index ? nil : index }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: activitySymbol(a["type"].string)).font(.system(size: 20, weight: .semibold)).foregroundStyle(TodayHue.butter.ink)
                                        .frame(width: 54, height: 54)
                                        .background(TodayHue.butter.fill, in: .circle)
                                        .overlay(Circle().strokeBorder(picked == index ? TodayHue.butter.ink : .clear, lineWidth: 2))
                                    Text("\(a["minutes"].int)′").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Palette.textPrimary)
                                    Text(date).font(.caption2).foregroundStyle(Palette.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(a["name"].string + " \(a["minutes"].int) 分钟，" + date)
                            .accessibilityIdentifier("health-activity-\(index)")
                        }
                    }
                    .padding(.horizontal, Space.xs).padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                if let picked, picked < acts.count {
                    let a = acts[picked].1
                    HStack(spacing: Space.lg) {
                        Text(a["name"].string).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary)
                        Spacer()
                        if !a["avg_hr"].isNull { Label("\(a["avg_hr"].int)", systemImage: "heart.fill").foregroundStyle(TodayHue.pink.ink) }
                        if !a["calories"].isNull { Label("\(a["calories"].int)", systemImage: "flame.fill").foregroundStyle(TodayHue.butter.ink) }
                    }
                    .font(TypeScale.footnote.weight(.semibold).monospacedDigit())
                    .padding(Space.md)
                    .background(Palette.surface, in: .rect(cornerRadius: Radius.md, style: .continuous))
                    .id(picked)
                    .transition(reduce ? .opacity : .blurLift)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("health-activities")
        }
    }
}

func activitySymbol(_ type: String) -> String {
    type.contains("climb") || type.contains("boulder") ? "figure.climbing" : type.contains("run") ? "figure.run" : type.contains("cycl") ? "figure.outdoor.cycle"
        : type.contains("walk") || type.contains("hik") ? "figure.hiking" : type.contains("swim") ? "figure.pool.swim" : "figure.mixed.cardio"
}

// MARK: 二级：单项趋势

/// 点开一格后的整页：7 / 14 / 30 天切换 + 那一项的完整面板（原来铺在一级的图表都在这里）。
private struct HealthMetricPage: View {
    let item: MetricGrid.Item
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("health.span") private var spanRaw = HealthSpan.fortnight.rawValue
    @State private var shown = false
    @Namespace private var spanSpace
    var body: some View {
        let source = model.healthRange
        let all = source["days"].array
        let span = HealthSpan(rawValue: spanRaw) ?? .fortnight
        let days = Array(all.suffix(span.rawValue))
        let today = source["today"].isNull ? all.last ?? .null : source["today"]
        let m = today["measurements"]
        ScrollPage {
            HStack(spacing: 4) {
                ForEach(HealthSpan.allCases) { s in
                    Button {
                        Haptics.selection()
                        withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.82)) { spanRaw = s.rawValue }
                    } label: {
                        Text(s.title).font(TypeScale.footnote.weight(.semibold))
                            .foregroundStyle(span == s ? Palette.onAccent : Palette.textSecondary)
                            .padding(.horizontal, Space.md).padding(.vertical, 6)
                            .background { if span == s { Capsule().fill(Palette.accent).matchedGeometryEffect(id: "span", in: spanSpace) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("health-span-\(s.rawValue)")
                }
            }
            .padding(3).background(Palette.fill, in: .capsule)
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch item.id {
                case "battery": BatteryPanel(today: today, days: days, shown: shown)
                case "sleep": SleepPanel(m: m, days: days, shown: shown)
                case "hrv": HRVPanel(m: m, days: days, shown: shown)
                case "load": LoadPanel(m: m, days: all, shown: shown)
                default: HeartStressPanel(days: days, shown: shown)
                }
            }
            .animation(reduce ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: spanRaw)
            Text("来源：Garmin Connect（python-garminconnect）。和你自己的近期均值比，不是医疗诊断。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.xs)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: ComDock.height) }
        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .onAppear { shown = true }
        .accessibilityIdentifier("health-metric-" + item.id)
    }
}

// MARK: 趋势面板

private struct Panel<Content: View>: View {
    let title: String
    let symbol: String
    let hue: TodayHue
    var trailing = ""
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(hue.ink)
                    .frame(width: 26, height: 26).background(hue.fill, in: .circle)
                Text(title).font(TypeScale.headline).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                if !trailing.isEmpty { Text(trailing).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) }
            }
            content
        }
        .padding(Space.lg)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.xl, style: .continuous))
        .elevation(.raised)
    }
}

private func day(_ d: JSON) -> String { String(d["date"].string.suffix(5)) }
private func avg(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
private func values(_ days: [JSON], _ key: String) -> [(String, Double)] {
    days.compactMap { d in d["measurements"][key].isNull ? nil : (day(d), d["measurements"][key].double) }
}

/// 一个大数 + 单位 + 小字说明。
private struct Stat: View {
    let title: String
    let value: String
    var unit = ""
    var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Palette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(Palette.textTertiary) }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(Palette.textTertiary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct BatteryPanel: View {
    let today: JSON
    let days: [JSON]
    let shown: Bool
    var body: some View {
        let m = today["measurements"]
        let wake = values(days, "body_battery_at_wake")
        Panel(title: "身体电量", symbol: "bolt.heart.fill", hue: .mint, trailing: m["body_battery"].isNull ? "" : "现在 \(m["body_battery"].int)") {
            HStack {
                Stat(title: "起床时", value: m["body_battery_at_wake"].isNull ? "—" : "\(m["body_battery_at_wake"].int)",
                     note: avg(wake.dropLast().map(\.1)).map { "均值 \(Int($0))" } ?? "")
                Stat(title: "充了", value: m["body_battery_charged"].isNull ? "—" : "+\(m["body_battery_charged"].int)")
                Stat(title: "用了", value: m["body_battery_drained"].isNull ? "—" : "−\(m["body_battery_drained"].int)")
            }
            let curve = today["body_battery_curve"].array
            if curve.count > 2 {
                BatteryCurve(points: curve).frame(height: 90).modifier(DrawIn(on: shown, delay: 0.3, duration: 1.1))
            }
            if wake.count > 1 {
                Text("每天起床时").font(.caption).foregroundStyle(Palette.textTertiary)
                Chart(wake, id: \.0) { d, v in
                    BarMark(x: .value("日期", d), y: .value("电量", shown ? v : 0), width: .ratio(0.6))
                        .foregroundStyle(d == wake.last?.0 ? TodayHue.mint.ink : TodayHue.mint.ink.opacity(0.35)).cornerRadius(3)
                }
                .chartYScale(domain: 0...100).chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel() } }
                .frame(height: 70)
                .animation(.spring(response: 0.7, dampingFraction: 0.82), value: shown)
            }
        }
        .accessibilityIdentifier("health-battery")
    }
}

private struct SleepPanel: View {
    let m: JSON
    let days: [JSON]
    let shown: Bool
    var body: some View {
        let hours = values(days, "sleep_seconds").map { ($0.0, $0.1 / 3600) }
        let need = (m["sleep_need_minutes"].isNull ? 480 : m["sleep_need_minutes"].double) / 60
        Panel(title: "睡眠", symbol: "moon.zzz.fill", hue: .lavender, trailing: m["sleep_score"].isNull ? "" : "\(m["sleep_score"].int) 分") {
            if !m["sleep_seconds"].isNull { SleepBar(m: m, shown: shown) }
            if hours.count > 1 {
                Chart {
                    ForEach(hours, id: \.0) { d, v in
                        BarMark(x: .value("日期", d), y: .value("小时", shown ? v : 0), width: .ratio(0.6))
                            .foregroundStyle(v < need - 1 ? TodayHue.pink.ink.opacity(0.75) : TodayHue.lavender.ink.opacity(d == hours.last?.0 ? 1 : 0.45)).cornerRadius(3)
                    }
                    RuleMark(y: .value("需要", need))
                        .foregroundStyle(Palette.textTertiary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) { Text("需要 " + need.formatted(.number.precision(.fractionLength(1))) + "h").font(.caption2).foregroundStyle(Palette.textTertiary) }
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel() } }
                .frame(height: 110)
                .animation(.spring(response: 0.7, dampingFraction: 0.82), value: shown)
            }
            HStack {
                Stat(title: "均值", value: avg(hours.map(\.1)).map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", unit: "h")
                Stat(title: "睡眠压力", value: m["sleep_stress"].isNull ? "—" : "\(m["sleep_stress"].int)")
                Stat(title: "呼吸", value: m["respiration_sleep"].isNull ? "—" : "\(m["respiration_sleep"].int)", unit: "次/分")
                Stat(title: "血氧", value: m["spo2_avg"].isNull ? (m["spo2_7d"].isNull ? "—" : "\(m["spo2_7d"].int)") : "\(m["spo2_avg"].int)", unit: "%",
                     note: m["spo2_avg"].isNull && !m["spo2_7d"].isNull ? "7 天均值" : "")
            }
        }
        .accessibilityIdentifier("health-sleep")
    }
}

/// HRV：每晚均值的折线 + Garmin 给的「平衡」基线带（garmin-grafana 的画法），落在带下面的点标粉。
private struct HRVPanel: View {
    let m: JSON
    let days: [JSON]
    let shown: Bool
    var body: some View {
        let series = values(days, "hrv_last_night")
        let band = m["hrv_baseline"].array.map(\.double)
        let low = band.first ?? 0, high = band.count > 1 ? band[1] : 0
        let status = ["BALANCED": "平衡", "UNBALANCED": "失衡", "LOW": "偏低", "POOR": "很低"][m["hrv_status"].string] ?? ""
        Panel(title: "HRV", symbol: "waveform.path.ecg", hue: .sky, trailing: status) {
            HStack {
                Stat(title: "昨晚", value: m["hrv_last_night"].isNull ? "—" : "\(m["hrv_last_night"].int)", unit: "ms")
                Stat(title: "7 天均值", value: m["hrv_weekly"].isNull ? "—" : "\(m["hrv_weekly"].int)", unit: "ms")
                Stat(title: "基线", value: high > 0 ? "\(Int(low))–\(Int(high))" : "—", unit: "ms")
            }
            if series.count > 1 {
                Chart {
                    if high > 0 {
                        RectangleMark(xStart: .value("起", series.first!.0), xEnd: .value("止", series.last!.0), yStart: .value("低", low), yEnd: .value("高", high))
                            .foregroundStyle(TodayHue.mint.fill.opacity(0.8))
                    }
                    ForEach(series, id: \.0) { d, v in
                        LineMark(x: .value("日期", d), y: .value("HRV", v)).foregroundStyle(TodayHue.sky.ink).interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("日期", d), y: .value("HRV", v))
                            .foregroundStyle(high > 0 && v < low ? TodayHue.pink.ink : TodayHue.sky.ink).symbolSize(d == series.last?.0 ? 60 : 18)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                // 横轴按日期顺序钉死：基线带先用了首尾两天，不钉的话 Charts 按出现顺序排，日期会乱。
                .chartXScale(domain: series.map(\.0))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel() } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
                .frame(height: 130)
                .modifier(DrawIn(on: shown, delay: 0.3, duration: 0.9))
            }
        }
        .accessibilityIdentifier("health-hrv")
    }
}

private struct HeartStressPanel: View {
    let days: [JSON]
    let shown: Bool
    var body: some View {
        let rhr = values(days, "resting_heart_rate"), stress = values(days, "avg_stress")
        Panel(title: "心率与压力", symbol: "heart.fill", hue: .pink) {
            HStack(alignment: .top, spacing: Space.md) {
                mini("静息心率", rhr, unit: "bpm", color: TodayHue.pink.ink, line: true)
                mini("平均压力", stress, unit: "", color: TodayHue.butter.ink, line: false)
            }
        }
        .accessibilityIdentifier("health-heart")
    }
    private func mini(_ title: String, _ series: [(String, Double)], unit: String, color: Color, line: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Stat(title: title, value: series.last.map { "\(Int($0.1))" } ?? "—", unit: unit, note: avg(series.dropLast().map(\.1)).map { "均值 \(Int($0))" } ?? "")
            if series.count > 1 {
                Chart(series, id: \.0) { d, v in
                    if line {
                        LineMark(x: .value("日期", d), y: .value(title, v)).foregroundStyle(color).interpolationMethod(.monotone)
                        AreaMark(x: .value("日期", d), y: .value(title, v))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.monotone)
                    } else {
                        BarMark(x: .value("日期", d), y: .value(title, shown ? v : 0), width: .ratio(0.6)).foregroundStyle(color.opacity(d == series.last?.0 ? 1 : 0.4)).cornerRadius(2)
                    }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: !line))
                .frame(height: 56)
                .animation(.spring(response: 0.7, dampingFraction: 0.82), value: shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 训练负荷（急性 / 慢性 / 比值）、训练状态、体能年龄，和最近两周的活动。
private struct LoadPanel: View {
    let m: JSON
    let days: [JSON]
    let shown: Bool
    var body: some View {
        let acts = days.reversed().flatMap { d in d["activities"].array.map { (day(d), $0) } }.prefix(5)
        Panel(title: "负荷与活动", symbol: "figure.climbing", hue: .butter, trailing: statusWord(m["training_status"].string)) {
            HStack {
                Stat(title: "急性负荷", value: m["load_acute"].isNull ? "—" : "\(m["load_acute"].int)")
                Stat(title: "慢性负荷", value: m["load_chronic"].isNull ? "—" : "\(m["load_chronic"].int)")
                Stat(title: "体能年龄", value: m["fitness_age"].isNull ? "—" : m["fitness_age"].double.formatted(.number.precision(.fractionLength(0))),
                     unit: "岁", note: m["age"].isNull ? "" : "实际 \(m["age"].int)")
            }
            if !m["load_ratio"].isNull {
                LoadRatioBar(ratio: m["load_ratio"].double, shown: shown)
            }
            if acts.isEmpty {
                Text("最近两周没有记录活动").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            } else {
                VStack(spacing: Space.sm) {
                    ForEach(Array(acts.enumerated()), id: \.offset) { _, item in
                        let (date, a) = item
                        HStack(spacing: Space.md) {
                            Image(systemName: a["type"].string.contains("climb") || a["type"].string.contains("boulder") ? "figure.climbing" : a["type"].string.contains("run") ? "figure.run" : a["type"].string.contains("cycl") ? "figure.outdoor.cycle" : "figure.mixed.cardio")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(TodayHue.butter.ink)
                                .frame(width: 30, height: 30).background(TodayHue.butter.fill, in: .circle)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a["name"].string).font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                                Text([date + " " + a["start"].string, "\(a["minutes"].int) 分钟", a["avg_hr"].isNull ? "" : "均心率 \(a["avg_hr"].int)"].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Palette.textTertiary)
                            }
                            Spacer(minLength: 0)
                            if !a["calories"].isNull { Text("\(a["calories"].int) kcal").font(.caption.monospacedDigit()).foregroundStyle(Palette.textSecondary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .accessibilityIdentifier("health-load")
    }
    private func statusWord(_ raw: String) -> String {
        let map = ["PRODUCTIVE": "有效训练", "MAINTAINING": "保持", "RECOVERY": "恢复中", "UNPRODUCTIVE": "低效", "DETRAINING": "退训", "PEAKING": "巅峰",
                   "OVERREACHING": "负荷过量", "STRAINED": "紧绷", "NO_STATUS": "暂无状态"]
        return map.first { raw.hasPrefix($0.key) }?.value ?? ""
    }
}

/// 急慢性负荷比：0.8–1.5 是合适区间（Garmin 的划法），指针从 0 滑到当前位置。
private struct LoadRatioBar: View {
    let ratio: Double
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let x = min(1, ratio / 2)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("急慢性负荷比").font(.caption).foregroundStyle(Palette.textSecondary)
                Spacer()
                Text(ratio.formatted(.number.precision(.fractionLength(1))) + (ratio < 0.8 ? " · 偏低" : ratio > 1.5 ? " · 偏高" : " · 合适"))
                    .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.fill)
                    Capsule().fill(TodayHue.mint.fill).frame(width: geo.size.width * 0.35).offset(x: geo.size.width * 0.4)
                    Circle().fill(TodayHue.butter.ink).frame(width: 12, height: 12)
                        .offset(x: (geo.size.width - 12) * (shown || reduce ? x : 0))
                        .animation(reduce ? nil : .spring(response: 0.8, dampingFraction: 0.75).delay(0.3), value: shown)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 面板错峰上浮：下方 12pt、模糊淡入（和今天页 EnterRise 同语法）。
private struct HealthRise: ViewModifier {
    let on: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.opacity(on || reduce ? 1 : 0).blur(radius: on || reduce ? 0 : 5).offset(y: on || reduce ? 0 : 12)
            .animation(reduce ? nil : .spring(response: 0.5, dampingFraction: 0.86).delay(delay), value: on)
    }
}
