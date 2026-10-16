import SwiftUI
import Textual
import ComCore

// Com! iOS design system · 「层级」版（青柠 accent）+ iOS 26 Liquid Glass
//
// 颜色、字阶、间距、圆角、投影和所有共享组件的唯一真源。页面只组合这里的零件，
// 不自己定 padding、字号、颜色或卡片形状。
//
// 分层（由后到前）：background → surface（卡片、分组列表）→ elevated（输入区）→ glass（浮动控件）。
// Liquid Glass 只给会浮在内容上面的东西：Dock、顶栏右侧按钮、回到最新、下拉舞台。内容本身保持不透明。

// MARK: - Detail transition plumbing

private struct DetailSpaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues { var detailSpace: Namespace.ID? { get { self[DetailSpaceKey.self] } set { self[DetailSpaceKey.self] = newValue } } }
struct DetailSource: ViewModifier {
    @Environment(\.detailSpace) private var space
    let id: String
    @ViewBuilder func body(content: Content) -> some View { if let space { content.matchedTransitionSource(id: id, in: space) } else { content } }
}
extension View { func detailSource(_ id: String) -> some View { modifier(DetailSource(id: id)) } }

// MARK: - Colour tokens (light + dark)

private func dynamicColor(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
}
private func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> UIColor {
    UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

enum Palette {
    // Brand
    /// 青柠：唯一的主操作色。只做填充，不在浅色面上当文字。
    static let accent = Color(red: 0.82, green: 0.94, blue: 0.38)
    static let onAccent = Color(red: 0.09, green: 0.10, blue: 0.07)
    /// 能在面上当文字 / 图标用的青柠。
    static let accentText = dynamicColor(hex(0x4C6600), hex(0xD2F061))
    static let coral = Color(red: 0.94, green: 0.43, blue: 0.34)

    // Surfaces, back to front
    static let background = dynamicColor(hex(0xF4F3EF), hex(0x000000))
    static let surface = dynamicColor(.white, hex(0x1C1C1E))
    static let elevated = dynamicColor(.white, hex(0x2C2C2E))
    /// 面里的内嵌块：输入框、chip、代码、引用。
    static let fill = dynamicColor(hex(0xF0EEE9), hex(0x2C2C2E))
    static let separator = dynamicColor(hex(0x000000, 0.08), hex(0xFFFFFF, 0.12))

    // Text
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(uiColor: .tertiaryLabel)

    // Status
    static let success = dynamicColor(hex(0x2E9A58), hex(0x4CD580))
    static let warning = dynamicColor(hex(0xB86E00), hex(0xFFB340))
    static let danger = dynamicColor(hex(0xD5452F), hex(0xFF6B5A))
    static let info = dynamicColor(hex(0x2F6BD8), hex(0x6AA6FF))

    // 反色焦点面：我的气泡、选中的 tab。
    static let ink = dynamicColor(hex(0x1B1C18), hex(0x2C2C2E))
    static let onInk = Color.white
    static let onInkSecondary = Color.white.opacity(0.68)
    static let inkShadow = Color.black
}

/// Semantic tone for pills, icon badges, dots and highlighted cards.
enum Tone: Equatable {
    case neutral, accent, success, warning, danger, info
    var color: Color {
        switch self {
        case .neutral: Palette.textSecondary
        case .accent: Palette.accentText
        case .success: Palette.success
        case .warning: Palette.warning
        case .danger: Palette.danger
        case .info: Palette.info
        }
    }
    var soft: Color {
        switch self {
        case .neutral: Palette.fill
        case .accent: Palette.accent.opacity(0.32)
        default: color.opacity(0.14)
        }
    }
    /// Icon colour on a `soft` background.
    var symbol: Color { self == .neutral ? Palette.textPrimary : color }
}

/// One mapping from backend status to tone, used by every pill and row.
func statusTone(_ status: String) -> Tone {
    switch status {
    case "waiting", "unknown", "uncertain", "approval_required", "awaiting_review", "paused", "execution_finished", "proposed", "pending": .warning
    case "failed", "rejected": .danger
    case "queued", "dispatching", "running", "sending", "cancel_requested", "executing": .info
    case "completed", "accepted", "succeeded", "delivered": .success
    default: .neutral
    }
}

// MARK: - Typography (Dynamic Type safe; 标题用圆体，正文系统字)

/// 旧宋体入口保留名字，现在都是系统圆体。
enum Serif {
    static func bold(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func semibold(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

enum TypeScale {
    static let largeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)   // 34 · 配对页问候
    static let title = Font.system(.title2, design: .rounded, weight: .bold)            // 22 · 详情标题、页面焦点
    static let section = Font.system(.title3, design: .rounded, weight: .semibold)      // 20 · 区块标题
    static let headline = Font.headline                                                  // 17 semibold · 卡片标题
    static let judgement = Font.headline
    static let stamp = Font.caption.weight(.semibold)                                    // 12 · 状态
    static let link = Font.subheadline.weight(.semibold)                                 // 15 · 看明细 / 去聊
    static let draft = Font.callout                                                      // 16 · 草稿引用
    static let body = Font.body                                                          // 17 · 长阅读
    static let callout = Font.callout                                                    // 16 · 聊天、输入框
    static let rowTitle = Font.callout.weight(.semibold)                                 // 16 semibold · 列表行标题
    static let subheadline = Font.subheadline                                            // 15 · 行副标题、按钮
    static let footnote = Font.footnote                                                  // 13 · 元信息
    static let caption = Font.caption.weight(.medium)                                    // 12 · 徽标
    static let metric = Font.title3.weight(.semibold).monospacedDigit()
    static let code = Font.footnote.monospaced()
}

// MARK: - Spacing, radius, layout

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
    static let xxxl: CGFloat = 40
}
enum Radius {
    static let xs: CGFloat = 8     // 行内小 chip
    static let sm: CGFloat = 12    // 输入框、代码、引用、图标徽标
    static let md: CGFloat = 18    // 我的气泡、小卡
    static let note: CGFloat = 18  // 旧便签圆角，现在等于 md
    static let lg: CGFloat = 22    // 卡片、分组列表
    static let xl: CGFloat = 28    // 焦点卡、输入区
}
enum Layout {
    static let margin: CGFloat = 20          // 页面左右边距
    static let sectionSpacing: CGFloat = 28  // 顶级区块间距
    static let rowInset: CGFloat = 64        // 行带 36pt 徽标时分割线的缩进
    static let topBar: CGFloat = 60          // 顶栏在安全区以下的高度
    static let dock: CGFloat = 72            // 浮动 Dock 占的底部空间
}

// MARK: - Elevation & glass

enum Elevation { case flat, raised, floating }
private struct ElevationModifier: ViewModifier {
    let level: Elevation
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder func body(content: Content) -> some View {
        switch level {
        case .flat: content
        case .raised: content.shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 12, y: 3)
        case .floating: content.shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.10), radius: 22, y: 8)
        }
    }
}
extension View {
    func elevation(_ level: Elevation) -> some View { modifier(ElevationModifier(level: level)) }
    /// Liquid Glass：只给浮在内容上的控件（Dock、顶栏按钮、回到最新）。
    func floatingGlass<S: Shape>(_ shape: S) -> some View { glassEffect(.regular.interactive(), in: shape) }
    /// 顶栏那种半透明条：内容从下面滑过。
    func paperGlass() -> some View { background(Palette.background.opacity(0.72)).background(.ultraThinMaterial) }
    func paperBackground() -> some View { background(Palette.background) }
    /// Standard inner padding for a row living inside a `GroupedCard`.
    func rowPadding() -> some View { padding(.horizontal, Space.lg).padding(.vertical, Space.md) }
    /// Inset text-field look used inside cards.
    func insetField() -> some View {
        font(TypeScale.callout).padding(.horizontal, Space.md).padding(.vertical, Space.md - 1)
            .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
    }
    /// 输入区：玻璃胶囊，浮在时间线上。
    func composerSurface() -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: Radius.xl, style: .continuous))
    }
    /// 普通卡面（旧便签入口保留名字；倾斜参数忽略）。
    func noteSurface(tilt: Double = 0, fill: Color = Palette.surface) -> some View {
        background(fill, in: .rect(cornerRadius: Radius.lg, style: .continuous)).elevation(.raised)
    }
}

