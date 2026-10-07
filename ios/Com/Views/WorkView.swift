import SwiftUI
import ComCore

struct WorkView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var query = ""
    @State private var creating = false
    private var sessions: [JSON] { model.datasets["/sessions"]?["sessions"].array ?? [] }
    private var filtered: [JSON] { sessions.filter { (filter.isEmpty || $0["agent"].string == filter) && (query.isEmpty || $0["display_title"].string.localizedCaseInsensitiveContains(query) || $0["cwd"].string.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        PageCanvas {
            PageHeading(title: "工作台", subtitle: "与你一起，把事情做好。")
            Picker("执行器", selection: $filter) { Text("全部").tag(""); Text("Pi").tag("pi"); Text("Claude").tag("claude"); Text("Codex").tag("codex") }.pickerStyle(.segmented)
            HStack {
                Text("工作记录").font(.title2.weight(.semibold))
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44).background(Palette.surface, in: .circle) }.accessibilityLabel("新建工作")
            }
            InlineSearch(text: $query, prompt: "搜索工作与项目")
            Freshness(path: "/sessions")
            if filtered.isEmpty { EmptyState(title: "从一个想法开始", description: "创建工作或回看 Mac mini 上的历史会话。", symbol: "terminal") }
            let projects = Dictionary(grouping: filtered) { $0["cwd"].string }
            ForEach(projects.keys.sorted(), id: \.self) { project in
                Eyebrow(text: URL(fileURLWithPath: project).lastPathComponent)
                ForEach((projects[project] ?? []).map(RemoteRow.init)) { row in
                    Button { model.selectedSession = row.value } label: {
                        HStack(alignment: .top, spacing: 15) {
                            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 24))
                                .foregroundStyle(.primary).frame(width: 46, height: 46)
                                .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: 15))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(row.value["display_title"].string.isEmpty ? row.value["title"].string : row.value["display_title"].string).font(.headline).lineLimit(2)
                                if !row.value["snippet"].string.isEmpty { Text(row.value["snippet"].string).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                                Text(agentName(row.value["agent"].string) + " · " + displayStatus(row.value["status"].string)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if row.value["status"].string == "waiting" { Circle().fill(Palette.coral).frame(width: 6, height: 6).accessibilityLabel("等你回应") }
                        }.multilineTextAlignment(.leading).padding(16).background(Palette.surface, in: .rect(cornerRadius: 22))
                    }.buttonStyle(.plain)
                }
            }
        }.refreshable { await model.refresh(.work) }
            .sheet(isPresented: $creating) { NewWorkView() }
    }
}

struct NewWorkView: View {
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
            Form {
                Section("谁来一起做") { Picker("执行器", selection: $agent) { Text("Pi").tag("pi"); Text("Claude").tag("claude"); Text("Codex").tag("codex") }.pickerStyle(.segmented) }
                Section("这次想完成什么") { TextField("工作要求", text: $prompt, axis: .vertical).lineLimit(4...10) }
                Section("项目") { Button { pickingDirectory = true } label: { Label(URL(fileURLWithPath: directory).lastPathComponent, systemImage: "folder") }; Text(directory).font(.caption).foregroundStyle(.secondary) }
                Section("模型") {
                    Picker("模型", selection: $selection) { Text("执行器默认").tag(""); ForEach(models.map(RemoteRow.init)) { row in Text(row.value["label"].string.isEmpty ? row.id : row.value["label"].string).tag(row.id) } }
                    let efforts = models.first { $0.id == selection }?["efforts"].array.map(\.string) ?? []
                    if !efforts.isEmpty { Picker("推理强度", selection: $effort) { Text("默认").tag(""); ForEach(efforts, id: \.self) { Text($0).tag($0) } } }
                }
                if !note.isEmpty { Section { Text(note).foregroundStyle(Palette.coral) } }
                Section {
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
                    } label: { if working { ProgressView() } else { Label("开始工作", systemImage: "arrow.up.right") } }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                }
            }.navigationTitle("新工作").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .task(id: agent) {
                    selection = ""; effort = ""
                    if let data = await model.load("/models?agent=" + agent) { models = data["models"].array }
                }
                .sheet(isPresented: $pickingDirectory) { DirectoryPicker(path: $directory) }
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
            List {
                Section { Text(data["path"].string).font(.caption).textSelection(.enabled) }
                if !data["parent"].isNull { Button("上一级", systemImage: "arrow.up") { Task { await browse(data["parent"].string) } } }
                Section("文件夹") { ForEach(data["directories"].array.map(\.string), id: \.self) { directory in Button(URL(fileURLWithPath: directory).lastPathComponent, systemImage: "folder") { Task { await browse(directory) } } } }
                Section("最近使用") { ForEach(data["recent"].array.map(\.string), id: \.self) { directory in Button(URL(fileURLWithPath: directory).lastPathComponent) { Task { await browse(directory) } } } }
            }.navigationTitle("工作目录").navigationBarTitleDisplayMode(.inline)
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
                    LazyVStack(alignment: .leading, spacing: 22) {
                        HStack { Pill(text: agentName(metadata["agent"].string), color: Palette.cyan); Spacer(); Text(displayStatus(live["status"].string.isEmpty ? metadata["status"].string : live["status"].string)).font(.caption).foregroundStyle(.secondary) }
                        Text(metadata["display_title"].string.isEmpty ? metadata["title"].string : metadata["display_title"].string).font(.title2.weight(.semibold))
                        if !note.isEmpty { Text(note).font(.caption).foregroundStyle(Palette.coral) }
                        if messages.isEmpty { EmptyState(title: "会话已打开", description: "回看历史不会启动执行器。", symbol: "bubble.left") }
                        ForEach(messages.map(RemoteRow.init)) { row in MessageView(message: row.value, sourceSession: currentID).id(row.id) }
                        ForEach(Array(live["approvals"].array.enumerated()), id: \.offset) { _, approval in
                            WorkApprovalCard(approval: approval) { await refresh() }
                        }
                        Color.clear.frame(height: 1).id("work-bottom")
                    }.padding(20)
                }.scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 10) {
                            if metadata["capabilities"]["input"].bool {
                                HStack(alignment: .bottom) {
                                    TextField("继续这项工作", text: $draft, axis: .vertical).lineLimit(1...6)
                                    Button { submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(Palette.violet) }.disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送工作消息")
                                }.padding(16).glassEffect(.regular, in: .rect(cornerRadius: 26))
                            } else if metadata["capabilities"]["resume"].bool {
                                Button("恢复此会话输入") { resume() }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(sending)
                            } else { Text("当前为历史回看，执行器暂不支持继续输入。").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.horizontal, 16).padding(.vertical, 8)
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
