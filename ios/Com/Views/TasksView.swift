import SwiftUI
import ComCore

struct TaskSummary: View {
    enum Style { case card, row }
    let task: JSON
    var style: Style = .card
    private var passed: Bool { task["acceptance_passed"].bool }
    private var attention: Bool {
        !passed && ["waiting", "failed", "execution_finished", "unknown", "paused"].contains(task["status"].string)
    }
    private var tone: Tone { passed ? .success : attention ? (task["status"].string == "failed" ? .danger : .warning) : statusTone(task["status"].string) }
    var body: some View {
        let category = TaskCategory(task)
        let row = ListRow(symbol: category.symbol, tone: category.tone,
                          title: task["title"].string, titleLines: 3,
                          status: passed ? "验收通过" : displayStatus(task["status"].string), statusTone: attention || passed ? tone : .neutral,
                          subtitle: task["completion_condition"].string, subtitleLines: 2, meta: category.label)
        switch style {
        case .row: row
        case .card: row.background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous)).elevation(.raised)
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
    private var proposals: [JSON] {
        let data = model.datasets["/personal/work/proposals?limit=20"]?["items"].array ?? model.datasets["/personal/work/proposals?limit=20"]?["proposals"].array ?? []
        return data.filter { ["proposed", "pending", "approval_required"].contains($0["status"].string) }
    }
    var body: some View {
        ScreenScaffold(title: "任务", freshness: timed ? "/personal/automations" : "/personal/tasks") {
            Picker("任务或定时工作", selection: $timed) { Text("任务").tag(false); Text("定时").tag(true) }.pickerStyle(.segmented)
            if timed {
                let jobs = model.datasets["/personal/automations"]?["jobs"].array ?? []
                if jobs.isEmpty { EmptyState(title: "当前没有读取到定时工作", description: "已安排的工作由 Mac mini 执行。", symbol: "clock") }
                VStack(spacing: Space.md) {
                    ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in TimedJobCard(job: job) }
                }
            } else {
                // Decisions first: proposals waiting for approval are the screen's focus.
                if !proposals.isEmpty {
                    VStack(spacing: Space.md) {
                        ForEach(proposals.map(RemoteRow.init)) { row in ProposalCard(proposal: row.value) }
                    }
                }
                VStack(alignment: .leading, spacing: Space.lg) {
                    FilterChips(options: ["全部", "待决定", "执行中", "待验收", "已完成", "已结束"], selection: $filter, animation: .smooth(duration: 0.2))
                    if filtered.isEmpty {
                        EmptyState(title: "这一栏暂时是空的", description: "从聊天交办一件事，进度就会出现在这里。", symbol: "tray")
                    } else {
                        GroupedCard(dividerInset: Layout.rowInset) {
                            ForEach(filtered.map(RemoteRow.init)) { row in
                                Button { model.selectedTask = row.value } label: { TaskSummary(task: row.value, style: .row) }.buttonStyle(.row).detailSource("task-" + row.id)
                            }
                        }
                    }
                }
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
        Card(.highlighted(.warning)) {
            VStack(alignment: .leading, spacing: Space.md) {
                StatusPill(text: "待你批准", tone: .warning)
                Text(proposal["title"].string).font(TypeScale.headline)
                Text(prompt).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(expanded ? nil : 2)
                if prompt.count > 60 {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.quiet)
                }
                HStack(spacing: Space.md) {
                    Button("批准这项工作") { Task { await model.action("/personal/work/proposals/" + proposal.id.pathEncoded + "/approve", fields: ["explicit_authorization": .bool(true)], refresh: .tasks) } }.buttonStyle(.primaryAction)
                    Button("拒绝") { Task { await model.action("/personal/work/proposals/" + proposal.id.pathEncoded + "/reject", refresh: .tasks) } }.buttonStyle(.secondaryAction)
                }.padding(.top, Space.xs)
            }
        }
    }
}

