import SwiftUI
import ComCore

// App chrome shared by the four tabs: 顶栏（她 + 标题 + 两侧玻璃按钮）、浮动 Dock、聊天页里的迷你 Dock、
// 点她弹出的菜单（系统 popover，箭头对准她）、按住她往下拉打开「回来简报」（跟手，与聊天顶部的简报卡同一套状态）。

// MARK: - 顶栏

/// 全 App 只有这一条顶栏。她固定站在正中偏右一点：左边挂标题和她的状态（说话时那一行换成手绘气泡），
/// 右边是她手里的东西（牌子、盖章台、纸飞机）。两侧玻璃按钮随页面换：工作页像 ChatGPT——左上侧栏、右上新对话；
/// 其他页只有右上一颗。简报展开时右上按钮变成收起。
struct ComTopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("work.lastAgent") private var lastAgent = "codex"
    @State private var dragStart: CGFloat?
    @GestureState private var dragging = false
    /// 双栏时左栏的顶栏固定是 Com 主对话，不跟着右栏换页。
    var pinned: SectionTab? = nil
    private var tab: SectionTab { pinned ?? model.tab }
    /// 她在顶栏里缩小的比例：Duo 外屏只有约 466×678pt，顶栏要把高度让给内容。
    static let restScale: CGFloat = 0.72
    static var figureWidth: CGFloat { StripFigure.bodyWidth * restScale }
    /// 她靠左，标题跟在她右边，右侧留给这一页的一个动作。
    static func figureX(hasLeadingButton: Bool) -> CGFloat { Space.lg + (hasLeadingButton ? 44 + Space.xs : 0) }
    private var motion: Animation { ComMotion.reduced(reduce, ComMotion.settle) }
    private var brief: CGFloat { min(1, max(0, model.briefProgress)) }
    /// 标题：工作页是「派给谁」（点开换人 / 会话菜单），其他页是页名。
    private var head: String {
        switch tab {
        case .chat: "Com"
        case .work: agentName(model.work.mode == .home ? lastAgent : model.work.agent)
        default: tab.rawValue
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = Self.figureX(hasLeadingButton: tab == .work)
            let titleLeading = x + Self.figureWidth + Space.sm
            let titleWidth = max(56, width - titleLeading - Space.lg - 44)
            ZStack(alignment: .topLeading) {
                titleBlock
                    .frame(width: titleWidth, height: Layout.topBar, alignment: .leading)
                    .overlay { titleTarget }
                    .padding(.leading, titleLeading)
                figure()
                    .scaleEffect(Self.restScale, anchor: .topLeading)
                    .padding(.leading, x).padding(.top, Self.figureTop)
                HStack(spacing: 0) {
                    if tab == .work {
                        GlassIconButton(symbol: "sidebar.left", label: "历史对话") { model.openWorkSidebar(reduce: reduce) }
                            .accessibilityIdentifier("work-sidebar")
                            .transition(reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.7)))
                    }
                    Spacer(minLength: 0)
                    TopBarTrailing(tab: tab, closing: model.briefExpanded || brief > 0.5)
                }
                .padding(.horizontal, Space.lg)
                .frame(width: width, height: Layout.topBar)
            }
        }
        .frame(height: Layout.topBar)
        .background {
            // 实色顶栏：ultraThinMaterial 叠在滚动列表上会每帧重模糊，上滑掉帧。
            Palette.background.opacity(0.94)
                .ignoresSafeArea(edges: .top)
        }
        // 她和气泡会探出顶栏一点：往下补一段渐隐，滚上来的字不会和人物叠在一起。
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Palette.background.opacity(0.85), Palette.background.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 18).offset(y: 18).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(briefDrag)
        .onChange(of: dragging) { _, now in
            guard !now, let start = dragStart else { return }
            dragStart = nil
            let delta = (model.briefProgress - start) * max(120, model.briefDragHeight)
            model.settleBriefFromTopBar(start: start, translation: delta, predictedEnd: delta)
        }
        .animation(motion, value: tab)
    }

    static var figureTop: CGFloat { (Layout.topBar - StripFigure.size.height * restScale) / 2 }
    /// 聊天页底部已有「等你」条，顶栏不再重复说一遍。
    private var caption: String {
        tab == .chat && model.waitingInboxCount > 0 ? "" : model.stripCaption
    }

    /// 标题 + 她现在的状态；她说话时状态那行换成手绘气泡（尾巴指向她）。
    private var titleBlock: some View {
        let talking = !model.workBubble.isEmpty
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text(head).font(TypeScale.headline).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    .contentTransition(.opacity)
                // 小箭头一直在，只是别的页收成 0 宽、透明：插入 / 移除会在切页那一帧闪没。
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.textSecondary)
                    .padding(.leading, 4)
                    .frame(width: tab == .work ? 15 : 0, alignment: .leading)
                    .opacity(tab == .work ? 1 : 0)
                    .accessibilityHidden(true)
            }
            ZStack(alignment: .leading) {
                Text(caption).font(TypeScale.footnote).foregroundStyle(
                    model.waitingInboxCount > 0 && !talking ? Palette.warning : Palette.textTertiary
                ).lineLimit(1)
                    .contentTransition(.opacity)
                    .opacity(talking ? 0 : 1)
                    .attentionBreath(active: model.waitingInboxCount > 0 && !talking && !reduce)
                    // 气泡出来时这行先让开；气泡收回时等它缩到尾尖再露出来，两样东西不在同一处叠着。
                    .animation(reduce ? nil : talking ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2).delay(0.2), value: talking)
                    .accessibilityIdentifier("agent-stage-status")
                TalkBubble(text: model.workBubble)
            }
            .frame(height: talking ? 26 : (caption.isEmpty ? 0 : 16), alignment: .leading)
        }
        .animation(reduce ? nil : .smooth(duration: 0.28), value: head)
        .animation(reduce ? nil : .smooth(duration: 0.24), value: model.stripCaption)
        .animation(motion, value: talking)
    }

    /// 标题的触摸：工作页是换人 / 会话菜单；其他页和点她一样弹主菜单。
    @ViewBuilder private var titleTarget: some View {
        if tab == .work {
            WorkTitleMenu()
        } else {
            Button { Haptics.selection(); model.showMenu.toggle() } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityHidden(true)
        }
    }

    /// 她本人（只有她接触摸；右边的道具不接）。菜单从她头顶弹出，箭头对准她。
    private func figure() -> some View {
        @Bindable var model = model
        return Button { Haptics.selection(); model.showMenu.toggle() } label: {
            StripFigure(state: model.stripState, sign: "", showsProps: false, animated: model.active && !AmbientMotionPolicy.scrollQuiet, quiet: !model.workBubble.isEmpty, outfit: tab.outfit)
                .frame(width: StripFigure.bodyWidth + 6, height: StripFigure.size.height, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-stage-pull-zone")
        .accessibilityLabel(head + "，" + (model.workBubble.isEmpty ? model.stripCaption : model.workBubble) + "，点开菜单")
        .accessibilityAction(named: "展开回来简报") {
            model.ensureChatVisibleForBrief()
            model.prepareManualChatBrief()
            DispatchQueue.main.async { model.openBrief() }
        }
        .popover(isPresented: $model.showMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            MenuContent().presentationCompactAdaptation(.popover)
        }
    }

    /// 按住她往下拉：简报跟着手指长出来；展开后在顶栏往上推收回。松手按位置和速度决定开合。
    private var briefDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                let dy = value.translation.height
                if model.briefExpanded {
                    if dragStart == nil { guard dy < 0 else { return }; dragStart = model.briefProgress }
                    model.dragBrief(to: (dragStart ?? 1) + dy / max(120, model.briefDragHeight))
                } else {
                    if dragStart == nil {
                        guard dy > 0, dy > abs(value.translation.width) * 0.8 else { return }
                        dragStart = 0
                        model.showMenu = false
                        model.ensureChatVisibleForBrief()
                        model.prepareManualChatBrief()
                    }
                    model.dragBrief(to: (dragStart ?? 0) + dy / max(120, model.briefDragHeight))
                }
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                dragStart = nil
                DispatchQueue.main.async {
                    model.settleBriefFromTopBar(
                        start: start,
                        translation: value.translation.height,
                        predictedEnd: value.predictedEndTranslation.height
                    )
                }
            }
    }
}

