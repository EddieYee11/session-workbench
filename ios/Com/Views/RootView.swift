import SwiftUI
import ComCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var keyboardVisible = false
    /// r3-work：哪个 tab 的根页被推到了下一层（今天页的详情）。那时全局顶栏让位给系统导航栏。
    @State private var pushed: Set<SectionTab> = []
    @State private var screenWidth: CGFloat = 0
    @Namespace private var details
    @AppStorage("appearance") private var appearance = "light"
    var body: some View {
        Group {
            if model.isPaired { paired } else { PairingView() }
        }
        .environment(\.detailSpace, details)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .modifier(RootSheets())
        .modifier(RootEvents(keyboardVisible: $keyboardVisible))
        .tint(Palette.textPrimary)
    }
    private var paired: some View {
        @Bindable var model = model
        let sidebar = WorkSidebarLayer.width(for: screenWidth)
        let base: CGFloat = model.showWorkSidebar ? sidebar : 0
        let open = min(1, max(0, (base + model.workSidebarDrag) / sidebar))
        let barHidden = pushed.contains(model.tab)
        return ZStack(alignment: .top) {
            // 主内容：页面 + Dock + 工作台 + 顶栏。工作页开侧栏时整块往右推走，Dock 跟着淡出。
            ZStack(alignment: .top) {
                TabView(selection: $model.tab) {
                    ForEach(SectionTab.dock) { tab in
                        Tab(tab.rawValue, systemImage: tab.symbol, value: tab) {
                            NavigationStack {
                                page(tab)
                                    // 根页被推走（还停在这个 tab）= 进了详情；回到根页再把顶栏请回来。
                                    .onAppear { pushed.remove(tab) }
                                    .onDisappear { if model.tab == tab { pushed.insert(tab) } }
                            }
                            .toolbar(.hidden, for: .tabBar)
                        }
                    }
                }
                .onChange(of: model.tab) { _, tab in
                    Task { await model.refresh(tab) }; model.showMenu = false
                    if tab != .work { model.showWorkSidebar = false; model.workSidebarDrag = 0; model.workSidebarMounted = false }
                }
                // Dock 只有一条，放在 TabView 外面：放进每个 tab 的话，切页时旧 Dock 和新 Dock 会一起淡入淡出，胶囊撑开的动画就看不到了。
                .overlay(alignment: .bottom) { if !SectionTab.typing.contains(model.tab) || !keyboardVisible { ComDock().opacity(Double(1 - open)) } }
                // 工作台在顶栏下面一层：没拉开时完全透明、不接触摸；拉开的过程跟着手指长出来。
                StagePanel().zIndex(2)
                // 顶栏也只有一条（r3-work）：她是全 App 唯一的实例，切页不重建、不挪位。进详情页时往左淡出让位。
                ComTopBar()
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
                if model.tab == .work && !model.showWorkSidebar && !barHidden {
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
        // 别处要打开某段工作会话（任务详情、项目看板、派活页）：切到工作页原地打开，不再弹 WorkDetailView。
        .onChange(of: model.selectedSession) { _, session in
            guard let session else { return }
            model.selectedSession = nil
            model.work.open(session)
            model.showWorkSidebar = false; model.workSidebarDrag = 0; model.workSidebarMounted = false
            if model.tab != .work { withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.46, dampingFraction: 0.66)) { model.tab = .work } }
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
    @ViewBuilder private func page(_ tab: SectionTab) -> some View {
        Group {
            switch tab { case .chat: ChatView(); case .next: NextView(); case .doing: TodayView(); case .work: WorkView() }
        }
        // 顶栏在 RootView 最上层只有一条（r3-work）：这里只给它让出高度，内容从它下面滑过。
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Layout.topBar) }
        // 给上面那条 Dock 留位置；聊天页和工作页打字时让位给键盘。
        .safeAreaInset(edge: .bottom, spacing: 0) { if !SectionTab.typing.contains(tab) || !keyboardVisible { Color.clear.frame(height: ComDock.height) } }
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
                Text("配对码在 Mac mini 上生成。账号凭据留在这台 iPhone 的钥匙串中。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
        }
    }
}
