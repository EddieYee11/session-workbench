import GhosttyTerminal
import HerdrKit
import SwiftUI
import UIKit

/// 终端里要跑什么。
enum HerdrTerminalTarget: Identifiable, Equatable {
    /// 完整的 herdr 界面（工作区、标签、分屏都在）。
    case whole
    /// 单个 pane 的原始终端流。
    case pane(terminalId: String, title: String, paneId: String, agent: String?)

    var id: String {
        switch self {
        case .whole: return "whole"
        case .pane(let terminalId, _, _, _): return terminalId
        }
    }

    var title: String {
        switch self {
        case .whole: return "herdr"
        case .pane(_, let title, _, _): return title
        }
    }

    var command: String? {
        let herdr = "\"$HOME/.local/bin/herdr\""
        switch self {
        case .whole:
            // 手机专用配置：始终用手机布局，Duo 展开或横屏时也不出左侧栏。
            return "env HERDR_CONFIG_PATH=\"$HOME/.config/herdr/config-com-phone.toml\" \(herdr)"
        case .pane(let terminalId, _, _, _):
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-:"))
            guard !terminalId.isEmpty, terminalId.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            return "\(herdr) terminal attach \(terminalId) --takeover"
        }
    }
}

/// 把一条 SSH PTY 和一个 libghostty 表面接起来：字节进、按键出、尺寸同步。
@MainActor
@Observable
final class HerdrPTYController {
    enum State: Equatable { case connecting, running, ended(String) }

    private(set) var state: State = .connecting
    @ObservationIgnored let surface: HerdrSurfaceView
    @ObservationIgnored private let endpoint: SSHEndpoint
    @ObservationIgnored private let target: HerdrTerminalTarget
    @ObservationIgnored private let bridge = PTYBridge()
    @ObservationIgnored private var session: SSHPTYSession?
    @ObservationIgnored private var grid: (cols: Int, rows: Int)?
    @ObservationIgnored private var hasStartedOnce = false

    init(endpoint: SSHEndpoint, target: HerdrTerminalTarget) {
        self.endpoint = endpoint
        self.target = target
        surface = HerdrSurfaceView(bridge: bridge)
        bridge.onResize = { [weak self] cols, rows in
            Task { @MainActor in self?.gridChanged(cols: cols, rows: rows) }
        }
    }

    /// 表面还没量出尺寸就不开 PTY，否则远端先按 80 列画一屏又立刻重排。
    private func gridChanged(cols: Int, rows: Int) {
        grid = (cols, rows)
        if session == nil, state == .connecting {
            start()
        } else {
            session?.resize(cols: cols, rows: rows)
        }
        surface.primePointerInCenter()
    }

    var hasActiveSession: Bool { session != nil }

    func start() {
        guard let command = target.command else {
            state = .ended("这个 pane 的 terminal id 无效。")
            return
        }
        guard let grid else {
            state = .connecting
            return
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-herdr-demo") && endpoint.username == "demo" {
            state = .running
            let banner = "\u{1b}[38;5;39m╭─────────────────────────────────────────────────────────────╮\u{1b}[0m\r\n\u{1b}[38;5;39m│\u{1b}[0m  \u{1b}[1mherdr\u{1b}[0m v0.9.3 (session active)                     \u{1b}[32m● live\u{1b}[0m  \u{1b}[38;5;39m│\u{1b}[0m\r\n\u{1b}[38;5;39m│\u{1b}[0m  workspace: \u{1b}[36mAI_Work_System\u{1b}[0m  pane: \u{1b}[33mp1 [claude]\u{1b}[0m              \u{1b}[38;5;39m│\u{1b}[0m\r\n\u{1b}[38;5;39m╰─────────────────────────────────────────────────────────────╯\u{1b}[0m\r\n\u{1b}[32m➜\u{1b}[0m  \u{1b}[1;34mAI_Work_System\u{1b}[0m \u{1b}[35mgit:(main)\u{1b}[0m ✗ \u{1b}[32mherdr dispatch --agent claude\u{1b}[0m\r\n[claude] herdr session live (demo mode). Terminal ready.\r\n"
            surface.terminalSession.receive(Data(banner.utf8))
            bridge.send = { [weak self] data in
                self?.surface.terminalSession.receive(data)
            }
            return
        }
#endif
        session?.close()
        if hasStartedOnce {
            // 重连后远端会重画，先把旧画面和终端模式清掉。
            surface.terminalSession.receive(Data("\u{1b}c".utf8))
        }
        hasStartedOnce = true
        state = .connecting
        let surfaceSession = surface.terminalSession
        let new = SSHPTYSession(
            endpoint: endpoint,
            command: command,
            cols: grid.cols,
            rows: grid.rows,
            onOutput: { [weak self] data in
                surfaceSession.receive(data)
                Task { @MainActor in
                    guard let self else { return }
                    if self.state == .connecting {
                        self.state = .running
                        self.surface.primePointerInCenter()
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(200))
                            self?.surface.primePointerInCenter()
                        }
                    }
                }
            },
            onExit: { [weak self] error in
                let reason = error.map { "\($0)" } ?? "已从 herdr 分离。"
                Task { @MainActor in self?.state = .ended(reason) }
            }
        )
        bridge.send = { [weak new] data in new?.write(data) }
        session = new
        new.start()
    }

    /// App 回到前台时调用：iOS 在后台会掐断 socket，断了就自动接回。
    func resumeIfNeeded() {
        if case .ended = state { start() }
    }

    func stop() {
        session?.close()
        session = nil
    }
}

