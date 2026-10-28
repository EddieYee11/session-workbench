import SwiftUI
import ComCore

// 热点板块（10-28）：AIHOT 的多源热点事件 + 24 小时精选。
// 数据：/personal/hot（backend/aihot.py，15 分钟缓存；?refresh=1 强制重抓）。
// 今天页放前 5 条热点，「全部」进完整列表；点条目开 AIHOT 阅读页，「让 Com 讲讲」把来龙去脉交给对话。

extension AppModel {
    static let hotPath = "/personal/hot"
    var hotData: JSON { datasets[AppModel.hotPath] ?? .null }
    func refreshHot(force: Bool = false) async {
        guard force, let data = await load(AppModel.hotPath + "?refresh=1") else { _ = await load(AppModel.hotPath); return }
        datasets[AppModel.hotPath] = data
    }
    func askAboutHot(_ title: String) async {
        tab = .chat
        await send(textOverride: "用 AIHOT 讲讲「\(title)」的来龙去脉，和我有什么关系？")
    }
}

struct HotBoardCard: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false
    var body: some View {
        let topics = model.hotData["topics"].array
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI 热点").font(TypeScale.section).accessibilityAddTraits(.isHeader)
                Text("AIHOT").font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
                if !topics.isEmpty {
                    Button("全部") { showAll = true }.font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier("hot-all")
                }
            }
            if topics.isEmpty {
                Text(model.hotData.isNull ? "正在读 AI 圈的热点…" : "暂时没读到热点，下拉刷新再试。")
                    .font(TypeScale.subheadline).foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(topics.prefix(5).enumerated()), id: \.offset) { index, topic in
                        if index > 0 { Divider().padding(.leading, 44) }
                        HotTopicRow(topic: topic, rank: index + 1)
                    }
                }
                .padding(.vertical, Space.xs)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                .elevation(.raised)
            }
        }
        .task { if model.hotData.isNull { await model.refreshHot() } }
        .sheet(isPresented: $showAll) { HotBoardSheet() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-hot")
    }
}

private struct HotTopicRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let topic: JSON
    let rank: Int
    var body: some View {
        Button { if let url = URL(string: topic["url"].string) { openURL(url) } } label: {
            HStack(alignment: .top, spacing: Space.md) {
                Text("\(rank)").font(TypeScale.callout.weight(.bold)).monospacedDigit()
                    .foregroundStyle(rank <= 3 ? TodayHue.pink.ink : Palette.textTertiary).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(topic["title"].string).font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Text("\(topic["source_count"].int) 个信源 · " + HotTime.ago(topic["latest_at"].string))
                        .font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm + 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { Task { await model.askAboutHot(topic["title"].string) } } label: { Label("让 Com 讲讲", systemImage: "bubble.left") }
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
    var body: some View {
        let data = model.hotData
        let items = data["items"].array.filter { category.isEmpty || $0["category"].string == category }
        NavigationStack {
            List {
                Picker("板块", selection: $section) { Text("热点事件").tag(0); Text("24 小时精选").tag(1) }
                    .pickerStyle(.segmented).listRowSeparator(.hidden)
                if section == 0 {
                    ForEach(Array(data["topics"].array.enumerated()), id: \.offset) { index, topic in
                        HotTopicRow(topic: topic, rank: index + 1).listRowInsets(EdgeInsets())
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.sm) {
                            chip("全部", "")
                            ForEach(data["categories"].object.keys.sorted(), id: \.self) { key in chip(data["categories"][key].string, key) }
                        }
                    }.listRowSeparator(.hidden)
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Button { if let url = URL(string: item["url"].string) { openURL(url) } } label: {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(item["title"].string).font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                                if !item["summary"].string.isEmpty {
                                    Text(item["summary"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(3)
                                }
                                Text([item["category_label"].string, item["source"].string, HotTime.ago(item["published_at"].string)].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
                            }.padding(.vertical, Space.xs)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button { dismiss(); Task { await model.askAboutHot(item["title"].string) } } label: { Label("让 Com 讲讲", systemImage: "bubble.left") } }
                    }
                }
                Text("数据来源 AIHOT（aihot.news）" + (data["stale"].bool ? " · 暂时连不上，显示的是上次的结果" : ""))
                    .font(TypeScale.caption).foregroundStyle(Palette.textTertiary).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .refreshable { await model.refreshHot(force: true) }
            .navigationTitle("AI 热点").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { refreshing = true; Task { await model.refreshHot(force: true); refreshing = false } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(refreshing).accessibilityLabel("重新抓取热点")
                }
            }
        }
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
