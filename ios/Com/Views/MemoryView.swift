import SwiftUI
import ComCore

// 轨道 r2-memory：记忆页改成「磨砂文件夹网格」（参考 Invoices：大标题 + 下拉、筛选胶囊、两列玻璃文件夹，
// 文件夹后面露出几张带状态角标的纸片，右下角一枚贴纸，下面是名称 + 数量；底部 Grid/List 玻璃切换 + 搜索圆钮）。
//
// 动效对照动效库（work/内容生产/动效库/）：
// - 04-screenshot-cascade 截图层叠飞入：文件夹网格、文件夹里的纸片都按「同一条减速曲线、起飞时间整齐错 2 帧（≈67ms）」从下方甩上来落定。
//   原片实测前段比 power4 慢、后段比 expo 快，这里用 timingCurve(0.16, 1, 0.3, 1) 近似。
// - 09-float-card-3d 3D 浮卡：纸片落定前带一点绕 X 轴的透视倾角（14° → 0），按下文件夹时整只轻轻后仰、纸片往上探。
// - 03-badge-stamp 徽章盖章：右下角贴纸从 1.7 倍、-24° 甩进来摊平到 -8°（原片徽章最终 -8.7°）。
// - 13-leaderboard-counter 数字爬升：切换筛选时数量徽标用 numericText 滚动。
// - 05-tweet-highlight 荧光笔扫入：「最近自动学到」提示里的数字下面一道青柠高亮从左扫入（原片 10 帧，前 1 帧几乎不动、2–4 帧冲掉 40%）。
// 所有位移在 reduce motion 下退成纯淡入；没有 TimelineView / Canvas 逐帧重绘。
//
// 轨道 r3-memory：文件夹面上原来是 `folder.name.prefix(1)`——代码本意是「一笔手写缩写」，所以只露出「生」「关」「工」一个字。
// 现在面上印分类英文（LIFE / ABOUT ME / WORK…），下面的中文升成标题，中英各说一次不重复。
// 待你过目的纸片重做了三个按钮和结果动效，动效库对照写在「自动记忆」那一节。

/// 记忆按用途放进文件夹：首页是文件夹网格，点进文件夹是纸片明细，再点是单条。三层都在同一个导航栈里推进。
enum MemoryRoute: Hashable { case folder(String), item(String), learned }

struct MemoryFolder: Identifiable {
    let name: String
    let blurb: String
    var id: String { name }
    var symbol: String { memoryFolderStyle(name).symbol }
    var tint: Color { memoryFolderStyle(name).tint }
    var word: String { memoryFolderWord(name) }
}

/// 文件夹面上印的英文（轨道 r3-memory）：按分类映射，后端以后冒出来的新分类统一印 NOTES。
func memoryFolderWord(_ name: String) -> String {
    switch name {
    case "关于我": "ABOUT\nME"
    case "工作": "WORK"
    case "创作": "CREATIVE"
    case "技能": "SKILLS"
    case "设备": "DEVICES"
    case "项目": "PROJECTS"
    case "生活": "LIFE"
    case "财务": "MONEY"
    case "健康": "HEALTH"
    case "兴趣": "HOBBIES"
    case "人物关系", "人物": "PEOPLE"
    case "偏好": "TASTE"
    case "习惯": "HABITS"
    default: "NOTES"
    }
}

func memoryFolderStyle(_ name: String) -> (symbol: String, tint: Color) {
    switch name {
    case "关于我": ("person.crop.circle.fill", Color(red: 0.42, green: 0.55, blue: 0.10))
    case "工作": ("briefcase.fill", Palette.info)
    case "创作": ("video.fill", Palette.coral)
    case "技能": ("wrench.and.screwdriver.fill", Color(red: 0.55, green: 0.33, blue: 0.95))
    case "设备": ("desktopcomputer", Color(red: 0.20, green: 0.55, blue: 0.60))
    case "项目": ("square.stack.3d.up.fill", Color(red: 0.86, green: 0.55, blue: 0.08))
    case "财务": ("yensign", Color(red: 0.18, green: 0.60, blue: 0.35))
    case "人物关系", "人物": ("person.2.fill", Color(red: 0.85, green: 0.38, blue: 0.55))
    case "偏好": ("heart.fill", Color(red: 0.90, green: 0.36, blue: 0.40))
    case "习惯": ("repeat", Color(red: 0.25, green: 0.50, blue: 0.85))
    default: ("leaf.fill", Palette.success)
    }
}

/// 旧后端没有 folder/preview/title 时在这里兜底，保证新旧版本都能看。
extension JSON {
    var memoryFolder: String {
        if !self["folder"].string.isEmpty { return self["folder"].string }
        let category = self["category"].string
        return ["兴趣": "生活", "健康": "生活", "财务": "生活"][category] ?? (category.isEmpty ? "生活" : category)
    }
    var memoryTitle: String {
        if !self["title"].string.isEmpty { return self["title"].string }
        let first = memoryPreview.split(whereSeparator: { "。；！？\n".contains($0) }).first.map(String.init) ?? ""
        return first.count > 24 ? String(first.prefix(23)) + "…" : first
    }
    var memoryPreview: String {
        if !self["preview"].string.isEmpty { return self["preview"].string }
        let raw = self["summary"].string.isEmpty ? self["content"].string : self["summary"].string
        return raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).trimmingPrefix(while: { "-*#> ".contains($0) }) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    var memoryKindLabel: String { self["read_only"].bool || self["kind"].string == "knowledge" ? "共享知识" : "对话中记住" }
}

private let defaultFolders: [MemoryFolder] = [
    .init(name: "关于我", blurb: "身份、称呼和协作偏好"), .init(name: "工作", blurb: "搜狐、求职与职业发展"),
    .init(name: "创作", blurb: "视频号、素材与发布口径"), .init(name: "技能", blurb: "自动化、工程与排障方法"),
    .init(name: "设备", blurb: "电脑、手机、NAS 与网络"), .init(name: "项目", blurb: "Agent 系统与在做的工程"),
    .init(name: "生活", blurb: "记账、提醒、健康与兴趣"),
]

// MARK: - 纸片：一条记忆 / 一条待确认

/// 纸片角标：自动学到 = 青柠勾、待确认 = 琥珀点、已纠正 = 蓝笔、共享知识 = 灰文档、对话中记住 = 无色。
enum PaperMark: String {
    case learned, pending, corrected, shared, plain
    var symbol: String {
        switch self { case .learned: "checkmark"; case .pending: "circle.fill"; case .corrected: "pencil"; case .shared: "doc.text"; case .plain: "bubble.left" }
    }
    var label: String {
        switch self { case .learned: "自动学到"; case .pending: "待确认"; case .corrected: "已纠正"; case .shared: "共享知识"; case .plain: "对话中记住" }
    }
    var badge: Color {
        switch self { case .learned: Palette.accent; case .pending: Color(red: 1.0, green: 0.74, blue: 0.22); case .corrected: Palette.info; case .shared: Color(white: 0.62); case .plain: Color(white: 0.80) }
    }
    var glyph: Color { self == .learned ? Palette.onAccent : .white }
    /// 纸面颜色：待确认是暖黄便签，已纠正淡蓝，其余白纸。
    var paper: Color {
        switch self {
        case .pending: Color(red: 1.0, green: 0.93, blue: 0.70)
        case .corrected: Color(red: 0.88, green: 0.93, blue: 1.0)
        default: Color(white: 0.985)
        }
    }
}

struct MemoryPaper: Identifiable {
    let id: String
    let title: String
    let folder: String
    let mark: PaperMark
    let updated: Double
    let value: JSON
    var isPending: Bool { mark == .pending }

    static func build(items: [JSON], inbox: JSON?) -> [MemoryPaper] {
        let learnedIDs = Set((inbox?["learned"].array ?? []).map { $0["memory_id"].string }.filter { !$0.isEmpty })
        var out = items.map { item -> MemoryPaper in
            let mark: PaperMark =
                item["read_only"].bool || item["kind"].string == "knowledge" ? .shared
                : (item["version"].int > 1 || !item["history"].array.isEmpty) ? .corrected
                : (item["source"]["type"].string == "auto_learned" || learnedIDs.contains(item.id)) ? .learned
                : .plain
            return MemoryPaper(id: item.id, title: item.memoryTitle, folder: item.memoryFolder, mark: mark, updated: item["updated_at"].double, value: item)
        }
        for item in inbox?["pending"].array ?? [] {
            out.append(MemoryPaper(id: item.id, title: item["content"].string, folder: item.memoryFolder, mark: .pending, updated: item["created_at"].double, value: item))
        }
        return out.sorted { $0.updated > $1.updated }
    }
}

enum MemoryFilter: String, CaseIterable {
    case all = "全部", learned = "自动学到", pending = "待确认"
    func keeps(_ paper: MemoryPaper) -> Bool {
        switch self { case .all: true; case .learned: paper.mark == .learned; case .pending: paper.isPending }
    }
}

