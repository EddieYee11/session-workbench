import SwiftUI
import ComCore

// App chrome shared by the four tabs: 顶栏（她 + 标题 + 两侧玻璃按钮）、浮动 Dock、聊天页里的迷你 Dock、
// 点她弹出的菜单（系统 popover，箭头对准她）、按住她往下拉出来的工作台（跟手、玻璃）。
// r3-work：顶栏从「每个 tab 一份」改成 RootView 最上层一份，切页时她不重建、不挪位，标题文字交叉淡入。

// MARK: - 顶栏

/// 全 App 只有这一条顶栏。她固定站在正中偏右一点：左边挂标题和她的状态（说话时那一行换成手绘气泡），
/// 右边是她手里的东西（牌子、盖章台、纸飞机）。两侧玻璃按钮随页面换：工作页像 ChatGPT——左上侧栏、右上新对话；
/// 其他页只有右上一颗。往下拉出工作台时，中间这组淡出、「Com 的工作台」淡入，右上按钮变成收起。
struct ComTopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("work.lastAgent") private var lastAgent = "codex"
    @State private var dragStart: CGFloat?
    /// 双栏时左栏的顶栏固定是 Com 主对话，不跟着右栏换页。
    var pinned: SectionTab? = nil
    private var tab: SectionTab { pinned ?? model.tab }
    /// 她的左边缘（顶栏坐标）：正中往右 26pt。字挂她左边、牌子伸她右边，整组看着居中；哪一页都是这个位置。
    static func figureX(in width: CGFloat) -> CGFloat { (width / 2 + 26 - StripFigure.bodyWidth / 2).rounded() }
    private var motion: Animation { reduce ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86) }
    private var stage: CGFloat { min(1, max(0, model.stageProgress)) }
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
            let x = Self.figureX(in: width)
            let leading = Space.lg + (tab == .work ? 44 + Space.sm : 0)
            let titleWidth = max(56, x - 6 - leading)
            // 往下拉时标题先走（拉到 0.2 就没了）：她要往左下跳，不能从字上面穿过去。
            let center = Double(1 - min(1, stage * 5))
            ZStack(alignment: .topLeading) {
                stageTitle
                    .padding(.leading, Space.lg).frame(height: Layout.topBar)
                    .opacity(Double(max(0, (stage - 0.4) / 0.6)))
                    .accessibilityHidden(!model.stageExpanded)
                titleBlock
                    .frame(width: titleWidth, height: Layout.topBar, alignment: .trailing)
                    .overlay { titleTarget }
                    .padding(.leading, x - 6 - titleWidth)
                    .opacity(center).allowsHitTesting(stage < 0.05)
                // 她不跟着淡出：往下拉时她自己跳到桌前（StripFigure.Hop），收起时原路跳回来。
                figure(hop: hop(width: width, x: x))
                    .padding(.leading, x).padding(.top, (Layout.topBar - StripFigure.size.height) / 2)
                    .allowsHitTesting(stage < 0.05)
                HStack(spacing: 0) {
                    if tab == .work {
                        GlassIconButton(symbol: "sidebar.left", label: "历史对话") { model.openWorkSidebar(reduce: reduce) }
                            .accessibilityIdentifier("work-sidebar")
                            .opacity(Double(1 - min(1, stage * 2))).allowsHitTesting(stage < 0.05)
                            .transition(reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.7)))
                    }
                    Spacer(minLength: 0)
                    TopBarTrailing(tab: tab, closing: model.stageExpanded || stage > 0.5)
                }
                .padding(.horizontal, Space.lg)
                .frame(width: width, height: Layout.topBar)
            }
        }
        .frame(height: Layout.topBar)
        .background {
            ZStack { Rectangle().fill(.ultraThinMaterial); Palette.background.opacity(0.72) }
                .opacity(Double(1 - min(1, stage * 2)))
                .ignoresSafeArea(edges: .top)
        }
        // 她和气泡会探出顶栏一点：往下补一段渐隐，滚上来的字不会和人物叠在一起。
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Palette.background.opacity(0.85), Palette.background.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 18).offset(y: 18).allowsHitTesting(false)
                .opacity(Double(1 - min(1, stage * 2)))
        }
        .contentShape(Rectangle())
        .simultaneousGesture(stageDrag)
        .animation(motion, value: tab)
    }

    /// 标题 + 她现在的状态；她说话时状态那行换成手绘气泡（尾巴指向她）。
    private var titleBlock: some View {
        let talking = !model.workBubble.isEmpty
        return VStack(alignment: .trailing, spacing: 2) {
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
            ZStack(alignment: .trailing) {
                Text(model.stripCaption).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    .contentTransition(.opacity)
                    .opacity(talking ? 0 : 1)
                    // 气泡出来时这行先让开；气泡收回时等它缩到尾尖再露出来，两样东西不在同一处叠着。
                    .animation(reduce ? nil : talking ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2).delay(0.2), value: talking)
                    .accessibilityIdentifier("agent-stage-status")
                TalkBubble(text: model.workBubble)
            }
            .frame(height: talking ? 30 : 17, alignment: .trailing)
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

    /// 往下拉工作台时她的路线：从顶栏的位置跳到桌前（桌子的位置跟着工作台展开时的缩放走）。一直传，进度 0 就是待在顶栏。
    private func hop(width: CGFloat, x: CGFloat) -> StripFigure.Hop {
        let top = (Layout.topBar - StripFigure.size.height) / 2
        return StripFigure.Hop(progress: min(1, max(0, model.stageProgress)), start: CGPoint(x: x, y: top + 6), width: width, frameOrigin: CGPoint(x: x, y: top))
    }

    /// 她本人（只有她接触摸；右边的道具不接）。菜单从她头顶弹出，箭头对准她。
    private func figure(hop: StripFigure.Hop) -> some View {
        @Bindable var model = model
        return Button { Haptics.selection(); model.showMenu.toggle() } label: {
            StripFigure(state: model.stripState, sign: model.stripSign, animated: model.active, quiet: !model.workBubble.isEmpty, hop: hop, outfit: tab.outfit)
                .frame(width: StripFigure.bodyWidth + 6, height: StripFigure.size.height, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-stage-pull-zone")
        .accessibilityLabel(head + "，" + (model.workBubble.isEmpty ? model.stripCaption : model.workBubble) + "，点开菜单")
        .accessibilityAction(named: "展开工作舞台") { model.openStage() }
        .popover(isPresented: $model.showMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            MenuContent().presentationCompactAdaptation(.popover)
        }
    }

    private var stageTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Com 的工作台").font(TypeScale.headline)
            Text(model.stripCaption).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
        }
    }

    /// 按住她往下拉：舞台跟着手指长出来；展开后在顶栏往上推收回。松手按位置和速度决定开合。
    private var stageDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                let dy = value.translation.height
                if model.stageExpanded {
                    if dragStart == nil { guard dy < 0 else { return }; dragStart = model.stageProgress }
                    model.dragStage(to: (dragStart ?? 1) + dy / StagePanel.revealHeight)
                } else {
                    guard dy > 0, dy > abs(value.translation.width) * 0.8 else { return }
                    model.showMenu = false
                    model.dragStage(to: dy / StagePanel.revealHeight)
                }
            }
            .onEnded { value in
                // 松手的弹簧放到下一轮：和最后一次跟手更新（不带动画）挤在同一帧时，弹簧会被吞掉、直接跳到终点。
                if model.stageExpanded {
                    guard dragStart != nil else { return }
                    dragStart = nil
                    let predicted = 1 + value.predictedEndTranslation.height / StagePanel.revealHeight
                    DispatchQueue.main.async { model.settleStage(predicted: predicted) }
                } else {
                    guard model.stageProgress > 0 else { return }
                    let predicted = value.predictedEndTranslation.height / StagePanel.revealHeight
                    DispatchQueue.main.async { model.settleStage(predicted: predicted) }
                }
            }
    }
}

