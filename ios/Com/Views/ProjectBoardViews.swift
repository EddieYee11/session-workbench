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
    private var data: JSON { model.datasets["/personal/projects"] ?? .null }
    private var projects: [JSON] {
        data["projects"].array
            .filter { p in host.isEmpty || p["items"].array.contains { $0["host"].string == host } }
            .sorted { latest($0) > latest($1) }
    }
    private func latest(_ project: JSON) -> Double { project["items"].array.map { $0["updated_at"].double }.max() ?? 0 }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.lg) {
            if projects.isEmpty {
                EmptyState(title: data.isNull ? "正在汇总两台电脑的会话" : "这一栏还没有项目", description: "每 15 分钟整理一次有变化的会话；有需要收尾的事会出现在流里。", symbol: "rectangle.3.group")
            }
            ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                let items = project["items"].array.sorted { $0["updated_at"].double > $1["updated_at"].double }
                let newest = items.first ?? .null
                let next = items.first { !$0["next_step"].string.isEmpty && ["pending", "active"].contains($0["status"].string) }
                let pending = project["counts"]["pending"].int
                Button { selected = project } label: {
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
                }.buttonStyle(.plain).accessibilityIdentifier("project-card-" + project.id)
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
        .animation(reduce ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.88), value: projects.map(\.id))
        .sheet(item: Binding(get: { selected.map(RemoteRow.init) }, set: { selected = $0?.value })) { ProjectBoardDetail(project: $0.value) }
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
                            }.buttonStyle(.plain).accessibilityIdentifier("project-item-" + row.id)
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
                if source["messages"].array.isEmpty { Text("正在读取来源会话…").font(TypeScale.body).foregroundStyle(Palette.textSecondary) }
                ForEach(Array(source["messages"].array.enumerated()), id: \.offset) { _, message in
                    Card {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(message["role"].string == "user" ? "你" : agentName(item["agent"].string)).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                            RichText(text: message["text"].string)
                        }
                    }
                }
            }
            Text("这是最近消息的只读摘录，打开它不会启动或续接原会话。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
        }.task { source = await model.load("/personal/projects/sources/" + item.id.pathEncoded) ?? .null }
    }
}
