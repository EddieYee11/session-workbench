import SwiftUI
import WebKit
import ComCore
import QuickLook

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "light"
    @AppStorage("appLockEnabled") private var appLock = false
    @AppStorage("voice.pauseToSend") private var voicePause = 0.9
    @State private var showPairCode = false
    @State private var disconnecting = false
    @State private var notificationNote = ""
    var body: some View {
        @Bindable var devices = model.devices!
        let unresolved = SecureVault.operationRecords().filter { $0["status"].string == "unknown" }
        NavigationStack {
            ScrollPage(spacing: Space.xxl) {
                NavigationLink { AgencySettings() } label: { NavigationRowLabel(title: "主动性与晨晚报", symbol: "sun.max") }.buttonStyle(.row)
                settingsGroup(title: "主动消息通知", footer: "晨报与主动消息写入主聊天。后台读取由 iOS 安排，可能延迟；08:00–23:00 通知，锁屏不显示对话正文。") {
                    Button("开启新消息通知", systemImage: "bell.badge") {
                        Task { notificationNote = await ComNotifications.enable() ? "通知已开启" : "未开启，请到系统设置允许通知" }
                    }.buttonStyle(.quiet).rowPadding()
                    if !notificationNote.isEmpty { Text(notificationNote).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).rowPadding() }
                }
                settingsGroup(title: "快捷语音", footer: "设置 → 操作按钮 → 快捷指令 → Com 语音。打开即录音；停顿达到设定时长自动转写并发送。说「停 / 取消 / 不用了」只会结束这次录音，不发送。") {
                    Button { dismiss(); model.openVoice(quick: true) } label: { NavigationRowLabel(title: "打开光效语音小窗", symbol: "waveform") }.buttonStyle(.row)
                    HStack {
                        Text("停顿多久自动发送").font(TypeScale.callout)
                        Spacer()
                        Picker("停顿多久自动发送", selection: $voicePause) {
                            Text("0.6 秒").tag(0.6); Text("0.9 秒").tag(0.9); Text("1.2 秒").tag(1.2); Text("1.8 秒").tag(1.8)
                        }.pickerStyle(.menu).tint(Palette.textSecondary)
                    }.padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                }
                settingsGroup(title: "外观", footer: "大字体、VoiceOver、减少动态效果和降低透明度跟随系统设置。") {
                    HStack {
                        Text("主题").font(TypeScale.callout)
                        Spacer()
                        Picker("主题", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                            .pickerStyle(.menu).tint(Palette.textSecondary)
                    }.padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                }
                settingsGroup(title: "隐私", footer: "开启后，离开 Com 超过 30 秒回来要先解锁；切到后台时先盖上，任务切换器里不会露出对话。只保护本机界面，不改变服务端权限。") {
                    Toggle("应用锁（Face ID / 设备密码）", isOn: $appLock)
                        .font(TypeScale.callout).tint(Palette.accentText)
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                        .disabled(!AppLock.shared.available)
                    if appLock {
                        Button("立即上锁") { AppLock.shared.lockNow(); dismiss() }
                            .buttonStyle(.quiet).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    }
                    if !AppLock.shared.available {
                        Text("这台设备还没有设置设备密码，无法使用应用锁。")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).rowPadding()
                    }
                }
                settingsGroup(title: "连接", footer: "手机退到后台后，任务继续在 mini 上执行。重新打开时会补取最新状态。") {
                    settingsRow(label: "服务", value: model.base)
                    settingsRow(label: "实时对话", value: model.streaming ? "已连接" : "缓存模式")
                    settingsRow(label: "手机能力", value: devices.connected ? "已连接" : "未连接")
                    if !devices.note.isEmpty { Text(devices.note).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity, alignment: .leading).rowPadding() }
                    Button("刷新连接") { Task { await model.setActive(true) } }.buttonStyle(.quiet).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    Button { showPairCode = true } label: { NavigationRowLabel(title: "配对另一台设备", symbol: "qrcode") }.buttonStyle(.row)
                }
                settingsGroup(title: "服务器", footer: "只读诊断，不会重启或改动 mini。审批数、运行中会话和可用 Agent 来自 /status；磁盘是 mini 用户目录所在卷。") {
                    let status = model.datasets["/status"] ?? .null
                    settingsRow(label: "主机", value: status["host"].string.isEmpty ? "Mac mini" : status["host"].string)
                    settingsRow(label: "已索引会话", value: "\(status["index"].int) · 运行中 \(status["running"].int)")
                    settingsRow(label: "等你审批", value: "\(status["approvals"].int)")
                    settingsRow(label: "可用 Agent", value: [status["agents"]["pi"].bool ? "Pi" : "", status["agents"]["codex"].bool ? "Codex" : ""].filter { !$0.isEmpty }.joined(separator: " / "))
                    settingsRow(label: "磁盘余量", value: String(format: "%.1f GB", status["disk_free_gb"].double))
                    settingsRow(label: "通知通道", value: status["push"].string.isEmpty ? "后台刷新" : status["push"].string)
                    settingsRow(label: "已运行", value: "\(status["uptime"].int / 3600) 小时")
                    Button("刷新服务器状态") { Task { _ = await model.load("/status") } }.buttonStyle(.quiet).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                }
                settingsGroup(title: "数据来源") {
                    NavigationLink { ConnectionsView() } label: { NavigationRowLabel(title: "管理数据连接", symbol: "link") }.buttonStyle(.row)
                }
                GroupSection("本机健康数据", footer: "读取留在本机；同步到 mini 在下面单独开启。") { HealthCard() }
                settingsGroup(title: "首次使用时授权") {
                    permission("健康 · 只读", "heart", "health")
                    permission("日历", "calendar", "calendar")
                    permission("提醒事项", "checklist", "reminders")
                    permission("联系人", "person.crop.circle", "contacts")
                    permission("使用期间的位置", "location", "location")
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                        NavigationRowLabel(title: "打开系统权限设置", symbol: "gear")
                    }.buttonStyle(.row)
                }
                settingsGroup(title: "设备结果同步", footer: "开启后，已授权范围内的数据可供 mini 处理你的交办。健康包括步数、活动能量、心率、静息心率、睡眠和运动；联系人查询仅返回符合交办条件的结果。关闭会停止后续设备读取；已交办的结果可能已保存在服务端。") {
                    Toggle("向 mini 提供健康摘要", isOn: $devices.healthSync).font(TypeScale.callout).tint(Palette.accentText).padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                    Toggle("向 mini 提供联系人查询结果", isOn: $devices.contactsSync).font(TypeScale.callout).tint(Palette.accentText).padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                }
                .onChange(of: devices.healthSync) { _, _ in Task { await devices.updateSync() } }
                .onChange(of: devices.contactsSync) { _, _ in Task { await devices.updateSync() } }
                GroupedCard {
                    Button { dismiss(); model.showShareInbox = true } label: { NavigationRowLabel(title: "分享收件箱", symbol: "tray.and.arrow.down") }.buttonStyle(.row)
                }
                settingsGroup(title: "发送记录") {
                    if model.pending.isEmpty {
                        Text("还没有本机发送记录").font(TypeScale.callout).foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    } else {
                        ForEach(Array(model.pending.reversed().enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(entry.text.isEmpty ? "恢复工作会话" : entry.text).font(TypeScale.callout).lineLimit(3)
                                Text(entry.note + " · " + entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                                if entry.state == .uncertain || entry.state == .checking {
                                    Button("查询原请求回执") { Task { if entry.path.hasPrefix("/sessions") { _ = await model.deliverWork(entry.id) } else { await model.deliver(entry.id) } } }.buttonStyle(.quiet).padding(.top, Space.xs)
                                }
                                if entry.state == .rejected {
                                    Button("恢复文字到聊天草稿") { model.draft = entry.text; model.tab = .chat; dismiss(); model.persistNow() }.buttonStyle(.quiet).padding(.top, Space.xs)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                        }
                    }
                }
                if !unresolved.isEmpty {
                    settingsGroup(title: "送达待核实的操作", footer: "先更新任务、记忆或日程结果，核对后再决定下一步。这里不会自动重发操作。") {
                        ForEach(Array(unresolved.enumerated()), id: \.offset) { _, record in RawDetails(title: "查看原请求与操作内容", value: record).rowPadding() }
                        Button("更新服务端状态") { Task { await model.refreshAll() } }.buttonStyle(.quiet).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    }
                }
                settingsGroup(title: "平台能力", footer: "iOS 不支持读取其他 App 的全部通知、列出所有应用或任意操作其他 App。免费账号签名需要定期重新安装，首版没有锁屏实时远程推送。") {
                    DisclosureGroup("能力与授权明细") {
                        VStack(spacing: 0) {
                            ForEach(Array(devices.capabilities.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top) {
                                    Text(item["tool"].string).font(TypeScale.subheadline)
                                    Spacer()
                                    Text(!item["available"].bool ? "不支持" : item["permission"].bool ? "可用" : "未授权 / 同步关闭").font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.trailing)
                                }.padding(.vertical, Space.xs + 2)
                            }
                        }.padding(.top, Space.sm)
                    }.font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                    NavigationLink { DeviceReceiptsView() } label: { NavigationRowLabel(title: "设备操作回执与撤销") }.buttonStyle(.row)
                }
                GroupedCard {
                    Button(role: .destructive) { disconnecting = true } label: {
                        Text("解除本机配对").font(TypeScale.callout.weight(.medium)).foregroundStyle(Palette.danger).frame(maxWidth: .infinity, alignment: .center).rowPadding()
                    }.buttonStyle(.row)
                }
            }.navigationTitle("设置").navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Palette.background, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .confirmationDialog("解除配对后本机保留草稿与缓存", isPresented: $disconnecting, titleVisibility: .visible) { Button("解除配对", role: .destructive) { Task { await model.disconnect(); dismiss() } } }
                .sheet(isPresented: $showPairCode) { PairCodeSheet() }
        }
    }
    @ViewBuilder private func settingsGroup(title: String, footer: String = "", @ViewBuilder content: () -> some View) -> some View {
        GroupSection(title, footer: footer) { GroupedCard { content() } }
    }
    private func settingsRow(label: String, value: String) -> some View {
        KeyValueRow(label: label, value: value)
    }
    private func permission(_ title: String, _ symbol: String, _ domain: String) -> some View {
        Button { Task { await model.devices.authorize(domain) } } label: { NavigationRowLabel(title: title, symbol: symbol) }.buttonStyle(.row)
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [JSON] = []
    @State private var note = ""
    var body: some View {
        NavigationStack {
            ScrollPage {
                SearchField(text: $query, prompt: "聊天、任务或成果名称")
                if !note.isEmpty { InlineNotice(text: note, tone: .neutral) }
                if query.isEmpty {
                    let artifacts = model.datasets["/personal/artifacts"]?["items"].array ?? []
                    GroupSection("成果") {
                        if artifacts.isEmpty { EmptyState(title: "还没有成果", description: "Agent 交付的文件、图片和报告会收在这里；也可以直接搜聊天和任务。", symbol: "tray") }
                        else { ArtifactList(artifacts: artifacts) }
                    }
                } else {
                    VStack(spacing: Space.md) {
                        ForEach(results.map(RemoteRow.init)) { row in
                            if row.value["kind"].string == "artifact" { ArtifactList(artifacts: [row.value]) }
                            else {
                                Button {
                                    let item = row.value
                                    dismiss()
                                    Task {
                                        if item["kind"].string == "task" {
                                            await model.refresh(.doing)
                                            model.selectedTask = model.datasets["/personal/tasks"]?["items"].array.first { $0.id == item.id }
                                        } else { await model.locateMessage(item.id) }
                                    }
                                } label: {
                                    ListRow(symbol: row.value["kind"].string == "task" ? "checkmark.square" : "bubble.left", title: row.value["text"].string, titleLines: 4,
                                            meta: row.value["source"].string + " · " + Date(timeIntervalSince1970: row.value["created_at"].double).formatted(date: .abbreviated, time: .shortened))
                                        .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous)).elevation(.raised)
                                }.buttonStyle(MessagePressStyle())
                            }
                        }
                    }
                }
            }.navigationTitle("搜索与成果").navigationBarTitleDisplayMode(.large)
                .task { _ = await model.load("/personal/artifacts") }
                .task(id: query) {
                    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
                    do {
                        try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation()
                        guard let api = model.client else { return }
                        let result = try await api.request("/personal/search?q=" + query.queryEncoded)
                        try Task.checkCancellation(); results = result["items"].array; note = results.isEmpty ? "未找到匹配内容" : ""
                    } catch { if !Task.isCancelled { note = error.localizedDescription } }
                }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

struct ArtifactList: View {
    @Environment(AppModel.self) private var model
    let artifacts: [JSON]
    /// 10-25 附件片（参考 Mailio 邮件底部的 Brief.pdf 片）：两列小卡，类型色块 + 名字 + 类型 · 大小 + 下载记号。
    var chips = false
    @State private var preview: PreviewFile?
    @State private var page: PreviewFile?
    @State private var loading: String?
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if chips && !artifacts.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)], spacing: Space.sm) {
                    ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                        Button { Task { await open(artifact) } } label: { AttachmentChip(artifact: artifact, loading: loading == artifact.id) }
                            .buttonStyle(.plain).disabled(loading != nil)
                    }
                }
            } else if !artifacts.isEmpty {
                GroupedCard(dividerInset: Layout.rowInset) {
                    ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                        Button {
                            Task { await open(artifact) }
                        } label: {
                            ListRow(symbol: artifact["mime"].string.hasPrefix("image") ? "photo" : artifact["name"].string.hasSuffix(".html") ? "rectangle.on.rectangle.angled" : "doc.richtext", tone: .info,
                                    title: artifact["name"].string.isEmpty ? URL(fileURLWithPath: artifact["path"].string).lastPathComponent : artifact["name"].string,
                                    subtitle: artifact["availability"].string == "available" ? (artifact["name"].string.hasSuffix(".html") ? "点开直接看" : "预览与分享") : artifact["availability"].string == "missing" ? "文件已移动或不存在" : "核对登记后预览", subtitleLines: 1) {
                                if loading == artifact.id { ProgressView() } else { Image(systemName: "arrow.up.right").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary) }
                            }
                        }.buttonStyle(.row).disabled(loading != nil)
                    }
                }
            }
            if !error.isEmpty { InlineNotice(text: error) }
        }
        .fullScreenCover(item: $page) { file in NavigationStack { HTMLPreview(url: file.url, initialState: file.state, save: saveState(file.url)).ignoresSafeArea(edges: .bottom).navigationTitle(file.url.deletingPathExtension().lastPathComponent).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { page = nil } }; ToolbarItem(placement: .topBarTrailing) { ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") } } } } }
        .sheet(item: $preview) { file in NavigationStack { FilePreview(url: file.url).navigationTitle(file.url.lastPathComponent).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { preview = nil } }; ToolbarItem(placement: .topBarTrailing) { ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") } } } } }
    }
    private func open(_ item: JSON) async {
        guard let api = model.client else { return }
        loading = item.id; error = ""; defer { loading = nil }
        do {
            var record = item
            if !item.id.hasPrefix("art_") {
                let catalog = try await api.request("/personal/artifacts")
                guard let found = catalog["items"].array.first(where: { $0["path"] == item["path"] || $0["reference"] == item["path"] }) else { throw APIError(status: 404, detail: "成果尚未登记，不能直接读取任意路径") }
                record = found
            }
            let file = try await api.download(record.id, name: record["name"].string, into: SecureVault.directory.appendingPathComponent("Previews"))
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            if file.pathExtension.lowercased() == "html" {
                let saved = try? await api.request("/personal/artifact-state/" + file.lastPathComponent.pathEncoded)
                let state = (saved?["state"]).flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                page = PreviewFile(url: file, state: state)
            } else { preview = PreviewFile(url: file) }
        } catch { self.error = error.localizedDescription }
    }
    private func saveState(_ file: URL) -> (String) -> Void {
        let client = model.client
        return { text in
            guard let client, let data = text.data(using: .utf8), let state = try? JSONDecoder().decode(JSON.self, from: data) else { return }
            Task { _ = try? await client.request("/personal/artifact-state/" + file.lastPathComponent.pathEncoded, body: .object(["state": state])) }
        }
    }
}
private struct AttachmentChip: View {
    let artifact: JSON
    let loading: Bool
    var body: some View {
        let name = artifact["name"].string.isEmpty ? URL(fileURLWithPath: artifact["path"].string).lastPathComponent : artifact["name"].string
        let ext = (URL(fileURLWithPath: name).pathExtension.uppercased()).prefix(4)
        let tint: Color = switch ext { case "PDF": Palette.danger; case "PNG", "JPG", "JPEG", "WEBP", "GIF": Palette.info; case "HTML": Palette.success; case "XLSX", "CSV": Color(red: 0.2, green: 0.6, blue: 0.35); default: Palette.textSecondary }
        let size = artifact["size"].double > 0 ? ByteCountFormatter.string(fromByteCount: Int64(artifact["size"].double), countStyle: .file) : ""
        HStack(spacing: Space.sm) {
            Text(ext.isEmpty ? "FILE" : String(ext)).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 30, height: 36).background(tint, in: .rect(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text(artifact["availability"].string == "missing" ? "已移动或不存在" : [String(ext), size].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textTertiary) }
        }
        .padding(Space.sm)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
    }
}
private struct PreviewFile: Identifiable { let url: URL; var state = "{}"; var id: String { url.path } }
/// 航程产出的 HTML：自包含单文件，直接在 App 里交互；只读本文件所在目录，外部链接一律不跳转。
/// 勾选、展开、输入按元素顺序存到后端（和网页共用），下次打开照原样恢复。
struct HTMLPreview: UIViewRepresentable {
    let url: URL
    var initialState: String = "{}"
    var save: (String) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(save) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let script = """
        (function(){var S=\(initialState);var els=[].slice.call(document.querySelectorAll('input,textarea,details')).filter(function(e){return e.type!=='file'&&e.type!=='password'});
        function box(e){return e.type==='checkbox'||e.type==='radio'}
        function k(e,i){return e.id||i}
        els.forEach(function(e,i){var v=S[k(e,i)];if(v===undefined)return;if(e.tagName==='DETAILS')e.open=!!v;else if(box(e))e.checked=!!v;else e.value=v});
        function snap(){var o={};els.forEach(function(e,i){o[k(e,i)]=e.tagName==='DETAILS'?e.open:box(e)?e.checked:e.value});window.webkit.messageHandlers.comState.postMessage(JSON.stringify(o))}
        document.addEventListener('change',snap,true);document.addEventListener('input',snap,true);
        els.forEach(function(e){if(e.tagName==='DETAILS')e.addEventListener('toggle',snap)})})();
        """
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "comState")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "comState")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let save: (String) -> Void
        init(_ save: @escaping (String) -> Void) { self.save = save }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let text = message.body as? String { save(text) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true || action.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, @preconcurrency QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}


struct ConnectionList: View {
    @Environment(AppModel.self) private var model
    private var sources: [JSON] { model.datasets["/personal/connectors"]?["sources"].array ?? model.datasets["/personal/briefing"]?["source_status"]["sources"].array ?? [] }
    var body: some View {
        GroupedCard {
            ForEach(sources.map { RemoteRow(.object(["id": $0["name"], "source": $0])) }) { row in
                let source = row.value["source"]
                NavigationLink { ConnectionDetail(source: source) } label: {
                    ListRow(symbol: connectionSymbol(source["name"].string), tone: source["status"].string == "connected" ? .success : .neutral,
                            title: sourceName(source["name"].string), status: connectionStatus(source["status"].string), statusTone: source["status"].string == "connected" ? .success : .neutral,
                            subtitle: source["status"].string == "connected" ? "查看连接与同步" : "点击配置或重试", subtitleLines: 1) { Chevron() }
                }.buttonStyle(.row)
            }
        }
    }
}
struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollPage {
            Text("连接你的数据，让 Com 更了解你。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary)
            ConnectionList()
            if let error = model.errors["/personal/connectors"] { InlineNotice(text: error) }
        }.navigationTitle("数据连接").navigationBarTitleDisplayMode(.large)
            .task { _ = await model.load("/personal/connectors") }
            .refreshable { _ = await model.load("/personal/connectors") }
    }
}
struct ConnectionDetail: View {
    @Environment(AppModel.self) private var model
    let source: JSON
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var region = "garmin.cn"
    @State private var protocolKind = "ews"
    @State private var email = ""
    @State private var busy = false
    @State private var note = ""
    private var name: String { source["name"].string }
    private var current: JSON { model.datasets["/personal/connectors"]?["sources"].array.first { $0["name"].string == name } ?? source }
    private var connected: Bool { current["status"].string == "connected" }
    var body: some View {
        ScrollPage {
            Card { HStack { IconBadge(symbol: connectionSymbol(name), tone: connected ? .success : .neutral); Text(sourceName(name)).font(TypeScale.title); Spacer(); StatusPill(text: connectionStatus(current["status"].string), tone: connected ? .success : .neutral) } }
            if !note.isEmpty { InlineNotice(text: note, tone: .neutral) }
            if !connected && ["work_mail", "garmin"].contains(name) && current["status"].string != "disconnected" {
                GroupSection("账号") {
                    GroupedCard {
                        if name == "work_mail" {
                            Picker("邮箱类型", selection: $protocolKind) { Text("Exchange（OWA）").tag("ews"); Text("IMAP").tag("imap") }.pickerStyle(.segmented).rowPadding()
                            TextField(protocolKind == "ews" ? "服务器，如 mail.sohu-inc.com" : "IMAP 服务器", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).rowPadding()
                            if protocolKind == "ews" { TextField("邮箱地址，如 name@sohu-inc.com", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress).rowPadding() }
                        }
                        else { Picker("地区", selection: $region) { Text("中国区").tag("garmin.cn"); Text("国际区").tag("garmin.com") }.rowPadding() }
                        TextField(name == "work_mail" && protocolKind == "ews" ? "域账号（登录 OWA 用的那个）" : "账号", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().rowPadding()
                        SecureField(name == "work_mail" ? (protocolKind == "ews" ? "邮箱密码" : "邮箱专用密码") : "密码", text: $password).rowPadding()
                    }
                    if name == "work_mail" && protocolKind == "ews" {
                        Text("搜狐邮箱不开 IMAP，走 Exchange 的 EWS 接口读收件箱邮件头，不改已读状态。密码直接发给 mini 保存，不进聊天记录。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    Button("连接") { update(credentials: true) }.buttonStyle(.primaryFull).disabled(busy || username.isEmpty || password.isEmpty || (name == "work_mail" && (host.isEmpty || (protocolKind == "ews" && !email.contains("@")))))
                }
            } else if !connected {
                if name == "gmail" || name == "google_calendar" { Text("首次连接需在 Mac mini 完成 Google 授权，然后点击检查连接。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary) }
                Button(current["status"].string == "disconnected" ? "重新连接" : "检查连接") { update(credentials: false) }.buttonStyle(.primaryFull).disabled(busy)
            }
            if connected {
                Button("断开同步", role: .destructive) { update(enabled: false, credentials: false) }.buttonStyle(.secondaryAction).disabled(busy)
                Text("停止 Com 后续读取；保留既有资料及其他 App 的授权。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
            if busy { ProgressView("正在核验连接") }
            if !current["error"].string.isEmpty { DisclosureGroup("诊断详情") { Text(current["error"].string).font(TypeScale.footnote).textSelection(.enabled) } }
        }.navigationTitle(sourceName(name)).navigationBarTitleDisplayMode(.inline)
            .onAppear { if name == "work_mail" && host.isEmpty { host = "mail.sohu-inc.com" } }
    }
    private func update(enabled: Bool = true, credentials: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                var fields: [String: JSON] = ["enabled": .bool(enabled)]
                if credentials {
                    fields["username"] = .string(username); fields["password"] = .string(password)
                    if name == "work_mail" { fields["host"] = .string(host); fields["protocol"] = .string(protocolKind); if protocolKind == "ews" { fields["email"] = .string(email) } }
                    else { fields["domain"] = .string(region) }
                }
                guard let api = model.client else { throw APIError(status: 0, detail: "请先连接服务") }
                // Account secrets go directly over authenticated TLS, never into the local operation ledger.
                _ = try await api.request("/personal/connectors/" + name.pathEncoded, body: .object(fields))
                password = ""
                if enabled { _ = try await model.mutate("/personal/sync", fields: ["group": .string(name)]) }
                _ = await model.load("/personal/connectors")
                _ = await model.load("/personal/briefing")
                note = enabled ? (connected ? "连接已核验" : "尚未连接，请检查授权或账号") : "已停止此来源同步"
            } catch { note = "操作未完成：" + error.localizedDescription }
        }
    }
}
private func connectionStatus(_ raw: String) -> String {
    ["connected": "已连接", "disconnected": "已断开", "needs_connection": "未连接", "not_synced": "未检查", "unavailable": "暂不可用"][raw] ?? "待核实"
}
private func connectionSymbol(_ name: String) -> String {
    switch name {
    case "gmail", "work_mail": "envelope"
    case "github": "desktopcomputer"
    case "apple_calendar", "phone_calendar", "google_calendar": "calendar"
    case "accounting": "creditcard"
    case "garmin", "phone_health": "heart"
    case "phone_reminders": "bell"
    case "sms": "message"
    case "plaud": "waveform"
    case "weather": "cloud.sun"
    default: "link"
    }
}


/// 10-25 活动日志（借鉴 Muse）：它替你做过的每个写操作。审批只拦删除之后，这里是事后那道闸：
/// 能看到做了什么、凭哪句话做的，结果不确定的可以说一句做成了没有。微信通道发过的提醒也列在最后。
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    private var data: JSON { model.activityData }
    var body: some View {
        DetailPage(title: "它做过的事") {
            Text("记账、日程、提醒、改文件……每一步都在这。结果不确定的点一下告诉它，做错的标出来，它会记住。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            let items = data["items"].array
            if items.isEmpty {
                EmptyState(title: "还没有记录", description: "它替你动手做过的事会按时间列在这里。", symbol: "list.bullet.rectangle")
            } else {
                GroupedCard(dividerInset: Layout.rowInset) {
                    ForEach(items.map { RemoteRow(.object(["id": $0["key"], "entry": $0])) }) { row in
                        ActivityRow(entry: row.value["entry"])
                    }
                }
            }
            let pushes = data["wechat"].array
            if !pushes.isEmpty {
                GroupSection("发到微信的提醒") {
                    GroupedCard(dividerInset: Layout.rowInset) {
                        ForEach(pushes.map { RemoteRow(.object(["id": $0["key"], "push": $0])) }) { row in
                            let push = row.value["push"]
                            ListRow(symbol: "bubble.left", tone: push["state"].string == "sent" ? .success : .warning,
                                    title: push["text"].string.components(separatedBy: "\n").first ?? "", subtitle: relativeTime(push["at"].double) + (push["state"].string == "sent" ? "" : " · 没发出去"), subtitleLines: 1) { EmptyView() }
                        }
                    }
                }
            }
        }
        .task { _ = await model.load("/personal/activity") }
        .refreshable { _ = await model.load("/personal/activity") }
    }
}

private struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let entry: JSON
    private var state: (String, Tone, String) {
        switch entry["state"].string {
        case "completed": ("checkmark.circle", .success, "做成了")
        case "confirmed": ("checkmark.seal", .success, "你确认做成了")
        case "failed": ("xmark.circle", .danger, "失败")
        case "not_done": ("minus.circle", .neutral, "你说没做成")
        case "disputed": ("exclamationmark.bubble", .danger, "你标了做错")
        default: ("questionmark.circle", .warning, "结果不确定")
        }
    }
    var body: some View {
        let (symbol, tone, label) = state
        let when = entry["at"].double > 0 ? relativeTime(entry["at"].double) : ""
        let source = entry["source"].string
        Menu {
            Section(source.isEmpty ? "没有记下来源" : "来自：" + source) {
                Button("做成了", systemImage: "checkmark") { verdict("done") }
                Button("没做成", systemImage: "minus") { verdict("not_done") }
                Button("做错了", systemImage: "exclamationmark.bubble") { verdict("wrong") }
            }
        } label: {
            ListRow(symbol: symbol, tone: tone, title: entry["summary"].string, status: label, statusTone: tone,
                    subtitle: [when, source].filter { !$0.isEmpty }.joined(separator: " · "), subtitleLines: 1) { EmptyView() }
        }
        .buttonStyle(.row)
    }
    private func verdict(_ value: String) { Task { await model.activityVerdict(entry["key"].string, value) } }
}
