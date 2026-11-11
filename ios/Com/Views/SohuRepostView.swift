import SwiftUI
import ComCore

// 工作 Tab · 「搜狐」切面：搜狐关注流自动转发（NAS sohu_watcher + Mac mini sohu-repost-bot）可视化工作台。
// 覆盖：三通道配额 Bento 卡、链路探活与 Dry-Run 触发、低置信待审队列放行/否决、7 日转发趋势、带 @ 与站内表情的转发流水、活跃播主频次榜。

enum SohuFeedFilter: String, CaseIterable, Identifiable {
    case all, topic, outdoor, nonOutdoor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .topic: return "#大有可攀"
        case .outdoor: return "关注流"
        case .nonOutdoor: return "非户外"
        }
    }
    func matches(_ category: String) -> Bool {
        switch self {
        case .all: return true
        case .topic: return category == "topic_dayoukepan"
        case .outdoor: return category == "outdoor" || category.isEmpty
        case .nonOutdoor: return category == "non_outdoor"
        }
    }
}

extension AppModel {
    static let sohuRepostPath = "/personal/sohu-repost"
    var sohuRepostData: JSON { datasets[Self.sohuRepostPath] ?? .null }

    @discardableResult
    func loadSohuRepost() async -> Bool {
        await load(Self.sohuRepostPath) != nil
    }

