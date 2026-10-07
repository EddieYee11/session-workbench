import SwiftUI
import Textual
import ComCore

// Com! iOS design system · 方向 D「层级」
//
// The single source of truth for colour, type, spacing, radius, elevation and
// every shared component. Screens compose these pieces and never introduce
// their own paddings, font sizes, colours or card shapes.
//
// Layers, back to front:
//   background  →  surface (cards, grouped lists)  →  elevated (composer, dock)
//   Liquid Glass is reserved for floating controls: the dock, the
//   scroll-to-latest pill and system toolbars. Content stays opaque.

// MARK: - Detail transition plumbing (kept)

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
    /// Lime: the one primary-action colour. Fill only — never text on light surfaces.
    static let accent = Color(red: 0.82, green: 0.94, blue: 0.38)
    static let onAccent = Color(red: 0.09, green: 0.10, blue: 0.07)
    /// Lime that stays readable as text / icon tint on surfaces.
    static let accentText = dynamicColor(hex(0x4C6600), hex(0xD2F061))
    /// Coral: the companion crab identity.
    static let coral = Color(red: 0.94, green: 0.43, blue: 0.34)

    // Surfaces, back to front
    static let background = dynamicColor(hex(0xF4F3EF), hex(0x000000))
    static let surface = dynamicColor(.white, hex(0x1C1C1E))
    static let elevated = dynamicColor(.white, hex(0x2C2C2E))
    /// Inset fill inside a surface: inputs, chips, code, quoted text.
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

    // Inverted focus surface: hero card and the user's own chat bubble.
    static let ink = dynamicColor(hex(0x1B1C18), hex(0x2C2C2E))
    static let onInk = Color.white
    static let onInkSecondary = Color.white.opacity(0.68)
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
    case "waiting", "unknown", "approval_required", "paused", "execution_finished", "proposed", "pending": .warning
    case "failed", "rejected": .danger
    case "queued", "dispatching", "running", "sending", "cancel_requested": .info
    case "completed", "accepted": .success
    default: .neutral
    }
}

// MARK: - Typography: semantic text styles only (Dynamic Type safe)
//
// Hierarchy per screen: large title 34 → section 20 → card/row title 16–17 →
// secondary 15 → meta 13. Never set point sizes in screens.

enum TypeScale {
    static let largeTitle = Font.largeTitle.weight(.bold)      // 34 · pairing hero, empty greeting
    static let title = Font.title2.weight(.bold)               // 22 · detail title, focus card
    static let section = Font.title3.weight(.semibold)         // 20 · section header
    static let headline = Font.headline                        // 17 semibold · card heading
    static let body = Font.body                                // 17 · long reading
    static let callout = Font.callout                          // 16 · chat, inputs
    static let rowTitle = Font.callout.weight(.semibold)       // 16 semibold · list row title
    static let subheadline = Font.subheadline                  // 15 · row secondary, buttons in rows
    static let footnote = Font.footnote                        // 13 · meta, timestamps
    static let caption = Font.caption.weight(.medium)          // 12 · pills, eyebrows
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
    static let xs: CGFloat = 8     // tiny chips inside rows
    static let sm: CGFloat = 12    // inputs, code, quotes, icon badges
    static let md: CGFloat = 18    // user bubble, small cards
    static let lg: CGFloat = 22    // cards & grouped lists
    static let xl: CGFloat = 28    // hero card, composer
}
enum Layout {
    static let margin: CGFloat = 20          // screen horizontal margin
    static let sectionSpacing: CGFloat = 28  // between top-level sections
    static let rowInset: CGFloat = 64        // divider inset when rows carry a 36pt badge
}

// MARK: - Elevation

