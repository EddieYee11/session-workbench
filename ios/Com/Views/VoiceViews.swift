import SwiftUI
import WebKit
import ComCore

/// The upstream MIT voice-glow renderer, bundled offline. It receives only
/// the native meter envelope; no audio, transcript or credentials enter it.
struct VoiceBeamSurface: UIViewRepresentable {
    let level: Double
    let processing: Bool
    let active: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false; view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.navigationDelegate = context.coordinator
        if let url = Bundle.main.url(forResource: "VoiceBeam", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let state: [String: Any] = ["level": min(1, max(0, level)), "processing": processing,
                                   "active": active, "paused": reduce || !active,
                                   "theme": scheme == .dark ? "dark" : "light"]
        guard let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return }
        context.coordinator.update = "window.comVoiceUpdate?.(" + json + ")"
        if context.coordinator.ready { view.evaluateJavaScript(context.coordinator.update, completionHandler: nil) }
        view.alpha = opaque ? 0.65 : 1
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.comVoiceUpdate?.({active:false,paused:true})", completionHandler: nil)
        view.stopLoading(); view.navigationDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate {
        var ready = false
        var update = ""
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; webView.evaluateJavaScript(update, completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme
            decisionHandler(scheme == "file" || scheme == "about" ? .allow : .cancel)
        }
    }
}

/// Draw real glyphs in the native text layout: no HStack splitting, so CJK,
/// wrapping and Dynamic Type retain their normal spacing and semantics.
private struct RhythmicGlyphRenderer: TextRenderer {
    var elapsed: Double
    var animatableData: Double { get { elapsed } set { elapsed = newValue } }
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let delay = Double(min(index, 60)) * 0.016
                    let p = min(1, max(0, (elapsed - delay) / 0.48))
                    var layer = context
                    layer.opacity = 1 - pow(1 - p, 3)
                    layer.addFilter(.blur(radius: 4 * (1 - p)))
                    let displacement = p >= 1 ? 0 : 10 * exp(-8 * p) * cos(10 * p)
                    layer.translateBy(x: 0, y: displacement)
                    layer.draw(slice, options: .disablesSubpixelQuantization)
                    index += 1
                }
            }
        }
    }
}
struct RhythmicText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var elapsed = 0.0
    var body: some View {
        Text(text).textRenderer(RhythmicGlyphRenderer(elapsed: reduce ? 10 : elapsed))
            .task(id: text) {
                elapsed = reduce ? 10 : 0
                guard !reduce else { return }
                let duration = Double(min(text.count, 60)) * 0.016 + 0.48
                // The clock is steady; each glyph uses its own damped spring
                // curve, cubic opacity and blur-to-sharp reveal above.
                withAnimation(.linear(duration: duration)) { elapsed = duration }
            }
            .accessibilityLabel(text)
    }
}

struct VoiceSessionPanel: View {
    @Environment(AppModel.self) private var model
    var quick = false
    private var title: String {
        switch model.voice.phase {
        case .recording: "说吧，我在听。"
        case .transcribing: "正在整理你的话…"
        case .ready: "听到了。"
        case .recorded: "这段话，已经留下。"
        case .failed: "录音已保留。"
        default: "想说点什么？"
        }
    }
    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            VoiceBeamSurface(level: model.voice.level, processing: model.voice.phase == .transcribing,
                             active: model.active && [.recording, .transcribing].contains(model.voice.phase))
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.sm) {
                    StatusDot(tone: model.voice.phase == .recording ? .danger : .accent)
                    Text(model.voice.phase == .recording ? "正在录音" : model.voice.phase == .transcribing ? "正在转写" : "Com 语音").font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text(String(format: "%d:%02d", model.voice.seconds / 60, model.voice.seconds % 60)).font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs).background(Palette.fill, in: .capsule)
                }
                RhythmicText(text: model.voice.phase == .ready ? model.voice.transcript : title)
                    .font(model.voice.phase == .ready ? TypeScale.callout : TypeScale.title)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("voice-rhythmic-text")
                if model.voice.phase == .ready {
                    TextField("确认语音内容", text: $model.draft, axis: .vertical).lineLimit(1...4)
                        .font(TypeScale.callout).padding(Space.md).background(Palette.fill.opacity(0.9), in: .rect(cornerRadius: Radius.sm, style: .continuous))
                        .accessibilityIdentifier("voice-transcript-input")
                        .onChange(of: model.draft) { _, _ in model.persistSoon() }
                } else {
                    HStack(spacing: 3) {
                        ForEach(0..<40, id: \.self) { i in
                            let samples = Array(model.voice.levels.suffix(40))
                            let energy = i < samples.count ? samples[i] : 0.02
                            Capsule().fill(Palette.textPrimary.opacity(0.35)).frame(height: max(3, energy * 28))
                        }
                    }.frame(height: 28).accessibilityHidden(true)
                }
                if !model.voice.error.isEmpty { Text(model.voice.error).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(3) }
                HStack {
                    CircleActionButton(symbol: "xmark", label: "放弃录音", size: 40) {
                        if model.draft == model.voice.transcript { model.draft = ""; model.persistSoon() }
                        model.voice.cancel()
                        if quick { model.showQuickVoice = false }
                    }
                    Spacer()
                    Button { primaryAction() } label: {
                        HStack(spacing: Space.sm) {
                            if model.voice.phase == .transcribing || model.sending { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                            else { Image(systemName: model.voice.phase == .recording ? "stop.fill" : model.voice.phase == .ready ? "arrow.up" : "mic") }
                            Text(model.voice.phase == .recording ? "完成录音" : model.voice.phase == .ready ? "确认发送" : model.voice.phase == .transcribing ? "转写中" : model.voice.hasCapture ? "重新转写" : "开始录音")
                        }
                    }
                    .buttonStyle(.primaryAction)
                    .disabled(model.voice.phase == .transcribing || model.sending || (model.voice.phase == .ready && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }.buttonStyle(.plain)
            }.padding(Space.lg)
        }.frame(height: model.voice.phase == .ready ? 260 : 220).clipShape(.rect(cornerRadius: Radius.xl, style: .continuous))
    }
    private func primaryAction() {
        if model.voice.phase == .recording {
            model.voice.finishRecording(); Task { await model.transcribeVoice() }
        } else if model.voice.phase == .ready {
            Task {
                await model.send(voiceMessage: true)
                if model.pending.last?.state == .delivered { model.voice.cancel(); if quick { model.showQuickVoice = false } }
            }
        } else if model.voice.hasCapture { Task { await model.transcribeVoice() } }
        else { Task { await model.voice.start() } }
    }
}

struct QuickVoiceView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: Space.md) {
            HStack(spacing: Space.md) {
                CompanionPortrait(size: 32)
                Text("Com 语音").font(TypeScale.headline)
                Spacer()
                if model.voice.phase != .recording && model.voice.phase != .transcribing {
                    Button { model.showQuickVoice = false } label: {
                        Image(systemName: "chevron.down").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                            .frame(width: 32, height: 32).background(Palette.fill, in: .circle)
                    }.buttonStyle(.plain).accessibilityLabel("保留录音并收起")
                }
            }.padding(.horizontal, Layout.margin).padding(.top, Space.xl)
            VoiceSessionPanel(quick: true).background(Palette.surface, in: .rect(cornerRadius: Radius.xl, style: .continuous)).elevation(.raised).padding(.horizontal, Space.md)
            Text("完成录音后转写，确认内容再发送。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 0)
        }
    }
}
