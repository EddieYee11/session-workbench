import SwiftUI
import ComCore

/// One bounded transition per real state change; no idle rendering loop.
struct AgentStageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var scene
    @AppStorage("agentStageExpanded") private var expanded = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var state: AgentStageState {
        .resolve(runs: model.conversation.runs, tasks: model.conversation.tasks,
                 messages: model.conversation.messages, connected: model.streaming)
    }
    private var moving: Bool { !reduce && !lowPower && scene == .active }
    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(moving ? .easeInOut(duration: 0.25) : nil) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: state.symbol).frame(width: 20)
                    Text(state.title).font(TypeScale.footnote).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }.foregroundStyle(Palette.textSecondary).padding(.horizontal, Layout.margin).frame(height: 44)
            }.buttonStyle(.plain).accessibilityIdentifier("agent-stage-toggle")
            if expanded {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        Path { path in
                            path.move(to: CGPoint(x: 36, y: 82))
                            path.addLine(to: CGPoint(x: geometry.size.width - 36, y: 82))
                        }.stroke(Palette.textTertiary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                        HStack {
                            Label("工作台", systemImage: "laptopcomputer")
                            Spacer()
                            Label("回复", systemImage: "tray")
                        }.font(.caption2).foregroundStyle(Palette.textTertiary)
                        face
                            .position(x: state == .delivered ? geometry.size.width - 48 : 48, y: 47)
                            .animation(moving ? .easeInOut(duration: 0.6) : nil, value: state)
                    }
                }.frame(height: 112).padding(.horizontal, Layout.margin + 12).padding(.bottom, 10)
                if state == .review {
                    Button("查看待确认事项") { model.tab = .tasks }.buttonStyle(.secondaryAction).padding(.bottom, 12)
                }
            }
        }
        .background(Palette.background)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        .onChange(of: state) { old, next in
            if next == .review && old != .review { expanded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
    private var face: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 23).fill(Color(red: 0.76, green: 0.86, blue: 0.98)).frame(width: 62, height: 58)
            RoundedRectangle(cornerRadius: 20).fill(.white).frame(width: 51, height: 46).offset(x: -9, y: 5)
            HStack(spacing: 10) {
                Capsule().frame(width: 4, height: state == .idle ? 2 : 9)
                Capsule().frame(width: 4, height: state == .idle ? 2 : 9)
            }.foregroundStyle(Color.black.opacity(0.8)).offset(x: -25, y: 23)
            Image(systemName: state.symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.textPrimary).padding(6).background(Palette.background, in: .circle)
                .offset(x: 13, y: -14)
        }.rotationEffect(.degrees(state == .thinking ? -7 : state == .failed ? 5 : 0))
            .accessibilityHidden(true)
    }
}
