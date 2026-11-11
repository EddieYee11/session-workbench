import SwiftUI

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
