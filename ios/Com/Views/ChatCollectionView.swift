import SwiftUI
import UIKit
import ComCore

/// 聊天列表里的一项。Equatable 决定这一格要不要重画。
enum ChatListEntry: Equatable, Identifiable {
    case history(loading: Bool, note: String)
    case empty
    case row(ChatDisplayRow, flying: Bool)
    case suggestions(messageID: String, options: [String])

    var id: String {
        switch self {
        case .history: return "list:history"
        case .empty: return "list:empty"
        case .row(let row, _): return row.id
        case .suggestions: return "list:suggestions"
        }
    }

    /// 还没量过的格子先按字数估高。估得越准，第一次滑到时补偿越小。
    func estimatedHeight(width: CGFloat) -> CGFloat {
        switch self {
        case .history: return 60
        case .empty: return 320
        case .suggestions: return 56
        case .row(let row, _):
            switch row.kind {
            case .day: return 24
            case .proactiveStack: return 56
            case .message(let item, _):
                let perLine = max(10, (width - 60) / 16)
                let count = Double(item.message["text"].string.count)
                return CGFloat((count / Double(perLine)).rounded(.up)) * 24 + 44
            }
        }
    }
}

/// 自己算位置的时间线布局：高度量一次记一次；锚点上方的格子高度变了，就把差值补进 contentOffset，
/// 所以往上滑时正在读的内容不会跳。这是 10-07「手动滑动位置乱跳」的根治点，别换回 Lazy 容器。
final class ChatTimelineLayout: UICollectionViewLayout {
    var spacing: CGFloat = Space.xl
    var verticalPadding: CGFloat = Space.md
    var estimate: (String, CGFloat) -> CGFloat = { _, _ in 80 }

    private(set) var ids: [String] = []
    private var heights: [String: CGFloat] = [:]
    private var frames: [CGRect] = []
    private var indexByID: [String: Int] = [:]
    private var contentHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0

    func setIDs(_ new: [String]) {
        ids = new
        indexByID = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($1, $0) })
        let live = Set(new)
        heights = heights.filter { live.contains($0.key) }
        invalidateLayout()
    }

    func frame(for id: String) -> CGRect? {
        guard let index = indexByID[id], index < frames.count else { return nil }
        return frames[index]
    }

    override func prepare() {
        super.prepare()
        guard let view = collectionView else { return }
        let width = view.bounds.width
        if width != measuredWidth {
            // 折叠屏展开、转屏：换行全变，旧高度作废，重新量。
            heights = [:]
            measuredWidth = width
        }
        var resolved = [CGFloat](repeating: 0, count: ids.count)
        var total = verticalPadding * 2
        for (index, id) in ids.enumerated() {
            let height = heights[id] ?? estimate(id, width)
            resolved[index] = height
            total += height + (index > 0 ? spacing : 0)
        }
        let visible = view.bounds.height - view.adjustedContentInset.top - view.adjustedContentInset.bottom
        // 内容不满一屏时贴底，和聊天的阅读习惯一致。
        var y = verticalPadding + max(0, visible - total)
        var next: [CGRect] = []
        next.reserveCapacity(ids.count)
        for height in resolved {
            next.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height + spacing
        }
        frames = next
        contentHeight = max(total, visible)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let item = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        item.frame = frames[index]
        return item
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !frames.isEmpty else { return [] }
        var low = 0, high = frames.count - 1, first = frames.count
        while low <= high {
            let middle = (low + high) / 2
            if frames[middle].maxY >= rect.minY { first = middle; high = middle - 1 } else { low = middle + 1 }
        }
        var out: [UICollectionViewLayoutAttributes] = []
        var index = first
        while index < frames.count, frames[index].minY <= rect.maxY {
            out.append(attributes(at: index))
            index += 1
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < frames.count ? attributes(at: indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        abs(preferred.size.height - original.size.height) > 0.5
    }

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        guard original.indexPath.item < ids.count else { return context }
        let delta = preferred.size.height - original.size.height
        heights[ids[original.indexPath.item]] = preferred.size.height
        context.contentSizeAdjustment.height = delta
        if let view = collectionView, original.frame.minY < view.contentOffset.y + view.adjustedContentInset.top {
            // 这一格的上沿已在视口之上：把差值补给 offset，正在读的内容原地不动。
            context.contentOffsetAdjustment.y = delta
        }
        return context
    }
}

