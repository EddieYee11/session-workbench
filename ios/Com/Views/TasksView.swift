import SwiftUI
import ComCore

struct TaskSummary: View {
    let task: JSON
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: task["acceptance_passed"].bool ? "checkmark" : "point.3.connected.trianglepath.dotted").font(.title3).foregroundStyle(.primary).frame(width: 44, height: 44).background(task["acceptance_passed"].bool ? Palette.accent : Palette.raised.opacity(0.6), in: .rect(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 7) {
                Text(task["title"].string).font(.headline).lineLimit(3)
                Text(task["acceptance_passed"].bool ? "验收通过" : displayStatus(task["status"].string)).font(.caption).foregroundStyle(.secondary)
                if !task["completion_condition"].string.isEmpty { Text(task["completion_condition"].string).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: .rect(cornerRadius: 22))
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
                ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(job["name"].string.isEmpty ? job["title"].string : job["name"].string).font(.headline)
                            Text(job["prompt"].string).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                            RawDetails(title: "运行记录与安排", value: job)
                        }
                    }
                }
            } else {
                ScrollView(.horizontal) { HStack { ForEach(["全部", "待决定", "执行中", "待验收", "已完成", "已结束"], id: \.self) { item in
                    Button { withAnimation(.smooth(duration: 0.2)) { filter = item } } label: { Text(item).font(.subheadline).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(filter == item ? Palette.onAccent : Color.primary).background(filter == item ? Palette.accent : Palette.surface, in: .capsule) }
                } } }.scrollIndicators(.hidden)
                if filtered.isEmpty { EmptyState(title: "这一栏暂时是空的", description: "从聊天交办一件事，进度就会出现在这里。", symbol: "tray") }
                ForEach(filtered.map(RemoteRow.init)) { row in Button { model.selectedTask = row.value } label: { TaskSummary(task: row.value) }.buttonStyle(.plain).detailSource("task-" + row.id) }
                let proposals = model.datasets["/personal/work/proposals?limit=20"]?["items"].array ?? model.datasets["/personal/work/proposals?limit=20"]?["proposals"].array ?? []
                ForEach(proposals.filter { ["proposed", "pending", "approval_required"].contains($0["status"].string) }.map(RemoteRow.init)) { row in
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Pill(text: "待你批准", color: Palette.coral)
                            Text(row.value["title"].string).font(.headline)
                            RichText(text: row.value["prompt"].string)
                            HStack {
                                Button("拒绝") { Task { await model.action("/personal/work/proposals/" + row.id.pathEncoded + "/reject", refresh: .tasks) } }.buttonStyle(.bordered)
                                Button("批准这项工作") { Task { await model.action("/personal/work/proposals/" + row.id.pathEncoded + "/approve", fields: ["explicit_authorization": .bool(true)], refresh: .tasks) } }.buttonStyle(.borderedProminent)
                            }.buttonBorderShape(.capsule)
                        }
                    }
                }
            }
        }.refreshable { await model.refresh(.tasks) }
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
    private var current: JSON { model.datasets["/personal/tasks"]?["items"].array.first { $0.id == task.id } ?? task }
    var body: some View {
        NavigationStack {
            PageCanvas {
                HStack { Pill(text: current["acceptance_passed"].bool ? "验收通过" : displayStatus(current["status"].string)); Spacer(); Text(agentName(current["agent"].string)).font(.caption).foregroundStyle(.secondary) }
                PageHeading(title: current["title"].string, subtitle: current["completion_condition"].string)
                if !current["result"].string.isEmpty { SurfaceCard { RichText(text: current["result"].string) } }
                if !current["structured_result"].isNull { RawDetails(title: "结果与检查记录", value: current["structured_result"]) }
                let artifacts = current["artifacts"].array.isEmpty ? current["structured_result"]["artifacts"].array : current["artifacts"].array
                ArtifactList(artifacts: artifacts)
                if !current["events"].array.isEmpty {
                    Eyebrow(text: "真实步骤")
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 17) {
                            ForEach(Array(current["events"].array.enumerated()), id: \.offset) { _, event in
                                HStack(alignment: .top, spacing: 12) {
                                    Circle().fill(Palette.cyan).frame(width: 6, height: 6).padding(.top, 6)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(eventLabel(event)).font(.subheadline)
                                        if event["at"].double > 0 { Text(Date(timeIntervalSince1970: event["at"].double).formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("补充新的要求", text: $supplement, axis: .vertical).lineLimit(2...6)
                        Button("补充到这项任务", systemImage: "arrow.turn.down.right") { command("input", fields: ["text": .string(supplement)]) }.disabled(supplement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controlling)
                        HStack {
                            Button("停止任务", role: .destructive) { command("cancel") }.disabled(controlling || ["cancelled", "failed"].contains(current["status"].string))
                            Spacer()
                            if ["paused", "unknown", "cancelled", "failed"].contains(current["status"].string) { Button("恢复") { command("resume") }.disabled(controlling) }
                        }
                    }
                }
                if current["status"].string == "execution_finished" && !current["acceptance_passed"].bool {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("核对完成条件").font(.headline)
                            ForEach(current["acceptance_criteria"].array.map(RemoteRow.init)) { criterion in
                                Toggle(criterion.value["text"].string.isEmpty ? criterion.value["description"].string : criterion.value["text"].string,
                                       isOn: Binding(get: { checked.contains(criterion.id) }, set: { if $0 { checked.insert(criterion.id) } else { checked.remove(criterion.id) } }))
                            }
                            TextField("填写你实际检查的结果或证据位置", text: $evidence, axis: .vertical).lineLimit(2...6)
                            Button("确认验收通过", systemImage: "checkmark.seal") {
                                let criteria = current["acceptance_criteria"].array
                                let refs: [JSON] = criteria.isEmpty ? [.object(["reference": .string(evidence), "passed": .bool(true)])] : criteria.map { .object(["criterion_id": .string($0.id), "reference": .string(evidence), "passed": .bool(true)]) }
                                command("verify", fields: ["explicit_acceptance": .bool(true), "evidence": .array(refs)])
                            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                .disabled(evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checked.count != current["acceptance_criteria"].array.count || controlling)
                        }
                    }
                }
                if !current["workspace_copy"].isNull {
                    Button("合入这次成果") { command("merge") }.disabled(current["verification_status"].string != "passed" || controlling)
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
                    }
                }
            }.navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .refreshable { await model.refresh(.tasks) }
        }
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
