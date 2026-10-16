import SwiftUI
import ComCore

struct TaskSummary: View {
    enum Style { case card, row }
    let task: JSON
    var style: Style = .card
    private var passed: Bool { task["acceptance_passed"].bool }
    var body: some View {
        let category = TaskCategory(task)
        let row = ListRow(symbol: category.symbol, tone: category.tone,
                          title: task["title"].string, titleLines: 3,
                          status: stampLabel(task["status"].string, accepted: passed), statusTone: stampTone(task["status"].string, accepted: passed),
                          subtitle: task["completion_condition"].string, subtitleLines: 2, meta: [hostName(task["host"].string), agentName(task["agent"].string), category.label].filter { !$0.isEmpty }.joined(separator: " · "))
        switch style {
        case .row: row
        case .card: row.noteSurface()
        }
    }
}

/// 任务与目标（从「今天」页底部进来的二级页）：等我决定 / 正在跑 / 目标 / 已结束 / 定时。
/// 每一行都对应真实的后端状态；这里是「等你决定」唯一的完整清单，今天页的时间线只摘其中要你拍板的。
struct TaskHubView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var filter = "全部"
    @State private var addingGoal = false
    @State private var showGoals = false
    @State private var showStale = false
    @State private var busy = false
    @State private var result = ""
    private var finished: [JSON] { model.tasks.filter { $0["acceptance_passed"].bool || ["failed", "cancelled", "rejected", "expired", "completed"].contains($0["status"].string) }.sorted { $0["updated_at"].double > $1["updated_at"].double } }
    private var decisions: [PendingItem] { model.pendingItems.filter { !$0.stale } }
    private var stale: [PendingItem] { model.staleItems }
    var body: some View {
        @Bindable var model = model
        ScrollPage(spacing: Layout.sectionSpacing) {
            FilterChips(options: ["全部", "等我决定", "正在跑", "目标", "已结束", "定时"], selection: $filter, animation: .smooth(duration: 0.2))
            if filter == "全部" || filter == "等我决定" {
                GroupSection("等我决定 · \(decisions.count)", footer: decisions.isEmpty ? "" : "左划归档或划掉，右划直接做，长按和它聊。") {
                    if decisions.isEmpty && stale.isEmpty { EmptyState(title: "眼下没有要你拍板的事", description: "派活待批准、停下来等你回应或验收的任务会排在这里；邮件和日程的建议在「下一步」。", symbol: "checkmark.circle") }
                    ForEach(decisions) { item in
                        PendingNote(item: item) { result = $0 }
                            .transition(reduce ? .opacity : .asymmetric(insertion: .offset(y: -12).combined(with: .opacity), removal: .scale(scale: 0.96, anchor: .top).combined(with: .opacity)))
                    }
                    if !stale.isEmpty { staleBlock }
                    if !result.isEmpty { Label(result, systemImage: "checkmark.circle").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).accessibilityIdentifier("agency-action-result") }
                } trailing: {
                    if decisions.contains(where: \.canDismiss) {
                        Button("全部稍后") { Task { await dismissAll() } }.buttonStyle(.quiet).disabled(busy)
                    }
                }
                .animation(reduce ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: decisions.map(\.id))
            }
            if filter == "全部" || filter == "正在跑" {
                GroupSection("正在跑 · \(model.runningTasks.count)") {
                    if model.runningTasks.isEmpty && model.activeRuns.isEmpty { Text("没有在跑的任务。").font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).padding(.horizontal, Space.xs) }
                    else {
                        GroupedCard(dividerInset: 0) {
                            ForEach(model.activeRuns.map(RemoteRow.init)) { row in
                                RunningRow(title: "主对话 · " + (row.value["phase"].string == "executing" ? "正在执行工具" : "正在思考"), subtitle: "Mac mini · Hermes", status: "执行中", since: row.value["created_at"].double)
                            }
                            ForEach(model.runningTasks.map(RemoteRow.init)) { row in
                                Button { model.selectedTask = row.value } label: {
                                    RunningRow(title: row.value["title"].string, subtitle: [hostName(row.value["host"].string).isEmpty ? "Mac mini" : hostName(row.value["host"].string), agentName(row.value["agent"].string), lastStep(row.value)].filter { !$0.isEmpty }.joined(separator: " · "), status: stampLabel(row.value["status"].string), since: row.value["created_at"].double)
                                }.buttonStyle(.row).detailSource("task-" + row.id)
                            }
                        }
                    }
                }
            }
            if filter == "全部" || filter == "目标" {
                GroupSection("目标") {
                    if model.goals.isEmpty {
                        Button { addingGoal = true } label: {
                            HStack(spacing: Space.md) {
                                IconBadge(symbol: "scope", tone: .accent)
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Text("把一件在意的事交给我记挂").font(TypeScale.rowTitle)
                                    Text("设定结果、下一步，持续跟进。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer(); Image(systemName: "plus")
                            }.rowPadding()
                        }.buttonStyle(.row).noteSurface()
                    } else {
                        GroupedCard(dividerInset: 0) {
                            ForEach(model.goals.prefix(3).map(RemoteRow.init)) { row in
                                Button { showGoals = true } label: {
                                    VStack(alignment: .leading, spacing: Space.xs) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(row.value["title"].string).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                                            Spacer(minLength: Space.sm)
                                            Text(row.value["status"].string == "blocked" ? "卡住了" : row.value["next_step"].string.isEmpty ? "持续跟进" : "下一步 · " + row.value["next_step"].string).font(TypeScale.footnote).foregroundStyle(row.value["status"].string == "blocked" ? Palette.warning : Palette.textTertiary).lineLimit(1)
                                        }
                                        if !row.value["completion_condition"].string.isEmpty { Text(row.value["completion_condition"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1) }
                                    }.padding(.horizontal, Space.lg).padding(.vertical, Space.md + 1)
                                }.buttonStyle(.row)
                            }
                        }
                    }
                } trailing: { Button("管理") { showGoals = true }.buttonStyle(.quiet) }
            }
            if filter == "已结束" {
                GroupSection("已结束", footer: "归档或取消的任务也在这里，打开后可以恢复。") {
                    if finished.isEmpty { Text("还没有结束的任务。").font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).padding(.horizontal, Space.xs) }
                    else {
                        GroupedCard(dividerInset: Layout.rowInset) {
                            ForEach(finished.prefix(40).map(RemoteRow.init)) { row in
                                Button { model.selectedTask = row.value } label: { TaskSummary(task: row.value, style: .row) }.buttonStyle(.row).detailSource("task-" + row.id)
                            }
                        }
                    }
                }
            }
            if filter == "定时" {
                GroupSection("定时") {
                    NavigationLink { AgencySettings() } label: { ListRow(symbol: "sun.max", title: "晨报与主动安排", subtitle: "调整晨晚报、每周复盘和提醒强度") }.buttonStyle(.row).noteSurface()
                    let jobs = model.datasets["/personal/automations"]?["jobs"].array ?? []
                    if jobs.isEmpty { Text("当前没有读取到定时工作。").font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).padding(.horizontal, Space.xs) }
                    ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in TimedJobCard(job: job) }
                }
            }
        }.refreshable { await model.refresh(.doing) }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: ComDock.height) }
        .navigationTitle("任务与目标").navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .sheet(isPresented: $addingGoal) { GoalEditor() }
        .sheet(isPresented: $showGoals) { GoalList() }
    }
    /// 超过一周没动静的任务折成一行：多半已经不作数，一键归档；想看也能展开。
    private var staleBlock: some View {
        Card(.inset) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    IconBadge(symbol: "archivebox", tone: .neutral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(stale.count) 件超过一周的旧任务").font(TypeScale.rowTitle)
                        Text(stale.prefix(2).map(\.title).joined(separator: "、") + (stale.count > 2 ? "…" : "")).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: Space.sm) {
                    Button(busy ? "归档中…" : "全部归档") { busy = true; Task { await model.archiveStale(); result = "旧任务已归档，在「已结束」里还能恢复"; busy = false } }.buttonStyle(.primaryCompact).disabled(busy).accessibilityIdentifier("archive-stale")
                    Button(showStale ? "收起" : "逐条看") { withAnimation(.smooth(duration: 0.2)) { showStale.toggle() } }.buttonStyle(.secondaryCompact)
                }
                if showStale {
                    ForEach(stale) { item in PendingNote(item: item) { result = $0 } }
                }
            }
        }
    }
    private func dismissAll() async {
        busy = true; defer { busy = false }
        for item in decisions where item.canDismiss { await model.pendingDismiss(item) }
        result = "都留到明天再提"
    }
    private func lastStep(_ task: JSON) -> String {
        guard let last = task["events"].array.last else { return "" }
        let text = eventLabel(last)
        return text == "正在处理，请稍候" ? "" : text
    }
}