/// libghostty 的回调可能在任意线程，这里只转发。
final class PTYBridge: @unchecked Sendable {
    var send: (@Sendable (Data) -> Void)?
    var onResize: (@Sendable (Int, Int) -> Void)?
}

/// 终端统一底色（与 Ghostty 默认 One Dark / Herdr 表面底色 #282C34 完全融为一体，不再出现割裂纯黑块）。
public enum HerdrTerminalTheme {
    public static let backgroundHex = "#282C34"
    public static let uiColor = UIColor(red: 0x28 / 255.0, green: 0x2C / 255.0, blue: 0x34 / 255.0, alpha: 1.0)
    public static let color = Color(red: 0x28 / 255.0, green: 0x2C / 255.0, blue: 0x34 / 255.0)
}

/// 终端字号偏好管理器：统一管理 UserDefaults / @AppStorage 存取、范围约束与默认值。
public enum HerdrTerminalFont {
    public static let defaultsKey = "com.comapp.terminal.fontSize"
    public static let legacyKey = "herdr.terminal.fontSize"

    public static let minSize: Float = 9.0
    public static let maxSize: Float = 28.0

    /// 设备感知默认字号：普通 iPhone 竖屏 13pt，iPad / 宽屏折叠内屏（短边 ≥ 600）15pt
    public static var defaultSize: Float {
        let short = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        return short >= 600 ? 15.0 : 13.0
    }

    /// 限制字号在合法人体工学范围内 [9, 28]
    public static func clamp(_ value: Float) -> Float {
        min(maxSize, max(minSize, value))
    }

    /// 当前持久化的字号
    public static var size: Float {
        get {
            let v = UserDefaults.standard.float(forKey: defaultsKey)
            if v > 0 { return clamp(v) }
            let legacy = UserDefaults.standard.float(forKey: legacyKey)
            if legacy > 0 { return clamp(legacy) }
            return defaultSize
        }
        set {
            let clamped = clamp(newValue)
            UserDefaults.standard.set(clamped, forKey: defaultsKey)
            UserDefaults.standard.set(clamped, forKey: legacyKey)
        }
    }

    /// 重置为默认字号
    public static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}

final class HerdrSurfaceView: UITerminalView {
    let terminalSession: InMemoryTerminalSession
    private let terminalController: TerminalController
    private let gestures = HerdrGestureHelper()

    /// 当前运行时字号（追踪 Ghostty 实际渲染字号）
    private(set) var currentFontSize: Float

    /// 字号变动回调（供 SwiftUI 界面同步更新）
    var onFontSizeChanged: ((Float) -> Void)?

    /// 两指横滑：+1 下一个 agent，-1 上一个。
    var onSwitch: ((Int) -> Void)? { didSet { gestures.onSwitch = onSwitch } }

