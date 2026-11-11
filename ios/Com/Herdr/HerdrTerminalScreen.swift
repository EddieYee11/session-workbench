import GhosttyTerminal
import HerdrKit
import SwiftUI
import UIKit

/// 全屏终端。布局参考 RexPocket：整屏是终端的底，顶上一条圆角控件，键位不常驻、要用才开。
/// - 竖拿：浮动 Dock（键盘 / 回车 / 键位）+ 向上展开一排键。
/// - 横屏：键位竖排在右侧系统列里（iPhone Duo 那一列原来是一整条黑），不占终端宽度。
struct HerdrTerminalScreen: View {
    let endpoint: SSHEndpoint
    let machineLabel: String
    let route: String
    @State private var target: HerdrTerminalTarget
    @State private var controller: HerdrPTYController
    @State private var padOpen = true
    @State private var keyboardUp = false
    @State private var ctrl: TerminalPublicStickyActivation = .inactive
    @State private var alt: TerminalPublicStickyActivation = .inactive
    @State private var cmd: TerminalPublicStickyActivation = .inactive
    @State private var isTabOperating = false
    @AppStorage(HerdrTerminalFont.defaultsKey) private var savedFontSize: Double = Double(HerdrTerminalFont.defaultSize)
    @Environment(HerdrSessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(endpoint: SSHEndpoint, target: HerdrTerminalTarget, machineLabel: String, route: String = "") {
        self.endpoint = endpoint
        self.machineLabel = machineLabel
        self.route = route
        _target = State(initialValue: target)
        _controller = State(initialValue: HerdrPTYController(endpoint: endpoint, target: target))
    }

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            // Duo 右边缘系统自己留一列（状态图标那列，外屏竖拿和展开横屏都有）：键位进这一列。
            // 普通 iPhone 竖拿没有这一列，仍用浮动 Dock；普通横屏自己让出 60pt。
            let sysTrailing = proxy.safeAreaInsets.trailing
            // 三种形态：内屏竖拿（宽 ≥600，常驻两排键位）、横屏（右侧系统列竖排键位，切换条并进顶栏省高度）、
            // 窄屏（外屏/普通 iPhone：浮动 Dock，外屏有系统列时键位进列）。
            let widePortrait = !landscape && proxy.size.width >= 560
            let useRail = !widePortrait && (sysTrailing > 20 || landscape)
            let railWidth = useRail ? max(sysTrailing, 60) : 0
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    // 顶栏改为 Apple 原生浮动毛玻璃胶囊，底色与下方终端 #282C34 彻底融为一体，不再占整条纯黑横条；
                    // 展开竖屏时上移进系统状态栏行，上下边距与 iPhone Duo 右上角状态栏（时间/Wi-Fi）严格齐平。
                    topBar(statusReserve: widePortrait ? 136 : 0, widePortrait: widePortrait)
                        .frame(width: proxy.size.width)
                    HerdrSurfaceHost(surface: controller.surface)
                        .id(ObjectIdentifier(controller))
                        .accessibilityIdentifier("herdr-terminal-view")
                    if case .ended(let reason) = controller.state {
                        endedBar(reason)
                    }
                }
                .padding(.trailing, max(0, railWidth - sysTrailing))
                .ignoresSafeArea(.container, edges: widePortrait ? .top : [])