/// 细分割线（旧虚线入口保留名字）。
struct DashedRule: View {
    var color: Color = Palette.separator
    var body: some View { Rectangle().fill(color).frame(height: 0.5).accessibilityHidden(true) }
}

// MARK: - Screen scaffolds

/// 顶级 tab 页：内容从共享顶栏下面滑过；区块间距固定。
struct ScreenScaffold<Content: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    let freshness: String?
    let compact: Bool
    let content: Content
    let accessory: Accessory
    init(title: String, subtitle: String = "", freshness: String? = nil, compact: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.subtitle = subtitle; self.freshness = freshness; self.compact = compact
        self.content = content(); self.accessory = accessory()
    }
    private var hasHeader: Bool { !subtitle.isEmpty || freshness != nil || Accessory.self != EmptyView.self }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                if hasHeader {
                    HStack(alignment: .center, spacing: Space.md) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            if !subtitle.isEmpty { Text(subtitle).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary) }
                            if let freshness { Freshness(path: freshness) }
                        }
                        Spacer(minLength: 0)
                        accessory
                    }
                    .padding(.bottom, -Space.sm)
                }
                content
            }
            .padding(.horizontal, Layout.margin).padding(.top, Space.md).padding(.bottom, Space.xxl)
        }
        .background(Palette.background)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .toolbar(.hidden, for: .navigationBar)
    }
}
extension ScreenScaffold where Accessory == EmptyView {
    init(title: String, subtitle: String = "", freshness: String? = nil, compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, freshness: freshness, compact: compact, content: content, accessory: { EmptyView() })
    }
}