/// 动效库 04 的减速曲线：前段比 power4 慢、后段比 expo 快。
enum MemoryMotion {
    static let cascade = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.6)
    /// 04 卡片起飞间隔 2 帧 @30fps。
    static let stagger = 2.0 / 30.0
    /// 05 荧光笔扫入：10 帧、慢起急冲长尾。
    static let highlight = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 10.0 / 30.0)
    static let stamp = Animation.spring(response: 0.36, dampingFraction: 0.58)
}

/// 04 截图层叠 + 09 浮卡：从下方带透视倾角甩上来落定。
private struct CascadeIn: ViewModifier {
    let index: Int
    let shown: Bool
    var distance: CGFloat = 38
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : distance)
            .rotation3DEffect(.degrees(shown || reduce ? 0 : 14), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.55)
            .animation(reduce ? .easeOut(duration: 0.2) : MemoryMotion.cascade.delay(Double(min(index, 12)) * MemoryMotion.stagger), value: shown)
    }
}

// MARK: - 首页

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var searching = false
    @State private var filter: MemoryFilter = .all
    @State private var appeared = false
    @AppStorage("memory.layout") private var layout = "grid"
    @AppStorage("memory.sort") private var sort = "recent"
    @FocusState private var searchFocused: Bool
    @Namespace private var zoom
    @Namespace private var bar
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 待你过目的纸片在本地的过场与撤销（轨道 r3-memory），文件夹页和「自动记忆」页共用这一份。
    @State private var review = MemoryReview()
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false

    private var items: [JSON] { model.datasets["/personal/memory"]?["items"].array ?? [] }
    private var folders: [MemoryFolder] {
        let remote = model.datasets["/personal/memory"]?["folders"].array.map { MemoryFolder(name: $0["name"].string, blurb: $0["blurb"].string) } ?? []
        let list = remote.isEmpty ? defaultFolders : remote
        // 后端以后新加的文件夹、或旧数据里冒出来的分类，也要有地方放。
        let extra = Set(items.map(\.memoryFolder)).subtracting(list.map(\.name)).sorted().map { MemoryFolder(name: $0, blurb: "") }
        return list + extra
    }
    private var pulling: Bool { model.memoryOpening || loading || !loadedOnce }

    var body: some View {
        let papers = MemoryPaper.build(items: items, inbox: model.datasets[AppModel.memoryInboxPath]).filter { !review.hidden.contains($0.id) }
        let shown = papers.filter(filter.keeps)
        let grouped = Dictionary(grouping: shown, by: \.folder)
        // 验收修正（r2-review-memory）：空文件夹不占格子——参考图里每只文件夹都有纸，留白给有内容的类。
        let visible = sorted(folders.filter { !(grouped[$0.name] ?? []).isEmpty }, grouped: grouped)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                header(total: papers.count)
                if pulling {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在拉齐记忆…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    .accessibilityLabel("正在拉齐记忆")
                    .accessibilityIdentifier("memory-pulling")
                }
                if !failNote.isEmpty {
                    InlineNotice(text: failNote, tone: .danger)
                    Button(loading || model.memoryOpening ? "重试中…" : "再试一次") {
                        guard !loading, !model.memoryOpening else { return }
                        Task { await refreshMemory(force: true) }
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(loading || model.memoryOpening)
                    .accessibilityIdentifier("memory-retry")
                }
                FilterChips(options: MemoryFilter.allCases.map(\.rawValue), selection: Binding(get: { filter.rawValue }, set: { filter = MemoryFilter(rawValue: $0) ?? .all }),
                            animation: reduce ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86), haptic: true)
                if searching {
                    HStack(spacing: Space.sm) {
                        SearchField(text: $search, prompt: "搜索记忆").focused($searchFocused)
                        Button("取消") { closeSearch() }.buttonStyle(.quiet)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !search.isEmpty {
                    results
                } else {
                    LearnedTip()
                    if visible.isEmpty {
                        EmptyState(title: !failNote.isEmpty ? "记忆还没读上"
                                       : filter == .pending ? "眼下没有要你点头的"
                                       : filter == .learned ? "还没自动学到新东西" : "记忆还是空的",
                                   description: !failNote.isEmpty
                                   ? "先重试拉齐；通了会出现文件夹和待确认纸片。"
                                   : filter == .pending
                                   ? "聊到新的偏好或习惯时，我会先放在这里请你点头——对了再收进长期记忆，不对就纠正我。"
                                   : filter == .learned
                                   ? "对话里浮现的习惯和偏好，你点头确认后会出现在这里。"
                                   : "跟我说你的偏好、习惯或在做的事——我记下后会出现在这里，也可以随时改。",
                                   symbol: "checkmark.circle")
                    } else if layout == "grid" {
                        grid(visible, grouped: grouped)
                    } else {
                        list(visible, grouped: grouped)
                    }
                    // 验收修正（r2-review-memory）：去掉底部统计脚注——和标题旁「N 条」口径不一（是否含待确认），且非必要。
                }
            }
            .padding(.horizontal, Layout.margin).padding(.top, Space.xs).padding(.bottom, 96)
            .animation(reduce ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.86), value: filter)
            .animation(reduce ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.88), value: layout)
            .animation(.smooth(duration: 0.25), value: searching)
        }
        .background(Palette.background)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        // 大标题画在内容里（带下拉），系统标题让位。
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
        .navigationDestination(for: MemoryRoute.self) { route in
            Group {
                switch route {
                case .folder(let name):
                    MemoryFolderView(folder: folders.first { $0.name == name } ?? .init(name: name, blurb: ""), initial: filter)
                        .navigationTransition(.zoom(sourceID: "folder-" + name, in: zoom))
                case .learned:
                    LearnedMemoryView()
                case .item(let id):
                    if let memory = items.first(where: { $0.id == id }) { MemoryDetailView(memory: memory) }
                    else { EmptyState(title: "这条记忆不在了", description: "可能刚被整理或归档，返回刷新一下。", symbol: "questionmark.folder").padding(Layout.margin) }
                }
            }
            .environment(review)
        }
        .environment(review)
        .refreshable { await refreshMemory(force: true) }
        .task {
            #if DEBUG
            model.seedR3MemoryPreview()
            #endif
            await refreshMemory(force: false)
        }
        .onAppear { appeared = true }
    }

    private func refreshMemory(force: Bool) async {
        guard !loading else { return }
        loading = true
        if force { failNote = "" }
        defer {
            loading = false
            loadedOnce = true
        }
        let memPath = "/personal/memory"
        let inboxPath = AppModel.memoryInboxPath
        let gotMem: Bool
        let gotInbox: Bool
        // 与 openMemory 同路：入口已在拉则等它结束，避免叠刷。
        if model.memoryOpening && !force {
            while model.memoryOpening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
            }
            gotMem = model.errors[memPath] == nil && model.datasets[memPath] != nil
            gotInbox = model.errors[inboxPath] == nil && model.datasets[inboxPath] != nil
        } else {
            async let mem = model.load(memPath)
            async let inbox: Void = model.loadMemoryInbox()
            gotMem = await mem != nil
            await inbox
            gotInbox = model.errors[inboxPath] == nil && model.datasets[inboxPath] != nil
        }
        if gotMem && gotInbox {
            failNote = ""
            model.memoryOpenNote = ""
            return
        }
        let memErr = model.errors[memPath] ?? ""
        let inboxErr = model.errors[inboxPath] ?? ""
        let hadCache = !(model.datasets[memPath]?["items"].array ?? []).isEmpty
        if !gotMem && !gotInbox {
            let err = [memErr, inboxErr].first { !$0.isEmpty } ?? ""
            failNote = err.isEmpty
                ? (hadCache ? "记忆没刷新上——下面仍是上一版，可再试" : "记忆还没拉齐——检查配对或网络后再试")
                : (hadCache ? "记忆没刷新上：" + err + "——下面仍是上一版" : "记忆没拉齐：" + err + "——可再试")
        } else if !gotMem {
            failNote = memErr.isEmpty
                ? (hadCache ? "记忆列表没刷新上——待确认若在仍可先看；可再试" : "记忆列表没读上——可再试")
                : "记忆列表没读上：" + memErr + "——可再试"
        } else {
            failNote = inboxErr.isEmpty
                ? "待确认收件箱没读上——长期记忆若在仍可先看；可再试"
                : "待确认没读上：" + inboxErr + "——可再试"
        }
    }

    private func sorted(_ list: [MemoryFolder], grouped: [String: [MemoryPaper]]) -> [MemoryFolder] {
        switch sort {
        case "count": list.sorted { (grouped[$0.name]?.count ?? 0) > (grouped[$1.name]?.count ?? 0) }
        case "name": list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        default: list.sorted { (grouped[$0.name]?.first?.updated ?? 0) > (grouped[$1.name]?.first?.updated ?? 0) }
        }
    }

    /// 大标题 + 下拉（排序方式），参考图的「Invoices ⌄」。
    private func header(total: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Menu {
                Picker("排序", selection: $sort) {
                    Label("最近更新在前", systemImage: "clock").tag("recent")
                    Label("条数多的在前", systemImage: "number").tag("count")
                    Label("按名称", systemImage: "textformat").tag("name")
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("记忆").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Palette.textPrimary)
                    Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                }
            }
            .accessibilityIdentifier("memory-sort")
            .accessibilityLabel("记忆，排序方式")
            Spacer(minLength: 0)
            if model.memoryOpening {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("拉齐中…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                .accessibilityLabel("正在拉齐记忆")
            } else {
                Text("\(total) 条").font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                    .contentTransition(.numericText())
            }
        }
    }

    private func grid(_ list: [MemoryFolder], grouped: [String: [MemoryPaper]]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.lg), GridItem(.flexible(), spacing: Space.lg)], spacing: Space.xl) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, folder in
                let inside = grouped[folder.name] ?? []
                NavigationLink(value: MemoryRoute.folder(folder.name)) {
                    FolderTile(folder: folder, papers: Array(inside.prefix(3)), count: inside.count, index: index, shown: appeared)
                }
                .buttonStyle(FolderPress())
                .matchedTransitionSource(id: "folder-" + folder.name, in: zoom) { $0.clipShape(.rect(cornerRadius: Radius.lg, style: .continuous)) }
                .accessibilityIdentifier("memory-folder-" + folder.name)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private func list(_ list: [MemoryFolder], grouped: [String: [MemoryPaper]]) -> some View {
        GroupedCard(dividerInset: 68) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, folder in
                let inside = grouped[folder.name] ?? []
                NavigationLink(value: MemoryRoute.folder(folder.name)) {
                    HStack(spacing: Space.md) {
                        FolderSticker(folder: folder, size: 40, shown: appeared, delay: Double(index) * MemoryMotion.stagger)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(folder.name).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary)
                            Text(inside.first?.title ?? (folder.blurb.isEmpty ? "还没有内容" : folder.blurb))
                                .font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        FolderCountBadge(count: inside.count)
                        Chevron()
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
                    .contentShape(.rect)
                }
                .buttonStyle(.row)
                .modifier(CascadeIn(index: index, shown: appeared, distance: 18))
                .matchedTransitionSource(id: "folder-" + folder.name, in: zoom)
                .accessibilityIdentifier("memory-folder-" + folder.name)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    @ViewBuilder private var results: some View {
        let found = items.filter { $0["content"].string.localizedCaseInsensitiveContains(search) || $0.memoryTitle.localizedCaseInsensitiveContains(search) }
        if found.isEmpty {
            EmptyState(title: "没翻到「\(search)」", description: "换个词试试，或到文件夹里逛一圈——我可能用了另一个说法记下。", symbol: "sparkles.rectangle.stack")
        } else {
            GroupSection("找到 \(found.count) 条") {
                GroupedCard(dividerInset: Layout.rowInset) {
                    ForEach(found.map(RemoteRow.init)) { row in MemoryRow(memory: row.value, showFolder: true) }
                }
            }
        }
    }

    /// 底部玻璃：Grid / List 切换 + 搜索圆钮（参考图底栏）。
    private var bottomBar: some View {
        HStack {
            GlassEffectContainer {
                HStack(spacing: 2) {
                    layoutButton("grid", title: "网格", symbol: "square.grid.2x2")
                    layoutButton("list", title: "列表", symbol: "list.bullet.rectangle")
                }
                .padding(4)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            Spacer(minLength: 0)
            Button { searching ? closeSearch() : openSearch() } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary).frame(width: 54, height: 54)
                    .contentShape(.circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(searching ? "收起搜索" : "搜索记忆")
            .accessibilityIdentifier("memory-search")
        }
        .padding(.horizontal, Layout.margin).padding(.bottom, Space.sm).padding(.top, Space.xs)
        .sensoryFeedback(.selection, trigger: layout)
    }

    private func layoutButton(_ value: String, title: String, symbol: String) -> some View {
        let selected = layout == value
        return Button { withAnimation(reduce ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82)) { layout = value } } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
            .frame(width: 64, height: 46)
            .background {
                if selected { Capsule().fill(Palette.fill.opacity(0.9)).matchedGeometryEffect(id: "layout", in: bar) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memory-layout-" + value)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func openSearch() {
        withAnimation(.smooth(duration: 0.25)) { searching = true }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); searchFocused = true }
    }
    private func closeSearch() {
        search = ""; searchFocused = false
        withAnimation(.smooth(duration: 0.25)) { searching = false }
    }
}

