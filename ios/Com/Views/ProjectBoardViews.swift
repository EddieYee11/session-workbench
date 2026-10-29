import SwiftUI
import ComCore

func projectStatus(_ status: String) -> String {
    switch status { case "active": "进行中"; case "pending": "未收尾"; case "completed": "已完成"; default: "待核对" }
}
private func projectTone(_ status: String) -> Tone {
    switch status { case "active": .neutral; case "pending": .warning; case "completed": .success; default: .neutral }
}

/// 双机项目看板：每个项目一张便签（最近在干什么、哪台机器、哪个伙伴、下一步、未收尾的事），按最近活跃排序。
struct ProjectBoardHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let host: String
    @State private var selected: JSON?
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    private let path = "/personal/projects"
    private var data: JSON { model.datasets[path] ?? .null }
    private var projects: [JSON] {
        data["projects"].array
            .filter { p in host.isEmpty || p["items"].array.contains { $0["host"].string == host } }
            .sorted { latest($0) > latest($1) }
    }
    private func latest(_ project: JSON) -> Double { project["items"].array.map { $0["updated_at"].double }.max() ?? 0 }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.lg) {
            if loading || (!loadedOnce && data.isNull) {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在把两台电脑的会话拢到一起…").font(TypeScale.subheadline).foregroundStyle(Palette.textTertiary)
                }
                .padding(.horizontal, Space.xs)
                .accessibilityLabel("正在拉齐项目看板")
                .accessibilityIdentifier("project-board-pulling")
            }
            if !failNote.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    InlineNotice(text: failNote, tone: .danger)
                    Button(loading ? "重试中…" : "再试一次") {
                        guard !loading else { return }
                        Task { await refreshBoard(force: true) }
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(loading)
                    .accessibilityIdentifier("project-board-retry")
                }
                .padding(.horizontal, Space.xs)
            }
            if projects.isEmpty && loadedOnce && !loading {
                EmptyState(
                    title: failNote.isEmpty ? "这一栏还没有项目" : "项目看板还没读上",
                    description: failNote.isEmpty
                        ? "有需要收尾的活会自动归到项目里；也可以在工作页先开一段对话。"
                        : "先重试拉齐；通了我再开口列两台机器上的项目。别把失败当成「没有项目」。",
                    symbol: "rectangle.3.group"
                )
                .accessibilityIdentifier(failNote.isEmpty ? "project-board-empty" : "project-board-empty-fail")
            }
            ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                let items = project["items"].array.sorted { $0["updated_at"].double > $1["updated_at"].double }
                let newest = items.first ?? .null
                let next = items.first { !$0["next_step"].string.isEmpty && ["pending", "active"].contains($0["status"].string) }
                let pending = project["counts"]["pending"].int
                Button { selected = project; Haptics.selection() } label: {
                    VStack(alignment: .leading, spacing: Space.md - 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(project["title"].string).font(TypeScale.headline).lineLimit(2)
                            Spacer(minLength: Space.sm)
                            Text(relativeTime(latest(project))).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                        }
                        HStack(spacing: Space.md) {
                            HStack(spacing: 5) {
                                Circle().fill(newest["status"].string == "active" ? Palette.success : Palette.textTertiary.opacity(0.6)).frame(width: 6, height: 6)
                                Text((hostName(newest["host"].string).isEmpty ? "" : hostName(newest["host"].string) + " · ") + agentName(newest["agent"].string))
                            }
                            if pending > 0 { Text("未收尾 \(pending)").foregroundStyle(Palette.warning) }
                            if project["counts"]["active"].int > 0 { Text("在跑 \(project["counts"]["active"].int)") }
                        }.font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        if !newest["summary"].string.isEmpty { Text(newest["summary"].string).font(TypeScale.body).foregroundStyle(Palette.textSecondary).lineLimit(2).lineSpacing(3) }
                        if let next {
                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                Text("下一步").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.accentText).fixedSize()
                                Text(next["next_step"].string).font(TypeScale.body).lineLimit(2)
                                Spacer(minLength: 0)
                                Chevron()
                            }.padding(.top, Space.sm + 2).overlay(alignment: .top) { DashedRule() }
                        }
                    }
                    .padding(.horizontal, Space.lg + 2).padding(.vertical, Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .noteSurface()
                }.buttonStyle(SoftPressStyle(scale: 0.985)).accessibilityIdentifier("project-card-" + project.id)
                    .transition(reduce ? .opacity : .offset(y: 8).combined(with: .opacity))
            }
            if !data["note"].string.isEmpty || !data["hosts"].array.isEmpty {
                HStack(spacing: Space.md) {
                    ForEach(["mini", "macbook"], id: \.self) { entry in
                        let row = data["hosts"].array.first { $0["host"].string == entry }
                        HStack(spacing: 5) {
                            Circle().fill(row == nil || row?["stale"].bool == true ? Palette.textTertiary.opacity(0.5) : Palette.success).frame(width: 6, height: 6)
                            Text(hostName(entry) + (row == nil ? " 待同步" : row?["stale"].bool == true ? " 旧快照" : ""))
                        }
                    }
                    Spacer()
                }.font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.xs)
            }
        }
        .animation(ComMotion.reduced(reduce, ComMotion.settle), value: projects.map(\.id))
        .task { await refreshBoard(force: false) }
        .refreshable { await refreshBoard(force: true) }
        .sheet(item: Binding(get: { selected.map(RemoteRow.init) }, set: { selected = $0?.value })) { ProjectBoardDetail(project: $0.value) }
    }
    private func refreshBoard(force: Bool) async {
        guard !loading else { return }
        loading = true
        if force { failNote = "" }
        defer {
            loading = false
            loadedOnce = true
        }
        if await model.load(path) != nil {
            failNote = ""
            return
        }
        let err = model.errors[path] ?? ""
        let had = !data["projects"].array.isEmpty
        failNote = err.isEmpty
            ? (had ? "项目看板没刷新上——下面仍是上一版，可再试" : "项目看板没拉齐——检查配对或网络后再试")
            : (had ? "项目看板没刷新上：" + err + "——下面仍是上一版" : "项目看板没拉齐：" + err + "——可再试")
    }
}

