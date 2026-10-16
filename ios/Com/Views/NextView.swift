import SwiftUI
import ComCore

// 下一步：它主动把邮件、日程、项目、任务和账本收拢，归纳成几件现在值得做的事。
// 每条都写「凭什么」，依据可展开；「交给 Com」会作为一条消息交给主对话去办，执行仍走批准流。

extension AppModel {
    var nextData: JSON { datasets["/personal/next"] ?? .null }
    var nextItems: [JSON] { nextData["items"].array }
    /// 「现在就该做」的条数，给 Dock 徽标用。
    var nextUrgentCount: Int { nextItems.filter { $0["urgency"].string == "now" }.count }

    func nextAction(_ item: JSON, _ action: String) async {
        #if DEBUG
        if isUITesting {
            var value = nextData
            value["items"] = .array(value["items"].array.filter { $0.id != item.id }); datasets["/personal/next"] = value
            if action == "discuss" {
                conversation.messages.append(.object(["id": .string("next-" + item.id), "role": .string("user"), "text": .string(item["prompt"].string), "status": .string("completed"), "created_at": .number(Date().timeIntervalSince1970)]))
                conversation.revision += 1; tab = .chat
            }
            Haptics.selection(); return
        }
        #endif
        do {
            _ = try await mutate("/personal/next/" + item.id.pathEncoded, fields: ["action": .string(action)])
            _ = await load("/personal/next")
            if action == "discuss" { tab = .chat; await refresh(.chat) }
            Haptics.success()
        } catch { banner = error.localizedDescription }
    }
    func refreshNext() async {
        #if DEBUG
        if isUITesting {
            // 界面验收：按后端真实阶段顺序走一遍构建卡（collect → think → store → 结束）
            let started = Date().timeIntervalSince1970
            let counts: JSON = .object(["mail": .number(12), "calendar": .number(3), "projects": .number(5), "tasks": .number(2), "goals": .number(1), "finance": .number(1)])
            for (stage, wait) in [("collect", 1.2), ("think", 3.5), ("store", 0.8)] {
                var value = nextData; value["running"] = .bool(true)
                value["progress"] = .object(["stage": .string(stage), "counts": stage == "collect" ? .object([:]) : counts, "started_at": .number(started)])
                datasets["/personal/next"] = value
                try? await Task.sleep(for: .seconds(wait))
            }
            var value = nextData; value["running"] = .bool(false); value["progress"] = .null; datasets["/personal/next"] = value
            return
        }
        #endif
        do {
            _ = try await mutate("/personal/next/refresh")
            var value = nextData; value["running"] = .bool(true); datasets["/personal/next"] = value
            // 整理一般 20–90 秒；每 2 秒看一眼（构建卡要跟上阶段变化），最多等两分钟。
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(2))
                if let data = await load("/personal/next"), !data["running"].bool { break }
            }
        } catch { banner = error.localizedDescription }
    }
}

