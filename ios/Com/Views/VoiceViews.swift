import SwiftUI
import ComCore

/// Draw real glyphs in the native text layout: no HStack splitting, so CJK,
/// wrapping and Dynamic Type retain their normal spacing and semantics.
private struct RhythmicGlyphRenderer: TextRenderer {
    var elapsed: Double
    var shown: Int
    var animatableData: Double { get { elapsed } set { elapsed = newValue } }
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let delay = Double(min(max(index - shown, 0), 60)) * 0.016
                    let p = index < shown ? 1 : min(1, max(0, (elapsed - delay) / 0.48))
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
    /// Glyphs carried over unchanged from the previous text; only what follows them
    /// animates. A streamed transcript re-sends the whole sentence as it grows, so
    /// without this every partial would re-blur the line and the settled result would
    /// replay a second time.
    @State private var shown = 0
    @State private var previous = ""
    var body: some View {
        Text(text).textRenderer(RhythmicGlyphRenderer(elapsed: reduce ? 10 : elapsed, shown: shown))
            .task(id: text) {
                // Service revisions drop filler words and re-punctuate mid-sentence, so a
                // partial is not a pure append. Everything from the first difference on is
                // re-said, which is what animates a correction instead of hard-cutting it —
                // and those glyphs are at zero opacity when the reflow happens, so the
                // shift underneath is never seen. Pure appends only reveal their new tail.
                shown = zip(previous, text).prefix { $0 == $1 }.count
                previous = text
                elapsed = reduce ? 10 : 0
                guard !reduce else { return }
                let duration = Double(min(max(text.count - shown, 0), 60)) * 0.016 + 0.48
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
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.sm) {
                    StatusDot(tone: model.voice.phase == .recording ? .danger : .accent)
                    Text(model.voice.phase == .recording ? "正在录音" : model.voice.phase == .transcribing ? "正在转写" : "Com 语音").font(TypeScale.footnote.weight(.medium)).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button { model.voice.autoSend.toggle(); Haptics.selection() } label: {
                        HStack(spacing: Space.xxs) {
                            Image(systemName: model.voice.autoSend ? "pause.circle.fill" : "pause.circle")
                            Text("停顿即发")
                        }
                        .font(TypeScale.footnote.weight(.medium))
                        .foregroundStyle(model.voice.autoSend ? Palette.onAccent : Palette.textSecondary)
                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
                        .background(model.voice.autoSend ? Palette.accent : Palette.fill, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("停顿 0.7 秒自动发送")
                    .accessibilityValue(model.voice.autoSend ? "开" : "关")
                    .accessibilityIdentifier("voice-auto-send")
                    Text(String(format: "%d:%02d", model.voice.seconds / 60, model.voice.seconds % 60)).font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs).background(Palette.fill, in: .capsule)
                }
                // Long dictation scrolls with the newest words instead of clipping at line 3;
                // the top edge fades so earlier lines read as history, not as cut-off text.
                ScrollView(.vertical) {
                    RhythmicText(text: model.voice.transcript.isEmpty ? title : model.voice.transcript)
                        .font(model.voice.transcript.isEmpty ? TypeScale.title : TypeScale.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("voice-rhythmic-text")
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                             .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity)
                if model.voice.phase != .ready {
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
                        model.voice.cancel()
                        if quick { model.showQuickVoice = false }
                    }
                    Spacer()
                    Button { primaryAction() } label: {
                        HStack(spacing: Space.sm) {
                            if model.voice.phase == .transcribing { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                            else { Image(systemName: model.voice.phase == .recording ? "stop.fill" : model.voice.phase == .ready ? "arrow.up" : "mic") }
                            Text(model.voice.phase == .recording ? "完成录音" : model.voice.phase == .ready ? "正在发送" : model.voice.phase == .transcribing ? "转写中" : model.voice.hasCapture ? "重新转写" : "开始录音")
                        }
                    }
                    .buttonStyle(.primaryAction)
                    .disabled(model.voice.phase == .ready || model.voice.phase == .transcribing || (model.voice.phase == .ready && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }.buttonStyle(.plain)
            }.padding(Space.lg)
        }.frame(height: model.voice.transcript.count > 36 ? 280 : 220)
        .animation(.smooth(duration: 0.35), value: model.voice.transcript.count > 36)
        .clipShape(.rect(cornerRadius: Radius.xl, style: .continuous))
        .onChange(of: model.voice.phase) { old, phase in
            if old == .recording && phase == .recorded { Task { await model.transcribeVoice() } }
        }
    }
    private func primaryAction() {
        if model.voice.phase == .recording {
            model.voice.finishRecording()
        } else if model.voice.hasCapture { Task { await model.transcribeVoice() } }
        else { Task { await model.voice.start(using: model.client) } }
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
            Text(model.voice.autoSend ? "停顿 0.7 秒自动转文字并发送。" : "完成录音后转为文字，自动发送。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 0)
        }
    }
}

/// Siri-style screen-edge glow while Com is listening. Lives above the whole app,
/// takes no touches, and stays dim enough that the transcript remains the focus.
struct ScreenEdgeGlow: View {
    let level: Double
    let processing: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var smoothed = 0.0
    private var colors: [Color] {
        // 青柠为主，带一点暖珊瑚与冷青，和 Palette 同源，不引入新的品牌色。
        let lime = Palette.accent
        return [lime, Color(red: 0.55, green: 0.86, blue: 0.62), Color(red: 0.98, green: 0.80, blue: 0.42),
                Palette.coral.opacity(0.85), lime.opacity(0.9), Color(red: 0.45, green: 0.80, blue: 0.78), lime]
    }
    var body: some View {
        TimelineView(.animation(paused: reduce)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let energy = processing ? 0.35 + 0.15 * sin(t * 2.4) : smoothed
            let spin = Angle.degrees(reduce ? 0 : (t * (processing ? 70 : 28)).truncatingRemainder(dividingBy: 360))
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            let gradient = AngularGradient(colors: colors, center: .center, angle: spin)
            let base = scheme == .dark ? 0.55 : 0.5
            ZStack {
                shape.strokeBorder(gradient, lineWidth: 10 + 22 * energy).blur(radius: 18 + 14 * energy)
                    .opacity(base + 0.35 * energy)
                shape.strokeBorder(gradient, lineWidth: 2 + 3 * energy).blur(radius: 3)
                    .opacity(0.35 + 0.4 * energy)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { smoothed = min(1, max(0, level)) }
        .onChange(of: level) { _, value in
            // Fast attack, slow release: the edge breathes with the voice instead of flickering.
            smoothed += (min(1, max(0, value)) - smoothed) * (value > smoothed ? 0.5 : 0.12)
        }
    }
    /// Approximate display corner radius; the private API value is not available to apps.
    static var cornerRadius: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let insets = scene?.windows.first?.safeAreaInsets ?? .zero
        return insets.bottom > 0 ? 55 : 0
    }
}