/// 项目详情：该项目下的会话事项列表 + 派新活入口。
struct ProjectBoardDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: JSON
    @State private var selected: JSON?
    @State private var dispatching = false
    private var sessions: [JSON] {
        let ids = Set(project["items"].array.map { $0["session_id"].string }.filter { !$0.isEmpty })
        return (model.datasets["/sessions"]?["sessions"].array ?? []).filter { ids.contains($0.id) }
    }
    var body: some View {
        DetailPage(title: "项目") {
            DetailHeader(title: project["title"].string, subtitle: "\(project["items"].array.count) 个来源会话 · 会话报告保留来源，证据不足的留在待核对") { Stamp(text: "工作") }
            Button { dispatching = true } label: { Text("派新活") }.buttonStyle(.primaryFull)
            ForEach(["pending", "active", "completed", "uncertain"], id: \.self) { status in
                let items = project["items"].array.filter { $0["status"].string == status }
                if !items.isEmpty {
                    GroupSection(projectStatus(status) + " · \(items.count)") {
                        ForEach(items.map(RemoteRow.init)) { row in
                            Button { selected = row.value } label: {
                                Card {
                                    VStack(alignment: .leading, spacing: Space.md - 2) {
                                        HStack { Stamp(text: projectStatus(status), tone: projectTone(status)); Spacer(); Text([hostName(row.value["host"].string), agentName(row.value["agent"].string)].filter { !$0.isEmpty }.joined(separator: " · ")).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) }
                                        Text(row.value["title"].string).font(TypeScale.headline).multilineTextAlignment(.leading)
                                        if !row.value["summary"].string.isEmpty { Text(row.value["summary"].string).font(TypeScale.body).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.leading).lineSpacing(3) }
                                        if !row.value["next_step"].string.isEmpty {
                                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) { Text("下一步").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.accentText); Text(row.value["next_step"].string).font(TypeScale.body).multilineTextAlignment(.leading) }
                                        }
                                        HStack { Text(row.value["stale"].bool ? "旧快照 · 看依据" : "看依据与会话"); Spacer(); Chevron() }.font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                                    }
                                }
                            }.buttonStyle(SoftPressStyle(scale: 0.985)).accessibilityIdentifier("project-item-" + row.id)
                        }
                    }
                }
            }
            if !sessions.isEmpty {
                GroupSection("可以继续的会话") {
                    GroupedCard {
                        ForEach(sessions.prefix(12).map(RemoteRow.init)) { row in
                            Button { dismiss(); model.selectedSession = row.value } label: {
                                ListRow(symbol: "bubble.left", title: row.value["display_title"].string.isEmpty ? row.value["title"].string : row.value["display_title"].string, status: agentName(row.value["agent"].string), subtitle: row.value["snippet"].string, subtitleLines: 1)
                            }.buttonStyle(.row)
                        }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { selected.map(RemoteRow.init) }, set: { selected = $0?.value })) { BoardSourceView(item: $0.value) }
        .sheet(isPresented: $dispatching) { NewWorkView(initialAgent: "codex", initialPrompt: "", initialDirectory: project["cwd"].string.isEmpty ? project["path"].string : project["cwd"].string) }
    }
}

