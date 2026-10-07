import SwiftUI
import ComCore

struct WorkView: View {
    @Environment(AppModel.self) private var model
    @State private var section = "项目看板"
    @State private var filter = ""
    @State private var query = ""
    @State private var creating = false
    @State private var workDraft = ""
    private var sessions: [JSON] { model.datasets["/sessions"]?["sessions"].array ?? [] }
    private var filtered: [JSON] { sessions.filter { (filter.isEmpty || $0["agent"].string == filter) && (query.isEmpty || $0["display_title"].string.localizedCaseInsensitiveContains(query) || $0["cwd"].string.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        ScreenScaffold(title: "工作", compact: true) {
            HStack {
                Picker("工作视图", selection: $section) { Text("项目看板").tag("项目看板"); Text("会话").tag("会话") }.pickerStyle(.segmented)
                Button { creating = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.buttonStyle(.quiet).accessibilityLabel("新建工作")
            }
            if section == "项目看板" { ProjectBoardHome() }
            else {
                HStack(alignment: .bottom, spacing: Space.sm) {
                    TextField("描述你的工作…", text: $workDraft, axis: .vertical).lineLimit(1...5).font(TypeScale.callout)
                    CircleActionButton(symbol: "arrow.up", label: "选择伙伴并开始工作", filled: true, size: 36) { creating = true }
                        .disabled(workDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(Space.md).composerSurface()
                Picker("执行器", selection: $filter) { Text("全部").tag(""); Text("Hermes").tag("hermes"); Text("Pi").tag("pi"); Text("Claude").tag("claude"); Text("Codex").tag("codex") }.pickerStyle(.segmented)
                SearchField(text: $query, prompt: "搜索会话与项目")
                if filtered.isEmpty { EmptyState(title: "这里还没有会话", description: "跨设备进展在项目看板；这里可继续 Mac mini 上支持恢复的工作会话。", symbol: "bubble.left.and.bubble.right") }
                GroupedCard {
                    ForEach(filtered.prefix(80).map(RemoteRow.init)) { row in
                        Button { model.selectedSession = row.value } label: {
                            ListRow(symbol: agentSymbol(row.value["agent"].string), tone: statusTone(row.value["status"].string),
                                title: row.value["display_title"].string.isEmpty ? row.value["title"].string : row.value["display_title"].string,
                                status: agentName(row.value["agent"].string), subtitle: row.value["snippet"].string, subtitleLines: 1)
                        }.buttonStyle(.row)
                    }
                }
            }
        }.refreshable { await model.refresh(.work) }
        .sheet(isPresented: $creating) { NewWorkView(initialAgent: filter.isEmpty ? "hermes" : filter, initialPrompt: workDraft) }
    }
}

private func agentSymbol(_ agent: String) -> String {
    switch agent {
    case "codex": "chevron.left.forwardslash.chevron.right"
    case "claude": "sparkle"
    case "pi": "terminal"
    default: "point.3.connected.trianglepath.dotted"
    }
}

struct NewWorkView: View {
    init(initialAgent: String = "codex", initialPrompt: String = "") { _agent = State(initialValue: initialAgent); _prompt = State(initialValue: initialPrompt) }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var agent = "codex"
    @State private var directory = "/Users/eddiegao/AI_Work_System"
    @State private var prompt = ""
    @State private var models: [JSON] = []
    @State private var selection = ""
    @State private var effort = ""
    @State private var working = false
    @State private var pickingDirectory = false
    @State private var note = ""
    var body: some View {
        NavigationStack {
            ScrollPage(spacing: Space.xxl) {
                GroupSection("谁来一起做") {
                    Picker("执行器", selection: $agent) { Text("Hermes").tag("hermes"); Text("Pi").tag("pi"); Text("Claude").tag("claude"); Text("Codex").tag("codex") }.pickerStyle(.segmented)
                }
                GroupSection("这次想完成什么") {
                    TextField("工作要求", text: $prompt, axis: .vertical).lineLimit(4...10).font(TypeScale.callout)
                        .padding(Space.lg).background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous)).elevation(.raised)
                }
                GroupSection("项目", footer: directory) {
                    GroupedCard {
                        Button { pickingDirectory = true } label: { NavigationRowLabel(title: URL(fileURLWithPath: directory).lastPathComponent, symbol: "folder") }.buttonStyle(.row)
                    }
                }
                GroupSection("模型") {
                    GroupedCard {
                        HStack {
                            Text("模型").font(TypeScale.callout)
                            Spacer(minLength: Space.sm)
                            Picker("模型", selection: $selection) { Text("执行器默认").tag(""); ForEach(models.map(RemoteRow.init)) { row in Text(row.value["label"].string.isEmpty ? row.id : row.value["label"].string).tag(row.id) } }
                                .labelsHidden().tint(Palette.textSecondary)
                        }.padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                        let efforts = models.first { $0.id == selection }?["efforts"].array.map(\.string) ?? []
                        if !efforts.isEmpty {
                            HStack {
                                Text("推理强度").font(TypeScale.callout)
                                Spacer(minLength: Space.sm)
                                Picker("推理强度", selection: $effort) { Text("默认").tag(""); ForEach(efforts, id: \.self) { Text($0).tag($0) } }
                                    .labelsHidden().tint(Palette.textSecondary)
                            }.padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                        }
                    }
                }
                if !note.isEmpty { InlineNotice(text: note) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    working = true
                    Task {
                        do {
                            let entry = try model.queueWork(path: "/sessions", text: prompt, fields: ["agent": .string(agent), "cwd": .string(directory), "prompt": .string(prompt), "model": .string(selection), "effort": .string(effort), "sandbox": .string("danger-full-access")])
                            let result = await model.deliverWork(entry.id)
                            if let sid = result?["sid"].string, !sid.isEmpty { dismiss(); model.selectedSession = .object(["id": .string(sid), "agent": .string(agent), "cwd": .string(directory), "title": .string(String(prompt.prefix(60)))]) }
                            else { note = "送达待核实。要求已保存，可在发送记录中查询回执。" }
                        } catch { note = error.localizedDescription }
                        working = false
                    }
                } label: {
                    HStack(spacing: Space.sm) {
                        if working { ProgressView().tint(Palette.onAccent) } else { Image(systemName: "arrow.up.right") }
                        Text("开始工作")
                    }
                }
                .buttonStyle(.primaryFull)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                .padding(.horizontal, Layout.margin).padding(.top, Space.sm).padding(.bottom, Space.sm)
                .background(Palette.background)
            }
            .navigationTitle("新工作").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task(id: agent) {
                selection = ""; effort = ""
                if let data = await model.load("/models?agent=" + agent) { models = data["models"].array }
            }
            .sheet(isPresented: $pickingDirectory) { DirectoryPicker(path: $directory).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        }
    }
}

struct DirectoryPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var path: String
    @State private var data: JSON = .null
    var body: some View {
        NavigationStack {
            ScrollPage {
                CodeBlock(text: data["path"].string)
                if !data["parent"].isNull || !data["directories"].array.isEmpty {
                    GroupSection("文件夹") {
                        GroupedCard(dividerInset: Layout.rowInset) {
                            if !data["parent"].isNull {
                                Button { Task { await browse(data["parent"].string) } } label: {
                                    ListRow(symbol: "arrow.up", title: "上一级") { EmptyView() }
                                }.buttonStyle(.row)
                            }
                            ForEach(data["directories"].array.map(\.string), id: \.self) { directory in
                                Button { Task { await browse(directory) } } label: {
                                    ListRow(symbol: "folder", tone: .info, title: URL(fileURLWithPath: directory).lastPathComponent)
                                }.buttonStyle(.row)
                            }
                        }
                    }
                }
                if !data["recent"].array.isEmpty {
                    GroupSection("最近使用") {
                        GroupedCard(dividerInset: Layout.rowInset) {
                            ForEach(data["recent"].array.map(\.string), id: \.self) { directory in
                                Button { Task { await browse(directory) } } label: {
                                    ListRow(symbol: "clock", title: URL(fileURLWithPath: directory).lastPathComponent)
                                }.buttonStyle(.row)
                            }
                        }
                    }
                }
            }
            .navigationTitle("工作目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }; ToolbarItem(placement: .topBarTrailing) { Button("使用这里") { path = data["path"].string; dismiss() }.disabled(data["path"].string.isEmpty) } }
            .task { await browse(path) }
        }
    }
    private func browse(_ directory: String) async { if let result = await model.load("/directories?path=" + directory.queryEncoded) { data = result } }
}

struct WorkDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: JSON
    @State private var data: JSON = .null
    @State private var live: JSON = .null
    @State private var draft = ""
    @State private var currentID = ""
    @State private var sending = false
    @State private var terminal = false
    @State private var models: [JSON] = []
    @State private var selection = ""
    @State private var effort = ""
    @State private var note = ""
    private var metadata: JSON { data["session"].isNull ? session : data["session"] }
    private var messages: [JSON] { ConversationState.merge(data["messages"].array, live["items"].array) }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.xl) {
                        let liveStatus = live["status"].string.isEmpty ? metadata["status"].string : live["status"].string
                        DetailHeader(title: metadata["display_title"].string.isEmpty ? metadata["title"].string : metadata["display_title"].string) {
                            StatusPill(text: agentName(metadata["agent"].string), tone: .accent)
                            StatusPill(text: displayStatus(liveStatus), tone: statusTone(liveStatus))
                        }
                        if !note.isEmpty { InlineNotice(text: note) }
                        if messages.isEmpty { EmptyState(title: "会话已打开", description: "回看历史不会启动执行器。", symbol: "bubble.left") }
                        ForEach(messages.map(RemoteRow.init)) { row in MessageView(message: row.value, sourceSession: currentID).id(row.id) }
                        ForEach(Array(live["approvals"].array.enumerated()), id: \.offset) { _, approval in
                            WorkApprovalCard(approval: approval) { await refresh() }
                        }
                        Color.clear.frame(height: 1).id("work-bottom")
                    }.padding(.horizontal, Layout.margin).padding(.top, Space.sm).padding(.bottom, Space.xl)
                }.scrollDismissesKeyboard(.interactively).scrollIndicators(.hidden).background(Palette.background)
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: Space.md) {
                            if metadata["capabilities"]["input"].bool {
                                HStack(alignment: .bottom, spacing: Space.sm) {
                                    TextField("继续这项工作", text: $draft, axis: .vertical).font(TypeScale.callout).lineLimit(1...6).padding(.vertical, Space.sm).padding(.leading, Space.sm)
                                    CircleActionButton(symbol: "arrow.up", label: "发送工作消息", filled: true, size: 36) { submit() }
                                        .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        .opacity(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                                }
                                .padding(Space.sm)
                                .composerSurface()
                            } else if metadata["capabilities"]["resume"].bool {
                                Button("恢复此会话输入") { resume() }.buttonStyle(.primaryFull).disabled(sending)
                            } else { InlineNotice(text: "当前为历史回看，执行器暂不支持继续输入。", tone: .neutral) }
                        }.padding(.horizontal, Space.md).padding(.top, Space.xs).padding(.bottom, Space.sm)
                    }
                    .onChange(of: messages) { _, _ in
                        if let target = model.workJumpMessage, messages.contains(where: { $0.id == target }) { proxy.scrollTo(target, anchor: .center); model.workJumpMessage = nil }
                        else if sending { proxy.scrollTo("work-bottom", anchor: .bottom) }
                    }
            }
            .navigationTitle(agentName(metadata["agent"].string)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if metadata["capabilities"]["terminal"].bool { Button("终端", systemImage: "terminal") { terminal = true } }
                        Button("停止执行", systemImage: "stop") { Task { await model.action("/sessions/" + currentID.pathEncoded + "/stop"); await refresh() } }
                        Menu("模型") { ForEach(models.map(RemoteRow.init)) { row in Button(row.value["label"].string.isEmpty ? row.id : row.value["label"].string) { selection = row.id; effort = "" } }; Button("执行器默认") { selection = ""; effort = "" } }
                        let efforts = models.first { $0.id == selection }?["efforts"].array.map(\.string) ?? []
                        if !efforts.isEmpty { Menu("推理强度") { ForEach(efforts, id: \.self) { item in Button(item) { effort = item } } } }
                        Button(metadata["pinned"].bool ? "取消置顶" : "置顶") { Task { await model.action("/sessions/" + currentID.pathEncoded + "/labels", fields: ["pinned": .bool(!metadata["pinned"].bool)], refresh: .work); await refresh() } }
                        Button("结束会话", role: .destructive) { Task { await model.action("/sessions/" + currentID.pathEncoded + "/end", refresh: .work); await refresh() } }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .task {
                currentID = session.id
                draft = (try? SecureVault.load(String.self, name: "work-draft-" + currentID.pathEncoded)) ?? ""
                await refresh()
                if let catalog = await model.load("/models?agent=" + metadata["agent"].string) { models = catalog["models"].array }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    if model.active { await refresh() }
                }
            }
            .onChange(of: draft) { _, value in try? SecureVault.save(value, name: "work-draft-" + currentID.pathEncoded) }
            .sheet(isPresented: $terminal) { TerminalScreen(sessionID: currentID) }
        }
    }
    private func refresh() async {
        guard let api = model.client, !currentID.isEmpty else { return }
        do { data = try await api.request("/sessions/" + currentID.pathEncoded); live = try await api.request("/sessions/" + currentID.pathEncoded + "/live"); note = "" }
        catch { note = "历史缓存 · " + error.localizedDescription }
    }
    private func submit() {
        sending = true
        Task {
            defer { sending = false }
            do {
                var fields: [String: JSON] = ["model": .string(selection), "effort": .string(effort)]
                if let reference = model.reference, reference["source_session_id"].string == currentID { fields["reference"] = reference }
                let entry = try model.queueWork(path: "/sessions/" + currentID.pathEncoded + "/input", text: draft, fields: fields)
                if let result = await model.deliverWork(entry.id), result["status"].string == "accepted" { draft = ""; model.reference = nil; await refresh() }
                else { note = "送达待核实，要求已保存。先在设置中的发送记录核对回执。" }
            } catch { note = error.localizedDescription }
        }
    }
    private func resume() {
        sending = true
        Task {
            defer { sending = false }
            do {
                let entry = try model.queueWork(path: "/sessions/" + currentID.pathEncoded + "/resume", text: "", fields: [:])
                if let result = await model.deliverWork(entry.id), !result["sid"].string.isEmpty { currentID = result["sid"].string; await refresh() }
            } catch { note = error.localizedDescription }
        }
    }
    private func approve(_ approval: JSON, _ allow: Bool) {
        let id = approval["key"].string.isEmpty ? approval.id : approval["key"].string
        Task { await model.action("/approvals/" + id.pathEncoded, fields: ["decision": .string(allow ? "accept" : "decline")]); await refresh() }
    }
}
