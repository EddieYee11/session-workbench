import SwiftUI
import ComCore

// 热点板块（10-28）：AIHOT 的多源热点事件 + 24 小时精选。
// 数据：/personal/hot（backend/aihot.py，15 分钟缓存；?refresh=1 强制重抓）。
// 今天页放前 5 条热点，「全部」进完整列表；点条目开 AIHOT 阅读页，「让 Com 讲讲」把来龙去脉交给对话。

extension AppModel {
    static let hotPath = "/personal/hot"
    var hotData: JSON { datasets[AppModel.hotPath] ?? .null }
    /// 强制失败时仍回落普通拉齐；返回最终是否读到数据。失败写 hotOpenNote，别假装热点已齐。
    @discardableResult
    func refreshHot(force: Bool = false) async -> Bool {
        let ok: Bool
        if force, let data = await load(AppModel.hotPath + "?refresh=1") {
            datasets[AppModel.hotPath] = data
            ok = true
        } else {
            ok = await load(AppModel.hotPath) != nil
        }
        if ok {
            hotOpenNote = ""
            return true
        }
        let err = errors[AppModel.hotPath] ?? errors[AppModel.hotPath + "?refresh=1"] ?? ""
        let had = !hotData["topics"].array.isEmpty
        hotOpenNote = err.isEmpty
            ? (had
               ? "热点没刷上——下面仍可能是上一版。可再下拉。不会假装已是最新。"
               : "热点还没拉齐——可再下拉。不会假装已是最新。")
            : (had
               ? "热点没刷上：" + err + "——下面仍可能是上一版。不会假装已是最新。"
               : "热点没拉齐：" + err + "——可再下拉。不会假装已是最新。")
        return false
    }
    @discardableResult
    func askAboutHot(_ title: String) async -> Bool {
        let ok = await send(textOverride: "用 AIHOT 讲讲「\(title)」的来龙去脉，和我有什么关系？")
        if ok { tab = .chat }
        return ok
    }
}

struct HotBoardCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var showAll = false
    @State private var land = false
    @State private var cardLoading = false
    @State private var cardFail = ""
    @State private var cardLoaded = false
    var body: some View {
        let topics = model.hotData["topics"].array
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI 热点").font(TypeScale.section).accessibilityAddTraits(.isHeader)
                Text("AIHOT").font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
                // 空/失败也能进全表重试，不把入口藏掉。
                Button("全部") { showAll = true }
                    .font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    .buttonStyle(SoftPressStyle(scale: 0.96))
                    .accessibilityIdentifier("hot-all")
            }
            let surfaceFail = !cardFail.isEmpty ? cardFail : model.hotOpenNote
            if !surfaceFail.isEmpty && topics.isEmpty {
                InlineNotice(text: surfaceFail, tone: .danger)
                Button(cardLoading ? "重试中…" : "再试一次") {
                    guard !cardLoading else { return }
                    Task { await pullCard(force: true) }
                }
                .buttonStyle(.secondaryCompact)
                .disabled(cardLoading)
                .accessibilityIdentifier("hot-card-retry")
            }
            if topics.isEmpty {
                Text(emptyLead)
                    .font(TypeScale.subheadline).foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                    .modifier(EnterRise(on: land, delay: 0.04, y: 10, blur: 4, animation: ComMotion.pop))
                    .accessibilityIdentifier(surfaceFail.isEmpty ? "today-hot-empty" : "today-hot-empty-fail")
            } else {
                if !surfaceFail.isEmpty {
                    InlineNotice(text: surfaceFail, tone: .danger)
                        .accessibilityIdentifier("hot-card-stale-fail")
                }
                VStack(spacing: 0) {
                    ForEach(Array(topics.prefix(5).enumerated()), id: \.offset) { index, topic in
                        if index > 0 { Divider().padding(.leading, 44) }
                        HotTopicRow(topic: topic, rank: index + 1)
                    }
                }
                .padding(.vertical, Space.xs)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                .elevation(.raised)
                .modifier(EnterRise(on: land, delay: 0.06, y: 12, blur: 5, animation: ComMotion.rise))
            }
        }
        .onAppear {
            if reduce { land = true }
            else { withAnimation(ComMotion.lift) { land = true } }
        }
        .task { await pullCard(force: false) }
        .sheet(isPresented: $showAll) { HotBoardSheet() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-hot")
    }
    private var emptyLead: String {
        if cardLoading || (!cardLoaded && model.hotData.isNull) { return "我正在扫一眼 AI 圈在吵什么…" }
        if !cardFail.isEmpty || !model.hotOpenNote.isEmpty { return "热点还没读上——可再试，或点「全部」进全表重拉。" }
        return "这会儿读不到热点。下拉刷新一下，或晚点再来。"
    }
    private func pullCard(force: Bool) async {
        guard !cardLoading else { return }
        if !force && !model.hotData.isNull && !model.hotData["topics"].array.isEmpty {
            cardLoaded = true
            return
        }
        cardLoading = true
        if force {
            cardFail = ""
            model.hotOpenNote = ""
        }
        defer {
            cardLoading = false
            cardLoaded = true
        }
        if await model.refreshHot(force: force) {
            cardFail = ""
            model.hotOpenNote = ""
            return
        }
        // refreshHot 已写 hotOpenNote；行内再留一份 cardFail 兼容旧标识。
        cardFail = model.hotOpenNote
    }
}

