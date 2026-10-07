import SwiftUI
import ComCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var keyboardVisible = false
    @Namespace private var details
    @AppStorage("appearance") private var appearance = "light"
    var body: some View {
        @Bindable var model = model
        Group {
            if model.isPaired {
                TabView(selection: $model.tab) {
                    ForEach(SectionTab.allCases) { tab in
                        Tab(tab.rawValue, systemImage: tab.symbol, value: tab) {
                            NavigationStack {
                                page(tab)
                                    .toolbar { chrome(tab) }
                                    .safeAreaInset(edge: .bottom, spacing: 0) { if tab != .chat || !keyboardVisible { ComDock() } }
                            }
                            .toolbar(.hidden, for: .tabBar)
                        }
                    }
                }
                .onChange(of: model.tab) { _, tab in Task { await model.refresh(tab) }; Haptics.selection() }
            } else { PairingView() }
        }
        .environment(\.detailSpace, details)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .sheet(isPresented: $model.showQuickVoice) { QuickVoiceView().presentationDetents([.height(360), .medium]).presentationDragIndicator(.visible).presentationBackground(Palette.background).interactiveDismissDisabled(model.voice.phase == .recording || model.voice.phase == .transcribing) }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(isPresented: $model.showShareInbox) { ShareInboxView().presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $model.showSearch) { SearchView() }
        .sheet(item: Binding(get: { model.selectedTask.map(RemoteRow.init) }, set: { model.selectedTask = $0?.value })) { TaskDetailView(task: $0.value).presentationDragIndicator(.visible) }
        .sheet(item: Binding(get: { model.selectedMemory.map(RemoteRow.init) }, set: { model.selectedMemory = $0?.value })) { MemoryDetailView(memory: $0.value).presentationDragIndicator(.visible) }
        .sheet(item: Binding(get: { model.selectedMatter.map(RemoteRow.init) }, set: { model.selectedMatter = $0?.value })) { MatterDetailView(matter: $0.value).presentationDragIndicator(.visible) }
        .sheet(item: Binding(get: { model.selectedSession.map(RemoteRow.init) }, set: { model.selectedSession = $0?.value })) { WorkDetailView(session: $0.value) }
        .onReceive(NotificationCenter.default.publisher(for: .comOpenMessage)) { event in
            model.tab = .chat
            if let id = event.object as? String { Task { await model.locateMessage(id) } }
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
        .tint(Palette.textPrimary)
    }
    /// One toolbar for every tab: avatar menu · search + settings. Chat adds its identity as principal.
    @ToolbarContentBuilder private func chrome(_ tab: SectionTab) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { MainMenu() }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("搜索聊天与成果", systemImage: "magnifyingglass") { model.showSearch = true }
            Button("设置与连接", systemImage: "slider.horizontal.3") { model.showSettings = true }
        }
    }
    @ViewBuilder private func page(_ tab: SectionTab) -> some View {
        switch tab { case .chat: ChatView(); case .today: TodayView(); case .tasks: TasksView(); case .memory: MemoryView(); case .work: WorkView() }
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
                Companion().frame(height: 210).padding(.top, Space.xl)
                VStack(alignment: .leading, spacing: Space.md) {
                    Eyebrow(text: "YOUR PERSONAL AGENT")
                    Text("随时，\n与你一起。").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("连接你的 Mac mini，让对话、工作与生活在这里汇合。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary)
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
                        HStack { Text("开始连接"); Spacer(); if loading { ProgressView().tint(Palette.onAccent) } else { Image(systemName: "arrow.right") } }
                    }.buttonStyle(.primaryFull).disabled(loading || code.isEmpty)
                    if !error.isEmpty { InlineNotice(text: error) }
                }
                Text("配对码在 Mac mini 上生成。账号凭据留在这台 iPhone 的钥匙串中。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
        }
    }
}
