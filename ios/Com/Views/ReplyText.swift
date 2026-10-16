import SwiftUI
import Textual

// 聊天轨道（chat）· 助手回复的排版。
// 目标：长回复读起来不累、一眼抓住重点。标题分层、粗体是重点、段落和列表之间有呼吸，行高放宽。
// 只给 Com 主聊天的助手消息用；其他页面仍用 DesignSystem 里的 RichText。
//
// r2-chat（10-10 第二轮）：
// - 结论句（lead）单独抽出来：放大一档、半粗、底下一道青柠荧光笔；
// - 模型给的是整段纯文本时，客户端兜底排版（切短段、并列项转列表、数字金额加粗），见 ReplyFormatter；
// - 新回复进场的动效移植自动效库（编号见各处注释），尊重「减少动态效果」。

struct ReplyText: View {
    let text: String
    /// 刚到的回复才播一次进场动效（翻历史、切页回来都是静止的），见 ReplyMotion.claim。
    var motionID: String? = nil
    var createdAt: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown: Bool
    @State private var sweep: CGFloat
    init(text: String, motionID: String? = nil, createdAt: Double = 0) {
        self.text = text; self.motionID = motionID; self.createdAt = createdAt
        // 验收修正：刚到的回复第一帧就从「藏起」开始，否则会先整句闪现一帧再模糊上浮。
        let fresh = motionID.map { ReplyMotion.isFresh($0, createdAt: createdAt) } ?? false
        _shown = State(initialValue: !fresh)
        _sweep = State(initialValue: fresh ? 0 : 1)
    }
    var body: some View {
        let layout = ReplyFormatter.layout(text)
        VStack(alignment: .leading, spacing: 0) {
            if let lead = layout.lead {
                ReplyLead(text: lead, sweep: sweep)
                    .padding(.bottom, layout.body.isEmpty ? 0 : 12)
                    // 动效库 20-build-checklist：标题模糊上浮（y+26→0、blur 10→0、power3.out，约 7 帧）。
                    .modifier(BlurRise(shown: shown, distance: 14, blur: 8))
            }
            if !layout.body.isEmpty {
                ReplyMarkdown(markdown: layout.body)
                    // 同一条 20：副标题晚 2 帧跟上（这里错峰 0.07s）。
                    .modifier(BlurRise(shown: shown, distance: 10, blur: 6))
                    .animation(reduce ? nil : ReplyMotion.rise.delay(0.07), value: shown)
            }
        }
        .animation(reduce ? nil : ReplyMotion.rise, value: shown)
        .animation(reduce ? nil : .smooth(duration: 0.28), value: layout.lead != nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard !reduce, let motionID, ReplyMotion.claim(motionID, createdAt: createdAt) else {
                // 已播过 / 减少动态效果：直接落定，不动。
                if !shown || sweep < 1 { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { shown = true; sweep = 1 } }
                return
            }
            Task { @MainActor in
                await Task.yield()
                shown = true
                // 动效库 05-tweet-highlight：荧光笔从左扫到右（10 帧 ≈ 0.33s，power2.out），落位后停住。
                withAnimation(ReplyMotion.sweep.delay(0.16)) { sweep = 1 }
            }
        }
    }
}