/// Scroll container for sheets and pushed screens (title comes from the nav bar).
struct ScrollPage<Content: View>: View {
    let spacing: CGFloat
    let content: Content
    init(spacing: CGFloat = Space.xl, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, Layout.margin).padding(.top, Space.sm).padding(.bottom, Space.xxxl)
        }
        .background(Palette.background)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Every detail sheet: inline title, one "完成", then header → decision → disclosure.
struct DetailPage<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.dismiss) private var dismiss
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        NavigationStack {
            ScrollPage { content }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Palette.background, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

/// Detail header zone: pills row, title, optional supporting line.
struct DetailHeader<Badges: View>: View {
    let title: String
    let subtitle: String
    let badges: Badges
    init(title: String, subtitle: String = "", @ViewBuilder badges: () -> Badges) { self.title = title; self.subtitle = subtitle; self.badges = badges() }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) { badges }
            if !title.isEmpty { Text(title).font(TypeScale.title).fixedSize(horizontal: false, vertical: true) }
            if !subtitle.isEmpty { Text(subtitle).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sections & cards

/// Titled group: section header (+ optional trailing action) → content → footer.
struct GroupSection<Content: View, Trailing: View>: View {
    let title: String
    let footer: String
    let content: Content
    let trailing: Trailing
    init(_ title: String, footer: String = "", @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.footer = footer; self.content = content(); self.trailing = trailing()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !title.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(title).font(TypeScale.section).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Space.sm)
                    trailing
                }
            }
            content
            if !footer.isEmpty {
                Text(footer).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.xs)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
extension GroupSection where Trailing == EmptyView {
    init(_ title: String, footer: String = "", @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, content: content, trailing: { EmptyView() })
    }
}

enum CardStyle: Equatable {
    /// White surface card with a soft lift.
    case standard
    /// Flat inset block (inside other cards or for quiet info).
    case inset
    /// Surface card with a tone outline: needs a decision.
    case highlighted(Tone)
    /// Inverted ink card: the screen's one focal element.
    case ink
}