struct NextView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    private var data: JSON { model.nextData }
    private var groups: [(String, [JSON])] {
        [("现在", "now"), ("今天", "today"), ("这周", "week")].compactMap { title, key in
            let rows = model.nextItems.filter { $0["urgency"].string == key }
            return rows.isEmpty ? nil : (title, rows)
        }
    }
    var body: some View {
        ScreenScaffold(title: "下一步") {
            header
            let broken = model.brokenSources
            if !broken.isEmpty {
                ForEach(broken.map { RemoteRow(.object(["id": $0["name"], "source": $0])) }) { row in SourceBrokenNote(source: row.value["source"]) }
            }
            if data["running"].bool {
                NextBuildingCard(progress: data["progress"])
                    .transition(reduce ? .opacity : .blurLift)
            } else if model.nextItems.isEmpty {
                EmptyState(title: "眼下没有要提的事",
                           description: "我每小时会自己再看一遍；有新邮件、新日程或项目有进展，会整理成下一步放在这里。",
                           symbol: "sparkles")
            }
            ForEach(groups, id: \.0) { title, rows in
                GroupSection(title) {
                    ForEach(Array(rows.map(RemoteRow.init).enumerated()), id: \.element.id) { index, row in
                        // 新建议错峰模糊上浮进来（每张晚 50ms），和构建卡同一套语法
                        NextCard(item: row.value)
                            .transition(reduce ? .opacity : .asymmetric(insertion: AnyTransition.blurLift.animation(.spring(response: 0.42, dampingFraction: 0.86).delay(Double(index) * 0.05)),
                                                                      removal: .scale(scale: 0.96).combined(with: .opacity)))
                    }
                }
            }
            if let finance = model.datasets["/personal/finance"], finance["available"].bool { GroupSection("账本") { LedgerNote(finance: finance) } }
            footer
        }
        .animation(reduce ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.nextItems.map(\.id))
        .animation(reduce ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: data["running"].bool)
        .refreshable { await model.refreshNext() }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(data["running"].bool ? "正在重新整理…" : "我从邮件、日程、项目和账本里挑的").font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary)
                if data["updated_at"].double > 0 {
                    Text("上次整理 " + relativeTime(data["updated_at"].double) + (data["source"].string == "rule" ? " · 模型没接上，先按规则排" : ""))
                        .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
    @ViewBuilder private var footer: some View {
        let week = data["week"]
        if week["shown"].int > 0 {
            Text("这周提了 \(week["shown"].int) 件，你做了 \(week["acted"].int) 件、划掉 \(week["dismissed"].int) 件。划掉的我会少提。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.xs)
        }
    }
}

/// 一条建议：做什么 → 凭什么 → 依据（可展开）→ 交给 Com / 已经做了 / 不用。
private struct NextCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let item: JSON
    @State private var offset: CGFloat = 0
    @State private var busy = false
    var body: some View {
        Card(item["urgency"].string == "now" ? .highlighted(.accent) : .standard, padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(item["title"].string).font(TypeScale.headline).foregroundStyle(Palette.textPrimary).lineLimit(2)
                    Spacer(minLength: Space.sm)
                    if item["urgency"].string == "now" { Stamp(text: "现在", tone: .warning) }
                }
                if !item["why"].string.isEmpty { Text(item["why"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineSpacing(2) }
                let evidence = item["evidence"].array
                if !evidence.isEmpty {
                    // 依据只用依据袋表达：点开纸片从袋口飞出来停住，点哪张纸就打开哪份原始来源（轨道 r2-pages：去掉了卡片里的列表）。
                    EvidencePocket(evidence: evidence, itemID: item.id, itemTitle: item["title"].string)
                }
                HStack(spacing: Space.sm) {
                    Button("交给 Com") { act("discuss") }.buttonStyle(.primaryCompact).disabled(busy).accessibilityIdentifier("next-discuss-" + item.id)
                    Button("已经做了") { act("done") }.buttonStyle(.secondaryCompact).disabled(busy)
                    Spacer(minLength: 0)
                    Button("不用") { act("dismiss") }.buttonStyle(.quiet).disabled(busy).accessibilityIdentifier("next-dismiss-" + item.id)
                }
            }
        }
        .offset(x: offset)
        .gesture(DragGesture(minimumDistance: 24).onChanged { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
            offset = max(-110, min(0, value.translation.width * 0.6))
        }.onEnded { value in
            withAnimation(reduce ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
            if value.translation.width < -80 { act("dismiss") }
        })
        .contextMenu {
            Button("交给 Com", systemImage: "bubble.left") { act("discuss") }
            Button("已经做了", systemImage: "checkmark") { act("done") }
            Button("不用，少提这类", systemImage: "xmark") { act("dismiss") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("next-" + item.id)
    }
    private func act(_ action: String) {
        busy = true
        Task { await model.nextAction(item, action); busy = false }
    }
}

/// 重新整理时的构建清单。阶段是后端真实上报的（progress.stage：collect → think → store），条数来自这轮摘要，没有假百分比。
/// 动作语法取自 Amena Sabuwala 的 App onboarding 动效展示（2026-10，x.com/AmenaiSabuwala），同款入了动效库 20-build-checklist：
/// 卡片模糊上浮、逐项转圈→打勾、没轮到的行半透明加模糊（景深清单），卡片角落一团强调色光。
private struct NextBuildingCard: View {
    let progress: JSON
    @Environment(\.accessibilityReduceMotion) private var reduce
    private struct Step: Identifiable { let id: String; let symbol: String; let text: String; let meta: String; let done: Bool }

    private var stage: String { progress["stage"].string }
    private var steps: [Step] {
        let c = progress["counts"]
        let got = stage == "think" || stage == "store"
        func meta(_ key: String, _ unit: String) -> String { got ? (c[key].int > 0 ? "\(c[key].int) \(unit)" : "没有新的") : "" }
        return [
            Step(id: "mail", symbol: "envelope", text: "读邮件", meta: meta("mail", "封"), done: got),
            Step(id: "calendar", symbol: "calendar", text: "看日程", meta: meta("calendar", "个"), done: got),
            Step(id: "projects", symbol: "desktopcomputer", text: "对项目进度", meta: meta("projects", "个"), done: got),
            Step(id: "tasks", symbol: "checkmark.square", text: "看今天的任务", meta: meta("tasks", "件"), done: got),
            Step(id: "finance", symbol: "creditcard", text: "翻账本", meta: got ? (c["finance"].int > 0 ? "本月" : "没接上") : "", done: got),
            Step(id: "plaud", symbol: "waveform", text: "听会议纪要和短信", meta: got ? (c["commitments"].int + c["sms"].int > 0 ? "\(c["commitments"].int) 场会 · \(c["sms"].int) 条短信" : "没有新的") : "", done: got),
            Step(id: "think", symbol: "sparkles", text: "归纳成下一步", meta: "", done: stage == "store"),
        ]
    }

    var body: some View {
        let rows = steps
        let active = rows.firstIndex { !$0.done } ?? rows.count
        VStack(alignment: .leading, spacing: Space.md) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince1970 - progress["started_at"].double)
                VStack(alignment: .leading, spacing: 6) {
                    ProgressTrack(fraction: fraction(elapsed))
                    HStack {
                        Text(stage == "think" ? "模型在归纳" : stage == "store" ? "快好了" : "在收集").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: 0)
                        if progress["started_at"].double > 0 { Text("已 \(Int(elapsed)) 秒").font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.accentText) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, step in
                    row(step, active: index == active)
                        .opacity(index <= active ? 1 : index == active + 1 ? 0.55 : 0.3)
                        .blur(radius: index > active + 1 && !reduce ? 2.5 : 0)
                        .animation(reduce ? nil : .spring(response: 0.4, dampingFraction: 0.85).delay(Double(index) * 0.04), value: active)
                }
            }
            .padding(.vertical, Space.sm).padding(.horizontal, Space.md)
            .background(Palette.surface.opacity(0.9), in: .rect(cornerRadius: Radius.md, style: .continuous))
        }
        .padding(Space.lg)
        .background {
            ZStack(alignment: .topTrailing) {
                Palette.surface
                RadialGradient(colors: [Palette.accent.opacity(0.75), Palette.accent.opacity(0)], center: .center, startRadius: 0, endRadius: 150)
                    .frame(width: 300, height: 240).offset(x: 90, y: -110)
            }
            .clipShape(.rect(cornerRadius: Radius.lg, style: .continuous))
        }
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在重新整理下一步")
        .accessibilityIdentifier("next-building")
    }

    /// 收集很快，大头在模型；归纳段按经验曲线逼近 90%，真正存库后才到头。
    private func fraction(_ elapsed: Double) -> Double {
        switch stage {
        case "store": 1
        case "think": 0.35 + 0.55 * (1 - exp(-elapsed / 35))
        default: 0.12
        }
    }

    private func row(_ step: Step, active: Bool) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: step.symbol).font(.system(size: 15)).foregroundStyle(Palette.textPrimary).frame(width: 22)
            Text(step.text).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary)
            if !step.meta.isEmpty { Text(step.meta).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).transition(.opacity) }
            Spacer(minLength: 0)
            ZStack {
                if step.done {
                    Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundStyle(Palette.textPrimary)
                        .transition(reduce ? .opacity : .scale(scale: 0.4).combined(with: .opacity).animation(.spring(duration: 0.35, bounce: 0.45)))
                } else if active {
                    BuildSpinner(reduce: reduce).transition(.opacity)
                } else {
                    Circle().strokeBorder(Palette.separator, lineWidth: 1.5).frame(width: 18, height: 18)
                }
            }
            .frame(width: 22, height: 22)
        }
        .padding(.vertical, 9)
    }
}

