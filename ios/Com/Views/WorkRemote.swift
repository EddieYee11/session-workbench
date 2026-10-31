import SwiftUI
import ComCore

/// 工作 Tab 的第二面：远程控制面（Rex 状态卡 + herdr 只读树）。
/// 不覆盖「对话」派活面；由 `WorkSurface` 切换进入。
///
/// - Rex：mini 后端 `/remote/rex/snapshot`（控制面，不嵌终端）
/// - herdr：`/remote/herdr/snapshot` 只读会话树；真 PTY / HerdrKit 写输入另开

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

/// 终端面：Com / Rex / herdr 三分态诚实探测 + Rex 列表 + herdr 只读树。
struct WorkRemoteSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    @State private var loading = false
    @State private var comOK = false
    @State private var rex: JSON = .null
    @State private var herdr: JSON = .null
    @State private var failNote = ""
    @State private var actionNote = ""

    private var rexOK: Bool { rex["ok"].bool }
    private var herdrOK: Bool { herdr["ok"].bool }
    private var rexItems: [JSON] { rex["items"].array }
    private var herdrItems: [JSON] { herdr["items"].array }

    private var statusLabel: String {
        if loading { return "探测中…" }
        if !model.isPaired { return "未配对" }
        if !comOK { return "Com 不通" }
        if rexOK && herdrOK { return "Com · Rex · herdr 通" }
        if rexOK { return "Com · Rex 通 · herdr 未接" }
        if herdrOK { return "Com · herdr 通 · Rex 未接" }
        return "Com 通 · Rex/herdr 未接"
    }

    private var statusTone: Tone {
        if loading { return .info }
        if !model.isPaired || !comOK { return .danger }
        if rexOK || herdrOK { return rexOK && herdrOK ? .success : .warning }
        return .warning
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                header
                    .modifier(EnterRise(on: shown, delay: 0, y: 16, blur: 0, animation: ComMotion.pop))

                linkCard
                    .modifier(EnterRise(on: shown, delay: 0.04, y: 12, blur: 0, animation: ComMotion.rise))

                rexSection
                    .modifier(EnterRise(on: shown, delay: 0.08, y: 12, blur: 0, animation: ComMotion.rise))

                herdrSection
                    .modifier(EnterRise(on: shown, delay: 0.12, y: 12, blur: 0, animation: ComMotion.rise))

                if !failNote.isEmpty {
                    InlineNotice(text: failNote, tone: .danger)
                }
                if !actionNote.isEmpty {
                    InlineNotice(text: actionNote, tone: .neutral)
                }

                InlineNotice(text: honestyNote, tone: .neutral)
                    .accessibilityIdentifier("work-remote-honesty")
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
        .task { await refreshAll() }
        .refreshable { await refreshAll() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("远程终端")
                    .font(TypeScale.title)
                Spacer(minLength: 0)
                StatusPill(text: statusLabel, tone: statusTone)
            }
            Text(headerLead)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .accessibilityIdentifier("work-remote-opening")
        }
    }

    private var headerLead: String {
        if loading { return "正在问 Com 后端、Rex 和 herdr——通了才说通，不通直说。" }
        if !model.isPaired { return "还没配对 Mac mini，远程面动不了。" }
        if !comOK { return "Com 后端没通。修好配对或 mini 上的 sessions 再刷。" }
        if rexOK && herdrOK { return "Rex 控制面和 herdr 会话树都读到了。真 PTY 输入还没开——不会假装能打字进窗格。" }
        if rexOK { return "Rex 通了。herdr 没接上（多半没开 herdr server）——不假装已连。" }
        if herdrOK { return "herdr 通了。Rex 快照没读到——检查 mini 上 rex server / 隧道。" }
        return "Com 通了，Rex 和 herdr 都还没接。不会假装远程已连上。"
    }

    private var honestyNote: String {
        "控制面走 Com 后端调 rex/herdr CLI；手机不嵌闭源 Rex GUI。写命令只允许白名单模板（换行 / 中断 / clear）。"
    }

    private var linkCard: some View {
        GroupSection("链路") {
            GroupedCard {
                HStack(spacing: Space.md) {
                    Button {
                        guard !loading else { return }
                        Task { await refreshAll() }
                    } label: {
                        Label(loading ? "刷新中…" : "刷新状态", systemImage: loading ? "hourglass" : "arrow.clockwise")
                    }
                    .buttonStyle(.primaryCompact)
                    .disabled(loading)
                    .accessibilityIdentifier("work-remote-connect")

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
                    Spacer(minLength: 0)
                }
                .rowPadding()
            }
        }
    }

    private var rexSection: some View {
        GroupSection("Rex · 控制面") {
            if !rexOK {
                GroupedCard {
                    Text(rex["detail"].string.isEmpty ? "Rex 未接通" : rex["detail"].string)
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .rowPadding()
                }
            } else if rexItems.isEmpty {
                GroupedCard {
                    Text("Rex 通了，但没有 session / 窗格。")
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .rowPadding()
                }
            } else {
                GroupedCard {
                    ForEach(Array(rexItems.prefix(24).enumerated()), id: \.offset) { _, item in
                        rexRow(item)
                    }
                }
            }
        }
    }

    private func rexRow(_ item: JSON) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.md) {
                IconBadge(symbol: agentSymbol(item["agent_hint"].string), tone: item["focused"].bool ? .info : .neutral)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item["title"].string.isEmpty ? item["id"].string : item["title"].string)
                        .font(TypeScale.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(item["detail"].string.isEmpty ? item["status"].string : item["detail"].string)
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: 0)
                StatusPill(text: item["status"].string.isEmpty ? item["kind"].string : item["status"].string,
                           tone: item["status"].string == "error" ? .danger : .neutral)
            }
            HStack(spacing: Space.sm) {
                if !item["window_id"].string.isEmpty, !item["session_id"].string.isEmpty {
                    Button("聚焦") {
                        Task { await runRexAction("focus_window", args: [
                            "session_id": .string(item["session_id"].string),
                            "window_id": .string(item["window_id"].string),
                        ]) }
                    }
                    .buttonStyle(.secondaryCompact)
                }
                if !item["block_id"].string.isEmpty {
                    Button("中断 ⌃C") {
                        Task { await runRexAction("send_template", args: [
                            "block_id": .string(item["block_id"].string),
                            "template": .string("interrupt"),
                        ]) }
                    }
                    .buttonStyle(.secondaryCompact)
                }
                Button("丢给 Com") {
                    let title = item["title"].string
                    model.draft = model.draft.isEmpty
                        ? "看一下 Rex 上的「\(title)」并告诉我状态"
                        : model.draft
                    model.tab = .chat
                    Haptics.selection()
                }
                .buttonStyle(.secondaryCompact)
            }
        }
        .rowPadding()
        .accessibilityIdentifier("work-remote-rex-\(item.id)")
    }

    private var herdrSection: some View {
        GroupSection("herdr · 只读会话树") {
            if !herdrOK {
                GroupedCard {
                    Text(herdr["detail"].string.isEmpty ? "herdr 未接通（可能没开 server）" : herdr["detail"].string)
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .rowPadding()
                }
            } else if herdrItems.isEmpty {
                GroupedCard {
                    Text("herdr 通了，快照里没有 tab/pane。")
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .rowPadding()
                }
            } else {
                GroupedCard {
                    ForEach(Array(herdrItems.prefix(24).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: Space.md) {
                            IconBadge(symbol: "rectangle.split.3x1", tone: item["focused"].bool ? .info : .neutral)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item["title"].string)
                                    .font(TypeScale.rowTitle)
                                Text(item["detail"].string.isEmpty ? item["status"].string : item["detail"].string)
                                    .font(TypeScale.footnote)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            Spacer(minLength: 0)
                            StatusPill(text: item["status"].string.isEmpty ? item["kind"].string : item["status"].string, tone: .neutral)
                        }
                        .rowPadding()
                        .accessibilityIdentifier("work-remote-herdr-\(item.id)")
                    }
                }
            }
        }
    }

    private func agentSymbol(_ hint: String) -> String {
        switch hint {
        case "claude": return "sparkles"
        case "pi": return "circle.hexagongrid"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "herdr": return "rectangle.split.3x1"
        case "shell": return "terminal"
        default: return "square.grid.2x2"
        }
    }

    private func refreshAll() async {
        guard !loading else { return }
        loading = true
        failNote = ""
        defer { loading = false }
        guard model.isPaired else {
            comOK = false; rex = .null; herdr = .null
            failNote = "还没跟 Mac mini 配对——先回 Com 对话页完成配对。"
            return
        }
        let health = await model.load("/health")
        comOK = health != nil && !(health?.isNull ?? true)
        async let rexLoad = model.load("/remote/rex/snapshot")
        async let herdrLoad = model.load("/remote/herdr/snapshot")
        let (r, h) = await (rexLoad, herdrLoad)
        rex = r ?? .object(["ok": .bool(false), "detail": .string(model.errors["/remote/rex/snapshot"] ?? "Rex 快照没读到"), "items": .array([])])
        herdr = h ?? .object(["ok": .bool(false), "detail": .string(model.errors["/remote/herdr/snapshot"] ?? "herdr 快照没读到"), "items": .array([])])
        if !comOK {
            failNote = model.errors["/health"] ?? "已配对，但 /health 没读到。"
        }
        Haptics.selection()
    }

    private func runRexAction(_ name: String, args: [String: JSON]) async {
        actionNote = ""
        do {
            let result = try await model.mutate("/remote/rex/action", fields: [
                "action": .string(name),
                "args": .object(args),
            ])
            if result["ok"].bool {
                actionNote = "已执行 \(name)。"
                await refreshAll()
            } else {
                actionNote = result["detail"].string.isEmpty ? "动作没成功。" : result["detail"].string
            }
        } catch {
            actionNote = error.localizedDescription
        }
    }
}
