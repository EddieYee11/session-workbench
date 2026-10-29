import SwiftUI
import ComCore

/// 双栏时右栏的标题栏（左栏的顶栏是她本人）：页名 + 右上那颗玻璃按钮；工作页像 ChatGPT——左边侧栏、标题点开换人。
struct PaneBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("work.lastAgent") private var lastAgent = "codex"
    let tab: SectionTab
    private var title: String {
        tab == .work ? agentName(model.work.mode == .home ? lastAgent : model.work.agent) : tab.rawValue
    }
    var body: some View {
        HStack(spacing: Space.sm) {
            if tab == .work {
                GlassIconButton(symbol: "sidebar.left", label: "历史对话") { model.openWorkSidebar(reduce: reduce) }
                    .accessibilityIdentifier("work-sidebar")
            }
            Text(title).font(TypeScale.headline).foregroundStyle(Palette.textPrimary).lineLimit(1)
                .contentTransition(.opacity)
                .overlay { if tab == .work { WorkTitleMenu() } }
            if tab == .work { Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.textSecondary).accessibilityHidden(true) }
            Spacer(minLength: 0)
            TopBarTrailing(tab: tab)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: Layout.topBar)
        .background {
            ZStack { Rectangle().fill(.ultraThinMaterial); Palette.background.opacity(0.72) }.ignoresSafeArea(edges: .top)
        }
        .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: title)
    }
}
