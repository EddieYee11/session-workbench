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
                if !work.note.isEmpty { InlineNotice(text: work.note) }
                if rows.isEmpty && work.loaded {
                    Text(work.mode == .snapshot ? "这段还没有可看的摘录。" : "会话已打开。回看历史不会启动执行器。")
                        .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
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
        case .steps: WorkStepsRow(steps: row.steps, live: row.live)
        }
    }
}

/// 右边：我的话，和主聊天同款深色气泡。刚发的那条下面说一句送达情况。
private struct WorkUserBubble: View {
    @Environment(AppModel.self) private var model
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
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: outgoing.state)
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
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var open = false
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
                withAnimation(reduce ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { open.toggle() }
            } label: { header }
                .buttonStyle(.plain)
                .accessibilityIdentifier(live ? "work-steps-live" : "work-steps")
                .accessibilityHint(open ? "收起步骤" : "展开全部步骤")
            if open {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(calls.enumerated()), id: \.offset) { index, step in
                        line(step, running: live && index == calls.count - 1)
                    }
                }
                .padding(.leading, 6).padding(.top, Space.sm).padding(.bottom, Space.xs)
                .transition(.opacity.combined(with: .offset(y: -4)))
                .accessibilityIdentifier("work-steps-list")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xs)
    }
    @ViewBuilder private var header: some View {
        HStack(spacing: Space.sm) {
            if live, let last = calls.last {
                WorkPulse()
                let kind = Self.kind(last)
                let seed = last.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
                Text(last["role"].string == "progress" ? firstLine(last["text"].string) : kind.live[seed % kind.live.count])
                    .font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(reduce ? nil : .smooth(duration: 0.3), value: last.id)
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
        return "做了 \(calls.count) 步" + (span >= 1 ? " · 用时 " + WorkProcess.duration(span) : "")
    }
    private func line(_ step: JSON, running: Bool) -> some View {
        let kind = Self.kind(step)
        return HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: kind.symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(running ? Palette.accentText : Palette.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(step["role"].string == "progress" ? "进度" : running ? kind.live[0] : kind.done(1))
                    .font(TypeScale.footnote.weight(running ? .semibold : .regular))
                    .foregroundStyle(running ? Palette.textPrimary : Palette.textSecondary)
                let detail = firstLine(step["text"].string)
                Text(detail.isEmpty ? Self.tool(step) : detail).font(.caption2.monospaced()).foregroundStyle(Palette.textTertiary).lineLimit(1)
            }
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
