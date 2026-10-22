// Root navigation, sheets, and the app-lock cover.
import SwiftUI
import ComCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var keyboardVisible = false
    /// r3-work：哪个 tab 的根页被推到了下一层（今天页的详情）。那时全局顶栏让位给系统导航栏。
    @State private var pushed: Set<SectionTab> = []
    @State private var screenWidth: CGFloat = 0
    /// 折痕（官方：向 GeometryProxy 要 reservedRegions(kind: .division)）：半折叠时是内屏上一条有宽度的活动区域，摊平 / 合上时没有。
    @State private var crease: CGRect?
    @State private var hingeTick = 0
    @Namespace private var details
    @AppStorage("appearance") private var appearance = "light"
    @State private var lock = AppLock.shared
    var body: some View {
        Group {
            if model.isPaired { paired } else { PairingView() }
        }
        .environment(\.detailSpace, details)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .overlay {
            if lock.isCovering {
                LockScreen().environment(lock)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .overlay {
            if [.recording, .transcribing].contains(model.voice.phase) {
                ScreenEdgeGlow(level: model.voice.level, processing: model.voice.phase == .transcribing)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: [.recording, .transcribing].contains(model.voice.phase))
        .modifier(RootSheets())
        .modifier(RootEvents(keyboardVisible: $keyboardVisible))
        .tint(Palette.textPrimary)
    }
    private var paired: some View {
        @Bindable var model = model
        let wide = screenWidth >= Self.splitMinWidth
        // 折痕是竖条（展开横拿、半折叠）：左右栏各占折痕两边，折痕那一条留空；其他情况按固定比例分栏。
        let vertical = crease.flatMap { $0.width > 0 && $0.height > $0.width ? $0 : nil }
        let leftWidth = vertical.map { $0.minX.rounded() } ?? Self.leftPaneWidth(for: screenWidth)
        let gap = vertical?.width.rounded() ?? 0
        let sidebar = wide ? min(340, leftWidth - 40) + 40 : WorkSidebarLayer.width(for: screenWidth)
        let base: CGFloat = model.showWorkSidebar ? sidebar : 0
        let open = min(1, max(0, (base + model.workSidebarDrag) / sidebar))
        let barHidden = pushed.contains(wide ? .chat : model.tab)
        let rightBarHidden = pushed.contains(model.rightTab)
        return ZStack(alignment: .top) {
            // 主内容：页面 + Dock + 工作台 + 顶栏。工作页开侧栏时整块往右推走，Dock 跟着淡出。
            ZStack(alignment: .top) {
                if wide {
                    splitContent(leftWidth: leftWidth, gap: gap, rightBarHidden: rightBarHidden)
                } else {
                    tabHost(SectionTab.dock, selection: $model.tab)
                        .onChange(of: model.tab) { _, tab in
                            Task { await model.refresh(tab) }; model.showMenu = false
                            if tab != .work { model.showWorkSidebar = false; model.workSidebarDrag = 0; model.workSidebarMounted = false }
                        }
                        // Dock 只有一条，放在 TabView 外面：放进每个 tab 的话，切页时旧 Dock 和新 Dock 会一起淡入淡出，胶囊撑开的动画就看不到了。
                        .overlay(alignment: .bottom) { if !SectionTab.typing.contains(model.tab) || !keyboardVisible { ComDock().opacity(Double(1 - open)) } }
                }
                // 工作台在顶栏下面一层：没拉开时完全透明、不接触摸；拉开的过程跟着手指长出来。
                StagePanel().zIndex(2)
                // 顶栏也只有一条（r3-work）：她是全 App 唯一的实例，切页不重建、不挪位。进详情页时往左淡出让位。
                ComTopBar(pinned: wide ? .chat : nil)
                    .frame(width: wide ? leftWidth : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(barHidden ? 0 : 1).offset(x: barHidden ? -40 : 0)
                    .allowsHitTesting(!barHidden).accessibilityHidden(barHidden)
                    .animation(reduce ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.32), value: barHidden)
                    .zIndex(3)
            }
            .overlay {
                // 侧栏开着时，主内容只剩右边一条：压暗；点它、往左拖都收起。
                if open > 0 {
                    Color.black.opacity(0.22 * Double(open)).ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { model.closeWorkSidebar(reduce: reduce) }
                        .gesture(sidebarDrag(sidebar))
                        .accessibilityLabel("收起历史对话").accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("work-sidebar-dismiss")
                }
            }
            .offset(x: sidebar * open)
            .overlay(alignment: .leading) {
                // 工作页从左边缘往右拉：侧栏跟着手指出来。
                if model.isShown(.work) && !model.showWorkSidebar && !(wide ? rightBarHidden : barHidden) {
                    Color.clear.frame(width: 20).contentShape(Rectangle()).gesture(sidebarDrag(sidebar))
                }
            }
            // 侧栏：从左滑进来，占满整屏高度（连原来 Dock 那一截）。点按钮打开时随主内容同一条弹簧滑进来（move 进场），
            // 拖动时跟手（offset），收起时沿 offset 回去、走完才拿掉。
            if model.workSidebarMounted {
                WorkSidebarLayer(width: sidebar)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: -sidebar * (1 - open))
                    .transition(reduce ? .opacity : .move(edge: .leading))
                    .zIndex(4)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0; model.splitView = $0 >= Self.splitMinWidth }
        .background { CreaseProbe(tick: hingeTick) { crease = $0 } }
        .modifier(HingeWatch { hingeTick += 1 })
        // 折痕上不放交互元素：不管下面是什么，这一条不接触摸（官方只给了区域，怎么避开由 App 定）。
        .overlay(alignment: .topLeading) {
            if let crease, crease.width > 0, crease.height > 0 {
                Color.clear.frame(width: crease.width, height: crease.height)
                    .contentShape(Rectangle()).onTapGesture {}
                    .offset(x: crease.minX, y: crease.minY)
                    .accessibilityHidden(true)
            }
        }
        // 折叠 / 展开会整块重建页面：旧页面的 onDisappear 晚于新页面的 onAppear，会把顶栏误判成「进了详情」而藏起来。
        // 宽窄一换就清零，随后各页自己的 onAppear 会把真正推进详情的那几页补回来。
        .onChange(of: wide) { _, _ in pushed = [] }
        // 别处要打开某段工作会话（任务详情、项目看板、派活页）：切到工作页原地打开，不再弹 WorkDetailView。
        .onChange(of: model.selectedSession) { _, session in
            guard let session else { return }
            model.selectedSession = nil
            model.work.open(session)
            model.showWorkSidebar = false; model.workSidebarDrag = 0; model.workSidebarMounted = false
            if model.tab != .work { withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.46, dampingFraction: 0.66)) { model.tab = .work } }
        }
    }
    /// 展开的折叠屏：宽度到这个值就换成左右双栏（iPhone Duo 展开横屏约 951pt；竖拿约 669pt 仍是单栏）。
    static let splitMinWidth: CGFloat = 700
    static func leftPaneWidth(for screen: CGFloat) -> CGFloat { min(420, max(360, (screen * 0.42).rounded())) }

    /// 一组页面各自带导航栈，切页保留各自的状态；Dock 另外画在外面。
    private func tabHost(_ tabs: [SectionTab], selection: Binding<SectionTab>) -> some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                Tab(tab.rawValue, systemImage: tab.symbol, value: tab) {
                    NavigationStack {
                        page(tab)
                            // 根页被推走（还停在这个 tab）= 进了详情；回到根页再把顶栏请回来。
                            .onAppear { pushed.remove(tab) }
                            .onDisappear { if selection.wrappedValue == tab { pushed.insert(tab) } }
                    }
                    .toolbar(.hidden, for: .tabBar)
                }
            }
        }
    }

    /// 展开后的双栏：左边 Com 主对话（顶栏上的她留在左栏），右边一个工作页面（自己的标题栏 + Dock）。
    private func splitContent(leftWidth: CGFloat, gap: CGFloat, rightBarHidden: Bool) -> some View {
        @Bindable var model = model
        return HStack(spacing: 0) {
            NavigationStack {
                page(.chat, dock: false)
                    .onAppear { pushed.remove(.chat) }
                    .onDisappear { pushed.insert(.chat) }
            }
            .frame(width: leftWidth)
            // 半折叠时这里是折痕：不画线、不放任何东西；摊平时是一条分隔线。
            if gap > 0 { Color.clear.frame(width: gap) } else { Rectangle().fill(Palette.separator).frame(width: 1).ignoresSafeArea() }
            tabHost(SectionTab.workspace, selection: Binding(get: { model.rightTab }, set: { model.tab = $0 }))
                .onChange(of: model.rightTab) { _, tab in
                    Task { await model.refresh(tab) }; model.showMenu = false
                    if tab != .work { model.showWorkSidebar = false; model.workSidebarDrag = 0; model.workSidebarMounted = false }
                }
                .overlay(alignment: .top) {
                    PaneBar(tab: model.rightTab)
                        .opacity(rightBarHidden ? 0 : 1).allowsHitTesting(!rightBarHidden)
                        .animation(reduce ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.32), value: rightBarHidden)
                }
                .overlay(alignment: .bottom) {
                    if !SectionTab.typing.contains(model.rightTab) || !keyboardVisible { ComDock(tabs: SectionTab.workspace) }
                }
        }
    }

    /// 拖侧栏：开着时往左拖收起，关着时（左边缘）往右拉出来；跟手，松手按速度和位置决定。
    private func sidebarDrag(_ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) || model.workSidebarDrag != 0 else { return }
                let base: CGFloat = model.showWorkSidebar ? width : 0
                model.dragWorkSidebar(min(width, max(0, base + value.translation.width)) - base)
            }
            .onEnded { value in
                guard model.workSidebarDrag != 0 else { return }
                // 松手的弹簧放到下一轮，免得和最后一次跟手更新挤在同一帧被吞掉。
                let predicted = value.predictedEndTranslation.width
                DispatchQueue.main.async { model.settleWorkSidebar(predicted: predicted, width: width, reduce: reduce) }
            }
    }
    @ViewBuilder private func page(_ tab: SectionTab, dock: Bool = true) -> some View {
        Group {
            switch tab { case .chat: ChatView(); case .next: NextView(); case .doing: TodayView(); case .health: HealthView(); case .work: WorkView() }
        }
        // 顶栏在 RootView 最上层只有一条（r3-work）：这里只给它让出高度，内容从它下面滑过。
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Layout.topBar) }
        // 给上面那条 Dock 留位置；聊天页和工作页打字时让位给键盘。
        .safeAreaInset(edge: .bottom, spacing: 0) { if dock && (!SectionTab.typing.contains(tab) || !keyboardVisible) { Color.clear.frame(height: ComDock.height) } }
    }
}