struct Card<Content: View>: View {
    let style: CardStyle
    let padding: CGFloat
    let content: Content
    init(_ style: CardStyle = .standard, padding: CGFloat = Space.lg, tilt: Double = 0, @ViewBuilder content: () -> Content) {
        self.style = style; self.padding = padding; self.content = content()
    }
    private var fill: Color {
        switch style {
        case .standard, .highlighted: Palette.surface
        case .inset: Palette.fill
        case .ink: Palette.ink
        }
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style == .ink ? Radius.xl : Radius.lg, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: shape)
            .overlay {
                if case .highlighted(let tone) = style { shape.strokeBorder(tone == .accent ? Palette.accent : tone.color.opacity(0.45), lineWidth: tone == .accent ? 2 : 1) }
            }
            .elevation(style == .inset ? .flat : style == .ink ? .floating : .raised)
    }
}

/// An inset-grouped list: one surface, rows separated by hairlines.
/// Rows provide their own padding (`ListRow` or `.rowPadding()`).
struct GroupedCard<Content: View>: View {
    let dividerInset: CGFloat
    let content: Content
    init(dividerInset: CGFloat = Space.lg, @ViewBuilder content: () -> Content) { self.dividerInset = dividerInset; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews) { subview in
                    subview
                    if subview.id != subviews.last?.id {
                        Rectangle().fill(Palette.separator).frame(height: 0.5).padding(.leading, dividerInset)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: Radius.lg, style: .continuous))
        .elevation(.raised)
    }
}

/// Press feedback for tappable rows inside grouped cards.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.fill : Color.clear)
            .contentShape(.rect)
    }
}
extension ButtonStyle where Self == RowButtonStyle { static var row: RowButtonStyle { RowButtonStyle() } }

// MARK: - Rows

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
    }
}

/// The one list row: badge · title · status · subtitle · meta · trailing.
struct ListRow<Trailing: View>: View {
    let symbol: String?
    let tone: Tone
    let title: String
    let titleLines: Int
    let status: String
    let statusTone: Tone
    let subtitle: String
    let subtitleLines: Int
    let meta: String
    let trailing: Trailing
    init(symbol: String? = nil, tone: Tone = .neutral, title: String, titleLines: Int = 2, status: String = "", statusTone: Tone = .neutral,
         subtitle: String = "", subtitleLines: Int = 2, meta: String = "", @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol; self.tone = tone; self.title = title; self.titleLines = titleLines
        self.status = status; self.statusTone = statusTone; self.subtitle = subtitle; self.subtitleLines = subtitleLines
        self.meta = meta; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            if let symbol { IconBadge(symbol: symbol, tone: tone) }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary).lineLimit(titleLines)
                if !status.isEmpty {
                    Text(status).font(TypeScale.footnote.weight(statusTone == .neutral ? .regular : .semibold))
                        .foregroundStyle(statusTone == .neutral ? Palette.textSecondary : statusTone.color)
                }
                if !subtitle.isEmpty { Text(subtitle).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(subtitleLines) }
                if !meta.isEmpty { Text(meta).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md + 2)
        .contentShape(.rect)
    }
}
extension ListRow where Trailing == Chevron {
    init(symbol: String? = nil, tone: Tone = .neutral, title: String, titleLines: Int = 2, status: String = "", statusTone: Tone = .neutral,
         subtitle: String = "", subtitleLines: Int = 2, meta: String = "") {
        self.init(symbol: symbol, tone: tone, title: title, titleLines: titleLines, status: status, statusTone: statusTone,
                  subtitle: subtitle, subtitleLines: subtitleLines, meta: meta, trailing: { Chevron() })
    }
}

/// Label + value, value trailing and secondary. For settings and facts.
struct KeyValueRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(label).font(TypeScale.callout)
            Spacer(minLength: Space.sm)
            Text(value).font(TypeScale.callout).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.trailing)
        }.rowPadding()
    }
}

/// Leading label with icon + chevron, for navigation / action rows.
struct NavigationRowLabel: View {
    let title: String
    var symbol: String?
    var body: some View {
        HStack(spacing: Space.md) {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            Spacer(minLength: Space.sm)
            Chevron()
        }
        .font(TypeScale.callout).foregroundStyle(Palette.textPrimary)
        .rowPadding().contentShape(.rect)
    }
}