// MARK: - 文件夹卡

/// 磨砂玻璃文件夹的外形：左上一枚页签，斜坡接到主体。
struct FolderShape: Shape {
    var tabWidth: CGFloat = 0.44
    var tabHeight: CGFloat = 12
    var radius: CGFloat = 20
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = rect.minY + tabHeight, tw = rect.minX + rect.width * tabWidth
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + 10, y: rect.minY), radius: 14)
        p.addLine(to: CGPoint(x: tw - 16, y: rect.minY))
        p.addCurve(to: CGPoint(x: tw + 8, y: top), control1: CGPoint(x: tw - 4, y: rect.minY), control2: CGPoint(x: tw - 4, y: top))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top + 10), radius: radius)
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - 10, y: rect.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - 10), radius: radius)
        p.closeSubpath()
        return p
    }
}

/// 一只文件夹：后面露出最近几张纸片，前面磨砂玻璃（面上印英文），右下角贴纸；下面中文标题 + 数量。
private struct FolderTile: View {
    let folder: MemoryFolder
    let papers: [MemoryPaper]
    let count: Int
    let index: Int
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm + 2) {
            ZStack(alignment: .top) {
                // 纸片：从文件夹里探出来（04 层叠，比文件夹晚 0.12s 起飞，彼此再错 2 帧）。
                ForEach(Array(papers.enumerated().reversed()), id: \.element.id) { i, paper in
                    PaperSlip(mark: paper.mark)
                        .frame(width: 62, height: 74)
                        .rotationEffect(.degrees([-7, 3, 10][i]), anchor: .bottom)
                        .offset(x: [-38, -4, 28][i], y: shown || reduce ? [2, -4, 5][i] : 40)
                        .opacity(shown ? 1 : 0)
                        .animation(reduce ? .easeOut(duration: 0.2) : MemoryMotion.cascade.delay(Double(min(index, 12)) * MemoryMotion.stagger + 0.12 + Double(i) * MemoryMotion.stagger), value: shown)
                }
                .frame(maxWidth: .infinity)
                FolderFace(folder: folder, shown: shown, delay: Double(min(index, 12)) * MemoryMotion.stagger + 0.22)
                    .padding(.top, 32)
            }
            // 轨道 r3-memory：原来的小字升成标题（15 → 20 圆体），条数跟在旁边。
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(folder.name).font(TypeScale.section).foregroundStyle(Palette.textPrimary).lineLimit(1)
                FolderCountBadge(count: count)
            }
            .padding(.leading, Space.xs)
        }
        .modifier(CascadeIn(index: index, shown: shown))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name)，\(count) 条")
    }
}

/// 文件夹正面：磨砂玻璃 + 分类色，左上印英文，右下贴纸。网格里那只、纸片收进去时接住它的那只都用这一个（轨道 r3-memory 抽出来）。
private struct FolderFace: View {
    let folder: MemoryFolder
    var height: CGFloat = 118
    var wordSize: CGFloat = 32
    var stickerSize: CGFloat = 46
    var shown = true
    var delay: Double = 0
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        FolderShape()
            .fill(.ultraThinMaterial)
            .overlay(FolderShape().fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.06 : 0.42), folder.tint.opacity(scheme == .dark ? 0.10 : 0.06)], startPoint: .top, endPoint: .bottom)))
            .overlay(FolderShape().stroke(Color.white.opacity(scheme == .dark ? 0.16 : 0.85), lineWidth: 0.8))
            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.07), radius: 14, y: 6)
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                FolderWord(word: folder.word, tint: folder.tint, size: wordSize)
                    .padding(.top, 12 + wordSize * 0.3).padding(.leading, Space.md + 2).padding(.trailing, Space.md)
            }
            .overlay(alignment: .bottomTrailing) {
                FolderSticker(folder: folder, size: stickerSize, shown: shown, delay: delay)
                    .padding(stickerSize * 0.26)
            }
    }
}