private struct ProgressTrack: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.fill)
                Capsule().fill(LinearGradient(colors: [Palette.accent.opacity(0.55), Palette.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(10, geo.size.width * fraction))
                    .shadow(color: Palette.accent.opacity(0.5), radius: 6)
                    .animation(.smooth(duration: 0.9), value: fraction)
            }
        }
        .frame(height: 10)
    }
}

private struct BuildSpinner: View {
    let reduce: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduce)) { context in
            Circle().trim(from: 0, to: 0.28)
                .stroke(Palette.accentText, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 17, height: 17)
                .rotationEffect(.degrees(reduce ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
        }
    }
}

/// 模糊上浮：从下方 24pt、10pt 模糊淡入；离场时同路反向。
private struct BlurLift: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { content.opacity(on ? 0 : 1).blur(radius: on ? 10 : 0).offset(y: on ? 24 : 0) }
}
extension AnyTransition {
    static var blurLift: AnyTransition { .modifier(active: BlurLift(on: true), identity: BlurLift(on: false)) }
}

private func evidenceSymbol(_ kind: String) -> String {
    switch kind { case "mail": "envelope"; case "event": "calendar"; case "project": "desktopcomputer"; case "task": "checkmark.square"; case "finance": "creditcard"; case "goal": "scope"; case "wechat": "bubble.left.and.bubble.right"; case "health": "heart"; case "todo": "checklist"; case "inbox": "tray"; case "reminder": "bell"; case "sms": "message"; case "plaud": "waveform"; case "weather": "cloud.sun"; default: "doc" }
}


