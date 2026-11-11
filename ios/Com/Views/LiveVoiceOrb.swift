import SwiftUI
import ComCore

/// 通话圆球：只用品牌青柠一个色系，靠形变、明度和光晕表达状态。
/// 在听 = 沉、慢呼吸、随人声亮边；在说 = 亮、随音量鼓动；在想/接通 = 收小、内部流光；静音 = 褪色；断线 = 暗珊瑚。
struct LiveVoiceOrb: View {
    let phase: LiveVoiceSession.Phase
    let userLevel: Double
    let assistantLevel: Double
    let muted: Bool
    var bargeInTriggerCount: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var rippleStart: Date?

    private enum Mood { case listening, speaking, working, muted, failed }

    private var mood: Mood {
        switch phase {
        case .failed: return .failed
        case .speaking: return .speaking
        case .listening, .idle: return muted ? .muted : .listening
        default: return .working // thinking / connecting / reconnecting
        }
    }

    private struct Tone {
        let core: Color   // 高光侧
        let body: Color   // 主体
        let deep: Color   // 背光侧
        let glow: Color   // 外晕
    }

    private var tone: Tone {
        switch mood {
        case .speaking:
            return Tone(core: Color(red: 0.96, green: 1.00, blue: 0.74),
                        body: Color(red: 0.80, green: 0.94, blue: 0.36),
                        deep: Color(red: 0.26, green: 0.52, blue: 0.20),
                        glow: Color(red: 0.78, green: 0.94, blue: 0.38))
        case .listening:
            return Tone(core: Color(red: 0.84, green: 0.95, blue: 0.56),
                        body: Color(red: 0.52, green: 0.72, blue: 0.28),
                        deep: Color(red: 0.10, green: 0.26, blue: 0.14),
                        glow: Color(red: 0.56, green: 0.78, blue: 0.32))
        case .working:
            return Tone(core: Color(red: 0.90, green: 0.97, blue: 0.70),
                        body: Color(red: 0.44, green: 0.62, blue: 0.28),
                        deep: Color(red: 0.08, green: 0.20, blue: 0.12),
                        glow: Color(red: 0.50, green: 0.70, blue: 0.32))
        case .muted:
            return Tone(core: Color(white: 0.62), body: Color(white: 0.34), deep: Color(white: 0.12), glow: Color(white: 0.30))
        case .failed:
            return Tone(core: Color(red: 0.98, green: 0.70, blue: 0.62),
                        body: Color(red: 0.62, green: 0.26, blue: 0.20),
                        deep: Color(red: 0.20, green: 0.07, blue: 0.06),
                        glow: Palette.coral)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduce)) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSinceReferenceDate
            let tone = tone

