import SwiftUI
import CoreImage.CIFilterBuiltins
import ComCore

/// 给另一台设备配对：服务端生成一次性码，这里把它拼成 com-eddie://pair 链接并画成二维码。
/// 相机扫码会直接打开 Com；链接里的 base 只是地址，凭据要等新设备自己换。
struct PairCodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var code = ""
    @State private var seconds = 0
    @State private var error = ""
    @State private var loading = false
    @State private var land = false
    @State private var timer: Timer?
    /// 过期后自动换一张；失败只试一次，避免死循环打 /pair/code。
    @State private var autoRefreshArmed = true

    private var link: String {
        guard !code.isEmpty, seconds > 0 else { return "" }
        var components = URLComponents()
        components.scheme = "com-eddie"; components.host = "pair"
        components.queryItems = [URLQueryItem(name: "base", value: model.base), URLQueryItem(name: "code", value: code)]
        return components.string ?? ""
    }

    private var usable: Bool { !code.isEmpty && seconds > 0 && error.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollPage(spacing: Space.xl) {
                VStack(spacing: Space.md) {
                    if usable, let image = QRCode.image(link) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 240).padding(Space.lg)
                            .background(.white, in: .rect(cornerRadius: Radius.md, style: .continuous))
                            .accessibilityLabel("配对二维码")
                            .modifier(EnterRise(on: land && !loading, delay: 0.02, y: 12, blur: 5, animation: ComMotion.pop))
                    } else if loading {
                        ProgressView(code.isEmpty ? "正在生成配对码…" : "正在换一张新码…").frame(height: 200)
                            .accessibilityIdentifier("pair-code-pulling")
                    } else if !error.isEmpty {
                        Text("配对码还没开口——先重试；通了我再给你二维码。")
                            .font(TypeScale.subheadline).foregroundStyle(Palette.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .accessibilityIdentifier("pair-code-empty-fail")
                    }
                    if usable {
                        Text(code).font(.system(.title2, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                            .contentTransition(.numericText())
                            .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: code)
                        Text("\(seconds / 60):\(String(format: "%02d", seconds % 60)) 内有效，用一次即失效")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                            .contentTransition(.numericText())
                    }
                    if !error.isEmpty {
                        InlineNotice(text: error, tone: .danger)
                            .accessibilityIdentifier("pair-code-fail")
                    }
                }.frame(maxWidth: .infinity)
                Text(usable
                     ? "另一台 iPhone 用相机扫码，或把链接发给自己。它会带着地址和一次性码打开 Com——你确认后才写入钥匙串。"
                     : "过期或失败时不会假装还有可用码。修好网络或确认本机仍配对后，再点「再试一次」。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    .modifier(EnterRise(on: land, delay: 0.08, y: 8, blur: 3, animation: ComMotion.settle))
                if usable {
                    ShareLink(item: link) { Label("分享配对链接", systemImage: "square.and.arrow.up") }.buttonStyle(.quiet)
                }
                Button(loading ? "生成中…" : (usable ? "重新生成" : "再试一次")) {
                    guard !loading else { return }
                    autoRefreshArmed = true
                    Task { await load(reason: .manual) }
                }
                    .buttonStyle(.secondaryAction).disabled(loading)
                    .accessibilityIdentifier("pair-code-retry")
            }
            .navigationTitle("配对另一台设备").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .task { await load(reason: .open) }
            .onAppear {
                if reduce { land = true }
                else { withAnimation(ComMotion.lift) { land = true } }
            }
            .onDisappear { timer?.invalidate() }
        }
    }

    private enum LoadReason { case open, manual, expired }

    private func load(reason: LoadReason) async {
        guard !loading else { return }
        loading = true
        // 换新码前先作废旧展示，避免过期码/二维码/分享链还挂着像能用。
        if reason != .open || !code.isEmpty {
            timer?.invalidate(); timer = nil
        }
        let previous = code
        code = ""
        seconds = 0
        if reason == .expired {
            error = "上一对码已过期——正在换新的。旧码作废，不会假装还能用。"
        } else {
            error = ""
        }
        defer { loading = false }
        guard let api = model.client else {
            error = "这台还没连上 mini——先完成配对，再来给别的设备生成码。不会假装已有二维码。"
            return
        }
        do {
            let data = try await api.request("/pair/code", body: .object([:]))
            let next = data["code"].string
            guard !next.isEmpty else {
                error = reason == .expired
                    ? "自动换新没返回码——旧码已作废。点「再试一次」；别把空白当成可用码。"
                    : "服务没返回配对码——可以再试；别把空白当成可用码。"
                return
            }
            code = next
            seconds = max(0, data["expires_in"].int)
            error = ""
            autoRefreshArmed = true
            startExpiryTimer()
        } catch {
            // 失败留页：旧码已清，提示可再生成，勿假装已有可用码。
            if reason == .expired {
                self.error = "自动换新没成：" + error.localizedDescription
                    + (previous.isEmpty ? "" : "——旧码已作废")
                    + "。点「再试一次」。不会假装还能用。"
            } else {
                self.error = "没生成出来：" + error.localizedDescription + "——可以再点「再试一次」"
            }
        }
    }

    private func startExpiryTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard seconds > 0 else { return }
                seconds -= 1
                guard seconds == 0 else { return }
                // 到期立刻作废展示；可选自动换新一次。
                code = ""
                timer?.invalidate(); timer = nil
                if autoRefreshArmed {
                    autoRefreshArmed = false
                    await load(reason: .expired)
                } else {
                    error = "配对码已过期——点「再试一次」换一张。不会假装还能用。"
                }
            }
        }
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