/// 结论句：放大一档的圆体半粗字 + 一道从左扫入的青柠荧光笔。
private struct ReplyLead: View {
    let text: String
    var sweep: CGFloat
    private var font: Font { .system(size: 19, weight: .semibold, design: .rounded) }
    var body: some View {
        // 荧光笔用逐行字形底色（真实折行几何），整层被一块从左往右展开的遮罩揭开——05 的扫入。
        var marked = AttributedString(text)
        marked.backgroundColor = Palette.accent.opacity(0.28)
        return ZStack(alignment: .topLeading) {
            Text(text)
            Text(marked).mask(alignment: .leading) { Rectangle().scaleEffect(x: sweep, y: 1, anchor: .leading) }
                .accessibilityHidden(true)
        }
        .font(font).lineSpacing(5).foregroundStyle(Palette.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reply-lead")
    }
}

/// 正文：Textual 渲染 Markdown，逐项样式离视图更近、优先生效。
private struct ReplyMarkdown: View {
    let markdown: String
    var body: some View {
        StructuredText(markdown: markdown)
            .textual.paragraphStyle(ReplyParagraphStyle())
            .textual.headingStyle(ReplyHeadingLevels())
            .textual.blockQuoteStyle(ReplyQuoteStyle())
            .textual.thematicBreakStyle(ReplyBreakStyle())
            .textual.listItemSpacing(.fontScaled(top: 0.5))
            .textual.unorderedListMarker(ReplyBulletMarker())
            .textual.orderedListMarker(ReplyNumberMarker())
            .textual.inlineStyle(InlineStyle()
                .code(.monospaced, .fontScale(0.88), .backgroundColor(Palette.fill))
                .strong(.fontWeight(.semibold), .backgroundColor(Palette.accent.opacity(0.32)))
                .link(.foregroundColor(Palette.info)))
            .textual.textSelection(.enabled)
            // 整套 GitHub 样式放最外层只做兜底（代码块、表格）；上面的逐项样式离视图更近，优先生效。
            .textual.structuredTextStyle(.gitHub)
            .font(TypeScale.body)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ReplyMotion {
    /// GSAP power3.out ≈ cubic-bezier(0.215, 0.61, 0.355, 1)。
    static let rise = Animation.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.34)
    /// GSAP power2.out ≈ cubic-bezier(0.25, 0.46, 0.45, 0.94)。
    static let sweep = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.36)
    /// GSAP back.out(1.7) 的弹簧近似：轻微过冲后落定。
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.62)
    /// 已经播过进场的消息（滚动重建、切页回来不重播）。
    @MainActor static var played: Set<String> = []
    /// 只给刚到（30 秒内）、还没播过的回复播一次。
    @MainActor static func isFresh(_ id: String, createdAt: Double) -> Bool {
        createdAt > 0 && Date().timeIntervalSince1970 - createdAt < 30 && !played.contains(id)
    }
    @MainActor static func claim(_ id: String, createdAt: Double) -> Bool {
        guard isFresh(id, createdAt: createdAt) else { return false }
        played.insert(id)
        return true
    }
}

/// 动效库 20-build-checklist 的「模糊上浮」：位移 + 高斯模糊 + 透明度一起收。
struct BlurRise: ViewModifier {
    let shown: Bool
    var distance: CGFloat = 12
    var blur: CGFloat = 6
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : distance).blur(radius: shown ? 0 : blur)
    }
}

/// 段落：行距放到字号的 0.45 倍，段后空一行多一点。
private struct ReplyParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.45))
            .textual.blockSpacing(.fontScaled(top: 0, bottom: 0.95))
    }
}

/// 标题：明显放大。一二级 22pt 圆体粗；三级（模型最常用的「### 小标题」）20pt 圆体粗，左边一粒青柠竖条；更低的是次级小标题。
private struct ReplyHeadingLevels: StructuredText.HeadingStyle {
    func makeBody(configuration: Configuration) -> some View {
        switch configuration.headingLevel {
        case 1, 2:
            configuration.label
                .font(.system(.title2, design: .rounded, weight: .bold))
                .textual.lineSpacing(.fontScaled(0.15))
                .textual.blockSpacing(.init(top: 26, bottom: 10))
        case 3:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 4, height: 16).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                configuration.label.font(.system(.title3, design: .rounded, weight: .bold))
            }
            .textual.blockSpacing(.init(top: 22, bottom: 8))
        default:
            configuration.label
                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                .textual.blockSpacing(.init(top: 16, bottom: 6))
        }
    }
}

