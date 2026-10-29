import SwiftUI
import ComCore

/// Com 空对话的伙伴存在感（Grok Bot 式「有人在」+ Muse 式对话重心）。
/// 有「等你 / 下一步」时优先给行动入口；否则用时段问候 + 可点的开口提示。
struct ChatEmptyPresence: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    /// starter 发送中：失败可再点；成功空态会被时间线顶替。
    @State private var sending = false
    /// starter 发送失败开口（Composer 未必在视野里）。
    @State private var starterFail = ""

    /// 问候按上海时区切，避免设备时区漂到别处时早晚说错。
    private var hour: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal.component(.hour, from: Date())
    }

    private var greeting: String {
        if model.waitingInboxCount > 0 {
            switch hour {
            case 5..<11: return "早。有件事想先跟你对齐"
            case 11..<14: return "中午好。先办要紧的"
            case 14..<18: return "下午。我拦了一件等你"
            case 18..<23: return "晚上。还差你点一下"
            default: return "还醒着？有件事先说"
            }
        }
        switch hour {
        case 5..<11: return "早，我在这儿"
        case 11..<14: return "中午好，随时叫我"
        case 14..<18: return "下午好，我闲着"
        case 18..<23: return "晚上好，还在岗"
        default: return "还没睡？我醒着"
        }
    }

    private var statusLine: String {
        if !model.isPaired { return "先连上 Mac mini，我才能动手。" }
        if model.waitingInboxCount > 0 {
            if let tip = ChatAttentionHint.topWaitingTitle(model) {
                let more = model.waitingInboxCount > 1 ? "（还有 \(model.waitingInboxCount - 1) 件）" : ""
                return "先看这一件：\(tip)\(more)。点下面去拍板，或直接跟我说怎么处理。"
            }
            return "有 \(model.waitingInboxCount) 件在等你拍板。办完再聊也行，或者直接跟我说怎么处理。"
        }
        if model.nextUrgentCount > 0 {
            if let tip = ChatAttentionHint.topNextTitle(model) {
                return "「下一步」里最要紧的是：\(tip)。点下面，或告诉我先办哪件。"
            }
            return "「下一步」里有 \(model.nextUrgentCount) 件现在就该看的。点下面，或直接告诉我先办哪件。"
        }
        if let broken = model.brokenSources.first {
            return "读不到 \(sourceName(broken["name"].string)) 了——修一下，或先跟我说别的。"
        }
        if model.casesData["active"].int > 0 {
            return "我这边有 \(model.casesData["active"].int) 段航程在跑。问进度，或丢给我下一件事。"
        }
        // 空闲人格：像活人值班，不是功能清单。
        switch hour {
        case 5..<11: return "邮件、日历和账本我扫过了。今天想先办哪件，直接丢给我。"
        case 11..<14: return "这会儿安静。记一笔、改日程、查邮件——开口就行。"
        case 14..<18: return "我还在看两边电脑。有事随时叫，不用先找菜单。"
        case 18..<23: return "晚上也在岗。琐事丢过来，我帮你收口。"
        default: return "夜深了我也醒着。一句话能办的，现在说也行。"
        }
    }

    private var starters: [(label: String, action: StarterAction)] {
        var items: [(String, StarterAction)] = []
        let attention = model.waitingInboxCount > 0 || model.nextUrgentCount > 0
        if model.waitingInboxCount > 0 {
            let tip = ChatAttentionHint.topWaitingTitle(model)
            items.append((tip.map { "去拍板：\($0)" } ?? "去处理等你的 \(model.waitingInboxCount) 件", .waiting))
        }
        if model.nextUrgentCount > 0 {
            let tip = ChatAttentionHint.topNextTitle(model)
            items.append((tip.map { "下一步：\($0)" } ?? "看看下一步", .next))
        }
        // 有等待/下一步时最多再塞一个轻开口，避免按钮墙；空闲才给到三枚。
        let cap = attention ? 2 : 3
        if items.count < cap {
            let prompts: [(String, StarterAction)] = [
                ("记一笔开销", .send("记一下咖啡18")),
                ("明天要准备什么", .send("明天要准备什么")),
                ("这个月花了多少", .send("这个月花了多少")),
                ("有什么该我拍板的", .waiting),
            ]
            for p in prompts where items.count < cap {
                if case .waiting = p.1, model.waitingInboxCount == 0, items.contains(where: { if case .waiting = $0.1 { return true }; return false }) { continue }
                if items.contains(where: { $0.0 == p.0 }) { continue }
                items.append(p)
            }
        }
        return items
    }

    private enum StarterAction {
        case send(String)
        case waiting
        case next
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(alignment: .bottom, spacing: Space.md) {
                StripFigure(
                    state: model.stripState,
                    sign: model.stripSign,
                    animated: model.active,
                    quiet: false,
                    hop: nil,
                    outfit: .chat
                )
                .frame(width: StripFigure.bodyWidth + 6, height: StripFigure.size.height, alignment: .leading)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(greeting)
                        .font(TypeScale.title)
                        .foregroundStyle(Palette.textPrimary)
                    Text(model.stripCaption)
                        .font(TypeScale.footnote.weight(.medium))
                        .foregroundStyle(model.waitingInboxCount > 0 ? Palette.warning : Palette.accentText)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .attentionBreath(active: model.waitingInboxCount > 0 && !reduce)
                }
                Spacer(minLength: 0)
            }
            .modifier(EnterRise(on: shown, delay: 0, y: 18, blur: 8, animation: ComMotion.pop))

            Text(statusLine)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: statusLine)
                .modifier(EnterRise(on: shown, delay: 0.06, y: 14, blur: 6, animation: ComMotion.rise))

            if !starterFail.isEmpty {
                InlineNotice(text: starterFail, tone: .danger)
                    .accessibilityIdentifier("chat-presence-starter-fail")
                    .modifier(EnterRise(on: shown, delay: 0.08, y: 10, blur: 4, animation: ComMotion.rise))
            }

            FlowLayout(spacing: Space.sm + 2) {
                ForEach(Array(starters.enumerated()), id: \.offset) { index, item in
                    let primary = index == 0 && (model.waitingInboxCount > 0 || model.nextUrgentCount > 0)
                    let waitingBusy: Bool = {
                        if case .waiting = item.1 { return model.waitingOpening }
                        return false
                    }()
                    let busy = sending || waitingBusy
                    Button {
                        guard !busy else { return }
                        Haptics.selection()
                        run(item.1)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: waitingBusy ? "hourglass" : symbol(for: item.1))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(primary ? Palette.warning : Palette.accentText)
                            Text(waitingBusy ? "打开中…" : item.0)
                                .font(TypeScale.subheadline.weight(.medium))
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Space.lg - 2)
                        .frame(height: 40)
                        .background(primary ? Palette.warning.opacity(0.12) : Palette.surface, in: .capsule)
                        .overlay(Capsule().strokeBorder(primary ? Palette.warning.opacity(0.35) : Palette.separator, lineWidth: primary ? 1 : 0.5))
                        .contentShape(.capsule)
                        .opacity(busy ? 0.55 : 1)
                    }
                    .buttonStyle(SoftPressStyle())
                    .disabled(busy)
                    .accessibilityIdentifier("chat-presence-starter-\(index)")
                    .modifier(EnterRise(on: shown, delay: 0.12 + Double(index) * 0.05, y: 10, blur: 4, animation: ComMotion.pop))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.xxl)
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-empty-presence")
        .onAppear {
            if reduce { shown = true }
            else { withAnimation { shown = true } }
        }
        .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: model.waitingInboxCount)
        .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: model.nextUrgentCount)
    }

    private func symbol(for action: StarterAction) -> String {
        switch action {
        case .waiting: return "hand.raised.fill"
        case .next: return "arrow.turn.up.right"
        case .send(let text):
            if text.contains("花") || text.contains("记") { return "yensign.circle" }
            if text.contains("明天") || text.contains("准备") { return "calendar" }
            return "bubble.left"
        }
    }

    private func run(_ action: StarterAction) {
        switch action {
        case .send(let text):
            sending = true
            starterFail = ""
            Task {
                let ok = await model.send(textOverride: text)
                // 失败才放开 + 窗内开口；成功空态会被消息顶替，不必抢回按钮。
                if !ok {
                    sending = false
                    starterFail = model.chatComposerNote.isEmpty
                        ? "没发出去——还可以再点上面那句。不会假装已说出口。"
                        : model.chatComposerNote
                }
            }
        case .waiting:
            guard !model.waitingOpening else { return }
            starterFail = ""
            model.openWaitingInbox()
        case .next:
            starterFail = ""
            model.tab = .next
        }
    }
}

