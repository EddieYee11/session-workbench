import HerdrKit
import SwiftUI

/// 工作 Tab「终端」面 = herdr 的手机控制台：谁在跑、谁在等你、派新活、追问、一键进真终端。
/// 参考 RexPocket 的首页：一屏列出所有 tab，进行中的有状态点，进终端只差一次点击。
struct HerdrTerminalSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(HerdrSessionStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var presented: HerdrTerminalTarget?
    @State private var showDispatch = false
    @State private var askTarget: HerdrPane?
    @State private var expanded: Set<String> = []
    @State private var tails: [String: String] = [:]
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                machinePicker
                statusBlock
                if store.phase == .connected {
                    summaryStrip
                    actionRow
                    if !note.isEmpty { InlineNotice(text: note, tone: .warning) }
                    queue
                }
            }
            .padding(Layout.margin)
        }
        .refreshable { await store.connect() }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--ui-herdr-demo") {
                store.loadDemo()
                if ProcessInfo.processInfo.environment["COM_PREVIEW_TERMINAL"] == "1" {
                    presented = ProcessInfo.processInfo.environment["COM_PREVIEW_PANE"] == "2"
                        ? .pane(terminalId: "term_2", title: "pi·herdr接口核对", paneId: "p2", agent: "pi")
                        : .pane(terminalId: "term_1", title: "Com 终端改版", paneId: "p1", agent: "claude")
                }
            } else if store.phase == .idle { await store.prepare(model: model) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, store.phase == .connected { Task { await store.refresh() } }
        }
        .fullScreenCover(item: $presented) { target in
            if let endpoint = store.endpoint {
                HerdrTerminalScreen(endpoint: endpoint, target: target, machineLabel: store.selectedMachine?.label ?? "", route: store.routeLabel)
            }
        }
        .sheet(isPresented: $showDispatch) { HerdrDispatchSheet { id in showDispatch = false; note = "已派出，新 tab 在队列里。"; _ = id } }
        .sheet(item: $askTarget) { pane in HerdrAskSheet(pane: pane) }
        .accessibilityIdentifier("herdr-terminal-surface")
    }

    // MARK: 机器与状态

    private var machinePicker: some View {
        HStack(spacing: Space.sm) {
            ForEach(store.machines) { machine in
                Group {
                    if machine.id == store.selectedMachineId {
                        Button(machine.label) {}.buttonStyle(.primaryCompact)
                    } else {
                        Button(machine.label) { expanded = []; tails = [:]; note = ""; Task { await store.select(machine.id) } }.buttonStyle(.secondaryCompact)
                    }
                }
                .accessibilityIdentifier("herdr-machine-\(machine.id)")
            }
            Spacer(minLength: 0)
            if store.phase == .connected {
                HStack(spacing: 6) {
                    Circle().fill(Palette.success).frame(width: 7, height: 7)
                    Text(store.routeLabel).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                }
                .accessibilityIdentifier("herdr-connected-route")
            }
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch store.phase {
        case .idle, .connecting:
            HStack(spacing: Space.sm) {
                ProgressView()
                Text("正在连接 \(store.selectedMachine?.label ?? "")…")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
        case .connected:
            EmptyView()
        case .needsAuthorization:
            VStack(alignment: .leading, spacing: Space.sm) {
                InlineNotice(text: "\(store.selectedMachine?.label ?? "这台机器")还没授权这台手机的钥匙。公钥已交给 Com 后端，运行安装脚本后下拉重试。", tone: .warning)
                Text(store.publicKey)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                retryButton
            }
            .accessibilityIdentifier("herdr-needs-authorization")
        case .hostKeyChanged:
            VStack(alignment: .leading, spacing: Space.sm) {
                InlineNotice(text: "\(store.selectedMachine?.label ?? "这台机器")的主机指纹变了。重装过系统可以重新信任；否则可能有人在中间拦截。", tone: .danger)
                Button("确认是我的机器，重新信任") { Task { await store.forgetHostKeyAndRetry() } }
                    .buttonStyle(.secondaryCompact)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.sm) {
                InlineNotice(text: message, tone: .danger)
                retryButton
            }
        }
    }

    private var retryButton: some View {
        Button("重试") { Task { await store.connect() } }
            .buttonStyle(.secondaryCompact)
            .accessibilityIdentifier("herdr-retry")
    }

    // MARK: 概览与动作

    private var summaryStrip: some View {
        let c = store.counts
        return HStack(spacing: Space.sm) {
            chip("等你", c.blocked, .blocked)
            chip("在跑", c.working, .working)
            chip("完成", c.done, .done)
            if c.error > 0 { chip("出错", c.error, .error) }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("herdr-summary")
    }

    private func chip(_ title: String, _ n: Int, _ status: HerdrAgentStatus) -> some View {
        HStack(spacing: 6) {
            Circle().fill(herdrStatusColor(status)).frame(width: 7, height: 7)
            Text("\(title) \(n)").font(TypeScale.footnote.weight(.semibold))
                .foregroundStyle(n == 0 ? Palette.textTertiary : Palette.textPrimary)
        }
        .padding(.horizontal, Space.md).padding(.vertical, 6)
        .background(Palette.fill, in: .capsule)
    }

    private var actionRow: some View {
        HStack(spacing: Space.sm) {
            Button { showDispatch = true } label: { Label("派活", systemImage: "paperplane.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.primaryFull)
                .accessibilityIdentifier("herdr-dispatch")
            Button { presented = .whole } label: { Label("完整 herdr", systemImage: "rectangle.split.2x1").frame(maxWidth: .infinity) }
                .buttonStyle(.secondaryAction)
                .accessibilityIdentifier("herdr-open-whole")
        }
    }

    // MARK: 队列

    @ViewBuilder
    private var queue: some View {
        let panes = store.agentPanes
        let waiting = panes.filter { $0.agentStatus == .blocked || $0.agentStatus == .error }
        let rest = panes.filter { $0.agentStatus != .blocked && $0.agentStatus != .error }
        if panes.isEmpty {
            Text("还没有 agent 在跑。点「派活」让 pi / agy / Cursor 干点什么。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                .padding(.vertical, Space.lg)
        }
        if !waiting.isEmpty { section("要你看一眼", waiting) }
        if !rest.isEmpty { section("队列", rest) }
        if let snapshot = store.snapshot {
            let shells = snapshot.panes.filter { ($0.agent ?? "").isEmpty }
            if !shells.isEmpty { section("终端", shells) }
        }
    }

    private func section(_ title: String, _ panes: [HerdrPane]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            ForEach(panes) { pane in card(pane) }
        }
    }

    private func title(of pane: HerdrPane) -> String {
        let tab = store.snapshot?.tabs.first { $0.tabId == pane.tabId }
        return pane.terminalTitleStripped ?? tab?.label ?? pane.paneId
    }

    private func card(_ pane: HerdrPane) -> some View {
        let isOpen = expanded.contains(pane.paneId)
        return VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                if let id = pane.terminalId { presented = .pane(terminalId: id, title: title(of: pane), paneId: pane.paneId, agent: pane.agent) }
            } label: {
                HStack(spacing: Space.md) {
                    ZStack(alignment: .topTrailing) {
                        HerdrAgentIcon(agent: pane.agent, size: 38)
                        Circle().fill(herdrStatusColor(pane.agentStatus)).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Palette.fill, lineWidth: 2))
                            .offset(x: 3, y: -3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(of: pane)).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Text("\(pane.agent ?? "shell") · \(herdrStatusLabel(pane.agentStatus)) · \(shortCwd(pane.cwd))")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .disabled(pane.terminalId == nil)
            .accessibilityIdentifier("herdr-pane-\(pane.paneId)")

            if (pane.agent ?? "").isEmpty == false {
                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    smallButton("看一眼", "eye") { toggleTail(pane) }
                    smallButton("追问", "text.bubble") { askTarget = pane }
                    if pane.agentStatus == .blocked {
                        smallButton("同意", "checkmark", tint: Palette.success) { Task { note = await store.sendKeys(paneId: pane.paneId, keys: ["enter"]) ?? "" } }
                        smallButton("拒绝", "xmark", tint: Palette.danger) { Task { note = await store.sendKeys(paneId: pane.paneId, keys: ["esc"]) ?? "" } }
                    } else if pane.agentStatus == .working {
                        smallButton("中断", "stop.fill", tint: Palette.danger) { Task { note = await store.sendKeys(paneId: pane.paneId, keys: ["ctrl+c"]) ?? "" } }
                    }
                }
                }
                if isOpen {
                    Text(tails[pane.paneId] ?? "读取中…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.sm)
                        .background(Palette.surface, in: .rect(cornerRadius: 10))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(Space.md)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.md))
    }

    private func smallButton(_ title: String, _ symbol: String, tint: Color = Palette.textPrimary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(tint)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, Space.md).frame(height: 32)
                .background(Palette.surface, in: .capsule)
        }
        .buttonStyle(SoftPressStyle(scale: 0.96))
    }

    private func shortCwd(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "-" }
        return cwd == "/" ? "/" : (cwd as NSString).lastPathComponent
    }

    private func toggleTail(_ pane: HerdrPane) {
        if expanded.contains(pane.paneId) { expanded.remove(pane.paneId); return }
        expanded.insert(pane.paneId)
        Task { tails[pane.paneId] = await store.tail(paneId: pane.paneId) }
    }
}

