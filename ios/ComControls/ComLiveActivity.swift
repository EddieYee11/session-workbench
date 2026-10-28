import ActivityKit
import SwiftUI
import WidgetKit

// 轨道 r3-memory + r4 增强：灵动岛常驻的 Com。
// r4 新增：休息状态动画（呼吸缩放 + 微光效果）、展开视图工作台预览、语音快捷按钮。
// 人物就是 App 图标那个青柠圆里的线稿女孩（Assets 里的 ComAvatar，取自图标母版）。
// compact：左边头像（休息时呼吸动画）；右边「下一步现在该做」的件数，在跑就走秒。
// 10-25：去掉「等你」计数（过期待办只增不减、Eddie 不用）；点灵动岛直接进下一步，展开后可去聊天或记一笔。
// minimal：头像（休息时呼吸动画）。
// expanded：工作台预览 + 一行状态说明 + 三个计数 + 走秒 + 「打开 Com」按钮 + 语音快捷按钮。
// 动画原则（从动效库移植）：
// - 呼吸缩放：scale 0.92→1.0，ease-in-out，2.4s 循环
// - 微光效果：opacity 0.3→0.7 渐变叠加，相位偏移 0.6s
// - 展开过渡：spring(response: 0.6, dampingFraction: 0.75) 弹性动画
// - 按钮点击：scale + opacity 反馈
// iOS 26.3 模拟器实测：repeating 的 symbolEffect（如 .pulse）在 Live Activity 里不动，值触发的 .bounce 也没看到；
// 只有换图标时 contentTransition(.symbolEffect(.replace)) 有过渡，所以只留它。
// 免费账号没有 APNs，App 被挂起后内容停在最后一次；超过 staleDate 系统标过时，这里改说「点开看最新」。

private enum LiveInk {
    static let lime = Color(red: 0.82, green: 0.94, blue: 0.38)
    static let ink = Color(red: 0.106, green: 0.11, blue: 0.094)
    static let coral = Color(red: 0.94, green: 0.43, blue: 0.34)
    static let dim = Color.white.opacity(0.62)
    static let glow = Color(red: 0.82, green: 0.94, blue: 0.38).opacity(0.4)
}

private extension ComActivityAttributes.ContentState {
    var symbol: String {
        switch mood {
        case "read": "magnifyingglass"
        case "think": "ellipsis"
        case "exec": "keyboard"
        case "send": "paperplane.fill"
        case "ask": "hand.raised.fill"
        case "done": "checkmark"
        case "broken": "exclamationmark.triangle.fill"
        default: "moon.zzz.fill"
        }
    }
    var tint: Color { mood == "broken" ? LiveInk.coral : LiveInk.lime }
    var busy: Bool { since != nil }
    var isResting: Bool { mood == "idle" && !busy && urgent == 0 }
    /// 点灵动岛 / 锁屏卡：进下一步（Eddie 用得最多）。
    var link: URL { URL(string: "com-eddie://plan")! }
    /// 回主对话（com-eddie://today 在 App 里落到聊天页）。
    var chatLink: URL { URL(string: "com-eddie://today")! }
    var voiceLink: URL { URL(string: "com-eddie://voice")! }
}

struct ComLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ComActivityAttributes.self) { context in
            LockScreenLive(state: context.state, stale: context.isStale)
                .activityBackgroundTint(LiveInk.ink.opacity(0.94))
                .activitySystemActionForegroundColor(LiveInk.lime)
                .widgetURL(context.state.link)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveAvatar(size: 50, ring: state.tint, isResting: state.isResting)
                        .padding(.leading, 4).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedBadge(state: state, stale: context.isStale)
                        .padding(.trailing, 4).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Com").font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(LiveInk.lime)
                        Caption(text: context.isStale ? "可能有新进展，点开看最新" : state.caption, size: 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        // 工作台预览卡片
                        WorkspacePreview(state: state)

                        HStack(alignment: .center, spacing: 10) {
                            LiveCounts(state: state)
                            Spacer(minLength: 0)

                            // 记一笔：记账占日常消息四成，直接开快捷语音
                            Link(destination: state.voiceLink) {
                                Image(systemName: "yensign.circle")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 32)
                                    .background(.white.opacity(0.14), in: .circle)
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .accessibilityLabel("记一笔")

                            // 聊天
                            Link(destination: state.chatLink) {
                                Image(systemName: "bubble.left.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 32)
                                    .background(.white.opacity(0.14), in: .circle)
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .accessibilityLabel("聊天")

                            // 下一步
                            Link(destination: state.link) {
                                HStack(spacing: 4) {
                                    Text("下一步")
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(LiveInk.ink)
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(LiveInk.lime, in: .capsule)
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }
                    .padding(.horizontal, 4).padding(.top, 6)
                }
            } compactLeading: {
                LiveAvatar(size: 24, isResting: state.isResting)
            } compactTrailing: {
                CompactStatus(state: state, stale: context.isStale)
            } minimal: {
                LiveAvatar(size: 22, ring: state.urgent > 0 ? LiveInk.lime : nil, isResting: state.isResting)
            }
            .widgetURL(state.link)
            .keylineTint(LiveInk.lime)
        }
    }
}

/// 青柠圆里的线稿女孩；休息时呼吸动画；需要提醒时外面一圈青柠描边。
private struct LiveAvatar: View {
    let size: CGFloat
    var ring: Color? = nil
    var isResting: Bool = false

