import HerdrKit
import SwiftUI

/// 工作 Tab「终端」面：选 MBP / mini，一键进完整 herdr，或直接进某个 pane。
struct HerdrTerminalSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(HerdrSessionStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var presented: HerdrTerminalTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                machinePicker
                statusBlock
                if store.phase == .connected {
                    Button {
                        presented = .whole
                    } label: {
                        Text("打开完整 herdr").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primaryFull)
                    .accessibilityIdentifier("herdr-open-whole")
                    paneTree
                }
            }
            .padding(Layout.margin)
        }
        .refreshable { await store.connect() }
        .task {
            if store.phase == .idle { await store.prepare(model: model) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, store.phase == .connected {
                Task { await store.refresh() }
            }
        }
        .fullScreenCover(item: $presented) { target in
            if let endpoint = store.endpoint {
                HerdrTerminalScreen(endpoint: endpoint, target: target, machineLabel: store.selectedMachine?.label ?? "")
            }
        }
        .accessibilityIdentifier("herdr-terminal-surface")
    }

    private var machinePicker: some View {
        HStack(spacing: Space.sm) {
            ForEach(store.machines) { machine in
                Group {
                    if machine.id == store.selectedMachineId {
                        Button(machine.label) {}.buttonStyle(.primaryCompact)
                    } else {
                        Button(machine.label) { Task { await store.select(machine.id) } }.buttonStyle(.secondaryCompact)
                    }
                }
                .accessibilityIdentifier("herdr-machine-\(machine.id)")
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
                    .font(TypeScale.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        case .connected:
            Text("\(store.endpoint?.username ?? "")@\(store.selectedMachine?.label ?? "") · \(store.routeLabel)")
                .font(TypeScale.footnote)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("herdr-connected-route")
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

    @ViewBuilder
    private var paneTree: some View {
        if let snapshot = store.snapshot {
            ForEach(snapshot.workspaces) { workspace in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(workspace.label)
                        .font(TypeScale.caption.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                    ForEach(snapshot.panes.filter { $0.workspaceId == workspace.workspaceId }) { pane in
                        paneRow(pane, tab: snapshot.tabs.first { $0.tabId == pane.tabId })
                    }
                }
            }
        }
    }

    private func paneRow(_ pane: HerdrPane, tab: HerdrTab?) -> some View {
        let title = pane.terminalTitleStripped ?? tab?.label ?? pane.paneId
        return Button {
            if let terminalId = pane.terminalId {
                presented = .pane(terminalId: terminalId, title: title)
            }
        } label: {
            HStack(spacing: Space.sm) {
                Circle().fill(statusColor(pane.agentStatus)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TypeScale.subheadline)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text("\(pane.agent ?? "shell") · \(pane.cwd ?? "-")")
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.sm)
            .background(Palette.fill, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(pane.terminalId == nil)
        .accessibilityIdentifier("herdr-pane-\(pane.paneId)")
    }

    private func statusColor(_ status: HerdrAgentStatus?) -> Color {
        switch status {
        case .working: return .green
        case .blocked: return .orange
        case .done: return .blue
        case .error: return .red
        default: return .gray.opacity(0.4)
        }
    }
}

/// 全屏终端。
struct HerdrTerminalScreen: View {
    let target: HerdrTerminalTarget
    let machineLabel: String
    @State private var controller: HerdrPTYController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(endpoint: SSHEndpoint, target: HerdrTerminalTarget, machineLabel: String) {
        self.target = target
        self.machineLabel = machineLabel
        _controller = State(initialValue: HerdrPTYController(endpoint: endpoint, target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Button {
                    controller.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 32, height: 32)
                }
                .tint(.white)
                .accessibilityLabel("关闭终端")
                .accessibilityIdentifier("herdr-terminal-close")
                Text("\(machineLabel) · \(target.title)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if controller.state == .connecting { ProgressView().tint(.white) }
            }
            .padding(.horizontal, Space.sm)
            HerdrSurfaceHost(surface: controller.surface)
                .ignoresSafeArea(.container, edges: .bottom)
                .accessibilityIdentifier("herdr-terminal-view")
            if case .ended(let reason) = controller.state {
                HStack(spacing: Space.sm) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("重新连接") { controller.start() }
                        .buttonStyle(.secondaryCompact)
                        .accessibilityIdentifier("herdr-terminal-reconnect")
                }
                .padding(Space.sm)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.resumeIfNeeded() }
        }
        .onDisappear { controller.stop() }
    }
}