/// 正在跑的一行：标题 · 已跑多久；哪台机器、哪个伙伴、到了哪一步。
private struct RunningRow: View {
    let title: String
    let subtitle: String
    let status: String
    let since: Double
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(title).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary).lineLimit(2)
                Spacer(minLength: Space.sm)
                if since > 0 { Text(elapsed(since)).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) } else { Stamp(text: status, angle: 2) }
            }
            Text(subtitle).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).lineLimit(1)
            RunningTicks()
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md + 1)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }
    private func elapsed(_ start: Double) -> String {
        let minutes = Int(max(0, Date().timeIntervalSince1970 - start) / 60)
        return minutes < 1 ? "刚开始" : minutes < 60 ? "已跑 \(minutes) 分钟" : "已跑 \(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

/// 没有真实分母就不画进度，只画一条在走的虚线。
private struct RunningTicks: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduce)) { timeline in
            let phase = reduce ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            Path { $0.move(to: CGPoint(x: 0, y: 3)); $0.addLine(to: CGPoint(x: 4000, y: 3)) }
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [6, 5], dashPhase: CGFloat(-phase * 11)))
                .frame(height: 6).clipped()
        }.frame(height: 6).padding(.top, 2).accessibilityHidden(true)
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
                Text(prompt).font(TypeScale.body).foregroundStyle(Palette.textSecondary).lineLimit(expanded ? nil : 2)
                if prompt.count > 60 {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.quiet)
                }
                HStack {
                    Stamp(text: job["enabled"].bool || job["status"].string == "active" ? "已启用" : stampLabel(job["status"].string.isEmpty ? "unknown" : job["status"].string), angle: 2)
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

/// 任务详情：状态头部 → 我要做的决定 → 步骤时间线 → 成果与证据。
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
        return showAllEvents ? events : Array(events.suffix(5))
    }
    var body: some View {
        DetailPage(title: "任务") {
            let status = current["status"].string, passed = current["acceptance_passed"].bool
            DetailHeader(title: current["title"].string,
                         subtitle: [hostName(current["host"].string).isEmpty ? "Mac mini" : hostName(current["host"].string), agentName(current["agent"].string), current["created_at"].double > 0 ? clockTime(current["created_at"].double) + " 开始" : "", runtime(current)].filter { !$0.isEmpty }.joined(separator: " · ")) {
                Stamp(text: stampLabel(status, accepted: passed), tone: stampTone(status, accepted: passed), dashed: status == "unknown", angle: -3)
                if pendingAcceptance { Stamp(text: "等你验收", tone: .warning, angle: 2) }
            }
            // 要你决定
            if pendingAcceptance {
                Card(.highlighted(.accent), padding: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("要你决定").font(TypeScale.section).foregroundStyle(Palette.accentText)
                        Text("核对完成条件，确认这次结果能不能收").font(TypeScale.title)
                        ForEach(current["acceptance_criteria"].array.map(RemoteRow.init)) { criterion in
                            Toggle(criterion.value["text"].string.isEmpty ? criterion.value["description"].string : criterion.value["text"].string,
                                   isOn: Binding(get: { checked.contains(criterion.id) }, set: { if $0 { checked.insert(criterion.id) } else { checked.remove(criterion.id) } }))
                                .font(TypeScale.body).tint(Palette.accentText)
                        }
                        TextField("填写你实际检查的结果或证据位置", text: $evidence, axis: .vertical).lineLimit(2...6).insetField()
                        HStack(spacing: Space.sm) {
                            Button {
                                let criteria = current["acceptance_criteria"].array
                                let refs: [JSON] = criteria.isEmpty ? [.object(["reference": .string(evidence), "passed": .bool(true)])] : criteria.map { .object(["criterion_id": .string($0.id), "reference": .string(evidence), "passed": .bool(true)]) }
                                command("verify", fields: ["explicit_acceptance": .bool(true), "evidence": .array(refs)])
                            } label: { Text("确认验收通过") }
                                .buttonStyle(.primaryAccent)
                                .disabled(evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checked.count != current["acceptance_criteria"].array.count || controlling)
                            if !current["workspace_copy"].isNull {
                                Button("合入成果") { command("merge") }.buttonStyle(.secondaryAction).disabled(current["verification_status"].string != "passed" || controlling)
                            }
                        }
                    }
                }.padding(.top, Space.sm)
            }
            if !current["events"].array.isEmpty {
                GroupSection("步骤") {
                    Card(padding: Space.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(visibleEvents.enumerated()), id: \.offset) { index, event in
                                let last = index == visibleEvents.count - 1
                                StepRow(text: eventLabel(event), state: !last ? .done : ["completed", "cancelled", "failed"].contains(status) || passed ? (status == "failed" ? .blocked : .done) : stepState(event), time: clockTime(event["at"].double))
                            }
                            if pendingAcceptance { StepRow(text: "等你验收后收尾", state: .blocked) }
                            else if ["queued", "running", "dispatching"].contains(status) { StepRow(text: "跑完后等你验收", state: .pending) }
                            if current["events"].array.count > 5 {
                                Button(showAllEvents ? "收起" : "展开全部 \(current["events"].array.count) 步") { showAllEvents.toggle() }.buttonStyle(.quiet).padding(.top, Space.sm)
                            }
                        }.padding(.horizontal, Space.xs)
                    }
                }
            }
            if !artifacts.isEmpty || !current["result"].string.isEmpty {
                GroupSection("成果与证据") {
                    if !artifacts.isEmpty { ArtifactList(artifacts: artifacts) }
                    if !current["result"].string.isEmpty {
                        Card { RichText(text: current["result"].string) }
                    }
                }
            }
            GroupSection("补充要求") {
                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        TextField("补充新的要求", text: $supplement, axis: .vertical).lineLimit(2...6).insetField()
                        HStack(spacing: Space.lg) {
                            Button("补充到这项任务") { command("input", fields: ["text": .string(supplement)]) }
                                .buttonStyle(.secondaryAction)
                                .disabled(supplement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controlling)
                            Spacer()
                            if ["paused", "unknown", "cancelled", "failed"].contains(status) {
                                Button("恢复") { command("resume") }.buttonStyle(.quiet).disabled(controlling)
                            } else if !["completed", "execution_finished"].contains(status) {
                                Button("停止", role: .destructive) { command("cancel") }.buttonStyle(.quiet).disabled(controlling)
                            }
                        }
                    }
                }
            }
            GroupedCard {
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
                } label: { Text("回到原交办消息") }
                    .buttonStyle(.quiet).frame(maxWidth: .infinity)
            }
        }
        .refreshable { await model.refresh(.doing) }
    }
    private func runtime(_ task: JSON) -> String {
        guard task["created_at"].double > 0, ["queued", "running", "dispatching", "waiting"].contains(task["status"].string) else { return "" }
        let minutes = Int(max(0, Date().timeIntervalSince1970 - task["created_at"].double) / 60)
        return minutes < 1 ? "刚开始" : "已跑 \(minutes) 分钟"
    }
    private func command(_ action: String, fields: [String: JSON] = [:]) {
        controlling = true
        Task {
            defer { controlling = false }
            do { _ = try await model.mutate("/personal/tasks/" + task.id.pathEncoded + "/" + action, fields: fields); await model.refresh(.doing); if action == "input" { supplement = "" } }
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
            ("财务", "creditcard", .neutral, ["记账", "账本", "报销", "付款", "收款", "财务", "bookkeep", "finance"]),
            ("开发", "desktopcomputer", .neutral, ["代码", "编程", "修复", "github", "部署", "开发", "code", "bug", "app", "ui"]),
            ("健康", "heart", .neutral, ["健康", "身体", "睡眠", "心率", "health"]),
            ("运动", "figure.run", .neutral, ["跑步", "攀岩", "训练", "健身", "运动", "workout"]),
            ("日程", "calendar", .neutral, ["日程", "会议", "预约", "日历", "calendar"]),
            ("出行", "airplane", .neutral, ["机票", "航班", "酒店", "旅行", "出差", "flight"]),
            ("购物", "bag", .neutral, ["比价", "购物", "购买", "尺码", "衣服", "羽绒", "价格"]),
            ("创作", "film", .neutral, ["视频", "拍摄", "剪辑", "素材", "内容", "口播", "创作"]),
            ("设计", "paintpalette", .neutral, ["设计", "视觉", "品牌", "海报", "ppt", "kv"]),
            ("沟通", "envelope", .neutral, ["邮件", "邮箱", "回复", "联系", "email"]),
            ("研究", "magnifyingglass", .neutral, ["调研", "研究", "检索", "查找", "论文", "分析"]),
            ("事务", "doc.text", .neutral, ["合同", "保险", "报案", "材料", "申请", "办理"]),
            ("提醒", "bell", .neutral, ["提醒", "定时", "巡检", "monitor"])
        ]
        if let rule = rules.first(where: { rule in rule.3.contains { text.contains($0) } }) {
            label = rule.0; symbol = rule.1; tone = rule.2
        } else { label = "待办"; symbol = "checklist"; tone = .neutral }
    }
}
