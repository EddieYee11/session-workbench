import SwiftUI
import ComCore

/// 工作 Tab 的第二面「运行」：手机上不开终端就能看状态、审阅改动、追问。
/// 数据全来自 mini 后端 `/remote/fleet`（会话 + 航程 + Rex + herdr 合并，来源失败各自标明）。
/// 不覆盖「对话」派活面；由 `WorkSurface` 切换进入。

enum WorkSurface: String, CaseIterable, Identifiable {
    case sessions, remote, terminal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: return "对话"
        case .remote: return "运行"
        case .terminal: return "终端"
        }
    }
}

struct WorkSurfacePicker: View {
    @Binding var surface: WorkSurface
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var workSurfaceNS
    var body: some View {
        HStack(spacing: 4) {
            ForEach(WorkSurface.allCases) { item in
                Button {
                    Haptics.selection()
                    withAnimation(reduce ? .easeOut(duration: 0.15) : ComMotion.snap) { surface = item }
                } label: {
                    Text(item.title)
                        .font(TypeScale.subheadline.weight(.semibold))
                        .foregroundStyle(surface == item ? Palette.onAccent : Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if surface == item {
                                Capsule().fill(Palette.accent)
                                    .matchedGeometryEffect(id: "work-surface-pill", in: workSurfaceNS, properties: .frame, isSource: true)
                            }
                        }
                }
                .buttonStyle(SoftPressStyle(scale: 0.96))
                .accessibilityIdentifier("work-surface-\(item.rawValue)")
                .accessibilityAddTraits(surface == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.fill, in: .capsule)
        .padding(.horizontal, Layout.margin)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work-surface-picker")
    }
}

// MARK: - 运行面

private func runAgentSymbol(_ hint: String) -> String {
    switch hint {
    case "claude": return "sparkles"
    case "pi": return "circle.hexagongrid"
    case "codex": return "chevron.left.forwardslash.chevron.right"
    case "herdr": return "rectangle.split.3x1"
    case "shell": return "terminal"
    default: return "square.grid.2x2"
    }
}

private func runTone(_ state: String) -> Tone {
    switch state {
    case "needs_you": return .warning
    case "failed": return .danger
    case "running": return .info
    case "done": return .success
    default: return .neutral
    }
}

private func runStateLabel(_ state: String) -> String {
    switch state {
    case "needs_you": return "需要你"
    case "failed": return "失败"
    case "running": return "在跑"
    case "done": return "做完了"
    default: return "空闲"
    }
}

/// 来源失败说人话；不通就直说，不假装在线。
private func runSourceProblem(_ source: JSON) -> String {
    let name = source["name"].string
    let label = ["sessions": "会话", "cases": "航程", "rex": "Rex", "herdr": "herdr"][name] ?? name
    switch source["error"].string {
    case "server_not_running": return "herdr 没开：mini 上没有启动 herdr server。"
    case "herdr_not_found": return "mini 上没有 herdr 命令。"
    case "rex_not_found": return "mini 上没有 rex 命令。"
    case "unreachable": return "\(label) 连不上：服务没在接受连接。"
    case "timeout": return "\(label) 读取超时。"
    default:
        let detail = source["detail"].string
        return detail.isEmpty ? "\(label) 没读到。" : "\(label) 没读到：\(detail)"
    }
}

/// 运行面：状态优先列表——需要你 / 失败 / 在跑 / 做完了。
struct WorkRemoteSurface: View {
    @Environment(AppModel.self) private var model
    @State private var items: [JSON] = []
    @State private var sources: [JSON] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var failNote = ""
    @State private var selected: RemoteRow?

    private static let sections: [(key: String, title: String)] = [
        ("needs_you", "需要你"), ("failed", "失败"), ("running", "在跑"), ("done", "做完了"),
    ]

    private func group(_ key: String) -> [JSON] {
        items.filter { item in
            let state = item["state"].string
            return key == "done" ? (state == "done" || state == "idle") : state == key
        }
    }

    private var hasRunning: Bool { items.contains { $0["state"].string == "running" } }

    private var sourceLine: String {
        guard !sources.isEmpty else { return "" }
        let names = ["sessions": "会话", "cases": "航程", "rex": "Rex", "herdr": "herdr"]
        return sources.map { s in
            let label = names[s["name"].string] ?? s["name"].string
            if s["ok"].bool { return "\(label) 通" }
            switch s["error"].string {
            case "server_not_running": return "\(label) 没开"
            case "herdr_not_found", "rex_not_found": return "\(label) 没装"
            default: return "\(label) 没读到"
            }
        }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                header
                if !failNote.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        InlineNotice(text: failNote, tone: .danger)
                        Button("重试") { Task { await refresh() } }
                            .buttonStyle(.secondaryCompact)
                            .accessibilityIdentifier("run-retry")
                    }
                }
                ForEach(Array(sources.filter { !$0["ok"].bool }.enumerated()), id: \.offset) { _, source in
                    InlineNotice(text: runSourceProblem(source), tone: .warning)
                }
                ForEach(Self.sections, id: \.key) { section in
                    let rows = group(section.key)
                    if !rows.isEmpty { sectionView(section.key, section.title, rows) }
                }
                if loaded && failNote.isEmpty && items.isEmpty {
                    Text("最近 7 天没有在跑或做完的事。")
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier("run-empty")
                }
            }
            .padding(.horizontal, Layout.margin)
            .padding(.bottom, Space.xxxl)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("work-remote-surface")
        .refreshable { await refresh() }
        .task {
            await refresh()
            // 有在跑项时每 10 秒静默刷一次；页面消失，任务取消，循环即停。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                if hasRunning { await refresh(silent: true) }
            }
        }
        .sheet(item: $selected) { row in
            RunDetailView(item: row.value)
                .environment(model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("运行").font(TypeScale.title)
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.small) }
            }
            if !sourceLine.isEmpty {
                Text(sourceLine)
                    .font(TypeScale.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityIdentifier("run-sources")
            }
        }
    }

    private func sectionView(_ key: String, _ title: String, _ rows: [JSON]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("\(title) · \(rows.count)")
                .font(TypeScale.subheadline.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("run-section-\(key)")
            GroupedCard {
                ForEach(rows, id: \.id) { item in
                    Button { selected = RemoteRow(item) } label: { row(item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("run-row-\(item["id"].string)")
                }
            }
        }
    }

    private func row(_ item: JSON) -> some View {
        let state = item["state"].string
        let reason = item["waiting_reason"].string
        let when = relativeTime(item["last_activity_at"].double)
        let sub = state == "needs_you" && !reason.isEmpty ? reason : [state == "idle" ? "空闲" : "", when].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: Space.md) {
            IconBadge(symbol: runAgentSymbol(item["agent"].string), tone: runTone(state))
            VStack(alignment: .leading, spacing: 2) {
                Text(item["title"].string.isEmpty ? item["id"].string : item["title"].string)
                    .font(TypeScale.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                if !item["goal"].string.isEmpty {
                    Text(item["goal"].string)
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                if !sub.isEmpty {
                    Text(sub)
                        .font(TypeScale.footnote)
                        .foregroundStyle(state == "needs_you" ? Palette.warning : Palette.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
                .padding(.top, Space.xs)
        }
        .rowPadding()
        .contentShape(.rect)
    }

    private func refresh(silent: Bool = false) async {
        if loading && !silent { return }
        if !silent { loading = true }
        defer { if !silent { loading = false } }
        guard let data = await model.load("/remote/fleet") else {
            let why = model.errors["/remote/fleet"]
            failNote = (!model.isPaired && why == nil)
                ? "还没跟 Mac mini 配对——先回 Com 对话页完成配对。"
                : "没连上 Mac mini（\(why ?? "没有返回")）。下面如果有内容，是上次读到的，不一定是现状。"
            loaded = true
            return
        }
        failNote = ""
        items = data["items"].array
        sources = data["sources"].array
        loaded = true
    }
}

/// 一条运行项的详情：阶段与原因 → 改动 → 产物 → 操作。
struct RunDetailView: View {
    let item: JSON
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var changes: JSON = .null
    @State private var changesNote = ""
    @State private var changesLoading = false
    @State private var diffs: [String: [String]] = [:]
    @State private var openFile: String?
    @State private var artifacts: [JSON] = []
    @State private var artifactsNote = ""
    @State private var actionNote = ""

    private var kind: String { item["kind"].string }
    private var state: String { item["state"].string }
    private var sessionID: String { item["session_id"].string }
    private var caseID: String { item["case_id"].string }
    private var title: String { item["title"].string.isEmpty ? item["id"].string : item["title"].string }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    stageSection
                    if !sessionID.isEmpty { changesSection }
                    if !caseID.isEmpty { artifactsSection }
                    actionsSection
                }
                .padding(.horizontal, Layout.margin)
                .padding(.bottom, Space.xxxl)
            }
            .scrollIndicators(.hidden)
            .background(Palette.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task { await loadChanges() }
        .task { await loadArtifacts() }
    }

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                StatusPill(text: runStateLabel(state), tone: runTone(state))
                if !item["agent"].string.isEmpty {
                    Label(item["agent"].string, systemImage: runAgentSymbol(item["agent"].string))
                        .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            if !item["waiting_reason"].string.isEmpty {
                Text(item["waiting_reason"].string).font(TypeScale.callout).foregroundStyle(Palette.warning)
            }
            if !item["goal"].string.isEmpty {
                Text(item["goal"].string).font(TypeScale.callout).foregroundStyle(Palette.textPrimary)
            }
            Text([relativeTime(item["last_activity_at"].double), item["host"].string].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: 改动

    private var changesSection: some View {
        GroupSection("改动") {
            if changesLoading {
                Text("正在读 git 状态…").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            } else if !changesNote.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    InlineNotice(text: changesNote, tone: .danger)
                    Button("重试") { Task { await loadChanges() } }
                        .buttonStyle(.secondaryCompact)
                        .accessibilityIdentifier("run-changes-retry")
                }
            } else if !changes["git"].bool {
                Text(changes["reason"].string.isEmpty ? "这个目录不在 git 仓库里，看不到改动。" : changes["reason"].string + "，看不到改动。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            } else if changes["files"].array.isEmpty {
                Text("工作区干净，没有未提交的改动。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: Space.md) {
                    if !changes["stat"].string.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(changes["stat"].string.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(TypeScale.code).foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                    GroupedCard {
                        ForEach(Array(changes["files"].array.enumerated()), id: \.offset) { _, file in
                            fileRow(file)
                        }
                    }
                    if changes["truncated"].bool {
                        InlineNotice(text: "改动太大，只显示前 200KB，后面的被截掉了。", tone: .warning)
                    }
                }
            }
        }
    }

    private func fileRow(_ file: JSON) -> some View {
        let path = file["path"].string
        let open = openFile == path
        return VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { openFile = open ? nil : path }
            } label: {
                HStack(spacing: Space.md) {
                    Text(file["status"].string).font(TypeScale.code).foregroundStyle(Palette.textSecondary).frame(width: 28, alignment: .leading)
                    Text(path).font(TypeScale.code).foregroundStyle(Palette.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.footnote).foregroundStyle(Palette.textTertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("run-file-\(path)")
            if open { diffView(diffs[Self.diffKey(path)] ?? []) }
        }
        .rowPadding()
    }

    private func diffView(_ lines: [String]) -> some View {
        Group {
            if lines.isEmpty {
                Text("没有可显示的 diff（新文件未跟踪，或改动在被截掉的部分里）。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            } else {
                // 按行懒排版，外面框一个最大高度的双向滚动区，长 diff 不会一次排完。
                let width = CGFloat(min(lines.reduce(0) { max($0, $1.count) }, 300)) * 8 + 16
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(TypeScale.code)
                                .foregroundStyle(Self.lineColor(line))
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(minWidth: width, alignment: .leading)
                                .background(Self.lineBackground(line))
                        }
                    }
                }
                .frame(maxHeight: 420)
                .background(Palette.fill, in: .rect(cornerRadius: Radius.xs, style: .continuous))
                .accessibilityIdentifier("run-diff")
            }
        }
    }

    private static func lineColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return Palette.textSecondary }
        if line.hasPrefix("+") { return Palette.success }
        if line.hasPrefix("-") { return Palette.danger }
        if line.hasPrefix("@@") { return Palette.info }
        return Palette.textPrimary
    }

    private static func lineBackground(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Palette.success.opacity(0.12) }
        if line.hasPrefix("-") { return Palette.danger.opacity(0.12) }
        return .clear
    }

    private static func diffKey(_ path: String) -> String {
        // porcelain 改名写作 "old -> new"，diff 头里用新路径。
        path.components(separatedBy: " -> ").last ?? path
    }

    /// 把整段 diff 按 `diff --git a/x b/x` 切成每个文件一段。
    private static func splitDiff(_ diff: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String?
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git "), let r = line.range(of: " b/", options: .backwards) {
                current = String(line[r.upperBound...])
                out[current!] = [line]
            } else if let key = current {
                out[key, default: []].append(line)
            }
        }
        return out
    }

    private func loadChanges() async {
        guard !sessionID.isEmpty else { return }
        let path = "/sessions/" + sessionID.pathEncoded + "/changes"
        changesLoading = true
        changesNote = ""
        defer { changesLoading = false }
        let data = await model.load(path)
        // diff 可能有 200KB：只在这一页用，别留进会落盘的 datasets 缓存。
        if !model.isUITesting { model.datasets[path] = nil }
        guard let data else {
            changesNote = "没读到改动（\(model.errors[path] ?? "没有返回")）。"
            return
        }
        changes = data
        diffs = Self.splitDiff(data["diff"].string)
    }

    // MARK: 产物

    private var artifactsSection: some View {
        GroupSection("产物") {
            if !artifactsNote.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    InlineNotice(text: artifactsNote, tone: .danger)
                    Button("重试") { Task { await loadArtifacts() } }
                        .buttonStyle(.secondaryCompact)
                        .accessibilityIdentifier("run-artifacts-retry")
                }
            } else if artifacts.isEmpty {
                Text("还没有产物。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            } else {
                ArtifactList(artifacts: artifacts, chips: true)
            }
        }
    }

    private func loadArtifacts() async {
        guard !caseID.isEmpty else { return }
        artifactsNote = ""
        let path = "/personal/cases/" + caseID.pathEncoded
        guard let data = await model.load(path) else {
            artifactsNote = "没读到产物（\(model.errors[path] ?? "没有返回")）。"
            return
        }
        artifacts = data["artifacts"].array.filter { !$0["path"].string.isEmpty }
    }

    // MARK: 操作

    private var actionsSection: some View {
        GroupSection("操作") {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    if kind == "session", !sessionID.isEmpty {
                        Button("打开原会话") {
                            // 工作页可能停在「运行」面，先切回「对话」面再打开会话。
                            UserDefaults.standard.set(WorkSurface.sessions.rawValue, forKey: "work.surface")
                            dismiss()
                            model.selectedSession = .object(["id": .string(sessionID), "agent": item["agent"].string.isEmpty ? .string("pi") : item["agent"]])
                        }
                        .buttonStyle(.primaryCompact)
                        .accessibilityIdentifier("run-open-session")
                    }
                    if kind == "case", !caseID.isEmpty {
                        Button("打开航程") {
                            dismiss()
                            let id = caseID
                            Task { try? await Task.sleep(for: .milliseconds(350)); model.presentedCase = id }
                        }
                        .buttonStyle(.primaryCompact)
                        .accessibilityIdentifier("run-open-case")
                    }
                    if kind == "rex" {
                        let rex = item["rex"]
                        if !rex["block_id"].string.isEmpty {
                            Button("中断 ⌃C") {
                                Task { await runRexAction("send_template", args: ["block_id": .string(rex["block_id"].string), "template": .string("interrupt")]) }
                            }
                            .buttonStyle(.secondaryCompact)
                            .accessibilityIdentifier("run-rex-interrupt")
                        }
                        if !rex["window_id"].string.isEmpty, !rex["session_id"].string.isEmpty {
                            Button("聚焦") {
                                Task { await runRexAction("focus_window", args: ["session_id": .string(rex["session_id"].string), "window_id": .string(rex["window_id"].string)]) }
                            }
                            .buttonStyle(.secondaryCompact)
                        }
                    }
                    if kind == "herdr" {
                        let h = item["herdr"]
                        let machine = h["machine"].string.isEmpty ? item["host"].string : h["machine"].string
                        let tab = h["tab_id"].string
                        if !tab.isEmpty, !machine.isEmpty {
                            Button("聚焦") {
                                Task { await runHerdrAction("focus_tab", machine: machine, args: ["tab_id": .string(tab)], confirmed: false) }
                            }
                            .buttonStyle(.secondaryCompact)
                            .accessibilityIdentifier("run-herdr-focus")
                            if h["is_agent"].bool {
                                Button("中断 ⌃C") {
                                    Task {
                                        await runHerdrAction(
                                            "send_template",
                                            machine: machine,
                                            args: ["tab_id": .string(tab), "pane_id": .string(h["pane_id"].string), "template": .string("interrupt"), "is_agent": .bool(true)],
                                            confirmed: false
                                        )
                                    }
                                }
                                .buttonStyle(.secondaryCompact)
                                .accessibilityIdentifier("run-herdr-interrupt")
                            }
                        }
                    }
                    Button("追问") {
                        let text = "接着问「\(title)」（\(runStateLabel(state))）："
                        model.draft = model.draft.isEmpty ? text : model.draft
                        model.tab = .chat
                        Haptics.selection()
                        dismiss()
                    }
                    .buttonStyle(.secondaryCompact)
                    .accessibilityIdentifier("run-follow-up")
                    Spacer(minLength: 0)
                }
                if !actionNote.isEmpty { InlineNotice(text: actionNote, tone: .neutral) }
            }
        }
    }

    private func runRexAction(_ name: String, args: [String: JSON]) async {
        actionNote = ""
        do {
            let result = try await model.mutate("/remote/rex/action", fields: ["action": .string(name), "args": .object(args)])
            actionNote = result["ok"].bool ? "已执行 \(name)。" : (result["detail"].string.isEmpty ? "动作没成功。" : result["detail"].string)
        } catch {
            actionNote = error.localizedDescription
        }
    }

    private func runHerdrAction(_ name: String, machine: String, args: [String: JSON], confirmed: Bool) async {
        actionNote = ""
        let requestId = "ios-herdr-\(UUID().uuidString)"
        do {
            var fields: [String: JSON] = [
                "action": .string(name),
                "machine": .string(machine),
                "args": .object(args),
                "request_id": .string(requestId),
            ]
            if confirmed { fields["confirmed"] = .bool(true) }
            let result = try await model.mutate("/remote/herdr/action", fields: fields)
            if result["ok"].bool {
                actionNote = result["applied"]["ok"].bool == false
                    ? (result["applied"]["detail"].string.isEmpty ? "已入队，本机执行失败。" : result["applied"]["detail"].string)
                    : (machine == "mini" ? "已执行 \(name)。" : "已入队，等 \(machine) 拉取执行。")
            } else {
                actionNote = result["detail"].string.isEmpty ? "动作没成功（可能写开关关着）。" : result["detail"].string
            }
        } catch {
            actionNote = error.localizedDescription
        }
    }
}
