import SwiftUI
import ComCore

/// 工作 Tab 三面：对话（派活）、终端（herdr 队列 + 真 PTY）、搜狐（关注流自动转发可视化面板）。

enum WorkSurface: String, CaseIterable, Identifiable {
    case sessions, terminal, sohu
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: return "对话"
        case .terminal: return "终端"
        case .sohu: return "搜狐"
        }
    }
}

struct WorkSurfacePicker: View {
    @Binding var surface: WorkSurface
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var workSurfaceNS
    private var sohuBadge: Int {
        model.datasets["/personal/sohu-repost"]?["review_queue"].array.count ?? 0
    }
    var body: some View {
        HStack(spacing: 4) {
            ForEach(WorkSurface.allCases) { item in
                Button {
                    Haptics.selection()
                    withAnimation(reduce ? .easeOut(duration: 0.15) : ComMotion.snap) { surface = item }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(TypeScale.subheadline.weight(.semibold))
                            .foregroundStyle(surface == item ? Palette.onAccent : Palette.textSecondary)
                        if item == .sohu && sohuBadge > 0 {
                            Text("\(sohuBadge)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(surface == item ? Palette.accent : .white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(surface == item ? Palette.onAccent : Palette.warning, in: .capsule)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if surface == item {
                            Capsule().fill(Palette.accent)
                                .matchedGeometryEffect(id: "work-surface-pill", in: workSurfaceNS, properties: .frame, isSource: true)
                        }
                    }
                }
                .buttonStyle(SoftPressStyle(scale: 0.96))
                .accessibilityIdentifier("work-surface-\(item.rawValue)")
                .accessibilityAddTraits(surface == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.fill, in: .capsule)
        .padding(.horizontal, Layout.margin)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work-surface-picker")
    }
}