struct BoardSourceView: View {
    @Environment(AppModel.self) private var model
    let item: JSON
    @State private var source: JSON = .null
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    var body: some View {
        DetailPage(title: "进展依据") {
            DetailHeader(title: item["title"].string, subtitle: [hostName(item["host"].string), agentName(item["agent"].string)].filter { !$0.isEmpty }.joined(separator: " · ")) { Stamp(text: projectStatus(item["status"].string), tone: projectTone(item["status"].string)) }
            if !item["evidence_quote"].string.isEmpty {
                Card(.highlighted(.accent)) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("会话中的依据").font(TypeScale.section).foregroundStyle(Palette.accentText)
                        LinedText(text: item["evidence_quote"].string)
                        Text("是具体事项的会话报告，仍可能需要实际验收。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    }
                }.padding(.top, Space.sm)
            }
            GroupSection("最近的对话") {
                if loading || !loadedOnce {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在读取来源会话…").font(TypeScale.body).foregroundStyle(Palette.textSecondary)
                    }
                    .accessibilityLabel("正在读取来源会话")
                } else if !failNote.isEmpty {
                    InlineNotice(text: failNote, tone: .danger)
                    Button(loading ? "重试中…" : "再试一次") {
                        guard !loading else { return }
                        Task { await reload() }
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(loading)
                    .accessibilityIdentifier("board-source-retry")
                } else if source["messages"].array.isEmpty {
                    Text("来源会话里暂时没有可摘的消息。")
                        .font(TypeScale.body).foregroundStyle(Palette.textSecondary)
                } else {
                    ForEach(Array(source["messages"].array.enumerated()), id: \.offset) { _, message in
                        Card {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text(message["role"].string == "user" ? "你" : agentName(item["agent"].string)).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                                RichText(text: message["text"].string)
                            }
                        }
                    }
                }
            }
            Text("这是最近消息的只读摘录，打开它不会启动或续接原会话。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
        }
        .task { await reload() }
    }

    private func reload() async {
        guard !loading else { return }
        // 首次 / 重试：明确 busy，失败别永远停在「正在读取」。
        loading = true
        failNote = ""
        defer {
            loading = false
            loadedOnce = true
        }
        if let data = await model.load("/personal/projects/sources/" + item.id.pathEncoded) {
            source = data
            if let err = model.errors["/personal/projects/sources/" + item.id.pathEncoded], !err.isEmpty, data["messages"].array.isEmpty {
                failNote = "没读到会话摘录：" + err + "——可再试"
            }
        } else {
            source = .null
            let err = model.errors["/personal/projects/sources/" + item.id.pathEncoded] ?? ""
            failNote = err.isEmpty ? "没读到来源会话——检查配对或网络后再试" : "没读到会话摘录：" + err + "——可再试"
        }
    }
}