/// 引用：左侧青柠细线，字退一档颜色。
private struct ReplyQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3)
            configuration.label.foregroundStyle(Palette.textSecondary)
                .textual.padding(.horizontal, .fontScaled(0.8))
        }
        .fixedSize(horizontal: false, vertical: true)
        .textual.blockSpacing(.fontScaled(top: 0.2, bottom: 0.9))
    }
}

private struct ReplyBreakStyle: StructuredText.ThematicBreakStyle {
    func makeBody(configuration _: Configuration) -> some View {
        Rectangle().fill(Palette.separator).frame(height: 0.5)
            .textual.blockSpacing(.init(top: 18, bottom: 18))
    }
}

/// 无序列表：小圆点，一级用青柠深色，更深层次退成灰。
private struct ReplyBulletMarker: StructuredText.UnorderedListMarker {
    func makeBody(configuration: Configuration) -> some View {
        Image(systemName: configuration.indentationLevel > 1 ? "circle" : "circle.fill")
            .textual.fontScale(0.3)
            .foregroundStyle(configuration.indentationLevel > 1 ? Palette.textTertiary : Palette.accentText)
            .textual.frame(minWidth: .fontScaled(1.1), alignment: .center)
    }
}

/// 有序列表：圆体粗数字，青柠深色，不加句点。
private struct ReplyNumberMarker: StructuredText.OrderedListMarker {
    func makeBody(configuration: Configuration) -> some View {
        Text("\(configuration.ordinal)")
            .font(.system(.callout, design: .rounded, weight: .bold)).monospacedDigit()
            .foregroundStyle(Palette.accentText)
            .textual.frame(minWidth: .fontScaled(1.3), alignment: .center)
    }
}

/// 太长的段落按句子切开（约 90 字一段），代码块、列表、标题、表格保持原样。
func breathableMarkdown(_ text: String) -> String {
    var fenced = false
    return text.components(separatedBy: "\n").map { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); return line }
        guard !fenced, line.count > 140, !line.hasPrefix("    "), !["#", "-", "*", ">", "|", "+"].contains(where: { trimmed.hasPrefix($0) }), trimmed.first?.isNumber != true else { return line }
        var output = "", count = 0
        for character in line {
            output.append(character); count += 1
            if count >= 90 && "。！？；".contains(character) { output += "\n\n"; count = 0 }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }.joined(separator: "\n")
}

// MARK: - r2-chat：纯文本兜底排版

struct ReplyLayout: Equatable {
    var lead: String?
    var body: String
}

/// 把一条回复拆成「结论句 + 正文 Markdown」。
/// 模型已经用了 Markdown 的，只抽结论句、其余原样；整段纯文本的，切短段、并列项转列表、数字金额日期加粗。
enum ReplyFormatter {
    @MainActor private static var cache: [String: ReplyLayout] = [:]

    @MainActor static func layout(_ text: String) -> ReplyLayout {
        #if DEBUG
        // 前后对比截图用：改版前没有结论句、没有纯文本兜底。
        if ProcessInfo.processInfo.arguments.contains("--ui-reply-legacy") { return ReplyLayout(lead: nil, body: breathableMarkdown(text)) }
        #endif
        if let hit = cache[text] { return hit }
        let value = make(text)
        if cache.count > 300 { cache.removeAll(keepingCapacity: true) }
        cache[text] = value
        return value
    }