                if useRail {
                    keyRail(width: railWidth, topInset: proxy.safeAreaInsets.top, hasSystemColumn: sysTrailing > 20)
                        .frame(width: railWidth)
                        .ignoresSafeArea(.container, edges: [.trailing, .bottom])
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if widePortrait { keyBar } else if !useRail { dock }
            }
        }
        .background(HerdrTerminalTheme.color.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in if phase == .active { controller.resumeIfNeeded() } }
        .onDisappear {
            controller.surface.setStickyModifierChangeHandler(nil)
            controller.surface.onFontSizeChanged = nil
            controller.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--landscape") || ProcessInfo.processInfo.environment["HERDR_FORCE_LANDSCAPE"] == "1" {
                for scene in UIApplication.shared.connectedScenes {
                    guard let windowScene = scene as? UIWindowScene else { continue }
                    let geometry = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscapeRight)
                    windowScene.requestGeometryUpdate(geometry) { _ in }
                }
            }
            syncSticky()
            controller.surface.setStickyModifierChangeHandler { syncSticky() }
            controller.surface.onFontSizeChanged = { newSize in
                savedFontSize = Double(newSize)
            }
            bindSwipe()
        }
    }

    // MARK: 顶栏

    private var agentName: String? {
        if case .pane(_, _, _, let agent) = target { return agent }
        return nil
    }

    private var currentPane: HerdrPane? {
        guard case .pane(_, _, let paneId, _) = target else { return nil }
        return store.snapshot?.panes.first { $0.paneId == paneId }
    }

    private func topBar(statusReserve: CGFloat, widePortrait: Bool) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            roundButton("chevron.left", label: "返回队列") { controller.stop(); dismiss() }
                .accessibilityIdentifier("herdr-terminal-close")
            if let index = currentIndex, entries.count > 1 {
                carousel(current: index)
            } else {
                HStack(spacing: Space.sm) {
                    HerdrAgentIcon(agent: agentName, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(statusDot).frame(width: 6, height: 6)
                            Text([machineLabel, route.isEmpty ? nil : route, currentPane.map { herdrStatusLabel($0.agentStatus) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.white.opacity(0.68)).lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Palette.surface.opacity(0.94), in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                Spacer(minLength: 0)
            }
            if controller.state == .connecting || isTabOperating { ProgressView().tint(.white) }
            tabActionCapsule
            Menu {
                Section("新建 Tab") {
                    ForEach(HerdrNewTabPreset.allCases) { preset in
                        Button {
                            createNewTab(preset)
                        } label: {
                            Label(preset.title, systemImage: preset.systemImage)
                        }
                    }
                }
                Button(role: .destructive) {
                    closeCurrentTabAction()
                } label: {
                    Label("关闭当前 Tab (⌘W)", systemImage: "xmark.square")
                }
                Divider()
                Button { controller.start() } label: { Label("重新连接", systemImage: "arrow.clockwise") }
                Section("字号 (\(Int(savedFontSize))pt)") {
                    Button {
                        controller.surface.adjustFont(by: 1)
                        savedFontSize = Double(controller.surface.currentFontSize)
                    } label: {
                        Label("放大 (+1pt)", systemImage: "textformat.size.larger")
                    }
                    .disabled(savedFontSize >= Double(HerdrTerminalFont.maxSize))

                    Button {
                        controller.surface.adjustFont(by: -1)
                        savedFontSize = Double(controller.surface.currentFontSize)
                    } label: {
                        Label("缩小 (-1pt)", systemImage: "textformat.size.smaller")
                    }
                    .disabled(savedFontSize <= Double(HerdrTerminalFont.minSize))

                    Button {
                        controller.surface.resetFont()
                        savedFontSize = Double(controller.surface.currentFontSize)
                    } label: {
                        Label("恢复默认 (\(Int(HerdrTerminalFont.defaultSize))pt)", systemImage: "arrow.counterclockwise")
                    }

                    Picker("快捷字号", selection: Binding(
                        get: { Int(savedFontSize) },
                        set: { newSize in
                            controller.surface.setFontSize(Float(newSize))
                            savedFontSize = Double(newSize)
                        }
                    )) {
                        ForEach([10, 11, 12, 13, 14, 16, 18, 20, 24], id: \.self) { size in
                            Text("\(size) pt").tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if let pane = currentPane, pane.agentStatus == .working {
                    Button(role: .destructive) { Task { _ = await store.sendKeys(paneId: pane.paneId, keys: ["ctrl+c"]) } } label: { Label("中断 agent", systemImage: "stop.fill") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Palette.surface.opacity(0.94), in: .circle)
                    .overlay(Circle().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            }
            .accessibilityLabel("更多")
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.md + statusReserve)
        .padding(.top, widePortrait ? 12 : 4)
        .padding(.bottom, 4)
        .frame(height: widePortrait ? 54 : 46, alignment: .bottom)
        .background(HerdrTerminalTheme.color)
    }

    /// 顶栏浮动毛玻璃胶囊：一键「打开新的 Tab（普通终端 / Agy / Claude Code / Pi）」与「关闭当前 Tab」。
    private var tabActionCapsule: some View {
        HStack(spacing: 0) {
            Menu {
                Section("打开新的 Tab") {
                    ForEach(HerdrNewTabPreset.allCases) { preset in
                        Button {
                            createNewTab(preset)
                        } label: {
                            Label(preset.title, systemImage: preset.systemImage)
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 38)
                    .contentShape(.rect)
            }
            .accessibilityLabel("打开新的 Tab")
            .accessibilityIdentifier("herdr-tab-new")

            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 0.6, height: 18)

            Button {
                closeCurrentTabAction()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 34, height: 38)
                    .contentShape(.rect)
            }
            .accessibilityLabel("关闭当前 Tab")
            .accessibilityIdentifier("herdr-tab-close")
        }
        .background(Palette.surface.opacity(0.94), in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    private func createNewTab(_ preset: HerdrNewTabPreset) {
        Haptics.impact(.light)
        guard !isTabOperating else { return }
        isTabOperating = true
        Task {
            defer { isTabOperating = false }
            do {
                let newPaneId = try await store.openNewTab(preset: preset, cwd: currentPane?.cwd)
                if case .pane = target,
                   let newPane = store.snapshot?.panes.first(where: { $0.paneId == newPaneId }),
                   newPane.terminalId != nil {
                    switchTo(.pane(newPane))
                }
            } catch {
                // 若 socket 暂不可用且当前处于完整 herdr，回退发送 config-com-phone.toml 对应的快捷键
                switch preset {
                case .terminal: press(.q, .ctrl)
                case .agy: press(.g, .ctrl)
                case .claudeCode: press(.x, .ctrl)
                case .pi: press(.p, .ctrl)
                }
            }
        }
    }

    private func closeCurrentTabAction() {
        Haptics.impact(.medium)
        guard !isTabOperating else { return }
        isTabOperating = true
        let paneIdToClose = currentPane?.paneId
        let wasPaneTarget: Bool = {
            if case .pane = target { return true }
            return false
        }()
        Task {
            defer { isTabOperating = false }
            do {
                try await store.closeCurrentTab(paneId: paneIdToClose)
                if wasPaneTarget {
                    switchTo(.whole)
                }
            } catch {
                press(.w, .ctrl)
            }
        }
    }

    private var statusDot: Color {
        switch controller.state {
        case .running: currentPane.map { herdrStatusColor($0.agentStatus) } ?? Palette.success
        case .connecting: Palette.warning
        case .ended: Palette.danger
        }
    }

    /// 同一台机器上其他 agent：一指切过去，不用退回队列。
    private var agentPanes: [HerdrPane] { store.agentPanes.filter { $0.terminalId != nil } }

    /// 轮显的条目：第一格是完整 herdr，后面是同机的各个 agent。
    private enum Entry { case whole, pane(HerdrPane) }
    private var entries: [Entry] { [.whole] + agentPanes.map(Entry.pane) }
    private func entryID(_ e: Entry) -> String {
        switch e { case .whole: "whole"; case .pane(let p): p.terminalId ?? p.paneId }
    }
    private var currentIndex: Int? { entries.firstIndex { entryID($0) == target.id } }

    /// 三联轮显：中间是当前 agent，左右两个落在中间下方、变小变淡并渐隐到边缘；点击或左右滑动都能切换。
    private func carousel(current cur: Int) -> some View {
        let panes = entries
        return GeometryReader { g in
            let centerW = min(g.size.width * 0.46, 190)
            // 侧项宽度封顶：横屏顶栏很宽时也紧贴中间一组，不往两边撑开。
            let sideW = min(max(60, (g.size.width - centerW) / 2 - 4), 112)
            let gap = centerW / 2 + sideW / 2 - 10
            ZStack {
                ForEach(Array(panes.enumerated()), id: \.offset) { i, pane in
                    let d = i - cur
                    if abs(d) <= 1 {
                        carouselItem(pane, selected: d == 0)
                            .frame(width: d == 0 ? centerW : sideW)
                            .scaleEffect(d == 0 ? 1 : 0.90, anchor: .center)
                            .opacity(d == 0 ? 1 : 0.65)
                            .offset(x: CGFloat(d) * gap, y: 0)
                            .zIndex(d == 0 ? 1 : 0)
                            .contentShape(.rect)
                            .onTapGesture { switchTo(pane) }
                            .transition(.opacity)
                            .accessibilityIdentifier("herdr-switch-\(entryID(pane))")
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 14).onEnded { v in
                guard abs(v.translation.width) > 36, abs(v.translation.width) > abs(v.translation.height) else { return }
                step(v.translation.width < 0 ? 1 : -1)
            })
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: cur)
        }
        .frame(height: 38)
        .accessibilityIdentifier("herdr-carousel")
    }

    @ViewBuilder
    private func carouselItem(_ entry: Entry, selected: Bool) -> some View {
        let pane: HerdrPane? = { if case .pane(let p) = entry { return p } else { return nil } }()
        let name = pane.map { $0.terminalTitleStripped ?? $0.agent ?? $0.paneId } ?? "herdr"
        let statusText = pane.map { herdrStatusLabel($0.agentStatus) } ?? "全部"
        let agent = pane?.agent
        if selected {
            HStack(spacing: Space.sm) {
                HerdrAgentIcon(agent: agent, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusDot).frame(width: 6, height: 6)
                        Text("\(machineLabel) · \(statusText)")
                            .font(.caption2).foregroundStyle(.white.opacity(0.68)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 38)
            .background(Palette.surface.opacity(0.94), in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        } else {
            HStack(spacing: 6) {
                HerdrAgentIcon(agent: agent, size: 20)
                Text(name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            }
            .padding(.leading, 6).padding(.trailing, 10).frame(height: 32)
            .background(Palette.surface.opacity(0.94), in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))
        }
    }

    /// 切到相邻 agent（+1 下一个 / -1 上一个），到头不循环。
    private func step(_ n: Int) {
        let panes = entries
        guard let i = currentIndex, panes.indices.contains(i + n) else { return }
        switchTo(panes[i + n])
    }

    private func switchTo(_ entry: Entry) {
        let next: HerdrTerminalTarget
        switch entry {
        case .whole: next = .whole
        case .pane(let pane):
            guard let id = pane.terminalId else { return }
            next = .pane(terminalId: id, title: pane.terminalTitleStripped ?? pane.paneId, paneId: pane.paneId, agent: pane.agent)
        }
        guard target.id != next.id else { return }
        let keyboardWasUp = controller.surface.isFirstResponder
        controller.surface.setStickyModifierChangeHandler(nil)
        controller.surface.onFontSizeChanged = nil
        _ = controller.surface.resignFirstResponder()
        controller.stop()
        target = next
        controller = HerdrPTYController(endpoint: endpoint, target: next)
        controller.surface.onFontSizeChanged = { newSize in
            savedFontSize = Double(newSize)
        }
        syncSticky()
        controller.surface.setStickyModifierChangeHandler { syncSticky() }
        bindSwipe()
        if keyboardWasUp { DispatchQueue.main.async { _ = controller.surface.becomeFirstResponder() } }
    }

    /// 两指横滑切 agent：向左滑下一个、向右滑上一个，到头不循环。
    private func bindSwipe() {
        controller.surface.onSwitch = { step in self.step(step) }
    }

    private func endedBar(_ reason: String) -> some View {
        HStack(spacing: Space.sm) {
            Text(reason).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            Spacer(minLength: 0)
            Button("重新连接") { controller.start() }.buttonStyle(.secondaryCompact)
                .accessibilityIdentifier("herdr-terminal-reconnect")
        }
        .padding(Space.sm)
    }

    // MARK: 键位

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Palette.surface.opacity(0.94), in: .circle)
                .overlay(Circle().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
        .accessibilityLabel(label)
    }

    private func syncSticky() {
        ctrl = controller.surface.stickyActivation(for: .ctrl)
        alt = controller.surface.stickyActivation(for: .alt)
        cmd = controller.surface.stickyActivation(for: .command)
    }

    private func press(_ key: TerminalKey, _ mods: TerminalInputModifiers = []) {
        Haptics.selection()
        _ = controller.surface.sendKey(key, modifiers: mods)
        syncSticky()
    }

    private func type(_ text: String) {
        Haptics.selection()
        controller.surface.insertText(text)
        syncSticky()
    }

    private func toggleKeyboard() {
        if controller.surface.isFirstResponder { _ = controller.surface.resignFirstResponder() } else { _ = controller.surface.becomeFirstResponder() }
    }

    private func pasteClipboard() {
        Haptics.selection()
        if let text = UIPasteboard.general.string, !text.isEmpty {
            _ = controller.surface.paste(text: text)
        } else {
            _ = controller.surface.sendKey(.v, modifiers: .super_)
        }
        syncSticky()
    }

    private func copySelection() {
        Haptics.selection()
        if !controller.surface.performBindingAction("copy_to_clipboard") {
            _ = controller.surface.sendKey(.c, modifiers: .super_)
        }
        syncSticky()
    }

    private func clearTerminalScreen() {
        Haptics.selection()
        _ = controller.surface.performBindingAction("clear_screen")
        _ = controller.surface.sendKey(.l, modifiers: .ctrl)
        syncSticky()
    }

    private func switchHerdrTab(_ delta: Int) {
        Haptics.selection()
        if case .pane = target, entries.count > 1 {
            step(delta)
        } else {
            // 完整 herdr 下 ctrl+, / ctrl+. 为上/下个 Tab
            _ = controller.surface.sendKey(delta < 0 ? .comma : .period, modifiers: .ctrl)
        }
        syncSticky()
    }

    private enum PadKey: Identifiable {
        case key(String, String, TerminalKey, TerminalInputModifiers)   // id, 标题, 键, 修饰
        case sticky(String, TerminalPublicStickyModifier)
        case text(String)
        case paste
        case cmdCopy
        case cmdPaste
        case cmdClear
        case cmdPrevTab
        case cmdNextTab
        case newTabMenu
        case closeTab
        var id: String {
            switch self {
            case .key(let id, _, _, _): id
            case .sticky(let t, _): "sticky-" + t
            case .text(let t): "text-" + t
            case .paste: "paste"
            case .cmdCopy: "cmd-c"
            case .cmdPaste: "cmd-v"
            case .cmdClear: "cmd-k"
            case .cmdPrevTab: "cmd-prev-tab"
            case .cmdNextTab: "cmd-next-tab"
            case .newTabMenu: "new-tab-menu"
            case .closeTab: "close-tab"
            }
        }
    }

    private var padKeys: [PadKey] {
        [
            .sticky("⌘", .command), .sticky("ctrl", .ctrl), .sticky("opt", .alt),
            .key("esc", "esc", .escape, []), .key("tab", "tab", .tab, []),
            .newTabMenu, .closeTab,
            .cmdPaste, .cmdCopy, .cmdClear, .cmdPrevTab, .cmdNextTab,
            .key("cmd-left", "⌘←", .a, .ctrl), .key("cmd-right", "⌘→", .e, .ctrl), .key("cmd-bs", "⌘⌫", .u, .ctrl),
            .key("cmd-z", "⌘Z", .z, .super_), .key("cmd-a", "⌘A", .a, .super_), .key("cmd-f", "⌘F", .f, .super_),
            .key("left", "◀", .arrowLeft, []), .key("up", "▲", .arrowUp, []), .key("down", "▼", .arrowDown, []), .key("right", "▶", .arrowRight, []),
            .key("c-c", "C-c", .c, .ctrl), .key("c-d", "C-d", .d, .ctrl), .key("c-z", "C-z", .z, .ctrl), .key("c-l", "C-l", .l, .ctrl),
            .text("|"), .text("/"), .text("~"), .text("-"), .text("_"), .text("`"), .text("'"), .text("\""),
            .paste,
        ]
    }

    @ViewBuilder
    private func keyButton(_ item: PadKey, size: CGFloat) -> some View {
        if case .newTabMenu = item {
            Menu {
                Section("打开新的 Tab (⌘T)") {
                    ForEach(HerdrNewTabPreset.allCases) { preset in
                        Button {
                            createNewTab(preset)
                        } label: {
                            Label(preset.title, systemImage: preset.systemImage)
                        }
                    }
                }
            } label: {
                keyLabel(item)
                    .frame(width: max(size, 52), height: size)
                    .background(keyFill(item), in: .rect(cornerRadius: size / 2.8))
            }
            .accessibilityIdentifier("herdr-key-\(item.id)")
        } else {
            Button {
                performPadKey(item)
            } label: {
                keyLabel(item)
                    .frame(width: itemWidth(item, base: size), height: size)
                    .background(keyFill(item), in: .rect(cornerRadius: size / 2.8))
            }
            .buttonStyle(SoftPressStyle(scale: 0.92))
            .accessibilityIdentifier("herdr-key-\(item.id)")
        }
    }

    private func itemWidth(_ item: PadKey, base: CGFloat) -> CGFloat {
        switch item {
        case .closeTab, .cmdPrevTab, .cmdNextTab:
            return max(base, 48)
        default:
            return base
        }
    }

    private func performPadKey(_ item: PadKey) {
        switch item {
        case .key(_, _, let key, let mods): press(key, mods)
        case .sticky(_, let mod): Haptics.selection(); controller.surface.toggleStickyModifier(mod); syncSticky()
        case .text(let t): type(t)
        case .paste, .cmdPaste: pasteClipboard()
        case .cmdCopy: copySelection()
        case .cmdClear: clearTerminalScreen()
        case .cmdPrevTab: switchHerdrTab(-1)
        case .cmdNextTab: switchHerdrTab(1)
        case .closeTab: closeCurrentTabAction()
        case .newTabMenu: break
        }
    }

    @ViewBuilder
    private func keyLabel(_ item: PadKey) -> some View {
        switch item {
        case .key(_, let title, _, _):
            Text(title)
                .font(.system(size: title.count > 2 ? 12.5 : 14, weight: .semibold, design: (title.hasPrefix("C-") || title.hasPrefix("⌘")) ? .monospaced : .default))
                .foregroundStyle(.white)
        case .sticky(let t, let mod):
            Text(t).font(.system(size: t == "⌘" ? 16 : 13.5, weight: .semibold)).foregroundStyle(stateOf(mod) == .inactive ? .white : Palette.onAccent)
        case .text(let t):
            Text(t).font(.system(size: 17, weight: .medium, design: .monospaced)).foregroundStyle(.white)
        case .paste:
            Image(systemName: "doc.on.clipboard").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
        case .cmdCopy:
            Text("⌘C").font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
        case .cmdPaste:
            Text("⌘V").font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
        case .cmdClear:
            Text("⌘K").font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
        case .cmdPrevTab:
            Text("⌘[").font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
        case .cmdNextTab:
            Text("⌘]").font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
        case .newTabMenu:
            HStack(spacing: 2) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("⌘T").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.white)
        case .closeTab:
            Text("⌘W").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.52))
        }
    }

    private func stateOf(_ mod: TerminalPublicStickyModifier) -> TerminalPublicStickyActivation {
        switch mod {
        case .ctrl: ctrl
        case .alt: alt
        case .command: cmd
        }
    }

    private func keyFill(_ item: PadKey) -> Color {
        if case .sticky(_, let mod) = item, stateOf(mod) != .inactive { return Palette.accent }
        if case .newTabMenu = item { return Color.white.opacity(0.18) }
        if case .closeTab = item { return Color.red.opacity(0.20) }
        return Color.white.opacity(0.12)
    }

    // 竖拿 Dock：键盘 / 回车 / 新建Tab / 关闭Tab / 键位 + 向上展开的一排键。
    private var dock: some View {
        VStack(spacing: Space.sm) {
            if padOpen {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(padKeys) { keyButton($0, size: 44) } }
                        .padding(.horizontal, Space.sm)
                }
                .frame(height: 52)
                .background(Palette.surface.opacity(0.94), in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))
                .padding(.horizontal, Space.md)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: Space.sm) {
                HStack(spacing: 4) {
                    dockButton(keyboardUp ? "keyboard.chevron.compact.down" : "keyboard", "键盘") { toggleKeyboard() }
                    dockButton("return", "回车") { press(.enter) }
                    Menu {
                        Section("打开新的 Tab (⌘T)") {
                            ForEach(HerdrNewTabPreset.allCases) { preset in
                                Button {
                                    createNewTab(preset)
                                } label: {
                                    Label(preset.title, systemImage: preset.systemImage)
                                }
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            closeCurrentTabAction()
                        } label: {
                            Label("关闭当前 Tab (⌘W)", systemImage: "xmark.square")
                        }
                    } label: {
                        Image(systemName: "plus.square.on.square")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Tab 管理")
                    dockButton(padOpen ? "command.circle.fill" : "command", "键位") { withAnimation(ComMotion.settle) { padOpen.toggle() } }
                }
                .padding(4)
                .background(Palette.surface.opacity(0.94), in: .capsule)
                .overlay(Capsule().stroke(Palette.separator.opacity(0.5), lineWidth: 0.5))
            }
            .padding(.bottom, Space.sm)
        }
    }

    // 内屏竖拿：键位常驻两排（上排常驻核心修饰键含 Mac ⌘ 与方向键，下排横向汇集 Mac ⌘ 快捷键、新建/关闭 Tab 与符号）。
    private var keyBar: some View {
        let top: [PadKey] = [
            .key("esc", "esc", .escape, []),
            .key("tab", "tab", .tab, []),
            .sticky("⌘", .command),
            .sticky("ctrl", .ctrl),
            .sticky("opt", .alt),
            .key("left", "◀", .arrowLeft, []),
            .key("up", "▲", .arrowUp, []),
            .key("down", "▼", .arrowDown, []),
            .key("right", "▶", .arrowRight, []),
        ]
        let bottom: [PadKey] = [
            .newTabMenu, .closeTab,
            .cmdPaste, .cmdCopy, .cmdClear, .cmdPrevTab, .cmdNextTab,
            .key("cmd-left", "⌘←", .a, .ctrl), .key("cmd-right", "⌘→", .e, .ctrl), .key("cmd-bs", "⌘⌫", .u, .ctrl),
            .key("cmd-z", "⌘Z", .z, .super_), .key("cmd-a", "⌘A", .a, .super_), .key("cmd-f", "⌘F", .f, .super_),
            .key("c-c", "C-c", .c, .ctrl), .key("c-d", "C-d", .d, .ctrl), .key("c-z", "C-z", .z, .ctrl), .key("c-l", "C-l", .l, .ctrl),
            .text("|"), .text("/"), .text("~"), .text("-"), .text("_"), .text("`"), .paste,
        ]
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { toggleKeyboard() } label: {
                    Image(systemName: keyboardUp ? "keyboard.chevron.compact.down" : "keyboard").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Palette.accent, in: .rect(cornerRadius: 15))
                }.accessibilityLabel("键盘")
                Button { press(.enter) } label: {
                    Image(systemName: "return").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Color.white.opacity(0.18), in: .rect(cornerRadius: 15))
                }.accessibilityLabel("回车")
                ForEach(top) { flexKey($0) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(bottom) { keyButton($0, size: 42) }
                }
            }
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
        .background(Palette.surface.opacity(0.94))
        .overlay(Rectangle().stroke(Palette.separator.opacity(0.5), lineWidth: 0.5))
        .accessibilityIdentifier("herdr-key-bar")
    }

    @ViewBuilder
    private func flexKey(_ item: PadKey) -> some View {
        if case .newTabMenu = item {
            Menu {
                Section("打开新的 Tab (⌘T)") {
                    ForEach(HerdrNewTabPreset.allCases) { preset in
                        Button { createNewTab(preset) } label: {
                            Label(preset.title, systemImage: preset.systemImage)
                        }
                    }
                }
            } label: {
                keyLabel(item).frame(maxWidth: .infinity).frame(height: 44)
                    .background(keyFill(item), in: .rect(cornerRadius: 15))
            }
            .accessibilityIdentifier("herdr-key-\(item.id)")
        } else {
            Button {
                performPadKey(item)
            } label: {
                keyLabel(item).frame(maxWidth: .infinity).frame(height: 44)
                    .background(keyFill(item), in: .rect(cornerRadius: 15))
            }
            .buttonStyle(SoftPressStyle(scale: 0.94))
            .accessibilityIdentifier("herdr-key-\(item.id)")
        }
    }

    private func dockButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 44).contentShape(.rect)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier("herdr-dock-\(symbol)")
    }

    // 横屏右栏：键位竖排。贴系统右列底部，和系统标签栏同位置；上面留出状态图标那一段。
    private func keyRail(width: CGFloat, topInset: CGFloat, hasSystemColumn: Bool) -> some View {
        VStack(spacing: 0) {
            // 有系统右列时让开状态图标那一段（时间 / Wi-Fi / 勿扰，实测约 150pt）；否则只让开刘海。
            Color.clear.frame(height: hasSystemColumn ? max(topInset, 20) + 130 : max(topInset, 8) + 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    keyboardRailButton
                    keyRailEnter
                    ForEach(padKeys) { keyButton($0, size: 44) }
                }
                .padding(.vertical, Space.sm)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 24))
            .padding(.horizontal, 4)
            .padding(.bottom, Space.sm)
        }
        .accessibilityIdentifier("herdr-key-rail")
    }

    private var keyboardRailButton: some View {
        Button { toggleKeyboard() } label: {
            Image(systemName: keyboardUp ? "keyboard.chevron.compact.down" : "keyboard").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.onAccent)
                .frame(width: 44, height: 44).background(Palette.accent, in: .rect(cornerRadius: 15))
        }
        .accessibilityLabel("键盘")
    }

    private var keyRailEnter: some View {
        Button { press(.enter) } label: {
            Image(systemName: "return").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(Color.white.opacity(0.18), in: .rect(cornerRadius: 15))
        }
        .accessibilityLabel("回车")
    }
}
