import SwiftUI
import Textual
import ComCore

private struct DetailSpaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues { var detailSpace: Namespace.ID? { get { self[DetailSpaceKey.self] } set { self[DetailSpaceKey.self] = newValue } } }
struct DetailSource: ViewModifier {
    @Environment(\.detailSpace) private var space
    let id: String
    @ViewBuilder func body(content: Content) -> some View { if let space { content.matchedTransitionSource(id: id, in: space) } else { content } }
}
extension View { func detailSource(_ id: String) -> some View { modifier(DetailSource(id: id)) } }

enum Palette {
    static let accent = Color(red: 0.82, green: 0.94, blue: 0.38)
    static let onAccent = Color(red: 0.09, green: 0.10, blue: 0.07)
    static let cyan = Color.primary
    static let violet = Color.primary
    static let coral = Color(red: 0.94, green: 0.43, blue: 0.34)
    static let ink = Color.primary
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : .white })
    static let raised = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.20, alpha: 1) : UIColor(red: 0.91, green: 0.89, blue: 0.85, alpha: 1) })
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.06, alpha: 1) : UIColor(red: 0.965, green: 0.957, blue: 0.933, alpha: 1) })
    static let landscape = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.14, alpha: 1) : UIColor(red: 0.89, green: 0.87, blue: 0.81, alpha: 1) })
    static let line = Color.primary.opacity(0.06)
    static let spectrum = [accent, Color(red: 0.73, green: 0.83, blue: 0.65), coral]
}