/// 面上的英文：压缩黑体大写，像杂志栏目名印在文件夹上；ABOUT ME 断成两行、行距收紧，长词等比缩小、不截断。
private struct FolderWord: View {
    let word: String
    let tint: Color
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: -size * 0.2) {
            ForEach(Array(word.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                Text(line).lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .font(.system(size: size, weight: .black).width(.compressed))
        .tracking(size * 0.03)
        .foregroundStyle(tint.mix(with: .black, by: scheme == .dark ? 0 : 0.12).opacity(scheme == .dark ? 0.92 : 0.88))
        .accessibilityHidden(true)
    }
}

/// 一张小纸片：左上角带状态角标，纸面是两三道灰线。
private struct PaperSlip: View {
    let mark: PaperMark
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(mark.paper)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    MarkBadge(mark: mark, size: 15)
                    Capsule().fill(Color.black.opacity(0.10)).frame(width: 34, height: 3)
                    Capsule().fill(Color.black.opacity(0.07)).frame(width: 26, height: 3)
                }
                .padding(7)
            }
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

/// 状态角标：圆里一个小符号。
struct MarkBadge: View {
    let mark: PaperMark
    var size: CGFloat = 16
    var body: some View {
        Image(systemName: mark.symbol)
            .font(.system(size: mark == .pending ? size * 0.32 : size * 0.52, weight: .bold))
            .foregroundStyle(mark.glyph)
            .frame(width: size, height: size)
            .background(mark.badge, in: .circle)
            .accessibilityHidden(true)
    }
}

/// 贴纸：白描边的圆角块，微微歪着贴（03 徽章盖章：1.7 倍、-24° 甩进来摊平到 -8°）。
struct FolderSticker: View {
    let folder: MemoryFolder
    var size: CGFloat = 46
    var shown = true
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        Image(systemName: folder.symbol)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(folder.tint.gradient, in: .rect(cornerRadius: size * 0.3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white, lineWidth: max(2, size * 0.065)))
            .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
            .rotationEffect(.degrees(shown || reduce ? -8 : -24))
            .scaleEffect(shown || reduce ? 1 : 1.7)
            .opacity(shown ? 1 : 0)
            .animation(reduce ? .easeOut(duration: 0.2) : MemoryMotion.stamp.delay(delay), value: shown)
            .accessibilityHidden(true)
    }
}

/// 数量徽标：切换筛选时数字滚动（13 数字爬升）。
private struct FolderCountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(count == 0 ? Palette.textTertiary : Palette.textSecondary)
            .contentTransition(.numericText(value: Double(count)))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Palette.fill, in: .capsule)
    }
}

/// 按下文件夹：整只轻轻后仰（09 浮卡的透视姿态），松手弹回。
private struct FolderPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduce ? 0.96 : 1)
            .rotation3DEffect(.degrees(configuration.isPressed && !reduce ? 8 : 0), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.5)
            .animation(.spring(response: 0.28, dampingFraction: 0.66), value: configuration.isPressed)
    }
}

// MARK: - 最近自动学到：一条轻提示

/// 不再占大块：一行玻璃提示，点开是二级页（确认 / 纠正 / 删除 / 批准都在那里）。
private struct LearnedTip: View {
    @Environment(AppModel.self) private var model
    @Environment(MemoryReview.self) private var review
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.colorScheme) private var scheme
    @State private var swept = false
    var body: some View {
        let inbox = model.datasets[AppModel.memoryInboxPath]
        let learned = (inbox?["learned"].array ?? []).filter { !review.hidden.contains($0.id) }.count
        let pending = (inbox?["pending"].array ?? []).filter { !review.hidden.contains($0.id) }.count
        if learned + pending > 0 {
            NavigationLink(value: MemoryRoute.learned) {
                HStack(spacing: Space.sm) {
                    MarkBadge(mark: learned > 0 ? .learned : .pending, size: 20)
                    HStack(spacing: 0) {
                        Text(learned > 0 ? "最近自动学到 " : "")
                        if learned > 0 {
                            // 05 荧光笔：数字下面一道青柠从左扫入。
                            Text("\(learned) 条").fontWeight(.semibold)
                                .background(alignment: .leading) {
                                    Rectangle().fill(Palette.accent.opacity(scheme == .dark ? 0.32 : 0.75)).frame(height: 9).offset(y: 4)
                                        .scaleEffect(x: swept || reduce ? 1 : 0, anchor: .leading)
                                }
                        }
                        if pending > 0 {
                            Text(learned > 0 ? " · " : "")
                            Text(pending == 1 ? "有 1 条想请你点头" : "\(pending) 条想请你点头")
                                .fontWeight(.semibold).foregroundStyle(Palette.warning)
                        }
                    }
                    .font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    Chevron()
                }
                .padding(.horizontal, Space.md).padding(.vertical, Space.sm + 2)
                .background(Palette.surface.opacity(0.7), in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 0.5))
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memory-learned-all")
            .onAppear { withAnimation(MemoryMotion.highlight.delay(0.45)) { swept = true } }
        }
    }
}

/// 一条记忆的列表行（搜索结果用）：标题 + 两三行纯文本预览 + 来源与时间。
struct MemoryRow: View {
    let memory: JSON
    var showFolder = false
    var body: some View {
        let style = memoryFolderStyle(memory.memoryFolder)
        NavigationLink(value: MemoryRoute.item(memory.id)) {
            ListRow(symbol: showFolder ? style.symbol : (memory.memoryKindLabel == "共享知识" ? "doc.text" : "bubble.left"),
                    tone: memory.memoryKindLabel == "共享知识" ? .info : .accent,
                    title: memory.memoryTitle, subtitle: memory.memoryPreview, subtitleLines: showFolder ? 2 : 3,
                    meta: ([showFolder ? memory.memoryFolder : "", memory.memoryKindLabel, relativeTime(memory["updated_at"].double)]).filter { !$0.isEmpty }.joined(separator: " · "))
        }
        .buttonStyle(.row)
        .accessibilityIdentifier("memory-" + memory.id)
    }
}

// MARK: - 文件夹里：纸片展开

/// 打开文件夹：系统 zoom 转场把文件夹放大成页面，里面的纸片按 04 层叠从下方甩上来、带 09 的透视倾角落定。
struct MemoryFolderView: View {
    @Environment(AppModel.self) private var model
    @Environment(MemoryReview.self) private var review
    let folder: MemoryFolder
    var initial: MemoryFilter = .all
    @State private var filter: MemoryFilter = .all
    @State private var appeared = false
    /// 下拉刷失败开口；别假装夹子已是最新。
    @State private var refreshFailNote = ""
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let items = model.datasets["/personal/memory"]?["items"].array ?? []
        let inside = MemoryPaper.build(items: items, inbox: model.datasets[AppModel.memoryInboxPath]).filter { $0.folder == folder.name && !review.hidden.contains($0.id) }
        let present = MemoryFilter.allCases.filter { $0 == .all || inside.contains(where: $0.keeps) }
        let shown = inside.filter(filter.keeps)
        ScrollViewReader { proxy in
        ScrollPage(spacing: Space.xl) {
            HStack(spacing: Space.md) {
                FolderSticker(folder: folder, size: 54, shown: appeared)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(inside.count) 条").font(TypeScale.metric).contentTransition(.numericText(value: Double(inside.count)))
                    if !folder.blurb.isEmpty { Text(folder.blurb).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary) }
                }
            }
            if present.count > 1 {
                FilterChips(options: present.map(\.rawValue), selection: Binding(get: { filter.rawValue }, set: { filter = MemoryFilter(rawValue: $0) ?? .all }),
                            animation: reduce ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86), haptic: true)
                    // 收进来的记忆多出一个「自动学到」时，胶囊顺着让位，不跳（轨道 r3-memory）。
                    .animation(reduce ? .easeOut(duration: 0.15) : .smooth(duration: 0.3), value: present.map(\.rawValue))
            }
            if !refreshFailNote.isEmpty {
                InlineNotice(text: refreshFailNote, tone: .danger)
                    .accessibilityIdentifier("memory-folder-refresh-fail")
            }
            if !review.actFailNote.isEmpty {
                InlineNotice(text: review.actFailNote, tone: .danger)
                    .accessibilityIdentifier("memory-folder-act-fail")
            }
            if shown.isEmpty {
                EmptyState(title: "这个夹子还空着", description: "跟我聊到相关的事，或在共享知识库写下笔记后，会自动收进来。", symbol: folder.symbol)
            } else {
                // 间距算进每一格（待确认的纸片收起时连间距一起收），最后一格多出来的那截用负边距抵掉（轨道 r3-memory）。
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, paper in
                        Group {
                            if paper.isPending {
                                LearnedRow(item: paper.value, pending: true, gap: Space.md) { id in withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .bottom) } }
                            } else {
                                NavigationLink(value: MemoryRoute.item(paper.id)) {
                                    PaperCard(mark: paper.mark) { PaperBody(memory: paper.value, mark: paper.mark) }
                                }
                                .buttonStyle(FolderPress())
                                .accessibilityIdentifier("memory-" + paper.id)
                                .padding(.bottom, Space.md)
                            }
                        }
                        .modifier(CascadeIn(index: index, shown: appeared, distance: 46))
                        // 轨道 r3-memory：待确认的纸片撤销回来时从左边滑回原位；其余纸片进出不再「从底下滑上来」，
                        // 改成旧的先淡掉、新的晚一拍淡入——新写进来的记忆出现在顶上时不会和正往下挪的纸片叠在一起。
                        .transition(paper.isPending ? .reviewReturn(reduce: reduce) : .paperSwap(reduce: reduce))
                    }
                }
                .padding(.bottom, -Space.md)
                .animation(reduce ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.86), value: filter)
                // 待确认的纸片收进来以后，后端写成一条新记忆、重新拉数据时出现在这里：跟着顺下来，不跳（轨道 r3-memory）。
                .animation(reduce ? .easeOut(duration: 0.2) : MemoryMotion.collapse, value: inside.map(\.id))
            }
        }
        }
        .overlay(alignment: .bottom) { UndoToast() }
        .navigationTitle(folder.name).navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .refreshable { await refreshFolder() }
        .onAppear {
            if !appeared { filter = present.contains(initial) ? initial : .all }
            appeared = true
        }
    }

    private func refreshFolder() async {
        refreshFailNote = ""
        let memPath = "/personal/memory"
        let inboxPath = AppModel.memoryInboxPath
        let gotMem = await model.load(memPath) != nil
        await model.loadMemoryInbox()
        let gotInbox = model.errors[inboxPath] == nil && model.datasets[inboxPath] != nil
        if gotMem && gotInbox { return }
        let memErr = model.errors[memPath] ?? ""
        let inboxErr = model.errors[inboxPath] ?? ""
        let hadCache = !insideEmpty()
        if !gotMem && !gotInbox {
            let err = [memErr, inboxErr].first { !$0.isEmpty } ?? ""
            refreshFailNote = err.isEmpty
                ? (hadCache ? "夹子没刷上——下面仍是上一版，可再下拉。不会假装已是最新。" : "夹子还没拉齐——检查配对或网络后再试。不会假装已是最新。")
                : (hadCache ? "夹子没刷上：" + err + "——下面仍是上一版。不会假装已是最新。" : "夹子没拉齐：" + err + "——可再试。不会假装已是最新。")
        } else if !gotMem {
            refreshFailNote = memErr.isEmpty
                ? (hadCache ? "记忆列表没刷上——下面仍是上一版，可再下拉。不会假装已是最新。" : "记忆列表没读上——可再试。不会假装已是最新。")
                : "记忆列表没读上：" + memErr + "——可再试。不会假装已是最新。"
        } else {
            refreshFailNote = inboxErr.isEmpty
                ? "待确认没读上——夹子里旧纸片若在仍可先看；可再下拉。不会假装已是最新。"
                : "待确认没读上：" + inboxErr + "——可再下拉。不会假装已是最新。"
        }
    }

    private func insideEmpty() -> Bool {
        let items = model.datasets["/personal/memory"]?["items"].array ?? []
        return !items.contains { $0.memoryFolder == folder.name }
    }
}

