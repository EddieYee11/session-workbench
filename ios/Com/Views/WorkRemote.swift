import SwiftUI
import ComCore

/// 工作 Tab 的第二面：远程终端（Heeler × Moshi 取长补短）。
/// 不覆盖「对话」派活面；由 `WorkSurface` 切换进入。
///
/// - Heeler（ZingerLittleBee/Heeler，Claude 10-26 选型）：SSH → herdr.sock、原生终端/会话树
/// - Moshi（REA + moshi-ios）：moshi-hook 结构化 transcript / 审批 / 计划
/// 本夜先交付可切换的终端壳与能力说明；真 PTY / HerdrKit 接线续白天。

enum WorkSurface: String, CaseIterable, Identifiable {
    case sessions, remote
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: return "对话"
        case .remote: return "终端"
        }
    }
}

struct WorkSurfacePicker: View {
    @Binding var surface: WorkSurface
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var workSurfaceNS
    var body: some View {
        HStack(spacing: 4) {
            ForEach(WorkSurface.allCases) { item in
                Button {
                    Haptics.selection()
                    withAnimation(reduce ? .easeOut(duration: 0.15) : ComMotion.snap) { surface = item }
                } label: {
                    Text(item.title)
                        .font(TypeScale.subheadline.weight(.semibold))
                        .foregroundStyle(surface == item ? Palette.onAccent : Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if surface == item {
                                Capsule().fill(Palette.accent)
                                    .matchedGeometryEffect(id: "work-surface-pill", in: workSurfaceNS, properties: .frame, isSource: true)
                            }
                        }
                }
                .buttonStyle(SoftPressStyle(scale: 0.96))
                .accessibilityIdentifier("work-surface-\(item.rawValue)")
                .accessibilityAddTraits(surface == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.fill, in: .capsule)
        .padding(.horizontal, Layout.margin)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work-surface-picker")
    }
}

/// 终端面：主机入口 + Heeler/Moshi 能力分工 + 连接占位。
struct WorkRemoteSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("work.remote.host") private var hostPreset = "mini-lan"
    @State private var shown = false
    @State private var status: RemoteStatus = .idle

    private enum RemoteStatus: Equatable {
        case idle, connecting, probed(String), failed(String)
        var label: String {
            switch self {
            case .idle: return "还没探测"
            case .connecting: return "探测中…"
            case .probed: return "Com 通 · herdr 未接"
            case .failed: return "探测失败"
            }
        }
        var tone: Tone {
            switch self {
            case .idle: return .neutral
            case .connecting: return .info
            case .probed: return .warning  // 诚实：不是 herdr 已连上
            case .failed: return .danger
            }
        }
        var detail: String {
            switch self {
            case .idle: return ""
            case .connecting: return "正在问 Com 后端…"
            case .probed(let s), .failed(let s): return s
            }
        }
    }

    private var hosts: [(id: String, title: String, detail: String)] {
        [
            ("mini-lan", "Mac mini · 家里", "192.168.5.215 · Tailscale / 局域网"),
            ("mini-wan", "Mac mini · 公网", "ssh.eddiegao.fun:22022 · 已通公钥"),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                header
                    .modifier(EnterRise(on: shown, delay: 0, y: 16, blur: 8, animation: ComMotion.pop))

                hostBlock
                    .modifier(EnterRise(on: shown, delay: 0.05, y: 14, blur: 6, animation: ComMotion.rise))

                capabilities
                    .modifier(EnterRise(on: shown, delay: 0.1, y: 14, blur: 6, animation: ComMotion.rise))

                terminalPlaceholder
                    .modifier(EnterRise(on: shown, delay: 0.15, y: 12, blur: 5, animation: ComMotion.pop))

                InlineNotice(text: "真 SSH / herdr 终端和审批回流还在白天清单里。今晚只验证 Com 能连上 mini；原来的工作对话还在「对话」那一面。", tone: .neutral)
                    .modifier(EnterRise(on: shown, delay: 0.2, y: 10, blur: 4, animation: ComMotion.rise))
            }
            .padding(.horizontal, Layout.margin)
            .padding(.bottom, Space.xxxl)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("work-remote-surface")
        .onAppear {
            if reduce { shown = true }
            else { withAnimation(ComMotion.lift) { shown = true } }
        }
        // 进终端面 / 换主机：自动开口探测一次；失败用 InlineNotice，不假 herdr。
        .task(id: hostPreset) {
            status = .idle
            await probeComLink()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("远程终端")
                    .font(TypeScale.title)
                Spacer(minLength: 0)
                StatusPill(text: status.label, tone: status.tone)
            }
            Text(headerLead)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .contentTransition(.opacity)
                .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: headerLead)
                .accessibilityIdentifier("work-remote-opening")
        }
    }

    private var headerLead: String {
        switch status {
        case .connecting:
            return "我先开口问 Com 后端通不通——通了也只说「Com 通 · herdr 未接」。"
        case .failed:
            return "探测没成，我直说。修好配对或网络后再试；工作对话仍在「对话」那一面。"
        case .probed:
            return "Com 通了，herdr 还没接。Heeler 管连接与终端，Moshi 管结构化层——真 SSH 续白天。"
        case .idle:
            return "Heeler 管连接与终端，Moshi 管结构化 transcript / 审批。默认工作对话还在「对话」那一面。"
        }
    }

    private var hostBlock: some View {
        GroupSection("连哪台") {
            GroupedCard {
                ForEach(hosts, id: \.id) { host in
                    Button {
                        Haptics.selection()
                        // 换主机由 .task(id:) 重新开口探测；别停在旧成功态冒充仍通。
                        hostPreset = host.id
                    } label: {
                        HStack(spacing: Space.md) {
                            IconBadge(symbol: host.id == "mini-wan" ? "globe" : "desktopcomputer",
                                      tone: hostPreset == host.id ? .info : .neutral)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.title).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary)
                                Text(host.detail).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                            }
                            Spacer(minLength: 0)
                            if hostPreset == host.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Palette.accentText)
                            }
                        }
                        .rowPadding()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPressStyle(scale: 0.985))
                    .accessibilityIdentifier("work-remote-host-\(host.id)")
                }
            }
        }
    }

    private var capabilities: some View {
        GroupSection("取长补短") {
            GroupedCard {
                capabilityRow(symbol: "terminal", title: "Heeler · 连接与终端",
                              detail: "SSH → herdr.sock，会话树 / 纯终端 / Composer；Apache-2.0，可拆底层进 Com")
                capabilityRow(symbol: "text.bubble", title: "Moshi · 结构化层",
                              detail: "moshi-hook transcript / 审批 / 计划 / diff；对接「等你」与主对话语义")
                capabilityRow(symbol: "shippingbox", title: "自研桥 · HerdrKit",
                              detail: "projects/moshi-ios：Citadel SSH + herdr protocol 22，不整仓搬 Heeler UI")
            }
        }
    }

    private func capabilityRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            IconBadge(symbol: symbol, tone: .neutral)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(TypeScale.rowTitle)
                Text(detail).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .rowPadding()
    }

    private var terminalPlaceholder: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(Color.black.opacity(0.92))
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "terminal")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                        Text(hostPreset == "mini-wan" ? "ssh.eddiegao.fun:22022" : "192.168.5.215")
                            .font(TypeScale.code)
                            .foregroundStyle(Color.white.opacity(0.45))
                        Spacer(minLength: 0)
                    }
                    TimelineView(.periodic(from: .now, by: reduce ? 3600 : 0.55)) { context in
                        let blink = reduce ? true : Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                        Text(placeholderLine + (status == .idle || status == .connecting ? (blink ? " ▍" : "  ") : ""))
                            .font(TypeScale.code)
                            .foregroundStyle(Color.white.opacity(0.78))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentTransition(.opacity)
                    }
                    if !status.detail.isEmpty {
                        Text("# " + status.detail)
                            .font(TypeScale.code)
                            .foregroundStyle(Color.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Space.lg)
            }
            .frame(minHeight: 168)
            .accessibilityLabel("终端占位")
            .accessibilityValue(status.label + " " + status.detail)

            if case .failed(let detail) = status {
                InlineNotice(text: detail, tone: .danger)
                    .accessibilityIdentifier("work-remote-fail")
            }

            HStack(spacing: Space.sm) {
                Button {
                    guard status != .connecting else { return }
                    Task { await probeComLink() }
                } label: {
                    Label(probeButtonTitle, systemImage: status == .connecting ? "hourglass" : "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.primaryCompact)
                .disabled(status == .connecting)
                .accessibilityIdentifier("work-remote-connect")

                Button {
                    status = .idle
                    Haptics.selection()
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.secondaryCompact)
                .disabled(status == .idle || status == .connecting)

                Button {
                    guard !model.waitingOpening else { return }
                    model.openWaitingInbox()
                } label: {
                    Label(model.waitingOpening ? "打开中…" : "等你",
                          systemImage: model.waitingOpening ? "hourglass" : "hand.raised")
                }
                .buttonStyle(.secondaryCompact)
                .disabled(model.waitingOpening)
                .accessibilityIdentifier("work-remote-waiting")
            }

            Text(honestyNote)
                .font(TypeScale.footnote)
                .foregroundStyle(Palette.textTertiary)
                .contentTransition(.opacity)
                .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: honestyNote)
                .accessibilityIdentifier("work-remote-honesty")
        }
    }

    private var probeButtonTitle: String {
        switch status {
        case .connecting: return "探测中…"
        case .failed: return "再试一次"
        case .probed: return "再探测"
        case .idle: return "探测 Com 链路"
        }
    }

    private var honestyNote: String {
        switch status {
        case .probed:
            return "Com 后端通了。herdr SSH / PTY 还没接线——不会假装已连上；白天再接 HerdrKit。"
        case .failed:
            return "链路没通我直说——别把失败当成「已连上」。修好配对或 mini 上的 sessions，再点「再试一次」。"
        case .connecting:
            return "正在开口问 Com 后端通不通；通了也只报「Com 通 · herdr 未接」，不冒充 SSH。"
        case .idle:
            return "进这面我会先探测一次。不会假装 herdr 已连上；本夜只验证 Com 配对与后端可达。"
        }
    }

    private var placeholderLine: String {
        switch status {
        case .idle:
            return "$ ready\n# 进页会自动探测——不冒充 herdr"
        case .connecting:
            return "$ curl …/health\n# pairing + backend probe"
        case .probed:
            return "$ ok com-backend\n# herdr.sock SSH = not wired yet"
        case .failed:
            return "$ probe failed\n# see notice below — retry"
        }
    }

    /// 诚实探测：只查配对 + `/health`。成功也不宣称 herdr/SSH 已通。
    private func probeComLink() async {
        guard status != .connecting else { return }
        status = .connecting
        let name = hosts.first(where: { $0.id == hostPreset })?.title ?? "主机"
        guard model.isPaired else {
            try? await Task.sleep(for: .milliseconds(reduce ? 80 : 280))
            guard !Task.isCancelled else { return }
            status = .failed("还没跟 Mac mini 配对——先回 Com 对话页完成配对，再来探测。不会假装 herdr 已通。")
            Haptics.selection()
            return
        }
        let health = await model.load("/health")
        guard !Task.isCancelled else { return }
        if let health, !health.isNull {
            let ver = health["version"].string
            let mode = health["main_operation_mode"].string
            var bits: [String] = [name, "已配对"]
            if !ver.isEmpty { bits.append("v\(ver)") }
            if !mode.isEmpty { bits.append(mode) }
            bits.append("herdr SSH 未接线")
            status = .probed(bits.joined(separator: " · "))
            Haptics.selection()  // 不用 success：避免「连上 herdr」的错觉
        } else {
            let err = model.errors["/health"] ?? ""
            status = .failed(
                err.isEmpty
                    ? "已配对，但 /health 没读到——检查网络或 mini 上的 sessions。可再试；不会假装 herdr 已通。"
                    : "已配对，但 /health 没读到：\(err)——可再试；不会假装 herdr 已通。"
            )
            Haptics.selection()
        }
    }
}