enum Elevation { case flat, raised, floating }
private struct ElevationModifier: ViewModifier {
    let level: Elevation
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder func body(content: Content) -> some View {
        switch level {
        case .flat: content
        case .raised: content.shadow(color: .black.opacity(scheme == .dark ? 0 : 0.045), radius: 10, y: 2)
        case .floating: content.shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.10), radius: 22, y: 8)
        }
    }
}
extension View {
    func elevation(_ level: Elevation) -> some View { modifier(ElevationModifier(level: level)) }
    /// Liquid Glass for floating controls only (dock, floating pills).
    func floatingGlass<S: Shape>(_ shape: S) -> some View { glassEffect(.regular.interactive(), in: shape) }
    /// Standard inner padding for a row living inside a `GroupedCard`.
    func rowPadding() -> some View { padding(.horizontal, Space.lg).padding(.vertical, Space.md) }
    /// Inset text-field look used inside cards.
    func insetField() -> some View {
        font(TypeScale.callout).padding(.horizontal, Space.md).padding(.vertical, Space.md - 1)
            .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
    }
    /// The shared floating input surface (chat composer, work composer).
    func composerSurface() -> some View {
        background(Palette.elevated, in: .rect(cornerRadius: Radius.xl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
            .elevation(.floating)
    }
}

// MARK: - Screen scaffolds

/// Top-level tab screen: native large title (collapses on scroll) + one
/// subtitle/status row + vertically stacked sections with a fixed rhythm.
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
            .padding(.horizontal, Layout.margin).padding(.top, Space.xs).padding(.bottom, Space.xxxl)
        }
        .background(Palette.background)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(compact ? .inline : .large)
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
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

/// Detail header zone: pills row, 22pt title, optional supporting line.
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
    init(_ style: CardStyle = .standard, padding: CGFloat = Space.lg, @ViewBuilder content: () -> Content) {
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
                if case .highlighted(let tone) = style { shape.strokeBorder(tone.color.opacity(0.45), lineWidth: 1) }
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

struct StatusPill: View {
    let text: String
    var tone: Tone = .neutral
    var body: some View {
        Text(text).font(TypeScale.caption).lineLimit(1)
            .padding(.horizontal, Space.sm + 2).padding(.vertical, Space.xs + 1)
            .foregroundStyle(tone == .neutral ? Palette.textPrimary : tone.color)
            .background(tone.soft, in: .capsule)
    }
}

struct StatusDot: View {
    var tone: Tone = .success
    var size: CGFloat = 7
    var body: some View { Circle().fill(tone.color).frame(width: size, height: size) }
}

/// English-only eyebrow (uppercase is meaningless for Chinese).
struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(TypeScale.caption).tracking(1.4).foregroundStyle(Palette.textSecondary) }
}

// MARK: - Buttons

/// Primary decision: lime capsule. At most one per screen region.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? TypeScale.subheadline : TypeScale.callout).weight(.semibold))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, compact ? Space.lg : Space.xl).padding(.vertical, compact ? Space.sm + 1 : Space.md + 2)
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
}

/// Secondary: neutral filled capsule.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.subheadline.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? Palette.danger : Palette.textPrimary)
            .padding(.horizontal, Space.lg).padding(.vertical, Space.sm + 1)
            .background(Palette.fill, in: .capsule)
            .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.45)
    }
}
extension ButtonStyle where Self == SecondaryButtonStyle { static var secondaryAction: SecondaryButtonStyle { SecondaryButtonStyle() } }

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
                            .background(selected ? Palette.accent : Palette.surface, in: .capsule)
                            .overlay(Capsule().strokeBorder(selected ? Color.clear : Palette.separator, lineWidth: 0.5))
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

// MARK: - States

struct EmptyState: View {
    let title: String
    let description: String
    let symbol: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(description))
            .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
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
            .font(.system(configuration.headingLevel <= 2 ? .title3 : .headline, weight: .bold))
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

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

// MARK: - Android-aligned Hermes pixel companion

private enum CrabState: String {
    case idle, listening, thinking, working, speaking, success, error, offline
    init(_ raw: String) {
        switch raw.lowercased() {
        case "倾听", "listening": self = .listening
        case "思考", "thinking": self = .thinking
        case "转写", "发送", "running", "executing", "delivering", "working": self = .working
        case "responding", "speaking": self = .speaking
        case "task_completed", "verified_success", "success": self = .success
        case "failed", "error": self = .error
        case "offline": self = .offline
        default: self = .idle
        }
    }
    var period: Double {
        switch self { case .working: 0.9; case .success: 0.85; case .listening: 1.4; case .offline: 4; default: 2.4 }
    }
    var tilt: Double {
        switch self { case .listening: -4; case .thinking: -8; case .error: 7; case .working: 10; default: 0 }
    }
}