/// 顶栏右上那颗玻璃按钮：图标随页换（符号替换动画），简报展开时变成收起。玻璃本身不换，切页不闪。
struct TopBarTrailing: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let tab: SectionTab
    var closing = false
    /// 本地点按门控：在服务端 running 亮起前挡住连点叠刷。
    @State private var localBusy = false
    private var motion: Animation { ComMotion.reduced(reduce, ComMotion.settle) }
    var body: some View {
        let item = trailingItem(closing: closing)
        return Button(action: item.action) {
            // 没有圆底：只留图标，点击区仍是 44pt。
            Image(systemName: item.symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.textSecondary)
                .contentTransition(.symbolEffect(.replace))
                .opacity(item.disabled ? 0.4 : 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(MessagePressStyle())
        .disabled(item.disabled)
        .accessibilityLabel(item.label)
        .accessibilityIdentifier(item.id)
        .animation(motion, value: item.symbol)
    }
    private struct BarItem { let symbol: String; let label: String; let id: String; var disabled = false; let action: () -> Void }
    private func trailingItem(closing: Bool) -> BarItem {
        if closing { return BarItem(symbol: "chevron.up", label: "收起回来简报", id: "agent-stage-close") { model.closeBrief() } }
        switch tab {
        case .health:
            let running = model.healthInsight["running"].bool || localBusy
            return BarItem(symbol: running ? "hourglass" : "arrow.clockwise", label: "重新评估身体", id: "health-refresh", disabled: running) {
                guard !localBusy, !model.healthInsight["running"].bool else { return }
                localBusy = true
                Task {
                    await model.refreshHealthInsight()
                    localBusy = false
                }
            }
        case .chat, .doing:
            let opening = model.searchOpening
            return BarItem(
                symbol: opening ? "hourglass" : "magnifyingglass",
                label: opening ? "正在打开搜索" : "搜索聊天与成果",
                id: "top-search",
                disabled: opening
            ) {
                guard !model.searchOpening else { return }
                model.openSearch()
            }
        case .next:
            let running = model.nextUserRefresh || localBusy
            return BarItem(symbol: running ? "hourglass" : "arrow.clockwise", label: "让它重新整理", id: "next-refresh", disabled: running) {
                guard !localBusy, !model.nextUserRefresh else { return }
                localBusy = true
                Task {
                    await model.refreshNext()
                    localBusy = false
                }
            }
        case .work:
            // ChatGPT 右上角：新对话。已经在新对话里就是灰的。
            return BarItem(symbol: "square.and.pencil", label: "新对话", id: "work-new", disabled: model.work.mode == .home) {
                Haptics.selection()
                withAnimation(motion) { model.work.newChat() }
            }
        }
    }
}

/// 顶栏右侧圆按钮（实色：压在聊天滚动上时不做玻璃合成）。
struct GlassIconButton: View {
    let symbol: String
    let label: String
    var badge = 0
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.textPrimary)
                .frame(width: 44, height: 44)
                .background(Palette.surface, in: .circle)
                .overlay(Circle().strokeBorder(Palette.separator, lineWidth: 0.5))
                .overlay(alignment: .topTrailing) { CountBadge(count: badge).offset(x: 4, y: -4) }
        }
        .buttonStyle(MessagePressStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - 点角色弹出的菜单

private struct MenuContent: View {
    @Environment(AppModel.self) private var model
    private var ledger: String {
        let money = model.datasets["/personal/finance"]?["currencies"].array.first ?? .null
        guard !money.isNull else { return "本月账目" }
        return "\(monthName())已花 ¥" + (money["month_minor"].double / 100).formatted(.number.precision(.fractionLength(0)))
    }
    private var voyageNote: String {
        let c = model.casesData
        if c["waiting"].int > 0 { return "\(c["waiting"].int) 段停下来等你" }
        if c["active"].int > 0 { return "\(c["active"].int) 段进行中 · 看它每一步怎么做的" }
        return "Com 自己开的 session 和每一步操作"
    }
    private var connectorNote: (String, Bool) {
        let broken = model.brokenSources
        if let first = broken.first { return ((broken.count > 1 ? "\(broken.count) 个来源" : sourceName(first["name"].string)) + "需要重新授权", true) }
        return ("邮件、日历、账本都在读", false)
    }
    private var activityNote: (String, Bool) {
        let n = model.activityData["uncertain"].array.count
        return n > 0 ? ("\(n) 个操作结果待核对", true) : ("记账、日程、改文件，一条条可核对", false)
    }
    var body: some View {
        VStack(spacing: 0) {
            row("等你", model.waitingOpening ? "打开中…" : (model.waitingInboxCount > 0 ? "\(model.waitingInboxCount) 件要你拍板或回一下" : "审批、航程停顿、微信待回、过期待办"),
                symbol: "hand.raised", warning: !model.waitingOpening && model.waitingInboxCount > 0, busy: model.waitingOpening) {
                guard !model.waitingOpening else { return }
                model.openWaitingInbox()
            }
            if !model.waitingOpening, !model.waitingOpenNote.isEmpty {
                InlineNotice(text: model.waitingOpenNote, tone: .danger)
                    .padding(.horizontal, Space.sm)
                    .padding(.bottom, Space.xs)
                    .accessibilityIdentifier("menu-waiting-open-fail")
            }
            row("记忆", model.memoryOpening ? "打开中…" : "搜索、分类、纠正它记住的事",
                symbol: "brain", busy: model.memoryOpening) {
                guard !model.memoryOpening else { return }
                model.openMemory()
            }
            if !model.memoryOpening, !model.memoryOpenNote.isEmpty {
                InlineNotice(text: model.memoryOpenNote, tone: .danger)
                    .padding(.horizontal, Space.sm)
                    .padding(.bottom, Space.xs)
                    .accessibilityIdentifier("menu-memory-open-fail")
            }
            row("账本", model.financeOpening ? "打开中…" : ledger,
                symbol: "creditcard", busy: model.financeOpening) {
                guard !model.financeOpening else { return }
                model.openFinance()
            }
            if !model.financeOpening, !model.financeOpenNote.isEmpty {
                InlineNotice(text: model.financeOpenNote, tone: .danger)
                    .padding(.horizontal, Space.sm)
                    .padding(.bottom, Space.xs)
                    .accessibilityIdentifier("menu-finance-open-fail")
            }
            row("连接器", model.connectorsOpening ? "打开中…" : connectorNote.0,
                symbol: "link", warning: !model.connectorsOpening && connectorNote.1, busy: model.connectorsOpening) {
                guard !model.connectorsOpening else { return }
                model.openConnectors()
            }
            if !model.connectorsOpening, !model.connectorsOpenNote.isEmpty {
                InlineNotice(text: model.connectorsOpenNote, tone: .danger)
                    .padding(.horizontal, Space.sm)
                    .padding(.bottom, Space.xs)
                    .accessibilityIdentifier("menu-connectors-open-fail")
            }
            // 10-28：航程和「它做过的事」合成一页动态（ActivityFeedView）：做过的写操作 + 航程进展，事后能看、能纠正
            row("动态", model.activityOpening ? "打开中…" : (model.casesData["waiting"].int > 0 ? voyageNote : activityNote.0),
                symbol: "list.bullet.rectangle",
                warning: !model.activityOpening && (activityNote.1 || model.casesData["waiting"].int > 0),
                busy: model.activityOpening) {
                guard !model.activityOpening else { return }
                model.openActivityFeed()
            }
            if !model.activityOpening, !model.activityOpenNote.isEmpty {
                InlineNotice(text: model.activityOpenNote, tone: .danger)
                    .padding(.horizontal, Space.sm)
                    .padding(.bottom, Space.xs)
                    .accessibilityIdentifier("menu-activity-open-fail")
            }
            row("设置", model.settingsOpening ? "打开中…" : "",
                symbol: "slider.horizontal.3", busy: model.settingsOpening) {
                guard !model.settingsOpening else { return }
                model.openSettings()
            }
            if !model.settingsOpening, !model.settingsOpenNote.isEmpty {
                InlineNotice(text: model.settingsOpenNote, tone: .danger)
                    .padding(.horizontal, Space.sm)
                    .padding(.bottom, Space.xs)
                    .accessibilityIdentifier("menu-settings-open-fail")
            }
        }
        .padding(.vertical, Space.sm).padding(.horizontal, Space.sm)
        .frame(width: 290)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("main-menu")
    }
    private func row(_ title: String, _ subtitle: String, symbol: String, warning: Bool = false, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            guard !busy else { return }
            model.showMenu = false
            if model.briefExpanded || model.briefProgress > 0 { model.closeBrief(dockAfter: false) }
            action()
        } label: {
            HStack(spacing: Space.md) {
                IconBadge(symbol: symbol, tone: warning ? .warning : .neutral, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary)
                    if !subtitle.isEmpty { Text(subtitle).font(TypeScale.footnote).foregroundStyle(warning ? Palette.warning : Palette.textSecondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, Space.sm + 2).padding(.horizontal, Space.sm)
            .contentShape(.rect)
            .opacity(busy ? 0.72 : 1)
        }
        .buttonStyle(.row)
        .disabled(busy)
        .clipShape(.rect(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityLabel(title + (subtitle.isEmpty ? "" : "，" + subtitle))
    }
}

private func monthName() -> String { "\(Calendar.current.component(.month, from: Date()))月" }

// MARK: - Dock（在办 / 工作）：浮动玻璃胶囊，内容从下面滑过

/// 底部 Dock：每个页面一颗独立的玻璃胶囊，选中的那颗撑开露出彩色图标和名字。
/// 动效复刻自 Nitish Khagwal「expanding tab item interaction」（x.com/nitishkmrk）：宽度带回弹、名字模糊淡入、撑开后高光扫过一次。
struct ComDock: View {
    /// 胶囊 48 + 上 8 + 下 4；页面按这个高度留底部空白。
    static let height: CGFloat = 48 + Space.sm + Space.xs
    /// 横屏侧边栏：胶囊 48 + 左 8 + 右 8（选中项要放得下名字的小字）。
    static let sideWidth: CGFloat = 48 + Space.sm * 2
    @Environment(AppModel.self) private var model
    @Environment(\.dockOnSide) private var side
    /// 双栏时右栏的 Dock 只放工作页面（Com 主对话常驻左栏）。
    var tabs: [SectionTab] = SectionTab.dock
    var body: some View {
        // 不包 GlassEffectContainer：每颗各自一块玻璃，徽标才能压在玻璃上面。
        let items = ForEach(tabs) { tab in
            DockItem(tab: tab, selected: (model.splitView ? model.rightTab : model.tab) == tab,
                     badge: tab == .next ? model.waitingInboxCount + model.nextUrgentCount : 0)
        }
        // 横屏（Duo 展开）：工具栏贴右边缘竖着排；竖屏仍是底部横排。
        Group {
            if side {
                VStack(spacing: Space.sm) { items }
                    .padding(.horizontal, Space.sm).padding(.vertical, Space.sm)
            } else {
                HStack(spacing: Space.sm) { items }
                    .padding(.horizontal, Space.xl).padding(.top, Space.sm).padding(.bottom, Space.xs)
            }
        }
        .sensoryFeedback(.selection, trigger: model.tab)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

private struct DockOnSideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Dock 是否贴在右边缘（横屏双栏）。页面据此把底部留白换成右侧留白。
    var dockOnSide: Bool {
        get { self[DockOnSideKey.self] }
        set { self[DockOnSideKey.self] = newValue }
    }
}

/// 页面给 Dock 留的底部空白；Dock 在右边时不需要（右侧留白由 RootView 统一给）。
struct DockSpacer: View {
    @Environment(\.dockOnSide) private var side
    var body: some View { Color.clear.frame(height: side ? 0 : ComDock.height) }
}

private struct DockItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.dockOnSide) private var side
    let tab: SectionTab
    let selected: Bool
    let badge: Int
    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(ComMotion.reduced(reduce, ComMotion.snap)) { model.tab = tab }
        } label: {
            label
        }
        .buttonStyle(DockPress())
        .accessibilityLabel(tab.rawValue)
        .accessibilityIdentifier("tab-" + tab.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var label: some View {
        if side { sideLabel } else { bottomLabel }
    }
    /// 右侧竖排：选中的那颗向下撑开，图标下面露出名字。
    private var sideLabel: some View {
        VStack(spacing: 3) {
            TabGlyph(tab: tab, selected: selected)
                .font(.system(size: 18, weight: .semibold))
            if selected {
                Text(tab.rawValue).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                    .transition(reduce ? AnyTransition.opacity : AnyTransition(BlurReplaceTransition(configuration: .downUp)))
            }
        }
        .foregroundStyle(selected ? tab.tint : Palette.textPrimary)
        .padding(.vertical, selected ? Space.sm : 0)
        .frame(width: 48).frame(minHeight: 48)
        .clipShape(.capsule)
        .contentShape(.capsule)
        .background(Palette.surface, in: .capsule)
        .overlay {
            if selected {
                Capsule().strokeBorder(tab.tint.opacity(0.35), lineWidth: 1)
            } else {
                Capsule().strokeBorder(Palette.separator, lineWidth: 0.5)
            }
        }
        .scaleEffect(reduce ? 1 : (selected ? 1.02 : 1))
        .animation(ComMotion.reduced(reduce, ComMotion.snap), value: selected)
        .overlay(alignment: .topTrailing) {
            if !selected {
                CountBadge(count: badge).offset(x: 4, y: -3)
                    .attentionBreath(active: badge > 0 && !reduce)
            }
        }
    }
    private var bottomLabel: some View {
        HStack(spacing: 7) {
            // 图标不换实心/空心，只变颜色：换图形会先淡出再淡入，切换瞬间图标会闪没。
            TabGlyph(tab: tab, selected: selected)  // 轨道 r2-pages：「下一步」换成自绘宇航员靴印（MoonBootPrint.swift）
                .font(.system(size: 18, weight: .semibold))
            if selected { name }
        }
        .foregroundStyle(selected ? tab.tint : Palette.textPrimary)
        .padding(.horizontal, selected ? Space.lg : 0)
        .frame(minWidth: 48, minHeight: 48)
        .clipShape(.capsule)
        .contentShape(.capsule)
        // 实色底：玻璃胶囊压在聊天滚动上会跟列表抢合成预算。
        .background(Palette.surface, in: .capsule)
        .overlay {
            if selected {
                Capsule().strokeBorder(tab.tint.opacity(0.35), lineWidth: 1)
            } else {
                Capsule().strokeBorder(Palette.separator, lineWidth: 0.5)
            }
        }
        .scaleEffect(reduce ? 1 : (selected ? 1.02 : 1))
        .animation(ComMotion.reduced(reduce, ComMotion.snap), value: selected)
        .overlay(alignment: .topTrailing) {
            if !selected {
                CountBadge(count: badge).offset(x: 4, y: -3)
                    .attentionBreath(active: badge > 0 && !reduce)
            }
        }
    }
    private var name: some View {
        Text(tab.rawValue).font(TypeScale.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
            .modifier(ShineOnce(enabled: !reduce))
            .transition(reduce ? AnyTransition.opacity : AnyTransition(BlurReplaceTransition(configuration: .downUp)).combined(with: AnyTransition.scale(scale: 0.7, anchor: .leading)))
    }
}

extension SectionTab {
    /// 顶栏她在这一页的造型（10-17）。
    var outfit: CharacterOutfit {
        switch self { case .chat: .chat; case .next: .next; case .doing: .today; case .health: .health; case .work: .work }
    }
}

private extension SectionTab {
    /// 选中时图标和名字的颜色：每页一种，Com 用主题青柠的深色版。
    var tint: Color {
        switch self { case .chat: Palette.accentText; case .next: Color(red: 0.55, green: 0.33, blue: 0.95); case .doing: Palette.info; case .health: TodayHue.pink.ink; case .work: Palette.warning }
    }
}

/// 按下时整颗胶囊微缩。不用玻璃自带的 interactive：它按下时会把胶囊里的 SF Symbol 提亮到看不见。
private struct DockPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduce ? 1 : (configuration.isPressed ? 0.92 : 1))
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduce ? .easeOut(duration: 0.12) : ComMotion.press, value: configuration.isPressed)
    }
}

/// 名字出现后，一道高光从左到右扫过一次。
private struct ShineOnce: ViewModifier {
    let enabled: Bool
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(colors: [.clear, .white.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.7)
                            .offset(x: -width * 0.7 + phase * width * 1.7)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear {
                guard enabled else { return }
                phase = 0
                withAnimation(.easeInOut(duration: 0.7).delay(0.22)) { phase = 1 }
            }
    }
}