private func evidenceKindName(_ kind: String) -> String {
    ["mail": "邮件", "event": "日程", "project": "项目", "task": "任务", "finance": "账本", "goal": "目标", "wechat": "微信", "health": "身体", "todo": "行动台", "inbox": "速记", "reminder": "提醒事项", "sms": "短信", "plaud": "录音纪要", "weather": "天气"][kind] ?? "资料"
}

// MARK: - 依据袋（r3-pages：动效还原到第一版）

/// 依据袋：像一只文件袋，纸片从袋口探出一截。按下去纸片就错峰弹出来，松手留在外面；再点一下滑回袋里。
/// 点某一张纸：它摆正、整张抽出来（其余几张滑回袋里），原始来源那一页从底下滑上来，在那一页还能继续跳到事项 / 任务 / 项目进展 / 原文；
/// 看完收起，纸片再落回扇形。
/// 动效（r3-pages 还原第一版 v0，即 Hamad Tanveer「Just Playing with Motion」文件袋；纸片样式沿用 r2）：
/// - 出袋：按下即起，和展开是同一个状态（v0 的 up = open || pressed）；纸片 spring(0.42, 0.58) 带倾角弹出，
///   每张晚 60ms（≈ 动效库 04-screenshot-cascade「每 2 帧发一张」）；
/// - 入袋：spring(0.32, 0.9)，反序每张晚 30ms；
/// - 卡片高度：spring(0.4, 0.82)，和下面的按钮在同一个动画事务里走；入袋时等最后一张纸起步再收，纸片不会冒出卡片顶（模拟见验收记录）；
/// - 抽一张：.smooth(0.2) 摆正、整张提出袋口，别的按入袋参数滑回；纸片站稳（220ms）后用普通 sheet 打开详情，收起后别的按出袋参数弹回。
/// r3 录屏抽帧查到的闪屏根因：① 开合不在动画事务里，卡片高度和按钮瞬间跳、袋子还在半路，互相压住；
/// ② 原来的飞行模糊用 if/else 包住纸片，开合时纸片身份翻转，新旧两份交叉淡入淡出成重影；
/// ③ 系统 zoom 转场：源纸片落回时底边一道黑线（摆正抽出后仍在），推近途中详情按小尺寸排版、文字两份叠着重排。所以改成普通 sheet。
private struct EvidencePocket: View {
    let evidence: [JSON]
    let itemID: String
    let itemTitle: String
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var open = false
    @State private var pressing = false
    /// 抽出来、正在看详情的那张。
    @State private var lifted: Int?
    @State private var picked: PickedSlip?
    private struct PickedSlip: Identifiable { let id: Int }

    private static let pocketHeight: CGFloat = 58
    private static let slipHeight: CGFloat = 100
    /// 飞出来后纸片底部还塞在袋口里的深度。
    private static let tuck: CGFloat = 24
    private static let tilts: [Double] = [-4, 3.5, -2, 5, -3]

    private var slips: [(offset: Int, element: JSON)] { Array(evidence.prefix(5).enumerated()) }
    /// v0 的结构：按住和展开是同一个「出袋」状态。
    private var up: Bool { open || pressing }
    private var height: CGFloat { up ? Self.pocketHeight - Self.tuck + Self.slipHeight + 14 : Self.pocketHeight + 8 }