    @State private var breathPhase: CGFloat = 0
    @State private var glowPhase: CGFloat = 0

    var body: some View {
        ZStack {
            // 微光背景层（休息时）
            if isResting {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [LiveInk.glow, .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.8
                        )
                    )
                    .frame(width: size * 1.4, height: size * 1.4)
                    .opacity(0.3 + glowPhase * 0.4)
            }

            // 头像主体
            Image("ComAvatar").resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.circle)
                .scaleEffect(isResting ? (0.92 + breathPhase * 0.08) : 1.0)
                .overlay {
                    if let ring {
                        Circle()
                            .strokeBorder(ring, lineWidth: max(1.5, size * 0.05))
                            .padding(-max(1.5, size * 0.05) - 1.5)
                    }
                }
        }
        .accessibilityLabel("Com")
        .onAppear {
            if isResting {
                startBreathingAnimation()
            }
        }
        .onChange(of: isResting) { _, newValue in
            if newValue {
                startBreathingAnimation()
            }
        }
    }

    private func startBreathingAnimation() {
        // 呼吸动画：2.4s 循环，ease-in-out
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            breathPhase = 1.0
        }
        // 微光动画：相位偏移 0.6s
        withAnimation(.easeInOut(duration: 2.4).delay(0.6).repeatForever(autoreverses: true)) {
            glowPhase = 1.0
        }
    }
}

/// 工作台预览卡片：显示状态与任务概览
private struct WorkspacePreview: View {
    let state: ComActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            // 状态指示器
            ZStack {
                Circle()
                    .fill(state.tint.opacity(0.2))
                    .frame(width: 40, height: 40)
                Image(systemName: state.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.tint)
                    .contentTransition(.symbolEffect(.replace))
            }

            // 任务概览
            VStack(alignment: .leading, spacing: 2) {
                Text(state.busy ? "正在处理" : state.urgent > 0 ? "下一步" : "待命中")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(LiveInk.dim)

                HStack(spacing: 6) {
                    if state.running > 0 {
                        Label("\(state.running)", systemImage: "gearshape.fill")
                    }
                    if state.urgent > 0 {
                        Label("\(state.urgent)", systemImage: "exclamationmark.circle.fill")
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LiveInk.ink.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(LiveInk.lime.opacity(0.3), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.6, dampingFraction: 0.75), value: state)
    }
}

/// 按钮缩放点击反馈样式
private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 一行状态说明：换句时新的从下面推上来。
private struct Caption: View {
    let text: String
    var size: CGFloat = 16
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.8)
            .id(text)
            .transition(.push(from: .bottom))
    }
}

/// compact 右边：先说下一步现在该做的件数；没有就在跑时走秒；都没有就一个状态小图标。
private struct CompactStatus: View {
    let state: ComActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        Group {
            if state.urgent > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "shoeprints.fill").font(.system(size: 11, weight: .bold))
                    Text("\(state.urgent)").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(state.urgent)))
                }
                .foregroundStyle(LiveInk.lime)
                .transition(.push(from: .bottom))
            } else if let since = state.since, !stale {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(LiveInk.lime)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 46, alignment: .trailing)
                    .transition(.push(from: .bottom))
            } else {
                Image(systemName: state.symbol).font(.system(size: 13, weight: .bold))
                    .foregroundStyle(state.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.push(from: .bottom))
            }
        }
        .animation(.spring(duration: 0.45), value: state)
    }
}

/// expanded 右上：在跑就是走秒，否则是状态图标。
private struct ExpandedBadge: View {
    let state: ComActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let since = state.since, !stale {
                Text("在跑").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(LiveInk.dim)
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(LiveInk.lime)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 76, alignment: .trailing)
            } else {
                Image(systemName: state.symbol).font(.system(size: 20, weight: .bold))
                    .foregroundStyle(state.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .background(state.tint.opacity(0.16), in: .circle)
            }
        }
        .animation(.spring(duration: 0.45), value: state)
    }
}

/// 两个计数：在跑 · 该做；数字变了按位滚动。
private struct LiveCounts: View {
    let state: ComActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 14) {
            stat("在跑", state.running, lit: false)
            stat("该做", state.urgent, lit: state.urgent > 0)
        }
        .animation(.spring(duration: 0.45), value: state)
    }
    private func stat(_ label: String, _ value: Int, lit: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(value)").font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(lit ? LiveInk.lime : .white)
                .contentTransition(.numericText(value: Double(value)))
            Text(label).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(LiveInk.dim)
        }
    }
}

/// 锁屏：墨色底，左边头像，右边一行说明 + 三个计数，在跑时右上角走秒。
private struct LockScreenLive: View {
    let state: ComActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            LiveAvatar(size: 48, ring: state.urgent > 0 ? LiveInk.lime : nil, isResting: state.isResting)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Com").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(LiveInk.lime)
                    Spacer(minLength: 0)
                    if let since = state.since, !stale {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(LiveInk.lime)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70, alignment: .trailing)
                    } else {
                        Image(systemName: state.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(state.tint)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                Caption(text: stale ? "可能有新进展，点开看最新" : state.caption, size: 17)
                LiveCounts(state: state)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .animation(.spring(duration: 0.45), value: state)
    }
}