/// 展开后的纸片：纸色随状态，左上角标 + 状态字（「自动记忆」页里再跟上所属文件夹）。
private struct PaperCard<Content: View>: View {
    let mark: PaperMark
    var note = ""
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 6) {
                MarkBadge(mark: mark, size: 18)
                Text(note.isEmpty ? mark.label : mark.label + " · " + note).font(TypeScale.stamp).foregroundStyle(Palette.textSecondary)
            }
            content
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme == .dark ? Palette.surface : mark.paper.mix(with: .white, by: 0.45), in: .rect(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.black.opacity(scheme == .dark ? 0 : 0.06), lineWidth: 0.5))
        .elevation(.raised)
    }
}

private struct PaperBody: View {
    let memory: JSON
    let mark: PaperMark
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(memory.memoryTitle).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary).lineLimit(2)
            let preview = memory.memoryPreview
            let bare = { (t: String) in t.filter { !"。．.…，,！!？? ".contains($0) } }
            if !preview.isEmpty && bare(preview) != bare(memory.memoryTitle) {
                Text(preview).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(3)
            }
            Text([memory.memoryKindLabel, relativeTime(memory["updated_at"].double)].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
        }
        .multilineTextAlignment(.leading)
    }
}

/// 单条记忆。推进在记忆的导航栈里（不再叠 sheet），返回键回到文件夹。
struct MemoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let memory: JSON
    @State private var text = ""
    @State private var editing = false
    @State private var saving = false
    @State private var note = ""
    var body: some View {
        let style = memoryFolderStyle(memory.memoryFolder)
        ScrollPage {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Label(memory.memoryFolder, systemImage: style.symbol).font(TypeScale.stamp).foregroundStyle(style.tint)
                        .padding(.horizontal, Space.sm + 2).padding(.vertical, 5).background(style.tint.opacity(0.12), in: .capsule)
                    Stamp(text: memory.memoryKindLabel, tone: memory["read_only"].bool ? .neutral : .accent)
                }
                // 对话里记住的短句，标题就是正文本身：不重复写两遍。
                if memory["kind"].string == "knowledge" || memory["content"].string.count > 60 {
                    Text(memory.memoryTitle).font(TypeScale.title).fixedSize(horizontal: false, vertical: true)
                }
                if memory["updated_at"].double > 0 { Text("更新于 " + relativeTime(memory["updated_at"].double)).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) }
            }
            if editing {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextEditor(text: $text).font(TypeScale.body).scrollContentBackground(.hidden).frame(minHeight: 240).padding(Space.md)
                        .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.accentText.opacity(0.5), lineWidth: 1))
                    HStack(spacing: Space.md) {
                        Button("取消") { editing = false }.buttonStyle(.secondaryAction)
                        Button("保存纠正") {
                            guard !saving else { return }
                            saving = true
                            note = ""
                            Task {
                                do {
                                    _ = try await model.mutate("/personal/memory/" + memory.id.pathEncoded, fields: ["content": .string(text), "expected_version": memory["version"]])
                                    // 纠正已写入；列表没刷上仍 dismiss，但开口别假装网格已是新内容。
                                    if await model.load("/personal/memory") == nil {
                                        let err = model.errors["/personal/memory"] ?? ""
                                        model.memoryOpenNote = err.isEmpty
                                            ? "纠正已保存，记忆列表没刷上——可再打开记忆下拉。不会假装列表已更新。"
                                            : "纠正已保存，记忆列表没刷上：" + err + "——可再打开记忆。不会假装列表已更新。"
                                    } else {
                                        model.memoryOpenNote = ""
                                    }
                                    dismiss()
                                } catch {
                                    note = "保存没成：" + error.localizedDescription + "——还可以再试"
                                }
                                saving = false
                            }
                        }.buttonStyle(.primaryFull).disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !note.isEmpty { InlineNotice(text: note, tone: .danger) }
                }
            } else {
                Card(padding: Space.xl) { RichText(text: memory["content"].string) }
                if !memory["read_only"].bool {
                    Button { text = memory["content"].string; withAnimation(.smooth(duration: 0.2)) { editing = true } } label: { Label("纠正这条记忆", systemImage: "pencil") }.buttonStyle(.secondaryAction)
                }
            }
            Text(memory["read_only"].bool ? "来自共享知识库，来源文件更新后会自动同步。" : "保存时核对版本，旧内容与来源会保留。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            GroupedCard {
                if !memory["source"]["path"].string.isEmpty {
                    DisclosureGroup("原始来源") { CodeBlock(text: memory["source"]["path"].string).padding(.top, Space.sm) }
                        .font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                } else if !memory["source"]["quote"].string.isEmpty {
                    DisclosureGroup("你当时说的") { LinedText(text: memory["source"]["quote"].string).padding(.top, Space.sm) }
                        .font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                } else { RawDetails(title: "原始来源", value: memory["source"]).rowPadding() }
                if !memory["history"].array.isEmpty {
                    DisclosureGroup("历史版本") {
                        ForEach(Array(memory["history"].array.enumerated()), id: \.offset) { _, old in
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text("历史版本 \(old["version"].int)").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                                RichText(text: old["content"].string)
                            }.padding(.top, Space.sm)
                        }
                    }.font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                }
            }
        }
        .navigationTitle(memory.memoryFolder).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
    }
}

