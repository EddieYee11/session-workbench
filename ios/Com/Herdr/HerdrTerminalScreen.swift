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
    @State private var padOpen = false
    @State private var keyboardUp = false
    @State private var ctrl: TerminalPublicStickyActivation = .inactive
    @State private var alt: TerminalPublicStickyActivation = .inactive
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
            let widePortrait = !landscape && proxy.size.width >= 600
            let useRail = !widePortrait && (sysTrailing > 20 || landscape)
            let railWidth = useRail ? max(sysTrailing, 60) : 0
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    // 内屏竖拿：状态栏那一行左边是空的，顶栏上移进去（右边让开时间 / Wi-Fi 那一簇），终端整体往上顶。
                    topBar(statusReserve: widePortrait ? 132 : 0)
                        .padding(.top, widePortrait ? 6 : 0)
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
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in if phase == .active { controller.resumeIfNeeded() } }
        .onDisappear { controller.surface.setStickyModifierChangeHandler(nil); controller.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .task { syncSticky(); controller.surface.setStickyModifierChangeHandler { syncSticky() }; bindSwipe() }
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

    private func topBar(statusReserve: CGFloat) -> some View {
        HStack(spacing: Space.sm) {
            roundButton("chevron.left", label: "返回队列") { controller.stop(); dismiss() }
                .accessibilityIdentifier("herdr-terminal-close")
            if let index = currentIndex, entries.count > 1 {
                carousel(current: index)
            } else {
            HStack(spacing: Space.sm) {
                    HerdrAgentIcon(agent: agentName, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(statusDot).frame(width: 6, height: 6)
                            Text([machineLabel, route.isEmpty ? nil : route, currentPane.map { herdrStatusLabel($0.agentStatus) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if controller.state == .connecting { ProgressView().tint(.white) }
            Menu {
                Button { controller.start() } label: { Label("重新连接", systemImage: "arrow.clockwise") }
                Section("字号") {
                    Button { controller.surface.adjustFont(by: 1) } label: { Label("放大", systemImage: "textformat.size.larger") }
                    Button { controller.surface.adjustFont(by: -1) } label: { Label("缩小", systemImage: "textformat.size.smaller") }
                    Button { controller.surface.resetFont() } label: { Label("默认", systemImage: "arrow.counterclockwise") }
                }
                if let pane = currentPane, pane.agentStatus == .working {
                    Button(role: .destructive) { Task { _ = await store.sendKeys(paneId: pane.paneId, keys: ["ctrl+c"]) } } label: { Label("中断 agent", systemImage: "stop.fill") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Color.white.opacity(0.12), in: .circle)
            }
            .accessibilityLabel("更多")
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.md + statusReserve)
        .frame(height: 64)
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
                            .scaleEffect(d == 0 ? 1 : 0.88, anchor: .center)
                            .opacity(d == 0 ? 1 : 0.5)
                            .offset(x: CGFloat(d) * gap, y: d == 0 ? -4 : 14)
                            .zIndex(d == 0 ? 1 : 0)
                            .contentShape(.rect)
                            .onTapGesture { switchTo(pane) }
                            .transition(.opacity)
                            .accessibilityIdentifier("herdr-switch-\(entryID(pane))")
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
                                         .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 14).onEnded { v in
                guard abs(v.translation.width) > 36, abs(v.translation.width) > abs(v.translation.height) else { return }
                step(v.translation.width < 0 ? 1 : -1)
            })
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: cur)
        }
        .frame(height: 60)
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
                HerdrAgentIcon(agent: agent, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusDot).frame(width: 6, height: 6)
                        Text("\(machineLabel) · \(statusText)")
                            .font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 44)
            .background(Color.white.opacity(0.10), in: .capsule)
        } else {
            HStack(spacing: 6) {
                HerdrAgentIcon(agent: agent, size: 22)
                Text(name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            }
            .padding(.leading, 5).padding(.trailing, 10).frame(height: 32)
            .background(Color.white.opacity(0.08), in: .capsule)
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
        _ = controller.surface.resignFirstResponder()
        controller.stop()
        target = next
        controller = HerdrPTYController(endpoint: endpoint, target: next)
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
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(Color.white.opacity(0.12), in: .circle)
        }
        .accessibilityLabel(label)
    }

    private func syncSticky() {
        ctrl = controller.surface.stickyActivation(for: .ctrl)
        alt = controller.surface.stickyActivation(for: .alt)
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
        if let text = UIPasteboard.general.string, !text.isEmpty { _ = controller.surface.paste(text: text) }
    }

    private enum PadKey: Identifiable {
        case key(String, String, TerminalKey, TerminalInputModifiers)   // id, 标题, 键, 修饰
        case sticky(String, TerminalPublicStickyModifier)
        case text(String)
        case paste
        var id: String {
            switch self {
            case .key(let id, _, _, _): id
            case .sticky(let t, _): "sticky-" + t
            case .text(let t): "text-" + t
            case .paste: "paste"
            }
        }
    }

    private var padKeys: [PadKey] {
        [.key("esc", "esc", .escape, []), .key("tab", "tab", .tab, []),
         .sticky("ctrl", .ctrl), .sticky("alt", .alt),
         .key("left", "◀", .arrowLeft, []), .key("up", "▲", .arrowUp, []), .key("down", "▼", .arrowDown, []), .key("right", "▶", .arrowRight, []),
         .key("c-c", "C-c", .c, .ctrl), .key("c-d", "C-d", .d, .ctrl), .key("c-z", "C-z", .z, .ctrl), .key("c-l", "C-l", .l, .ctrl),
         .text("|"), .text("/"), .text("~"), .text("-"), .text("_"), .text("`"), .text("'"), .text("\""),
         .paste]
    }

    private func keyButton(_ item: PadKey, size: CGFloat) -> some View {
        Button {
            switch item {
            case .key(_, _, let key, let mods): press(key, mods)
            case .sticky(_, let mod): Haptics.selection(); controller.surface.toggleStickyModifier(mod); syncSticky()
            case .text(let t): type(t)
            case .paste: pasteClipboard()
            }
        } label: {
            keyLabel(item)
                .frame(width: size, height: size)
                .background(keyFill(item), in: .rect(cornerRadius: size / 2.8))
        }
        .buttonStyle(SoftPressStyle(scale: 0.92))
        .accessibilityIdentifier("herdr-key-\(item.id)")
    }

    @ViewBuilder
    private func keyLabel(_ item: PadKey) -> some View {
        switch item {
        case .key(_, let title, _, _):
            Text(title).font(.system(size: title.count > 2 ? 13 : 15, weight: .semibold, design: title.hasPrefix("C-") ? .monospaced : .default)).foregroundStyle(.white)
        case .sticky(let t, let mod):
            Text(t).font(.system(size: 14, weight: .semibold)).foregroundStyle(stateOf(mod) == .inactive ? .white : Palette.onAccent)
        case .text(let t):
            Text(t).font(.system(size: 17, weight: .medium, design: .monospaced)).foregroundStyle(.white)
        case .paste:
            Image(systemName: "doc.on.clipboard").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
        }
    }

    private func stateOf(_ mod: TerminalPublicStickyModifier) -> TerminalPublicStickyActivation {
        mod == .ctrl ? ctrl : (mod == .alt ? alt : .inactive)
    }

    private func keyFill(_ item: PadKey) -> Color {
        if case .sticky(_, let mod) = item, stateOf(mod) != .inactive { return Palette.accent }
        return Color.white.opacity(0.12)
    }

    // 竖拿 Dock：键盘 / 回车 / 键位 + 向上展开的一排键。
    private var dock: some View {
        VStack(spacing: Space.sm) {
            if padOpen {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(padKeys) { keyButton($0, size: 44) } }
                        .padding(.horizontal, Space.sm)
                }
                .frame(height: 52)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(.horizontal, Space.md)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: Space.sm) {
                HStack(spacing: 4) {
                    dockButton(keyboardUp ? "keyboard.chevron.compact.down" : "keyboard", "键盘") { toggleKeyboard() }
                    dockButton("return", "回车") { press(.enter) }
                    dockButton(padOpen ? "command.circle.fill" : "command", "键位") { withAnimation(ComMotion.settle) { padOpen.toggle() } }
                }
                .padding(4)
                .background(.ultraThinMaterial, in: .capsule)
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            }
            .padding(.bottom, Space.sm)
        }
    }

    // 内屏竖拿：键位常驻两排（不用再点「键位」展开），键均分宽度，触控目标 44pt。
    private var keyBar: some View {
        let top: [PadKey] = [.key("esc", "esc", .escape, []), .key("tab", "tab", .tab, []), .sticky("ctrl", .ctrl), .sticky("alt", .alt),
                             .key("left", "◀", .arrowLeft, []), .key("up", "▲", .arrowUp, []), .key("down", "▼", .arrowDown, []), .key("right", "▶", .arrowRight, [])]
        let bottom: [PadKey] = [.key("c-c", "C-c", .c, .ctrl), .key("c-d", "C-d", .d, .ctrl), .key("c-z", "C-z", .z, .ctrl), .key("c-l", "C-l", .l, .ctrl),
                                .text("|"), .text("/"), .text("~"), .text("-"), .text("_"), .text("`"), .paste]
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
            HStack(spacing: 6) { ForEach(bottom) { flexKey($0) } }
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("herdr-key-bar")
    }

    private func flexKey(_ item: PadKey) -> some View {
        Button {
            switch item {
            case .key(_, _, let key, let mods): press(key, mods)
            case .sticky(_, let mod): Haptics.selection(); controller.surface.toggleStickyModifier(mod); syncSticky()
            case .text(let t): type(t)
            case .paste: pasteClipboard()
            }
        } label: {
            keyLabel(item).frame(maxWidth: .infinity).frame(height: 44)
                .background(keyFill(item), in: .rect(cornerRadius: 15))
        }
        .buttonStyle(SoftPressStyle(scale: 0.94))
        .accessibilityIdentifier("herdr-key-\(item.id)")
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