/// 顶栏右上那颗玻璃按钮：图标随页换（符号替换动画），拉开工作台时变成收起。玻璃本身不换，切页不闪。
struct TopBarTrailing: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let tab: SectionTab
    var closing = false
    private var motion: Animation { reduce ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86) }
    var body: some View {
        let item = trailingItem(closing: closing)
        return Button(action: item.action) {
            Image(systemName: item.symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.textPrimary)
                .contentTransition(.symbolEffect(.replace))
                .opacity(item.disabled ? 0.4 : 1)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(MessagePressStyle())
        .floatingGlass(.circle)
        .disabled(item.disabled)
        .accessibilityLabel(item.label)
        .accessibilityIdentifier(item.id)
        .animation(motion, value: item.symbol)
    }
    private struct BarItem { let symbol: String; let label: String; let id: String; var disabled = false; let action: () -> Void }
    private func trailingItem(closing: Bool) -> BarItem {
        if closing { return BarItem(symbol: "chevron.up", label: "收起工作舞台", id: "agent-stage-close") { model.closeStage() } }
        switch tab {
        case .health:
            let running = model.healthInsight["running"].bool
            return BarItem(symbol: running ? "hourglass" : "arrow.clockwise", label: "重新评估身体", id: "health-refresh", disabled: running) { Task { await model.refreshHealthInsight() } }
        case .chat, .doing:
            return BarItem(symbol: "magnifyingglass", label: "搜索聊天与成果", id: "top-search") { model.showSearch = true }
        case .next:
            let running = model.nextData["running"].bool
            return BarItem(symbol: running ? "hourglass" : "arrow.clockwise", label: "让它重新整理", id: "next-refresh", disabled: running) { Task { await model.refreshNext() } }
        case .work:
            // ChatGPT 右上角：新对话。已经在新对话里就是灰的。
            return BarItem(symbol: "square.and.pencil", label: "新对话", id: "work-new", disabled: model.work.mode == .home) {
                Haptics.selection()
                withAnimation(motion) { model.work.newChat() }
            }
        }
    }
}

