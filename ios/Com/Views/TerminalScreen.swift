import SwiftUI
import ComCore
@preconcurrency import SwiftTerm

struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    @State private var terminal = TerminalConnection()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(terminal.note).font(TypeScale.footnote).foregroundStyle(.secondary).padding(Space.sm)
                TerminalSurface(connection: terminal)
            }.navigationTitle("终端").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { terminal.stop(); dismiss() } }; ToolbarItem(placement: .topBarTrailing) { Button("重连") { Task { await terminal.connect(model.client, sid: sessionID) } } } }
                .task { await terminal.connect(model.client, sid: sessionID) }
                .onDisappear { terminal.stop() }
                .onChange(of: model.active) { _, active in if !active { terminal.stop() } }
        }
    }
}
@MainActor @Observable final class TerminalConnection {
    var note = "正在连接"
    var output: ((Data) -> Void)?
    private var backlog = Data()
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var dimensions: JSON?
    func connect(_ api: APIClient?, sid: String) async {
        stop(); guard let api else { note = "请先配对"; return }
        do {
            let ws = try api.socket("/terminal/" + sid.pathEncoded)
            socket = ws; ws.resume()
            // Existing terminal protocol authenticates in its first WebSocket message.
            try await ws.send(.string(String(decoding: JSONEncoder().encode(JSON.object(["token": .string(api.token)])), as: UTF8.self)))
            if let dimensions { send(dimensions) }
            note = "正在建立终端连接"
            reader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let frame = try await ws.receive()
                        guard let self else { return }
                        self.note = "已连接 · 退出面板后执行器继续运行"
                        let bytes: Data
                        switch frame { case .data(let data): bytes = data; case .string(let value): bytes = Data(value.utf8); @unknown default: continue }
                        if let output = self.output { output(bytes) } else { self.backlog.append(bytes); if self.backlog.count > 1024 * 1024 { self.backlog.removeFirst(self.backlog.count - 1024 * 1024) } }
                    }
                } catch { if !Task.isCancelled { self?.note = "终端断开，请重连。输入不会自动重发。" } }
            }
        } catch { note = error.localizedDescription }
    }
    func attach(_ view: TerminalView) {
        output = { [weak view] bytes in view?.feed(byteArray: Array(bytes)[...]) }
        if !backlog.isEmpty { output?(backlog); backlog.removeAll() }
    }
    func resize(cols: Int, rows: Int) {
        let value = JSON.object(["type": .string("resize"), "cols": .number(Double(cols)), "rows": .number(Double(rows))])
        dimensions = value; send(value)
    }
    func send(_ value: JSON) {
        guard let socket else { return }
        Task { do { try await socket.send(.string(String(decoding: JSONEncoder().encode(value), as: UTF8.self))) } catch { note = "输入送达未确认，请核对终端结果" } }
    }
    func stop() { reader?.cancel(); reader = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil }
}
struct TerminalSurface: UIViewRepresentable {
    let connection: TerminalConnection
    func makeCoordinator() -> Coordinator { Coordinator(connection) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.terminalDelegate = context.coordinator
        connection.attach(view)
        return view
    }
    func updateUIView(_ view: TerminalView, context: Context) {}
    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let connection: TerminalConnection
        init(_ connection: TerminalConnection) { self.connection = connection }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { connection.resize(cols: newCols, rows: newRows) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) { connection.send(.object(["type": .string("input"), "data": .string(String(decoding: data, as: UTF8.self))])) }
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) { Haptics.selection() }
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