struct PageCanvas<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) { content }.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 24) }
            .background(Palette.canvas).scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
    }
}
struct SurfaceCard<Content: View>: View {
    var accent: Color = Palette.violet
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: .rect(cornerRadius: 24))
    }
}
struct Eyebrow: View {
    let text: String
    var body: some View { Text(text).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary) }
}
struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 28, weight: .bold)); if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) } } }
}
struct Pill: View {
    let text: String
    var color = Palette.violet
    var body: some View { Text(text).font(.caption.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 6).foregroundStyle(.primary).background(Palette.accent.opacity(0.25), in: .capsule) }
}
struct EmptyState: View {
    let title: String
    let description: String
    let symbol: String
    var body: some View { ContentUnavailableView(title, systemImage: symbol, description: Text(description)).frame(maxWidth: .infinity).padding(.vertical, 20) }
}
struct Freshness: View {
    @Environment(AppModel.self) private var model
    let path: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.errors[path] == nil ? Palette.cyan : Palette.coral).frame(width: 5, height: 5)
            if let error = model.errors[path] { Text(error).foregroundStyle(.secondary) }
            else if let date = model.fetchedAt[path] { Text("更新于 \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }
            else { Text("尚未读取").foregroundStyle(.secondary) }
        }.font(.caption).accessibilityElement(children: .combine)
    }
}
struct RichText: View {
    let text: String
    var body: some View {
        StructuredText(markdown: text)
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .font(.body).frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct RawDetails: View {
    let title: String
    let value: JSON
    var body: some View {
        DisclosureGroup(title) { Text(value.pretty).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
            .font(.subheadline).tint(.primary)
    }
}
func displayStatus(_ value: String) -> String {
    ["queued": "等待执行", "dispatching": "正在启动", "running": "执行中", "waiting": "等你回应", "unknown": "待核实",
     "execution_finished": "待验收", "completed": "已完成", "cancel_requested": "正在停止", "cancelled": "已取消", "failed": "失败",
     "paused": "已暂停", "accepted": "已受理", "stopped": "已停止", "idle": "空闲", "ended": "已结束"][value] ?? value
}
func eventLabel(_ event: JSON) -> String {
    for key in ["summary", "text", "title", "type", "kind"] { if !event[key].string.isEmpty { return event[key].string } }
    return "执行记录"
}
func agentName(_ value: String) -> String { ["hermes": "Hermes", "pi": "Pi", "claude": "Claude", "codex": "Codex"][value] ?? value }
func textContent(_ value: JSON) -> String {
    if case .string = value { return value.string }
    if case .array(let parts) = value { return parts.map { $0["text"].string }.joined(separator: "\n") }
    return value["text"].string
}

struct FlowGlow: View {
    var level: Double = 0.15
    var processing = false
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.accessibilityReduceTransparency) private var opaque
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduce)) { timeline in
            let t = reduce ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let height = size.height * (0.08 + min(1, level) * 0.60)
                for i in 0..<5 {
                    let phase = t * (processing ? 1.7 : 0.65) + Double(i) * 1.4
                    let x = size.width * (0.5 + sin(phase) * 0.34)
                    let rect = CGRect(x: x - size.width * 0.24, y: size.height - height * (1 + Double(i % 2) * 0.3), width: size.width * 0.48, height: height * 1.6)
                    var layer = context
                    layer.addFilter(.blur(radius: opaque ? 0 : 14))
                    layer.fill(Path(ellipseIn: rect), with: .color(Palette.spectrum[i % 3].opacity(opaque ? 0.35 : 0.6)))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A sculpted coral crab keeps the existing Hermes identity while gaining fluid motion.
struct Companion: View {
    var state = "陪伴"
    var compact = false
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.colorScheme) private var colorScheme
    @State private var drag = CGSize.zero
    @State private var touched = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.active || reduce)) { timeline in
            let t = reduce ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let breathe = 1 + sin(t * 1.8) * (compact ? 0.012 : 0.025)
            let blink = reduce ? 1.0 : (t.truncatingRemainder(dividingBy: 5.3) < 0.13 ? 0.12 : 1.0)
            GeometryReader { geometry in
                let w = geometry.size.width
                ZStack {
                    Ellipse().fill(Palette.violet.opacity(0.16)).frame(width: w * 0.58, height: w * 0.08).blur(radius: 10).offset(y: w * 0.34)
                    if !compact {
                        Circle().stroke(Palette.violet.opacity(0.10), lineWidth: 1).frame(width: w * 0.92)
                        Circle().stroke(Palette.cyan.opacity(0.13), lineWidth: 1).frame(width: w * 0.73)
                        ForEach(0..<3) { i in
                            Circle().fill(Palette.spectrum[i]).frame(width: 4 + CGFloat(i), height: 4 + CGFloat(i))
                                .offset(x: cos(t * 0.4 + Double(i) * 2.1) * w * 0.4, y: sin(t * 0.4 + Double(i) * 2.1) * w * 0.4)
                        }
                    }
                    ZStack {
                        ForEach([-1, 1], id: \.self) { side in
                            ForEach(0..<3) { i in
                                Capsule().fill(Palette.coral.gradient).frame(width: w * 0.16, height: w * 0.055)
                                    .rotationEffect(.degrees(Double(side) * (15 + Double(i) * 23)))
                                    .offset(x: CGFloat(side) * w * 0.25, y: w * (0.04 + CGFloat(i) * 0.06))
                            }
                            RoundedRectangle(cornerRadius: w * 0.045).fill(Palette.coral.gradient)
                                .frame(width: w * 0.11, height: w * 0.19)
                                .rotationEffect(.degrees(Double(side) * (state == "思考" ? 42 + sin(t * 3) * 10 : 27)))
                                .offset(x: CGFloat(side) * w * 0.27, y: -w * 0.105)
                            Circle().fill(Palette.coral.gradient).frame(width: w * 0.15).offset(x: CGFloat(side) * w * 0.31, y: -w * 0.2)
                            Capsule().fill(Palette.canvas).frame(width: w * 0.025, height: w * 0.10)
                                .rotationEffect(.degrees(Double(side) * 24)).offset(x: CGFloat(side) * w * 0.315, y: -w * 0.225)
                        }
                        RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                            .fill(LinearGradient(colors: [Palette.coral.opacity(0.9), Palette.coral, Color(red: 0.72, green: 0.22, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: w * 0.53, height: w * 0.38)
                            .overlay(alignment: .topLeading) { Ellipse().fill(.white.opacity(0.3)).frame(width: w * 0.30, height: w * 0.065).blur(radius: 5).offset(x: w * 0.09, y: w * 0.035) }
                            .shadow(color: Palette.coral.opacity(0.20), radius: 15, y: 7)
                        HStack(spacing: w * 0.11) {
                            ForEach(0..<2) { _ in
                                ZStack {
                                    Capsule().fill(.white.opacity(0.95)).frame(width: w * 0.085, height: w * 0.12)
                                    Capsule().fill(Color.black.opacity(0.85)).frame(width: w * 0.032, height: w * 0.064)
                                        .offset(x: min(w * 0.017, max(-w * 0.017, drag.width * 0.08)), y: state == "思考" ? -w * 0.015 : 0)
                                    Circle().fill(.white).frame(width: w * 0.012).offset(x: -w * 0.008, y: -w * 0.016)
                                }.scaleEffect(y: blink)
                            }
                        }.offset(y: -w * 0.025)
                        Capsule().fill(Color.black.opacity(0.65)).frame(width: w * 0.055, height: w * 0.012).offset(y: w * 0.07)
                    }
                    .scaleEffect(x: breathe + (touched ? 0.08 : 0), y: 1 / breathe - (touched ? 0.06 : 0))
                    .rotationEffect(.degrees(Double(drag.width) * 0.08))
                    .offset(x: drag.width * 0.15, y: drag.height * 0.12 + (reduce ? 0 : sin(t * 1.8) * w * 0.012))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in drag = value.translation; touched = true }.onEnded { _ in
            withAnimation(reduce ? .linear(duration: 0.12) : .spring(response: 0.45, dampingFraction: 0.63)) { drag = .zero; touched = false }
            Haptics.selection()
        })
        .accessibilityElement(children: .ignore).accessibilityLabel("Com 珊瑚螃蟹，\(state)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Haptics.selection() }
    }
}


struct CompanionPortrait: View {
    var size: CGFloat = 76
    var body: some View {
        Image("CompanionPortrait").resizable().scaledToFill()
            .frame(width: size, height: size).clipShape(.circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct CompanionHeader: View {
    @Environment(AppModel.self) private var model
    private var status: String {
        if model.roleState != "陪伴" { return model.activeRuns.first?["phase"].string.nonEmpty ?? model.roleState }
        return model.streaming ? "随时在这里" : "离线 · 已保存的内容"
    }
    var body: some View {
        HStack(spacing: 10) {
                Menu {
                    Button("搜索聊天与成果", systemImage: "magnifyingglass") { model.showSearch = true }
                    Button("工作记录", systemImage: "clock.arrow.circlepath") { model.tab = .work }
                    Button("分享收件箱", systemImage: "tray") { model.showShareInbox = true }
                    Button("设置与连接", systemImage: "slider.horizontal.3") { model.showSettings = true }
                } label: { CompanionPortrait(size: 32).frame(width: 44, height: 44) }
                .accessibilityLabel("主菜单")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Com").font(.subheadline.weight(.semibold))
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { model.showSearch = true } label: { Image(systemName: "magnifyingglass").font(.system(size: 17)).frame(width: 40, height: 40).background(Palette.surface, in: .circle) }.accessibilityLabel("搜索聊天与成果")
                Button { model.showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 17)).frame(width: 40, height: 40).background(Palette.surface, in: .circle) }
                    .accessibilityLabel("设置与连接")
        }.buttonStyle(.plain).foregroundStyle(.primary).padding(.horizontal, 16).padding(.bottom, 2)
            .background(Palette.canvas)
    }
}

struct ComDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Namespace private var selection
    var body: some View {
        HStack(spacing: 2) {
            ForEach(SectionTab.allCases) { tab in
                Button {
                    withAnimation(reduce ? nil : .spring(response: 0.32, dampingFraction: 0.86)) { model.tab = tab }
                } label: {
                    Image(systemName: tab.symbol).font(.system(size: 21, weight: model.tab == tab ? .semibold : .regular))
                        .frame(width: 46, height: 46)
                        .background {
                            if model.tab == tab { Circle().fill(Palette.accent).matchedGeometryEffect(id: "selected-tab", in: selection) }
                        }.frame(maxWidth: .infinity).contentShape(.rect)
                }.buttonStyle(.plain).foregroundStyle(model.tab == tab ? Palette.onAccent : Color.secondary)
                    .accessibilityLabel(tab == .work ? "Com" : tab.rawValue)
                    .accessibilityIdentifier("tab-" + tab.id)
                    .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                    .help(tab == .work ? "Com · 工作记录" : tab.rawValue)
            }
        }.padding(7)
            .background(Palette.surface.opacity(opaque ? 1 : 0.97), in: .capsule)
            .shadow(color: .black.opacity(0.07), radius: 20, y: 5)
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 5)
    }
}

struct InlineSearch: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清除搜索") }
        }.padding(.horizontal, 16).padding(.vertical, 14)
            .background(Palette.surface, in: .capsule)
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

struct ChatCompanionStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ZStack(alignment: .bottom) {
            Canvas { context, size in
                for i in 0..<2 {
                    var ridge = Path(); ridge.move(to: CGPoint(x: 0, y: size.height))
                    for j in 0...12 {
                        let x = size.width * CGFloat(j) / 12
                        let y = size.height * (0.60 + sin(Double(j) * 1.5 + Double(i)) * 0.13 + Double(i) * 0.17)
                        ridge.addLine(to: CGPoint(x: x, y: y))
                    }
                    ridge.addLine(to: CGPoint(x: size.width, y: size.height)); ridge.closeSubpath()
                    context.fill(ridge, with: .color(Palette.landscape.opacity(i == 0 ? 0.50 : 0.85)))
                }
            }.accessibilityHidden(true)
            Companion(state: model.roleState, compact: true).frame(width: 104, height: 104).offset(y: -3)
        }.frame(height: typeSize.isAccessibilitySize ? 70 : 105).clipped().background(Palette.canvas)
    }
}

struct TodayFocusCard: View {
    let matter: JSON
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("为你整理").font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(Palette.accent, in: .capsule)
                    Text("今日焦点").font(.system(size: 24, weight: .bold))
                    Text(sourceName(matter["source"].string)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                CompanionPortrait(size: 85).rotationEffect(.degrees(-7))
            }.foregroundStyle(.primary).padding(20).frame(maxWidth: .infinity).background(Palette.raised.opacity(0.45))
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(matter["title"].string).font(.headline).lineLimit(2)
                    let summary = matter["why"].string.isEmpty ? matter["next_step"].string : matter["why"].string
                    if !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.onAccent).frame(width: 42, height: 42).background(Palette.accent, in: .circle)
            }.foregroundStyle(.white).padding(20).background(Color(red: 0.10, green: 0.11, blue: 0.09))
        }.clipShape(.rect(cornerRadius: 24)).multilineTextAlignment(.leading)
    }
}
