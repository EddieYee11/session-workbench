import SwiftUI
import ComCore

// r3-work：工作页的原地聊天（ChatGPT / Claude App 式）。右边是 Eddie（和主聊天同款深色气泡），
// 左边是 Agent：真实 logo + 品牌色名字，正文用 ReplyText 排 Markdown；工具步骤折成一行「做了 N 步」，点开看每一步。
// 原 WorkDetailView 的能力都留在这一页：状态（头部 + 顶栏标题菜单）、审批卡（流里）、停止（输入框右边 / 标题菜单）、
// 置顶与结束（标题菜单）、模型和推理强度（输入框「+」）、恢复输入（输入框位置）、从任务跳到某条消息（workJumpMessage）。

struct WorkChat: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 正从输入框飞上来的气泡：真气泡先藏着、只报位置，落地后再露出来。
    var flying: Set<String> = []
    @State private var position = ScrollPosition(idType: String.self)
    @State private var nearBottom = true
    private var work: WorkSessionModel { model.work }
    var body: some View {
        let rows = work.rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xl) {
                WorkChatHeader()
                if let line = usageLine {
                    Text(line).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                        .accessibilityIdentifier("work-usage")
                }
                // 10-18 会话↔航程互通：这段是某段航程的执行会话，一键回到航程看步骤和结论
                if let owner = (model.datasets["/sessions"]?["sessions"].array ?? []).first(where: { $0.id == work.sessionID }), !owner["case_id"].string.isEmpty {
                    Button { model.openThreadNode(.object(["kind": .string("case"), "id": owner["case_id"]])) } label: {
                        Label("航程「" + owner["case_title"].string + "」的执行会话 · 看航程", systemImage: "rectangle.stack")
                            .font(TypeScale.footnote.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Palette.surface, in: .capsule)
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accentText)
                    .accessibilityIdentifier("work-case-banner")
                }
                // 侧栏点开后拉齐失败：危险开口，勿用中性灰字假装「历史缓存」。
                if !work.note.isEmpty {
                    InlineNotice(text: work.note, tone: .danger)
                        .accessibilityIdentifier("work-chat-fail")
                } else if !work.loaded && (work.mode == .session || work.mode == .snapshot) {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text(work.mode == .snapshot ? "正在拉齐摘录…" : "正在打开会话…")
                            .font(TypeScale.footnote)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .accessibilityIdentifier("work-chat-opening")
                    .accessibilityLabel(work.mode == .snapshot ? "正在拉齐摘录" : "正在打开会话")
                }
                if rows.isEmpty && work.loaded && work.note.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(work.mode == .snapshot
                             ? "这段还没有可看的摘录"
                             : "会话开着，还没开口")
                            .font(TypeScale.subheadline.weight(.medium))
                            .foregroundStyle(Palette.textSecondary)
                        Text(work.mode == .snapshot
                             ? "同步过来的摘要到了会出现在这里；急用可到那台机器上看完整记录。"
                             : "下面说一句就行。我在听——不会假装远程终端已接通。")
                            .font(TypeScale.footnote)
                            .foregroundStyle(Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Space.sm)
                    .accessibilityIdentifier("work-chat-empty")
                }
                ForEach(rows) { row in
                    WorkRow(row: row, agent: work.agent, flying: flying.contains(row.id))
                        .id(row.id)
                        .transition(reduce ? .opacity : .opacity.combined(with: .offset(y: 8)))
                }
                if let line = liveLine(rows) {
                    HStack(spacing: Space.sm) {
                        WorkPulse()
                        Text(line).font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textSecondary).contentTransition(.opacity)
                    }
                    .padding(.horizontal, Space.xs)
                    .transition(.opacity)
                    .accessibilityIdentifier("work-live-line")
                }
                ForEach(work.approvals.map(RemoteRow.init)) { row in
                    WorkApprovalCard(approval: row.value) { await work.refresh(model) }
                }
                Color.clear.frame(height: 1).id("work-bottom")
            }
            .padding(.horizontal, Layout.margin).padding(.top, Space.md).padding(.bottom, Space.lg)
            .animation(reduce ? nil : .smooth(duration: 0.3), value: rows.map(\.id))
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { g in g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY < 90 } action: { _, near in nearBottom = near }
        // 新的一行、流式回复变长：人在底部就跟着走；往上翻着看时不打扰。
        .onChange(of: rows.last.map { $0.id + ":\(textContent($0.message["text"]).count):\($0.steps.count)" }) { _, _ in
            guard nearBottom else { return }
            Task { @MainActor in await Task.yield(); withAnimation(reduce ? nil : .smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) } }
        }
        .onChange(of: rows.map(\.id), initial: true) { _, _ in
            guard let target = model.workJumpMessage, let row = rows.first(where: { $0.message.id == target || $0.steps.contains { $0.id == target } }) else { return }
            model.workJumpMessage = nil
            Task { @MainActor in await Task.yield(); withAnimation(reduce ? nil : .smooth(duration: 0.25)) { position.scrollTo(id: row.id, anchor: .center) } }
        }
        .refreshable { await work.refresh(model) }
        .accessibilityIdentifier("work-chat")
    }
    /// 最近一轮的用量：只在服务端真的上报时显示，不显示猜测值。
    private var usageLine: String? {
        let u = work.usage
        guard !u.isNull else { return nil }
        var parts: [String] = []
        let used = u["context_used"].int, max = u["context_max"].int
        if used > 0 && max > 0 {
            parts.append("上下文 \(Int(Double(used) / Double(max) * 100))%")
        }
        let total = u["total"].int, input = u["input"].int, output = u["output"].int
        if total > 0 {
            parts.append("本轮 \(total) tok")
        } else if input > 0 || output > 0 {
            parts.append("入 \(input) / 出 \(output)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// 在跑但还没有步骤行在动：说一句它在干嘛（派出中 / 在想 / 在写回复）。
    private func liveLine(_ rows: [WorkSessionModel.Row]) -> String? {
        guard work.mode == .session, work.running else { return nil }
        if work.starting { return "正在派给 " + agentName(work.agent) + "…" }
        guard let last = rows.last, !(last.kind == .steps && last.live) else { return nil }
        return last.kind == .reply ? "在写回复" : "在想怎么办"
    }
}

/// 顶上一块：这段对话是什么、谁在做、现在什么状态、在哪个目录。只读快照再加一张「会话中的依据」。
private struct WorkChatHeader: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let work = model.work
        VStack(alignment: .leading, spacing: Space.sm) {
            // 标题就是第一句话时（首页刚发出去的那种）不重复写一遍，只留下面那行状态。
            if !work.title.isEmpty, !(work.rows.first { $0.kind == .user }.map { textContent($0.message["text"]).hasPrefix(work.title) } ?? false) {
                Text(work.title).font(TypeScale.title).lineLimit(2)
                    .accessibilityIdentifier("work-chat-title")
            }
            HStack(spacing: Space.sm) {
                HStack(spacing: 5) {
                    AgentMark(agent: work.agent).frame(width: 13, height: 13)
                    Text(agentName(work.agent)).font(TypeScale.caption).foregroundStyle(agentTint(work.agent))
                }
                .padding(.horizontal, Space.sm + 2).padding(.vertical, Space.xs + 1)
                .background(agentBrand(work.agent)?.wash ?? Palette.fill, in: .capsule)
                if work.mode == .snapshot {
                    Stamp(text: projectStatus(work.snapshot["status"].string))
                    Label("摘录", systemImage: "doc.text").font(.caption).foregroundStyle(Palette.textTertiary)
                } else {
                    Stamp(text: workStatusLabel(work.status), tone: stampTone(work.status), dashed: work.status == "unknown")
                        .contentTransition(.opacity)
                    if !work.folder.isEmpty { Label(work.folder, systemImage: "folder").font(.caption).foregroundStyle(Palette.textTertiary).lineLimit(1) }
                    if work.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Palette.textTertiary).accessibilityLabel("已置顶") }
                }
            }
            if work.mode == .snapshot, !work.snapshot["evidence_quote"].string.isEmpty {
                Card(.highlighted(.accent)) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("会话中的依据").font(TypeScale.headline).foregroundStyle(Palette.accentText)
                        LinedText(text: work.snapshot["evidence_quote"].string)
                        Text("是具体事项的会话报告，仍可能需要实际验收。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    }
                }.padding(.top, Space.xs)
            }
        }
        .padding(.bottom, Space.xs)
        .animation(.smooth(duration: 0.25), value: work.status)
    }
}