    var body: some View {
        GeometryReader { geo in
            let count = CGFloat(slips.count)
            let width = min(158, max(108, (geo.size.width - 16) / count + (count > 1 ? 22 : 0)))
            let step = count > 1 ? (geo.size.width - 16 - width) / (count - 1) : 0
            ZStack(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) {
                    ForEach(slips, id: \.offset) { index, row in
                        slipButton(row, index: index, width: width)
                            .rotationEffect(.degrees(tilt(index)), anchor: .bottom)
                            .offset(x: 8 + CGFloat(index) * step, y: lift(index))
                            .zIndex(Double(-index))
                            .animation(slipAnimation(index), value: up)
                            .animation(pickAnimation(index), value: lifted)
                    }
                }
                // 遮罩按整条宽度算（纸片是 offset 出去的，不撑大 ZStack）；只露袋口以上：收着时纸片的下半截藏在袋子下面。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .mask { Rectangle().padding(.top, -400).padding(.horizontal, -80) }
                pocket
            }
            // GeometryReader 默认把子视图贴左上角、按内容定高；这里撑满，袋子才贴在底边。
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .frame(height: height)
        .sheet(item: $picked, onDismiss: { withAnimation(reduce ? nil : .default) { lifted = nil } }) { pick in
            EvidenceDetail(evidence: evidence[pick.id], itemID: itemID, index: pick.id, itemTitle: itemTitle)
        }
    }

    private func out(_ index: Int) -> Bool { up && (lifted == nil || lifted == index) }
    private func tilt(_ index: Int) -> Double {
        if reduce || lifted == index { return 0 }
        return out(index) ? Self.tilts[index] : 0
    }
    /// 纸片底边相对袋子底边的位移：收着时只露出顶上 7pt；出袋时整张飞出、底部塞在袋口里；抽中的那张再整张提出袋口。
    private func lift(_ index: Int) -> CGFloat {
        if lifted == index { return -Self.pocketHeight }
        return out(index) ? -(Self.pocketHeight - Self.tuck) : Self.slipHeight - Self.pocketHeight - 7
    }
    /// v0 原参数：出袋 spring(0.42, 0.58) 每张晚 60ms；入袋 spring(0.32, 0.9) 反序每张晚 30ms。
    private func slipAnimation(_ index: Int) -> Animation {
        if reduce { return .easeOut(duration: 0.2) }
        return up ? .spring(response: 0.42, dampingFraction: 0.58).delay(Double(index) * 0.06)
                  : .spring(response: 0.32, dampingFraction: 0.9).delay(Double(slips.count - 1 - index) * 0.03)
    }
    /// 抽一张：它 .smooth(0.2) 摆正提出，别的按入袋参数滑回去；看完回来，别的按出袋参数弹回扇形。
    private func pickAnimation(_ index: Int) -> Animation {
        if reduce { return .easeOut(duration: 0.2) }
        if lifted == nil { return .spring(response: 0.42, dampingFraction: 0.58).delay(Double(index) * 0.06) }
        return lifted == index ? .smooth(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.9)
    }
    /// 卡片高度和下面的按钮同走一条弹簧；入袋要等最后一张纸起步（反序错峰的总时长）再收。
    private func layoutAnimation(goingUp: Bool) -> Animation {
        if reduce { return .easeOut(duration: 0.2) }
        let spring = Animation.spring(response: 0.4, dampingFraction: 0.82)
        return goingUp ? spring : spring.delay(Double(slips.count - 1) * 0.03)
    }
    private func press(_ value: Bool) {
        if value {
            withAnimation(layoutAnimation(goingUp: true)) { pressing = true }
        } else {
            // 松手时按钮动作（open.toggle）和 isPressed 归零在同一轮；晚一拍再放掉 pressing，出袋状态不会在中间闪回一下。
            DispatchQueue.main.async { withAnimation(layoutAnimation(goingUp: open)) { pressing = false } }
        }
    }
    private func pick(_ index: Int) {
        if reduce { lifted = index; picked = PickedSlip(id: index); return }
        withAnimation(.smooth(duration: 0.2)) { lifted = index }
        // 纸片抽出来站稳了，详情再滑上来。
        Task { try? await Task.sleep(for: .milliseconds(220)); picked = PickedSlip(id: index) }
    }

