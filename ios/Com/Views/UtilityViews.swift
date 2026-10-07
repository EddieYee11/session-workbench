import SwiftUI
import ComCore
import QuickLook

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "light"
    @State private var disconnecting = false
    var body: some View {
        @Bindable var devices = model.devices!
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                    Text("大字体、VoiceOver、减少动态效果和降低透明度跟随系统设置。").font(.caption).foregroundStyle(.secondary)
                }
                Section("连接") {
                    LabeledContent("服务", value: model.base).font(.caption)
                    LabeledContent("实时对话", value: model.streaming ? "已连接" : "缓存模式")
                    LabeledContent("手机能力", value: devices.connected ? "已连接" : "未连接")
                    Text(devices.note).font(.caption).foregroundStyle(.secondary)
                    Button("刷新连接") { Task { await model.setActive(true) } }
                    Text("手机退到后台后，任务继续在 mini 上执行。重新打开时会补取最新状态。").font(.caption).foregroundStyle(.secondary)
                }
                Section("首次使用时授权") {
                    permission("健康 · 只读", "heart", "health")
                    permission("日历", "calendar", "calendar")
                    permission("提醒事项", "checklist", "reminders")
                    permission("联系人", "person.crop.circle", "contacts")
                    permission("使用期间的位置", "location", "location")
                    Button("打开系统权限设置", systemImage: "gear") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
                Section("设备结果同步") {
                    Toggle("向 mini 提供健康摘要", isOn: $devices.healthSync)
                    Toggle("向 mini 提供联系人查询结果", isOn: $devices.contactsSync)
                    Text("开启后，已授权范围内的数据可供 mini 处理你的交办。健康包括步数、活动能量、心率、静息心率、睡眠和运动；联系人查询仅返回符合交办条件的结果。关闭会停止后续设备读取；已交办的结果可能已保存在服务端。").font(.caption).foregroundStyle(.secondary)
                }.onChange(of: devices.healthSync) { _, _ in Task { await devices.updateSync() } }.onChange(of: devices.contactsSync) { _, _ in Task { await devices.updateSync() } }
                Section { Button("分享收件箱", systemImage: "tray.and.arrow.down") { dismiss(); model.showShareInbox = true } }
                Section("发送记录") {
                    if model.pending.isEmpty { Text("还没有本机发送记录").foregroundStyle(.secondary) }
                    ForEach(model.pending.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.text.isEmpty ? "恢复工作会话" : entry.text).lineLimit(3)
                            Text(entry.note + " · " + entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            if entry.state == .uncertain || entry.state == .checking {
                                Button("查询原请求回执") { Task { if entry.path.hasPrefix("/sessions") { _ = await model.deliverWork(entry.id) } else { await model.deliver(entry.id) } } }
                            }
                            if entry.state == .rejected {
                                Button("恢复文字到聊天草稿") { model.draft = entry.text; model.tab = .chat; dismiss(); model.persistNow() }
                            }
                        }.padding(.vertical, 5)
                    }
                }
                let unresolved = SecureVault.operationRecords().filter { $0["status"].string == "unknown" }
                if !unresolved.isEmpty {
                    Section("送达待核实的操作") {
                        Text("先更新任务、记忆或日程结果，核对后再决定下一步。这里不会自动重发操作。").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(unresolved.enumerated()), id: \.offset) { _, record in RawDetails(title: "查看原请求与操作内容", value: record) }
                        Button("更新服务端状态") { Task { await model.refreshAll() } }
                    }
                }
                Section { NavigationLink("设备操作回执与撤销") { DeviceReceiptsView() } }
                Section("平台能力") {
                    Text("iOS 不支持读取其他 App 的全部通知、列出所有应用或任意操作其他 App。免费账号签名需要定期重新安装，首版没有锁屏实时远程推送。").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("能力与授权明细") { ForEach(Array(devices.capabilities.enumerated()), id: \.offset) { _, item in LabeledContent(item["tool"].string, value: !item["available"].bool ? "不支持" : item["permission"].bool ? "可用" : "未授权 / 同步关闭").font(.caption) } }
                }
                Section { Button("解除本机配对", role: .destructive) { disconnecting = true } }
            }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .confirmationDialog("解除配对后本机保留草稿与缓存", isPresented: $disconnecting, titleVisibility: .visible) { Button("解除配对", role: .destructive) { Task { await model.disconnect(); dismiss() } } }
        }
    }
    private func permission(_ title: String, _ symbol: String, _ domain: String) -> some View {
        Button(title, systemImage: symbol) { Task { await model.devices.authorize(domain) } }
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
            List {
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                if query.isEmpty {
                    Section("成果") { ArtifactList(artifacts: model.datasets["/personal/artifacts"]?["items"].array ?? []) }
                } else {
                    ForEach(results.map(RemoteRow.init)) { row in
                        if row.value["kind"].string == "artifact" { ArtifactList(artifacts: [row.value]) }
                        else {
                            Button {
                                let item = row.value
                                dismiss()
                                Task {
                                    if item["kind"].string == "task" {
                                        await model.refresh(.tasks)
                                        model.selectedTask = model.datasets["/personal/tasks"]?["items"].array.first { $0.id == item.id }
                                    } else { await model.locateMessage(item.id) }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 7) { Text(row.value["text"].string).lineLimit(4); Text(row.value["source"].string + " · " + Date(timeIntervalSince1970: row.value["created_at"].double).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.navigationTitle("搜索与成果").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "聊天、任务或成果名称")
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
    @State private var preview: PreviewFile?
    @State private var loading: String?
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                Button {
                    Task { await open(artifact) }
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: artifact["mime"].string.hasPrefix("image") ? "photo" : "doc.richtext").foregroundStyle(Palette.violet)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artifact["name"].string.isEmpty ? URL(fileURLWithPath: artifact["path"].string).lastPathComponent : artifact["name"].string).font(.subheadline.weight(.medium))
                            Text(artifact["availability"].string == "available" ? "预览与分享" : artifact["availability"].string == "missing" ? "文件已移动或不存在" : "核对登记后预览").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); if loading == artifact.id { ProgressView() } else { Image(systemName: "arrow.up.right").font(.caption) }
                    }.padding(14).background(Palette.canvas, in: .rect(cornerRadius: 18))
                }.buttonStyle(.plain).disabled(loading != nil)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(Palette.coral) }
        }
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
            preview = PreviewFile(url: file)
        } catch { self.error = error.localizedDescription }
    }
}
private struct PreviewFile: Identifiable { let url: URL; var id: String { url.path } }
struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