/// Every sheet the root presents, kept out of the body so the type-checker stays fast.
private struct RootSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.showQuickVoice) { QuickVoiceView().presentationDetents([.height(360), .medium]).presentationDragIndicator(.visible).presentationBackground(Palette.background).interactiveDismissDisabled(model.voice.phase == .recording || model.voice.phase == .transcribing) }
            .sheet(isPresented: $model.showSettings) { SettingsView() }
            .sheet(isPresented: $model.showShareInbox) { ShareInboxView().presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
            .sheet(isPresented: $model.showSearch) { SearchView() }
            .sheet(isPresented: $model.showMemory) { MemorySheet() }
            .sheet(isPresented: $model.showFinance) { FinanceDetail(initialPeriod: "本月", initialCurrency: model.datasets["/personal/finance"]?["currencies"].array.first?.id ?? "") }
            .sheet(isPresented: $model.showConnectors) { ConnectorsSheet() }
            .sheet(isPresented: $model.showNewWork) { NewWorkView(initialAgent: "codex") }
            .modifier(RootItemSheets())
    }
}

private struct RootItemSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { model.selectedConnector.map(RemoteRow.init) }, set: { model.selectedConnector = $0?.value })) { ConnectorSheet(source: $0.value) }
            .sheet(item: Binding(get: { model.selectedTask.map(RemoteRow.init) }, set: { model.selectedTask = $0?.value })) { TaskDetailView(task: $0.value).presentationDragIndicator(.visible) }
            .sheet(item: Binding(get: { model.selectedMatter.map(RemoteRow.init) }, set: { model.selectedMatter = $0?.value })) { MatterDetailView(matter: $0.value).presentationDragIndicator(.visible) }
            // 10-17 航程：聊天里的航程卡、今天页、推送深链都从这里打开
            .sheet(item: Binding(get: { model.presentedCase.map { RemoteRow(.object(["id": .string($0)])) } }, set: { model.presentedCase = $0?.id })) { CaseSheet(id: $0.id) }
            .sheet(isPresented: Binding(get: { model.showCases }, set: { model.showCases = $0 })) { CasesSheet() }
            .sheet(isPresented: Binding(get: { model.showWaiting }, set: { model.showWaiting = $0 })) { WaitingSheet() }
    }
}