    private var pocket: some View {
        Button {
            withAnimation(layoutAnimation(goingUp: !open || pressing)) { open.toggle() }
        } label: {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    // 两句字接力换：旧的 0.1s 淡出，新的晚 0.08s 再 0.15s 淡入，合起来还是 v0 的 0.25s。
                    // 同一位置交叉淡入时两串字压在一起，抽帧看像花屏，所以不重叠。
                    ZStack(alignment: .leading) {
                        Text("依据 · \(evidence.count) 份").opacity(open ? 0 : 1).animation(labelFade(showing: !open), value: open)
                        Text("点一张看原文").opacity(open ? 1 : 0).animation(labelFade(showing: open), value: open)
                    }
                    .font(TypeScale.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                    Text(kinds).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    // 箭头沿用 v0 点按时的 .smooth(0.25)。
                    .animation(reduce ? nil : .smooth(duration: 0.25), value: open)
                    .frame(width: 30, height: 30).background(Palette.surface, in: .circle)
            }
            .padding(.horizontal, Space.lg)
            .frame(maxWidth: .infinity, minHeight: Self.pocketHeight, maxHeight: Self.pocketHeight)
            .background(Palette.fill, in: .rect(cornerRadius: Radius.md, style: .continuous))
            // 袋口那圈厚边：外圈卡面色，再描一道细线，压住后面的纸。
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.surface, lineWidth: 3))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(up ? 0.06 : 0.03), radius: up ? 10 : 4, y: up ? -2 : 0)
            .scaleEffect(pressing && !open ? 0.985 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(PocketPress(onPress: press))
        .sensoryFeedback(.impact(weight: .light), trigger: pressing) { _, now in now }
        .accessibilityLabel(open ? "收起依据" : "依据 \(evidence.count) 份")
        .accessibilityIdentifier("next-evidence-" + itemID)
    }

    private func labelFade(showing: Bool) -> Animation? {
        if reduce { return nil }
        return showing ? .easeIn(duration: 0.15).delay(0.08) : .easeOut(duration: 0.1)
    }

    private func slipButton(_ row: JSON, index: Int, width: CGFloat) -> some View {
        Button { pick(index) } label: {
            EvidenceSlip(evidence: row, width: width, height: Self.slipHeight)
        }
        .buttonStyle(SlipPress())
        .allowsHitTesting(open && lifted == nil)
        .accessibilityHidden(!open)
        .accessibilityLabel(row["label"].string)
        .accessibilityIdentifier("next-evidence-slip-\(itemID)-\(index)")
    }

    private var kinds: String {
        var seen: [String] = []
        for kind in evidence.map({ evidenceKindName($0["kind"].string) }) where !seen.contains(kind) { seen.append(kind) }
        return seen.joined(separator: "、")
    }
}

/// 一张依据纸：来源、标题、时间。收着时只露出顶边，飞出来后整张可读。
private struct EvidenceSlip: View {
    let evidence: JSON
    let width: CGFloat
    let height: CGFloat
    private var detail: JSON { evidence["detail"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: evidenceSymbol(evidence["kind"].string)).font(.system(size: 9, weight: .semibold))
                Text(source).lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Palette.textSecondary)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textPrimary).lineLimit(2)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(evidenceWhen(evidence)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 30)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Palette.surface, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
    }
    private var source: String {
        let label = detail["source_label"].string
        return label.isEmpty ? (evidence["label"].string.components(separatedBy: " · ").first ?? evidenceKindName(evidence["kind"].string)) : label
    }
    private var title: String {
        let t = detail["title"].string
        return t.isEmpty ? (evidence["label"].string.components(separatedBy: " · ").last ?? "") : t
    }
}

/// 依据的时间：日程写几号几点到几点，其余写相对时间。
private func evidenceWhen(_ evidence: JSON) -> String {
    let detail = evidence["detail"]
    let at = detail["at"].double
    guard at > 0 else { return "" }
    if evidence["kind"].string == "event" {
        let day = Date(timeIntervalSince1970: at).formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
        let end = detail["end"].double
        return day + " " + clockTime(at) + (end > at ? "–" + clockTime(end) : "")
    }
    return relativeTime(at)
}

/// 按住袋子：把按压状态交给依据袋，按下就出袋（v0 是在 ButtonStyle 里直接读 isPressed）。
private struct PocketPress: ButtonStyle {
    let onPress: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, value in onPress(value) }
    }
}

