import SwiftUI
import ComCore

func projectStatus(_ status: String) -> String {
    switch status { case "active": "进行中"; case "pending": "待推进"; case "completed": "已完成"; default: "待核对" }
}
private func projectTone(_ status: String) -> Tone {
    switch status { case "active": .info; case "pending": .warning; case "completed": .success; default: .neutral }
}

struct ProjectBoardHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var filter = "全部"
    @State private var selected: JSON?
    private var data: JSON { model.datasets["/personal/projects"] ?? .null }
    private var projects: [JSON] {
        data["projects"].array.filter { p in filter == "全部" || p["items"].array.contains { projectStatus($0["status"].string) == filter } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Card(.ink, padding: Space.lg) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("让进展，一眼可见。").font(TypeScale.title).foregroundStyle(Palette.onInk)
                        Spacer(); Image(systemName: "rectangle.3.group").foregroundStyle(Palette.accent)
                    }
                    HStack(spacing: Space.md) {
                        ForEach(["active", "pending", "completed"], id: \.self) { status in
                            Button { withAnimation(reduce ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.88)) { filter = projectStatus(status) } } label: {
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Text("\(data["counts"][status].int)").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText()).foregroundStyle(status == "pending" ? Palette.accent : Palette.onInk)
                                    Text(projectStatus(status)).font(TypeScale.footnote).foregroundStyle(Palette.onInkSecondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                    Text("最近 30 天 · 双机会话整理").font(TypeScale.caption).foregroundStyle(Palette.onInkSecondary)
                }
            }
            HStack(spacing: Space.md) {
                ForEach(["macbook", "mini"], id: \.self) { host in
                    let entry = data["hosts"].array.first { $0["host"].string == host }
                    HStack(spacing: 5) {
                        Circle().fill(entry == nil || entry?["stale"].bool == true ? Palette.textTertiary : Color.green).frame(width: 6, height: 6)
                        Text(host == "mini" ? "Mac mini" : "MacBook")
                        Text(entry == nil ? "待同步" : entry?["stale"].bool == true ? "旧快照" : "已同步").foregroundStyle(Palette.textTertiary)
                    }.font(TypeScale.caption)
                }
                Spacer()
            }
            FilterChips(options: ["全部", "进行中", "待推进", "已完成", "待核对"], selection: $filter, animation: reduce ? .easeOut(duration: 0.12) : .smooth(duration: 0.2))
            if projects.isEmpty { EmptyState(title: data.isNull ? "正在汇总工作进展" : "这一栏暂时没有项目", description: "每 15 分钟整理有变化的会话，建议也会出现在今天页。", symbol: "rectangle.3.group") }
            ForEach(projects.map(RemoteRow.init)) { row in
                Button { selected = row.value } label: {
                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            HStack(alignment: .top) {
                                IconBadge(symbol: "folder", tone: .accent)
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Text(row.value["title"].string).font(TypeScale.headline).lineLimit(2)
                                    Text("\(row.value["items"].array.count) 个会话 · " + Array(Set(row.value["items"].array.map { agentName($0["agent"].string) })).sorted().joined(separator: " / ")).font(TypeScale.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                                }
                                Spacer(); Chevron()
                            }
                            if let action = row.value["items"].array.first(where: { !$0["next_step"].string.isEmpty && ["pending", "active"].contains($0["status"].string) }) {
                                Text(action["next_step"].string).font(TypeScale.callout).foregroundStyle(Palette.textSecondary).lineLimit(2)
                            }
                            HStack(spacing: Space.sm) {
                                ForEach(["active", "pending", "completed", "uncertain"], id: \.self) { status in
                                    if row.value["counts"][status].int > 0 { StatusPill(text: "\(row.value["counts"][status].int) " + projectStatus(status), tone: projectTone(status)) }
                                }
                            }
                        }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("project-card-" + row.id)
                    .transition(reduce ? .opacity : .offset(y: 8).combined(with: .opacity))
            }
            Text(data["note"].string).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
        }
        .animation(reduce ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.88), value: projects.map(\.id))
        .sheet(item: Binding(get: { selected.map(RemoteRow.init) }, set: { selected = $0?.value })) { ProjectBoardDetail(project: $0.value) }
    }
}

struct ProjectBoardDetail: View {
    @Environment(AppModel.self) private var model
    let project: JSON
    @State private var selected: JSON?
    var body: some View {
        DetailPage(title: "项目看板") {
            DetailHeader(title: project["title"].string, subtitle: "会话报告保留来源；没有足够证据的事项会留在待核对。") { StatusPill(text: "\(project["items"].array.count) 个来源会话", tone: .accent) }
            ForEach(["pending", "active", "completed", "uncertain"], id: \.self) { status in
                let items = project["items"].array.filter { $0["status"].string == status }
                if !items.isEmpty {
                    GroupSection(projectStatus(status)) {
                        ForEach(items.map(RemoteRow.init)) { row in
                            Button { selected = row.value } label: {
                                Card {
                                    VStack(alignment: .leading, spacing: Space.md) {
                                        HStack { StatusPill(text: projectStatus(status), tone: projectTone(status)); Spacer(); Text(row.value["host"].string == "mini" ? "Mac mini" : "MacBook").font(TypeScale.caption).foregroundStyle(Palette.textTertiary) }
                                        Text(row.value["title"].string).font(TypeScale.headline).multilineTextAlignment(.leading)
                                        Text(row.value["summary"].string).font(TypeScale.callout).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.leading)
                                        if !row.value["next_step"].string.isEmpty { Label(row.value["next_step"].string, systemImage: "arrow.turn.down.right").font(TypeScale.callout).multilineTextAlignment(.leading) }
                                        HStack { Text(agentName(row.value["agent"].string)); Spacer(); Text(row.value["stale"].bool ? "旧快照 · 查看依据" : "查看依据与会话"); Chevron() }.font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
                                    }
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("project-item-" + row.id)
                        }
                    }
                }
            }
        }.sheet(item: Binding(get: { selected.map(RemoteRow.init) }, set: { selected = $0?.value })) { BoardSourceView(item: $0.value) }
    }
}

struct BoardSourceView: View {
    @Environment(AppModel.self) private var model
    let item: JSON
    @State private var source: JSON = .null
    var body: some View {
        DetailPage(title: "进展依据") {
            DetailHeader(title: item["title"].string, subtitle: (item["host"].string == "mini" ? "Mac mini" : "MacBook") + " · " + agentName(item["agent"].string)) { StatusPill(text: projectStatus(item["status"].string), tone: projectTone(item["status"].string)) }
            if !item["evidence_quote"].string.isEmpty {
                Card(.highlighted(.accent)) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Label("会话中的依据", systemImage: "quote.opening").font(TypeScale.headline)
                        Text(item["evidence_quote"].string).font(TypeScale.callout).textSelection(.enabled)
                        Text("是具体事项的会话报告，仍可能需要实际验收。").font(TypeScale.caption).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            GroupSection("最近的对话") {
                if source["messages"].array.isEmpty { Text("正在读取来源会话…").font(TypeScale.callout).foregroundStyle(Palette.textSecondary) }
                ForEach(Array(source["messages"].array.enumerated()), id: \.offset) { _, message in
                    Card {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(message["role"].string == "user" ? "你" : agentName(item["agent"].string)).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                            RichText(text: message["text"].string, font: TypeScale.callout)
                        }
                    }
                }
            }
            Text("这是最近消息的只读摘录，打开它不会启动或续接原会话。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
        }.task { source = await model.load("/personal/projects/sources/" + item.id.pathEncoded) ?? .null }
    }
}
