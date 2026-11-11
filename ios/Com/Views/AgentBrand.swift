import SwiftUI

// 轨道 r2-memory：Agent 用各家的真实图标（来源见 ios/scripts/agent-logos/NOTES.md），
// 底色以品牌色为基准降饱和——Claude 暖陶土、Codex 冷灰、Hermes Nous 浅靛、Pi 浅薄荷。
private func agentDynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    func ui(_ v: UInt32) -> UIColor { UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
    return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
}

struct AgentBrand {
    /// Assets.xcassets 里的单色蒙版（template）。
    let mark: String
    /// 图标与强调用的品牌色（已降饱和）。
    let ink: Color
    /// 头像底、页面氛围用的浅底。
    let wash: Color
    /// 图标在圆里的留白比例：线稿头像要更满，几何标要留气口。
    let inset: CGFloat
}

func agentBrand(_ agent: String) -> AgentBrand? {
    switch agent {
    case "claude": AgentBrand(mark: "AgentClaude", ink: agentDynamic(0xC15F3C, 0xE59A7C), wash: agentDynamic(0xF7EAE3, 0x3A2620), inset: 0.22)
    case "codex": AgentBrand(mark: "AgentCodex", ink: agentDynamic(0x23262B, 0xE6E8EB), wash: agentDynamic(0xEBECEF, 0x2A2C31), inset: 0.22)
    case "hermes": AgentBrand(mark: "AgentHermes", ink: agentDynamic(0x3F3A8F, 0xC6C1FF), wash: agentDynamic(0xECEAFA, 0x272442), inset: 0.10)
    case "pi": AgentBrand(mark: "AgentPi", ink: agentDynamic(0x1F6B57, 0x9BDFC5), wash: agentDynamic(0xE2F2EA, 0x1C302A), inset: 0.27)
    default: nil
    }
}

func agentTint(_ agent: String) -> Color { agentBrand(agent)?.ink ?? Palette.textSecondary }

/// Agent 的真实图标（单色，按品牌色上色）。
struct AgentMark: View {
    let agent: String
    var body: some View {
        if let brand = agentBrand(agent) {
            Image(brand.mark).renderingMode(.template).resizable().interpolation(.high).scaledToFit().foregroundStyle(brand.ink)
        } else {
            Image(systemName: "square.grid.2x2").resizable().scaledToFit().foregroundStyle(Palette.textPrimary)
        }
    }
}

/// Agent 头像：品牌浅底的圆，里面是它的真实图标。
/// 换 Agent 时像贴纸一样「盖」上来——动效库 03-badge-stamp（徽章从 1.75 倍、-8.7° 旋转甩进来摊平贴住），
/// 手机上收成 1.3 倍 / -9° → 0.96 → 1 的三段弹簧，reduce motion 时只淡入。
struct AgentAvatar: View {
    let agent: String
    var size: CGFloat = 36
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let brand = agentBrand(agent)
        AgentMark(agent: agent)
            .padding(size * (brand?.inset ?? 0.28))
            .frame(width: size, height: size)
            .background(brand?.wash ?? Palette.fill, in: .circle)
            .overlay(Circle().strokeBorder((brand?.ink ?? Palette.textPrimary).opacity(0.10), lineWidth: 0.5))
            .clipShape(.circle)
            .modifier(AgentStampMotion(trigger: agent, reduce: reduce))
            .accessibilityHidden(true)
    }
}

struct AgentStampPose { var scale: CGFloat = 1; var angle: Double = 0 }

/// 把 reduce 作为普通 Bool 传入 keyframe 闭包，避免捕获 `@Environment` 主线程隔离属性。
struct AgentStampMotion: ViewModifier {
    let trigger: String
    let reduce: Bool
    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: AgentStampPose(), trigger: trigger) { view, pose in
            view.scaleEffect(reduce ? 1 : pose.scale).rotationEffect(.degrees(reduce ? 0 : pose.angle))
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.3, duration: 0.001)
                SpringKeyframe(0.96, duration: 0.16, spring: .snappy)
                SpringKeyframe(1, duration: 0.24, spring: .bouncy)
            }
            KeyframeTrack(\.angle) {
                CubicKeyframe(-9, duration: 0.001)
                SpringKeyframe(2, duration: 0.16, spring: .snappy)
                SpringKeyframe(0, duration: 0.24, spring: .smooth)
            }
        }
    }
}