/// 派活：选 agent、写任务，手机直接在目标机器上开 tab、起 agent、投任务。
struct HerdrDispatchSheet: View {
    @Environment(HerdrSessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("herdr.dispatch.kind") private var kindRaw = HerdrAgentKind.pi.rawValue
    @State private var task = ""
    @State private var label = ""
    @State private var sending = false
    @State private var error = ""
    var done: (String) -> Void

    private var kind: HerdrAgentKind { HerdrAgentKind(rawValue: kindRaw) ?? .pi }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("派给谁").font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    ForEach(HerdrAgentKind.allCases) { item in
                        Button { kindRaw = item.rawValue } label: {
                            HStack(spacing: Space.md) {
                                HerdrAgentIcon(agent: item.rawValue, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(TypeScale.rowTitle)
                                    Text(item.hint).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer()
                                if item == kind { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accentText) }
                            }
                            .padding(Space.md)
                            .background(item == kind ? Palette.accent.opacity(0.28) : Palette.fill, in: .rect(cornerRadius: Radius.sm))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("herdr-kind-\(item.rawValue)")
                    }
                    Text("任务").font(TypeScale.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary).padding(.top, Space.sm)
                    TextField("自包含地写清楚要做什么、验收怎么看", text: $task, axis: .vertical)
                        .lineLimit(4...10)
                        .padding(Space.md)
                        .background(Palette.fill, in: .rect(cornerRadius: Radius.sm))
                        .accessibilityIdentifier("herdr-dispatch-task")
                    TextField("tab 名（可选，默认取任务开头）", text: $label)
                        .padding(Space.md)
                        .background(Palette.fill, in: .rect(cornerRadius: Radius.sm))
                    Text("会在 \(store.selectedMachine?.label ?? "这台机器") 新开一个 tab，agent 在里面干活；改文件的活请在电脑上用 herdr_dispatch.sh 带范围派。")
                        .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    if !error.isEmpty { InlineNotice(text: error, tone: .danger) }
                }
                .padding(Layout.margin)
            }
            .navigationTitle("派活")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { send() } label: { sending ? AnyView(ProgressView()) : AnyView(Text("派出")) }
                        .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                        .accessibilityIdentifier("herdr-dispatch-send")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func send() {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? String(text.prefix(12)) : label
        sending = true
        error = ""
        Task {
            do {
                let id = try await store.dispatch(kind: kind, label: "\(kind.title)·\(name)", task: text, cwd: nil)
                done(id)
            } catch {
                self.error = "\(error.localizedDescription)"
            }
            sending = false
        }
    }
}

/// 追问：把一句话投进正在跑的 agent。
struct HerdrAskSheet: View {
    let pane: HerdrPane
    @Environment(HerdrSessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("\(pane.agent ?? "agent") · \(pane.terminalTitleStripped ?? pane.paneId)")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                TextField("追加一句", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .padding(Space.md)
                    .background(Palette.fill, in: .rect(cornerRadius: Radius.sm))
                    .accessibilityIdentifier("herdr-ask-text")
                if !error.isEmpty { InlineNotice(text: error, tone: .danger) }
                Spacer()
            }
            .padding(Layout.margin)
            .navigationTitle("追问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        sending = true
                        Task {
                            if let e = await store.ask(paneId: pane.paneId, text: text) { error = e } else { dismiss() }
                            sending = false
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                    .accessibilityIdentifier("herdr-ask-send")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
