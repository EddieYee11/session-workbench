import SwiftUI
import ComCore

// 手绘伙伴：顶栏角色条 + 下拉工作台（设计稿 Strip / Stage / C-08）。
// 线稿来自 Claude Design 的 SVG，按 120×132 的角色坐标系绘制；动作由真实事件驱动，不是装饰循环。

/// 顶栏角色的 8 个状态。
enum StripState: String, Equatable, Sendable { case idle, read, think, exec, send, ask, done, broken }

// MARK: - SVG path data → Path

enum SVGPath {
    nonisolated private static let cache = Cache()
    nonisolated private final class Cache: @unchecked Sendable {
        private var paths: [String: Path] = [:]
        private let lock = NSLock()
        func path(_ d: String) -> Path {
            lock.lock(); defer { lock.unlock() }
            if let cached = paths[d] { return cached }
            let parsed = SVGPath.parse(d); paths[d] = parsed; return parsed
        }
    }
    nonisolated static func path(_ d: String) -> Path { cache.path(d) }

    nonisolated static func parse(_ d: String) -> Path {
        enum Token { case command(Character), number(CGFloat) }
        var tokens: [Token] = []
        var buffer = ""
        func flush() { if let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }; buffer = "" }
        for character in d {
            if character.isLetter && character != "e" && character != "E" { flush(); tokens.append(.command(character)) }
            else if character == "-" && !buffer.isEmpty && !buffer.hasSuffix("e") { flush(); buffer = "-" }
            else if character == "." && buffer.contains(".") { flush(); buffer = "." }
            else if character == " " || character == "," || character == "\n" { flush() }
            else { buffer.append(character) }
        }
        flush()
        var path = Path()
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        var numbers: [CGFloat] = []
        func arity(_ c: Character) -> Int {
            switch c.uppercased().first! { case "M", "L", "T": 2; case "H", "V": 1; case "Q", "S": 4; case "C": 6; default: 0 }
        }
        func run() {
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased().first! {
            case "M":
                current = CGPoint(x: base.x + numbers[0], y: base.y + numbers[1]); start = current; path.move(to: current)
                command = relative ? "l" : "L"
            case "L": current = CGPoint(x: base.x + numbers[0], y: base.y + numbers[1]); path.addLine(to: current)
            case "H": current = CGPoint(x: base.x + numbers[0], y: current.y); path.addLine(to: current)
            case "V": current = CGPoint(x: current.x, y: base.y + numbers[0]); path.addLine(to: current)
            case "Q":
                let control = CGPoint(x: base.x + numbers[0], y: base.y + numbers[1])
                current = CGPoint(x: base.x + numbers[2], y: base.y + numbers[3]); path.addQuadCurve(to: current, control: control)
            case "C":
                let a = CGPoint(x: base.x + numbers[0], y: base.y + numbers[1]), b = CGPoint(x: base.x + numbers[2], y: base.y + numbers[3])
                current = CGPoint(x: base.x + numbers[4], y: base.y + numbers[5]); path.addCurve(to: current, control1: a, control2: b)
            default: break
            }
            numbers.removeAll(keepingCapacity: true)
        }
        for token in tokens {
            switch token {
            case .command(let c):
                if c == "Z" || c == "z" { path.closeSubpath(); current = start; numbers.removeAll() } else { command = c; numbers.removeAll() }
            case .number(let n):
                numbers.append(n)
                if numbers.count == arity(command) { run() }
            }
        }
        return path
    }
}

// MARK: - Keyframe helpers

nonisolated private func keyframe(_ values: [Double], _ times: [Double], dur: Double, t: Double, begin: Double = 0) -> Double {
    guard dur > 0, values.count == times.count, values.count > 1 else { return values.first ?? 0 }
    let local = (t - begin).truncatingRemainder(dividingBy: dur)
    let phase = (local < 0 ? local + dur : local) / dur
    for i in 1..<times.count where phase <= times[i] {
        let span = times[i] - times[i - 1]
        let f = span > 0 ? (phase - times[i - 1]) / span : 1
        return values[i - 1] + (values[i] - values[i - 1]) * f
    }
    return values.last ?? 0
}
nonisolated private func even(_ values: [Double], dur: Double, t: Double, begin: Double = 0) -> Double {
    keyframe(values, (0..<values.count).map { Double($0) / Double(values.count - 1) }, dur: dur, t: t, begin: begin)
}

// MARK: - Painter (角色坐标系 120×132)

struct CharacterPainter {
    let state: StripState
    let t: Double
    let moving: Bool
    let ink: Color
    let paper: Color
    let red: Color
    var sign = ""
    var danger: Color = Palette.danger
    /// 旁边有对话气泡时，不再画思考点（气泡本身就是她在想的事）。
    var quiet = false
    private var time: Double { moving ? t : 0 }
    /// 身体上下起伏（角色坐标），气泡跟着同一条曲线走。
    var bob: Double { state == .read ? even([0, -4, 0], dur: 0.6, t: time) : state == .ask ? even([0, -3, 0], dur: 1.2, t: time) : even([0, 3, 0], dur: 3.6, t: time) }
    private var blinkR: Double {
        let r = state == .broken ? 2.0 : 3.0
        return keyframe([r, r, 0.4, r], [0, 0.93, 0.96, 1], dur: 4.2, t: time)
    }

