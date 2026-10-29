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
        // 先亮 running，顶栏立刻 hourglass，别等 mutate 回包前连点叠刷。
        var kick = healthInsight
        kick["running"] = .bool(true)
        datasets["/personal/health/insight"] = kick
        do {
            _ = try await mutate("/personal/health/insight/refresh")
            for _ in 0..<20 {
                try await Task.sleep(for: .seconds(3))
                if let data = await load("/personal/health/insight"), !data["running"].bool {
                    healthOpenNote = ""
                    return
                }
            }
            // 轮询结束再核：load 失败别假亮 running / 假装评估已写好。
            if let data = await load("/personal/health/insight") {
                if !data["running"].bool { healthOpenNote = "" }
                else {
                    healthOpenNote = "评估还在整理或超时未齐——可下拉再试。不会假装已写好。"
                }
            } else {
                var stuck = healthInsight
                stuck["running"] = .bool(false)
                datasets["/personal/health/insight"] = stuck
                let err = errors["/personal/health/insight"] ?? ""
                healthOpenNote = err.isEmpty
                    ? "评估整理过程中没刷上——可下拉再试。不会假装已写好。"
                    : "评估整理过程中没刷上：" + err + "——可下拉再试。不会假装已写好。"
            }
        } catch {
            var fail = healthInsight
            fail["running"] = .bool(false)
            datasets["/personal/health/insight"] = fail
            banner = error.localizedDescription
            healthOpenNote = "重新评估没成：" + error.localizedDescription + "——可下拉再试。不会假装已写好。"
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
    /// 截图验收用：COM_PREVIEW_HEALTH_BENTO=1 时只留指标拼图（UI 测试里建议卡堆会吃掉滑动，拼图下半截拍不到）。
    #if DEBUG
    static let bentoOnly = ProcessInfo.processInfo.environment["COM_PREVIEW_HEALTH_BENTO"] == "1"
    #else
    static let bentoOnly = false
    #endif
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    @State private var loading = false
    @State private var failNote = ""
    @State private var briefFail = ""
    @State private var loadedOnce = false
    @Namespace private var zoom
    private let rangePath = "/personal/health?days=30"
    private let insightPath = "/personal/health/insight"
    var body: some View {
        let source = model.healthRange
        let all = source["days"].array
        let today = source["today"].isNull ? all.last ?? .null : source["today"]
        let m = today["measurements"]
        let mEmpty = m.isNull || m.object.isEmpty
        let briefPoints = model.todayBrief.filter { $0["kind"].string == "health" }
        // 10-17 二版：一级界面只放图形和能点的东西——恢复环 + 四个维度小环、建议卡堆、指标拼图（10-28 起大小不一，含最近活动）；
        // 解释文字、趋势图都收进点开以后（参考 Originkit 的 Swipe Stack / Flip Gallery / Interactive Grid）。
        ScreenScaffold(title: "健康") {
            if loading && !loadedOnce {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在拉齐健康曲线和评估…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                .accessibilityIdentifier("health-pulling")
            }
            if !model.healthOpenNote.isEmpty {
                InlineNotice(text: model.healthOpenNote, tone: .danger)
                    .accessibilityIdentifier("health-open-fail")
                Button(loading ? "重试中…" : "再试一次") {
                    guard !loading else { return }
                    Task {
                        await pullHealth(force: true)
                        await model.refreshHealthInsight()
                    }
                }
                .buttonStyle(.secondaryCompact)
                .disabled(loading)
                .accessibilityIdentifier("health-open-retry")
            } else if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                Button(loading ? "重试中…" : "再试一次") {
                    guard !loading else { return }
                    Task { await pullHealth(force: true) }
                }
                .buttonStyle(.secondaryCompact)
                .disabled(loading)
                .accessibilityIdentifier("health-retry")
            } else if loadedOnce && mEmpty {
                // 真没数才说手表；别把拉齐失败说成 Garmin 没到。
                InlineNotice(text: "今天的 Garmin 还没到。你先忙别的——手表同步后我再开口评估。", tone: .neutral)
            } else if !mEmpty && model.healthInsight["headline"].string.isEmpty && !model.healthInsight["running"].bool {
                InlineNotice(text: companionHealthLine(m: m), tone: .neutral)
            }
            if !Self.bentoOnly {
                HealthHero(insight: model.healthInsight, m: m, shown: shown)
                    .modifier(EnterRise(on: shown, delay: 0.04, y: 12, blur: 5, animation: ComMotion.lift))
                ActionStack(actions: model.healthInsight["actions"].array)
                    .modifier(EnterRise(on: shown, delay: 0.12, y: 12, blur: 5, animation: ComMotion.lift))
            }
            MetricGrid(today: today, days: all, shown: shown, zoom: zoom)
                .modifier(EnterRise(on: shown, delay: 0.2, y: 12, blur: 5, animation: ComMotion.lift))
            HealthBrief(
                points: briefPoints,
                loading: loading && !loadedOnce,
                loadFailed: !briefFail.isEmpty && briefPoints.isEmpty
            )
                .modifier(EnterRise(on: shown, delay: 0.32, y: 12, blur: 5, animation: ComMotion.lift))
            BodyCard(shown: shown, showTiles: false)
                .modifier(EnterRise(on: shown, delay: 0.36, y: 12, blur: 5, animation: ComMotion.lift))
        }
        .refreshable {
            await pullHealth(force: true)
            await model.refreshHealthInsight()
        }
        // 进页一次拉齐：今天/下一步（身体要点）+ 健康曲线 + 评估；别只靠切 Tab 的 refresh。
        .task { await pullHealth(force: false) }
        .onAppear {
            if reduce { shown = true }
            else { withAnimation(ComMotion.lift) { shown = true } }
        }
        .onDisappear { shown = false }
        .accessibilityIdentifier("health-page")
    }

    private func pullHealth(force: Bool) async {
        guard !loading else { return }
        loading = true
        if force {
            failNote = ""
            briefFail = ""
        }
        defer {
            loading = false
            loadedOnce = true
        }
        async let range = model.load(rangePath)
        async let insight = model.load(insightPath)
        async let today = model.load("/personal/today")
        async let next = model.load("/personal/next")
        let gotRange = await range != nil
        let gotInsight = await insight != nil
        let gotToday = await today != nil
        let gotNext = await next != nil

        let hadRange = !model.healthRange["days"].array.isEmpty || !model.healthRange["today"]["measurements"].isNull
        let rangeErr = model.errors[rangePath] ?? model.errors["/personal/health"] ?? ""
        let insightErr = model.errors[insightPath] ?? ""

        if gotRange && gotInsight {
            failNote = ""
            model.healthOpenNote = ""
        } else if !gotRange && !gotInsight {
            let err = [rangeErr, insightErr].first { !$0.isEmpty } ?? ""
            failNote = err.isEmpty
                ? (hadRange ? "健康曲线和评估都没刷新上——下面仍是上一版，可再试" : "健康曲线和评估没拉齐——检查配对或网络后再试")
                : (hadRange ? "健康没刷新上：" + err + "——下面仍是上一版" : "健康没拉齐：" + err + "——可再试")
        } else if !gotRange {
            failNote = rangeErr.isEmpty
                ? (hadRange ? "健康曲线没刷新上——评估若在仍可先看；可再试" : "健康曲线没读上——可再试")
                : "健康曲线没读上：" + rangeErr + "——可再试"
        } else {
            let hadInsight = !model.healthInsight.isNull
            failNote = insightErr.isEmpty
                ? (hadInsight ? "身体评估没刷新上——下面仍是上一版，可再试" : "身体评估没拉齐——可再试；别把空白当成已写好")
                : "身体评估没拉齐：" + insightErr + "——可再试"
        }

        if gotToday || gotNext {
            briefFail = ""
        } else {
            let tErr = model.errors["/personal/today"] ?? ""
            let nErr = model.errors["/personal/next"] ?? ""
            let err = [tErr, nErr].first { !$0.isEmpty } ?? ""
            briefFail = err.isEmpty
                ? "身体简报没拉齐——可再试；通了我再开口说一句"
                : "身体简报没拉齐：" + err + "——可再试"
            if failNote.isEmpty { failNote = briefFail }
        }
    }
}

