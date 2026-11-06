import SwiftUI
import ComCore

/// 工作 Tab 只有两面：对话（派活）和终端（herdr 队列 + 真 PTY）。2026-11-03 起「运行」面已移除（代码在 _archive/ios-removed-20261103/）。

enum WorkSurface: String, CaseIterable, Identifiable {
    case sessions, terminal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: return "对话"
        case .terminal: return "终端"
        }
    }
}

struct WorkSurfacePicker: View {
    @Binding var surface: WorkSurface
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var workSurfaceNS
    var body: some View {
        HStack(spacing: 4) {
            ForEach(WorkSurface.allCases) { item in
                Button {
                    Haptics.selection()
                    withAnimation(reduce ? .easeOut(duration: 0.15) : ComMotion.snap) { surface = item }
                } label: {
                    Text(item.title)
                        .font(TypeScale.subheadline.weight(.semibold))
                        .foregroundStyle(surface == item ? Palette.onAccent : Palette.textSecondary)
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
