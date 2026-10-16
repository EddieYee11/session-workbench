import SwiftUI
import ComCore

struct AgentStageView: View {
    var on: SectionTab = .chat
    var paused = false
    var onClose: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var scene
    @State private var entranceFinished = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var stage: AgentStageModel { model.stage }
    private var allowed: Bool { !reduce && !lowPower && scene == .active && model.tab == on }
    private var animating: Bool { stage.state.isBusy || stage.state == .delivered || (!entranceFinished && (stage.state == .failed || stage.state == .idle || stage.state == .review)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("COM 的小工位").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.2)
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "chevron.up").font(.system(size: 13, weight: .medium)).frame(width: 44,height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("收起工作舞台").accessibilityIdentifier("agent-stage-close")
                }
            }.foregroundStyle(Palette.textTertiary).padding(.leading, 20).padding(.trailing, 8)
            TimelineView(.animation(minimumInterval: 1.0/30, paused: !allowed || paused || !animating)) { timeline in
                AgentStageScene(state: stage.state, elapsed: max(0,timeline.date.timeIntervalSince(stage.changedAt)), moving: allowed, preview: stage.preview)
            }.frame(height: 152).padding(.horizontal, 8)
            HStack {
                Text("工作台")
                Spacer()
                Text("出品台")
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.textTertiary)
                .padding(.leading, 32).padding(.trailing, 24).padding(.top, -7).padding(.bottom, 8)
            HStack(spacing: 8) {
                Image(systemName: stage.state.symbol).font(.system(size: 12)).frame(width: 15)
                Text(stage.state.title).font(TypeScale.footnote).lineLimit(2).accessibilityIdentifier("agent-stage-status")
                if let attempt = stage.retryCount, attempt > 0 { Text("第 \(attempt) 次重试").font(TypeScale.footnote) }
                Spacer(minLength: 0)
                if stage.state == .review {
                    Button("去看看") { model.tab = .tasks }.buttonStyle(.quiet)
                } else if [.delivered, .idle].contains(stage.state), !stage.deliveryID.isEmpty {
                    Button("查看回复") { Task { await model.locateMessage(stage.deliveryID) } }
                        .buttonStyle(.quiet).accessibilityIdentifier("agent-stage-delivery")
                }
            }.foregroundStyle(Palette.textSecondary).frame(minHeight: 38).padding(.horizontal, 18).padding(.bottom, 5)
        }
        .background(Palette.surface, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius:22).stroke(Palette.separator.opacity(0.5),lineWidth:0.5))
        .padding(.horizontal, on == .chat ? Layout.margin : 0).padding(.bottom, on == .chat ? 8 : 0)
        .task(id: stage.changedAt) {
            entranceFinished = false
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { entranceFinished = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .accessibilityElement(children: .contain)
    }
}

/// The pull zone stays visible while the detailed stage is tucked away.
struct AgentStageHeader: View {
    let onPull: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MainMenu().frame(width: 48, height: 48)
                Spacer(minLength: 0)
                CompanionTitle()
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Button("搜索聊天与成果", systemImage: "magnifyingglass") { model.showSearch = true }
                    Button("设置与连接", systemImage: "slider.horizontal.3") { model.showSettings = true }
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 18))
                .buttonStyle(.plain)
                .frame(height: 48)
            }
            .padding(.horizontal, Layout.margin)
            MiniStageRunner(state: model.stage.state)
                .frame(height: 26)
                .padding(.horizontal, Layout.margin + 10)
        }
        .padding(.top, 4)
        .padding(.bottom, 3)
        .background(Palette.background)
        .overlay(alignment: .bottom) { Palette.separator.frame(height: 0.5) }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { value in
            guard value.translation.height > 42,
                  abs(value.translation.height) > abs(value.translation.width) * 1.25 else { return }
            onPull()
        })
        .accessibilityIdentifier("agent-stage-pull-zone")
        .accessibilityAction(named: "展开工作舞台", onPull)
    }
}

private struct MiniStageRunner: View {
    let state: AgentStageState
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var scene
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var running: Bool { state.isBusy && !reduce && !lowPower && scene == .active }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30, paused: !running)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let reach = max(0, size.width / 2 - 26)
                let wave = running ? sin(t * 1.7) : 0
                let x = size.width / 2 + reach * wave
                let stride = running ? sin(t * 21) : 0
                let facing: CGFloat = running && cos(t * 1.7) < 0 ? -1 : 1
                var track = Path()
                track.move(to: CGPoint(x: 0, y: 22))
                track.addLine(to: CGPoint(x: size.width, y: 22))
                context.stroke(track, with: .color(Palette.separator), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
                var person = context
                person.translateBy(x: x, y: 11 - abs(stride) * 1.5)
                person.scaleBy(x: facing, y: 1)
                let blue = Color(red: 0.52, green: 0.64, blue: 0.94)
                let navy = Color(red: 0.18, green: 0.22, blue: 0.43)
                let ink = Color(red: 0.17, green: 0.19, blue: 0.20)
                func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: CGFloat) {
                    var path = Path(); path.move(to: a); path.addLine(to: b)
                    person.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
                line(CGPoint(x: -4, y: 7), CGPoint(x: -7 + stride * 4, y: 12), navy, 2)
                line(CGPoint(x: 4, y: 7), CGPoint(x: 7 - stride * 4, y: 12), navy, 2)
                line(CGPoint(x: -7, y: 0), CGPoint(x: -11 - stride * 3, y: 6), blue, 2)
                line(CGPoint(x: 7, y: 0), CGPoint(x: 11 + stride * 3, y: 6), blue, 2)
                person.fill(Path(roundedRect: CGRect(x: -9, y: -8, width: 18, height: 17), cornerRadius: 7), with: .color(blue))
                person.fill(Path(ellipseIn: CGRect(x: -10, y: -12, width: 20, height: 7)), with: .color(navy))
                person.fill(Path(roundedRect: CGRect(x: 3, y: -14, width: 3, height: 5), cornerRadius: 1), with: .color(navy))
                for eye: CGFloat in [-4, 3] {
                    person.fill(Path(roundedRect: CGRect(x: eye, y: -3, width: 2, height: 3), cornerRadius: 1), with: .color(ink))
                }
            }
        }
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}