// MARK: - 自动记忆（轨道 agent；三个按钮与结果动效 · 轨道 r3-memory）
//
// 动效库对照（work/内容生产/动效库/）：
// - 03-badge-stamp 贴纸摊平：「没错 / 记住」盖一枚「记住了」。照原片 K[] 9 帧逐帧表：缩放 2.2→1.9→1.75→1.06→1、
//   倾角 −30°→−8.7°、中心按章宽回位、斜边揭示（底边先露），f9 落定后零回弹。
// - 20-build-checklist 构建清单：章落定后里面的对勾 back.out(2.4) 弹入（0.4→1、8 帧）；「纠正」时编辑框「模糊上浮」进场
//   （y+18→0、blur 8→0、power3.out 7 帧、错峰 2 帧）；文件夹接住纸片后「模糊上浮离场」（y−12、blur 6、power2.in 8 帧）。
// - 04-screenshot-cascade 截图层叠：接纸片的那只文件夹从下方甩上来，同一条减速曲线、13 帧走完。
// - 13-leaderboard-counter 榜单：标签组离场那 12 帧逐帧量出来是二次缓入（power2.in），纸片掉进文件夹、删掉时滑走都用它。
// - 15-bubble-glow-logo 气泡：按钮松手那口小回弹（原片落定后 1.00→0.98→1.00）。
// reduce motion 下全部退成淡入淡出；动画都是一次性的，没有逐帧重绘。

extension MemoryMotion {
    /// 13 离场：二次缓入，12 帧。
    static let drop = Animation.timingCurve(0.55, 0.085, 0.68, 0.53, duration: 12.0 / 30.0)
    /// 04 的减速曲线，单张卡 13 帧走完。
    static let catchUp = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 13.0 / 30.0)
    /// 20 模糊上浮进场：power3.out，7 帧。
    static let rise = Animation.timingCurve(0.215, 0.61, 0.355, 1, duration: 7.0 / 30.0)
    /// 20 模糊上浮离场：power2.in，8 帧。
    static let exit = Animation.timingCurve(0.55, 0.085, 0.68, 0.53, duration: 8.0 / 30.0)
    /// 05 荧光笔那条「慢起急冲长尾」：纸片缩进文件夹口，11 帧（第一帧几乎不动，不会像跳切）。
    static let tuck = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 11.0 / 30.0)
    /// 20 对勾 back.out(2.4)：约 18% 过冲，8 帧内落定。
    static let pop = Animation.spring(response: 0.27, dampingFraction: 0.48)
    /// 03 盖章 9 帧。
    static let stampDuration = 9.0 / 30.0
    /// 格子收起、撤销后让出位置：临界阻尼不回弹，0.45s 内落定到 1pt 以内，之后才动数据（数据一变整页重算，落定前动会把尾巴挤成一跳）。
    static let collapse = Animation.spring(response: 0.36, dampingFraction: 1)
}

/// 三个动作在本地的过场（轨道 r3-memory）：动画播完才把结果交给接口，播的时候数据刷新也不会把纸片抽走；
/// 删掉先在本地藏 4 秒、可以撤销，过了才真正 actOnLearned("delete")——接口和语义都不变。
@MainActor @Observable final class MemoryReview {
    struct Undo: Equatable { let id: String; let title: String; let pending: Bool }
    private(set) var hidden: Set<String> = []
    private(set) var undo: Undo?
    /// 记住/纠正/删掉失败开口（别只靠 banner alert）。
    var actFailNote = ""
    @ObservationIgnored private var commits: [String: (ids: Set<String>, task: Task<Void, Never>)] = [:]

    /// 没错 / 纠正：纸片先藏再提交；成功保持隐藏（列表已无此条）；失败才放回，别闪一下假成功。
    func file(_ item: JSON, action: String, content: String = "", model: AppModel) {
        actFailNote = ""
        hidden.insert(item.id)
        Task {
            let ok = await model.actOnLearned(item.id, action: action, content: content)
            if !ok {
                withAnimation(.smooth(duration: 0.25)) { _ = hidden.remove(item.id) }
                actFailNote = action == "correct"
                    ? "纠正没成——纸片回来了，还可以再改再存。不会假装已记住。"
                    : "记住没成——纸片回来了，还可以再点。不会假装已写入。"
            }
        }
    }

    /// 删掉 / 不用：先藏 4 秒（连同文件夹里那张纸），期间能撤销；过了才提交。
    func remove(_ item: JSON, title: String, pending: Bool, model: AppModel) {
        actFailNote = ""
        let ids = Set([item.id, item["memory_id"].string].filter { !$0.isEmpty })
        hidden.formUnion(ids)
        withAnimation(MemoryMotion.catchUp) { undo = Undo(id: item.id, title: title, pending: pending) }
        commits[item.id]?.task.cancel()
        // 强引用自己：4 秒内关掉记忆页，删掉也照样提交，不会悄悄作废。
        let task = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if self.undo?.id == item.id { withAnimation(.easeOut(duration: 0.2)) { self.undo = nil } }
            let ok = await model.actOnLearned(item.id, action: "delete")
            self.commits[item.id] = nil
            // 失败才放回；成功留在 hidden（数据里已没这条）。
            if !ok {
                withAnimation(.smooth(duration: 0.25)) { self.hidden.subtract(ids) }
                self.actFailNote = pending
                    ? "「先不用」没成——纸片回来了，还可以再点。不会假装已丢掉。"
                    : "删掉没成——纸片回来了，还可以再试。不会假装已归档。"
            }
        }
        commits[item.id] = (ids, task)
    }

    /// 撤销：先停掉提交（接口一次都没调），撤销条先收，再把纸片放回来——两步错开，条和下面挪动的纸片不叠在一起。
    func restore(reduce: Bool) async {
        guard let undo, let commit = commits.removeValue(forKey: undo.id) else { self.undo = nil; return }
        commit.task.cancel()
        withAnimation(.easeOut(duration: 0.15)) { self.undo = nil }
        try? await Task.sleep(for: .seconds(0.16))
        withAnimation(reduce ? .easeOut(duration: 0.2) : MemoryMotion.collapse) { hidden.subtract(commit.ids) }
    }
}

private enum ReviewPhase: Int, Comparable {
    case idle, stamped, filing, dropping, closed
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// 一张待你过目的纸片：内容 + 你当时的原话 + 三个按钮（没错 / 纠正 / 删掉；待确认的叫 记住 / 纠正 / 不用）。
/// 没错：盖章「记住了」，纸片缩小掉进所属文件夹；纠正：纸片就地展开成编辑框，保存后盖「改好了」再收进去；删掉：纸片滑走，底部给 4 秒撤销。
private struct LearnedRow: View {
    @Environment(AppModel.self) private var model
    @Environment(MemoryReview.self) private var review
    @Environment(\.accessibilityReduceMotion) private var reduce
    let item: JSON
    var pending = false
    /// 「自动记忆」页标上所属文件夹；文件夹里本来就知道是哪个，不重复。
    var showFolder = false
    /// 和下一张纸片的间距算在这一格里，收起时一起收成 0，下面的纸片补位不会最后再跳一下。
    var gap: CGFloat = 0
    /// 展开编辑时把「保存纠正」那一行滚到键盘上面（页面的 ScrollViewReader 给的）。
    var reveal: (String) -> Void = { _ in }
    @State private var phase: ReviewPhase = .idle
    @State private var editing = false
    @State private var leaving = false
    @State private var collapsed = false
    @State private var stampText = "记住了"
    @State private var stamp = 0.0
    @State private var checkIn = false
    @State private var draft = ""
    @State private var corrected = ""
    @State private var chrome = false
    @State private var size = CGSize(width: 360, height: 160)
    @FocusState private var focused: Bool

    private var folder: MemoryFolder { MemoryFolder(name: item.memoryFolder, blurb: "") }
    private var mark: PaperMark { pending ? .pending : .learned }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 接纸片的那只小文件夹。
    private static let pocket = CGSize(width: 168, height: 76)

