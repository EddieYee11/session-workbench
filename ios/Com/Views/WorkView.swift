import SwiftUI
import ComCore

struct NewWorkView: View {
    init(initialAgent: String = "codex", initialPrompt: String = "", initialDirectory: String = "") {
        _agent = State(initialValue: initialAgent); _prompt = State(initialValue: initialPrompt)
        _directory = State(initialValue: initialDirectory.isEmpty ? "/Users/eddiegao/AI_Work_System" : initialDirectory)
    }
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
    @State private var modelsLoading = false
    @State private var modelsFailNote = ""
    @State private var modelsLoadedOnce = false
    var body: some View {
        NavigationStack {
            ScrollPage(spacing: Space.xxl) {
                GroupSection("谁来一起做") {
                    Picker("执行器", selection: $agent) {
                        Text("Hermes").tag("hermes"); Text("Pi").tag("pi"); Text("Claude").tag("claude"); Text("Codex").tag("codex")
                    }
                    .pickerStyle(.segmented)
                    .disabled(modelsLoading)
                }
                GroupSection("这次想完成什么") {
                    TextField("工作要求", text: $prompt, axis: .vertical).lineLimit(4...10).font(TypeScale.callout)
                        .padding(Space.lg).noteSurface()
                }
                GroupSection("项目", footer: directory) {
                    GroupedCard {
                        Button { pickingDirectory = true } label: { NavigationRowLabel(title: URL(fileURLWithPath: directory).lastPathComponent, symbol: "folder") }.buttonStyle(.row)
                    }
                }
                GroupSection("模型") {
                    if modelsLoading || !modelsLoadedOnce {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.small)
                            Text("正在拉模型列表…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                        }
                        .accessibilityLabel("正在拉模型列表")
                    }
                    if !modelsFailNote.isEmpty {
                        InlineNotice(text: modelsFailNote, tone: .danger)
                        Button(modelsLoading ? "重试中…" : "再试一次") {
                            guard !modelsLoading else { return }
                            Task { await loadModels() }
                        }
                        .buttonStyle(.secondaryCompact)
                        .disabled(modelsLoading)
                        .accessibilityIdentifier("newwork-models-retry")
                    }
                    GroupedCard {
                        HStack {
                            Text("模型").font(TypeScale.body)
                            Spacer(minLength: Space.sm)
                            if modelsLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Picker("模型", selection: $selection) {
                                    Text(models.isEmpty && modelsLoadedOnce ? "执行器默认（列表未读上也可派）" : "执行器默认").tag("")
                                    ForEach(models.map(RemoteRow.init)) { row in
                                        Text(row.value["label"].string.isEmpty ? row.id : row.value["label"].string).tag(row.id)
                                    }
                                }
                                .labelsHidden().tint(Palette.textSecondary)
                            }
                        }.padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                        let efforts = models.first { $0.id == selection }?["efforts"].array.map(\.string) ?? []
                        if !efforts.isEmpty {
                            HStack {
                                Text("推理强度").font(TypeScale.body)
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
                        if working { ProgressView().tint(Palette.onInk) } else { Image(systemName: "paperplane") }
                        Text("派出去")
                    }
                }
                .buttonStyle(.primaryFull)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                .padding(.horizontal, Layout.margin).padding(.top, Space.sm).padding(.bottom, Space.sm)
                .background(Palette.background)
            }
            .navigationTitle("派新活").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task(id: agent) {
                selection = ""; effort = ""
                await loadModels()
            }
            .sheet(isPresented: $pickingDirectory) { DirectoryPicker(path: $directory).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        }
    }

    private func loadModels() async {
        guard !modelsLoading else { return }
        modelsLoading = true
        modelsFailNote = ""
        defer {
            modelsLoading = false
            modelsLoadedOnce = true
        }
        let path = "/models?agent=" + agent
        if let data = await model.load(path) {
            models = data["models"].array
        } else {
            models = []
            let err = model.errors[path] ?? model.errors["/models"] ?? ""
            modelsFailNote = err.isEmpty
                ? "模型列表没读上——可用「执行器默认」先派，或检查配对后再试"
                : "模型列表没读上：" + err + "——可再试，或先用默认派"
        }
    }
}

struct DirectoryPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var path: String
    @State private var data: JSON = .null
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    var body: some View {
        NavigationStack {
            ScrollPage {
                if loading || !loadedOnce {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在读取目录…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    .accessibilityLabel("正在读取目录")
                }
                if !failNote.isEmpty {
                    InlineNotice(text: failNote, tone: .danger)
                    Button(loading ? "重试中…" : "再试一次") {
                        guard !loading else { return }
                        Task { await browse(path.isEmpty ? data["path"].string : path) }
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(loading)
                    .accessibilityIdentifier("directory-retry")
                }
                CodeBlock(text: data["path"].string.isEmpty ? (loading ? "…" : "（还没读到路径）") : data["path"].string)
                if !data["parent"].isNull || !data["directories"].array.isEmpty {
                    GroupSection("文件夹") {
                        GroupedCard(dividerInset: Layout.rowInset) {
                            if !data["parent"].isNull {
                                Button {
                                    guard !loading else { return }
                                    Task { await browse(data["parent"].string) }
                                } label: {
                                    ListRow(symbol: "arrow.up", title: "上一级") { EmptyView() }
                                }.buttonStyle(.row).disabled(loading)
                            }
                            ForEach(data["directories"].array.map(\.string), id: \.self) { directory in
                                Button {
                                    guard !loading else { return }
                                    Task { await browse(directory) }
                                } label: {
                                    ListRow(symbol: "folder", tone: .neutral, title: URL(fileURLWithPath: directory).lastPathComponent)
                                }.buttonStyle(.row).disabled(loading)
                            }
                        }
                    }
                }
                if !data["recent"].array.isEmpty {
                    GroupSection("最近使用") {
                        GroupedCard(dividerInset: Layout.rowInset) {
                            ForEach(data["recent"].array.map(\.string), id: \.self) { directory in
                                Button {
                                    guard !loading else { return }
                                    Task { await browse(directory) }
                                } label: {
                                    ListRow(symbol: "clock", title: URL(fileURLWithPath: directory).lastPathComponent)
                                }.buttonStyle(.row).disabled(loading)
                            }
                        }
                    }
                }
            }
            .navigationTitle("工作目录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("使用这里") { path = data["path"].string; dismiss() }
                        .disabled(data["path"].string.isEmpty || loading)
                }
            }
            .task { await browse(path) }
        }
    }
    private func browse(_ directory: String) async {
        guard !loading else { return }
        loading = true
        failNote = ""
        defer {
            loading = false
            loadedOnce = true
        }
        let target = directory.isEmpty ? path : directory
        if let result = await model.load("/directories?path=" + target.queryEncoded) {
            data = result
        } else {
            let err = model.errors["/directories?path=" + target.queryEncoded] ?? model.errors["/directories"] ?? ""
            failNote = err.isEmpty
                ? "目录没读上——检查配对或网络后再试"
                : "目录没读上：" + err + "——可再试"
        }
    }
}

// r3-work：WorkDetailView（会话详情的整页 sheet）已拆进工作页的原地聊天——见 WorkChat.swift / WorkSessionModel.swift。