    init(bridge: PTYBridge) {
        let initialSize = HerdrTerminalFont.size
        self.currentFontSize = initialSize

        terminalSession = InMemoryTerminalSession(
            write: { [weak bridge] data in bridge?.send?(data) },
            resize: { [weak bridge] viewport in
                bridge?.onResize?(Int(viewport.columns), Int(viewport.rows))
            },
            suppressesPixelOnlyResizes: true
        )
        terminalController = TerminalController(configuration: TerminalConfiguration(startingFrom: .default) {
            $0.withFontSize(initialSize)
            $0.withBackground(HerdrTerminalTheme.backgroundHex)
        })
        super.init(frame: .zero)
        configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession), fontSize: initialSize)
        controller = terminalController
        backgroundColor = HerdrTerminalTheme.uiColor
        // 系统键盘上方那条库自带的按键栏关掉：键位改由 SwiftUI 自己画（竖拿浮动 Dock，横屏进右侧栏）。
        inputAccessoryItems = []
        gestures.attach(to: self)

        // 接管并持久化双指捏合缩放手势
        setupManagedPinchZoom()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            primePointerInCenter()
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            gestures.stopMomentum()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gestures.disableBuiltInSingleFingerPan(in: self)
    }

    /// 预设鼠标指针在终端视口正中，使 herdr 等开启鼠标捕获的 TUI 立即响应滚轮回看。
    func primePointerInCenter() {
        guard bounds.width > 16, bounds.height > 48 else { return }
        sendMousePos(x: Double(bounds.midX), y: Double(bounds.midY))
    }

    /// 库会把所有长按识别器拦掉（没设选择委托时返回 false），宿主自己的「长按粘贴」要单独放行。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestures.owns(gestureRecognizer) { return true }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    // MARK: - 自管理 Pinch-to-Zoom 手势

    private var pinchStartFontSize: Float = 13.0
    private var lastPinchScale: CGFloat = 1.0

    private func setupManagedPinchZoom() {
        // 移除 UITerminalView 内部未持久化的 pinch 手势
        if let defaultPinch = gestureRecognizers?.first(where: { $0 is UIPinchGestureRecognizer }) {
            removeGestureRecognizer(defaultPinch)
        }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleManagedPinchZoom(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = gestures
        addGestureRecognizer(pinch)
    }

    @objc private func handleManagedPinchZoom(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartFontSize = currentFontSize
            lastPinchScale = gesture.scale

        case .changed:
            let delta = gesture.scale - lastPinchScale
            let steps = Int(delta / 0.1) // 每 0.1 缩放对应 1pt 字号
            guard steps != 0 else { return }

            lastPinchScale += CGFloat(steps) * 0.1
            let targetSize = HerdrTerminalFont.clamp(currentFontSize + Float(steps))
            let diff = Int(targetSize - currentFontSize)
            if diff != 0 {
                applyFontSizeDelta(diff)
                UISelectionFeedbackGenerator().selectionChanged()
            }

        case .ended, .cancelled, .failed:
            lastPinchScale = 1.0
            HerdrTerminalFont.size = currentFontSize
            onFontSizeChanged?(currentFontSize)

        default:
            break
        }
    }

    // MARK: - 字号调节与 Ghostty 实时生效

    /// 增量调节字号（支持 Menu / 快捷键）
    func adjustFont(by delta: Int) {
        let targetSize = HerdrTerminalFont.clamp(currentFontSize + Float(delta))
        let diff = Int(targetSize - currentFontSize)
        guard diff != 0 else { return }
        applyFontSizeDelta(diff)
        HerdrTerminalFont.size = currentFontSize
        onFontSizeChanged?(currentFontSize)
    }

    /// 设置指定字号
    func setFontSize(_ size: Float) {
        let clamped = HerdrTerminalFont.clamp(size)
        let diff = Int(round(clamped - currentFontSize))
        guard diff != 0 else { return }
        applyFontSizeDelta(diff)
        HerdrTerminalFont.size = currentFontSize
        onFontSizeChanged?(currentFontSize)
    }

    /// 重置为默认字号
    func resetFont() {
        let targetSize = HerdrTerminalFont.defaultSize
        let diff = Int(round(targetSize - currentFontSize))
        HerdrTerminalFont.reset()
        if diff != 0 {
            applyFontSizeDelta(diff)
        }
        onFontSizeChanged?(currentFontSize)
    }

    /// 核心底层执行：调用 Ghostty binding action 并触发布局与远程 PTY 刷新
    private func applyFontSizeDelta(_ diff: Int) {
        guard diff != 0 else { return }
        if diff > 0 {
            _ = performBindingAction("increase_font_size:\(diff)")
        } else {
            _ = performBindingAction("decrease_font_size:\(-diff)")
        }
        currentFontSize += Float(diff)
        fitToSize()
    }
}