    var body: some View {
        // 纸片缩到比文件夹口窄一圈，下沿落在文件夹口往下 20pt：上半截从文件夹里探出来（像网格里那样），再整张掉进去。
        let w = max(size.width, 1), h = max(size.height, 1)
        let shrink = min(Self.pocket.width * 0.8 / w, Self.pocket.height * 0.8 / h)
        let pocketTop = h - 6 - Self.pocket.height
        let anchor = UnitPoint(x: 0.5, y: min(1, max(0, (pocketTop + 20 - shrink * h) / (h * (1 - shrink)))))
        let moving = !reduce
        ZStack(alignment: .bottom) {
            paper
                .scaleEffect(phase >= .filing && moving ? shrink : 1, anchor: anchor)
                .offset(y: phase >= .dropping && moving ? Self.pocket.height - 22 : 0)
                // 掉进去的同时淡掉：它本来就在文件夹后面，文件夹合上时不会再从磨砂里透出来。
                .opacity(phase >= .dropping || (phase >= .filing && !moving) ? 0 : 1)
            if phase >= .filing && moving {
                FolderFace(folder: folder, height: Self.pocket.height, wordSize: 20, stickerSize: 28)
                    .frame(width: Self.pocket.width)
                    // 20 模糊上浮离场：文件夹合上、往上一飘就没了。
                    .offset(y: phase >= .closed ? -12 : 0)
                    .blur(radius: phase >= .closed ? 6 : 0)
                    .opacity(phase >= .closed ? 0 : 1)
                    .padding(.bottom, 6)
                    .transition(.offset(y: 26).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { if phase == .idle && !leaving { size = $0 } }
        // 删掉：13 的二次缓入整张往左滑走，越走越快、越糊。
        .offset(x: leaving && moving ? -(w + 60) : 0)
        .blur(radius: leaving && moving ? 6 : 0)
        .opacity(leaving && !moving ? 0 : 1)
        .padding(.bottom, gap)
        // 收起这一格：内容已经收进文件夹 / 滑走看不见了，只把高度连同间距收成 0，下面的纸片顺着补上来。
        .frame(height: collapsed ? 0 : nil, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory-learned-" + item.id)
        .id("memory-row-" + item.id)
    }

    private var paper: some View {
        PaperCard(mark: mark, note: showFolder ? item.memoryFolder : "") { content }
        .overlay(alignment: .trailing) {
            ReviewStamp(text: stampText, checkIn: checkIn)
                .mask { StampReveal(progress: stamp) }
                .modifier(StampPose(progress: stamp))
                .opacity(stamp > 0 ? 1 : 0)
                .padding(.trailing, Space.xl)
                .allowsHitTesting(false)
                .accessibilityHidden(stamp == 0)
        }
    }

    /// 读和改共用一张纸：那句话原地换成可编辑的字（不交叉淡化，免得两层字叠成重影），原话一直在；
    /// 编辑框的底和边从下面浮上来包住它（20 模糊上浮），提示和按钮再错 2 帧跟上。
    @ViewBuilder private var content: some View {
        if editing {
            TextField("正确的说法", text: $draft, axis: .vertical)
                .font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary)
                .lineLimit(1...6)
                .focused($focused)
                .disabled(phase != .idle)
                .background {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Palette.surface)
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Palette.accentText.opacity(0.55), lineWidth: 1))
                        .padding(.horizontal, -Space.sm - 2).padding(.vertical, -6)
                        .opacity(chrome ? 1 : 0)
                        .offset(y: chrome || reduce ? 0 : 18)
                        .blur(radius: chrome || reduce ? 0 : 8)
                }
                .accessibilityIdentifier("memory-correct-field")
                .transition(.identity)
        } else {
            Text(corrected.isEmpty ? item["content"].string : corrected)
                .font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                .transition(.identity)
        }
        if !item["quote"].string.isEmpty {
            Text("你说过「" + item["quote"].string + "」").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).lineLimit(2)
                .padding(.top, editing ? Space.xs : 0)
        }
        if pending && !editing && phase == .idle {
            Text("我猜这是你的习惯——对就记住，不对请纠正我。")
                .font(TypeScale.footnote)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Space.xxs)
        }
        if editing {
            Text("保存后旧版本和你的原话都会留着。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                .modifier(BlurRiseIn(index: 1))
                .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.1))))
            HStack(spacing: Space.sm) {
                Button("取消") { stopCorrecting() }.buttonStyle(ReviewButtonStyle(kind: .secondary))
                Spacer(minLength: 0)
                Button { corrected = trimmed; file("correct", content: trimmed) } label: {
                    Label { Text("保存纠正") } icon: { Image(systemName: "checkmark").fontWeight(.heavy) }
                }
                .buttonStyle(ReviewButtonStyle(kind: .primary))
                .disabled(trimmed.isEmpty || trimmed == item["content"].string)
            }
            .padding(.top, Space.xs)
            .opacity(phase == .idle ? 1 : 0)
            .disabled(phase != .idle)
            .modifier(BlurRiseIn(index: 2))
            .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.1))))
        } else {
            HStack(spacing: Space.sm) {
                Button { file("confirm") } label: {
                    Label { Text(pending ? "对，记住" : "没错") } icon: { Image(systemName: "checkmark").fontWeight(.heavy) }
                }
                .buttonStyle(ReviewButtonStyle(kind: .primary))
                Button { startCorrecting() } label: { Label(pending ? "纠正我" : "纠正", systemImage: "pencil") }
                    .buttonStyle(ReviewButtonStyle(kind: .secondary))
                Spacer(minLength: 0)
                Button(role: .destructive) { remove() } label: { Label(pending ? "先不用" : "删掉", systemImage: "trash") }
                    .buttonStyle(ReviewButtonStyle(kind: .danger))
            }
            .padding(.top, Space.xs)
            .opacity(phase == .idle && !leaving ? 1 : 0)
            .disabled(phase != .idle || leaving)
            // 换成编辑按钮时先 0.1s 淡掉，新按钮晚一拍才浮上来，两排不叠在一起；取消时反过来。
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.1)), removal: .opacity.animation(.easeOut(duration: 0.1))))
        }
    }

    private func startCorrecting() {
        draft = item["content"].string
        withAnimation(reduce ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.86)) { editing = true }
        withAnimation(reduce ? .easeOut(duration: 0.15) : MemoryMotion.rise.delay(0.06)) { chrome = true }
        Task {
            try? await Task.sleep(for: .milliseconds(260)); focused = true
            // 等键盘升起来再滚：整格（纸片 + 下面的间距）露在键盘上面。
            try? await Task.sleep(for: .milliseconds(380)); reveal("memory-row-" + item.id)
        }
    }
    private func stopCorrecting() {
        focused = false
        // 先把编辑框的底和边收掉，再原地换回那句话。
        withAnimation(reduce ? .easeOut(duration: 0.15) : MemoryMotion.exit) { chrome = false }
        Task {
            try? await Task.sleep(for: .seconds(reduce ? 0.15 : 8.0 / 30.0))
            withAnimation(reduce ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.86)) { editing = false }
        }
    }

    /// 没错 / 保存纠正：盖章（03）→ 对勾弹一下（20）→ 文件夹甩上来接住（04）、纸片缩进文件夹口（05 慢起急冲）→ 掉进去（13）
    /// → 文件夹合上离场（20）→ 这一格收起 → 交给接口。
    private func file(_ action: String, content: String = "") {
        guard phase == .idle, !leaving else { return }
        let typing = focused
        focused = false
        stampText = action == "correct" ? "改好了" : "记住了"
        Haptics.sent()
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.15)) { phase = .stamped }
            // 纠正时键盘还在：先等它收下去、整页停稳，章再落，免得章和整页滚动叠在一起动。
            if typing { try? await Task.sleep(for: .seconds(0.32)) }
            withAnimation(reduce ? .easeOut(duration: 0.2) : .linear(duration: MemoryMotion.stampDuration)) { stamp = 1 }
            try? await Task.sleep(for: .seconds(reduce ? 0.2 : MemoryMotion.stampDuration))
            Haptics.success()
            withAnimation(reduce ? .easeOut(duration: 0.15) : MemoryMotion.pop) { checkIn = true }
            try? await Task.sleep(for: .seconds(0.35))
            if reduce {
                withAnimation(.easeOut(duration: 0.25)) { phase = .filing }
                try? await Task.sleep(for: .seconds(0.25))
            } else {
                withAnimation(MemoryMotion.tuck) { phase = .filing }
                try? await Task.sleep(for: .seconds(11.0 / 30.0))
                withAnimation(MemoryMotion.drop) { phase = .dropping }
                try? await Task.sleep(for: .seconds(12.0 / 30.0))
                withAnimation(MemoryMotion.exit) { phase = .closed }
                try? await Task.sleep(for: .seconds(8.0 / 30.0))
            }
            await collapse()
            review.file(item, action: action, content: content, model: model)
        }
    }

    /// 删掉 / 不用：纸片滑走，这一格收起，底部出撤销条。
    private func remove() {
        guard phase == .idle, !leaving else { return }
        Haptics.sent()
        Task { @MainActor in
            withAnimation(reduce ? .easeOut(duration: 0.2) : MemoryMotion.drop) { leaving = true }
            try? await Task.sleep(for: .seconds(reduce ? 0.2 : 12.0 / 30.0))
            await collapse()
            review.remove(item, title: item["content"].string, pending: pending, model: model)
        }
    }

    /// 内容已经看不见了，把这一格（连同间距）收成 0；收完再从列表里拿掉，列表不会再跳。
    private func collapse() async {
        withAnimation(reduce ? .easeOut(duration: 0.2) : MemoryMotion.collapse) { collapsed = true }
        try? await Task.sleep(for: .seconds(reduce ? 0.25 : 0.5))
    }
}

/// 「记住了」章：双线圆角框 + 对勾 + 字，像橡皮章盖在纸片右侧。
private struct ReviewStamp: View {
    let text: String
    let checkIn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .black))
                .scaleEffect(checkIn || reduce ? 1 : 0.4).opacity(checkIn ? 1 : 0)
            Text(text).font(.system(size: 18, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(Palette.accentText)
        .padding(.horizontal, Space.md + 1).padding(.vertical, Space.sm - 1)
        .background(Palette.accent.opacity(0.24), in: .rect(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.accentText, lineWidth: 2.2))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.accentText.opacity(0.5), lineWidth: 0.8).padding(4))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 03-badge-stamp 的 K[]（f1…f9 @30fps）：缩放、倾角、中心位移（按章宽归一）、斜边揭示的上沿 / 下沿。