            // 驱动量：0…1
            let level: Double = {
                switch mood {
                case .speaking: return min(1, max(0.10, assistantLevel))
                case .listening: return min(1, userLevel)
                case .working: return 0.16 + 0.08 * sin(t * 2.6)
                case .muted, .failed: return 0
                }
            }()
            let rippleAge = rippleStart.map { now.timeIntervalSince($0) } ?? 9

            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) * 0.30
                let breathe = 0.018 * sin(t * (mood == .listening ? 1.1 : 1.7))
                let stateScale: Double = mood == .working ? 0.90 : mood == .speaking ? 1.04 : 1.0
                let r = base * (stateScale + breathe + level * (mood == .speaking ? 0.20 : 0.07))

                // 1. 外晕
                // 用渐变到透明而不是模糊滤镜：模糊会被画布边界裁成方块
                let gr = min(size.width, size.height) / 2
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2)),
                         with: .radialGradient(
                            Gradient(stops: [
                                .init(color: tone.glow.opacity(0.30 + level * 0.30), location: 0),
                                .init(color: tone.glow.opacity(0.10 + level * 0.12), location: 0.55),
                                .init(color: .clear, location: 1),
                            ]),
                            center: c, startRadius: r * 0.85, endRadius: gr))

                // 2. 一次性打断波纹
                if rippleAge < 0.7 {
                    let p = rippleAge / 0.7
                    let eased = 1 - pow(1 - p, 3)
                    let rr = r * (1.02 + eased * 0.55)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                               with: .color(tone.core.opacity((1 - p) * 0.55)),
                               lineWidth: 2.2 * (1 - p) + 0.4)
                }

                // 3. 球体：平滑闭合曲线，说话时形变更大
                let wobble = r * (mood == .speaking ? 0.020 + level * 0.075 : mood == .working ? 0.022 : 0.010 + level * 0.030)
                let speed = mood == .speaking ? 1.9 : mood == .working ? 1.3 : 0.6
                let blob = Self.blob(center: c, radius: r, t: t * speed, amplitude: wobble)
                let light = CGPoint(x: c.x - r * 0.34, y: c.y - r * 0.40)
                ctx.fill(blob, with: .radialGradient(
                    Gradient(stops: [
                        .init(color: tone.core, location: 0),
                        .init(color: tone.body, location: 0.42),
                        .init(color: tone.deep, location: 1),
                    ]),
                    center: light, startRadius: 0, endRadius: r * 1.75))

                // 4. 内部流光：两团慢速游走的柔光，被球体裁切
                var inner = ctx
                inner.clip(to: blob)
                inner.addFilter(.blur(radius: r * 0.24))
                let drift = mood == .working ? 1.5 : 0.45 + level * 0.9
                for i in 0..<2 {
                    let a = t * drift * (i == 0 ? 1 : -0.7) + Double(i) * 2.4
                    let d = r * (0.36 + 0.10 * sin(t * 0.8 + Double(i)))
                    let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
                    let pr = r * (i == 0 ? 0.52 : 0.40)
                    inner.fill(Path(ellipseIn: CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2)),
                               with: .color((i == 0 ? tone.core : tone.body).opacity(i == 0 ? 0.30 + level * 0.30 : 0.45)))
                }

                // 5. 背光侧压暗，做出体积
                var shade = ctx
                shade.clip(to: blob)
                shade.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.2, y: c.y - r * 1.2, width: r * 2.4, height: r * 2.4)),
                           with: .radialGradient(
                            Gradient(colors: [.clear, .clear, .black.opacity(0.34)]),
                            center: light, startRadius: r * 0.5, endRadius: r * 1.9))

                // 6. 受光边：在听时随人声变亮，告诉他「听到了」
                let rim = mood == .listening ? 0.22 + level * 0.70 : mood == .speaking ? 0.38 : 0.16
                ctx.stroke(blob, with: .linearGradient(
                    Gradient(colors: [.white.opacity(rim), tone.core.opacity(rim * 0.25), .clear]),
                    startPoint: CGPoint(x: c.x - r, y: c.y - r),
                    endPoint: CGPoint(x: c.x + r * 0.7, y: c.y + r * 0.9)),
                           lineWidth: 1.4)
            }
        }
        .onChange(of: bargeInTriggerCount) { _, new in
            if new > 0 { rippleStart = Date() }
        }
        .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: phase)
    }

    /// 低阶谐波叠出来的有机轮廓，用二次曲线连成平滑闭合路径。
    private static func blob(center: CGPoint, radius: Double, t: Double, amplitude: Double) -> Path {
        let n = 48
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            let th = Double(i) / Double(n) * .pi * 2
            let off = amplitude * (0.55 * sin(2 * th + t) + 0.30 * sin(3 * th - t * 1.4 + 1.3) + 0.15 * sin(5 * th + t * 2.1))
            let rr = radius + off
            pts.append(CGPoint(x: center.x + cos(th) * rr, y: center.y + sin(th) * rr))
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var path = Path()
        path.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n {
            path.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i])
        }
        path.closeSubpath()
        return path
    }
}