private struct RootEvents: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var keyboardVisible: Bool
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .comOpenMessage)) { event in
                if event.userInfo?["section"] as? String == "tasks" { model.tab = .doing; return }
                model.tab = .chat
                if let id = event.object as? String, !id.isEmpty { Task { await model.locateMessage(id) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .comOpenApproval)) { event in
                guard let sid = event.userInfo?["sid"] as? String, !sid.isEmpty else { model.tab = .work; return }
                model.tab = .work
                model.work.open(.object(["id": .string(sid), "agent": .string("codex")]))
                Task { await model.work.refresh(model) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .comApprovalResolved)) { _ in
                Task { await model.work.refresh(model) }
            }
            .alert("Com", isPresented: Binding(get: { !model.banner.isEmpty }, set: { if !$0 { model.banner = "" } })) {
                Button("知道了") { model.banner = "" }
            } message: { Text(model.banner) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                      let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first(where: \.isKeyWindow) else { return }
                let keyboard = window.convert(frame, from: nil)
                let visible = window.bounds.intersection(keyboard).height > window.safeAreaInsets.bottom + 1
                let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                withAnimation(.easeOut(duration: duration)) { keyboardVisible = visible }
            }
            .onReceive(NotificationCenter.default.publisher(for: .comVoiceIntent)) { _ in
                UserDefaults.standard.set(false, forKey: "openVoiceIntent")
                model.openVoice(quick: true)
            }
    }
}