private struct HotTopicRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let topic: JSON
    let rank: Int
    /// 「讲讲」进行中：防连点叠发。
    @State private var talking = false
    @State private var failNote = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button { if let url = URL(string: topic["url"].string) { openURL(url) } } label: {
                HStack(alignment: .top, spacing: Space.md) {
                    Text("\(rank)").font(TypeScale.callout.weight(.bold)).monospacedDigit()
                        .foregroundStyle(rank <= 3 ? TodayHue.pink.ink : Palette.textTertiary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic["title"].string).font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textPrimary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Text("\(topic["source_count"].int) 个信源 · " + HotTime.ago(topic["latest_at"].string))
                            .font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
                        if talking {
                            Text("正在交给 Com…").font(TypeScale.caption).foregroundStyle(Palette.textSecondary)
                        } else if !failNote.isEmpty {
                            Text(failNote).font(TypeScale.caption.weight(.medium)).foregroundStyle(Palette.danger)
                                .accessibilityIdentifier("hot-talk-fail")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.md).padding(.vertical, Space.sm + 2).contentShape(Rectangle())
            }
            .buttonStyle(SoftPressStyle(scale: 0.985))
            .disabled(talking)
        }
        .contextMenu {
            // askAboutHot：送达成功才切聊天；失败留行内提示可重试。
            Button {
                guard !talking else { return }
                talking = true
                failNote = ""
                Task {
                    let ok = await model.askAboutHot(topic["title"].string)
                    talking = false
                    if !ok { failNote = "没送出去，还可以再让我讲讲" }
                }
            } label: {
                Label(talking ? "讲讲中…" : "让 Com 讲讲", systemImage: "bubble.left")
            }
            .disabled(talking)
            if let url = URL(string: topic["original"].string), !topic["original"].string.isEmpty {
                Button { openURL(url) } label: { Label("看原文", systemImage: "arrow.up.right.square") }
            }
        }
    }
}

