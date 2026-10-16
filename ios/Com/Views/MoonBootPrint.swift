import SwiftUI

// 轨道 r2-pages：「下一步」的 tab 图标 —— 一枚宇航员靴印（登月那种横纹鞋底的单个脚印），寓意「下一步」。
// 线宽、视觉重量对齐 Dock 里其他 SF Symbol（18pt semibold ≈ 1.8pt 线）；没选中只描边，选中时鞋底填上一层淡色，
// 并像盖章一样踩下去（动效库 03-badge-stamp：从大到小、带一点旋转盖入，back.out 回弹）。

/// 靴底轮廓：一只左脚的靴印——前掌圆宽、内侧足弓内收、外侧近乎笔直、后跟圆；单位坐标按 rect 缩放。
/// 内侧足弓那一下凹是「脚印」而不是「灯泡」的关键：两侧对称收腰会被看成灯泡。
struct BootSoleShape: Shape {
    func path(in rect: CGRect) -> Path {
        // 横向收窄到 0.8：靴印是细长的一条，太宽会读成豆子 / 灯泡（复验修：r2-review-pages）。
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (0.5 + (x - 0.5) * 0.8) * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        path.move(to: p(0.52, 0.03))
        path.addCurve(to: p(0.79, 0.34), control1: p(0.74, 0.03), control2: p(0.80, 0.18))
        path.addCurve(to: p(0.72, 0.80), control1: p(0.78, 0.52), control2: p(0.73, 0.66))
        path.addCurve(to: p(0.50, 0.97), control1: p(0.71, 0.93), control2: p(0.62, 0.97))
        path.addCurve(to: p(0.31, 0.80), control1: p(0.38, 0.97), control2: p(0.30, 0.92))
        path.addCurve(to: p(0.36, 0.50), control1: p(0.32, 0.66), control2: p(0.39, 0.60))
        path.addCurve(to: p(0.23, 0.26), control1: p(0.33, 0.41), control2: p(0.22, 0.38))
        path.addCurve(to: p(0.52, 0.03), control1: p(0.24, 0.11), control2: p(0.36, 0.03))
        path.closeSubpath()
        return path
    }
}

/// 鞋底横纹：登月靴那种一道道贯穿鞋底的横棱，画满宽度，再用鞋底轮廓裁掉两端。
struct BootTreadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for y in [0.17, 0.29, 0.41, 0.55, 0.69, 0.83] as [CGFloat] {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + y * rect.height))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + y * rect.height))
        }
        return path
    }
}

/// 靴印图标。selected 时淡色填底 + 盖章动效。
struct BootPrintGlyph: View {
    var selected = false
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let line = StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round)
        ZStack {
            BootSoleShape().fill(.foreground.opacity(selected ? 0.2 : 0))
            BootTreadShape().stroke(style: StrokeStyle(lineWidth: size * 0.06)).mask(BootSoleShape())
            BootSoleShape().stroke(style: line)
        }
        .frame(width: size, height: size)
        // 斜着踩一步，比竖直的鞋底更像「迈出去」，也更接近其他图标的方形占位。
        .rotationEffect(.degrees(-20))
        .keyframeAnimator(initialValue: StampPose(), trigger: selected) { view, value in
            view.scaleEffect(value.scale).rotationEffect(.degrees(value.angle))
        } keyframes: { _ in
            // 03-badge-stamp：大 → 压过头 → 回正。只在被选中那一下踩，减弱动态效果时不动。
            KeyframeTrack(\.scale) {
                if selected && !reduce {
                    CubicKeyframe(1.35, duration: 0.08)
                    SpringKeyframe(0.9, duration: 0.14, spring: .snappy)
                    SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                } else {
                    LinearKeyframe(1, duration: 0.01)
                }
            }
            KeyframeTrack(\.angle) {
                if selected && !reduce {
                    CubicKeyframe(-14, duration: 0.08)
                    SpringKeyframe(0, duration: 0.42, spring: .bouncy)
                } else {
                    LinearKeyframe(0, duration: 0.01)
                }
            }
        }
        .accessibilityHidden(true)
    }
    private struct StampPose { var scale: CGFloat = 1; var angle: Double = 0 }
}

/// Dock 用的 tab 图标：「下一步」是自绘靴印，其余仍是 SF Symbol。
struct TabGlyph: View {
    let tab: SectionTab
    let selected: Bool
    var body: some View {
        if tab == .next { BootPrintGlyph(selected: selected) } else { Image(systemName: tab.symbol) }
    }
}