/// Grid, colors, proportions and facial states ported from Android CrabAvatar.kt.
private struct PixelCrab: View {
    let state: CrabState
    let compact: Bool
    let moving: Bool
    let time: Double
    var body: some View {
        Canvas { context, size in
            let phase = moving ? time.truncatingRemainder(dividingBy: state.period) / state.period * .pi * 2 : 0
            let blink = moving && (0.925...0.965).contains(time.truncatingRemainder(dividingBy: 4.2) / 4.2)
            let px = min(size.width, size.height) / (compact ? 24 : 30)
            let ox = (size.width - 22 * px) / 2
            let oy = (size.height - (compact ? 20 : 30) * px) / 2 + (compact ? 0 : 6) * px
            let offline = state == .offline
            let body = offline ? Color(red: 154/255, green: 160/255, blue: 163/255) : Color(red: 221/255, green: 119/255, blue: 87/255)
            let shade = offline ? Color(red: 126/255, green: 132/255, blue: 135/255) : Color(red: 192/255, green: 95/255, blue: 66/255)
            let ink = Color(red: 26/255, green: 26/255, blue: 26/255)
            let wave = Color(red: 232/255, green: 147/255, blue: 107/255)
            let amplitude: Double = state == .success ? (compact ? 1 : 2) : state == .working ? 1.5 : offline ? 0.5 : 1
            let bob = moving ? (sin(phase) * amplitude).rounded() * px : 0
            if !offline {
                context.fill(Path(CGRect(x: ox + 5 * px, y: oy + 19 * px, width: 12 * px, height: px)), with: .color(.black.opacity(0.1)))
            }
            var draw = context
            draw.translateBy(x: ox + 11 * px, y: oy + 10 * px)
            draw.rotate(by: .degrees(state.tilt))
            draw.translateBy(x: -(ox + 11 * px), y: -(oy + 10 * px))
            func rect(_ color: Color, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
                draw.fill(Path(CGRect(x: ox + x * px, y: oy + y * px + bob, width: w * px, height: h * px)), with: .color(color))
            }
            func pixels(_ rows: [String], _ x: Double, _ y: Double, _ scale: Double, _ color: Color) {
                for (row, line) in rows.enumerated() {
                    for (col, character) in line.enumerated() where character == "X" {
                        rect(color, x + Double(col) * scale, y + Double(row) * scale, scale, scale)
                    }
                }
            }
            let armY: Double = state == .success ? 3 : 8
            rect(.white, 0, armY, 3, 5); rect(body, 1, armY + 1, 2, 3)
            rect(.white, 19, armY, 3, 5); rect(body, 19, armY + 1, 2, 3)
            rect(.white, 2, 1, 18, 14)
            for x in [4.0, 10, 16] { rect(.white, x, 13, 4, 6) }
            rect(body, 3, 2, 16, 12)
            rect(shade, 3, 12, 16, 2); rect(shade, 17, 2, 2, 12)
            for x in [4.0, 10, 16] { rect(body, x + 1, 14, 2, 4) }
            let look: Double = state == .listening || state == .thinking ? 1 : 0
            let eyeY: Double = state == .thinking ? 4 : 5
            for x in [6.0, 14] { rect(ink, x + (offline ? 0 : look), eyeY + (offline ? 1 : 0), 2, offline || blink ? 1 : 2) }
            switch state {
            case .offline, .thinking: rect(ink, 10, 11, 4, 1)
            case .speaking: rect(ink, 10, moving && sin(phase * 2) > 0 ? 10 : 11, 4, moving && sin(phase * 2) > 0 ? 3 : 1)
            case .success: rect(ink, 9, 10, 6, 3)
            case .error: rect(ink, 9, 11, 1, 1); rect(ink, 10, 10, 3, 1); rect(ink, 13, 11, 1, 1)
            default: rect(ink, 9, 10, 1, 1); rect(ink, 10, 11, 4, 1); rect(ink, 14, 10, 1, 1)
            }
            if !compact {
                let pulse = moving ? sin(phase) * 0.5 + 0.5 : 0.5
                switch state {
                case .listening:
                    for i in 0..<3 {
                        let h = 2 + Double(i) * 2 + (moving ? sin(phase * 2) * 0.5 + 0.5 : 0.5) * 1.5
                        rect(wave, 19.5 + Double(i) * 1.2, 8 - h / 2, 1, h)
                    }
                case .thinking: rect(wave, 15, -pulse, 3, 2); rect(wave, 13, 2.5 - pulse * 0.5, 1, 1)
                case .working:
                    for i in 0..<3 { rect(wave.opacity(0.7), 0.5, 6 + Double(i) * 3, 3 + (sin(phase * 3 + Double(i) * 2) * 0.5 + 0.5) * 3, 1) }
                case .speaking: pixels(["..XX", "..X.", "..X.", ".XX.", "XXX.", "XX.."], 20, 4 - pulse * 2, 1, wave)
                case .success:
                    for (i, spot) in [(1.0, 2.0), (20, 3), (3, 14), (18, 15)].enumerated() {
                        if !moving || sin(phase * 2 + Double(i)) * 0.5 + 0.5 > 0.35 {
                            pixels(["..X..", "..X..", "XXXXX", "..X..", "..X.."], spot.0, spot.1, 0.8, Color(red: 1, green: 214/255, blue: 107/255))
                        }
                    }
                case .error: pixels([".XXX.", "X...X", "....X", "...X.", "..X..", ".....", "..X.."], 17, -4, 1.2, wave)
                case .offline:
                    let z = moving ? sin(phase * 0.8) * 0.5 + 0.5 : 0
                    pixels(["XXXX", "...X", "..X.", ".X..", "XXXX"], 18, -3 - z * 2, 1, wave.opacity(0.8))
                    pixels(["XXXX", "...X", "..X.", ".X..", "XXXX"], 20, -3.5 - z * 1.5, 0.7, wave.opacity(0.5))
                default: break
                }
            }
        }
    }
}