/// 宿主手势：单指纵向滚动回滚（带惯性动量）、长按弹「粘贴」、两指横滑切 agent。
@MainActor
final class HerdrGestureHelper: NSObject, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    private static let touchScrollMultiplier: CGFloat = 3.0

    var onSwitch: ((Int) -> Void)?
    private weak var view: HerdrSurfaceView?
    private var menu: UIEditMenuInteraction?
    private var swiped = false
    private var owned: [UIGestureRecognizer] = []

    // 自由回滚状态与动量
    private var scrollPan: UIPanGestureRecognizer?
    private var twoFingerSwitchPan: UIPanGestureRecognizer?
    private var scrollAccumulator: CGFloat = 0
    private var lastScrollPoint: CGPoint = .zero
    private var displayLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero
    private var lastFrameTime: CFTimeInterval = 0

    func owns(_ g: UIGestureRecognizer) -> Bool { owned.contains { $0 === g } }

    func disableBuiltInSingleFingerPan(in view: UIView) {
        for g in view.gestureRecognizers ?? [] {
            if let pan = g as? UIPanGestureRecognizer, pan.maximumNumberOfTouches == 1, !owns(pan), pan.isEnabled {
                pan.isEnabled = false
            }
        }
    }

    func attach(to view: HerdrSurfaceView) {
        self.view = view

        // 1. 禁用 SPM 库内置的未同步 sendMousePos 的单指 pan，改由宿主手势统一驱动
        disableBuiltInSingleFingerPan(in: view)

        // 2. 挂载宿主单指垂直滚动手势（不拦 tap，单指点按仍可唤起键盘）
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scroll.minimumNumberOfTouches = 1
        scroll.maximumNumberOfTouches = 1
        scroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        view.addGestureRecognizer(scroll)
        owned.append(scroll)
        scrollPan = scroll

        // 3. 长按弹粘贴菜单
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        long.minimumPressDuration = 0.55
        long.allowableMovement = 12
        long.numberOfTouchesRequired = 1
        long.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        long.cancelsTouchesInView = false
        long.delegate = self
        view.addGestureRecognizer(long)
        owned.append(long)

        // 4. 两指横滑切 agent
        let pan = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.cancelsTouchesInView = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
        owned.append(pan)
        twoFingerSwitchPan = pan

        let interaction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        menu = interaction
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g === scrollPan || other === scrollPan {
            let counterpart = (g === scrollPan) ? other : g
            // 单指纵向滚动不与双指缩放、双指横滑同时识别
            if counterpart is UIPinchGestureRecognizer || counterpart === twoFingerSwitchPan {
                return false
            }
            // 阻止外部父容器（Sheet / 外层 ScrollView / 下拉刷新）抢夺终端内的单指拖拽
            if counterpart is UIPanGestureRecognizer, counterpart.view !== view {
                return false
            }
        }
        return true
    }

    // MARK: - 单指回滚与动量惯性（双通道：TUI 鼠标滚轮 + 本地 Scrollback）

    /// 将触点限制在活跃终端窗格内容区内（避开完整 herdr 顶部标签栏 y < 36 与底栏边缘），确保滚轮事件始终落入目标窗格。
    private func clampedPanePoint(_ pt: CGPoint, in view: UIView) -> CGPoint {
        let minX: CGFloat = 8
        let maxX = max(minX, view.bounds.width - 8)
        let minY: CGFloat = 36
        let maxY = max(minY, view.bounds.height - 20)
        return CGPoint(
            x: min(maxX, max(minX, pt.x)),
            y: min(maxY, max(minY, pt.y))
        )
    }

    @objc private func handleScrollPan(_ g: UIPanGestureRecognizer) {
        guard let view else { return }
        switch g.state {
        case .began:
            stopMomentum()
            scrollAccumulator = 0
            let pt = clampedPanePoint(g.location(in: view), in: view)
            lastScrollPoint = pt
            view.sendMousePos(x: Double(pt.x), y: Double(pt.y))
            view.sendMouseScroll(x: 0, y: 0, mods: TerminalScrollModifiers(precision: true, momentum: .began))

        case .changed:
            let pt = clampedPanePoint(g.location(in: view), in: view)
            lastScrollPoint = pt
            view.sendMousePos(x: Double(pt.x), y: Double(pt.y))

            let translation = g.translation(in: view)
            g.setTranslation(.zero, in: view)

            // 自然触控方向：与前版相反，直接传入 translation.y，使手指滑动与内容滚动方向符合真机手势直觉。
            view.sendMouseScroll(
                x: Double(translation.x * Self.touchScrollMultiplier),
                y: Double(translation.y * Self.touchScrollMultiplier),
                mods: TerminalScrollModifiers(precision: true)
            )

        case .ended:
            let velocity = g.velocity(in: view)
            if abs(velocity.x) > 50 || abs(velocity.y) > 50 {
                startMomentum(velocity: velocity)
            } else {
                view.sendMouseScroll(x: 0, y: 0, mods: TerminalScrollModifiers(precision: true, momentum: .none))
            }

        case .cancelled, .failed:
            stopMomentum()
            view.sendMouseScroll(x: 0, y: 0, mods: TerminalScrollModifiers(precision: true, momentum: .none))

        default:
            break
        }
    }

    private func startMomentum(velocity: CGPoint) {
        stopMomentum()
        momentumVelocity = velocity
        lastFrameTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(momentumFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func momentumFrame(_ link: CADisplayLink) {
        guard let view, hypot(momentumVelocity.x, momentumVelocity.y) > 15 else {
            stopMomentum()
            return
        }
        let now = CACurrentMediaTime()
        let dt = max(0.001, min(now - lastFrameTime, 0.05))
        lastFrameTime = now

        let decay = CGFloat(pow(0.92, dt * 60.0))
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay

        let dx = momentumVelocity.x * CGFloat(dt) * Self.touchScrollMultiplier
        let dy = momentumVelocity.y * CGFloat(dt) * Self.touchScrollMultiplier

        let pt = clampedPanePoint(lastScrollPoint, in: view)
        view.sendMousePos(x: Double(pt.x), y: Double(pt.y))
        view.sendMouseScroll(
            x: Double(dx),
            y: Double(dy),
            mods: TerminalScrollModifiers(precision: true, momentum: .changed)
        )
    }

    func stopMomentum() {
        let wasRunning = displayLink != nil
        displayLink?.invalidate()
        displayLink = nil
        momentumVelocity = .zero
        scrollAccumulator = 0
        if wasRunning, let view {
            view.sendMouseScroll(x: 0, y: 0, mods: TerminalScrollModifiers(precision: true, momentum: .none))
        }
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let view, UIPasteboard.general.hasStrings else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: g.location(in: view)))
    }

    @objc private func twoFingerPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: swiped = false
        case .changed:
            guard !swiped, let view, !pinching(in: view) else { return }
            let t = g.translation(in: view)
            // 横向明显大于纵向、且拖过 60pt 才算；一次手势只切一次。
            if abs(t.x) > 60, abs(t.x) > abs(t.y) * 1.5 {
                swiped = true
                UISelectionFeedbackGenerator().selectionChanged()
                onSwitch?(t.x < 0 ? 1 : -1)
            }
        default: break
        }
    }

    /// 库的双指捏合正在缩字号时，别把斜着张开的双指当成横滑。
    private func pinching(in view: UIView) -> Bool {
        (view.gestureRecognizers ?? []).contains { $0 is UIPinchGestureRecognizer && ($0.state == .began || $0.state == .changed) }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let view else { return nil }
        let paste = UIAction(title: "粘贴", image: UIImage(systemName: "doc.on.clipboard")) { _ in
            view.unmarkText()
            if let text = UIPasteboard.general.string { _ = view.paste(text: text) }
        }
        let pasteEnter = UIAction(title: "粘贴并回车", image: UIImage(systemName: "return")) { _ in
            view.unmarkText()
            if let text = UIPasteboard.general.string { _ = view.paste(text: text); _ = view.sendKey(.enter) }
        }
        return UIMenu(children: [paste, pasteEnter])
    }
}

struct HerdrSurfaceHost: UIViewRepresentable {
    let surface: HerdrSurfaceView
    func makeUIView(context: Context) -> HerdrSurfaceView {
        surface.setContentHuggingPriority(.defaultLow, for: .horizontal)
        surface.setContentHuggingPriority(.defaultLow, for: .vertical)
        surface.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        surface.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return surface
    }
    func updateUIView(_ uiView: HerdrSurfaceView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HerdrSurfaceView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