    func sohuRepostAct(action: String, id: String = "", angleIndex: Int = 0) async -> (ok: Bool, message: String) {
        #if DEBUG
        if isUITesting {
            var current = sohuRepostData
            if action == "approve" || action == "reject" {
                let remaining = current["review_queue"].array.filter { $0["id"].string != id }
                current["review_queue"] = .array(remaining)
                datasets[Self.sohuRepostPath] = current
                Haptics.success()
                return (true, action == "approve" ? "已采用放行，下一轮管道自动发布" : "已否决并跳过该条视频")
            }
            Haptics.success()
            return (true, action == "dry_run" ? "Dry-Run 沙箱演练通过：0 线上污染" : "已触发后台巡检与转发")
        }
        #endif
        do {
            var fields: [String: JSON] = ["action": .string(action)]
            if !id.isEmpty { fields["id"] = .string(id) }
            fields["angle_index"] = .number(Double(angleIndex))
            let resp = try await mutate("/personal/sohu-repost/action", fields: fields)
            if !resp["snapshot"].isNull {
                datasets[Self.sohuRepostPath] = resp["snapshot"]
            } else {
                _ = await load(Self.sohuRepostPath)
            }
            Haptics.success()
            let summary = resp["summary"].string
            if !summary.isEmpty { return (resp["ok"].bool, summary) }
            return (true, action == "approve" ? "已放行，下一轮管道自动发布" : action == "reject" ? "已否决跳过" : "操作已执行")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

struct SohuRepostSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.openURL) private var openURL
    @State private var filter: SohuFeedFilter = .all
    @State private var selectedAngles: [String: Int] = [:]
    @State private var busyAction: String = ""
    @State private var actionNotice: String = ""
    @State private var actionFailed = false
    @State private var loading = false
    @State private var landed = false
    @State private var creatorsExpanded = false

    private var data: JSON { model.sohuRepostData }
    private var health: JSON { data["health"] }
    private var quota: JSON { data["quota"] }
    private var reviews: [JSON] { data["review_queue"].array }
    private var week: [JSON] { data["week"].array }
    private var recent: [JSON] { data["recent"].array }
    private var filteredRecent: [JSON] {
        recent.filter { filter.matches($0["category"].string) }
    }
    private var topCreators: [JSON] { data["top_creators"].array }
    private var recentMentions: [String] { data["recent_mentions"].array.map(\.string).filter { !$0.isEmpty } }

    private var previewScrollMode: String {
        ProcessInfo.processInfo.environment["COM_PREVIEW_SOHU_SCROLL"] ?? ""
    }

    var body: some View {
        ScrollPage(spacing: Space.xl) {
            if previewScrollMode != "bottom" && previewScrollMode != "timeline" {
                headerSummary
                    .modifier(EnterRise(on: landed, delay: 0, y: 12, blur: 4, animation: ComMotion.rise))

                if !actionNotice.isEmpty {
                    InlineNotice(text: actionNotice, tone: actionFailed ? .danger : .accent)
                        .accessibilityIdentifier("sohu-action-notice")
                }

                bentoTopGrid
                    .modifier(EnterRise(on: landed, delay: 0.04, y: 14, blur: 4, animation: ComMotion.pop))
            }

            if previewScrollMode != "timeline", !reviews.isEmpty {
                reviewQueueSection
                    .modifier(EnterRise(on: landed, delay: 0.08, y: 14, blur: 4, animation: ComMotion.lift))
            }

            if previewScrollMode != "timeline", !week.isEmpty {
                weekTrendCard
                    .modifier(EnterRise(on: landed, delay: 0.10, y: 14, blur: 4, animation: ComMotion.lift))
            }

            recentFeedSection
                .modifier(EnterRise(on: landed, delay: 0.14, y: 16, blur: 4, animation: ComMotion.settle))

            if !topCreators.isEmpty {
                creatorsSection
                    .modifier(EnterRise(on: landed, delay: 0.18, y: 16, blur: 4, animation: ComMotion.settle))
            }
        }
        .accessibilityIdentifier("sohu-repost-surface")
        .onAppear {
            if reduce { landed = true }
            else { withAnimation(ComMotion.lift) { landed = true } }
        }
        .task {
            if data.isNull {
                loading = true
                _ = await model.loadSohuRepost()
                loading = false
            } else {
                _ = await model.loadSohuRepost()
            }
        }
        .refreshable {
            _ = await model.loadSohuRepost()
        }
    }

    // MARK: - 顶部状态栏

    private var headerSummary: some View {
        HStack(alignment: .center, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.xs) {
                    Text("搜狐户外 · 关注流自动转发")
                        .font(TypeScale.headline)
                        .foregroundStyle(Palette.textPrimary)
                    StatusPill(
                        text: health["login_ok"].bool ? "在线守护" : "需扫码重登",
                        tone: health["login_ok"].bool ? .success : .danger
                    )
                }
                Text(health["status_text"].string.isEmpty ? "NAS 抓片抽帧 → Gemini 拟人文案 → mini 站内转发" : health["status_text"].string)
                    .font(TypeScale.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if loading {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Bento 顶部双卡（左：今日三通道配额环；右：链路健康与触发）

    private var bentoTopGrid: some View {
        let total = quota["daily_total"].int
        let maxTotal = max(1, quota["daily_max"].int > 0 ? quota["daily_max"].int : 10)
        let progress = min(1.0, Double(total) / Double(maxTotal))
        let outdoor = quota["outdoor_today"].int
        let topic = quota["topic_today"].int
        let nonOutdoor = quota["non_outdoor_today"].int
        let nonMax = max(1, quota["non_outdoor_max"].int > 0 ? quota["non_outdoor_max"].int : 1)
        let cooldown = quota["non_outdoor_cooldown_hours"].double

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.md) {
                quotaCard(total: total, maxTotal: maxTotal, progress: progress, outdoor: outdoor, topic: topic, nonOutdoor: nonOutdoor, nonMax: nonMax, cooldown: cooldown)
                healthActionCard
            }
            VStack(spacing: Space.md) {
                quotaCard(total: total, maxTotal: maxTotal, progress: progress, outdoor: outdoor, topic: topic, nonOutdoor: nonOutdoor, nonMax: nonMax, cooldown: cooldown)
                healthActionCard
            }
        }
    }

    private func quotaCard(total: Int, maxTotal: Int, progress: Double, outdoor: Int, topic: Int, nonOutdoor: Int, nonMax: Int, cooldown: Double) -> some View {
        Card(.standard, padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .center, spacing: Space.md) {
                    ZStack {
                        Circle()
                            .stroke(Palette.fill, lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(total)")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .frame(width: 50, height: 50)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("今日配额 \(total) / \(maxTotal)")
                            .font(TypeScale.headline)
                            .foregroundStyle(Palette.textPrimary)
                        Text("单播主上限 \(max(1, quota["per_creator_max"].int)) 条 · 48h 有效")
                            .font(TypeScale.footnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }

                DashedRule()

                VStack(alignment: .leading, spacing: Space.xs + 2) {
                    channelRow(dot: Palette.accentText, label: "户外关注流", value: "今日 \(outdoor) 条")
                    channelRow(dot: Palette.info, label: "#大有可攀 话题", value: "今日 \(topic) 条 · 随机 @")
                    channelRow(
                        dot: Palette.warning,
                        label: "非户外跨界",
                        value: cooldown > 0 ? "\(nonOutdoor)/\(nonMax) · 冷却 \(String(format: "%.1f", cooldown))h" : "\(nonOutdoor)/\(nonMax) · 就绪"
                    )
                }
            }
        }
        .accessibilityIdentifier("sohu-quota-card")
    }

    private func channelRow(dot: Color, label: String, value: String) -> some View {
        HStack(spacing: Space.sm) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label)
                .font(TypeScale.footnote)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Space.xs)
            Text(value)
                .font(TypeScale.footnote.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
        }
    }

    private var healthActionCard: some View {
        let lastRun = health["last_run_at"].double
        let lastPub = health["last_publish_at"].double
        let hbHours = health["nas_heartbeat_hours"].double

        return Card(.standard, padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    IconBadge(symbol: "antenna.radiowaves.left.and.right", tone: health["pipeline_ok"].bool ? .success : .warning, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("NAS ↔ mini 管道")
                            .font(TypeScale.rowTitle)
                            .foregroundStyle(Palette.textPrimary)
                        Text(lastRun > 0 ? "上次巡检 " + relativeTime(lastRun) : "每 30 分钟巡检")
                            .font(TypeScale.footnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: Space.xs + 1) {
                    HStack {
                        Text("最近发帖")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Text(lastPub > 0 ? relativeTime(lastPub) : "今日暂无")
                            .font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.textPrimary)
                    }
                    HStack {
                        Text("NAS 容器心跳")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Text(hbHours > 0 ? String(format: "%.1f 小时前", hbHours) : "正常")
                            .font(TypeScale.footnote.weight(.medium)).foregroundStyle(health["nas_ok"].bool ? Palette.success : Palette.warning)
                    }
                }

                HStack(spacing: Space.sm) {
                    Button {
                        triggerAction("run_now")
                    } label: {
                        HStack(spacing: 4) {
                            if busyAction == "run_now" { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "play.fill").font(.system(size: 11)) }
                            Text("立即巡检")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primaryCompact)
                    .disabled(!busyAction.isEmpty)
                    .accessibilityIdentifier("sohu-run-now")

                    Button {
                        triggerAction("dry_run")
                    } label: {
                        HStack(spacing: 4) {
                            if busyAction == "dry_run" { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "testtube.2").font(.system(size: 11)) }
                            Text("试跑")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(!busyAction.isEmpty)
                    .accessibilityIdentifier("sohu-dry-run")
                }
            }
        }
        .accessibilityIdentifier("sohu-health-card")
    }

    // MARK: - 低置信度待审队列（review_queue）

    private var reviewQueueSection: some View {
        GroupSection("待你拍板（\(reviews.count)）", footer: "置信度 <7 或未打分的视频停在这里，选一条顺眼的文案放行，下一轮管道自动发出。") {
            VStack(spacing: Space.md) {
                ForEach(reviews.map(RemoteRow.init)) { row in
                    reviewCard(row.value)
                }
            }
        }
    }

    private func reviewCard(_ item: JSON) -> some View {
        let itemID = item["id"].string
        let angles = item["angles"].array.map(\.string).filter { !$0.isEmpty }
        let chosen = selectedAngles[itemID] ?? 0
        let conf = item["confidence"]

        return Card(.highlighted(.warning), padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Stamp(text: item["category_label"].string.isEmpty ? "关注流" : item["category_label"].string, tone: .warning)
                    Text(item["creator_name"].string)
                        .font(TypeScale.headline)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: Space.xs)
                    Text(conf.isNull ? "未打分" : String(format: "置信 %.1f", conf.double))
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.warning)
                }