struct Companion: View {
    var state = "陪伴"
    var compact = false
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var scenePhase
    @State private var drag = CGSize.zero
    @State private var touched = false
    private var moving: Bool { model.active && scenePhase == .active && !reduce }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
            PixelCrab(state: CrabState(state), compact: compact, moving: moving, time: moving ? timeline.date.timeIntervalSinceReferenceDate : 0)
        }
        .scaleEffect(x: touched ? 1.06 : 1, y: touched ? 0.95 : 1)
        .offset(x: drag.width * 0.15, y: drag.height * 0.12)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in drag = value.translation; touched = true }.onEnded { _ in
            withAnimation(reduce ? .linear(duration: 0.12) : .spring(response: 0.45, dampingFraction: 0.63)) { drag = .zero; touched = false }
            Haptics.selection()
        })
        .accessibilityElement(children: .ignore).accessibilityLabel("Hermes 像素螃蟹，\(state)")
        .accessibilityAddTraits(.isButton).accessibilityAction { Haptics.selection() }
    }
}

struct CompanionPortrait: View {
    var size: CGFloat = 76
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var scenePhase
    private var moving: Bool { model.active && scenePhase == .active && !reduce }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !moving)) { timeline in
            PixelCrab(state: CrabState(model.roleState == "陪伴" && !model.streaming ? "offline" : model.roleState), compact: true, moving: moving, time: moving ? timeline.date.timeIntervalSinceReferenceDate : 0)
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}

// MARK: - App chrome: toolbar pieces shared by every tab

/// Leading avatar menu, identical on every tab.
struct MainMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Menu {
            Button("搜索聊天与成果", systemImage: "magnifyingglass") { model.showSearch = true }
            Button("工作记录", systemImage: "clock.arrow.circlepath") { model.tab = .work }
            Button("分享收件箱", systemImage: "tray") { model.showShareInbox = true }
            Button("设置与连接", systemImage: "slider.horizontal.3") { model.showSettings = true }
        } label: { CompanionPortrait(size: 30) }
        .accessibilityLabel("主菜单")
    }
}

/// Chat tab principal: companion name + live status.
struct CompanionTitle: View {
    @Environment(AppModel.self) private var model
    private var status: String {
        if model.roleState != "陪伴" { return model.activeRuns.first?["phase"].string.nonEmpty ?? model.roleState }
        return model.streaming ? "随时在这里" : "离线 · 已保存的内容"
    }
    private var tone: Tone { model.roleState != "陪伴" ? .info : model.streaming ? .success : .neutral }
    var body: some View {
        VStack(spacing: 1) {
            Text("Com").font(TypeScale.headline)
            HStack(spacing: Space.xs) {
                StatusDot(tone: tone, size: 6)
                Text(status).font(.caption2).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Dock: floating Liquid Glass capsule

struct ComDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var selection
    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(SectionTab.allCases) { tab in
                let selected = model.tab == tab
                Button {
                    withAnimation(reduce ? nil : .spring(response: 0.32, dampingFraction: 0.86)) { model.tab = tab }
                } label: {
                    HStack(spacing: Space.xs + 2) {
                        Image(systemName: tab.symbol).symbolVariant(selected ? .fill : .none)
                            .font(.system(size: 18, weight: selected ? .semibold : .regular))
                        if selected {
                            Text(tab.rawValue).font(TypeScale.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                        }
                    }
                    .padding(.horizontal, selected ? Space.lg : 0)
                    .frame(height: 46)
                    .frame(maxWidth: selected ? nil : CGFloat.infinity)
                    .background {
                        if selected { Capsule().fill(Palette.accent).matchedGeometryEffect(id: "selected-tab", in: selection) }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Palette.onAccent : Palette.textSecondary)
                .accessibilityLabel(tab.rawValue)
                .accessibilityIdentifier("tab-" + tab.id)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(tab == .work ? "Com · 工作记录" : tab.rawValue)
            }
        }
        .padding(Space.xs + 2)
        .floatingGlass(.capsule)
        .elevation(.floating)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, Space.xl).padding(.top, Space.sm).padding(.bottom, Space.xs)
    }
}