/// 记忆页从菜单打开：文件夹 → 明细 → 单条，都在这一个导航栈里推进。
struct MemorySheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            MemoryView()
                // 轨道 r2-memory：大标题（带排序下拉）画在 MemoryView 内容里，系统标题用 inline 让位。
                .navigationTitle("记忆").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Palette.background, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { model.showMemory = false } } }
                .task { _ = await model.load("/personal/memory") }
        }
    }
}

struct ConnectorsSheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            ConnectionsView()
                .toolbarBackground(Palette.background, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { model.showConnectors = false } } }
        }
    }
}

struct ConnectorSheet: View {
    @Environment(AppModel.self) private var model
    let source: JSON
    var body: some View {
        NavigationStack {
            ConnectionDetail(source: source)
                .toolbarBackground(Palette.background, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { model.selectedConnector = nil } } }
        }
    }
}

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var loading = false
    @State private var error = ""
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollPage(spacing: Space.xxl) {
                Companion(state: .think).frame(height: 170).padding(.top, Space.xl)
                VStack(alignment: .leading, spacing: Space.md) {
                    Eyebrow(text: "YOUR PERSONAL AGENT")
                    Text("随时，\n与你一起。").font(TypeScale.largeTitle).lineSpacing(4)
                    Text("连接你的 Mac mini，让邮件、日历、账本和两台电脑上的工作在这里汇合。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary).lineSpacing(4)
                }
                VStack(alignment: .leading, spacing: Space.lg) {
                    GroupedCard {
                        TextField("HTTPS 服务地址", text: $model.base).font(TypeScale.callout).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("server-address").rowPadding()
                        TextField("一次性配对码", text: $code).font(TypeScale.callout).keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("pair-code").rowPadding()
                    }
                    Button {
                        loading = true
                        Task { do { try await model.pair(code: code) } catch { self.error = error.localizedDescription }; loading = false }
                    } label: {
                        HStack { Text("开始连接"); Spacer(); if loading { ProgressView().tint(Palette.onInk) } else { Image(systemName: "arrow.right") } }
                    }.buttonStyle(.primaryFull).disabled(loading || code.isEmpty)
                    if !error.isEmpty { InlineNotice(text: error) }
                }
                Text("配对码在 Mac mini 上生成。账号凭据留在这台 iPhone 的钥匙串中。也可以让已配对的设备出示二维码，用相机扫码自动填入。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
            .onAppear {
                if let pending = UserDefaults.standard.string(forKey: "pendingPairCode"), !pending.isEmpty {
                    code = pending
                    UserDefaults.standard.removeObject(forKey: "pendingPairCode")
                }
            }
        }
    }
}

/// 读折痕：iOS 27.1 起 GeometryProxy 能给出 .division 区域；只取活动的那条（半折叠），换成 id 重建来强制重读。
private struct CreaseProbe: View {
    let tick: Int
    let update: (CGRect?) -> Void
    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect?.self) { proxy in
                if #available(iOS 27.1, *) { return proxy.reservedRegions(kind: .division).first(where: \.isActive)?.frame }
                return nil
            } action: { update($0) }
            .id(tick)
    }
}

/// 铰链状态一变（合上 / 半折叠 / 完全展开）就让上面重读一次折痕。
private struct HingeWatch: ViewModifier {
    let changed: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) { content.onHingeChange { _, _ in changed() } } else { content }
    }
}