// MARK: - Badges, pills, dots

/// 36pt rounded-square leading badge. The only spec.
struct IconBadge: View {
    let symbol: String
    var tone: Tone = .neutral
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium)).foregroundStyle(tone.symbol)
            .frame(width: size, height: size)
            .background(tone.soft, in: .rect(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 状态胶囊。文字与后端状态一一对应，没有图标猜测。（旧印章入口保留参数名。）
struct Stamp: View {
    let text: String
    var tone: Tone = .neutral
    var dashed = false
    var angle: Double = 0
    var body: some View {
        Text(text).font(TypeScale.caption).lineLimit(1)
            .padding(.horizontal, Space.sm + 2).padding(.vertical, Space.xs + 1)
            .foregroundStyle(tone == .neutral ? Palette.textPrimary : tone.color)
            .background(tone.soft, in: .capsule)
            .overlay { if dashed { Capsule().strokeBorder(tone.color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) } }
            .fixedSize()
    }
}

struct StatusPill: View {
    let text: String
    var tone: Tone = .neutral
    var body: some View { Stamp(text: text, tone: tone, dashed: text == "结果未知" || text == "待核实") }
}

/// 状态词表：等待批准 / 执行中 / 已送达 / 结果未知 / 已完成（外加待验收、失败、已取消这些真实状态）。
func stampLabel(_ status: String, accepted: Bool = false) -> String {
    if accepted { return "已完成" }
    return ["queued": "执行中", "dispatching": "执行中", "running": "执行中", "sending": "执行中", "cancel_requested": "执行中", "executing": "执行中",
            "waiting": "等你回应", "approval_required": "等待批准", "awaiting_review": "等待批准", "proposed": "等待批准", "pending": "等待批准", "paused": "已暂停",
            "unknown": "结果未知", "uncertain": "结果未知", "execution_finished": "待验收", "accepted": "已送达", "delivered": "已送达",
            "completed": "已完成", "succeeded": "已完成", "failed": "失败", "rejected": "已拒绝", "expired": "已过期", "cancelled": "已取消", "stopped": "已停止", "idle": "空闲", "ended": "已结束"][status] ?? status
}
func stampTone(_ status: String, accepted: Bool = false) -> Tone { accepted ? .success : statusTone(status) }

struct StatusDot: View {
    var tone: Tone = .success
    var size: CGFloat = 7
    var body: some View { Circle().fill(tone.color).frame(width: size, height: size) }
}

/// Count badge on a control (在办 3).
struct CountBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text("\(min(count, 99))").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.onAccent)
                .frame(minWidth: 18, minHeight: 18).padding(.horizontal, 3)
                .background(Palette.accent, in: .capsule).overlay(Capsule().strokeBorder(Palette.surface, lineWidth: 2))
        }
    }
}

/// English-only eyebrow (uppercase is meaningless for Chinese).
struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(TypeScale.caption).tracking(1.4).foregroundStyle(Palette.textSecondary) }
}

// MARK: - Buttons

/// Primary decision: 青柠胶囊。每个区域最多一个。
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var compact = false
    var accent = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? TypeScale.subheadline : TypeScale.callout).weight(.semibold))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, compact ? Space.lg : Space.xl)
            .frame(height: compact ? 36 : 46)
            .frame(maxWidth: fullWidth ? CGFloat.infinity : nil)
            .background(Palette.accent.opacity(enabled ? 1 : 0.45), in: .capsule)
            .opacity(enabled ? 1 : 0.6)
            .scaleEffect(reduce ? 1 : configuration.isPressed ? 0.97 : 1)
            .animation(reduce ? nil : .spring(duration: 0.2, bounce: 0.15), value: configuration.isPressed)
    }
}
extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryAction: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryFull: PrimaryButtonStyle { PrimaryButtonStyle(fullWidth: true) }
    static var primaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
    static var primaryAccent: PrimaryButtonStyle { PrimaryButtonStyle(fullWidth: true) }
}