    private func stroke(_ ctx: inout GraphicsContext, _ d: String, _ width: CGFloat, color: Color? = nil) {
        ctx.stroke(SVGPath.path(d), with: .color(color ?? ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
    private func fill(_ ctx: inout GraphicsContext, _ d: String, _ color: Color, stroke width: CGFloat = 0) {
        ctx.fill(SVGPath.path(d), with: .color(color))
        if width > 0 { stroke(&ctx, d, width) }
    }
    private func text(_ ctx: inout GraphicsContext, _ value: String, size: CGFloat, color: Color, at point: CGPoint, weight: Font.Weight = .bold) {
        let font: Font = .system(size: size, weight: weight == .bold ? .heavy : .semibold, design: .rounded)
        ctx.draw(ctx.resolve(Text(value).font(font).foregroundStyle(color)), at: point, anchor: .center)
    }

    /// 从上一个姿态过渡过来（r3-work）：amount 0 = 还是 from，1 = 完全是当前 state（调用方已缓动）。
    struct PoseBlend { var from: StripState; var fromSign: String; var amount: Double }

    /// 整个角色（身体 + 头 + 当前状态的手持物）。调用方已设置 translate/scale。
    /// 带 blend 时只有变了的部分动：头的角度和起伏插值；表情、手上的东西交叉淡入；身体和头发只画一遍（叠两遍半透明会发虚）。
    func figure(_ c: inout GraphicsContext, blend: PoseBlend? = nil) {
        let a = blend?.amount ?? 1
        let previous = blend.map { CharacterPainter(state: $0.from, t: t, moving: moving, ink: ink, paper: paper, red: red, sign: $0.fromSign, danger: danger, quiet: quiet) }
        func mix(_ from: Double?, _ to: Double) -> Double { from.map { $0 + (to - $0) * a } ?? to }
        var ctx = c
        ctx.translateBy(x: 0, y: mix(previous?.bob, bob))
        fill(&ctx, "M28 132 Q32 106 60 104 Q88 106 92 132 Z", ink, stroke: 2)
        // 头：绕 (60,100) 轻轻点头 / 歪头
        var head = ctx
        let angle = mix(previous?.headAngle, headAngle)
        head.translateBy(x: 60, y: 100); head.rotate(by: .degrees(angle)); head.translateBy(x: -60, y: -100)
        stroke(&head, "M30 30 Q10 62 6 112 M27 40 Q14 76 12 120 M33 34 Q18 70 18 118 M31 50 Q22 86 22 124 M35 60 Q28 94 30 122 M24 30 Q4 58 2 96 M36 72 Q32 100 37 120 M90 30 Q110 62 114 112 M93 40 Q106 76 108 120 M87 34 Q102 70 102 118 M89 50 Q98 86 98 124 M85 60 Q92 94 90 122 M96 30 Q116 58 118 96 M84 72 Q88 100 83 120", 3.8)
        fill(&head, "M33 54 Q31 99 60 100 Q89 99 87 54 Q80 42 60 42 Q40 42 33 54 Z", paper)
        stroke(&head, "M33 62 Q32 99 60 100 Q88 99 87 62", 3.4)
        stroke(&head, "M24 54 Q20 10 60 8 Q100 10 96 54", 4)
        fill(&head, "M30 50 Q30 18 60 15 Q90 18 90 50 L85 44 L82 52 L77 42 L73 52 L68 41 L64 53 L59 41 L54 52 L50 42 L45 52 L41 43 L37 51 L34 45 Z", ink, stroke: 2)
        stroke(&head, "M40 20 L35 50 M80 20 L85 50 M28 30 Q40 14 56 12 M92 30 Q80 14 64 12", 3.4)
        stroke(&head, "M52 12 Q46 2 36 2 M66 12 Q72 2 84 4 M58 11 Q58 3 54 -2 M46 14 Q34 6 26 10 M74 14 Q88 6 96 12", 3)
        fill(&head, "M34 52 Q33 68 45 69 Q57 69 57 57 Q57 50 46 50 Q38 50 34 52 Z M63 57 Q63 69 75 69 Q86 68 86 57 Q86 50 76 50 Q66 50 63 57 Z", paper)
        stroke(&head, "M34 52 Q33 68 45 69 Q57 69 57 57 Q57 50 46 50 Q38 50 34 52 Z M34 52 L30 47 L38 50 M63 57 Q63 69 75 69 Q86 68 86 57 Q86 50 76 50 Q66 50 63 57 Z M86 54 L90 49 M57 55 Q60 52 63 55", 3.2)
        // 眼睛：都睁着就画一遍、视线滑过去；一个闭一个睁才交叉淡入。
        if let previous, previous.eyesClosed != eyesClosed {
            previous.eyes(&head, opacity: 1 - a); eyes(&head, opacity: a)
        } else if let previous {
            eyes(&head, opacity: 1, look: CGPoint(x: mix(previous.look.x, look.x), y: mix(previous.look.y, look.y)), radius: mix(previous.blinkR, blinkR))
        } else { eyes(&head, opacity: 1) }
        stroke(&head, "M60 62 L55 75 L61 75", 3)
        if let previous, previous.smiling != smiling { previous.mouth(&head, opacity: 1 - a); mouth(&head, opacity: a) } else { mouth(&head, opacity: 1) }
        // 出错时额角那滴汗：跟着状态淡入淡出。
        let was = previous.map { $0.state == .broken } ?? (state == .broken), now = state == .broken
        let drop: Double = was && now ? 1 : was ? 1 - a : now ? a : 0
        if drop > 0 { var layer = head; layer.opacity *= drop; stroke(&layer, "M98 40 Q94 47 98 50 Q102 47 98 40", 2.4) }
        // 手持物：换了的话旧的淡出、新的进场（牌子像盖章：动效库 03-badge-stamp）。
        if let previous, previous.state != state || previous.sign != sign {
            previous.props(&ctx, opacity: 1 - a, entrance: nil)
            props(&ctx, opacity: a, entrance: a)
        } else { props(&ctx, opacity: 1, entrance: nil) }
    }

    private var headAngle: Double { state == .idle ? even([-6, -11, -6], dur: 3.2, t: time) : state == .think ? even([0, 6, 0], dur: 1.6, t: time) : 0 }
    private var eyesClosed: Bool { state == .idle }
    private var smiling: Bool { state == .done }
    private var look: CGPoint { state == .read ? CGPoint(x: even([-2, 2, -2], dur: 1.2, t: time), y: 2) : state == .think ? CGPoint(x: 2, y: -2) : state == .send ? CGPoint(x: 3, y: 0) : .zero }

    private func eyes(_ head: inout GraphicsContext, opacity: Double, look custom: CGPoint? = nil, radius: Double? = nil) {
        var layer = head; layer.opacity *= opacity
        if eyesClosed { stroke(&layer, "M41 60 Q45.5 64 50 60 M70 60 Q74.5 64 79 60", 3); return }
        let look = custom ?? self.look, r = radius ?? blinkR
        for x in [46.0, 75.0] { layer.fill(Path(ellipseIn: CGRect(x: x + look.x - 3, y: 59 + look.y - r, width: 6, height: r * 2)), with: .color(ink)) }
    }
    private func mouth(_ head: inout GraphicsContext, opacity: Double) {
        var layer = head; layer.opacity *= opacity
        stroke(&layer, smiling ? "M48 83 Q54 91 62 83" : "M50 84 Q52.5 89 56 85", 3.2)
    }

    /// 当前状态拿在手上的东西。entrance 非空 = 正在进场（0…1，已缓动）。
    private func props(_ base: inout GraphicsContext, opacity: Double, entrance: Double?) {
        guard opacity > 0.001 else { return }
        var ctx = base; ctx.opacity *= opacity
        // 进场：牌子从 1.3 倍、-9° 摁下来摊平（03-badge-stamp：落地零回弹）；别的道具从 0.86 倍长出来。离场只淡出。
        if let e = entrance {
            let pivot: CGPoint = (state == .ask || state == .broken) ? CGPoint(x: 144, y: 32) : CGPoint(x: 100, y: 108)
            let stamp = state == .ask || state == .broken
            let scale = stamp ? 1.3 - 0.3 * e : 0.86 + 0.14 * e
            ctx.translateBy(x: pivot.x, y: pivot.y)
            if stamp { ctx.rotate(by: .degrees(-9 * (1 - e))) }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -pivot.x, y: -pivot.y)
        }
        switch state {
        case .read:
            stroke(&ctx, "M34 120 Q40 108 46 104 M86 120 Q80 108 74 104", 3.6)
            fill(&ctx, "M34 88 h52 v34 h-52z", paper, stroke: 3)
            stroke(&ctx, "M34 88 l26 16 26 -16", 2.6)
        case .think:
            stroke(&ctx, "M86 122 L92 112", 3.6)
            var pencil = ctx; pencil.translateBy(x: 92, y: 112); pencil.rotate(by: .degrees(even([0, -16, 0], dur: 0.8, t: time)))
            stroke(&pencil, "M0 0 L12 -22", 4); stroke(&pencil, "M12 -22 L14 -27", 2)
            for (i, dot) in [(102.0, 22.0, 5.0), (117.0, 9.0, 6.5), (135.0, -2.0, 8.0)].enumerated() where !quiet {
                let alpha = moving ? even([0.15, 1, 0.15], dur: 1.6, t: time, begin: Double(i) * 0.25) : (i == 2 ? 1 : 0.15)
                ctx.fill(Path(ellipseIn: CGRect(x: dot.0 - dot.2, y: dot.1 - dot.2, width: dot.2 * 2, height: dot.2 * 2)), with: .color(ink.opacity(alpha)))
            }
        case .exec:
            fill(&ctx, "M92 124 L100 112 L150 112 L158 124 Z", paper, stroke: 2.4)
            let mark = keyframe([0, 0, 1, 1], [0, 0.4, 0.44, 1], dur: 1.4, t: time)
            ctx.fill(Path(ellipseIn: CGRect(x: 113, y: 114.4, width: 24, height: 7.2)), with: .color(red.opacity(moving ? mark : 1)))
            var arm = ctx; arm.translateBy(x: 0, y: moving ? keyframe([-18, -18, 0, 0, -18], [0, 0.25, 0.42, 0.62, 1], dur: 1.4, t: time) : 0)
            stroke(&arm, "M86 120 Q100 104 112 98", 3.6)
            fill(&arm, "M118 84 q0 -8 7 -8 q7 0 7 8 v8 h-14z", ink, stroke: 2)
            fill(&arm, "M110 92 h30 v12 h-30z", red, stroke: 2.4)
        case .send:
            stroke(&ctx, "M86 120 Q104 100 120 90", 3.6)
        case .ask, .broken:
            stroke(&ctx, "M88 124 L104 66", 3.6)
            var board = ctx; board.translateBy(x: 88, y: 8)
            let rotation = state == .ask ? even([-2, 2, -2], dur: 1.2, t: time) : keyframe([0, -6, 5, -3, 2, 0, 0], [0, 0.12, 0.24, 0.36, 0.48, 0.6, 1], dur: 1.6, t: time)
            board.translateBy(x: 30, y: 48); board.rotate(by: .degrees(moving ? rotation : 0)); board.translateBy(x: -30, y: -48)
            fill(&board, "M0 0 h112 v48 h-112z", state == .ask ? red : paper, stroke: 3)
            text(&board, sign.isEmpty ? (state == .ask ? "等你点头" : "邮箱断了") : sign, size: sign.count > 4 ? 20 : 26, color: state == .ask ? ink : danger, at: CGPoint(x: 56, y: 26))
        case .done:
            var hand = ctx
            let p = moving ? keyframe([-6, 0, 34, 50], [0, 0.15, 0.65, 1], dur: 1.6, t: time) : 0
            hand.opacity *= moving ? keyframe([0, 1, 1, 0], [0, 0.15, 0.65, 1], dur: 1.6, t: time) : 1
            hand.translateBy(x: 0, y: p)
            stroke(&hand, "M86 120 Q96 112 104 104", 3.6)
            fill(&hand, "M98 90 h44 v30 h-44z", paper, stroke: 2.6)
            stroke(&hand, "M105 100 h28 M105 109 h18", 2.2)
        case .idle:
            for (i, z) in [(98.0, 40.0, 26.0), (114.0, 22.0, 34.0)].enumerated() {
                let begin = Double(i) * 1.1
                let alpha = moving ? keyframe([0, 1, 0], [0, 0.25, 1], dur: 3.2, t: time, begin: begin) : 0.5
                let drift = moving ? even([0, 1], dur: 3.2, t: time, begin: begin) : 0.4
                text(&ctx, "z", size: z.2, color: ink.opacity(alpha), at: CGPoint(x: z.0 + drift * 12, y: z.1 - drift * 18), weight: .semibold)
            }
        }
    }

    /// 纸飞机：在调用方坐标系内从 origin 起飞。reach = 飞多远（顶栏里收短，不飞进右边的按钮）。
    func plane(_ c: inout GraphicsContext, origin: CGPoint, scale: CGFloat, reach: Double = 90) {
        var ctx = c
        let p = moving ? (time.truncatingRemainder(dividingBy: 1.8)) / 1.8 : 0.5
        let dx = keyframe([0, reach * 4 / 9, reach], [0, 0.5, 1], dur: 1, t: p), dy = keyframe([0, -10, 2], [0, 0.5, 1], dur: 1, t: p)
        ctx.opacity = moving ? keyframe([0, 1, 1, 0], [0, 0.1, 0.85, 1], dur: 1, t: p) : 1
        ctx.translateBy(x: origin.x + dx * scale, y: origin.y + dy * scale); ctx.scaleBy(x: scale, y: scale)
        fill(&ctx, "M0 0 L12 4 L0 8 L3 4 Z", paper, stroke: 1.2); stroke(&ctx, "M3 4 L12 4", 1.2)
    }
}

// MARK: - 顶栏里的她（r3-work）

/// 顶栏里的她：全 App 只有这一个实例（ComTopBar 挂在 RootView 最上层），站在固定锚点上，切页、换状态都不挪位。
/// 姿态换的时候只有变了的部分动（PoseBlend）：表情和手上的东西交叉淡入，头的角度和身体起伏插值过去，
/// 新举起的牌子像盖章一样摁上来（动效库 03-badge-stamp）。
struct StripFigure: View {
    /// 120×132 线稿按 0.38 缩放后她本人的宽度；画布右边再留出牌子、盖章台、纸飞机的地方。
    static let bodyWidth: CGFloat = 120 * 0.38
    static let size = CGSize(width: 124, height: 56)
    /// 03-badge-stamp：贴纸约 9 帧摊平落位（30fps ≈ 0.3s），姿态交叉也用这个时长。
    static let blendDuration = 0.32
    let state: StripState
    var sign = ""
    var animated = true
    /// 旁边有手绘气泡时不画思考点（气泡本身就是她在想的事）。
    var quiet = false
    /// 往下拉工作台时她从顶栏跳到桌前；进度 0 = 待在顶栏。
    var hop: Hop?
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var scene
    @State private var pose: Pose
    @State private var blending = false
    private struct Pose: Equatable { var from: StripState; var fromSign: String; var to: StripState; var toSign: String; var at: Date }
    private struct Key: Equatable { let state: StripState; let sign: String }
    /// 跳下去的路线（坐标都是顶栏坐标，原点在顶栏左上角；线稿原点 = 120×132 角色坐标的 0,0）。桌子的位置由进度现算（StagePanel.deskFigure）。
    struct Hop: Equatable {
        /// 工作台展开进度：0 在顶栏，1 坐到桌前。拖的时候直接跟手指走，松手后跟着工作台的弹簧逐帧插值。
        var progress: CGFloat
        /// 顶栏里她的线稿原点。
        var start: CGPoint
        /// 顶栏宽（算桌子位置用）。
        var width: CGFloat
        /// StripFigure 自己在顶栏里的左上角（大画布要往回挪这么多，对齐顶栏原点）。
        var frameOrigin: CGPoint
        /// 画她的这块大画布：顶栏 + 工作台展开部分。
        var canvas: CGSize { CGSize(width: width, height: Layout.topBar + StagePanel.revealHeight) }
    }
    init(state: StripState, sign: String = "", animated: Bool = true, quiet: Bool = false, hop: Hop? = nil) {
        self.state = state; self.sign = sign; self.animated = animated; self.quiet = quiet; self.hop = hop
        _pose = State(initialValue: Pose(from: state, fromSign: sign, to: state, toSign: sign, at: .distantPast))
    }
    private var moving: Bool { animated && !reduce && scene == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled }
    var body: some View {
        // 画的永远是 pose（不是直接读 state）：onChange 之前那一帧还是旧姿态，不会先闪一下新姿态再从头淡入。
        let loops = moving && pose.to != .done
        TimelineView(.animation(minimumInterval: 1.0 / (pose.to == .idle && !blending ? 12 : 30), paused: !loops && !blending)) { timeline in
            let raw = min(1, max(0, timeline.date.timeIntervalSince(pose.at) / Self.blendDuration))
            let blend: CharacterPainter.PoseBlend? = raw < 1 ? .init(from: pose.from, fromSign: pose.fromSign, amount: 1 - pow(1 - raw, 3)) : nil  // GSAP power3.out
            let painter = CharacterPainter(state: pose.to, t: timeline.date.timeIntervalSinceReferenceDate, moving: moving, ink: Palette.ink, paper: Palette.surface, red: Palette.accent, sign: pose.toSign, quiet: quiet)
            FigureLayer(progress: hop?.progress ?? 0, hop: hop, painter: painter, blend: blend,
                        plane: pose.to == .send ? (blend != nil && pose.from != .send ? blend?.amount ?? 1 : 1) : nil, reduce: reduce)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .onChange(of: Key(state: state, sign: sign)) { _, key in
            let now = Date()
            // 上一段还没过半就又换：从上一段的起点接着走，免得一帧跳回目标姿态。
            let early = now.timeIntervalSince(pose.at) < Self.blendDuration / 2
            pose = Pose(from: early ? pose.from : pose.to, fromSign: early ? pose.fromSign : pose.toSign, to: key.state, toSign: key.sign, at: now)
            blending = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.blendDuration + 0.05))
                if Date().timeIntervalSince(pose.at) >= Self.blendDuration { blending = false }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 她这一层：平时在顶栏的小画布里；拉工作台时换到一块大画布上，跟着进度从顶栏跳到桌前。
/// 进度是动画值（Animatable）：松手后工作台的弹簧每一帧都插值，她不会一下闪到桌前，收起时也原路跳回来。
nonisolated private struct FigureLayer: View, Animatable {
    var progress: CGFloat
    let hop: StripFigure.Hop?
    let painter: CharacterPainter
    let blend: CharacterPainter.PoseBlend?
    /// 纸飞机的透明度（nil = 不画）。
    let plane: Double?
    let reduce: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    @MainActor var body: some View {
        if let hop, progress > 0.001 {
            Canvas { context, _ in draw(hop, in: context) }
                .frame(width: hop.canvas.width, height: hop.canvas.height)
                .offset(x: -hop.frameOrigin.x, y: -hop.frameOrigin.y)
                .allowsHitTesting(false)
        } else {
            Canvas { context, _ in
                var ctx = context
                ctx.translateBy(x: 0, y: 6); ctx.scaleBy(x: 0.38, y: 0.38)
                painter.figure(&ctx, blend: blend)
                if let plane {
                    var layer = context; layer.opacity = plane
                    painter.plane(&layer, origin: CGPoint(x: 48, y: 22), scale: 1, reach: 60)
                }
            }
            .frame(width: StripFigure.size.width, height: StripFigure.size.height)
        }
    }

    /// 从顶栏跳到桌前：位置走一段小抛物线（跳起 22pt），一路放大到桌前的尺寸，身子朝前进方向前倾——
    /// 动效库 16-arrow-label-3d 里物件落位的走法（落定后的过冲回弹交给工作台自己的弹簧）。减少动态效果时只交叉淡入，不移动。
    private func draw(_ hop: StripFigure.Hop, in context: GraphicsContext) {
        let p = Double(min(1, max(0, progress)))
        let desk = StagePanel.deskFigure(width: hop.width, progress: progress)
        func place(_ u: Double, opacity: Double) {
            guard opacity > 0.001 else { return }
            let x = hop.start.x + (desk.origin.x - hop.start.x) * u
            let y = hop.start.y + (desk.origin.y - hop.start.y) * u - (reduce ? 0 : 22 * sin(.pi * u))
            let scale = 0.38 + (desk.scale - 0.38) * u
            let lean = reduce ? 0 : -7 * sin(.pi * u) * (desk.origin.x < hop.start.x ? 1 : -1)
            var ctx = context
            ctx.opacity = opacity
            // 绕脚底中心转：前倾时脚不打滑。
            ctx.translateBy(x: x + 60 * scale, y: y + 132 * scale); ctx.rotate(by: .degrees(lean)); ctx.translateBy(x: -60 * scale, y: -132 * scale)
            ctx.scaleBy(x: scale, y: scale)
            painter.figure(&ctx, blend: blend)
        }
        if reduce {
            place(0, opacity: max(0, 1 - p * 2)); place(1, opacity: max(0, p * 2 - 1))
        } else {
            // 她比工作台先落定一点（进度到 0.85 就坐好），smoothstep 起落都缓。
            let t = min(1, p / 0.85)
            place(t * t * (3 - 2 * t), opacity: 1)
        }
    }
}

/// 她说的话（r3-work）：挂在她左边、标题下面那一行，尾巴指向她；空字符串 = 收起。
/// 开合走同一条路：从尾尖处旋转展开、原路收回——动效库 15-bubble-glow-logo 的气泡（从尾尖 scale 0.10→1、
/// 旋转 −39°→0°，落定后 1.00→0.98→1.00 微回弹）；手机上角度收成 −20°，回弹交给欠阻尼弹簧一次带出来。
struct TalkBubble: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var last = ""
    /// 尾尖在气泡右下：缩放和旋转都绕它。
    static let tail = UnitPoint(x: 1, y: 0.85)
    var body: some View {
        let open = !text.isEmpty
        SketchBubble(text: open ? text : last, tailOnLeading: false)
            .scaleEffect(open || reduce ? 1 : 0.1, anchor: Self.tail)
            .rotationEffect(.degrees(open || reduce ? 0 : -20), anchor: Self.tail)
            .opacity(open ? 1 : 0)
            .animation(reduce ? .easeOut(duration: 0.2) : open ? .spring(response: 0.46, dampingFraction: 0.64) : .spring(response: 0.34, dampingFraction: 1), value: open)
            // 收起后它还在（缩在尾尖等下次展开），无障碍上换个名字，免得读到一个看不见的气泡。
            .accessibilityHidden(!open)
            .accessibilityIdentifier(open ? "agent-work-bubble" : "agent-work-bubble-closed")
            .onChange(of: text, initial: true) { _, value in if !value.isEmpty { last = value } }
    }
}

// MARK: - 下拉工作台（402×170 设计坐标）

/// 她的工作台：左边信箱格，中间桌子，右边 mini / Book 两盏灯。
struct StageScene: View {
    let state: StripState
    var sign = ""
    var sourceBroken = false
    var machineLit: String = ""
    /// r3-work：下拉工作台里不画她——顶栏那个她自己跳下来坐到桌前（StripFigure.Hop），全 App 还是只有一个她。
    var drawsFigure = true
    /// 桌前她的原点和缩放（场景坐标，高 200 的场景）：和下面画桌子用的是同一套数。
    nonisolated static func figureOrigin(width: CGFloat, height: CGFloat = 200) -> (origin: CGPoint, scale: CGFloat) {
        let s = width / 402
        return (CGPoint(x: 158 * s, y: height - 170 * s + 20 * s), 0.8 * s)
    }
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var scene
    private var moving: Bool { !reduce && scene == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / (state == .idle ? 12 : 30), paused: !moving || state == .done)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let s = size.width / 402
                var ctx = context
                ctx.translateBy(x: 0, y: size.height - 170 * s); ctx.scaleBy(x: s, y: s)
                let ink = Palette.ink, paper = Palette.surface, red = Palette.accent
                let painter = CharacterPainter(state: state, t: now, moving: moving, ink: ink, paper: paper, red: red, sign: sign)
                func line(_ d: String, _ w: CGFloat, _ color: Color = ink, alpha: Double = 1) {
                    ctx.stroke(SVGPath.path(d), with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                }
                func fillPath(_ d: String, _ color: Color, _ w: CGFloat) { ctx.fill(SVGPath.path(d), with: .color(color)); line(d, w) }
                line("M12 160 Q120 157 200 160 T392 159", 1.8, alpha: 0.55)
                // 信箱格
                line("M22 160 L22 92 L92 92 L92 160 M57 92 L57 160 M22 126 L92 126", 2.2)
                line("M29 103 h20 v14 h-20z M29 103 l10 7 10 -7", 1.7)
                line("M64 102 h22 v16 h-22z M64 107 h22 M69 100 v4 M81 100 v4", 1.7)
                line("M29 136 h20 v11 h-12 l-5 4 v-4 h-3z", 1.7)
                line("M68 135 l6 7 6 -7 M74 142 v9 M69 145 h10", 1.7)
                if sourceBroken || state == .broken { line("M27 100 L51 121 M51 100 L27 121", 3, red) }
                if state == .read {
                    fillPath("M134 124 L139 115 L169 115 L174 124 Z", paper, 1.7)
                    var page = ctx; page.translateBy(x: 134, y: 124); page.rotate(by: .degrees(moving ? keyframe([0, 0, -150, 0], [0, 0.5, 0.75, 1], dur: 1.2, t: now) : 0)); page.translateBy(x: -134, y: -124)
                    page.fill(SVGPath.path("M134 124 L139 115 L169 115 L174 124 Z"), with: .color(paper))
                    page.stroke(SVGPath.path("M134 124 L139 115 L169 115 L174 124 Z"), with: .color(ink), lineWidth: 1.7)
                }
                // 桌子
                fillPath("M110 123 Q220 120 332 123 L332 134 Q220 131 110 134 Z", paper, 2.4)
                line("M124 134 L122 160 M318 133 L320 160", 2.4)
                // 角色
                if drawsFigure { var figure = ctx; figure.translateBy(x: 158, y: 20); figure.scaleBy(x: 0.8, y: 0.8); painter.figure(&figure) }
                if state == .send { painter.plane(&ctx, origin: CGPoint(x: 252, y: 100), scale: 1.5) }
                if state == .done {
                    var spark = ctx; spark.translateBy(x: 248, y: 104)
                    let grow = moving ? even([0.2, 1.3], dur: 1.6, t: now) : 1
                    spark.opacity = moving ? keyframe([0, 1, 0], [0, 0.3, 1], dur: 1.6, t: now) : 0.8
                    spark.scaleBy(x: grow, y: grow)
                    spark.stroke(SVGPath.path("M0 -6 V6 M-6 0 H6 M-4 -4 L4 4 M4 -4 L-4 4"), with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
                // 两台电脑
                line("M346 160 L346 102 L390 102 L390 160 M352 114 L384 114", 2.2)
                let lit = state == .send && moving ? keyframe([0, 0, 1, 1], [0, 0.8, 0.82, 1], dur: 1.8, t: now) : 0
                for (i, x) in [358.0, 378.0].enumerated() {
                    let on = (i == 0 && machineLit != "macbook") || (i == 1 && machineLit == "macbook")
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 126, width: 8, height: 8)), with: .color(on && lit > 0.5 ? ink : paper))
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - 4, y: 126, width: 8, height: 8)), with: .color(ink), lineWidth: 1.8)
                }
                for (x, label) in [(357.0, "mini"), (380.0, "Book")] {
                    ctx.draw(ctx.resolve(Text(label).font(.system(size: 6.5)).foregroundStyle(Palette.textTertiary)), at: CGPoint(x: x, y: 148), anchor: .center)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 头像：只画头，给菜单、语音小窗和配对页用。
struct CompanionPortrait: View {
    var size: CGFloat = 36
    var state: StripState = .idle
    var body: some View {
        Canvas { context, _ in
            var ctx = context
            let scale = size / 118
            ctx.translateBy(x: size / 2 - 60 * scale, y: -2 * scale); ctx.scaleBy(x: scale, y: scale)
            CharacterPainter(state: state == .idle ? .think : state, t: 0, moving: false, ink: Palette.ink, paper: Palette.surface, red: Palette.accent).figure(&ctx)
        }
        .frame(width: size, height: size).clipShape(.circle).background(Palette.surface, in: .circle)
        .overlay(Circle().strokeBorder(Palette.separator, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Kept for callers that drew the old companion full-size (pairing, empty states).
struct Companion: View {
    var state: StripState = .idle
    var body: some View {
        Canvas { context, size in
            var ctx = context
            let scale = min(size.width / 160, size.height / 140)
            ctx.translateBy(x: size.width / 2 - 60 * scale, y: size.height / 2 - 66 * scale); ctx.scaleBy(x: scale, y: scale)
            CharacterPainter(state: state, t: 0, moving: false, ink: Palette.ink, paper: Palette.surface, red: Palette.accent).figure(&ctx)
        }.accessibilityHidden(true)
    }
}

// MARK: - 后端状态 → 角色状态

extension AgentStageState {
    var strip: StripState {
        switch self {
        case .idle: .idle
        case .thinking, .waiting: .think
        case .working, .writing: .exec
        case .searching, .remembering, .calendar: .read
        case .handoff: .send
        case .review: .ask
        case .delivered: .done
        case .failed, .offline: .broken
        }
    }
}

// MARK: - 手绘对话气泡

/// 不规则手绘描边的对话气泡：一圈主线 + 一圈错位的淡线，像铅笔描了两遍；小尾巴指向人物。
struct SketchBubble: View {
    let text: String
    var tailOnLeading = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.85)
            .contentTransition(.opacity)
            .animation(reduce ? nil : .smooth(duration: 0.28), value: text)
            .padding(.vertical, 7).padding(.leading, tailOnLeading ? 19 : 11).padding(.trailing, tailOnLeading ? 11 : 19)
            .background {
                ZStack {
                    SketchBubbleShape(tailOnLeading: tailOnLeading, seed: 3).fill(Palette.surface)
                    SketchBubbleShape(tailOnLeading: tailOnLeading, seed: 3).stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    SketchBubbleShape(tailOnLeading: tailOnLeading, seed: 11).stroke(Palette.ink.opacity(0.35), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
                        .offset(x: 0.8, y: 0.7)
                }
            }
    }
}

struct SketchBubbleShape: Shape {
    var tailOnLeading = true
    var seed = 0
    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = 9
        let b = tailOnLeading ? CGRect(x: rect.minX + tail, y: rect.minY + 1, width: rect.width - tail - 1, height: rect.height - 2)
                              : CGRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - tail - 1, height: rect.height - 2)
        let r = min(13, b.height / 2)
        // 固定种子的小抖动：每次画都一样，不会闪。
        func j(_ i: Int) -> CGFloat { CGFloat(sin(Double(seed * 37 + i * 101)) * 1.3) }
        var p = Path()
        p.move(to: CGPoint(x: b.minX + r, y: b.minY + j(0)))
        p.addQuadCurve(to: CGPoint(x: b.maxX - r, y: b.minY + j(1)), control: CGPoint(x: b.midX, y: b.minY - 1.6 + j(2)))
        p.addQuadCurve(to: CGPoint(x: b.maxX + j(3), y: b.midY), control: CGPoint(x: b.maxX + 1 + j(4), y: b.minY + j(5)))
        if tailOnLeading {
            p.addQuadCurve(to: CGPoint(x: b.maxX - r, y: b.maxY + j(6)), control: CGPoint(x: b.maxX + j(7), y: b.maxY + 1))
            p.addQuadCurve(to: CGPoint(x: b.minX + r, y: b.maxY + j(8)), control: CGPoint(x: b.midX, y: b.maxY + 1.4 + j(9)))
            p.addQuadCurve(to: CGPoint(x: b.minX + 1, y: b.midY + 5), control: CGPoint(x: b.minX + j(10), y: b.maxY))
            // 尾巴：往左下方伸向她的脸。
            p.addQuadCurve(to: CGPoint(x: rect.minX + j(11) * 0.5, y: b.maxY - 2), control: CGPoint(x: b.minX - 3, y: b.midY + 8))
            p.addQuadCurve(to: CGPoint(x: b.minX + j(12) * 0.4, y: b.midY - 1), control: CGPoint(x: b.minX - 2, y: b.midY + 3))
            p.addQuadCurve(to: CGPoint(x: b.minX + r + j(13), y: b.minY + j(0)), control: CGPoint(x: b.minX - 1 + j(14), y: b.minY - 1))
        } else {
            p.addQuadCurve(to: CGPoint(x: b.maxX - 1, y: b.midY + 5), control: CGPoint(x: b.maxX + j(7), y: b.midY + 2))
            p.addQuadCurve(to: CGPoint(x: rect.maxX + j(11) * 0.5, y: b.maxY - 2), control: CGPoint(x: b.maxX + 3, y: b.midY + 8))
            p.addQuadCurve(to: CGPoint(x: b.maxX - r, y: b.maxY + j(6)), control: CGPoint(x: b.maxX - 2, y: b.maxY + 1))
            p.addQuadCurve(to: CGPoint(x: b.minX + r, y: b.maxY + j(8)), control: CGPoint(x: b.midX, y: b.maxY + 1.4 + j(9)))
            p.addQuadCurve(to: CGPoint(x: b.minX + j(10), y: b.midY), control: CGPoint(x: b.minX - 1, y: b.maxY + j(12)))
            p.addQuadCurve(to: CGPoint(x: b.minX + r + j(13), y: b.minY + j(0)), control: CGPoint(x: b.minX - 1 + j(14), y: b.minY - 1))
        }
        p.closeSubpath()
        return p
    }
}