final class ChatTimelineCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let fitted = attributes.copy() as! UICollectionViewLayoutAttributes
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        fitted.size = CGSize(width: attributes.size.width, height: size.height.rounded(.up))
        return fitted
    }
}

/// layoutSubviews 是唯一的贴底入口：流式长高、键盘升降、折叠屏变宽都走到这里。
final class ChatTimelineCollection: UICollectionView {
    var afterLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        afterLayout?()
    }
}

/// 列表的全部滚动状态都在这里，SwiftUI 只收「是否在底部 / 快到顶了」两个信号。
@MainActor final class ChatListController: NSObject, UICollectionViewDelegate {
    var onNearBottom: (Bool) -> Void = { _ in }
    var onNearTop: () -> Void = {}
    var onRefresh: () async -> Void = {}
    var content: (ChatListEntry) -> AnyView = { _ in AnyView(EmptyView()) }

    private(set) var following = true
    private var animatingToLatest = false
    private var nearBottom = true
    private var entries: [ChatListEntry] = []
    private var byID: [String: ChatListEntry] = [:]
    private var deferred: [ChatListEntry]?
    private var lastWidth: CGFloat = 0
    private var widthAnchor: String?
    private let frames = ScrollFrameMonitor()
    private let layout = ChatTimelineLayout()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private weak var collection: ChatTimelineCollection?

    func makeCollection() -> ChatTimelineCollection {
        let view = ChatTimelineCollection(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = false
        view.keyboardDismissMode = .interactive
        view.contentInsetAdjustmentBehavior = .never
        view.delegate = self
        view.accessibilityIdentifier = "chat-timeline-scroll"
        view.afterLayout = { [weak self] in self?.layoutDidRun() }
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { @MainActor in
                await self?.onRefresh()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        view.refreshControl = refresh
        layout.estimate = { [weak self] id, width in self?.byID[id]?.estimatedHeight(width: width) ?? 80 }
        let registration = UICollectionView.CellRegistration<ChatTimelineCell, String> { [weak self] cell, _, id in
            guard let self, let entry = self.byID[id] else { return }
            let body = self.content(entry)
            // .id 让复用的格子不继承上一条消息的 @State。
            cell.contentConfiguration = UIHostingConfiguration { body.id(id) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: view) { collection, path, id in
            collection.dequeueConfiguredReusableCell(using: registration, for: path, item: id)
        }
        collection = view
        return view
    }

    func update(_ new: [ChatListEntry]) {
        guard new != entries, let view = collection else { return }
        let oldIDs = entries.map(\.id), newIDs = new.map(\.id)
        let anchor = following ? nil : readingAnchor(in: view)
        // 减速途中往锚点上方插东西要改 offset，会掐断惯性：等停下再插。
        if let anchor, view.isDecelerating, oldIDs != newIDs, insertsAbove(anchor.id, old: oldIDs, new: newIDs) {
            deferred = new
            return
        }
        deferred = nil
        let previous = byID
        entries = new
        byID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        layout.setIDs(newIDs)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newIDs)
        let changed = new.filter { entry in previous[entry.id].map { $0 != entry } ?? false }.map(\.id)
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: false)
        if let anchor {
            view.layoutIfNeeded()
            if let frame = layout.frame(for: anchor.id) {
                let target = frame.minY - anchor.offset
                if abs(view.contentOffset.y - target) > 0.5 { view.contentOffset.y = target }
            }
        }
    }

    func scrollToLatest(animated: Bool) {
        guard let view = collection else { return }
        following = true
        view.layoutIfNeeded()
        let bottom = bottomOffset(view)
        // 离得太远先无动画跳到近处：沿途都是估高，长距离动画的终点不可靠。
        if animated, bottom - view.contentOffset.y < view.bounds.height * 3 {
            animatingToLatest = true
            view.setContentOffset(CGPoint(x: 0, y: bottom), animated: true)
        } else {
            view.contentOffset.y = bottom
        }
        report(view)
    }

    func scrollTo(id: String, animated: Bool) {
        guard let view = collection, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        following = false
        view.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: animated)
    }

    /// 只在 DEBUG 记录帧节奏，正式包里是空操作。
    func stopMonitoring() { frames.stop() }

