import SwiftUI
import CoreImage.CIFilterBuiltins
import ComCore

/// 给另一台设备配对：服务端生成一次性码，这里把它拼成 com-eddie://pair 链接并画成二维码。
/// 相机扫码会直接打开 Com；链接里的 base 只是地址，凭据要等新设备自己换。
struct PairCodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var seconds = 0
    @State private var error = ""
    @State private var loading = true
    @State private var timer: Timer?

    private var link: String {
        var components = URLComponents()
        components.scheme = "com-eddie"; components.host = "pair"
        components.queryItems = [URLQueryItem(name: "base", value: model.base), URLQueryItem(name: "code", value: code)]
        return components.string ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollPage(spacing: Space.xl) {
                VStack(spacing: Space.md) {
                    if let image = QRCode.image(link) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 240).padding(Space.lg)
                            .background(.white, in: .rect(cornerRadius: Radius.md, style: .continuous))
                            .accessibilityLabel("配对二维码")
                    } else if loading {
                        ProgressView().frame(height: 200)
                    }
                    if !code.isEmpty {
                        Text(code).font(.system(.title2, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                        Text(seconds > 0 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60)) 内有效，用一次即失效" : "已过期，重新生成")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                    }
                    if !error.isEmpty { InlineNotice(text: error) }
                }.frame(maxWidth: .infinity)
                Text("在另一台 iPhone 上用相机扫码，或把下面这段链接发给自己。新设备会带着地址和一次性码打开 Com，确认后才会保存。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                if !link.isEmpty {
                    ShareLink(item: link) { Label("分享配对链接", systemImage: "square.and.arrow.up") }.buttonStyle(.quiet)
                }
                Button("重新生成") { Task { await load() } }.buttonStyle(.quiet).disabled(loading)
            }
            .navigationTitle("配对另一台设备").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .task { await load() }
            .onDisappear { timer?.invalidate() }
        }
    }

    private func load() async {
        loading = true; error = ""; code = ""; seconds = 0
        defer { loading = false }
        guard let api = model.client else { error = "先连接这台设备"; return }
        do {
            let data = try await api.request("/pair/code", body: .object([:]))
            code = data["code"].string
            seconds = max(0, data["expires_in"].int)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in seconds = max(0, seconds - 1) }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private enum QRCode {
    static func image(_ text: String) -> UIImage? {
        guard !text.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
