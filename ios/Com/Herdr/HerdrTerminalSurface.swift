import GhosttyTerminal
import HerdrKit
import SwiftUI
import ComCore

private extension String {
    var strippingANSI: String {
        self.replacingOccurrences(of: #"\x1b\][^\x07\x1b]*(\x07|\x1b\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }
}

/// 工作 Tab「终端」面 = herdr 的手机控制台：三层卡片检视流（Urgent Approval Deck / Activity Cards / Smart Dispatcher）
/// 支持三种形态自适应：
/// 1. 外屏/窄屏 (<700pt)：单栏卡片检视流，4 行 ANSI 实时预览，1-Tap 拍板。
/// 2. 展开内屏 (≥700pt)：Master-Detail 左右双栏，左栏 380pt 窗格队列，中缝 16~24pt 纯空白避让，右栏 530pt 原生内嵌 Ghostty 终端（彻底终结全屏模态遮挡）。
/// 3. 半折叠悬停 (75°~115°) Tabletop 模式：上半屏展示纯净终端，下半屏紧凑操作台，键盘高度 ≤ 210pt。
struct HerdrTerminalSurface: View {
    @Environment(\.herdrBackend) private var backend: (any HerdrBackend)?
    @Environment(HerdrSessionStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DuoPosture.self) private var posture: DuoPosture?

    @State private var presented: HerdrTerminalTarget?
    @State private var selectedTarget: HerdrTerminalTarget?
    @State private var showDispatch = false
    @State private var askTarget: HerdrPane?
    @State private var expanded: Set<String> = []
    @State private var tails: [String: String] = [:]
    @State private var note = ""
    @State private var operatingPanes: Set<String> = []
    @FocusState private var isPromptFocused: Bool

    // Smart Dispatcher 状态
    @State private var dispatchTask = ""
    @State private var selectedKind: HerdrAgentKind = .pi
    @State private var isDispatching = false

    private func executeAction(paneId: String, keys: [String], successNote: String) {
        guard !operatingPanes.contains(paneId) else { return }
        operatingPanes.insert(paneId)
        Haptics.impact(.medium)
        Task {
            defer { operatingPanes.remove(paneId) }
            note = await store.sendKeys(paneId: paneId, keys: keys) ?? successNote
            await store.refresh()
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscapeWide = proxy.size.width > proxy.size.height && proxy.size.width >= 600
            let isWide = proxy.size.width >= 700 || isLandscapeWide || (posture?.isWide ?? false) || ProcessInfo.processInfo.arguments.contains("--posture-unfolded") || ProcessInfo.processInfo.environment["HERDR_UNFOLDED"] == "1"
            let isTabletop = (posture?.posture == .innerTabletop) || ((posture?.hingeAngle ?? 180) >= 75 && (posture?.hingeAngle ?? 180) <= 115) || ProcessInfo.processInfo.arguments.contains("--posture-tabletop") || ProcessInfo.processInfo.environment["HERDR_TABLETOP"] == "1"
            Group {
                if isTabletop {
                    tabletopView(proxy: proxy)
                } else if isWide {
                    masterDetailView(proxy: proxy)
                } else {
                    compactView
                }
            }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--ui-herdr-demo") {
                store.loadDemo()
                if ProcessInfo.processInfo.arguments.contains("--expand-first-pane") || ProcessInfo.processInfo.environment["HERDR_EXPAND_PANE"] == "1" {
                    if let first = store.agentPanes.first {
                        expanded.insert(first.paneId)
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--select-mini") || ProcessInfo.processInfo.environment["HERDR_MACHINE"] == "mini" {
                    await store.select("mini")
                }
                if ProcessInfo.processInfo.environment["COM_PREVIEW_TERMINAL"] == "1" || ProcessInfo.processInfo.arguments.contains("--preview-terminal") || ProcessInfo.processInfo.arguments.contains("--landscape") {
                    let target: HerdrTerminalTarget = ProcessInfo.processInfo.environment["COM_PREVIEW_PANE"] == "2"
                        ? .pane(terminalId: "term_2", title: "pi·herdr接口核对", paneId: "p2", agent: "pi")
                        : .pane(terminalId: "term_1", title: "Com 终端改版", paneId: "p1", agent: "claude")
                    presented = target
                    selectedTarget = target
                }
            } else if store.phase == .idle {
                await store.prepare(backend: backend)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, store.phase == .connected { Task { await store.refresh() } }
        }
        .fullScreenCover(item: $presented) { target in
            if let endpoint = store.endpoint {
                HerdrTerminalScreen(endpoint: endpoint, target: target, machineLabel: store.selectedMachine?.label ?? "", route: store.routeLabel)
            }
        }
        .sheet(isPresented: $showDispatch) {
            HerdrDispatchSheet { id in
                showDispatch = false
                note = "已派出，新 tab 在队列里。"
                _ = id
            }
        }
        .sheet(item: $askTarget) { pane in
            HerdrAskSheet(pane: pane)
        }
        .onAppear {
            HerdrSignposts.markFirstFrameRendered()
        }
        .accessibilityIdentifier("herdr-terminal-surface")
        .ignoresSafeArea()
    }

    // MARK: - 模式 1：外屏/单栏模式 (< 700pt)

    private var compactView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                topBar
                statusBlock
                if store.phase == .connected {
                    summaryStrip
                    actionRow
                    smartDispatcher
                    if !note.isEmpty { InlineNotice(text: note, tone: .warning) }
                    urgentApprovalDeck(isWide: false)
                    queue(isWide: false)
                }
            }
            .padding(.leading, 28)
            .padding(.trailing, 24)
            .padding(.vertical, Space.md)
        }
        .safeAreaPadding(.all)
        .refreshable { await store.connect() }
    }