    private func readingAnchor(in view: UICollectionView) -> (id: String, offset: CGFloat)? {
        let top = view.contentOffset.y + view.adjustedContentInset.top
        for id in layout.ids {
            if let frame = layout.frame(for: id), frame.maxY > top { return (id, frame.minY - view.contentOffset.y) }
        }
        return nil
    }

    private func insertsAbove(_ anchor: String, old: [String], new: [String]) -> Bool {
        guard let before = old.firstIndex(of: anchor), let after = new.firstIndex(of: anchor) else { return true }
        return before != after
    }

    private func bottomOffset(_ view: UICollectionView) -> CGFloat {
        max(-view.adjustedContentInset.top, view.collectionViewLayout.collectionViewContentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
    }

    private func layoutDidRun() {
        guard let view = collection else { return }
        if view.bounds.width != lastWidth {
            let wasFirst = lastWidth == 0
            lastWidth = view.bounds.width
            if !wasFirst, !following, let id = widthAnchor {
                view.layoutIfNeeded()
                scrollTo(id: id, animated: false)
            }
        }
        if !following { widthAnchor = readingAnchor(in: view)?.id }
        guard following, !animatingToLatest, !view.isTracking, !view.isDecelerating else { return }
        let bottom = bottomOffset(view)
        if abs(view.contentOffset.y - bottom) > 0.5 { view.contentOffset.y = bottom }
    }

    private func report(_ scroll: UIScrollView) {
        let distance = scroll.contentSize.height + scroll.adjustedContentInset.bottom - (scroll.contentOffset.y + scroll.bounds.height)
        let near = distance < 70
        if near != nearBottom {
            nearBottom = near
            onNearBottom(near)
        }
    }

    private func settled(_ scroll: UIScrollView) {
        AmbientMotionPolicy.scrollQuiet = false
        frames.stop()
        if nearBottom { following = true }
        if let pending = deferred { update(pending) }
    }

    func scrollViewWillBeginDragging(_ scroll: UIScrollView) {
        following = false
        animatingToLatest = false
        AmbientMotionPolicy.scrollQuiet = true
        frames.start()
    }

    func scrollViewDidScroll(_ scroll: UIScrollView) {
        report(scroll)
        if scroll.isDragging || scroll.isDecelerating, scroll.contentOffset.y < scroll.bounds.height * 1.5 { onNearTop() }
    }

    func scrollViewDidEndDragging(_ scroll: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settled(scroll) }
    }

    func scrollViewDidEndDecelerating(_ scroll: UIScrollView) { settled(scroll) }

    func scrollViewDidEndScrollingAnimation(_ scroll: UIScrollView) {
        animatingToLatest = false
        settled(scroll)
    }
}

struct ChatCollectionView: UIViewRepresentable {
    let controller: ChatListController
    let entries: [ChatListEntry]

    func makeUIView(context: Context) -> ChatTimelineCollection { controller.makeCollection() }

    func updateUIView(_ view: ChatTimelineCollection, context: Context) { controller.update(entries) }
}

/// 滑走再滑回来，格子是重建的；「展开」这类状态要活得比格子久。
@MainActor @Observable final class ChatExpansion {
    private var open: Set<String> = []
    func isOpen(_ id: String) -> Bool { open.contains(id) }
    func toggle(_ id: String) { if open.contains(id) { open.remove(id) } else { open.insert(id) } }
    func set(_ id: String, _ value: Bool) { if value { open.insert(id) } else { open.remove(id) } }
}

extension EnvironmentValues {
    /// 飞行气泡的落点：格子在独立的 hosting 里，SwiftUI preference 传不出来。
    @Entry var chatBubbleFrameSink: ((String, CGRect) -> Void)?
}

/// 只在飞行中的那条气泡上报全局坐标。
struct ChatBubbleFrameReport: ViewModifier {
    let id: String
    let enabled: Bool
    @Environment(\.chatBubbleFrameSink) private var sink
    func body(content: Content) -> some View {
        if enabled, let sink {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sink(id, $0) }
        } else {
            content
        }
    }
}

/// 日期分隔。
struct ChatDayAnchor: View {
    let label: String
    var body: some View {
        Text(label)
            .font(TypeScale.caption.weight(.medium))
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("chat-day-anchor")
    }
}
