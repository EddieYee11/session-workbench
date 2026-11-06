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
    }

    func start() {
        guard let command = target.command else {
            state = .ended("这个 pane 的 terminal id 无效。")
            return
        }
        guard let grid else {
            state = .connecting
            return
        }
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
                    if self?.state == .connecting { self?.state = .running }
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

/// 终端字号：宽屏（内屏）默认 14，窄屏 12；用户在「更多」里调过就记住。双指捏合库里自带（只改当前会话，不记忆）。
enum HerdrTerminalFont {
    private static let key = "herdr.terminal.fontSize"
    static var base: Float {
        let short = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        return short >= 600 ? 14 : 12
    }
    static var size: Float {
        get { let v = UserDefaults.standard.float(forKey: key); return v > 0 ? v : base }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

final class HerdrSurfaceView: UITerminalView {
    let terminalSession: InMemoryTerminalSession
    private let terminalController: TerminalController
    private let gestures = HerdrGestureHelper()
    /// 两指横滑：+1 下一个 agent，-1 上一个。
    var onSwitch: ((Int) -> Void)? { didSet { gestures.onSwitch = onSwitch } }

    init(bridge: PTYBridge) {
        terminalSession = InMemoryTerminalSession(
            write: { [weak bridge] data in bridge?.send?(data) },
            resize: { [weak bridge] viewport in
                bridge?.onResize?(Int(viewport.columns), Int(viewport.rows))
            },
            suppressesPixelOnlyResizes: true
        )
        let fontSize = HerdrTerminalFont.size
        terminalController = TerminalController(configuration: TerminalConfiguration(startingFrom: .default) {
            $0.withFontSize(fontSize)
        })
        super.init(frame: .zero)
        configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession), fontSize: fontSize)
        controller = terminalController
        backgroundColor = .black
        // 系统键盘上方那条库自带的按键栏关掉：键位改由 SwiftUI 自己画（竖拿浮动 Dock，横屏进右侧栏）。
        inputAccessoryItems = []
        gestures.attach(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// 库会把所有长按识别器拦掉（没设选择委托时返回 false），宿主自己的「长按粘贴」要单独放行。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestures.owns(gestureRecognizer) { return true }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// 「更多」菜单的字号：改记忆值，同时让当前画面立刻生效（库的捏合计数不受影响）。
    func adjustFont(by delta: Int) {
        let next = min(22, max(9, HerdrTerminalFont.size + Float(delta)))
        let applied = Int(next - HerdrTerminalFont.size)
        HerdrTerminalFont.size = next
        if applied > 0 { _ = performBindingAction("increase_font_size:\(applied)") }
        if applied < 0 { _ = performBindingAction("decrease_font_size:\(-applied)") }
    }

    func resetFont() {
        let delta = Int(HerdrTerminalFont.base - HerdrTerminalFont.size)
        HerdrTerminalFont.reset()
        if delta > 0 { _ = performBindingAction("increase_font_size:\(delta)") }
        if delta < 0 { _ = performBindingAction("decrease_font_size:\(-delta)") }
    }
}

/// 宿主手势：长按弹「粘贴」、两指横滑切 agent。库自己的单指滚动和双指捏合缩放不动，所以这里的识别器都允许与它们同时识别。
@MainActor
final class HerdrGestureHelper: NSObject, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    var onSwitch: ((Int) -> Void)?
    private weak var view: HerdrSurfaceView?
    private var menu: UIEditMenuInteraction?
    private var swiped = false
    private var owned: [UIGestureRecognizer] = []
    func owns(_ g: UIGestureRecognizer) -> Bool { owned.contains { $0 === g } }

    func attach(to view: HerdrSurfaceView) {
        self.view = view
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        long.minimumPressDuration = 0.55
        long.allowableMovement = 12
        long.numberOfTouchesRequired = 1
        long.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        long.cancelsTouchesInView = false
        long.delegate = self
        view.addGestureRecognizer(long)
        owned.append(long)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.cancelsTouchesInView = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
        owned.append(pan)

        let interaction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        menu = interaction
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

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
    func makeUIView(context: Context) -> HerdrSurfaceView { surface }
    func updateUIView(_ uiView: HerdrSurfaceView, context: Context) {}
}