                if !item["theme"].string.isEmpty {
                    Text("视频主题：" + item["theme"].string)
                        .font(TypeScale.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }

                if !angles.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(Array(angles.enumerated()), id: \.offset) { idx, angle in
                            let isSelected = idx == chosen
                            Button {
                                Haptics.selection()
                                selectedAngles[itemID] = idx
                            } label: {
                                HStack(alignment: .top, spacing: Space.sm) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? Palette.accentText : Palette.textTertiary)
                                        .font(.system(size: 16, weight: .semibold))
                                        .padding(.top, 2)
                                    Text(angle)
                                        .font(TypeScale.subheadline)
                                        .foregroundStyle(Palette.textPrimary)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(Space.sm + 2)
                                .background(isSelected ? Palette.accent.opacity(0.22) : Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sohu-review-angle-\(itemID)-\(idx)")
                        }
                    }
                }

                HStack(spacing: Space.sm) {
                    Button {
                        reviewItem(id: itemID, action: "approve", angleIndex: chosen)
                    } label: {
                        Text("采用并放行")
                    }
                    .buttonStyle(.primaryCompact)
                    .disabled(!busyAction.isEmpty)
                    .accessibilityIdentifier("sohu-review-approve-\(itemID)")

                    Button {
                        reviewItem(id: itemID, action: "reject", angleIndex: 0)
                    } label: {
                        Text("否决跳过")
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(!busyAction.isEmpty)
                    .accessibilityIdentifier("sohu-review-reject-\(itemID)")

                    Spacer(minLength: 0)

                    if let url = URL(string: item["link"].string), !item["link"].string.isEmpty {
                        Button {
                            openURL(url)
                        } label: {
                            Label("看原片", systemImage: "safari")
                                .font(TypeScale.footnote.weight(.semibold))
                        }
                        .buttonStyle(.quiet)
                    }
                }
            }
        }
        .accessibilityIdentifier("sohu-review-card-\(itemID)")
    }

    // MARK: - 7 日转发趋势与最近随机 @ 互动池

    private var weekTrendCard: some View {
        let maxCount = max(1, week.map { $0["total"].int }.max() ?? 1)
        let weekSum = week.reduce(0) { $0 + $1["total"].int }

        return Card(.standard, padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("近 7 日转发节奏")
                        .font(TypeScale.headline)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Text("共 \(weekSum) 条")
                        .font(TypeScale.footnote.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                }

                HStack(alignment: .bottom, spacing: Space.sm) {
                    ForEach(week.map { RemoteRow(.object(["id": $0["date"], "day": $0])) }) { row in
                        let day = row.value["day"]
                        let tot = day["total"].int
                        let topicCnt = day["topic"].int
                        let nonCnt = day["non_outdoor"].int
                        let barH = max(6, CGFloat(tot) / CGFloat(maxCount) * 68)
                        VStack(spacing: 5) {
                            Text("\(tot)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(tot > 0 ? Palette.textPrimary : Palette.textTertiary)
                            ZStack(alignment: .bottom) {
                                Capsule()
                                    .fill(Palette.fill)
                                    .frame(width: 22, height: 68)
                                if tot > 0 {
                                    Capsule()
                                        .fill(topicCnt > 0 ? Palette.info : (nonCnt > 0 ? Palette.warning : Palette.accent))
                                        .frame(width: 22, height: barH)
                                }
                            }
                            Text(day["label"].string)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(day["label"].string == "今天" ? Palette.textPrimary : Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, Space.xs)

                if !recentMentions.isEmpty {
                    DashedRule()
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("最近随机 @ 互动播主（5 次排他防重）")
                            .font(TypeScale.footnote)
                            .foregroundStyle(Palette.textSecondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.xs) {
                                ForEach(recentMentions, id: \.self) { mention in
                                    Text(mention)
                                        .font(TypeScale.caption.weight(.semibold))
                                        .foregroundStyle(Palette.info)
                                        .padding(.horizontal, Space.sm + 2)
                                        .padding(.vertical, 4)
                                        .background(Palette.info.opacity(0.12), in: .capsule)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("sohu-week-trend-card")
    }

    // MARK: - 近期已转发流水（支持分类筛选）

    private var recentFeedSection: some View {
        GroupSection("已转发流水（\(filteredRecent.count)）") {
            VStack(alignment: .leading, spacing: Space.md) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) {
                        ForEach(SohuFeedFilter.allCases) { item in
                            let selected = filter == item
                            Button {
                                Haptics.selection()
                                withAnimation(ComMotion.reduced(reduce, ComMotion.snap)) { filter = item }
                            } label: {
                                Text(item.title)
                                    .font(TypeScale.footnote.weight(.semibold))
                                    .foregroundStyle(selected ? Palette.onAccent : Palette.textSecondary)
                                    .padding(.horizontal, Space.md)
                                    .padding(.vertical, 6)
                                    .background(selected ? Palette.accent : Palette.surface, in: .capsule)
                                    .overlay(Capsule().strokeBorder(selected ? Color.clear : Palette.separator, lineWidth: 0.5))
                            }
                            .buttonStyle(SoftPressStyle(scale: 0.96))
                            .accessibilityIdentifier("sohu-filter-\(item.rawValue)")
                        }
                    }
                }

                if filteredRecent.isEmpty {
                    Card(.inset, padding: Space.lg) {
                        Text("该分类下暂时没有转发记录。")
                            .font(TypeScale.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                    }
                } else {
                    VStack(spacing: Space.sm + 2) {
                        ForEach(filteredRecent.prefix(20).map(RemoteRow.init)) { row in
                            repostTimelineCard(row.value)
                        }
                    }
                }
            }
        }
    }

    private func repostTimelineCard(_ item: JSON) -> some View {
        let cat = item["category"].string
        let catLabel = item["category_label"].string.isEmpty ? "关注流" : item["category_label"].string
        let tone: Tone = cat == "topic_dayoukepan" ? .info : (cat == "non_outdoor" ? .warning : .accent)
        let mentions = item["mentions"].array.map(\.string).filter { !$0.isEmpty }
        let emojis = item["emojis"].array.map(\.string).filter { !$0.isEmpty }
        let theme = item["theme"].string
        let link = item["link"].string

        return Card(.standard, padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .center, spacing: Space.sm) {
                    Stamp(text: catLabel, tone: tone)
                    Text(item["creator_name"].string)
                        .font(TypeScale.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: Space.xs)
                    Text(item["time_text"].string)
                        .font(TypeScale.footnote.monospacedDigit())
                        .foregroundStyle(Palette.textTertiary)
                }

                Text(item["copy"].string)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !mentions.isEmpty || !emojis.isEmpty || !theme.isEmpty || !link.isEmpty {
                    HStack(spacing: Space.xs) {
                        ForEach(mentions, id: \.self) { m in
                            Text("联动 \(m)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.info)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Palette.info.opacity(0.12), in: .capsule)
                        }
                        ForEach(emojis, id: \.self) { em in
                            Text("站内表情 \(em)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.accentText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Palette.accent.opacity(0.22), in: .capsule)
                        }
                        Spacer(minLength: 0)
                        if let url = URL(string: link), !link.isEmpty {
                            Button {
                                openURL(url)
                            } label: {
                                Label("原视频", systemImage: "arrow.up.right.square")
                                    .font(TypeScale.caption.weight(.semibold))
                            }
                            .buttonStyle(.quiet)
                        }
                    }
                }

                if !theme.isEmpty {
                    Text("原片主题：" + theme)
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier("sohu-recent-\(item["id"].string)")
    }

    // MARK: - 14 日活跃播主频次榜

    private var creatorsSection: some View {
        GroupSection("近 14 日高频转发播主") {
            GroupedCard {
                ForEach(topCreators.prefix(creatorsExpanded ? 10 : 5).map { RemoteRow(.object(["id": $0["uid"], "row": $0])) }) { item in
                    let row = item.value["row"]
                    let todayCnt = row["today_count"].int
                    let limit = max(1, row["daily_limit"].int)
                    HStack(spacing: Space.md) {
                        IconBadge(symbol: "person.wave.2", tone: todayCnt > 0 ? .accent : .neutral, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row["name"].string)
                                .font(TypeScale.rowTitle)
                                .foregroundStyle(Palette.textPrimary)
                            Text("14 日累计转发 \(row["count_14d"].int) 条")
                                .font(TypeScale.footnote)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        Stamp(
                            text: "今日 \(todayCnt)/\(limit)",
                            tone: todayCnt >= limit ? .warning : (todayCnt > 0 ? .accent : .neutral)
                        )
                    }
                    .rowPadding()
                }
                if topCreators.count > 5 {
                    Button {
                        withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { creatorsExpanded.toggle() }
                    } label: {
                        HStack {
                            Text(creatorsExpanded ? "收起播主榜" : "展开全部 \(topCreators.count) 位活跃播主")
                                .font(TypeScale.footnote.weight(.semibold))
                                .foregroundStyle(Palette.accentText)
                            Spacer()
                            Image(systemName: creatorsExpanded ? "chevron.up" : "chevron.down")
                                .font(TypeScale.footnote)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .rowPadding()
                    }
                    .buttonStyle(.row)
                }
            }
        }
    }

    // MARK: - Actions

    private func triggerAction(_ act: String) {
        guard busyAction.isEmpty else { return }
        busyAction = act
        actionNotice = ""
        Task {
            let res = await model.sohuRepostAct(action: act)
            actionFailed = !res.ok
            actionNotice = res.message
            busyAction = ""
        }
    }

    private func reviewItem(id: String, action: String, angleIndex: Int) {
        guard busyAction.isEmpty else { return }
        busyAction = id
        actionNotice = ""
        Task {
            let res = await model.sohuRepostAct(action: action, id: id, angleIndex: angleIndex)
            actionFailed = !res.ok
            actionNotice = res.message
            busyAction = ""
        }
    }
}