struct HotBoardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var section = 0
    @State private var category = ""
    @State private var refreshing = false
    @State private var loading = false
    @State private var loadFail = ""
    @State private var loadedOnce = false
    /// 24h 精选「讲讲」忙态（按标题）；失败写 sheetFail。
    @State private var talkingTitle: String?
    @State private var sheetFail = ""
    var body: some View {
        let data = model.hotData
        let topics = data["topics"].array
        let items = data["items"].array.filter { category.isEmpty || $0["category"].string == category }
        let emptyBoard = topics.isEmpty && data["items"].array.isEmpty
        NavigationStack {
            List {
                Picker("板块", selection: $section) { Text("热点事件").tag(0); Text("24 小时精选").tag(1) }
                    .pickerStyle(.segmented).listRowSeparator(.hidden)
                if loading || (!loadedOnce && emptyBoard) {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在拉齐 AI 热点全表…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    .listRowSeparator(.hidden)
                    .accessibilityLabel("正在拉齐 AI 热点全表")
                    .accessibilityIdentifier("hot-sheet-pulling")
                }
                if !loadFail.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        InlineNotice(text: loadFail, tone: .danger)
                        Button(loading || refreshing ? "重试中…" : "再试一次") {
                            guard !loading && !refreshing else { return }
                            Task { await pullSheet(force: true) }
                        }
                        .buttonStyle(.secondaryCompact)
                        .disabled(loading || refreshing)
                        .accessibilityIdentifier("hot-sheet-retry")
                    }
                    .listRowSeparator(.hidden)
                }
                if !sheetFail.isEmpty {
                    Text(sheetFail).font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.danger)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("hot-sheet-talk-fail")
                }
                if section == 0 {
                    if topics.isEmpty && loadedOnce && !loading {
                        Text(loadFail.isEmpty
                             ? "这会儿全表还没有热点事件——可下拉或点右上角重抓。"
                             : "全表还没读上——先重试；通了我再开口列事件。")
                            .font(TypeScale.subheadline).foregroundStyle(Palette.textTertiary)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier(loadFail.isEmpty ? "hot-sheet-empty" : "hot-sheet-empty-fail")
                    }
                    ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                        HotTopicRow(topic: topic, rank: index + 1).listRowInsets(EdgeInsets())
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.sm) {
                            chip("全部", "")
                            ForEach(data["categories"].object.keys.sorted(), id: \.self) { key in chip(data["categories"][key].string, key) }
                        }
                    }.listRowSeparator(.hidden)
                    if items.isEmpty && loadedOnce && !loading {
                        Text(loadFail.isEmpty
                             ? "这会儿没有精选条目——可换分类或重抓。"
                             : "精选还没读上——先重试；通了我再开口。")
                            .font(TypeScale.subheadline).foregroundStyle(Palette.textTertiary)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier(loadFail.isEmpty ? "hot-sheet-items-empty" : "hot-sheet-items-empty-fail")
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        let title = item["title"].string
                        Button { if let url = URL(string: item["url"].string) { openURL(url) } } label: {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(title).font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                                if !item["summary"].string.isEmpty {
                                    Text(item["summary"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(3)
                                }
                                Text([item["category_label"].string, item["source"].string, HotTime.ago(item["published_at"].string)].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
                                if talkingTitle == title {
                                    Text("正在交给 Com…").font(TypeScale.caption).foregroundStyle(Palette.textSecondary)
                                }
                            }.padding(.vertical, Space.xs)
                        }
                        .buttonStyle(.plain)
                        .disabled(talkingTitle != nil)
                        .contextMenu {
                            Button {
                                guard talkingTitle == nil else { return }
                                talkingTitle = title
                                sheetFail = ""
                                Task {
                                    // 送达成功才关热点表；失败留列表 + 页头提示可重试。
                                    let ok = await model.askAboutHot(title)
                                    talkingTitle = nil
                                    if ok {
                                        dismiss()
                                    } else {
                                        sheetFail = "没送出去，列表还在——可再让我讲讲"
                                    }
                                }
                            } label: {
                                Label(talkingTitle == title ? "讲讲中…" : "让 Com 讲讲", systemImage: "bubble.left")
                            }
                            .disabled(talkingTitle != nil)
                        }
                    }
                }
                Text("来源 AIHOT（aihot.news）" + (data["stale"].bool ? " · 暂时连不上，先看上次抓到的" : ""))
                    .font(TypeScale.caption).foregroundStyle(Palette.textTertiary).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .refreshable { await pullSheet(force: true) }
            .task { await pullSheet(force: false) }
            .navigationTitle("AI 热点").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard !loading && !refreshing else { return }
                        refreshing = true
                        Task {
                            await pullSheet(force: true)
                            refreshing = false
                        }
                    } label: {
                        if refreshing || loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(refreshing || loading).accessibilityLabel("重新抓取热点")
                    .accessibilityIdentifier("hot-sheet-refresh")
                }
            }
        }
    }
    private func pullSheet(force: Bool) async {
        guard !loading else { return }
        loading = true
        if force { loadFail = "" }
        defer {
            loading = false
            loadedOnce = true
        }
        if await model.refreshHot(force: force) {
            loadFail = ""
            return
        }
        let err = model.errors[AppModel.hotPath] ?? model.errors[AppModel.hotPath + "?refresh=1"] ?? ""
        let had = !model.hotData["topics"].array.isEmpty || !model.hotData["items"].array.isEmpty
        loadFail = err.isEmpty
            ? (had ? "热点全表没刷新上——下面仍是上一版，可再试" : "热点全表没拉齐——检查配对或网络后再试")
            : (had ? "热点全表没刷新上：" + err + "——下面仍是上一版" : "热点全表没拉齐：" + err + "——可再试")
    }
    private func chip(_ title: String, _ key: String) -> some View {
        Button(title) { category = key }
            .font(TypeScale.footnote.weight(.medium)).foregroundStyle(category == key ? Palette.background : Palette.textPrimary)
            .padding(.horizontal, Space.md).frame(height: 30)
            .background(category == key ? Palette.textPrimary : Palette.fill, in: .capsule)
            .buttonStyle(.plain)
    }
}

enum HotTime {
    static func ago(_ iso: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let minutes = Int(-date.timeIntervalSinceNow / 60)
        if minutes < 60 { return "\(max(1, minutes)) 分钟前" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小时前" }
        return "\(minutes / 1440) 天前"
    }
}