/// 顶栏右侧的玻璃圆按钮。
struct GlassIconButton: View {
    let symbol: String
    let label: String
    var badge = 0
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.textPrimary)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) { CountBadge(count: badge).offset(x: 4, y: -4) }
        }
        .buttonStyle(MessagePressStyle())
        .floatingGlass(.circle)
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
            row("记忆", "搜索、分类、纠正它记住的事", symbol: "brain") { model.showMemory = true }
            row("账本", ledger, symbol: "creditcard") { model.showFinance = true }
            row("连接器", connectorNote.0, symbol: "link", warning: connectorNote.1) { model.showConnectors = true }
            // 10-18：原「看她的工作台」换成航程（Com 自己开的 session 和每一步操作）；下拉工作台的手势保留
            row("航程", voyageNote, symbol: "location.north.line", warning: model.casesData["waiting"].int > 0) { model.showCases = true }
            // 10-25 活动日志（Muse）：审批只拦删除之后，事后能看、能纠正
            row("它做过的事", activityNote.0, symbol: "list.bullet.rectangle", warning: activityNote.1) { model.showActivity = true }
            row("设置", "", symbol: "slider.horizontal.3") { model.showSettings = true }
        }
        .padding(.vertical, Space.sm).padding(.horizontal, Space.sm)
        .frame(width: 290)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("main-menu")
    }
    private func row(_ title: String, _ subtitle: String, symbol: String, warning: Bool = false, action: @escaping () -> Void) -> some View {
        Button { model.showMenu = false; action() } label: {
            HStack(spacing: Space.md) {
                IconBadge(symbol: symbol, tone: warning ? .warning : .neutral, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary)
                    if !subtitle.isEmpty { Text(subtitle).font(TypeScale.footnote).foregroundStyle(warning ? Palette.warning : Palette.textSecondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Space.sm + 2).padding(.horizontal, Space.sm)
            .contentShape(.rect)
        }.buttonStyle(.row).clipShape(.rect(cornerRadius: Radius.sm, style: .continuous)).accessibilityLabel(title + (subtitle.isEmpty ? "" : "，" + subtitle))
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
                     badge: tab == .doing ? model.decisionCount : tab == .next ? model.nextUrgentCount : 0)
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
            withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.46, dampingFraction: 0.66)) { model.tab = tab }
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
        .background { Color.clear.glassEffect(.regular, in: .capsule) }
        .overlay(alignment: .topTrailing) {
            if !selected { CountBadge(count: badge).offset(x: 4, y: -3) }
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
        // 玻璃只做底，图标和字压在上面：图标放进玻璃里，按下时会被玻璃的高光吃掉。
        .background { Color.clear.glassEffect(.regular, in: .capsule) }
        .overlay(alignment: .topTrailing) {
            if !selected { CountBadge(count: badge).offset(x: 4, y: -3) }
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
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

// MARK: - 下拉工作台：从顶栏像水珠一样拉下来

/// 舞台面板常驻在根视图上层（r3-work：在顶栏下面一层）：高度 = 顶栏 + 进度 × 展开部分。进度跟手指走，松手弹到开或合。
/// 顶栏那一截只铺玻璃：标题「Com 的工作台」和收起按钮由顶栏自己换上去，她不再画第二份。
struct StagePanel: View {
    /// 展开部分的高度：场景 200 + 状态行 48 + 把手 28。
    nonisolated static let revealHeight: CGFloat = 276
    /// 展开到 progress 时桌前她的原点和缩放（顶栏坐标）：场景随进度从 0.9 倍长到 1 倍（锚在上沿正中），她要落在同一张桌子前。
    nonisolated static func deskFigure(width: CGFloat, progress: CGFloat) -> (origin: CGPoint, scale: CGFloat) {
        let k = 0.9 + 0.1 * min(1, max(0, progress))
        let local = StageScene.figureOrigin(width: width)
        return (CGPoint(x: width / 2 + (local.origin.x - width / 2) * k, y: Layout.topBar + local.origin.y * k), local.scale * k)
    }
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var dragStart: CGFloat?
    private var progress: CGFloat { model.stageProgress }
    var body: some View {
        GeometryReader { geometry in
            let top = geometry.safeAreaInsets.top
            let shape = UnevenRoundedRectangle(bottomLeadingRadius: 30 * min(1, progress * 2 + 0.3), bottomTrailingRadius: 30 * min(1, progress * 2 + 0.3), style: .continuous)
            ZStack(alignment: .top) {
                Color.black.opacity(0.18 * Double(min(1, progress)))
                    .ignoresSafeArea()
                    .allowsHitTesting(model.stageExpanded)
                    .onTapGesture { model.closeStage() }
                    .accessibilityIdentifier("agent-stage-outside")
                    .accessibilityHidden(!model.stageExpanded)
                VStack(spacing: 0) {
                    Color.clear.frame(height: Layout.topBar)
                    ZStack(alignment: .top) {
                        VStack(spacing: 0) {
                            StageScene(state: model.stripState, sign: model.stripSign, sourceBroken: !model.brokenSources.isEmpty, machineLit: model.stripMachine, drawsFigure: false)
                                .frame(height: 200)
                            stats.frame(height: 48)
                            Capsule().fill(Palette.separator).frame(width: 40, height: 5).frame(height: 28).accessibilityHidden(true)
                        }
                        .scaleEffect(0.9 + 0.1 * min(1, progress), anchor: .top)
                        .opacity(Double(min(1, max(0, (progress - 0.1) / 0.6))))
                    }
                    .frame(height: Self.revealHeight * max(0, progress), alignment: .top)
                    .clipped()
                }
                .padding(.top, top)
                .frame(maxWidth: .infinity)
                .background { shape.fill(Palette.background.opacity(0.55)) }
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.18 * Double(min(1, progress))), radius: 24, y: 12)
                .contentShape(Rectangle())
                .gesture(panelDrag)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(model.stageExpanded ? "agent-stage-panel" : "agent-stage-panel-collapsed")
                .accessibilityHidden(!model.stageExpanded)
            }
            .ignoresSafeArea(edges: .top)
        }
        // 原来是 progress > 0 就整块出现（第一帧整片玻璃硬切进来）；现在随进度淡入，和顶栏自己的底色交叉过去。
        .opacity(Double(min(1, progress * 4)))
        .allowsHitTesting(model.stageExpanded)
    }
    /// 展开后的一行实情：下一步 / 在跑 / 信源，各自能跳过去。
    private var stats: some View {
        HStack(spacing: Space.sm) {
            chip("下一步 \(model.nextUrgentCount)", symbol: "shoeprints.fill", tone: model.nextUrgentCount > 0 ? .warning : .neutral) { model.closeStage(); model.tab = .next }  // 10-25：「等你」只增不减，换成下一步
            chip("在跑 \(model.runningTasks.count)", symbol: "play.circle", tone: model.runningTasks.isEmpty ? .neutral : .info) { model.closeStage(); model.tab = .doing }
            chip(model.brokenSources.isEmpty ? "信源正常" : "信源断了 \(model.brokenSources.count)", symbol: model.brokenSources.isEmpty ? "checkmark.circle" : "exclamationmark.triangle", tone: model.brokenSources.isEmpty ? .success : .danger) { model.closeStage(); model.showConnectors = true }
            if model.stripState == .done, !model.stage.deliveryID.isEmpty {
                chip("看回复", symbol: "text.bubble", tone: .accent) { model.closeStage(); Task { await model.locateMessage(model.stage.deliveryID) } }.accessibilityIdentifier("agent-stage-delivery")
            }
        }.padding(.horizontal, Space.lg)
    }
    private func chip(_ text: String, symbol: String, tone: Tone, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)); Text(text).font(TypeScale.footnote.weight(.medium)).lineLimit(1) }
                .foregroundStyle(tone == .neutral ? Palette.textPrimary : tone.color)
                .padding(.horizontal, Space.md).frame(height: 32)
                .background(tone.soft, in: .capsule)
        }.buttonStyle(.plain)
    }
    /// 展开后，在面板上往上推：跟手收回；松手按位置和速度决定。
    private var panelDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard model.stageExpanded else { return }
                if dragStart == nil { dragStart = model.stageProgress }
                model.dragStage(to: (dragStart ?? 1) + value.translation.height / Self.revealHeight)
            }
            .onEnded { value in
                guard model.stageExpanded else { return }
                dragStart = nil
                let predicted = 1 + value.predictedEndTranslation.height / Self.revealHeight
                DispatchQueue.main.async { model.settleStage(predicted: predicted) }  // r3-work：松手弹簧单独一帧起，不被最后一次跟手吞掉
            }
    }
}