nonisolated private enum StampFrames {
    static let k: [[Double]] = [
        [2.20, -30, -0.863, 0.243, 0.00, 0.12],
        [1.90, -24, -0.515, 0.087, 0.05, 0.24],
        [1.75, -18, -0.108, -0.037, 0.16, 0.40],
        [1.06, -12, -0.237, 0.046, 0.30, 0.58],
        [1.00, -8.7, 0, 0, 0.44, 0.94],
        [1.00, -8.7, 0, 0, 0.58, 1.00],
        [1.00, -8.7, 0, 0, 0.74, 1.00],
        [1.00, -8.7, 0, 0, 0.90, 1.00],
        [1.00, -8.7, 0, 0, 1.00, 1.00],
    ]
    /// 逐帧线性插值：progress 0…1 对应 f1…f9。
    static func pose(_ progress: Double) -> [Double] {
        let x = min(max(progress, 0), 1) * Double(k.count - 1)
        let i = min(Int(x), k.count - 2), t = x - Double(i)
        return zip(k[i], k[i + 1]).map { $0 + ($1 - $0) * t }
    }
}

nonisolated private struct StampPose: GeometryEffect {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let k = StampFrames.pose(progress)
        let transform = CGAffineTransform(translationX: size.width / 2 + k[2] * size.width, y: size.height / 2 + k[3] * size.width)
            .rotated(by: k[1] * .pi / 180).scaledBy(x: k[0], y: k[0])
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
    }
}

/// 斜边揭示：底边先露（原片是贴纸背面的卷边由左下往右上收）。
nonisolated private struct StampReveal: Shape {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        let k = StampFrames.pose(progress)
        let r = rect.insetBy(dx: -4, dy: -4)
        if k[4] >= 1 && k[5] >= 1 { return Path(r) }
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * k[4], y: r.minY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * k[5], y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// 20 模糊上浮进场：y+18→0、blur 8→0、power3.out 7 帧，第 i 个晚 2 帧。
private struct BlurRiseIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 18)
            .blur(radius: shown || reduce ? 0 : 8)
            .onAppear {
                withAnimation(reduce ? .easeOut(duration: 0.15) : MemoryMotion.rise.delay(0.06 + Double(index) * MemoryMotion.stagger)) { shown = true }
            }
    }
}

/// 三个按钮主次分明：没错 = 青柠实心 + 对勾；纠正 = 浅墨底 + 笔；删掉 = 淡红底 + 垃圾桶。
/// 按下缩到 0.94、底色压深；松手带一口小回弹（15 气泡落定）。
private struct ReviewButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(TypeScale.subheadline.weight(.semibold))
            .labelStyle(ReviewLabelStyle())
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .primary ? Space.lg : Space.md + 2)
            .frame(height: 38)
            .background(fill(pressed), in: .capsule)
            .overlay(Capsule().strokeBorder(kind == .primary ? Color.black.opacity(0.06) : .clear, lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(pressed && !reduce ? 0.94 : 1)
            .animation(reduce ? nil : pressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.5), value: pressed)
            .contentShape(.capsule)
    }
    private var foreground: Color {
        switch kind { case .primary: Palette.onAccent; case .secondary: Palette.textPrimary; case .danger: Palette.danger }
    }
    private func fill(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? Palette.accent.mix(with: .black, by: 0.12) : Palette.accent
        case .secondary: Color.primary.opacity(pressed ? 0.14 : 0.065)
        case .danger: Palette.danger.opacity(pressed ? 0.2 : 0.1)
        }
    }
}

private struct ReviewLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.imageScale(.medium); configuration.title }
    }
}

/// 删掉之后的撤销条：4 秒内点「撤销」，纸片原样回来，什么都没提交。
private struct UndoToast: View {
    @Environment(MemoryReview.self) private var review
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        ZStack {
            if let undo = review.undo {
                HStack(spacing: Space.md) {
                    Image(systemName: "trash").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.danger)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(undo.pending ? "这条不记了" : "删掉了一条").font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                        Text(undo.title).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("撤销") { Task { await review.restore(reduce: reduce) } }
                        .buttonStyle(ReviewButtonStyle(kind: .primary))
                        .accessibilityIdentifier("memory-undo")
                }
                .padding(.leading, Space.lg).padding(.trailing, Space.sm).padding(.vertical, Space.sm)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, Layout.margin).padding(.bottom, Space.sm)
                .id(undo.id)
                .transition(.asymmetric(insertion: .offset(y: reduce ? 0 : 40).combined(with: .opacity), removal: .offset(y: reduce ? 0 : 24).combined(with: .opacity)))
            }
        }
    }
}

/// 撤销回来的纸片：先等这一格让出位置，再从左边滑回来（不和上下的纸片叠在一起）。
private extension AnyTransition {
    static func reviewReturn(reduce: Bool) -> AnyTransition {
        .asymmetric(insertion: reduce ? .opacity : AnyTransition.move(edge: .leading).combined(with: .opacity).animation(MemoryMotion.catchUp.delay(0.2)),
                    removal: .identity)
    }
    /// 文件夹里的普通纸片：旧的 0.12s 淡掉，其余纸片挪到位，新的晚一拍淡入。
    static func paperSwap(reduce: Bool) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(reduce ? 0 : 0.2)),
                    removal: .opacity.animation(.easeOut(duration: 0.12)))
    }
}

/// 二级页：待你确认的放在前面，然后是全部最近自动学到的。每条一张纸片。
struct LearnedMemoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(MemoryReview.self) private var review
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 下拉刷失败开口；别假装自动记忆已是最新。
    @State private var refreshFailNote = ""
    var body: some View {
        let inbox = model.datasets[AppModel.memoryInboxPath]
        let learned = (inbox?["learned"].array ?? []).filter { !review.hidden.contains($0.id) }
        let pending = (inbox?["pending"].array ?? []).filter { !review.hidden.contains($0.id) }
        ScrollViewReader { proxy in
        let reveal: (String) -> Void = { id in withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .bottom) } }
        ScrollPage(spacing: Layout.sectionSpacing) {
            if !refreshFailNote.isEmpty {
                InlineNotice(text: refreshFailNote, tone: .danger)
                    .accessibilityIdentifier("learned-memory-refresh-fail")
            }
            if !review.actFailNote.isEmpty {
                InlineNotice(text: review.actFailNote, tone: .danger)
                    .accessibilityIdentifier("memory-act-fail")
            }
            if !pending.isEmpty {
                GroupSection("等你确认", footer: "这些涉及健康、财务或不太确定的事，你点了「记住」才会写进记忆。") {
                    VStack(spacing: 0) {
                        ForEach(pending.map(RemoteRow.init)) { row in
                            LearnedRow(item: row.value, pending: true, showFolder: true, gap: Space.md, reveal: reveal).transition(.reviewReturn(reduce: reduce))
                        }
                    }
                    .padding(.bottom, -Space.md)
                }
                .transition(.opacity)
            }
            if !learned.isEmpty {
                GroupSection("最近自动学到", footer: "从你和 Com 的对话里自动记下，都带着你的原话。删掉会归档，历史版本还在。") {
                    VStack(spacing: 0) {
                        ForEach(learned.map(RemoteRow.init)) { row in
                            LearnedRow(item: row.value, showFolder: true, gap: Space.md, reveal: reveal).transition(.reviewReturn(reduce: reduce))
                        }
                    }
                    .padding(.bottom, -Space.md)
                }
                .transition(.opacity)
            }
            if learned.isEmpty && pending.isEmpty {
                EmptyState(title: "都看过了", description: "聊到新的偏好、习惯或在做的事，我会先记下再请你点头——对了才收进长期记忆。", symbol: "checkmark.circle")
                    .transition(.opacity)
            }
        }
        }
        .overlay(alignment: .bottom) { UndoToast() }
        .navigationTitle("自动记忆").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .refreshable { await refreshLearned() }
    }

    private func refreshLearned() async {
        refreshFailNote = ""
        let path = AppModel.memoryInboxPath
        let hadCache = model.datasets[path] != nil
        let got = await model.load(path) != nil
        if got { return }
        let err = model.errors[path] ?? ""
        refreshFailNote = err.isEmpty
            ? (hadCache
               ? "自动记忆没刷上——下面仍是上一版，可再下拉。不会假装已是最新。"
               : "自动记忆还没拉齐——检查配对或网络后再试。不会假装已是最新。")
            : (hadCache
               ? "自动记忆没刷上：" + err + "——下面仍是上一版。不会假装已是最新。"
               : "自动记忆没拉齐：" + err + "——可再试。不会假装已是最新。")
    }
}
