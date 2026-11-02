import GhosttyTerminal
import HerdrKit
import SwiftUI
import UIKit

/// 终端里要跑什么。
enum HerdrTerminalTarget: Identifiable, Equatable {
    /// 完整的 herdr 界面（工作区、标签、分屏都在）。
    case whole
    /// 单个 pane 的原始终端流。
    case pane(terminalId: String, title: String)

    var id: String {
        switch self {
        case .whole: return "whole"
        case .pane(let terminalId, _): return terminalId
        }
    }

    var title: String {
        switch self {
        case .whole: return "herdr"
        case .pane(_, let title): return title
        }
    }

    var command: String? {
        let herdr = "\"$HOME/.local/bin/herdr\""
        switch self {
        case .whole:
            // 手机专用配置：始终用手机布局，Duo 展开或横屏时也不出左侧栏。
            return "env HERDR_CONFIG_PATH=\"$HOME/.config/herdr/config-com-phone.toml\" \(herdr)"
        case .pane(let terminalId, _):
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

final class HerdrSurfaceView: UITerminalView {
    let terminalSession: InMemoryTerminalSession
    private let terminalController: TerminalController

    init(bridge: PTYBridge) {
        terminalSession = InMemoryTerminalSession(
            write: { [weak bridge] data in bridge?.send?(data) },
            resize: { [weak bridge] viewport in
                bridge?.onResize?(Int(viewport.columns), Int(viewport.rows))
            },
            suppressesPixelOnlyResizes: true
        )
        terminalController = TerminalController(configuration: TerminalConfiguration(startingFrom: .default) {
            $0.withFontSize(12)
        })
        super.init(frame: .zero)
        configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        controller = terminalController
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

struct HerdrSurfaceHost: UIViewRepresentable {
    let surface: HerdrSurfaceView
    func makeUIView(context: Context) -> HerdrSurfaceView { surface }
    func updateUIView(_ uiView: HerdrSurfaceView, context: Context) {}
}