/// 对话进行中仍把「有事找你」挂在输入区上方（Muse 式对话重心，不逼你离开聊天）。
/// Hark：同一时刻只推一件——优先「等你」，否则「下一步」；一行标题 + 一个动作，不堆芯片墙。
struct ChatAttentionStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false

    private var waiting: Int { model.waitingInboxCount }
    private var next: Int { model.nextUrgentCount }
    private var visible: Bool { waiting > 0 || next > 0 }
    /// 有等待就盯等待；否则才提下一步（一卡一动作）。
    private var preferWaiting: Bool { waiting > 0 }
    private var tip: String? {
        preferWaiting ? ChatAttentionHint.topWaitingTitle(model) : ChatAttentionHint.topNextTitle(model)
    }
    private var headline: String {
        if preferWaiting {
            return waiting == 1 ? "有一件要你拍板" : "有 \(waiting) 件在等你，先看这件"
        }
        return next == 1 ? "下一步有一件现在就该看" : "下一步有 \(next) 件，先看这件"
    }
    private var openingWaiting: Bool { preferWaiting && model.waitingOpening }
    private var cta: String {
        if openingWaiting { return "打开中…" }
        return preferWaiting ? "去拍板" : "去看"
    }

    var body: some View {
        Group {
            if visible {
                Button {
                    guard !openingWaiting else { return }
                    Haptics.selection()
                    if preferWaiting { model.openWaitingInbox() }
                    else { model.tab = .next }
                } label: {
                    HStack(alignment: .center, spacing: Space.md) {
                        Image(systemName: openingWaiting ? "hourglass" : (preferWaiting ? "hand.raised.fill" : "arrow.turn.up.right"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(preferWaiting ? Palette.warning : Palette.accentText)
                            .frame(width: 28, height: 28)
                            .background((preferWaiting ? Palette.warning : Palette.accent).opacity(0.14), in: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(openingWaiting ? "正在打开等你…" : headline)
                                .font(TypeScale.footnote.weight(.semibold))
                                .foregroundStyle(preferWaiting ? Palette.warning : Palette.accentText)
                                .contentTransition(.numericText())
                            if !openingWaiting, let tip, !tip.isEmpty {
                                Text(tip)
                                    .font(TypeScale.subheadline.weight(.medium))
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if openingWaiting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(cta)
                                .font(TypeScale.footnote.weight(.semibold))
                                .foregroundStyle(preferWaiting ? Palette.warning : Palette.accentText)
                        }
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm + 2)
                    .background(Palette.surface, in: .rect(cornerRadius: Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder((preferWaiting ? Palette.warning : Palette.accent).opacity(0.28), lineWidth: 1)
                    )
                    .contentShape(.rect(cornerRadius: Radius.md))
                    .opacity(openingWaiting ? 0.72 : 1)
                }
                .buttonStyle(SoftPressStyle(scale: 0.985))
                .disabled(openingWaiting)
                .accessibilityIdentifier(preferWaiting ? "chat-attention-waiting" : "chat-attention-next")
                .accessibilityLabel((openingWaiting ? "正在打开等你" : headline) + (tip.map { "：\($0)" } ?? "") + "，" + cta)
                .attentionBreath(active: preferWaiting && !openingWaiting && !reduce)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.xs)
                .enterRise(on: shown, delay: 0, y: 8, blur: 4)
                .transition(.asymmetric(
                    insertion: reduce ? .opacity : .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .onAppear {
                    if reduce { shown = true }
                    else { withAnimation(ComMotion.pop) { shown = true } }
                }
            }
        }
        .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: visible)
        .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: tip)
        .accessibilityIdentifier("chat-attention-strip")
    }
}

/// 给空态与注意力条共用的「现在最要紧那一件」标题，避免只报件数。
@MainActor
enum ChatAttentionHint {
    static func topWaitingTitle(_ model: AppModel) -> String? {
        // Waiting API 已按 case → wechat → todo 排；优先它，避免派活/旧任务盖住航程停顿。
        if let item = model.waitingData["items"].array.first {
            let title = item["title"].string
            if !title.isEmpty { return shorten(title) }
            let why = item["why"].string
            if !why.isEmpty { return shorten(why) }
        }
        if let item = model.pendingItems.first(where: { !$0.stale }), !item.title.isEmpty {
            return shorten(item.title)
        }
        return nil
    }

    static func topNextTitle(_ model: AppModel) -> String? {
        let now = model.nextItems.first { $0["urgency"].string == "now" }
        let item = now ?? model.nextItems.first
        let title = item?["title"].string ?? ""
        return title.isEmpty ? nil : shorten(title)
    }

    private static func shorten(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 22 { return t }
        return String(t.prefix(21)) + "…"
    }
}