private struct SlipPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1, anchor: .bottom)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 一份依据的原始来源。纸片抽出来后从底下滑上来；能继续跳到事项详情、任务详情、项目进展、原文链接。
/// 动效：纸面 3D 落定 = 动效库 09-float-card-3d（白卡带倾角浮入、摆一下定住）；标题荧光笔从左扫入 = 05-tweet-highlight（10 帧 power2.out）。
private struct EvidenceDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    let evidence: JSON
    let itemID: String
    let index: Int
    let itemTitle: String
    @State private var landed = false
    @State private var marked = false
    @State private var matter: JSON?
    @State private var task: JSON?
    @State private var board: JSON?
    private var detail: JSON { evidence["detail"] }
    private var kind: String { evidence["kind"].string }
    private var title: String { detail["title"].string.isEmpty ? (evidence["label"].string.components(separatedBy: " · ").last ?? "") : detail["title"].string }

    var body: some View {
        DetailPage(title: "依据") {
            paper
            if !detail["summary"].string.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(kind == "mail" ? "原文摘要" : "摘要").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                        Text(detail["summary"].string).font(TypeScale.body).foregroundStyle(Palette.textPrimary).lineSpacing(3)
                    }
                }
                .modifier(Rise(on: landed, delay: 0.12, reduce: reduce))
            }
            if kind == "wechat", !detail["messages"].array.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("最近几句").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                        ForEach(Array(detail["messages"].array.enumerated()), id: \.offset) { _, m in
                            HStack(alignment: .top, spacing: Space.sm) {
                                Text(m["sender"].string).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                                    .frame(width: 58, alignment: .leading).lineLimit(1)
                                Text(m["text"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .modifier(Rise(on: landed, delay: 0.14, reduce: reduce))
            }
            if !detail["next_step"].string.isEmpty {
                Card(.inset) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("那边记的下一步").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                        LinedText(text: detail["next_step"].string)
                    }
                }
                .modifier(Rise(on: landed, delay: 0.16, reduce: reduce))
            }
            if detail.isNull {
                Text("这条依据只记了标题，原始来源已经不在了。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
            jumps.modifier(Rise(on: landed, delay: 0.2, reduce: reduce))
            // 和「继续看」同一拍上浮：r3 抽帧看到它原地不动时会被正在上浮的那块压住。
            Text("支撑的建议：" + itemTitle).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.xs)
                .modifier(Rise(on: landed, delay: 0.2, reduce: reduce))
        }
        .accessibilityIdentifier("next-evidence-detail-\(itemID)-\(index)")
        // r3：先让 sheet 按最终尺寸排好版再起动画（时间点和原来一样：80ms 落纸、420ms 荧光笔）。
        // 原来在 onAppear 里同一个事务改状态，首帧的排版（摘要先按窄宽度排）也被做成了带延迟的弹簧，抽帧看到摘要先窄后宽、两份叠着。
        .task {
            if reduce { landed = true; marked = true; return }
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.spring(response: 0.62, dampingFraction: 0.66)) { landed = true }
            try? await Task.sleep(for: .milliseconds(340))
            withAnimation(.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.34)) { marked = true }
        }
        // 从事项详情里「交给 Com」会切到聊天页，这一页也一起收起。
        .onChange(of: model.tab) { _, _ in dismiss() }
        .sheet(item: rowBinding($matter)) { MatterDetailView(matter: $0.value).presentationDragIndicator(.visible) }
        .sheet(item: rowBinding($task)) { TaskDetailView(task: $0.value).presentationDragIndicator(.visible) }
        .sheet(item: rowBinding($board)) { BoardSourceView(item: $0.value) }
    }

    /// 纸面：来源 · 标题（荧光笔）· 时间、发件人、地点这些元信息。
    private var paper: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Stamp(text: evidenceKindName(kind), tone: .accent)
                let source = detail["source_label"].string.isEmpty ? (evidence["label"].string.components(separatedBy: " · ").first ?? "") : detail["source_label"].string
                if !source.isEmpty && source != title { Text(source).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary) }
                Spacer(minLength: 0)
                Image(systemName: evidenceSymbol(kind)).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.textTertiary)
            }
            Text(title).font(TypeScale.title).foregroundStyle(Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                .background(alignment: .bottomLeading) {
                    GeometryReader { geo in
                        Capsule().fill(Palette.accent.opacity(0.55))
                            .frame(width: geo.size.width * (marked ? 1 : 0), height: max(10, geo.size.height * 0.42))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .offset(y: 1)
                    }
                    .padding(.horizontal, -3)
                }
            let meta: [(String, String)] = [("时间", evidenceWhen(evidence)), (kind == "wechat" ? "谁说的" : "发件人", detail["sender"].string),
                                             ("聊天", detail["group"].string), ("地点", detail["location"].string), ("日历", detail["calendar"].string),
                                             ("在哪", [hostName(detail["host"].string), agentName(detail["agent"].string)].filter { !$0.isEmpty }.joined(separator: " · "))]
                .filter { !$0.1.isEmpty }
            if !meta.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(meta, id: \.0) { label, value in
                        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                            Text(label).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).frame(width: 44, alignment: .leading)
                            Text(value).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(landed ? 0.06 : 0.14), radius: landed ? 12 : 24, y: landed ? 6 : 16)
        // 09：带倾角浮进来，摆一下定住。
        .rotation3DEffect(.degrees(landed ? 0 : 14), axis: (x: 1, y: -0.4, z: 0), anchor: .bottom, perspective: 0.6)
        .scaleEffect(landed ? 1 : 0.94, anchor: .bottom)
    }

    @ViewBuilder private var jumps: some View {
        let link = detail["link"].string.isEmpty ? evidence["link"].string : detail["link"].string
        let matterID = evidence["matter_id"].string
        let taskID = evidence["task_id"].string
        let project = evidence["item_id"].string.isEmpty ? (kind == "project" ? String(evidence["ref"].string.dropFirst("project:".count)) : "") : evidence["item_id"].string
        let taskRow = model.tasks.first(where: { $0.id == taskID })
        if !matterID.isEmpty || taskRow != nil || !project.isEmpty || URL(string: link) != nil && !link.isEmpty {
            GroupSection("继续看") {
                GroupedCard(dividerInset: 56) {
                    if !matterID.isEmpty {
                        Button { openMatter(matterID) } label: { ListRow(symbol: "doc.text.magnifyingglass", tone: .accent, title: kind == "event" ? "看这个日程" : kind == "wechat" ? "看这条微信" : "看这封邮件", subtitle: "事项详情：交给 Com、标记处理、纠正") }
                            .buttonStyle(.row).accessibilityIdentifier("evidence-jump-matter")
                    }
                    if let taskRow {
                        Button { task = taskRow } label: { ListRow(symbol: "checkmark.square", tone: .info, title: "看任务", subtitle: taskRow["title"].string) }
                            .buttonStyle(.row).accessibilityIdentifier("evidence-jump-task")
                    }
                    if !project.isEmpty {
                        Button { board = boardRow(project) } label: { ListRow(symbol: "desktopcomputer", tone: .info, title: "看项目进展", subtitle: "会话里的原话和进展快照") }
                            .buttonStyle(.row).accessibilityIdentifier("evidence-jump-project")
                    }
                    if let url = URL(string: link), !link.isEmpty {
                        Link(destination: url) { ListRow(symbol: "arrow.up.right", title: "打开原文", subtitle: url.host() ?? link) }
                            .buttonStyle(.row).accessibilityIdentifier("evidence-jump-link")
                    }
                }
            }
        }
    }

    /// 邮件和日程按 matter 打开事项详情：事项卡里有就用那份（带完整事实），没有就用依据里记下的。
    private func openMatter(_ id: String) {
        if let card = model.agencyCards.first(where: { $0.id == id }) { matter = card; return }
        var facts: [String: JSON] = [:]
        for (key, name) in [("sender", kind == "wechat" ? "谁说的" : "发件人"), ("group", "聊天"), ("location", "地点"), ("calendar", "日历"), ("summary", "摘要")] where !detail[key].string.isEmpty { facts[name] = detail[key] }
        matter = .object(["id": .string(id), "title": detail["title"].isNull ? evidence["label"] : detail["title"], "what": detail["summary"],
                          "source": detail["source"], "facts": .object(facts)])
    }
    private func boardRow(_ id: String) -> JSON {
        for project in model.datasets["/personal/projects"]?["projects"].array ?? [] {
            if let item = project["items"].array.first(where: { $0.id == id }) { return item }
        }
        return .object(["id": .string(id), "title": detail["title"], "host": detail["host"], "agent": detail["agent"]])
    }
    private func rowBinding(_ value: Binding<JSON?>) -> Binding<RemoteRow?> {
        Binding(get: { value.wrappedValue.map(RemoteRow.init) }, set: { value.wrappedValue = $0?.value })
    }
}

/// 详情里各块跟着纸面错峰上浮（动效库 20-build-checklist 的「上浮、错峰 2 帧」）。
/// r3 去掉了模糊：推近途中带 6pt 模糊的整段字是一团灰影，抽帧看就是闪的那几帧。
private struct Rise: ViewModifier {
    let on: Bool
    let delay: Double
    let reduce: Bool
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || reduce ? 0 : 18)
            .animation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86).delay(delay), value: on)
    }
}