/// 一行：我的话 / 它的回复 / 折起来的工具步骤。
private struct WorkRow: View {
    let row: WorkSessionModel.Row
    let agent: String
    var flying = false
    var body: some View {
        switch row.kind {
        case .user: WorkUserBubble(row: row, flying: flying)
        case .reply: WorkReply(message: row.message, agent: agent, header: row.header)
        case .steps: WorkStepsRow(steps: row.steps, live: row.live, plan: row.plan, planLive: row.planLive, planTools: row.planTools)
        }
    }
}

/// 右边：我的话，和主聊天同款深色气泡。刚发的那条下面说一句送达情况。
private struct WorkUserBubble: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let row: WorkSessionModel.Row
    var flying = false
    var body: some View {
        let text = textContent(row.message["text"])
        VStack(alignment: .trailing, spacing: Space.xs) {
            if !row.message["reference"].isNull {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(row.message["reference"]["author"].string).font(TypeScale.footnote.weight(.semibold))
                    Text(row.message["reference"]["text"].string).font(TypeScale.footnote).lineLimit(3).foregroundStyle(Palette.textSecondary)
                }.padding(Space.md)
                    .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
            }
            Text(text).font(TypeScale.callout).textSelection(.enabled).userBubble()
                .chatFrame(row.id, enabled: flying).opacity(flying ? 0 : 1)
                .accessibilityIdentifier("work-bubble-" + row.id)
            if let outgoing = row.outgoing, outgoing.state != "accepted" {
                HStack(spacing: Space.sm) {
                    if outgoing.state == "sending" { ProgressView().controlSize(.mini) }
                    if outgoing.state == "elsewhere" {
                        Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(Palette.accentText)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                    Text(outgoing.state == "sending" ? "正在发送" : outgoing.note).font(TypeScale.footnote)
                        .foregroundStyle(outgoing.state == "rejected" ? Palette.danger : Palette.textSecondary)
                    if outgoing.state == "rejected" {
                        Button("回到草稿") { _ = model.work.restore(outgoing.requestID) }.buttonStyle(.quiet).font(TypeScale.footnote.weight(.semibold))
                    }
                }
                .contentTransition(.opacity)
                .animation(ComMotion.reduced(reduce, ComMotion.settle), value: outgoing.state)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .contextMenu { WorkMessageActions(text: text, message: row.message, author: "你") }
    }
}

/// 左边：Agent 的回复。这一轮第一条上面挂它的真实 logo 和品牌色名字，正文排 Markdown。
private struct WorkReply: View {
    let message: JSON
    let agent: String
    let header: Bool
    var body: some View {
        let text = textContent(message["text"])
        VStack(alignment: .leading, spacing: Space.sm) {
            if header {
                HStack(spacing: Space.sm) {
                    AgentAvatar(agent: agent, size: 26)
                    Text(agentName(agent)).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(agentTint(agent))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("work-reply-agent")
            }
            ReplyText(text: text, motionID: message.id, createdAt: message["time"].double)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work-reply-" + message.id)
        .contextMenu { WorkMessageActions(text: text, message: message, author: agentName(agent)) }
    }
}

/// 长按：复制 / 回复（引用这条继续说，原 WorkDetailView 里 MessageView 的能力）/ 分享。
private struct WorkMessageActions: View {
    @Environment(AppModel.self) private var model
    let text: String
    let message: JSON
    let author: String
    var body: some View {
        Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        if model.work.mode == .session, !model.work.sessionID.isEmpty, !message.id.isEmpty, !message.id.hasPrefix("request:") {
            Button("回复", systemImage: "arrowshape.turn.up.left") {
                model.reference = .object(["id": .string(message.id), "source_session_id": .string(model.work.sessionID), "mode": .string("reply"), "author": .string(author), "text": .string(String(text.prefix(2000)))])
            }
        }
        ShareLink(item: text) { Label("分享文字", systemImage: "square.and.arrow.up") }
    }
}

// MARK: - 工具步骤

/// 一串工具调用折成一行（参照 WorkProcess.swift 的「工作过程」）：在跑时一行实时说法 + 呼吸点；
/// 做完是「做了 N 步 · 用时 X」。点开看每一步：图标、说法、原始命令或路径。
private struct WorkStepsRow: View {
    let steps: [JSON]
    let live: Bool
    /// 10-28：Agent 这一轮记了 todo 清单 → 和主聊天一样画成时间轴，跑着时摊开、做完折起。
    var plan: TurnPlan? = nil
    var planLive = false
    var planTools: [WorkGroup] = []
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var open: Bool
    init(steps: [JSON], live: Bool, plan: TurnPlan? = nil, planLive: Bool = false, planTools: [WorkGroup] = []) {
        self.steps = steps
        self.live = live
        self.plan = plan
        self.planLive = planLive
        self.planTools = planTools
        _open = State(initialValue: planLive && plan != nil)
    }
    /// 工具的输出行跟着它的调用，不单独算一步。
    private var calls: [JSON] {
        let made = steps.filter { Self.tool($0) != "工具输出" }
        return made.isEmpty ? steps : made
    }
    static func tool(_ step: JSON) -> String {
        let title = step["title"].string.components(separatedBy: " · ").first ?? ""
        return title.isEmpty ? step["role"].string : title
    }
    static func kind(_ step: JSON) -> StepKind { StepKind.of(tool(step)) ?? .other }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.selection()
                withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { open.toggle() }
            } label: { header }
                .buttonStyle(.plain)
                .accessibilityIdentifier(live ? "work-steps-live" : "work-steps")
                .accessibilityHint(open ? "收起步骤" : "展开全部步骤")
            if open {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if let plan {
                        TodoTimeline(steps: plan.steps, groups: planTools, live: planLive)
                        Text("动用了 \(calls.count) 次工具").font(.caption2).foregroundStyle(Palette.textTertiary).padding(.leading, 26)
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                            line(group, running: live && index == groups.count - 1)
                        }
                    }
                }
                .padding(.leading, 6).padding(.top, Space.sm).padding(.bottom, Space.xs)
                .transition(.opacity.combined(with: .offset(y: -4)))
                .accessibilityIdentifier("work-steps-list")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xs)
        .onChange(of: planLive) { _, now in
            guard plan != nil else { return }
            withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { open = now }
        }
        .onChange(of: plan != nil) { _, has in
            if has && planLive { withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { open = true } }
        }
    }
    @ViewBuilder private var header: some View {
        HStack(spacing: Space.sm) {
            if planLive, let plan {
                WorkPulse()
                Text("\(plan.done)/\(plan.steps.count)").font(.caption2.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                Text(plan.active.isEmpty ? "接着往下做" : plan.active)
                    .font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: plan.active)
            } else if live, let last = calls.last {
                WorkPulse()
                let kind = Self.kind(last)
                let seed = last.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
                Text(last["role"].string == "progress" ? firstLine(last["text"].string) : kind.live[seed % kind.live.count])
                    .font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(reduce ? nil : .smooth(duration: 0.3), value: last.id)
            } else if let plan {
                Image(systemName: "checklist").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                Text("清单 \(plan.done)/\(plan.steps.count) · " + summary).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            } else {
                Image(systemName: "checkmark.circle").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                Text(summary).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
    }
    private var summary: String {
        let times = steps.map { $0["time"].double }.filter { $0 > 0 }
        let span = (times.max() ?? 0) - (times.min() ?? 0)
        return "做了 \(groups.count) 步" + (span >= 1 ? " · 用时 " + WorkProcess.duration(span) : "")
    }
    /// 大步骤：连续同类的工具调用并成一项（「读了 5 个文件」），不露具体命令和路径；模型自己写的「进度」单独成项。
    private struct Group { let kind: StepKind; let count: Int; let note: String }
    private var groups: [Group] {
        var out: [Group] = []
        for step in calls {
            if step["role"].string == "progress" { out.append(Group(kind: .other, count: 0, note: firstLine(step["text"].string))); continue }
            let kind = Self.kind(step)
            if let last = out.last, last.note.isEmpty, last.kind == kind { out[out.count - 1] = Group(kind: kind, count: last.count + 1, note: "") }
            else { out.append(Group(kind: kind, count: 1, note: "")) }
        }
        return out
    }
    /// TodoCard 式一行：做完是勾，正在做是呼吸点。
    private func line(_ group: Group, running: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: running ? "circle.dotted" : "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
                .foregroundStyle(running ? Palette.accentText : Palette.textTertiary)
                .frame(width: 18)
            Text(!group.note.isEmpty ? group.note : running ? group.kind.live[0] : group.kind.done(group.count))
                .font(TypeScale.footnote.weight(running ? .semibold : .regular))
                .foregroundStyle(running ? Palette.textPrimary : Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
    private func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
}
