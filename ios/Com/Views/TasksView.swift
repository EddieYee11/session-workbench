import SwiftUI
import ComCore

struct TaskSummary: View {
    let task: JSON
    private var passed: Bool { task["acceptance_passed"].bool }
    private var attention: Bool {
        !passed && ["waiting", "failed", "execution_finished", "unknown", "paused"].contains(task["status"].string)
    }
    var body: some View {
        RowCard {
            HStack(alignment: .top, spacing: Space.md) {
                IconBadge(symbol: passed ? "checkmark" : "point.3.connected.trianglepath.dotted",
                          tint: passed ? Palette.accent : Palette.raised)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(task["title"].string).font(TypeScale.chat.weight(.semibold)).lineLimit(3)
                    Text(passed ? "验收通过" : displayStatus(task["status"].string))
                        .font(TypeScale.footnote.weight(attention ? .semibold : .regular))
                        .foregroundStyle(attention ? Palette.coral : .secondary)
                    if !task["completion_condition"].string.isEmpty {
                        Text(task["completion_condition"].string).font(TypeScale.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(TypeScale.footnote).foregroundStyle(.tertiary)
            }
        }
    }
}

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = "全部"
    @State private var timed = false
    private var tasks: [JSON] { model.datasets["/personal/tasks"]?["items"].array ?? [] }
    private var filtered: [JSON] {
        tasks.filter { task in
            switch filter {
            case "执行中": return ["queued", "running", "dispatching", "cancel_requested"].contains(task["status"].string)
            case "待决定": return ["waiting", "unknown", "approval_required", "paused"].contains(task["status"].string)
            case "待验收": return task["status"].string == "execution_finished" && !task["acceptance_passed"].bool
            case "已完成": return task["acceptance_passed"].bool
            case "已结束": return ["failed", "cancelled", "rejected"].contains(task["status"].string)
            default: return true
            }
        }.sorted { $0["updated_at"].double > $1["updated_at"].double }
    }
    var body: some View {
        PageCanvas {
            PageHeading(title: "任务", subtitle: "")
            Picker("任务或定时工作", selection: $timed) { Text("任务").tag(false); Text("定时").tag(true) }.pickerStyle(.segmented)
            Freshness(path: timed ? "/personal/automations" : "/personal/tasks")
            if timed {
                let jobs = model.datasets["/personal/automations"]?["jobs"].array ?? []
                if jobs.isEmpty { EmptyState(title: "当前没有读取到定时工作", description: "已安排的工作由 Mac mini 执行。", symbol: "clock") }
                ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in TimedJobCard(job: job) }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        ForEach(["全部", "待决定", "执行中", "待验收", "已完成", "已结束"], id: \.self) { item in
                            Button { withAnimation(.smooth(duration: 0.2)) { filter = item } } label: {
                                Text(item).font(TypeScale.chat)
                                    .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                                    .foregroundStyle(filter == item ? Palette.onAccent : Color.primary)
                                    .background(filter == item ? Palette.accent : Palette.surface, in: .capsule)
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
                if filtered.isEmpty { EmptyState(title: "这一栏暂时是空的", description: "从聊天交办一件事，进度就会出现在这里。", symbol: "tray") }
                ForEach(filtered.map(RemoteRow.init)) { row in Button { model.selectedTask = row.value } label: { TaskSummary(task: row.value) }.buttonStyle(.plain).detailSource("task-" + row.id) }
                let proposals = model.datasets["/personal/work/proposals?limit=20"]?["items"].array ?? model.datasets["/personal/work/proposals?limit=20"]?["proposals"].array ?? []
                ForEach(proposals.filter { ["proposed", "pending", "approval_required"].contains($0["status"].string) }.map(RemoteRow.init)) { row in ProposalCard(proposal: row.value) }
            }
        }.refreshable { await model.refresh(.tasks) }
    }
}

struct ProposalCard: View {
    @Environment(AppModel.self) private var model
    let proposal: JSON
    @State private var expanded = false
    var body: some View {
        let prompt = proposal["prompt"].string
        SurfaceCard {
            VStack(alignment: .leading, spacing: Space.md) {
                Pill(text: "待你批准", color: Palette.coral)
                Text(proposal["title"].string).font(TypeScale.chat.weight(.semibold))
                Text(prompt).font(TypeScale.footnote).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                if prompt.count > 60 {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.quiet)
                }
                HStack(spacing: Space.md) {
                    Button("批准这项工作") { Task { await model.action("/personal/work/proposals/" + proposal.id.pathEncoded + "/approve", fields: ["explicit_authorization": .bool(true)], refresh: .tasks) } }.buttonStyle(.limeProminent)
                    Button("拒绝") { Task { await model.action("/personal/work/proposals/" + proposal.id.pathEncoded + "/reject", refresh: .tasks) } }.buttonStyle(.quiet)
                }
            }
        }
    }
}

struct TimedJobCard: View {
    let job: JSON
    @State private var expanded = false
    var body: some View {
        let prompt = job["prompt"].string
        SurfaceCard {
            VStack(alignment: .leading, spacing: Space.md) {
                Text(job["name"].string.isEmpty ? job["title"].string : job["name"].string).font(TypeScale.chat.weight(.semibold))
                Text(prompt).font(TypeScale.footnote).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                if prompt.count > 60 {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.quiet)
                }
                RawDetails(title: "运行记录与安排", value: job)
            }
        }
    }
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: JSON
    @State private var supplement = ""
    @State private var evidence = ""
    @State private var checked: Set<String> = []
    @State private var controlling = false
    @State private var showAllEvents = false
    private var current: JSON { model.datasets["/personal/tasks"]?["items"].array.first { $0.id == task.id } ?? task }
    private var pendingAcceptance: Bool { current["status"].string == "execution_finished" && !current["acceptance_passed"].bool }
    private var artifacts: [JSON] {
        current["artifacts"].array.isEmpty ? current["structured_result"]["artifacts"].array : current["artifacts"].array
    }
    private var visibleEvents: [JSON] {
        let events = current["events"].array
        return showAllEvents ? events : Array(events.suffix(3))
    }
    var body: some View {
        DetailPage(title: "任务详情") {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Pill(text: current["acceptance_passed"].bool ? "验收通过" : displayStatus(current["status"].string))
                    Spacer()
                    Text(agentName(current["agent"].string)).font(TypeScale.footnote).foregroundStyle(.secondary)
                }
                Text(current["title"].string).font(TypeScale.sectionTitle)
                if !current["completion_condition"].string.isEmpty {
                    Text(current["completion_condition"].string).font(TypeScale.footnote).foregroundStyle(.secondary)
                }
            }
            if pendingAcceptance {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("核对完成条件").font(TypeScale.chat.weight(.semibold))
                        ForEach(current["acceptance_criteria"].array.map(RemoteRow.init)) { criterion in
                            Toggle(criterion.value["text"].string.isEmpty ? criterion.value["description"].string : criterion.value["text"].string,
                                   isOn: Binding(get: { checked.contains(criterion.id) }, set: { if $0 { checked.insert(criterion.id) } else { checked.remove(criterion.id) } }))
                        }
                        TextField("填写你实际检查的结果或证据位置", text: $evidence, axis: .vertical).lineLimit(2...6)
                        Button("确认验收通过", systemImage: "checkmark.seal") {
                            let criteria = current["acceptance_criteria"].array
                            let refs: [JSON] = criteria.isEmpty ? [.object(["reference": .string(evidence), "passed": .bool(true)])] : criteria.map { .object(["criterion_id": .string($0.id), "reference": .string(evidence), "passed": .bool(true)]) }
                            command("verify", fields: ["explicit_acceptance": .bool(true), "evidence": .array(refs)])
                        }.buttonStyle(.limeProminent)
                            .disabled(evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checked.count != current["acceptance_criteria"].array.count || controlling)
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextField("补充新的要求", text: $supplement, axis: .vertical).lineLimit(2...6)
                    Button("补充到这项任务", systemImage: "arrow.turn.down.right") { command("input", fields: ["text": .string(supplement)]) }
                        .buttonStyle(.quiet)
                        .disabled(supplement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controlling)
                    HStack {
                        Button("停止任务", role: .destructive) { command("cancel") }
                            .buttonStyle(.quiet)
                            .disabled(controlling || ["cancelled", "failed"].contains(current["status"].string))
                        Spacer()
                        if ["paused", "unknown", "cancelled", "failed"].contains(current["status"].string) {
                            Button("恢复") { command("resume") }.buttonStyle(.quiet).disabled(controlling)
                        }
                    }
                    if !current["workspace_copy"].isNull {
                        Button("合入这次成果") { command("merge") }.buttonStyle(.quiet).disabled(current["verification_status"].string != "passed" || controlling)
                    }
                }
            }
            if !current["result"].string.isEmpty {
                DisclosureGroup("执行结果") {
                    RichText(text: current["result"].string).padding(.top, Space.sm)
                }.font(TypeScale.chat).tint(.primary)
            }
            if !current["structured_result"].isNull { RawDetails(title: "结果与检查记录", value: current["structured_result"]) }
            ArtifactList(artifacts: artifacts)
            if !current["events"].array.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Eyebrow(text: "真实步骤")
                    VStack(alignment: .leading, spacing: Space.md) {
                        ForEach(Array(visibleEvents.enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .top, spacing: Space.md) {
                                Circle().fill(Palette.cyan).frame(width: 6, height: 6).padding(.top, Space.xs)
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Text(eventLabel(event)).font(TypeScale.chat)
                                    if event["at"].double > 0 { Text(Date(timeIntervalSince1970: event["at"].double).formatted(date: .omitted, time: .shortened)).font(TypeScale.footnote).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    if current["events"].array.count > 3 {
                        Button(showAllEvents ? "收起" : "展开全部 \(current["events"].array.count) 条") { showAllEvents.toggle() }.buttonStyle(.quiet)
                    }
                }
            }
            RawDetails(title: "来源与约束", value: .object(["prompt": current["prompt"], "constraints": current["constraints"], "work_brief": current["work_brief"]]))
            if !current["origin_message_id"].string.isEmpty {
                Button("回到原交办消息", systemImage: "bubble.left") {
                    let id = current["origin_message_id"].string, session = current["source_session_id"].string
                    dismiss()
                    Task {
                        if !session.isEmpty && session != "personal-main" { model.workJumpMessage = current["source_message_id"].string; model.selectedSession = .object(["id": .string(session), "agent": current["agent"]]) }
                        else { await model.locateMessage(id) }
                    }
                }.buttonStyle(.quiet)
            }
        }
        .refreshable { await model.refresh(.tasks) }
    }
    private func command(_ action: String, fields: [String: JSON] = [:]) {
        controlling = true
        Task {
            defer { controlling = false }
            do { _ = try await model.mutate("/personal/tasks/" + task.id.pathEncoded + "/" + action, fields: fields); await model.refresh(.tasks); if action == "input" { supplement = "" } }
            catch { model.banner = error.localizedDescription }
        }
    }
}