/// Secondary: neutral filled capsule.
struct SecondaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.subheadline.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? Palette.danger : Palette.textPrimary)
            .padding(.horizontal, compact ? Space.md + 2 : Space.lg)
            .frame(height: compact ? 36 : 46)
            .background(Palette.fill, in: .capsule)
            .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.45)
    }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryAction: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryCompact: SecondaryButtonStyle { SecondaryButtonStyle(compact: true) }
}

/// Quiet tertiary: tinted text only. Destructive role turns it red.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.subheadline.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? Palette.danger : Palette.accentText)
            .opacity(configuration.isPressed ? 0.55 : enabled ? 1 : 0.4)
            .contentShape(.rect)
    }
}
extension ButtonStyle where Self == QuietButtonStyle { static var quiet: QuietButtonStyle { QuietButtonStyle() } }

/// Circular icon action. `filled` = primary (lime), otherwise neutral fill.
struct CircleActionButton: View {
    let symbol: String
    let label: String
    var filled = false
    var size: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(filled ? Palette.onAccent : Palette.textPrimary)
                .frame(width: size, height: size)
                .background(filled ? Palette.accent : Palette.fill, in: .circle)
        }.buttonStyle(MessagePressStyle()).accessibilityLabel(label)
    }
}

// MARK: - Controls

/// Horizontal single-select chips that bleed to the screen edge.
struct FilterChips: View {
    let options: [String]
    @Binding var selection: String
    var animation: Animation?
    var haptic = false
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.sm) {
                ForEach(options, id: \.self) { item in
                    let selected = selection == item
                    Button {
                        if let animation { withAnimation(animation) { selection = item } } else { selection = item }
                        if haptic { Haptics.selection() }
                    } label: {
                        Text(item).font(TypeScale.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, Space.md + 2).padding(.vertical, Space.sm)
                            .foregroundStyle(selected ? Palette.onAccent : Palette.textPrimary)
                            // 和 Dock、顶栏按钮同一种玻璃；选中项染青柠。
                            .glassEffect(selected ? .regular.tint(Palette.accent).interactive() : .regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(.horizontal, Layout.margin)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Layout.margin)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textTertiary)
            TextField(prompt, text: $text).font(TypeScale.callout).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, Space.md + 2).padding(.vertical, Space.md - 1)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
    }
}

/// A small metric: label over a large monospaced value.
struct MetricTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            Text(value).font(TypeScale.metric).contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
    }
}

/// Selectable monospaced block (commands, raw paths).
struct CodeBlock: View {
    let text: String
    var body: some View {
        Text(text).font(TypeScale.code).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.md)
            .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
    }
}

/// 它写好的草稿 / 引用：左侧一道青柠线的内嵌块。
struct LinedText: View {
    let text: String
    var body: some View {
        Text(text).font(TypeScale.draft).lineSpacing(4).foregroundStyle(Palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.md).padding(.vertical, Space.md - 2)
            .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3).padding(.vertical, Space.sm).padding(.leading, 6) }
    }
}

/// 进度条（只在有真实分母时使用）。
struct DashedBar: View {
    let fraction: Double
    var tone: Tone = .neutral
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.fill)
                Capsule().fill(tone == .neutral ? Palette.accent : tone.color).frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }.frame(height: 6).accessibilityHidden(true)
    }
}

// MARK: - States