struct TimedJobCard: View {
    let job: JSON
    @State private var expanded = false
    var body: some View {
        let prompt = job["prompt"].string
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    IconBadge(symbol: TaskCategory(job).symbol, tone: TaskCategory(job).tone)
                    Text(job["name"].string.isEmpty ? job["title"].string : job["name"].string).font(TypeScale.headline)
                }
                Text(prompt).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(expanded ? nil : 2)
                if prompt.count > 60 {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.quiet)
                }
                HStack {
                    StatusPill(text: job["enabled"].bool || job["status"].string == "active" ? "已启用" : displayStatus(job["status"].string.isEmpty ? "待核实" : job["status"].string), tone: .info)
                    Spacer()
                    if !job["next_run"].string.isEmpty { Label(calendarTime(job["next_run"]), systemImage: "clock").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary) }
                }
                let schedule = job["schedule"].string.isEmpty ? job["cron"].string : job["schedule"].string
                if !schedule.isEmpty { Label(schedule, systemImage: "repeat").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary) }
                RawDetails(title: "安排与运行记录", value: job)
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
            DetailHeader(title: current["title"].string, subtitle: current["completion_condition"].string) {
                StatusPill(text: current["acceptance_passed"].bool ? "验收通过" : displayStatus(current["status"].string),
                           tone: current["acceptance_passed"].bool ? .success : statusTone(current["status"].string))
                Spacer()
                Text(agentName(current["agent"].string)).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
            // Decision zone
            if pendingAcceptance {
                Card(.highlighted(.accent)) {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("核对完成条件").font(TypeScale.headline)
                        ForEach(current["acceptance_criteria"].array.map(RemoteRow.init)) { criterion in
                            Toggle(criterion.value["text"].string.isEmpty ? criterion.value["description"].string : criterion.value["text"].string,
                                   isOn: Binding(get: { checked.contains(criterion.id) }, set: { if $0 { checked.insert(criterion.id) } else { checked.remove(criterion.id) } }))
                                .font(TypeScale.callout).tint(Palette.accentText)
                        }
                        TextField("填写你实际检查的结果或证据位置", text: $evidence, axis: .vertical).lineLimit(2...6).insetField()
                        Button {
                            let criteria = current["acceptance_criteria"].array
                            let refs: [JSON] = criteria.isEmpty ? [.object(["reference": .string(evidence), "passed": .bool(true)])] : criteria.map { .object(["criterion_id": .string($0.id), "reference": .string(evidence), "passed": .bool(true)]) }
                            command("verify", fields: ["explicit_acceptance": .bool(true), "evidence": .array(refs)])
                        } label: { Label("确认验收通过", systemImage: "checkmark.seal") }
                            .buttonStyle(.primaryFull)
                            .disabled(evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checked.count != current["acceptance_criteria"].array.count || controlling)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextField("补充新的要求", text: $supplement, axis: .vertical).lineLimit(2...6).insetField()
                    Button { command("input", fields: ["text": .string(supplement)]) } label: { Label("补充到这项任务", systemImage: "arrow.turn.down.right") }
                        .buttonStyle(.secondaryAction)
                        .disabled(supplement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controlling)
                    Rectangle().fill(Palette.separator).frame(height: 0.5)
                    HStack(spacing: Space.lg) {
                        Button("停止任务", role: .destructive) { command("cancel") }
                            .buttonStyle(.quiet)
                            .disabled(controlling || ["cancelled", "failed"].contains(current["status"].string))
                        Spacer()
                        if !current["workspace_copy"].isNull {
                            Button("合入这次成果") { command("merge") }.buttonStyle(.quiet).disabled(current["verification_status"].string != "passed" || controlling)
                        }
                        if ["paused", "unknown", "cancelled", "failed"].contains(current["status"].string) {
                            Button("恢复") { command("resume") }.buttonStyle(.quiet).disabled(controlling)
                        }
                    }
                }
            }
            // Evidence zone
            if !artifacts.isEmpty {
                GroupSection("成果") { ArtifactList(artifacts: artifacts) }
            }
            if !current["events"].array.isEmpty {
                GroupSection("真实步骤") {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(visibleEvents.enumerated()), id: \.offset) { index, event in
                                HStack(alignment: .top, spacing: Space.md) {
                                    Circle().fill(index == visibleEvents.count - 1 ? Palette.accentText : Palette.textTertiary).frame(width: 8, height: 8).padding(.top, 6)
                                    VStack(alignment: .leading, spacing: Space.xxs) {
                                        Text(eventLabel(event)).font(TypeScale.callout)
                                        if event["at"].double > 0 { Text(Date(timeIntervalSince1970: event["at"].double).formatted(date: .omitted, time: .shortened)).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, Space.md)
                                }
                                .background(alignment: .topLeading) {
                                    if index < visibleEvents.count - 1 { Rectangle().fill(Palette.separator).frame(width: 1).padding(.top, 18).padding(.leading, 3.5) }
                                }
                            }
                            if current["events"].array.count > 3 {
                                Button(showAllEvents ? "收起" : "展开全部 \(current["events"].array.count) 条") { showAllEvents.toggle() }.buttonStyle(.quiet)
                            }
                        }
                    }
                }
            }
            // Disclosure zone
            GroupedCard {
                if !current["result"].string.isEmpty {
                    DisclosureGroup("执行结果") { RichText(text: current["result"].string).padding(.top, Space.sm) }
                        .font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                }
                if !current["structured_result"].isNull { RawDetails(title: "结果与检查记录", value: current["structured_result"]).rowPadding() }
                RawDetails(title: "来源与约束", value: .object(["prompt": current["prompt"], "constraints": current["constraints"], "work_brief": current["work_brief"]])).rowPadding()
            }
            if !current["origin_message_id"].string.isEmpty {
                Button {
                    let id = current["origin_message_id"].string, session = current["source_session_id"].string
                    dismiss()
                    Task {
                        if !session.isEmpty && session != "personal-main" { model.workJumpMessage = current["source_message_id"].string; model.selectedSession = .object(["id": .string(session), "agent": current["agent"]]) }
                        else { await model.locateMessage(id) }
                    }
                } label: { Label("回到原交办消息", systemImage: "bubble.left") }
                    .buttonStyle(.quiet).frame(maxWidth: .infinity)
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


/// Presentation categories inferred from declared kind and task title. They never change execution routing.
struct TaskCategory {
    let label: String
    let symbol: String
    let tone: Tone
    init(_ task: JSON) {
        let text = [task["category"].string, task["kind"].string, task["title"].string, task["name"].string].joined(separator: " ").lowercased()
        let rules: [(String, String, Tone, [String])] = [
            ("财务", "creditcard", .success, ["记账", "账本", "报销", "付款", "收款", "财务", "bookkeep", "finance"]),
            ("开发", "desktopcomputer", .info, ["代码", "编程", "修复", "github", "部署", "开发", "code", "bug", "app", "ui"]),
            ("健康", "heart.fill", .danger, ["健康", "身体", "睡眠", "心率", "health"]),
            ("运动", "figure.run", .success, ["跑步", "攀岩", "训练", "健身", "运动", "workout"]),
            ("日程", "calendar", .warning, ["日程", "会议", "预约", "日历", "calendar"]),
            ("出行", "airplane", .info, ["机票", "航班", "酒店", "旅行", "出差", "flight"]),
            ("购物", "bag", .accent, ["比价", "购物", "购买", "尺码", "衣服", "羽绒", "价格"]),
            ("创作", "film", .warning, ["视频", "拍摄", "剪辑", "素材", "内容", "口播", "创作"]),
            ("设计", "paintpalette", .danger, ["设计", "视觉", "品牌", "海报", "ppt", "kv"]),
            ("沟通", "envelope", .info, ["邮件", "邮箱", "回复", "联系", "email"]),
            ("研究", "magnifyingglass", .accent, ["调研", "研究", "检索", "查找", "论文", "分析"]),
            ("事务", "doc.text", .neutral, ["合同", "保险", "报案", "材料", "申请", "办理"]),
            ("提醒", "bell", .warning, ["提醒", "定时", "巡检", "monitor"])
        ]
        if let rule = rules.first(where: { rule in rule.3.contains { text.contains($0) } }) {
            label = rule.0; symbol = rule.1; tone = rule.2
        } else { label = "待办"; symbol = "checklist"; tone = .neutral }
    }
}