    nonisolated static func make(_ raw: String) -> ReplyLayout {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ReplyLayout(lead: nil, body: "") }
        let plain = isPlain(text)
        let (lead, rest) = extractLead(text)
        let body = plain ? emphasize(restructure(rest)) : breathableMarkdown(rest)
        return ReplyLayout(lead: lead, body: body)
    }

    nonisolated static func isPlain(_ text: String) -> Bool {
        if text.contains("**") || text.contains("```") || text.contains("__") { return false }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if ["#", "- ", "* ", "+ ", "> ", "|"].contains(where: { t.hasPrefix($0) }) { return false }
            if t.range(of: #"^\d{1,2}[.)]\s"#, options: .regularExpression) != nil { return false }
        }
        return true
    }

    private nonisolated static let terminators: Set<Character> = ["。", "！", "？", "!", "?"]

    /// 第一句当结论：两句以内的短回复不抽（直接说）。
    nonisolated static func extractLead(_ text: String) -> (String?, String) {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first else { return (nil, text) }
        let head = first.trimmingCharacters(in: .whitespaces)
        if head.isEmpty || ["#", "-", "* ", "+ ", ">", "|", "```", "~~~"].contains(where: { head.hasPrefix($0) }) || head.range(of: #"^\d{1,2}[.)、]"#, options: .regularExpression) != nil {
            return (nil, text)
        }
        let flat = text.replacingOccurrences(of: "**", with: "")
        let sentences = flat.filter { terminators.contains($0) }.count + lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count - 1
        guard sentences >= 3 || flat.count >= 80 else { return (nil, text) }
        var cut: String.Index?
        var index = head.startIndex
        while index < head.endIndex {
            let character = head[index]
            if terminators.contains(character) { cut = head.index(after: index); break }
            index = head.index(after: index)
        }
        if cut == nil, head.hasSuffix("：") || head.hasSuffix(":") || (head.count <= 40 && lines.count > 1) { cut = head.endIndex }
        guard let cut else { return (nil, text) }
        // 收尾的引号、括号跟着这句走。
        var end = cut
        while end < head.endIndex, "”」』）)".contains(head[end]) { end = head.index(after: end) }
        let lead = String(head[..<end]).replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        guard (4...64).contains(lead.count) else { return (nil, text) }
        var tail = String(head[end...]).trimmingCharacters(in: .whitespaces)
        // 加粗跨过了句号（「**结论。**」）：把落单的收尾 ** 一起带走，免得正文开头露出 **。
        if head[..<end].components(separatedBy: "**").count % 2 == 0, let close = tail.range(of: "**") {
            tail.removeSubrange(close)
            tail = tail.trimmingCharacters(in: .whitespaces)
        }
        let rest = ([tail] + lines.dropFirst()).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (lead, rest)
    }

    /// 纯文本：每个自然段再按语义拆成短段 / 列表。
    nonisolated static func restructure(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap(blocks(of:))
            .joined(separator: "\n\n")
    }

    private nonisolated static let numbered = try! NSRegularExpression(pattern: #"(?:^|(?<=[\s。；;，,：:]))(?:\d{1,2}[.、)）](?!\d)|[①②③④⑤⑥⑦⑧⑨⑩]|[（(]\d{1,2}[）)])\s*"#)
    private nonisolated static let sequence = try! NSRegularExpression(pattern: #"(?:^|(?<=[。；;，,：:]))(?:首先|第一|其次|第二|再次|第三|然后|此外|另外|最后)[，,、：:]?"#)

    nonisolated static func blocks(of paragraph: String) -> [String] {
        // ① 行内编号「1. … 2. …」「①…②…」
        if let split = splitList(paragraph, by: numbered, requireFirst: nil) { return split }
        // ② 「首先…其次…最后…」
        if let split = splitList(paragraph, by: sequence, requireFirst: ["首先", "第一"]) { return split }
        // ③ 「：」后面三项以上用「；」隔开 → 无序列表
        if let colon = paragraph.firstIndex(where: { $0 == "：" || $0 == ":" }) {
            let after = paragraph[paragraph.index(after: colon)...]
            var parts = after.split(whereSeparator: { $0 == "；" || $0 == ";" }).map(String.init)
            // 最后一项到句号为止，后面的话另起一段。
            var trailing = ""
            if let last = parts.last, let stop = last.firstIndex(where: { terminators.contains($0) }) {
                trailing = String(last[last.index(after: stop)...]).trimmingCharacters(in: .whitespaces)
                parts[parts.count - 1] = String(last[..<stop])
            }
            let items = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " 。")) }.filter { !$0.isEmpty }
            if items.count >= 3 {
                return sentenceGroups(String(paragraph[...colon])) + [items.map { "- " + $0 }.joined(separator: "\n")] + (trailing.isEmpty ? [] : sentenceGroups(trailing))
            }
        }
        return sentenceGroups(paragraph)
    }

    private nonisolated static func splitList(_ paragraph: String, by regex: NSRegularExpression, requireFirst: [String]?) -> [String]? {
        let ns = paragraph as NSString
        let matches = regex.matches(in: paragraph, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return nil }
        if let requireFirst, !requireFirst.contains(where: { ns.substring(with: matches[0].range).hasPrefix($0) }) { return nil }
        let intro = ns.substring(to: matches[0].range.location).trimmingCharacters(in: .whitespaces)
        var items: [String] = []
        var trailing = ""
        for (offset, match) in matches.enumerated() {
            let start = match.range.location + match.range.length
            let end = offset + 1 < matches.count ? matches[offset + 1].range.location : ns.length
            var item = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            if offset == matches.count - 1, let stop = item.firstIndex(where: { terminators.contains($0) }) {
                // 最后一项到句号为止，后面的话另起一段。
                trailing = String(item[item.index(after: stop)...]).trimmingCharacters(in: .whitespaces)
                item = String(item[...stop])
            }
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: " ；;，,。"))
            if !item.isEmpty { items.append(item) }
        }
        guard items.count >= 2 else { return nil }
        var result = intro.isEmpty ? [] : sentenceGroups(intro)
        result.append(items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        if !trailing.isEmpty { result += sentenceGroups(trailing) }
        return result
    }

    /// 按句切，两句或约 56 字成一段。
    nonisolated static func sentenceGroups(_ text: String) -> [String] {
        var sentences: [String] = [], current = ""
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            current.append(character)
            if terminators.contains(character) || character == "；" {
                while let next = characters.first, "”」』）)".contains(next) { current.append(next); characters.removeFirst() }
                sentences.append(current); current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current) }
        var groups: [String] = [], group = "", count = 0
        for sentence in sentences {
            let piece = sentence.trimmingCharacters(in: .whitespaces)
            if !group.isEmpty && (count >= 2 || group.count + piece.count > 64) { groups.append(group); group = ""; count = 0 }
            group += piece; count += 1
        }
        if !group.isEmpty { groups.append(group) }
        return groups
    }

    /// 金额、数字+单位、日期、钟点加粗。用零宽空格护住 `**`，免得 CommonMark 的边界规则在中文和符号旁失效。
    private nonisolated static let figures = try! NSRegularExpression(pattern:
        #"(?:\d{4}\s?年\s?)?\d{1,2}\s?月\s?\d{1,2}\s?[日号]"# + "|" +
        #"(?:上午|下午|晚上|早上|中午|今晚|明早|凌晨)\s?(?:\d{1,2}|[一二三四五六七八九十两]{1,3})\s?点(?:半|\d{1,2}\s?分)?"# + "|" +
        #"\d{1,2}[:：]\d{2}"# + "|" +
        #"(?:周|星期)[一二三四五六日天]"# + "|" +
        #"[¥￥$]\s?\d[\d,]*(?:\.\d+)?\s?[万千]?"# + "|" +
        #"\d[\d,]*(?:\.\d+)?\s?(?:%|％|元|块钱|块|万元|万|亿|次|小时|分钟|秒|天|周|个月|年|笔|项|条|个|人|公里|km|GB|MB)"#)

    nonisolated static func emphasize(_ markdown: String) -> String {
        let ns = markdown as NSString
        var output = "", cursor = 0
        for match in figures.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += "**\u{200B}" + ns.substring(with: match.range) + "\u{200B}**"
            cursor = match.range.location + match.range.length
        }
        return output + ns.substring(from: cursor)
    }
}