struct EmptyState: View {
    let title: String
    let description: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            IconBadge(symbol: symbol, tone: .neutral, size: 40)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(TypeScale.headline)
                if !description.isEmpty { Text(description).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).lineSpacing(3) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.lg)
        .background(Palette.fill.opacity(0.6), in: .rect(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct LoadingState: View {
    let text: String
    var body: some View {
        HStack(spacing: Space.sm) {
            ProgressView().controlSize(.small)
            Text(text).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline status/error line. Error copy is shown verbatim.
struct InlineNotice: View {
    let text: String
    var tone: Tone = .danger
    var body: some View {
        Label {
            Text(text).font(TypeScale.footnote).foregroundStyle(tone == .neutral ? Palette.textSecondary : tone.color)
        } icon: {
            Image(systemName: tone == .danger ? "exclamationmark.circle.fill" : "info.circle").font(TypeScale.footnote).foregroundStyle(tone.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Freshness: View {
    @Environment(AppModel.self) private var model
    let path: String
    var body: some View {
        HStack(spacing: Space.xs + 2) {
            StatusDot(tone: model.errors[path] == nil ? .success : .danger, size: 6)
            if let error = model.errors[path] { Text(error).foregroundStyle(Palette.textSecondary).lineLimit(2) }
            else if let date = model.fetchedAt[path] { Text("更新于 \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(Palette.textSecondary) }
            else { Text("尚未读取").foregroundStyle(Palette.textSecondary) }
        }.font(TypeScale.footnote).accessibilityElement(children: .combine)
    }
}

// MARK: - Content renderers

struct RichText: View {
    let text: String
    var font: Font = TypeScale.body
    var body: some View {
        StructuredText(markdown: readableMarkdown(text))
            .textual.structuredTextStyle(.gitHub)
            .textual.headingStyle(ReplyHeadingStyle())
            .textual.inlineStyle(InlineStyle().strong(.fontWeight(.bold), .fontScale(1.06)).link(.foregroundColor(Palette.info)))
            .textual.textSelection(.enabled)
            .font(font).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Split only oversized prose at sentence boundaries; code, lists and Markdown headings keep their structure.
private func readableMarkdown(_ text: String) -> String {
    var fenced = false
    return text.components(separatedBy: "\n").map { line in
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") { fenced.toggle(); return line }
        guard !fenced, line.count > 240, !line.hasPrefix("    "), !["#", "-", "*", ">", "|"].contains(where: { line.hasPrefix($0) }), line.first?.isNumber != true else { return line }
        var output = "", count = 0
        for character in line {
            output.append(character); count += 1
            if count >= 120 && "。！？；".contains(character) { output += "\n\n"; count = 0 }
        }
        return output
    }.joined(separator: "\n")
}

private struct ReplyHeadingStyle: StructuredText.HeadingStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(configuration.headingLevel <= 2 ? .title3 : .headline, design: .rounded, weight: .bold))
            .textual.blockSpacing(.init(top: 16, bottom: 8))
    }
}

/// Collapsed raw JSON. Plain disclosure; containers decide padding.
struct RawDetails: View {
    let title: String
    let value: JSON
    var body: some View {
        DisclosureGroup(title) { CodeBlock(text: value.pretty).padding(.top, Space.sm) }
            .font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary)
    }
}

func displayStatus(_ value: String) -> String { stampLabel(value) }
func eventLabel(_ event: JSON) -> String { AgentCopy.event(event) }

func agentName(_ value: String) -> String { ["hermes": "Hermes", "pi": "Pi", "claude": "Claude Code", "codex": "Codex"][value] ?? value }
func hostName(_ value: String) -> String { ["mini": "Mac mini", "macbook": "MacBook", "mbp": "MacBook"][value.lowercased()] ?? (value.isEmpty ? "" : value) }
func textContent(_ value: JSON) -> String {
    if case .string = value { return value.string }
    if case .array(let parts) = value { return parts.map { $0["text"].string }.joined(separator: "\n") }
    return value["text"].string
}
/// 「10月9日」「刚刚」「18 分钟前」这类口径。
func relativeTime(_ seconds: Double) -> String {
    guard seconds > 0 else { return "" }
    let delta = Date().timeIntervalSince1970 - seconds
    if delta < 60 { return "刚刚" }
    if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
    if delta < 86400 { return "\(Int(delta / 3600)) 小时前" }
    if delta < 86400 * 2 { return "昨天" }
    return Date(timeIntervalSince1970: seconds).formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
}
func clockTime(_ seconds: Double) -> String {
    guard seconds > 0 else { return "" }
    return Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
}
func dayLabel(_ date: Date = Date()) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE"; return f.string(from: date)
}