/// 评估还没写好时，先用测量值说一句人话，避免健康页像裸仪表盘。
private func companionHealthLine(m: JSON) -> String {
    if !m["readiness_score"].isNull {
        let readiness = m["readiness_score"].double
        if readiness >= 76 { return "准备度 \(Int(readiness))——身体这会儿挺能打，别空耗。" }
        if readiness >= 51 { return "准备度 \(Int(readiness))。能做事，别把高强度全排满。" }
        if readiness > 0 { return "准备度 \(Int(readiness))。今天宜收着点，留力给要紧的。" }
    }
    if !m["sleep_seconds"].isNull {
        let h = m["sleep_seconds"].double / 3600
        if h > 0 {
            return String(format: "昨晚睡了约 %.1f 小时。完整评估我还在写，先按感觉安排。", h)
        }
    }
    return "数字在下面。完整评估还没写好——下拉刷新，或等我整理完再看。"
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
        let motion: Animation = ComMotion.reduced(reduce, ComMotion.settle)
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .center, spacing: Space.lg) {
                ScoreRing(value: score, shown: shown)
                VStack(alignment: .leading, spacing: 6) {
                    Text(insight["headline"].string.isEmpty ? (running ? "我正在看你的身体…" : "我还没写好今天的评估") : insight["headline"].string)
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
                        .buttonStyle(SoftPressStyle(scale: 0.96))
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
        .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: insight["headline"].string)
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
        .buttonStyle(SoftPressStyle(scale: 0.94))
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
                            Button("重来") { withAnimation(ComMotion.reduced(reduce, ComMotion.pop)) { doneRaw = "" } }
                                .font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.accentText)
                                .buttonStyle(SoftPressStyle(scale: 0.96))
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
            withAnimation(ComMotion.reduced(reduce, ComMotion.lift)) { flipped.toggle() }
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
                else { withAnimation(ComMotion.reduced(reduce, ComMotion.pop)) { drag = .zero } }
            }
    }
    /// 甩出去：先顺着方向飞出屏幕（0.25s），再把它从堆里拿走，拖动归零给下一张。
    private func fling(_ direction: CGFloat, then: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.22)) { drag = CGSize(width: direction * 520, height: drag.height + 30) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { drag = .zero; flipped = false }
            withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { then() }
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

// MARK: 身体简报

/// 「下一步」整理时从身体数据里归纳的几条要点（原来在今天页的简报里）；没有就不占位。
/// 拉齐失败时要开口，别整块消失像「没什么好说」。
private struct HealthBrief: View {
    let points: [JSON]
    var loading: Bool = false
    var loadFailed: Bool = false
    var body: some View {
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("身体上我说一句")
                    .font(TypeScale.section)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(points.prefix(3).enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .top, spacing: Space.md) {
                        Image(systemName: index == 0 ? "quote.opening" : "heart.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(index == 0 ? Palette.accentText : TodayHue.pink.ink)
                            .frame(width: 34, height: 34)
                            .background((index == 0 ? Palette.accent.opacity(0.18) : TodayHue.pink.fill),
                                        in: .rect(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            if index == 0 {
                                Text("开场").font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.accentText)
                            }
                            Text(point["text"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Space.md)
                    .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("health-brief-\(index)")
                }
            }
        } else if loading {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("正在拉齐身体简报…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
            .accessibilityIdentifier("health-brief-pulling")
        } else if loadFailed {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("身体上我说一句")
                    .font(TypeScale.section)
                    .accessibilityAddTraits(.isHeader)
                Text("身体简报还没读上——先重试；通了我再开口说一句。别把失败当成「没什么好说」。")
                    .font(TypeScale.subheadline).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("health-brief-empty-fail")
        }
    }
}

// MARK: 指标拼图

/// 10-28 改版（参考 x.com/craft_120 的 bento 拼图）：七张大小不一的卡——睡眠宽卡 + 静息心率小卡；
/// HRV 中卡 + 电量 / 压力两张小方卡叠放 + 右侧「活动量」高卡；底下「最近活动」宽卡。
/// 每张卡都是入口：点开用 zoom 转场推进到那一项的趋势页（iOS 18 navigationTransition，卡片放大成页面）。
private struct MetricGrid: View {
    let today: JSON
    let days: [JSON]
    let shown: Bool
    let zoom: Namespace.ID
    @State private var width: CGFloat = 360
    struct Item: Identifiable { let id: String; let title: String; let symbol: String; let hue: TodayHue; let key: String; let unit: String; let higher: Bool; let scale: Double }
    static let items: [Item] = [
        Item(id: "battery", title: "身体电量", symbol: "bolt.heart.fill", hue: .mint, key: "body_battery_at_wake", unit: "", higher: true, scale: 1),
        Item(id: "sleep", title: "睡眠", symbol: "moon.zzz.fill", hue: .lavender, key: "sleep_seconds", unit: "h", higher: true, scale: 1.0 / 3600),
        Item(id: "hrv", title: "HRV", symbol: "waveform.path.ecg", hue: .sky, key: "hrv_last_night", unit: "ms", higher: true, scale: 1),
        Item(id: "rhr", title: "静息心率", symbol: "heart.fill", hue: .pink, key: "resting_heart_rate", unit: "bpm", higher: false, scale: 1),
        Item(id: "stress", title: "压力", symbol: "brain.head.profile", hue: .butter, key: "avg_stress", unit: "", higher: false, scale: 1),
        Item(id: "load", title: "活动量", symbol: "figure.walk", hue: .butter, key: "steps", unit: "步", higher: true, scale: 1),
        Item(id: "activity", title: "最近活动", symbol: "figure.climbing", hue: .butter, key: "load_acute", unit: "", higher: true, scale: 1),
    ]
    private var m: JSON { today["measurements"] }
    var body: some View {
        let g = Space.md
        let u = max(92, (width - 2 * g) / 3)
        let small: CGFloat = 112
        VStack(spacing: g) {
            HStack(spacing: g) {
                tile("sleep", height: 156)
                tile("rhr", height: 156).frame(width: u)
            }
            HStack(alignment: .top, spacing: g) {
                VStack(spacing: g) {
                    HStack(spacing: g) {
                        tile("hrv", height: small * 2 + g)
                        VStack(spacing: g) {
                            tile("battery", height: small)
                            tile("stress", height: small)
                        }
                        .frame(width: u * 0.86)
                    }
                    tile("activity", height: 132)
                }
                tile("load", height: small * 2 + g * 2 + 132).frame(width: u)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func tile(_ id: String, height: CGFloat) -> some View {
        let item = Self.items.first { $0.id == id }!
        let index = Self.items.firstIndex { $0.id == id } ?? 0
        return NavigationLink {
            HealthMetricPage(item: item)
                .navigationTransition(.zoom(sourceID: item.id, in: zoom))
        } label: {
            content(item, index: index)
                .padding(Space.md)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                .elevation(.raised)
                .contentShape(.rect(cornerRadius: Radius.lg, style: .continuous))
        }
        .buttonStyle(TilePress())
        .matchedTransitionSource(id: item.id, in: zoom) { $0.clipShape(.rect(cornerRadius: Radius.lg, style: .continuous)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title + "，" + spoken(item))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("health-tile-" + item.id)
    }

    // MARK: 取数

    private func series(_ key: String, scale: Double = 1, last: Int = 14) -> [Double] {
        days.suffix(last).compactMap { d in d["measurements"][key].isNull ? nil : d["measurements"][key].double * scale }
    }
    private func value(_ key: String) -> Double? { m[key].isNull ? nil : m[key].double }
    private func spoken(_ item: Item) -> String {
        switch item.id {
        case "battery": return value("body_battery").map { "现在 \(Int($0))" } ?? "无数据"
        case "activity": return "\(recent.count) 次"
        default: return series(item.key, scale: item.scale).last.map { (item.id == "sleep" ? $0.formatted(.number.precision(.fractionLength(1))) : "\(Int($0.rounded()))") + item.unit } ?? "无数据"
        }
    }
    private var recent: [(String, JSON)] {
        Array(days.suffix(14).reversed().flatMap { d in d["activities"].array.map { (String(d["date"].string.suffix(5)), $0) } })
    }

    // MARK: 卡片内容

    @ViewBuilder private func content(_ item: Item, index: Int) -> some View {
        switch item.id {
        case "sleep": sleepCard(item)
        case "rhr": heartCard(item, index: index)
        case "hrv": hrvCard(item, index: index)
        case "battery":
            ringCard(item, fraction: (value("body_battery") ?? value("body_battery_at_wake") ?? 0) / 100,
                     value: value("body_battery").map { "\(Int($0))" } ?? "—",
                     note: value("body_battery_at_wake").map { "起床 \(Int($0))" } ?? "")
        case "stress":
            ringCard(item, fraction: (value("avg_stress") ?? 0) / 100, value: value("avg_stress").map { "\(Int($0))" } ?? "—",
                     note: (value("avg_stress") ?? 0) <= 25 ? "很放松" : (value("avg_stress") ?? 0) <= 50 ? "平稳" : "偏紧")
        case "load": loadCard(item, index: index)
        default: activityCard(item)
        }
    }

    private func header(_ item: Item) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(item.hue.ink)
            Text(item.title).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
        }
    }
    private func big(_ text: String, unit: String = "", size: CGFloat = 40, color: Color = Palette.textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(text).font(.system(size: size, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(color)
                .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.6)
            if !unit.isEmpty { Text(unit).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) }
        }
    }
    private static func hm(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h\(String(format: "%02d", minutes % 60))" : "\(minutes)m"
    }

    /// 睡眠宽卡：左边大数（小时）+ 睡眠分，右边像「日志」那样一列带色条的分期。
    private func sleepCard(_ item: Item) -> some View {
        let stages: [(String, String, Color)] = [("深睡", "deep_seconds", TodayHue.lavender.ink), ("浅睡", "light_seconds", TodayHue.sky.ink), ("REM", "rem_seconds", TodayHue.pink.ink)]
            .compactMap { name, key, color in value(key).map { (name, Self.hm($0), color) } }
        return HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 0) {
                header(item)
                Spacer(minLength: Space.sm)
                big(value("sleep_seconds").map { ($0 / 3600).formatted(.number.precision(.fractionLength(1))) } ?? "—", unit: "小时", size: 46)
                if let score = value("sleep_score") {
                    Text("睡眠分 \(Int(score))").font(.caption).foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if stages.isEmpty {
                let s = series(item.key, scale: item.scale)
                if s.count > 1 { MiniTrend(values: s, color: item.hue.ink).frame(width: 90).modifier(DrawIn(on: shown, delay: 0.35, duration: 0.8)) }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                        HStack(spacing: Space.sm) {
                            Capsule().fill(stage.2).frame(width: 3)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(stage.0).font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.textPrimary)
                                Text(stage.1).font(.caption.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                            }
                        }
                        .fixedSize()
                    }
                }
                .frame(minWidth: 84, alignment: .leading)
            }
        }
    }

    /// 静息心率小卡：红色大数 + 14 天曲线 + 高 / 低。
    private func heartCard(_ item: Item, index: Int) -> some View {
        let s = series(item.key)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "heart.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.danger)
                Text(s.last.map { "\(Int($0))" } ?? "—").font(.system(size: 26, weight: .regular, design: .rounded)).monospacedDigit().foregroundStyle(Palette.danger)
                    .contentTransition(.numericText())
                Text("bpm").font(.caption2.weight(.semibold)).foregroundStyle(Palette.danger.opacity(0.75))
            }
            Text("静息心率").font(.caption).foregroundStyle(Palette.textTertiary)
            if s.count > 1 {
                MiniTrend(values: s, color: Palette.danger).frame(maxHeight: .infinity)
                    .modifier(DrawIn(on: shown, delay: 0.35 + Double(index) * 0.05, duration: 0.8))
                VStack(spacing: 1) {
                    minMax("高", s.max() ?? 0, Palette.danger)
                    minMax("低", s.min() ?? 0, Palette.info)
                }
            } else { Spacer(minLength: 0) }
        }
    }
    private func minMax(_ label: String, _ v: Double, _ color: Color) -> some View {
        HStack {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(Palette.textTertiary)
            Spacer()
            Text("\(Int(v.rounded()))").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }
    }

    /// HRV 中卡：昨晚 vs 14 天均值两个数，下面整块曲线。
    private func hrvCard(_ item: Item, index: Int) -> some View {
        let s = series(item.key)
        let mean = s.count > 1 ? s.dropLast().reduce(0, +) / Double(s.count - 1) : nil
        return VStack(alignment: .leading, spacing: Space.sm) {
            header(item)
            Text("近 \(s.count) 天 · ms").font(.caption2).foregroundStyle(Palette.textTertiary).padding(.top, -6)
            HStack(alignment: .top, spacing: Space.md) {
                pair("昨晚", s.last.map { "\(Int($0))" } ?? "—", item.hue.ink)
                pair("均值", mean.map { "\(Int($0.rounded()))" } ?? "—", Palette.textTertiary)
            }
            if s.count > 1 {
                MiniTrend(values: s, color: item.hue.ink).frame(maxHeight: .infinity)
                    .modifier(DrawIn(on: shown, delay: 0.35 + Double(index) * 0.05, duration: 0.9))
            } else { Spacer(minLength: 0) }
        }
    }
    private func pair(_ label: String, _ value: String, _ dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(value).font(.system(size: 22, weight: .regular, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText()).lineLimit(1).fixedSize()
            }
        }
    }

    /// 小方卡：圆环 + 名字 + 数。
    private func ringCard(_ item: Item, fraction: Double, value: String, note: String) -> some View {
        VStack(spacing: 5) {
            BentoRing(fraction: fraction, color: item.hue.ink, track: item.hue.fill, symbol: item.symbol, shown: shown)
                .frame(width: 40, height: 40)
            Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            HStack(spacing: 3) {
                Text(value).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Palette.textPrimary).contentTransition(.numericText())
                if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(Palette.textTertiary).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 活动量高卡：日均步数大数 + 14 天柱状 + 底下几条灰底指标（参考图里 Activity 那张）。
    private func loadCard(_ item: Item, index: Int) -> some View {
        let s = series("steps")
        let mean = s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
        let rows: [(String, String)] = [
            ("今天", value("steps").map { "\(Int($0))" } ?? "—"),
            ("急性负荷", value("load_acute").map { "\(Int($0))" } ?? "—"),
            ("负荷比", value("load_ratio").map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"),
        ]
        return VStack(alignment: .leading, spacing: Space.sm) {
            header(item)
            VStack(alignment: .leading, spacing: 0) {
                Text("日均").font(.caption2).foregroundStyle(Palette.textTertiary)
                big(mean.map { $0 >= 10000 ? ($0 / 1000).formatted(.number.precision(.fractionLength(1))) + "k" : "\(Int($0.rounded()))" } ?? "—", unit: "步", size: 26)
            }
            if s.count > 1 {
                Chart(Array(s.enumerated()), id: \.offset) { point in
                    // 类目轴（字符串）才有「每格宽度」，.ratio 才生效；整数轴是连续的，柱子宽度为 0
                    BarMark(x: .value("天", "\(point.offset)"), y: .value("步", point.element), width: .ratio(0.62))
                        .foregroundStyle(point.offset == s.count - 1 ? item.hue.ink : TodayHue.sky.ink.opacity(0.55))
                        .cornerRadius(2)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(maxHeight: .infinity)
                .modifier(DrawIn(on: shown, delay: 0.4, duration: 0.9))
            } else { Spacer(minLength: 0) }
            VStack(spacing: 4) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0).font(.caption2).foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: 2)
                        Text(row.1).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.textPrimary)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(Palette.fill, in: .rect(cornerRadius: 7, style: .continuous))
                }
                if let status = trainingStatusWord(m["training_status"].string).nilIfEmpty {
                    Text(status).font(.caption2.weight(.semibold)).foregroundStyle(TodayHue.mint.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(TodayHue.mint.fill, in: .rect(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    /// 最近活动宽卡：左边 14 天次数大数，右边最近两次（色条 + 名字 + 日期时长）。
    private func activityCard(_ item: Item) -> some View {
        let acts = recent
        return HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 0) {
                header(item)
                Spacer(minLength: Space.sm)
                big("\(acts.count)", unit: "次 · 14 天", size: 44)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 9) {
                if acts.isEmpty {
                    Text("两周没有记录").font(.caption).foregroundStyle(Palette.textTertiary)
                }
                ForEach(Array(acts.prefix(2).enumerated()), id: \.offset) { i, pair in
                    let (date, a) = pair
                    HStack(spacing: Space.sm) {
                        Capsule().fill(i == 0 ? TodayHue.butter.ink : TodayHue.sky.ink).frame(width: 3)
                        VStack(alignment: .leading, spacing: 0) {
                            Label(a["name"].string, systemImage: activitySymbol(a["type"].string))
                                .font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                            Text(date + " · \(a["minutes"].int) 分钟").font(.caption.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 150, alignment: .leading)
        }
    }
}

/// 小方卡里的圆环：进页时从 0 画到当前值，中间放图标。
private struct BentoRing: View {
    let fraction: Double
    let color: Color
    let track: Color
    let symbol: String
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 6)
            Circle().trim(from: 0, to: shown || reduce ? max(0.02, min(1, fraction)) : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduce ? nil : .timingCurve(0.45, 0, 0.2, 1, duration: 0.9).delay(0.4), value: shown)
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
        }
        .padding(3)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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

/// 按下时格子微缩、松手弹回（对齐 SoftPress / DockPress）。
private struct TilePress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduce ? 1 : (configuration.isPressed ? 0.96 : 1))
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduce ? .easeOut(duration: 0.12) : ComMotion.press, value: configuration.isPressed)
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
                    .buttonStyle(SoftPressStyle(scale: 0.96))
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
                case "load", "activity": LoadPanel(m: m, days: all, shown: shown)
                default: HeartStressPanel(days: days, shown: shown)
                }
            }
            .animation(reduce ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: spanRaw)
            Text("来源：Garmin Connect（python-garminconnect）。和你自己的近期均值比，不是医疗诊断。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.xs)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { DockSpacer() }
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
        Panel(title: "负荷与活动", symbol: "figure.climbing", hue: .butter, trailing: trainingStatusWord(m["training_status"].string)) {
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
}

func trainingStatusWord(_ raw: String) -> String {
    let map = ["PRODUCTIVE": "有效训练", "MAINTAINING": "保持", "RECOVERY": "恢复中", "UNPRODUCTIVE": "低效", "DETRAINING": "退训", "PEAKING": "巅峰",
               "OVERREACHING": "负荷过量", "STRAINED": "紧绷", "NO_STATUS": "暂无状态"]
    return map.first { raw.hasPrefix($0.key) }?.value ?? ""
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