    // MARK: - 模式 2：展开态 Master-Detail 双栏模式 (≥ 700pt)

    private func masterDetailView(proxy: GeometryProxy) -> some View {
        let totalWidth = proxy.size.width
        let gap: CGFloat = max(16, min(24, posture?.creaseRect?.width.rounded() ?? 20))
        let leftWidth: CGFloat = {
            if let crease = posture?.creaseRect, crease.minX > 100, crease.minX < totalWidth - 100 {
                return crease.minX.rounded()
            }
            return min(400, max(280, (totalWidth * 0.42).rounded()))
        }()
        let rightWidth: CGFloat = max(150, totalWidth - leftWidth - gap)
        let active = currentTarget

        return HStack(spacing: 0) {
            // 左栏：Work Master 队列
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    topBar
                    statusBlock
                    if store.phase == .connected {
                        summaryStrip
                        actionRow
                        smartDispatcher
                        if !note.isEmpty { InlineNotice(text: note, tone: .warning) }
                        urgentApprovalDeck(isWide: true)
                        queue(isWide: true)
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 20)
                .padding(.vertical, Space.md)
            }
            .safeAreaPadding(.leading)
            .refreshable { await store.connect() }
            .frame(width: leftWidth, height: proxy.size.height)

            // 中缝物理铰链隔离避让区 (16~24pt 纯空白)
            Color.clear
                .frame(width: gap)

            // 右栏：Live Terminal 内嵌视窗 (就地渲染，免去全屏遮挡，满屏铺满)
            Group {
                if let endpoint = store.endpoint, let target = active {
                    HerdrEmbeddedTerminalPane(
                        endpoint: endpoint,
                        target: target,
                        machineLabel: store.selectedMachine?.label ?? "",
                        route: store.routeLabel
                    )
                } else {
                    ZStack {
                        Color.black
                        VStack(spacing: Space.md) {
                            Image(systemName: "terminal")
                                .font(.system(size: 40))
                                .foregroundStyle(Color.white.opacity(0.3))
                            Text("从左侧选择窗格以查看实时终端")
                                .font(TypeScale.callout)
                                .foregroundStyle(Color.white.opacity(0.6))
                            Button("打开完整 herdr") {
                                selectedTarget = .whole
                            }
                            .buttonStyle(.secondaryCompact)
                        }
                    }
                }
            }
            .frame(width: rightWidth, height: proxy.size.height)
            .clipped()
        }
        .frame(width: totalWidth, height: proxy.size.height, alignment: .leading)
    }

    // MARK: - 模式 3：Tabletop 半折叠悬停姿态 (75°~115°)

    private func tabletopView(proxy: GeometryProxy) -> some View {
        let totalWidth = proxy.size.width
        let halfHeight = max(220, (proxy.size.height - 24) / 2)
        let active = currentTarget

        return VStack(spacing: 0) {
            // 上半屏：纯净展示视窗 (内嵌真实 Ghostty PTY 终端)
            Group {
                if let endpoint = store.endpoint, let target = active {
                    HerdrEmbeddedTerminalPane(
                        endpoint: endpoint,
                        target: target,
                        machineLabel: store.selectedMachine?.label ?? "",
                        route: store.routeLabel,
                        isTabletop: true
                    )
                    .frame(width: totalWidth, height: halfHeight)
                } else {
                    ZStack {
                        Color.black
                        VStack(spacing: Space.sm) {
                            Text("终端未连接").font(TypeScale.subheadline).foregroundStyle(Color.white.opacity(0.6))
                            if store.phase == .connected {
                                Button("打开完整 herdr") { selectedTarget = .whole }
                                    .buttonStyle(.secondaryCompact)
                            }
                        }
                    }
                    .frame(width: totalWidth, height: halfHeight)
                }
            }
            .frame(width: totalWidth, height: halfHeight)
            .clipped()

            // 物理折痕纯空白避让区 (24pt)
            Color.clear.frame(width: totalWidth, height: 24)

            // 下半屏：紧凑控制台 (使用 ScrollView 避让软键盘，且输入聚焦时自动折叠轮播与拍板卡片)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Space.sm) {
                    if !isPromptFocused {
                        topBar
                            .padding(.horizontal, Layout.margin)
                        // 水平窗格选择器 (Carousel)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.sm) {
                                Button {
                                    selectedTarget = .whole
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "rectangle.split.2x1")
                                        Text("完整 herdr")
                                    }
                                    .font(TypeScale.footnote.weight(.semibold))
                                    .foregroundStyle(selectedTarget?.id == "whole" ? Palette.onAccent : Palette.textPrimary)
                                    .padding(.horizontal, Space.md)
                                    .frame(height: 36)
                                    .background(selectedTarget?.id == "whole" ? Palette.accent : Palette.surface, in: .capsule)
                                }

                                ForEach(store.agentPanes) { pane in
                                    Button {
                                        selectTarget(pane, isWide: true)
                                    } label: {
                                        HStack(spacing: 5) {
                                            HerdrAgentIcon(agent: pane.agent, size: 20)
                                            Text(title(of: pane))
                                            Circle().fill(herdrStatusColor(pane.agentStatus)).frame(width: 6, height: 6)
                                        }
                                        .font(TypeScale.footnote.weight(.semibold))
                                        .foregroundStyle(selectedTarget?.id == (pane.terminalId ?? pane.paneId) ? Palette.onAccent : Palette.textPrimary)
                                        .padding(.horizontal, Space.md)
                                        .frame(height: 36)
                                        .background(selectedTarget?.id == (pane.terminalId ?? pane.paneId) ? Palette.accent : Palette.surface, in: .capsule)
                                    }
                                }
                            }
                            .padding(.horizontal, Layout.margin)
                        }
                        .frame(height: 42)

                        // 1-Tap 大动作拍板按钮组 (针对 blocked 状态)
                        let blockedPanes = store.agentPanes.filter { $0.agentStatus == .blocked }
                        if let currentBlocked = blockedPanes.first {
                            let isOp = operatingPanes.contains(currentBlocked.paneId)
                            HStack(spacing: Space.md) {
                                Button {
                                    executeAction(paneId: currentBlocked.paneId, keys: ["enter"], successNote: "已批准 (Enter)")
                                } label: {
                                    HStack(spacing: 6) {
                                        if isOp {
                                            ProgressView().controlSize(.small).tint(.black)
                                        } else {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(isOp ? "正在批准…" : "批准 (Enter)")
                                    }
                                    .font(TypeScale.subheadline.weight(.bold))
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color(red: 0.40, green: 0.85, blue: 0.35), in: .rect(cornerRadius: Radius.md))
                                }
                                .disabled(isOp)
                                .opacity(isOp ? 0.6 : 1.0)
                                .accessibilityIdentifier("tabletop-approve")

                                Button {
                                    executeAction(paneId: currentBlocked.paneId, keys: ["esc"], successNote: "已拒绝 (Esc)")
                                } label: {
                                    HStack(spacing: 6) {
                                        if isOp {
                                            ProgressView().controlSize(.small).tint(Palette.danger)
                                        } else {
                                            Image(systemName: "xmark")
                                        }
                                        Text(isOp ? "正在拒绝…" : "拒绝 (Esc)")
                                    }
                                    .font(TypeScale.subheadline.weight(.semibold))
                                    .foregroundStyle(Palette.danger)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Palette.danger.opacity(0.12), in: .rect(cornerRadius: Radius.md))
                                }
                                .disabled(isOp)
                                .opacity(isOp ? 0.6 : 1.0)
                                .accessibilityIdentifier("tabletop-reject")
                            }
                            .padding(.horizontal, Layout.margin)
                        }
                    }

                    // Tabletop 虚拟功能按键条
                    HStack(spacing: Space.sm) {
                        Button("Ctrl+C") {
                            if let current = currentPaneId {
                                Task { _ = await store.sendKeys(paneId: current, keys: ["ctrl+c"]) }
                            }
                        }.buttonStyle(.secondaryCompact)

                        Button("Tab") {
                            if let current = currentPaneId {
                                Task { _ = await store.sendKeys(paneId: current, keys: ["tab"]) }
                            }
                        }.buttonStyle(.secondaryCompact)

                        Button("↑") {
                            if let current = currentPaneId {
                                Task { _ = await store.sendKeys(paneId: current, keys: ["up"]) }
                            }
                        }.buttonStyle(.secondaryCompact)

                        Button("↓") {
                            if let current = currentPaneId {
                                Task { _ = await store.sendKeys(paneId: current, keys: ["down"]) }
                            }
                        }.buttonStyle(.secondaryCompact)

                        Button("Enter") {
                            if let current = currentPaneId {
                                Task { _ = await store.sendKeys(paneId: current, keys: ["enter"]) }
                            }
                        }.buttonStyle(.secondaryCompact)

                        if isPromptFocused {
                            Spacer()
                            Button {
                                isPromptFocused = false
                            } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .font(.footnote)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .buttonStyle(.secondaryCompact)
                            .accessibilityIdentifier("tabletop-dismiss-keyboard")
                        }
                    }
                    .padding(.horizontal, Layout.margin)

                    // 紧凑追问输入条 (高度 ≤ 40pt)
                    HStack(spacing: Space.sm) {
                        TextField("向当前 agent 追加指令…", text: $dispatchTask)
                            .focused($isPromptFocused)
                            .font(TypeScale.footnote)
                            .padding(.horizontal, Space.md)
                            .frame(height: 38)
                            .background(Palette.surface, in: .capsule)

                        Button {
                            let text = dispatchTask.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty, let current = currentPaneId else { return }
                            Task {
                                _ = await store.ask(paneId: current, text: text)
                                dispatchTask = ""
                                isPromptFocused = false
                            }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(Palette.accent, in: .circle)
                        }
                        .disabled(dispatchTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, Layout.margin)
                }
                .padding(.vertical, Space.xs)
                .animation(.easeInOut(duration: 0.22), value: isPromptFocused)
            }
            .frame(width: totalWidth, height: halfHeight)
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
        }
        .frame(width: totalWidth, height: proxy.size.height, alignment: .topLeading)
    }

    // MARK: - 卡片检视流第一层：紧急拍板胶囊带 (Urgent Approval Deck)

    @ViewBuilder
    private func urgentApprovalDeck(isWide: Bool) -> some View {
        let blocked = store.agentPanes.filter { $0.agentStatus == .blocked }
        if !blocked.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.warning).frame(width: 8, height: 8)
                    Text("待你拍板 (\(blocked.count))")
                        .font(TypeScale.section.weight(.bold))
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                }

                ForEach(blocked) { pane in
                    urgentCard(pane, isWide: isWide)
                }
            }
            .padding(Space.md)
            .background(Palette.warning.opacity(0.08), in: .rect(cornerRadius: Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(Palette.warning.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private func urgentCard(_ pane: HerdrPane, isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                HerdrAgentIcon(agent: pane.agent, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(of: pane))
                        .font(TypeScale.rowTitle.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text("\(pane.agent ?? "agent") · 等你批准 · \(shortCwd(pane.cwd))")
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button {
                    selectTarget(pane, isWide: isWide)
                } label: {
                    Image(systemName: "terminal")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Palette.surface, in: .circle)
                }
            }

            // 4 行 ANSI 实时预览 (清理 ANSI 转义字符)
            let tailText = (tails[pane.paneId] ?? "读取日志中…").strippingANSI
            Text(tailText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.sm)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.sm))

            // 1-Tap 44pt 快捷动作
            let isOp = operatingPanes.contains(pane.paneId)
            HStack(spacing: Space.md) {
                Button {
                    executeAction(paneId: pane.paneId, keys: ["enter"], successNote: "已批准 (Enter)")
                } label: {
                    HStack(spacing: 6) {
                        if isOp {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: "checkmark")
                        }
                        Text(isOp ? "正在批准…" : "批准")
                    }
                    .font(TypeScale.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color(red: 0.40, green: 0.85, blue: 0.35), in: .rect(cornerRadius: Radius.md))
                }
                .buttonStyle(SoftPressStyle(scale: 0.96))
                .disabled(isOp)
                .opacity(isOp ? 0.6 : 1.0)
                .accessibilityIdentifier("urgent-approve-\(pane.paneId)")

                Button {
                    executeAction(paneId: pane.paneId, keys: ["esc"], successNote: "已拒绝 (Esc)")
                } label: {
                    HStack(spacing: 6) {
                        if isOp {
                            ProgressView().controlSize(.small).tint(Palette.danger)
                        } else {
                            Image(systemName: "xmark")
                        }
                        Text(isOp ? "正在拒绝…" : "拒绝")
                    }
                    .font(TypeScale.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Palette.danger.opacity(0.12), in: .rect(cornerRadius: Radius.md))
                }
                .buttonStyle(SoftPressStyle(scale: 0.96))
                .disabled(isOp)
                .opacity(isOp ? 0.6 : 1.0)
                .accessibilityIdentifier("urgent-reject-\(pane.paneId)")

                Button {
                    askTarget = pane
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble")
                        Text("追问")
                    }
                    .font(TypeScale.subheadline.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Space.md)
                    .frame(height: 44)
                    .background(Palette.fill, in: .rect(cornerRadius: Radius.md))
                }
                .buttonStyle(SoftPressStyle(scale: 0.96))
                .accessibilityIdentifier("urgent-ask-\(pane.paneId)")
            }
        }
        .padding(Space.md)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.md))
        .task {
            if tails[pane.paneId] == nil {
                tails[pane.paneId] = await store.tail(paneId: pane.paneId, lines: 4)
            }
        }
    }

    // MARK: - 卡片检视流第三层：智能底栏 (Smart Dispatcher)

    private var smartDispatcher: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                TextField("给 agent 派个新活…", text: $dispatchTask)
                    .font(TypeScale.callout)
                    .padding(.horizontal, Space.md)
                    .frame(height: 40)
                    .background(Palette.surface, in: .capsule)
                    .accessibilityIdentifier("smart-dispatch-input")

                Menu {
                    ForEach(HerdrAgentKind.allCases) { kind in
                        Button {
                            selectedKind = kind
                        } label: {
                            Label(kind.title, systemImage: "sparkle")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedKind.title)
                            .font(TypeScale.footnote.weight(.semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.horizontal, Space.sm)
                    .frame(height: 40)
                    .background(Palette.surface, in: .capsule)
                }

                Button {
                    let text = dispatchTask.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !isDispatching else { return }
                    isDispatching = true
                    Task {
                        do {
                            let paneId = try await store.dispatch(kind: selectedKind, label: "任务", task: text, cwd: nil)
                            dispatchTask = ""
                            note = "已向 \(selectedKind.title) 派活 (pane: \(paneId))"
                        } catch {
                            note = "派活失败: \(error.localizedDescription)"
                        }
                        isDispatching = false
                    }
                } label: {
                    Image(systemName: isDispatching ? "hourglass" : "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Palette.accent, in: .circle)
                }
                .disabled(dispatchTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDispatching)
                .accessibilityIdentifier("smart-dispatch-send")
            }
        }
        .padding(Space.sm)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.lg))
    }

    // MARK: - 机器与连接状态

    private var topBar: some View {
        HStack(alignment: .center, spacing: Space.md) {
            StripFigure(
                state: store.stripState,
                sign: "",
                showsProps: false,
                animated: true,
                quiet: false,
                outfit: .work
            )
            .frame(width: StripFigure.bodyWidth + 6, height: StripFigure.size.height, alignment: .leading)
            .accessibilityIdentifier("herdr-top-figure")

            machinePicker
        }
    }

    private var machinePicker: some View {
        HStack(spacing: Space.sm) {
            ForEach(store.machines) { machine in
                Group {
                    if machine.id == store.selectedMachineId {
                        Button(machine.label) {}.buttonStyle(.primaryCompact)
                    } else {
                        Button(machine.label) {
                            expanded = []
                            tails = [:]
                            note = ""
                            Task { await store.select(machine.id) }
                        }.buttonStyle(.secondaryCompact)
                    }
                }
                .accessibilityIdentifier("herdr-machine-\(machine.id)")
            }
            Spacer(minLength: 0)
            if store.phase == .connected {
                HStack(spacing: 6) {
                    Circle().fill(Palette.success).frame(width: 7, height: 7)
                    Text(store.routeLabel).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                }
                .accessibilityIdentifier("herdr-connected-route")
            }
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch store.phase {
        case .idle, .connecting:
            HStack(spacing: Space.sm) {
                ProgressView()
                Text("正在连接 \(store.selectedMachine?.label ?? "")…")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
        case .connected:
            EmptyView()
        case .needsAuthorization:
            VStack(alignment: .leading, spacing: Space.sm) {
                InlineNotice(text: "\(store.selectedMachine?.label ?? "这台机器")还没授权这台手机的钥匙。公钥已交给 Com 后端，运行安装脚本后下拉重试。", tone: .warning)
                Text(store.publicKey)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                retryButton
            }
            .accessibilityIdentifier("herdr-needs-authorization")
        case .hostKeyChanged:
            VStack(alignment: .leading, spacing: Space.sm) {
                InlineNotice(text: "\(store.selectedMachine?.label ?? "这台机器")的主机指纹变了。重装过系统可以重新信任；否则可能有人在中间拦截。", tone: .danger)
                Button("确认是我的机器，重新信任") { Task { await store.forgetHostKeyAndRetry() } }
                    .buttonStyle(.secondaryCompact)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.sm) {
                InlineNotice(text: message, tone: .danger)
                retryButton
            }
        }
    }

    private var retryButton: some View {
        Button("重试") { Task { await store.connect() } }
            .buttonStyle(.secondaryCompact)
            .accessibilityIdentifier("herdr-retry")
    }

    // MARK: - 概览与动作

    private var summaryStrip: some View {
        let c = store.counts
        return HStack(spacing: Space.sm) {
            chip("等你", c.blocked, .blocked)
            chip("在跑", c.working, .working)
            chip("完成", c.done, .done)
            if c.error > 0 { chip("出错", c.error, .error) }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("herdr-summary")
    }

    private func chip(_ title: String, _ n: Int, _ status: HerdrAgentStatus) -> some View {
        HStack(spacing: 6) {
            Circle().fill(herdrStatusColor(status)).frame(width: 7, height: 7)
            Text("\(title) \(n)").font(TypeScale.footnote.weight(.semibold))
                .foregroundStyle(n == 0 ? Palette.textTertiary : Palette.textPrimary)
        }
        .padding(.horizontal, Space.md).padding(.vertical, 6)
        .background(Palette.fill, in: .capsule)
    }

    private var actionRow: some View {
        HStack(spacing: Space.sm) {
            Button { showDispatch = true } label: { Label("派活", systemImage: "paperplane.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.primaryFull)
                .accessibilityIdentifier("herdr-dispatch")
            Button {
                if posture?.isWide == true {
                    selectedTarget = .whole
                } else {
                    presented = .whole
                }
            } label: { Label("完整 herdr", systemImage: "rectangle.split.2x1").frame(maxWidth: .infinity) }
                .buttonStyle(.secondaryAction)
                .accessibilityIdentifier("herdr-open-whole")
        }
    }

    // MARK: - 卡片检视流第二层：执行队列与窗格卡 (带 4 行 ANSI tail)

    @ViewBuilder
    private func queue(isWide: Bool) -> some View {
        let panes = store.agentPanes
        let waiting = panes.filter { $0.agentStatus == .blocked || $0.agentStatus == .error }
        let rest = panes.filter { $0.agentStatus != .blocked && $0.agentStatus != .error }
        if panes.isEmpty {
            Text("还没有 agent 在跑。点「派活」让 pi / agy / Cursor 干点什么。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                .padding(.vertical, Space.lg)
        }
        if !waiting.isEmpty { section("要你看一眼", waiting, isWide: isWide) }
        if !rest.isEmpty { section("队列", rest, isWide: isWide) }
        if let snapshot = store.snapshot {
            let shells = snapshot.panes.filter { ($0.agent ?? "").isEmpty }
            if !shells.isEmpty { section("终端", shells, isWide: isWide) }
        }
    }

    private func section(_ title: String, _ panes: [HerdrPane], isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            ForEach(panes) { pane in card(pane, isWide: isWide) }
        }
    }

    private func title(of pane: HerdrPane) -> String {
        let tab = store.snapshot?.tabs.first { $0.tabId == pane.tabId }
        return pane.terminalTitleStripped ?? tab?.label ?? pane.paneId
    }

    private func card(_ pane: HerdrPane, isWide: Bool) -> some View {
        let isSelected = isWide && (selectedTarget?.id == (pane.terminalId ?? pane.paneId))
        let isOpen = expanded.contains(pane.paneId)
        return VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                selectTarget(pane, isWide: isWide)
            } label: {
                HStack(spacing: Space.md) {
                    ZStack(alignment: .topTrailing) {
                        HerdrAgentIcon(agent: pane.agent, size: 38)
                        Circle().fill(herdrStatusColor(pane.agentStatus)).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Palette.fill, lineWidth: 2))
                            .offset(x: 3, y: -3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(of: pane)).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Text("\(pane.agent ?? "shell") · \(herdrStatusLabel(pane.agentStatus)) · \(shortCwd(pane.cwd))")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if isWide {
                        Image(systemName: isSelected ? "chevron.right.circle.fill" : "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(isSelected ? Palette.accent : Palette.textTertiary)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(pane.terminalId == nil && !isWide)
            .accessibilityIdentifier("herdr-pane-\(pane.paneId)")

            if (pane.agent ?? "").isEmpty == false {
                let isOp = operatingPanes.contains(pane.paneId)
                HStack(spacing: Space.sm) {
                    smallButton(isOpen ? "收起" : "看一眼", "eye") { toggleTail(pane) }
                    smallButton("追问", "text.bubble") { askTarget = pane }
                    if pane.agentStatus == .blocked {
                        smallButton(isOp ? "处理中" : "同意", "checkmark", tint: Palette.success) {
                            executeAction(paneId: pane.paneId, keys: ["enter"], successNote: "已同意 (Enter)")
                        }
                        .disabled(isOp)
                        .opacity(isOp ? 0.6 : 1.0)

                        smallButton(isOp ? "处理中" : "拒绝", "xmark", tint: Palette.danger) {
                            executeAction(paneId: pane.paneId, keys: ["esc"], successNote: "已拒绝 (Esc)")
                        }
                        .disabled(isOp)
                        .opacity(isOp ? 0.6 : 1.0)
                    } else if pane.agentStatus == .working {
                        smallButton(isOp ? "处理中" : "中断", "stop.fill", tint: Palette.danger) {
                            executeAction(paneId: pane.paneId, keys: ["ctrl+c"], successNote: "已中断 (Ctrl+C)")
                        }
                        .disabled(isOp)
                        .opacity(isOp ? 0.6 : 1.0)
                    }
                }
                if isOpen {
                    Text((tails[pane.paneId] ?? "读取中…").strippingANSI)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.sm)
                        .background(Palette.surface, in: .rect(cornerRadius: 10))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(Space.md)
        .background(isSelected ? Palette.accent.opacity(0.12) : Palette.fill, in: .rect(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(isSelected ? Palette.accent : Color.clear, lineWidth: 1.5)
        )
    }

    private func smallButton(_ title: String, _ symbol: String, tint: Color = Palette.textPrimary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(tint)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, Space.md).frame(height: 32)
                .background(Palette.surface, in: .capsule)
        }
        .buttonStyle(SoftPressStyle(scale: 0.96))
    }

    private func shortCwd(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "-" }
        return cwd == "/" ? "/" : (cwd as NSString).lastPathComponent
    }

    private func toggleTail(_ pane: HerdrPane) {
        if expanded.contains(pane.paneId) { expanded.remove(pane.paneId); return }
        expanded.insert(pane.paneId)
        Task { tails[pane.paneId] = await store.tail(paneId: pane.paneId, lines: 4) }
    }

    private func selectTarget(_ pane: HerdrPane, isWide: Bool = false) {
        guard let id = pane.terminalId else { return }
        let target = HerdrTerminalTarget.pane(terminalId: id, title: title(of: pane), paneId: pane.paneId, agent: pane.agent)
        if isWide {
            selectedTarget = target
        } else {
            presented = target
        }
    }

    private var currentTarget: HerdrTerminalTarget? {
        if let s = selectedTarget { return s }
        if let first = store.agentPanes.first, let tid = first.terminalId {
            return .pane(terminalId: tid, title: title(of: first), paneId: first.paneId, agent: first.agent)
        }
        return .whole
    }

    private var currentPaneId: String? {
        if case .pane(_, _, let paneId, _) = currentTarget { return paneId }
        return nil
    }
}

// MARK: - 内嵌 Ghostty PTY 终端面板 (针对展开态右栏与悬停上半屏)

struct HerdrEmbeddedTerminalPane: View {
    let endpoint: SSHEndpoint
    let target: HerdrTerminalTarget
    let machineLabel: String
    let route: String
    var isTabletop: Bool = false
    @State private var controller: HerdrPTYController
    @State private var cmd: TerminalPublicStickyActivation = .inactive
    @State private var ctrl: TerminalPublicStickyActivation = .inactive
    @State private var isTabOperating = false
    @AppStorage(HerdrTerminalFont.defaultsKey) private var savedFontSize: Double = Double(HerdrTerminalFont.defaultSize)
    @Environment(HerdrSessionStore.self) private var store

    init(endpoint: SSHEndpoint, target: HerdrTerminalTarget, machineLabel: String, route: String = "", isTabletop: Bool = false) {
        self.endpoint = endpoint
        self.target = target
        self.machineLabel = machineLabel
        self.route = route
        self.isTabletop = isTabletop
        _controller = State(initialValue: HerdrPTYController(endpoint: endpoint, target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(maxWidth: .infinity)
            HerdrSurfaceHost(surface: controller.surface)
                .id(ObjectIdentifier(controller))
                .accessibilityIdentifier("herdr-embedded-terminal-view")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !isTabletop {
                bottomBar
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrTerminalTheme.color)
        .task {
            syncSticky()
            controller.surface.setStickyModifierChangeHandler { syncSticky() }
            controller.surface.onFontSizeChanged = { newSize in
                savedFontSize = Double(newSize)
            }
            if !controller.hasActiveSession {
                controller.start()
            }
        }
        .onChange(of: target.id) { _, _ in
            controller.surface.setStickyModifierChangeHandler(nil)
            controller.surface.onFontSizeChanged = nil
            controller.stop()
            controller = HerdrPTYController(endpoint: endpoint, target: target)
            syncSticky()
            controller.surface.setStickyModifierChangeHandler { syncSticky() }
            controller.surface.onFontSizeChanged = { newSize in
                savedFontSize = Double(newSize)
            }
            if !controller.hasActiveSession {
                controller.start()
            }
        }
        .onDisappear {
            controller.surface.setStickyModifierChangeHandler(nil)
            controller.surface.onFontSizeChanged = nil
            controller.stop()
        }
    }

    private var agentName: String? {
        if case .pane(_, _, _, let agent) = target { return agent }
        return nil
    }

    private var statusDot: Color {
        switch controller.state {
        case .running: Palette.success
        case .connecting: Palette.warning
        case .ended: Palette.danger
        }
    }

    private var topBar: some View {
        HStack(spacing: Space.sm) {
            HerdrAgentIcon(agent: agentName, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(statusDot).frame(width: 6, height: 6)
                    Text([machineLabel, route.isEmpty ? nil : route].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer()
            if controller.state == .connecting || isTabOperating { ProgressView().tint(.white) }
            HStack(spacing: 0) {
                Menu {
                    Section("打开新的 Tab (⌘T)") {
                        ForEach(HerdrNewTabPreset.allCases) { preset in
                            Button {
                                embeddedCreateTab(preset)
                            } label: {
                                Label(preset.title, systemImage: preset.systemImage)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 32)
                        .contentShape(.rect)
                }
                .accessibilityLabel("打开新的 Tab")

                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 0.6, height: 16)

                Button {
                    embeddedCloseTab()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 30, height: 32)
                        .contentShape(.rect)
                }
                .accessibilityLabel("关闭当前 Tab")
            }
            .background(Palette.surface.opacity(0.94), in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))
            Menu {
                Section("新建 Tab") {
                    ForEach(HerdrNewTabPreset.allCases) { preset in
                        Button {
                            embeddedCreateTab(preset)
                        } label: {
                            Label(preset.title, systemImage: preset.systemImage)
                        }
                    }
                }
                Button(role: .destructive) {
                    embeddedCloseTab()
                } label: {
                    Label("关闭当前 Tab (⌘W)", systemImage: "xmark.square")
                }
                Divider()
                Button { controller.start() } label: { Label("重新连接", systemImage: "arrow.clockwise") }
                Section("字号 (\(Int(savedFontSize))pt)") {
                    Button {
                        controller.surface.adjustFont(by: 1)
                        savedFontSize = Double(controller.surface.currentFontSize)
                    } label: { Label("放大 (+1pt)", systemImage: "textformat.size.larger") }
                    .disabled(savedFontSize >= Double(HerdrTerminalFont.maxSize))

                    Button {
                        controller.surface.adjustFont(by: -1)
                        savedFontSize = Double(controller.surface.currentFontSize)
                    } label: { Label("缩小 (-1pt)", systemImage: "textformat.size.smaller") }
                    .disabled(savedFontSize <= Double(HerdrTerminalFont.minSize))

                    Button {
                        controller.surface.resetFont()
                        savedFontSize = Double(controller.surface.currentFontSize)
                    } label: { Label("恢复默认 (\(Int(HerdrTerminalFont.defaultSize))pt)", systemImage: "arrow.counterclockwise") }

                    Picker("快捷字号", selection: Binding(
                        get: { Int(savedFontSize) },
                        set: { newSize in
                            controller.surface.setFontSize(Float(newSize))
                            savedFontSize = Double(newSize)
                        }
                    )) {
                        ForEach([10, 11, 12, 13, 14, 16, 18, 20, 24], id: \.self) { size in
                            Text("\(size) pt").tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.12), in: .circle)
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 44)
        .background(HerdrTerminalTheme.color)
    }

    private func syncSticky() {
        cmd = controller.surface.stickyActivation(for: .command)
        ctrl = controller.surface.stickyActivation(for: .ctrl)
    }

    private func embeddedCreateTab(_ preset: HerdrNewTabPreset) {
        Haptics.impact(.light)
        guard !isTabOperating else { return }
        isTabOperating = true
        Task {
            defer { isTabOperating = false }
            do {
                _ = try await store.openNewTab(preset: preset)
            } catch {
                switch preset {
                case .terminal: _ = controller.surface.sendKey(.q, modifiers: .ctrl)
                case .agy: _ = controller.surface.sendKey(.g, modifiers: .ctrl)
                case .claudeCode: _ = controller.surface.sendKey(.x, modifiers: .ctrl)
                case .pi: _ = controller.surface.sendKey(.p, modifiers: .ctrl)
                }
            }
        }
    }

    private func embeddedCloseTab() {
        Haptics.impact(.medium)
        guard !isTabOperating else { return }
        isTabOperating = true
        let paneId: String? = {
            if case .pane(_, _, let pid, _) = target { return pid }
            return nil
        }()
        Task {
            defer { isTabOperating = false }
            do {
                try await store.closeCurrentTab(paneId: paneId)
            } catch {
                _ = controller.surface.sendKey(.w, modifiers: .ctrl)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        Haptics.selection()
                        controller.surface.toggleStickyModifier(.command)
                        syncSticky()
                    } label: {
                        Text("⌘")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(cmd == .inactive ? .white : Palette.onAccent)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(cmd == .inactive ? Color.white.opacity(0.14) : Palette.accent, in: .capsule)
                    }

                    Button {
                        Haptics.selection()
                        controller.surface.toggleStickyModifier(.ctrl)
                        syncSticky()
                    } label: {
                        Text("ctrl")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ctrl == .inactive ? .white : Palette.onAccent)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(ctrl == .inactive ? Color.white.opacity(0.14) : Palette.accent, in: .capsule)
                    }

                    Menu {
                        Section("打开新的 Tab (⌘T)") {
                            ForEach(HerdrNewTabPreset.allCases) { preset in
                                Button { embeddedCreateTab(preset) } label: {
                                    Label(preset.title, systemImage: preset.systemImage)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text("⌘T").font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.18), in: .capsule)
                    }

                    Button("⌘W") {
                        embeddedCloseTab()
                    }.buttonStyle(.secondaryCompact)

                    Button("⌘V") {
                        if let text = UIPasteboard.general.string, !text.isEmpty {
                            _ = controller.surface.paste(text: text)
                        } else {
                            _ = controller.surface.sendKey(.v, modifiers: .super_)
                        }
                    }.buttonStyle(.secondaryCompact)

                    Button("⌘C") {
                        if !controller.surface.performBindingAction("copy_to_clipboard") {
                            _ = controller.surface.sendKey(.c, modifiers: .super_)
                        }
                    }.buttonStyle(.secondaryCompact)

                    Button("⌘K") {
                        _ = controller.surface.performBindingAction("clear_screen")
                        _ = controller.surface.sendKey(.l, modifiers: .ctrl)
                    }.buttonStyle(.secondaryCompact)

                    Button("⌘[") {
                        _ = controller.surface.sendKey(.comma, modifiers: .ctrl)
                    }.buttonStyle(.secondaryCompact)

                    Button("⌘]") {
                        _ = controller.surface.sendKey(.period, modifiers: .ctrl)
                    }.buttonStyle(.secondaryCompact)

                    Button("Ctrl+C") {
                        _ = controller.surface.sendKey(.c, modifiers: .ctrl)
                    }.buttonStyle(.secondaryCompact)

                    Button("Esc") {
                        _ = controller.surface.sendKey(.escape)
                    }.buttonStyle(.secondaryCompact)

                    Button("Tab") {
                        _ = controller.surface.sendKey(.tab)
                    }.buttonStyle(.secondaryCompact)

                    Button("↑") {
                        _ = controller.surface.sendKey(.arrowUp)
                    }.buttonStyle(.secondaryCompact)

                    Button("↓") {
                        _ = controller.surface.sendKey(.arrowDown)
                    }.buttonStyle(.secondaryCompact)

                    Button("Enter") {
                        _ = controller.surface.sendKey(.enter)
                    }.buttonStyle(.secondaryCompact)
                }
            }

            Button {
                if controller.surface.isFirstResponder {
                    _ = controller.surface.resignFirstResponder()
                } else {
                    _ = controller.surface.becomeFirstResponder()
                }
            } label: {
                Image(systemName: "keyboard")
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 32)
                    .background(Color.white.opacity(0.15), in: .rect(cornerRadius: Radius.sm))
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 6)
        .background(Palette.surface.opacity(0.94))
        .overlay(Rectangle().stroke(Palette.separator.opacity(0.5), lineWidth: 0.5))
    }
}

// MARK: - 派活 Sheet

struct HerdrDispatchSheet: View {
    @Environment(HerdrSessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("herdr.dispatch.kind") private var kindRaw = HerdrAgentKind.pi.rawValue
    @State private var task = ""
    @State private var label = ""
    @State private var sending = false
    @State private var error = ""
    var done: (String) -> Void

    private var kind: HerdrAgentKind { HerdrAgentKind(rawValue: kindRaw) ?? .pi }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("派给谁").font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    ForEach(HerdrAgentKind.allCases) { item in
                        Button { kindRaw = item.rawValue } label: {
                            HStack(spacing: Space.md) {
                                HerdrAgentIcon(agent: item.rawValue, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(TypeScale.rowTitle)
                                    Text(item.hint).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer()
                                if item == kind { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accentText) }
                            }
                            .padding(Space.md)
                            .background(item == kind ? Palette.accent.opacity(0.28) : Palette.fill, in: .rect(cornerRadius: Radius.sm))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("herdr-kind-\(item.rawValue)")
                    }
                    Text("任务").font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary).padding(.top, Space.sm)
                    TextField("自包含地写清楚要做什么、验收怎么看", text: $task, axis: .vertical)
                        .lineLimit(4...10)
                        .padding(Space.md)
                        .background(Palette.fill, in: .rect(cornerRadius: Radius.sm))
                        .accessibilityIdentifier("herdr-dispatch-task")
                    TextField("tab 名（可选，默认取任务开头）", text: $label)
                        .padding(Space.md)
                        .background(Palette.fill, in: .rect(cornerRadius: Radius.sm))
                    Text("会在 \(store.selectedMachine?.label ?? "这台机器") 新开一个 tab，agent 在里面干活；改文件的活请在电脑上用 herdr_dispatch.sh 带范围派。")
                        .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    if !error.isEmpty { InlineNotice(text: error, tone: .danger) }
                }
                .padding(Layout.margin)
            }
            .navigationTitle("派活")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { send() } label: { sending ? AnyView(ProgressView()) : AnyView(Text("派出")) }
                        .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                        .accessibilityIdentifier("herdr-dispatch-send")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func send() {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? String(text.prefix(12)) : label
        sending = true
        error = ""
        Task {
            do {
                let id = try await store.dispatch(kind: kind, label: "\(kind.title)·\(name)", task: text, cwd: nil)
                done(id)
            } catch {
                self.error = "\(error.localizedDescription)"
            }
            sending = false
        }
    }
}

// MARK: - 追问 Sheet

struct HerdrAskSheet: View {
    let pane: HerdrPane
    @Environment(HerdrSessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("\(pane.agent ?? "agent") · \(pane.terminalTitleStripped ?? pane.paneId)")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                TextField("追加一句", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .padding(Space.md)
                    .background(Palette.fill, in: .rect(cornerRadius: Radius.sm))
                    .accessibilityIdentifier("herdr-ask-text")
                if !error.isEmpty { InlineNotice(text: error, tone: .danger) }
                Spacer()
            }
            .padding(Layout.margin)
            .navigationTitle("追问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        sending = true
                        Task {
                            if let e = await store.ask(paneId: pane.paneId, text: text) { error = e } else { dismiss() }
                            sending = false
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                    .accessibilityIdentifier("herdr-ask-send")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
