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
                                    .safeAreaInset(edge: .top, spacing: 0) {
                                        CompanionHeader()
                                    }
                                    .safeAreaInset(edge: .bottom, spacing: 0) { if tab != .chat || !keyboardVisible { ComDock() } }
                                    .toolbar(.hidden, for: .navigationBar)
                            }
                            .toolbar(.hidden, for: .tabBar)
                        }
                    }
                }
                .tint(Palette.violet)
                .onChange(of: model.tab) { _, tab in Task { await model.refresh(tab) }; Haptics.selection() }
            } else { PairingView() }
        }
        .environment(\.detailSpace, details)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .sheet(isPresented: $model.showQuickVoice) { QuickVoiceView().presentationDetents([.height(360), .medium]).presentationDragIndicator(.visible).presentationBackground(Palette.canvas).interactiveDismissDisabled(model.voice.phase == .recording || model.voice.phase == .transcribing) }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(isPresented: $model.showShareInbox) { ShareInboxView() }
        .sheet(isPresented: $model.showSearch) { SearchView() }
        .sheet(item: Binding(get: { model.selectedTask.map(RemoteRow.init) }, set: { model.selectedTask = $0?.value })) { TaskDetailView(task: $0.value) }
        .sheet(item: Binding(get: { model.selectedMemory.map(RemoteRow.init) }, set: { model.selectedMemory = $0?.value })) { MemoryDetailView(memory: $0.value) }
        .sheet(item: Binding(get: { model.selectedMatter.map(RemoteRow.init) }, set: { model.selectedMatter = $0?.value })) { MatterDetailView(matter: $0.value) }
        .sheet(item: Binding(get: { model.selectedSession.map(RemoteRow.init) }, set: { model.selectedSession = $0?.value })) { WorkDetailView(session: $0.value) }
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
        .onReceive(NotificationCenter.default.publisher(for: .comVoiceIntent)) { _ in model.openVoice(quick: true) }
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
            PageCanvas {
                Companion().frame(height: 230).padding(.top, 20)
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "YOUR PERSONAL AGENT")
                    Text("随时，\n与你一起。").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("连接你的 Mac mini，让对话、工作与生活在这里汇合。").foregroundStyle(.secondary)
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("HTTPS 服务地址", text: $model.base).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("server-address")
                        Divider()
                        TextField("一次性配对码", text: $code).keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("pair-code")
                        Button {
                            loading = true
                            Task { do { try await model.pair(code: code) } catch { self.error = error.localizedDescription }; loading = false }
                        } label: {
                            HStack { Text("开始连接"); Spacer(); if loading { ProgressView() } else { Image(systemName: "arrow.right") } }.padding(.vertical, 9)
                        }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(loading || code.isEmpty)
                        if !error.isEmpty { Text(error).font(TypeScale.footnote).foregroundStyle(Palette.coral) }
                    }
                }
                Text("配对码在 Mac mini 上生成。账号凭据留在这台 iPhone 的钥匙串中。").font(TypeScale.footnote).foregroundStyle(.secondary)
            }.tint(Palette.violet)
        }
    }
}
