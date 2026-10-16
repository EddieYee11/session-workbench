import SwiftUI
import ComCore

// r2-chat · 助手回复下面的「下一步」建议卡。
// 后端把模型末行的 `[[选项: A | B | C]]` 剥成 message.suggestions；客户端再兜一层：
// 后端还没部署、或流式中途标记先露出来时，也不让原始标记闪现。

enum ReplyOptions {
    private static let full = try! NSRegularExpression(pattern: #"\s*\[\[\s*选项\s*[:：]([^\[\]]*)\]\]\s*$"#)

    /// 去掉末尾完整或半截的选项标记，返回 (正文, 选项)。
    static func split(_ text: String) -> (String, [String]) {
        let ns = text as NSString
        if let match = full.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            var options: [String] = []
            for raw in ns.substring(with: match.range(at: 1)).split(whereSeparator: { $0 == "|" || $0 == "｜" }) {
                let option = raw.trimmingCharacters(in: CharacterSet(charactersIn: " 「」\"'"))
                if !option.isEmpty, option.count <= 16, !options.contains(option) { options.append(option) }
            }
            return (ns.substring(to: match.range.location).trimmingCharacters(in: .whitespacesAndNewlines), Array(options.prefix(3)))
        }
        // 半截：末尾的 `[`、`[[选`、`[[选项: 帮我…` 先藏起来。
        guard let bracket = text.lastIndex(of: "[") else { return (text, []) }
        var start = bracket
        while start > text.startIndex, text[text.index(before: start)] == "[" { start = text.index(before: start) }
        let tail = text[start...].filter { !$0.isWhitespace }.replacingOccurrences(of: "：", with: ":")
        if !tail.contains("]") && ("[[选项".hasPrefix(tail) || tail.hasPrefix("[[选项")) {
            return (String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        return (text, [])
    }

    /// 消息上的选项：优先用后端字段，没有就从正文末行解析。
    static func options(for message: JSON) -> [String] {
        let field = message["suggestions"].array.map(\.string).filter { !$0.isEmpty }
        if !field.isEmpty { return Array(field.prefix(3)) }
        return split(message["text"].string).1
    }

    /// 按字面挑一个图标，让卡片一眼能分出「推进 / 查看 / 放下」。
    static func symbol(for option: String) -> String {
        let rules: [([String], String)] = [
            (["先不", "不用", "算了", "跳过", "不管", "取消", "以后"], "hand.raised"),
            (["详情", "看看", "查看", "展开", "明细", "看下"], "doc.text.magnifyingglass"),
            (["提醒", "闹钟"], "bell"),
            (["明天", "后天", "下周", "改到", "推迟", "日程", "安排"], "calendar"),
            (["记", "存", "收藏", "保存"], "square.and.arrow.down"),
            (["改", "调整", "换", "重写"], "pencil"),
            (["发", "回复", "告诉"], "paperplane"),
            (["继续", "好", "可以", "确认", "就这样", "开始", "去做"], "checkmark"),
        ]
        return rules.first { $0.0.contains(where: option.contains) }?.1 ?? "arrow.turn.down.right"
    }
}

/// 最新一条助手回复下面的 2–3 个建议卡，点一下就当作 Eddie 的回话发出。
struct SuggestionChips: View {
    let messageID: String
    let options: [String]
    let choose: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    @State private var picked: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label("下一步", systemImage: "sparkle")
                .font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
                .labelStyle(.titleAndIcon)
                .opacity(shown ? 1 : 0)
            FlowLayout(spacing: Space.sm) {
                ForEach(Array(options.enumerated()), id: \.element) { index, option in
                    Button {
                        guard picked == nil else { return }
                        Haptics.sent()
                        withAnimation(reduce ? .linear(duration: 0.12) : ReplyMotion.pop) { picked = option }
                        choose(option)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: ReplyOptions.symbol(for: option)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accentText)
                            Text(option).font(TypeScale.subheadline.weight(.medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 40)
                        .background(Palette.surface, in: .capsule)
                        .overlay(Capsule().strokeBorder(picked == option ? Palette.accent : Palette.separator, lineWidth: picked == option ? 1.5 : 0.5))
                        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(MessagePressStyle())
                    .accessibilityIdentifier("suggestion-\(index)")
                    // 动效库 15-bubble-glow-logo：气泡 back.out 弹出（从尾巴处小角度旋转放大落定）；
                    // 动效库 20-build-checklist：各行错峰 2 帧（≈0.07s）；整组等回复正文上浮落定（≈0.32s）后再弹。
                    .scaleEffect(shown ? (picked == nil || picked == option ? 1 : 0.92) : 0.6, anchor: .topLeading)
                    .rotationEffect(.degrees(shown || reduce ? 0 : -6), anchor: .topLeading)
                    .opacity(shown ? (picked == nil || picked == option ? 1 : 0) : 0)
                    .animation(reduce ? .linear(duration: 0.15) : ReplyMotion.pop.delay(0.32 + Double(index) * 0.07), value: shown)
                }
            }
        }
        .padding(.horizontal, Space.xs)
        .padding(.top, Space.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("suggestion-chips")
        .onAppear { shown = true }
        // 验收修正：.id 放在 ChatView 调用处（按消息 id），换到新回复时 shown 才会重置、重新弹入。
    }
}
