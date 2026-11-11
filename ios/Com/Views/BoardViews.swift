import SwiftUI
import ComCore
import UIKit

// 四列看板：布局分档、瘦卡、详情 sheet、「移到…」与自研长按拖拽（P0 见 docs/COM_NEXT_KANBAN_PLAN_20261103.md）。

enum BoardLayoutMode: Equatable {
    case singleCapsule, twoColumnScroll, fourColumn
    static func mode(width: CGFloat) -> BoardLayoutMode {
        .fourColumn
    }
}

private func boardCards(in group: BoardGroup, from cards: [BoardColumn: [JSON]]) -> [JSON] {
    switch group {
    case .suggest: cards[.suggest] ?? []
    case .todo: (cards[.doing] ?? []) + (cards[.todo] ?? [])
    case .done: cards[.done] ?? []
    }
}

private func boardGroupDoingCount(_ cards: [BoardColumn: [JSON]]) -> Int {
    cards[.doing]?.count ?? 0
}

private func boardCardColumn(_ card: JSON) -> BoardColumn {
    BoardColumn(rawValue: card["column"].string) ?? .suggest
}

private func boardCardFocusID(_ id: String) -> String {
    "board-focus-" + id.replacingOccurrences(of: ":", with: "__")
}

private func boardDoingTagID(_ id: String) -> String {
    "board-doing-tag-" + id.replacingOccurrences(of: ":", with: "__")
}

struct BoardKanbanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var drag = BoardDragSession()
    @State private var detail: JSON?
    @State private var containerWidth: CGFloat = 0
    @State private var groupFrames: [BoardGroup: CGRect] = [:]
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var capsuleFrames: [BoardGroup: CGRect] = [:]
    @State private var placeholderFrames: [BoardGroup: CGRect] = [:]
    @State private var doneDropFrame: CGRect = .zero
    @State private var horizontalSwipeCardID: String?

    private var mode: BoardLayoutMode { BoardLayoutMode.mode(width: containerWidth) }

    var body: some View {
        boardContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if let ghost = drag.ghostCard {
                    BoardSlimCard(
                        card: ghost,
                        pending: false,
                        showProgress: boardCardColumn(ghost) == .doing,
                        isDoing: boardCardColumn(ghost) == .doing,
                        isDoneColumn: false,
                        newlyDone: false,
                        isFloating: true,
                        isCompact: drag.cardSize.width < 180,
                        shadowRadius: drag.shadowRadius,
                        shadowY: drag.shadowY,
                        shadowOpacity: drag.shadowOpacity
                    )
                    .frame(width: drag.cardSize.width)
                    .scaleEffect(drag.liftScale)
                    .rotationEffect(.degrees(drag.tilt))
                    .opacity(drag.floatingOpacity)
                    .offset(x: drag.floatingPosition.x, y: drag.floatingPosition.y)
                    .allowsHitTesting(false)
                    .zIndex(50)
                }
            }
            .coordinateSpace(name: "board")
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { oldW, newW in
                            var tx = Transaction()
                            tx.disablesAnimations = true
                            withTransaction(tx) {
                                drag.cancelImmediate()
                                horizontalSwipeCardID = nil
                                model.boardDragFreeze = false
                                containerWidth = newW
                            }
                            if BoardLayoutMode.mode(width: oldW) != BoardLayoutMode.mode(width: newW) {
                                withAnimation(ComMotion.reduced(reduce, ComMotion.crossfade)) {}
                            }
                        }
                }
            }
            .onPreferenceChange(BoardGroupFrameKey.self) { groupFrames = $0 }
            .onPreferenceChange(BoardCardFrameKey.self) { cardFrames = $0 }
            .onPreferenceChange(BoardCapsuleFrameKey.self) { capsuleFrames = $0 }
            .onPreferenceChange(BoardPlaceholderFrameKey.self) { placeholderFrames = $0 }
            .onPreferenceChange(BoardDoneDropFrameKey.self) { doneDropFrame = $0 }
            .sheet(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
                if let detail { BoardCardDetailSheet(card: detail) }
            }
    }

    @ViewBuilder private var boardContent: some View {
        switch mode {
        case .singleCapsule:
            VStack(spacing: Space.md) {
                BoardCapsulePicker(
                    group: boardGroupBinding,
                    columns: model.boardCards,
                    dragHover: drag.hoverCapsule,
                    fillProgress: drag.capsuleFillProgress,
                    dragging: drag.active && !drag.settling
                )
                ZStack(alignment: .topLeading) {
                    if drag.active, drag.originGroup != model.boardColumn {
                        groupScroll(drag.originGroup)
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    groupScroll(model.boardColumn)
                }
            }
        case .twoColumnScroll, .fourColumn:
            boardMeasuredColumns
        }
    }

    private var boardGroupBinding: Binding<BoardGroup> {
        Binding(get: { model.boardColumn }, set: { model.boardColumn = $0 })
    }

    @ViewBuilder private var boardMeasuredColumns: some View {
        let totalW = containerWidth > 0 ? containerWidth : 390
        if totalW < 560 {
            let spacing: CGFloat = 6
            let hPad: CGFloat = 8
            let colWidth = max(108, floor((totalW - hPad * 2 - spacing * 2) / 3))
            HStack(alignment: .top, spacing: spacing) {
                ForEach(BoardGroup.allCases) { group in
                    groupBlock(group, width: colWidth)
                }
            }
            .padding(.horizontal, hPad)
        } else {
            let spacing: CGFloat = Space.md
            let hPad: CGFloat = Layout.margin
            let colWidth = max(156, min(320, floor((totalW - hPad * 2 - spacing * 2) / 3)))
            HStack(alignment: .top, spacing: spacing) {
                ForEach(BoardGroup.allCases) { group in
                    groupBlock(group, width: colWidth)
                }
            }
            .padding(.horizontal, hPad)
        }
    }

    private func groupScroll(_ group: BoardGroup) -> some View {
        groupBlock(group, width: max(260, containerWidth - Layout.margin * 2))
            .padding(.horizontal, Layout.margin)
    }

    private func groupBlock(_ group: BoardGroup, width: CGFloat) -> some View {
        BoardGroupColumnView(
            group: group,
            width: width,
            drag: drag,
            mode: mode,
            containerWidth: containerWidth,
            groupFrames: groupFrames,
            cardFrames: cardFrames,
            capsuleFrames: capsuleFrames,
            placeholderFrames: placeholderFrames,
            doneDropFrame: doneDropFrame,
            pendingIDs: model.boardPendingIDs,
            inFlightIDs: model.boardInFlightIDs,
            recentlyDoneIDs: model.boardRecentlyDoneIDs,
            moveNotes: model.boardMoveNotes,
            horizontalSwipeCardID: $horizontalSwipeCardID,
            anchor: model.boardAnchor(for: group.boardAnchorColumn),
            onAnchor: { model.setBoardAnchor($0, column: group.boardAnchorColumn) },
            onOpen: { detail = $0 },
            onSelectSingleGroup: { model.boardColumn = $0 },
            onMove: { card, target, index in
                // 长按拖进待办组给的是合并序号（正在做在上）：换成底层 doing / todo 列里的序号。
                var idx = index
                if let i = index, target == .todo || target == .doing {
                    let doingN = (model.boardCards[.doing] ?? []).filter { $0.id != card.id }.count
                    idx = target == .todo ? max(0, i - doingN) : min(i, doingN)
                }
                Task { _ = await model.boardMove(card: card, to: target, insertIndex: idx) }
            }
        )
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: BoardGroupFrameKey.self, value: [group: geo.frame(in: .named("board"))])
            }
        }
    }
}

private extension BoardGroup {
    var boardAnchorColumn: BoardColumn {
        switch self {
        case .suggest: .suggest
        case .todo: .todo
        case .done: .done
        }
    }
}

private struct BoardDisplayItem: Identifiable {
    let id: String
    let card: JSON?
    let isPlaceholder: Bool
}

private struct BoardTodoRow: Identifiable {
    enum Kind {
        case section(String)
        case card(JSON, index: Int, placeholder: Bool)
        case dropPlaceholder
    }
    let id: String
    let kind: Kind

    @MainActor
    static func rowsForGroup(_ group: BoardGroup, doing: [JSON], todo: [JSON], suggest: [JSON], done: [JSON], drag: BoardDragSession) -> [BoardTodoRow] {
        switch group {
        case .suggest: return simpleList(suggest, group: .suggest, drag: drag)
        case .done: return simpleList(done, group: .done, drag: drag)
        case .todo: return todoGroupRows(doing: doing, todo: todo, drag: drag)
        }
    }

    @MainActor
    private static func simpleList(_ cards: [JSON], group: BoardGroup, drag: BoardDragSession) -> [BoardTodoRow] {
        guard drag.active, let ghost = drag.ghostCard else {
            return cards.enumerated().map { i, c in
                BoardTodoRow(id: c.id, kind: .card(c, index: i, placeholder: false))
            }
        }
        if drag.originGroup == group {
            var reordered = cards
            if drag.hoverGroup == group || drag.hoverGroup == nil,
               let fromIdx = reordered.firstIndex(where: { $0.id == ghost.id }) {
                let moved = reordered.remove(at: fromIdx)
                let targetIdx = min(max(0, drag.insertIndex), reordered.count)
                reordered.insert(moved, at: targetIdx)
            }
            return reordered.enumerated().map { i, c in
                BoardTodoRow(id: c.id, kind: .card(c, index: i, placeholder: c.id == ghost.id))
            }
        }
        if drag.hoverGroup == group, drag.hoverCapsule == nil, !drag.hoverDoneStrip {
            var items = cards.enumerated().map { i, c in BoardTodoRow(id: c.id, kind: .card(c, index: i, placeholder: false)) }
            let targetIdx = min(max(0, drag.insertIndex), items.count)
            items.insert(BoardTodoRow(id: "__ph__" + group.rawValue, kind: .dropPlaceholder), at: targetIdx)
            return items
        }
        return cards.enumerated().map { i, c in
            BoardTodoRow(id: c.id, kind: .card(c, index: i, placeholder: false))
        }
    }

    @MainActor
    private static func todoGroupRows(doing: [JSON], todo: [JSON], drag: BoardDragSession) -> [BoardTodoRow] {
        var rows: [BoardTodoRow] = []
        let doingCount = doing.filter { $0.id != drag.ghostCard?.id }.count
        let doingList = reorderSublist(doing, group: .todo, sub: .doing, drag: drag, offset: 0)
        let todoList = reorderSublist(todo, group: .todo, sub: .todo, drag: drag, offset: doingCount)
        // 从别组拖进来：占位落在「待办」子段（合并序号减去正在做数），先算好再拼分段标题，免得标题行把占位挤偏。
        let incoming = drag.hoverGroup == .todo && drag.originGroup != .todo && drag.hoverCapsule == nil && !drag.hoverDoneStrip && drag.ghostCard != nil
        let incomingIdx = min(max(0, drag.insertIndex - doingCount), todoList.count)
        let showSections = !doingList.isEmpty && (!todoList.isEmpty || incoming)
        if !doingList.isEmpty {
            if showSections {
                rows.append(BoardTodoRow(id: "sec-doing", kind: .section("正在做 · \(doingList.count)")))
            }
            rows += doingList.enumerated().map { i, c in
                BoardTodoRow(id: c.id, kind: .card(c, index: i, placeholder: ghostPlaceholder(drag, c)))
            }
        }
        if !todoList.isEmpty || incoming {
            if showSections {
                rows.append(BoardTodoRow(id: "sec-todo", kind: .section("待办 · \(todoList.count)")))
            }
            var todoRows = todoList.enumerated().map { i, c in
                BoardTodoRow(id: c.id, kind: .card(c, index: i, placeholder: ghostPlaceholder(drag, c)))
            }
            if incoming {
                todoRows.insert(BoardTodoRow(id: "__ph__todo", kind: .dropPlaceholder), at: incomingIdx)
            }
            rows += todoRows
        }
        return rows
    }

    @MainActor
    private static func ghostPlaceholder(_ drag: BoardDragSession, _ card: JSON) -> Bool {
        drag.ghostCard?.id == card.id && drag.originGroup == .todo
    }

    @MainActor
    private static func reorderSublist(_ cards: [JSON], group: BoardGroup, sub: BoardColumn, drag: BoardDragSession, offset: Int) -> [JSON] {
        guard drag.active, let ghost = drag.ghostCard, drag.originGroup == group, boardCardColumn(ghost) == sub else {
            return cards
        }
        guard drag.hoverGroup == group || drag.hoverGroup == nil else { return cards }
        var reordered = cards
        guard let fromIdx = reordered.firstIndex(where: { $0.id == ghost.id }) else { return cards }
        let moved = reordered.remove(at: fromIdx)
        let targetIdx = min(max(0, drag.insertIndex - offset), reordered.count)  // 合并序号 → 本子段序号
        reordered.insert(moved, at: targetIdx)
        return reordered
    }
}

private struct BoardGroupColumnView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let group: BoardGroup
    let width: CGFloat
    @Bindable var drag: BoardDragSession
    let mode: BoardLayoutMode
    let containerWidth: CGFloat
    let groupFrames: [BoardGroup: CGRect]
    let cardFrames: [String: CGRect]
    let capsuleFrames: [BoardGroup: CGRect]
    let placeholderFrames: [BoardGroup: CGRect]
    let doneDropFrame: CGRect
    let pendingIDs: Set<String>
    let inFlightIDs: Set<String>
    let recentlyDoneIDs: Set<String>
    let moveNotes: [String: String]
    @Binding var horizontalSwipeCardID: String?
    let anchor: String?
    let onAnchor: (String?) -> Void
    let onOpen: (JSON) -> Void
    let onSelectSingleGroup: (BoardGroup) -> Void
    let onMove: (JSON, BoardColumn, Int?) -> Void

    private var doingCards: [JSON] { model.boardCards[.doing] ?? [] }
    private var todoOnlyCards: [JSON] { model.boardCards[.todo] ?? [] }
    private var cards: [JSON] { boardCards(in: group, from: model.boardCards) }

    private var isCompact: Bool { width < 180 }

    private var isHoveredNewGroup: Bool {
        drag.active && !drag.settling && drag.hoverGroup == group && drag.originGroup != group
    }

    private var displayRows: [BoardTodoRow] {
        BoardTodoRow.rowsForGroup(
            group,
            doing: doingCards,
            todo: todoOnlyCards,
            suggest: model.boardCards[.suggest] ?? [],
            done: model.boardCards[.done] ?? [],
            drag: drag
        )
    }

    var body: some View {
        VStack(spacing: isCompact ? 6 : Space.sm) {
            BoardGroupHeader(
                group: group,
                count: cards.count,
                doingCount: doingCards.count,
                highlighted: isHoveredNewGroup,
                compact: isCompact
            )
            ScrollView {
                VStack(spacing: isCompact ? 6 : Space.sm) {
                    ForEach(displayRows) { row in
                        switch row.kind {
                        case .section(let title):
                            Text(title)
                                .font(isCompact ? .system(size: 11, weight: .semibold) : TypeScale.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 2)
                        case .card(let card, let index, let placeholder):
                            cardRow(card: card, index: index, isPlaceholder: placeholder)
                        case .dropPlaceholder:
                            BoardPlaceholderCard(height: drag.cardSize.height)
                                .background {
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: BoardPlaceholderFrameKey.self,
                                            value: [group: geo.frame(in: .named("board"))]
                                        )
                                    }
                                }
                        }
                    }
                    Color.clear.frame(height: 72)
                }
                .scrollTargetLayout()
                .animation(ComMotion.reduced(reduce, ComMotion.reflow), value: displayRows.map(\.id))
                .background(BoardScrollViewBridge(group: group, session: drag))
            }
            .scrollPosition(id: .init(get: { anchor }, set: { onAnchor($0) }), anchor: .center)
            .scrollDisabled(drag.active || model.boardDragFreeze || horizontalSwipeCardID != nil)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Palette.accent.opacity(isHoveredNewGroup ? 0.08 : 0))
                .padding(.horizontal, -2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Palette.accentText.opacity(isHoveredNewGroup ? 0.45 : 0), lineWidth: 1.5)
                .padding(.horizontal, -2)
                .allowsHitTesting(false)
        )
        .animation(reduce ? nil : .smooth(duration: 0.18), value: isHoveredNewGroup)
        .frame(width: width)
        .accessibilityIdentifier("board-column-" + group.rawValue)
    }

    @ViewBuilder
    private func cardRow(card: JSON, index: Int, isPlaceholder: Bool) -> some View {
        let underlying = boardCardColumn(card)
        let isPressing = !reduce && drag.pressingCardID == card.id && !drag.active
        let note = moveNotes[card.id] ?? ""
        let canDrag = !pendingIDs.contains(card.id) && !inFlightIDs.contains(card.id)
        let swipeEnabled = canDrag && (mode == .singleCapsule || mode == .fourColumn || mode == .twoColumnScroll)
        let showFocus = group == .todo && underlying != .done
        BoardCardInteractiveRow(
            card: card,
            underlying: underlying,
            group: group,
            width: width,
            isPlaceholder: isPlaceholder,
            isPressing: isPressing,
            canDrag: canDrag,
            swipeEnabled: swipeEnabled,
            showFocus: showFocus,
            pending: pendingIDs.contains(card.id),
            newlyDone: recentlyDoneIDs.contains(card.id),
            note: note,
            drag: drag,
            mode: mode,
            containerWidth: containerWidth,
            groupFrames: groupFrames,
            cardFrames: cardFrames,
            capsuleFrames: capsuleFrames,
            placeholderFrames: placeholderFrames,
            doneDropFrame: doneDropFrame,
            horizontalSwipeCardID: $horizontalSwipeCardID,
            reduce: reduce,
            onOpen: onOpen,
            onSelectSingleGroup: onSelectSingleGroup,
            onMove: onMove,
            moveMenu: { moveMenu(card) },
            moveAccessibility: { moveAccessibility(card, underlying: underlying, index: index) }
        )
    }

    @ViewBuilder private func moveMenu(_ card: JSON) -> some View {
        let underlying = boardCardColumn(card)
        Button("聊这件", systemImage: "bubble.left") {
            triggerAttachBoardCard(card, model: model)
        }
        .accessibilityIdentifier("board-menu-chat-" + card.id)
        ForEach(BoardColumn.allCases.filter { $0.moveTarget != nil && $0 != underlying }) { target in
            Button("移到\(target.title)") { onMove(card, target, nil) }
                .accessibilityIdentifier("board-move-" + target.rawValue)
        }
    }

    @ViewBuilder private func moveAccessibility(_ card: JSON, underlying: BoardColumn, index: Int) -> some View {
        Button("聊这件") {
            triggerAttachBoardCard(card, model: model)
            UIAccessibility.post(notification: .announcement, argument: "已挂入聊天输入框")
        }
        ForEach(BoardColumn.allCases.filter { $0.moveTarget != nil && $0 != underlying }) { target in
            Button("移到 \(target.title)") {
                onMove(card, target, nil)
                UIAccessibility.post(notification: .announcement, argument: "已移到\(target.title)")
            }
        }
        let column = underlying
        let colCards = model.boardCards[column] ?? []
        if let idx = colCards.firstIndex(where: { $0.id == card.id }), idx > 0 {
            Button("上移") {
                model.reorderBoardColumnLocally(column, fromIndex: idx, toIndex: idx - 1)
                UIAccessibility.post(notification: .announcement, argument: "已上移")
            }
        }
        if let idx = colCards.firstIndex(where: { $0.id == card.id }), idx < colCards.count - 1 {
            Button("下移") {
                model.reorderBoardColumnLocally(column, fromIndex: idx, toIndex: idx + 1)
                UIAccessibility.post(notification: .announcement, argument: "已下移")
            }
        }
    }
}

private struct BoardCardInteractiveRow<Menu: View, A11y: View>: View {
    @Environment(AppModel.self) private var model
    let card: JSON
    let underlying: BoardColumn
    let group: BoardGroup
    let width: CGFloat
    let isPlaceholder: Bool
    let isPressing: Bool
    let canDrag: Bool
    let swipeEnabled: Bool
    let showFocus: Bool
    let pending: Bool
    let newlyDone: Bool
    let note: String
    @Bindable var drag: BoardDragSession
    let mode: BoardLayoutMode
    let containerWidth: CGFloat
    let groupFrames: [BoardGroup: CGRect]
    let cardFrames: [String: CGRect]
    let capsuleFrames: [BoardGroup: CGRect]
    let placeholderFrames: [BoardGroup: CGRect]
    let doneDropFrame: CGRect
    @Binding var horizontalSwipeCardID: String?
    let reduce: Bool
    let onOpen: (JSON) -> Void
    let onSelectSingleGroup: (BoardGroup) -> Void
    let onMove: (JSON, BoardColumn, Int?) -> Void
    @ViewBuilder let moveMenu: () -> Menu
    @ViewBuilder let moveAccessibility: () -> A11y

    private var isCompact: Bool { width < 180 }

    var body: some View {
        ZStack {
            // 焦点开关放进卡片内容层：子 Button 优先于外层 onTapGesture，点它不会顺带打开详情。
            cardContent
                .overlay(alignment: isCompact ? .bottomTrailing : .trailing) {
                    if showFocus && !isPlaceholder { focusToggle }
                }
        }
        .scaleEffect(isPressing ? 0.985 : 1)
        .animation(reduce ? .easeOut(duration: 0.12) : ComMotion.press, value: isPressing)
        .contentShape(.rect(cornerRadius: Radius.md))
        .onTapGesture {
            guard !drag.active else { return }
            onOpen(card)
        }
        .gesture(
            BoardCardLongPressGesture(
                enabled: canDrag,
                card: card,
                group: group,
                column: underlying,
                index: 0,
                reduce: reduce,
                session: drag,
                onTouchDown: { down in
                    if down {
                        drag.schedulePressPreview(cardID: card.id, reduce: reduce)
                    } else {
                        drag.clearPressPreview(reduce: reduce)
                    }
                },
                onBegin: { point in
                    beginFloatingDrag(at: point)
                },
                onMove: { point, vx in
                    moveFloatingDrag(to: point, velocityX: vx)
                },
                onEnd: { completed in
                    endFloatingDrag(completed: completed)
                }
            )
        )
        .modifier(BoardCardSwipePanModifier(
            enabled: swipeEnabled && canDrag,
            session: drag,
            onBegin: { point in
                beginFloatingDrag(at: point)
            },
            onMove: { point, vx in
                moveFloatingDrag(to: point, velocityX: vx)
            },
            onEnd: { completed in
                endFloatingDrag(completed: completed)
            }
        ))
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: BoardCardFrameKey.self, value: [card.id: geo.frame(in: .named("board"))])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(card["title"].string)
        .accessibilityIdentifier(boardCardID(card.id))
        .accessibilityActions { moveAccessibility() }
        .opacity(pending ? 0.7 : 1)
        .scrollTransition { content, phase in
            content.opacity(phase.isIdentity ? 1 : 0.92)
        }
    }

    @ViewBuilder private var cardContent: some View {
        if isPlaceholder {
            BoardPlaceholderCard(height: drag.cardSize.height)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: BoardPlaceholderFrameKey.self,
                            value: [group: geo.frame(in: .named("board"))]
                        )
                    }
                }
        } else {
            BoardSlimCard(
                card: card,
                pending: pending,
                showProgress: underlying == .doing,
                isDoing: underlying == .doing,
                isDoneColumn: underlying == .done,
                newlyDone: newlyDone,
                shake: !note.isEmpty,
                errorNote: note,
                isCompact: isCompact
            )
        }
    }

    private var focusToggle: some View {
        let isDoing = underlying == .doing
        return Button {
            Haptics.selection()
            let target: BoardColumn = isDoing ? .todo : .doing
            Task { _ = await model.boardMove(card: card, to: target) }
        } label: {
            Image(systemName: isDoing ? "flame.fill" : "flame")
                .font(.system(size: isCompact ? 14 : 18, weight: .semibold))
                .foregroundStyle(isDoing ? Palette.danger : Palette.textSecondary)
                .frame(width: isCompact ? 30 : 44, height: isCompact ? 30 : 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDoing ? "取消正在做" : "设为正在做")
        .accessibilityIdentifier(boardCardFocusID(card.id))
    }

    private func beginFloatingDrag(at point: CGPoint) {
        guard !drag.active else { return }
        // 待办组的插入位一律按「正在做 + 待办」合并序号算（和 drag.move 同一口径），落地时在 onMove 里换回底层列序号。
        let colCards = group == .todo
            ? (model.boardCards[.doing] ?? []) + (model.boardCards[.todo] ?? [])
            : (model.boardCards[underlying] ?? [])
        let origIdx = colCards.firstIndex(where: { $0.id == card.id }) ?? 0
        let frame = cardFrames[card.id] ?? CGRect(x: point.x - width / 2, y: point.y - 34, width: width, height: 68)
        model.boardDragFreeze = true
        drag.begin(card: card, group: group, column: underlying, index: origIdx, frame: frame, at: point, reduce: reduce)
    }

    private func moveFloatingDrag(to point: CGPoint, velocityX: CGFloat?) {
        guard drag.active else { return }
        drag.move(
            to: point,
            velocityX: velocityX,
            mode: mode,
            containerWidth: containerWidth,
            currentSingleGroup: model.boardColumn,
            groupFrames: groupFrames,
            cardFrames: cardFrames,
            capsuleFrames: capsuleFrames,
            doneDropFrame: doneDropFrame,
            boardCards: model.boardCards,
            reduce: reduce,
            onSelectGroup: onSelectSingleGroup
        )
    }

    private func endFloatingDrag(completed: Bool) {
        if completed {
            drag.end(
                placeholderFrames: placeholderFrames,
                capsuleFrames: capsuleFrames,
                groupFrames: groupFrames,
                doneDropFrame: doneDropFrame,
                reduce: reduce,
                onMove: onMove,
                onFinish: { model.boardDragFreeze = false }
            )
        } else {
            drag.cancelAnimated(reduce: reduce) {
                model.boardDragFreeze = false
            }
        }
    }

    init(
        card: JSON,
        underlying: BoardColumn,
        group: BoardGroup,
        width: CGFloat,
        isPlaceholder: Bool,
        isPressing: Bool,
        canDrag: Bool,
        swipeEnabled: Bool,
        showFocus: Bool,
        pending: Bool,
        newlyDone: Bool,
        note: String,
        drag: BoardDragSession,
        mode: BoardLayoutMode,
        containerWidth: CGFloat,
        groupFrames: [BoardGroup: CGRect],
        cardFrames: [String: CGRect],
        capsuleFrames: [BoardGroup: CGRect],
        placeholderFrames: [BoardGroup: CGRect],
        doneDropFrame: CGRect,
        horizontalSwipeCardID: Binding<String?>,
        reduce: Bool,
        onOpen: @escaping (JSON) -> Void,
        onSelectSingleGroup: @escaping (BoardGroup) -> Void,
        onMove: @escaping (JSON, BoardColumn, Int?) -> Void,
        @ViewBuilder moveMenu: @escaping () -> Menu,
        @ViewBuilder moveAccessibility: @escaping () -> A11y
    ) {
        self.card = card
        self.underlying = underlying
        self.group = group
        self.width = width
        self.isPlaceholder = isPlaceholder
        self.isPressing = isPressing
        self.canDrag = canDrag
        self.swipeEnabled = swipeEnabled
        self.showFocus = showFocus
        self.pending = pending
        self.newlyDone = newlyDone
        self.note = note
        self.drag = drag
        self.mode = mode
        self.containerWidth = containerWidth
        self.groupFrames = groupFrames
        self.cardFrames = cardFrames
        self.capsuleFrames = capsuleFrames
        self.placeholderFrames = placeholderFrames
        self.doneDropFrame = doneDropFrame
        self._horizontalSwipeCardID = horizontalSwipeCardID
        self.reduce = reduce
        self.onOpen = onOpen
        self.onSelectSingleGroup = onSelectSingleGroup
        self.onMove = onMove
        self.moveMenu = moveMenu
        self.moveAccessibility = moveAccessibility
    }
}

private struct BoardPlaceholderCard: View {
    let height: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Palette.accent.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Palette.accentText.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .frame(minHeight: max(44, height))
            .accessibilityHidden(true)
    }
}

private struct BoardGroupHeader: View {
    let group: BoardGroup
    let count: Int
    var doingCount: Int = 0
    var highlighted: Bool = false
    var compact: Bool = false
    @State private var showArchiveSheet = false

    var body: some View {
        HStack(spacing: compact ? 4 : Space.sm) {
            Text(group.title)
                .font(compact ? TypeScale.caption.weight(.semibold) : TypeScale.subheadline.weight(.semibold))
                .foregroundStyle(highlighted ? Palette.accentText : Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            CountBadge(count: count)
            if group == .todo, doingCount > 0 {
                Circle().fill(Palette.danger).frame(width: 6, height: 6)
            }
            Spacer(minLength: 0)
            if group == .done {
                Button {
                    showArchiveSheet = true
                } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: compact ? 12 : 14, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: compact ? 26 : 32, height: compact ? 26 : 32)
                        .background(Palette.fill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("board-open-archive-sheet")
            } else if !compact {
                Button { } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加")
                .disabled(true)
                .opacity(0.35)
            }
        }
        .frame(height: compact ? 34 : 44)
        .sheet(isPresented: $showArchiveSheet) {
            MatterArchiveSheet()
        }
    }
}

private struct BoardColumnHeader: View {
    let column: BoardColumn
    let count: Int
    var highlighted: Bool = false
    var body: some View {
        HStack(spacing: Space.sm) {
            Text(column.title)
                .font(TypeScale.subheadline.weight(.semibold))
                .foregroundStyle(highlighted ? Palette.accentText : Palette.textPrimary)
            CountBadge(count: count)
            Spacer(minLength: 0)
            if column != .done {
                Button { } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加")
                .disabled(true)
                .opacity(0.35)
            }
        }
        .frame(height: 44)
    }
}

struct BoardSlimCard: View {
    let card: JSON
    var pending: Bool = false
    var showProgress: Bool = false
    var isDoing: Bool = false
    var isDoneColumn: Bool = false
    var newlyDone: Bool = false
    var shake: Bool = false
    var errorNote: String = ""
    var isFloating: Bool = false
    var isCompact: Bool = false
    var shadowRadius: CGFloat = 12
    var shadowY: CGFloat = 3
    var shadowOpacity: Double = 0.05

    @State private var shakeX: CGFloat = 0
    @State private var ringTrim: CGFloat = 0
    @State private var checkScale: CGFloat = 0
    @State private var strikeProgress: CGFloat = 0
    @State private var compactDone: Bool = false
    @State private var doneAnimated = false
    @State private var isExecutingAction: Bool = false
    @State private var actionExecuted: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(AppModel.self) private var model

    private var item: JSON { card["kind"].string == "next" ? (card["next"].isNull ? card : card["next"]) : card }
    private var settledCompact: Bool { isDoneColumn && (!newlyDone || compactDone) }

    private var suggestedAction: JSON? {
        if !card["suggested_action"].isNull { return card["suggested_action"] }
        if !item["suggested_action"].isNull { return item["suggested_action"] }
        if !card["action"].isNull && (!card["action"]["label"].string.isEmpty || !card["action"]["title"].string.isEmpty) { return card["action"] }
        if !item["action"].isNull && (!item["action"]["label"].string.isEmpty || !item["action"]["title"].string.isEmpty) { return item["action"] }
        return nil
    }

    private var suggestedActionLabel: String {
        guard let act = suggestedAction else { return "" }
        let label = act["label"].string
        if !label.isEmpty { return label }
        let title = act["title"].string
        if !title.isEmpty { return title }
        let type = act["type"].string
        if type == "bookkeep" || type == "bookkeeping" { return "记一笔" }
        if type == "calendar" { return "加日程" }
        return "执行"
    }

    private var fsmStatus: String {
        let s = card["status"].string
        if !s.isEmpty { return s }
        let is_ = item["status"].string
        if !is_.isEmpty { return is_ }
        return card["column"].string
    }

    @ViewBuilder
    private var fsmStatusBadge: some View {
        switch fsmStatus {
        case "waiting_input", "waiting":
            Stamp(text: "等待输入", tone: .warning)
        case "executing":
            Stamp(text: "执行中", tone: .accent)
        case "error_retrying":
            Stamp(text: "重试中", tone: .warning, dashed: true)
        case "error_blocked":
            Stamp(text: "执行受阻", tone: .danger)
        case "snoozed":
            Stamp(text: "已稍后", tone: .neutral)
        case "dismissed":
            Stamp(text: "已划掉", tone: .neutral)
        case "cancelled":
            Stamp(text: "已取消", tone: .neutral)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var inlineActionButton: some View {
        if let _ = suggestedAction, !isDoneColumn, fsmStatus != "done" {
            Button(action: {
                executeInlineAction()
            }) {
                HStack(spacing: 4) {
                    if isExecutingAction {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Palette.accent)
                    } else if actionExecuted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.success)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.accent)
                    }
                    Text(actionExecuted ? "已完成" : "⚡️ " + suggestedActionLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(actionExecuted ? Palette.success : Palette.accent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Palette.accent.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.3), lineWidth: 0.8))
            }
            .buttonStyle(SoftPressStyle(scale: 0.95))
            .disabled(isExecutingAction || actionExecuted)
            .accessibilityIdentifier("board-inline-action-\(card.id)")
        }
    }

    @ViewBuilder
    private var chatAttachButton: some View {
        if !isDoneColumn && !isFloating {
            let ctx = makeBoardAttachedContext(card: card)
            let isAttached = !ctx.id.isEmpty && model.attachedContext?.id == ctx.id
            Button {
                triggerAttachBoardCard(card, model: model)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: isAttached ? "bubble.left.fill" : "bubble.left")
                        .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                    Text(isAttached ? (isCompact ? "已挂" : "已挂入") : (isCompact ? "聊" : "聊这件"))
                        .font(.system(size: isCompact ? 10 : 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(isAttached ? Palette.accentText : Palette.textSecondary)
                .padding(.horizontal, isCompact ? 6 : 8)
                .padding(.vertical, 3)
                .background(isAttached ? Tone.accent.soft : Palette.fill, in: Capsule())
            }
            .buttonStyle(SoftPressStyle(scale: 0.95))
            .accessibilityLabel("聊这件：\(ctx.title)")
            .accessibilityIdentifier("board-chat-\(card.id)")
        }
    }

    private func executeInlineAction() {
        guard !isExecutingAction, !actionExecuted, let act = suggestedAction else { return }
        isExecutingAction = true
        Haptics.impact(.medium)
        Task { @MainActor in
            let matterId = card["matter_id"].string.isEmpty ? card.id : card["matter_id"].string
            var fields = act.object
            if fields["action"] == nil {
                fields["action"] = .string("execute")
            }
            do {
                _ = try await model.mutate("/personal/matter/" + matterId.pathEncoded + "/action", fields: fields)
                withAnimation(ComMotion.settle) {
                    isExecutingAction = false
                    actionExecuted = true
                }
                Haptics.success()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    _ = await model.load(AppModel.boardPath)
                }
            } catch {
                isExecutingAction = false
                Haptics.error()
                model.banner = "执行失败: \(error.localizedDescription)"
            }
        }
    }

    var body: some View {
        Group {
            if settledCompact {
                compactDoneBody
            } else {
                standardCardBody
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Palette.surface)
                .shadow(
                    color: .black.opacity(isFloating ? shadowOpacity : 0),
                    radius: isFloating ? shadowRadius : 0,
                    y: isFloating ? shadowY : 0
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: isFloating ? 0 : 0.5)
        )
        .offset(x: shakeX)
        .onAppear {
            if isDoneColumn {
                startDoneSequenceIfNeeded()
            }
        }
        .onChange(of: newlyDone) { _, isNew in
            if isNew && isDoneColumn {
                startDoneSequenceIfNeeded()
            }
        }
        .onChange(of: shake) { _, on in
            guard on, !reduce else { return }
            withAnimation(.linear(duration: 0.08)) { shakeX = -6 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.linear(duration: 0.08)) { shakeX = 6 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.linear(duration: 0.08)) { shakeX = -3 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(.linear(duration: 0.08)) { shakeX = 0 }
            }
        }
    }

    private var compactDoneBody: some View {
        HStack(spacing: isCompact ? 6 : Space.sm) {
            doneCheckBadge(settled: true)
            Text(card["title"].string)
                .font(isCompact ? .system(size: 12) : TypeScale.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .strikethrough(true, color: Palette.textSecondary)
                .lineLimit(isCompact ? 2 : 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, isCompact ? 8 : Space.md)
        .padding(.vertical, isCompact ? 6 : 0)
        .frame(minHeight: isCompact ? 38 : 44)
    }

    private var standardCardBody: some View {
        HStack(spacing: 0) {
            if isDoing {
                Rectangle().fill(Palette.danger).frame(width: 3)
            } else if !isDoneColumn, (card["urgency"].string == "now" || item["urgency"].string == "now") {
                Rectangle().fill(Palette.accent).frame(width: 3)
            }
            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                if isCompact && isDoing {
                    Text("● 正在做")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.danger)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.danger.opacity(0.12), in: Capsule())
                        .accessibilityIdentifier(boardDoingTagID(card.id))
                }
                HStack(alignment: .firstTextBaseline, spacing: isCompact ? 4 : Space.sm) {
                    if isDoneColumn {
                        doneCheckBadge(settled: false)
                    }
                    if isDoing && !isCompact {
                        Text("● 正在做")
                            .font(TypeScale.caption.weight(.semibold))
                            .foregroundStyle(Palette.danger)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Palette.danger.opacity(0.12), in: Capsule())
                            .accessibilityIdentifier(boardDoingTagID(card.id))
                    }
                    Text(card["title"].string)
                        .font(isCompact ? .system(size: 13, weight: .semibold) : TypeScale.subheadline.weight(.semibold))
                        .foregroundStyle(isDoneColumn && strikeProgress > 0.5 ? Palette.textSecondary : Palette.textPrimary)
                        .strikethrough(isDoneColumn && strikeProgress > 0.5, color: Palette.textSecondary)
                        .lineLimit(isCompact ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .leading) {
                            if isDoneColumn && strikeProgress > 0 && strikeProgress < 1 {
                                GeometryReader { geo in
                                    Rectangle()
                                        .fill(Palette.textSecondary)
                                        .frame(width: geo.size.width * strikeProgress, height: 1.2)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                            }
                        }
                }
                HStack(spacing: isCompact ? 4 : 6) {
                    ForEach(card["sources"].array.prefix(3).map(\.string), id: \.self) { kind in
                        Image(systemName: sourceSymbol(kind)).font(.system(size: isCompact ? 11 : 12)).foregroundStyle(Palette.textTertiary)
                    }
                    fsmStatusBadge
                    if item["phase"].string == "waiting" && fsmStatus != "waiting_input" && fsmStatus != "waiting" {
                        Stamp(text: "等对方", tone: .info)
                    } else if item["phase"].string == "progress", !isDoing, fsmStatus != "executing" {
                        Stamp(text: "进展中", tone: .accent)
                    }
                    inlineActionButton
                    chatAttachButton
                    Spacer(minLength: isCompact ? 22 : 0)
                }
                if showProgress, !card["progress"].string.isEmpty {
                    Text(card["progress"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                if !errorNote.isEmpty {
                    Text(errorNote)
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.danger)
                        .lineLimit(2)
                }
            }
            .padding(isCompact ? 8 : Space.md)
            Spacer(minLength: 0)
        }
        .frame(minHeight: isCompact ? 54 : 64)
    }

    private func doneCheckBadge(settled: Bool) -> some View {
        let trim: CGFloat = settled ? 1 : ringTrim
        let scale: CGFloat = settled ? 1 : checkScale
        return ZStack {
            Circle()
                .trim(from: 0, to: trim)
                .stroke(Palette.success, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(-90))
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.success)
                .scaleEffect(scale)
                .opacity(scale > 0.01 ? 1 : 0)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private func startDoneSequenceIfNeeded() {
        guard newlyDone, !doneAnimated else { return }
        doneAnimated = true
        if reduce {
            ringTrim = 1
            checkScale = 1
            strikeProgress = 1
            withAnimation(.easeOut(duration: 0.2)) { compactDone = true }
            return
        }
        ringTrim = 0
        checkScale = 0
        strikeProgress = 0
        compactDone = false
        // 1) 圆环描边 0.22s
        withAnimation(.easeOut(duration: 0.22)) { ringTrim = 1 }
        // 2) 勾 bounce + 删除线 0.2s
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.spring(duration: 0.28, bounce: 0.45)) { checkScale = 1 }
            withAnimation(.easeOut(duration: 0.20)) { strikeProgress = 1 }
            // 3) 停 350ms → settle 收成 44pt 紧凑行
            try? await Task.sleep(for: .milliseconds(550))
            withAnimation(ComMotion.settle) { compactDone = true }
        }
    }

    private func sourceSymbol(_ kind: String) -> String {
        switch kind {
        case "mail": "envelope"
        case "event": "calendar"
        case "wechat": "message"
        case "project": "folder"
        default: "doc"
        }
    }
}

private struct BoardCapsulePicker: View {
    @Binding var group: BoardGroup
    let columns: [BoardColumn: [JSON]]
    var dragHover: BoardGroup?
    var fillProgress: CGFloat
    var dragging: Bool
    var body: some View {
        HStack(spacing: 4) {
            ForEach(BoardGroup.allCases) { col in
                let isHover = dragging && dragHover == col
                let count = boardCards(in: col, from: columns).count
                let doingN = col == .todo ? (columns[.doing]?.count ?? 0) : 0
                Button {
                    group = col
                    Haptics.selection()
                } label: {
                    HStack(spacing: 4) {
                        Text("\(col.title) \(count)")
                        if doingN > 0 {
                            Circle().fill(Palette.danger).frame(width: 6, height: 6)
                            Text("\(doingN)")
                                .font(TypeScale.caption.weight(.semibold))
                                .foregroundStyle(Palette.danger)
                        }
                    }
                    .font(TypeScale.caption.weight(group == col || isHover ? .semibold : .medium))
                    .foregroundStyle(group == col || isHover ? Palette.accentText : Palette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: dragging ? 44 : 34)
                    .background {
                        ZStack(alignment: .leading) {
                            Capsule().fill(group == col ? Palette.accent.opacity(0.22) : Palette.surface)
                            if isHover {
                                GeometryReader { geo in
                                    Rectangle()
                                        .fill(Palette.accent.opacity(0.32))
                                        .frame(width: geo.size.width * fillProgress)
                                }
                                .clipShape(.capsule)
                            }
                        }
                    }
                    .overlay(
                        Capsule()
                            .strokeBorder(isHover ? Palette.accentText.opacity(0.6) : Palette.separator, lineWidth: isHover ? 1 : 0.5)
                    )
                }
                .buttonStyle(.plain)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: BoardCapsuleFrameKey.self, value: [col: geo.frame(in: .named("board"))])
                    }
                }
                .accessibilityLabel(doingN > 0 ? "\(col.title) \(count) 项，正在做 \(doingN) 项" : "\(col.title) \(count) 项")
                .accessibilityIdentifier("board-capsule-" + col.rawValue)
            }
        }
        .padding(.horizontal, Layout.margin)
        .animation(ComMotion.reflow, value: dragging)
    }
}

private struct BoardDoneDropColumn: View {
    let cards: [JSON]
    @Bindable var drag: BoardDragSession
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var showArchiveSheet = false
    private var hovered: Bool { drag.active && (drag.hoverDoneStrip || drag.hoverGroup == .done) }
    var body: some View {
        VStack(spacing: Space.sm) {
            CountBadge(count: cards.count)
                .padding(.top, Space.md)
            Text("已完成")
                .font(TypeScale.caption.weight(.semibold))
                .foregroundStyle(hovered ? Palette.accentText : Palette.textSecondary)
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .padding(.top, Space.md)
            Spacer()
            Button {
                showArchiveSheet = true
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Palette.fill, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, Space.md)
            .accessibilityIdentifier("board-open-archive-sheet")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.accent.opacity(hovered ? 0.14 : 0.04))
        .animation(reduce ? nil : .smooth(duration: 0.18), value: hovered)
        .sheet(isPresented: $showArchiveSheet) {
            MatterArchiveSheet()
        }
        .accessibilityIdentifier("board-done-drop")
    }
}

@MainActor
final class WeakScrollView {
    weak var value: UIScrollView?
    init(_ value: UIScrollView?) { self.value = value }
}

@Observable @MainActor
final class BoardDragSession {
    var pressingCardID: String?
    var active = false
    var settling = false
    var ghostCard: JSON?
    var originColumn: BoardColumn = .suggest
    var originGroup: BoardGroup = .suggest
    var originIndex: Int = 0
    var originFrame: CGRect = .zero
    var grabOffset: CGSize = .zero
    var cardSize: CGSize = CGSize(width: 280, height: 68)
    var floatingPosition: CGPoint = .zero
    var floatingOpacity: Double = 1
    var hoverGroup: BoardGroup?
    var hoverMoveColumn: BoardColumn?
    var hoverCapsule: BoardGroup?
    var hoverDoneStrip = false
    var capsuleFillProgress: CGFloat = 0
    var insertIndex: Int = 0
    var liftScale: CGFloat = 1.0
    var tilt: Double = 0
    var shadowRadius: CGFloat = 12
    var shadowY: CGFloat = 3
    var shadowOpacity: Double = 0.05

    @ObservationIgnored var scrollViews: [BoardGroup: WeakScrollView] = [:]
    @ObservationIgnored var horizontalSwipeActive = false
    @ObservationIgnored private var pressTask: Task<Void, Never>?
    @ObservationIgnored private var capsuleDwellTask: Task<Void, Never>?
    @ObservationIgnored private var edgeFlipTask: Task<Void, Never>?
    @ObservationIgnored private var edgeFlipDirection: Int = 0
    @ObservationIgnored private var autoScrollTask: Task<Void, Never>?
    @ObservationIgnored private var autoScrollSpeed: CGFloat = 0
    @ObservationIgnored private var autoScrollGroup: BoardGroup?
    @ObservationIgnored private var lastPoint: CGPoint = .zero
    @ObservationIgnored private var lastMoveTime: TimeInterval = 0

    func schedulePressPreview(cardID: String, reduce: Bool) {
        pressTask?.cancel()
        pressTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, !active, !horizontalSwipeActive else { return }
            Haptics.prepareDrag()
            withAnimation(reduce ? .easeOut(duration: 0.12) : ComMotion.press) {
                pressingCardID = cardID
            }
        }
    }

    func clearPressPreview(reduce: Bool) {
        pressTask?.cancel()
        pressTask = nil
        if pressingCardID != nil {
            withAnimation(reduce ? .easeOut(duration: 0.12) : ComMotion.press) {
                pressingCardID = nil
            }
        }
    }

    func begin(card: JSON, group: BoardGroup, column: BoardColumn, index: Int, frame: CGRect, at point: CGPoint, reduce: Bool) {
        pressTask?.cancel()
        pressTask = nil
        pressingCardID = nil
        ghostCard = card
        originColumn = column
        originGroup = group
        originIndex = index
        originFrame = frame
        cardSize = frame.size.width > 0 ? frame.size : CGSize(width: 280, height: 68)
        grabOffset = CGSize(width: point.x - frame.minX, height: point.y - frame.minY)
        floatingPosition = CGPoint(x: frame.minX, y: frame.minY - 4)
        floatingOpacity = 1
        hoverGroup = group
        hoverMoveColumn = column
        hoverCapsule = nil
        hoverDoneStrip = false
        capsuleFillProgress = 0
        insertIndex = index
        active = true
        settling = false
        lastPoint = point
        lastMoveTime = CACurrentMediaTime()
        withAnimation(reduce ? .easeOut(duration: 0.15) : ComMotion.press) {
            liftScale = reduce ? 1.0 : 1.04
            shadowRadius = 28
            shadowY = 16
            shadowOpacity = 0.18
        }
        Haptics.impact(.medium, intensity: 0.8)
    }

    func move(
        to point: CGPoint,
        velocityX: CGFloat?,
        mode: BoardLayoutMode,
        containerWidth: CGFloat,
        currentSingleGroup: BoardGroup,
        groupFrames: [BoardGroup: CGRect],
        cardFrames: [String: CGRect],
        capsuleFrames: [BoardGroup: CGRect],
        doneDropFrame: CGRect,
        boardCards: [BoardColumn: [JSON]],
        reduce: Bool,
        onSelectGroup: @escaping (BoardGroup) -> Void
    ) {
        guard active, !settling, let ghost = ghostCard else { return }
        floatingPosition = CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height - 4)

        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240.0, now - lastMoveTime)
        let vx = velocityX ?? ((point.x - lastPoint.x) / CGFloat(dt))
        lastPoint = point
        lastMoveTime = now
        let targetTilt = reduce ? 0 : max(-4, min(4, Double(vx / 1200) * 4))
        withAnimation(reduce ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            tilt = targetTilt
        }

        // 单列模式：顶部胶囊命中与 0.4s 停顿切列（底色左→右填满）
        if mode == .singleCapsule {
            if let (capGroup, _) = capsuleFrames.first(where: { $0.value.insetBy(dx: -2, dy: -6).contains(point) }) {
                if hoverCapsule != capGroup {
                    hoverCapsule = capGroup
                    updateHoverGroup(capGroup, boardCards: boardCards, reduce: reduce)
                    insertIndex = 0
                    if capGroup != currentSingleGroup {
                        startCapsuleDwell(target: capGroup, reduce: reduce, onSelect: onSelectGroup)
                    } else {
                        capsuleDwellTask?.cancel()
                        capsuleFillProgress = 0
                    }
                }
                updateAutoScroll(speed: 0, group: nil)
                return
            } else if hoverCapsule != nil {
                cancelCapsuleDwell()
            }
        }

        // 两列模式：右侧 56pt 已完成投放栏
        if mode == .twoColumnScroll {
            if doneDropFrame.width > 0 && doneDropFrame.contains(point) {
                hoverDoneStrip = true
                updateAutoScroll(speed: 0, group: nil)
                updateHoverGroup(.done, boardCards: boardCards, reduce: reduce)
                insertIndex = 0
                return
            } else {
                hoverDoneStrip = false
            }
        }

        let hitGroup: BoardGroup? = {
            if mode == .singleCapsule { return currentSingleGroup }
            if let exact = groupFrames.first(where: { $0.value.insetBy(dx: -3, dy: -24).contains(point) })?.key {
                return exact
            }
            return groupFrames.min(by: { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) })?.key
        }()

        guard let grp = hitGroup else {
            updateAutoScroll(speed: 0, group: nil)
            return
        }

        let headerH: CGFloat = (containerWidth > 0 && containerWidth < 560) ? 34 : 44
        let rowSpacing: CGFloat = (containerWidth > 0 && containerWidth < 560) ? 6 : Space.sm
        let groupChanged = (hoverGroup != grp)
        updateHoverGroup(grp, boardCards: boardCards, reduce: reduce)
        let colCards = mergedCards(for: grp, columns: boardCards)
        let otherIDs = colCards.map(\.id).filter { $0 != ghost.id }
        let colTop = (groupFrames[grp]?.minY ?? 0) + headerH + rowSpacing
        let measuredMinY = otherIDs.compactMap { cardFrames[$0]?.minY }.min() ?? colTop
        var cursorY = min(colTop, measuredMinY)
        var centers: [CGFloat] = []
        for id in otherIDs {
            let h = cardFrames[id]?.height ?? cardSize.height
            centers.append(cursorY + h / 2)
            cursorY += h + rowSpacing
        }
        let probeY = floatingPosition.y + cardSize.height / 2
        let baseIdx = groupChanged ? (grp == originGroup ? originIndex : otherIDs.count) : insertIndex
        var candidate = 0
        for (i, midY) in centers.enumerated() {
            let threshold = groupChanged ? midY : (i < baseIdx ? (midY - 8) : (midY + 8))
            if probeY > threshold {
                candidate = i + 1
            } else {
                break
            }
        }
        candidate = min(max(0, candidate), otherIDs.count)
        if candidate != insertIndex || groupChanged {
            withAnimation(ComMotion.reduced(reduce, ComMotion.reflow)) {
                insertIndex = candidate
            }
            if !groupChanged {
                Haptics.selection()
            }
        }

        if let colFrame = groupFrames[grp] {
            let topEdge = colFrame.minY + headerH
            let bottomEdge = colFrame.maxY - 72
            if point.y >= topEdge && point.y < topEdge + 64 {
                let t = min(1, max(0, (topEdge + 64 - point.y) / 64))
                updateAutoScroll(speed: -900 * t * t, group: grp)
            } else if point.y > bottomEdge - 64 && point.y <= colFrame.maxY {
                let t = min(1, max(0, (point.y - (bottomEdge - 64)) / 64))
                updateAutoScroll(speed: 900 * t * t, group: grp)
            } else {
                updateAutoScroll(speed: 0, group: nil)
            }
        } else {
            updateAutoScroll(speed: 0, group: nil)
        }
    }

    private func mergedCards(for group: BoardGroup, columns: [BoardColumn: [JSON]]) -> [JSON] {
        boardCards(in: group, from: columns)
    }

    func end(
        placeholderFrames: [BoardGroup: CGRect],
        capsuleFrames: [BoardGroup: CGRect],
        groupFrames: [BoardGroup: CGRect],
        doneDropFrame: CGRect,
        reduce: Bool,
        onMove: @escaping (JSON, BoardColumn, Int?) -> Void,
        onFinish: @escaping () -> Void
    ) {
        stopTimers()
        guard let card = ghostCard else {
            cancelImmediate()
            onFinish()
            return
        }

        // 两列右侧 56pt 已完成栏投放：浮层缩 0.35 淡出飞入
        if hoverDoneStrip && originColumn != .done {
            settling = true
            Haptics.sent()
            onMove(card, .done, 0)
            let dest = CGPoint(
                x: doneDropFrame.midX - cardSize.width / 2,
                y: min(doneDropFrame.midY, doneDropFrame.minY + 72) - cardSize.height / 2
            )
            withAnimation(ComMotion.reduced(reduce, ComMotion.flight)) {
                floatingPosition = dest
                liftScale = 0.35
                floatingOpacity = 0
                tilt = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduce ? 180 : 360))
                cancelImmediate()
                onFinish()
            }
            return
        }

        // 单列顶部胶囊上直接松手：放该组顶部
        if let cap = hoverCapsule, cap != originGroup, let targetCol = dropColumn(for: cap, origin: originColumn) {
            settling = true
            Haptics.sent()
            onMove(card, targetCol, 0)
            let dest = capsuleFrames[cap]?.origin ?? originFrame.origin
            withAnimation(ComMotion.reduced(reduce, ComMotion.flight)) {
                floatingPosition = dest
                liftScale = 0.6
                floatingOpacity = 0
                tilt = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduce ? 180 : 340))
                cancelImmediate()
                onFinish()
            }
            return
        }

        if let targetCol = hoverMoveColumn,
           let hover = hoverGroup,
           (hover != originGroup && targetCol != originColumn) || (hover == originGroup && insertIndex != originIndex) {
            settling = true
            Haptics.sent()
            let targetIdx = insertIndex
            let destRect = placeholderFrames[hover] ?? groupFrames[hover] ?? originFrame
            onMove(card, targetCol, targetIdx)
            withAnimation(ComMotion.reduced(reduce, ComMotion.flight)) {
                floatingPosition = destRect.origin
                liftScale = 1.0
                tilt = 0
                shadowRadius = 12
                shadowY = 3
                shadowOpacity = 0.05
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduce ? 180 : 340))
                cancelImmediate()
                onFinish()
            }
            return
        }

        cancelAnimated(reduce: reduce, onFinish: onFinish)
    }

    private func dropColumn(for group: BoardGroup, origin: BoardColumn) -> BoardColumn? {
        switch group {
        case .suggest: return .suggest
        case .todo: return .todo
        case .done: return .done
        }
    }

    func cancelAnimated(reduce: Bool, onFinish: @escaping () -> Void) {
        stopTimers()
        guard active, ghostCard != nil else {
            cancelImmediate()
            onFinish()
            return
        }
        settling = true
        let anim: Animation = reduce ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.82)
        withAnimation(anim) {
            floatingPosition = originFrame.origin
            liftScale = 1.0
            tilt = 0
            shadowRadius = 12
            shadowY = 3
            shadowOpacity = 0.05
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduce ? 180 : 380))
            cancelImmediate()
            onFinish()
        }
    }

    func cancelImmediate() {
        stopTimers()
        pressingCardID = nil
        horizontalSwipeActive = false
        active = false
        settling = false
        ghostCard = nil
        hoverGroup = nil
        hoverMoveColumn = nil
        hoverCapsule = nil
        hoverDoneStrip = false
        capsuleFillProgress = 0
        floatingPosition = .zero
        floatingOpacity = 1
        liftScale = 1.0
        tilt = 0
        shadowRadius = 12
        shadowY = 3
        shadowOpacity = 0.05
    }

    private func updateHoverGroup(_ group: BoardGroup, boardCards: [BoardColumn: [JSON]], reduce: Bool) {
        guard hoverGroup != group else { return }
        hoverGroup = group
        let target = resolveMoveColumn(to: group, origin: originColumn, boardCards: boardCards)
        hoverMoveColumn = target
        if group != originGroup, target != nil {
            Haptics.impact(.light, intensity: 0.6)
        }
    }

    private func resolveMoveColumn(to group: BoardGroup, origin: BoardColumn, boardCards: [BoardColumn: [JSON]]) -> BoardColumn? {
        if group == originGroup {
            return origin
        }
        switch group {
        case .suggest: return .suggest
        case .todo:
            if origin == .suggest || origin == .done { return .todo }
            if origin == .doing || origin == .todo { return origin }
            return .todo
        case .done:
            return .done
        }
    }

    private func startCapsuleDwell(target: BoardGroup, reduce: Bool, onSelect: @escaping (BoardGroup) -> Void) {
        capsuleDwellTask?.cancel()
        capsuleFillProgress = 0
        withAnimation(.linear(duration: 0.4)) {
            capsuleFillProgress = 1
        }
        capsuleDwellTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, active, hoverCapsule == target else { return }
            capsuleFillProgress = 0
            onSelect(target)
            Haptics.selection()
        }
    }

    private func cancelCapsuleDwell() {
        capsuleDwellTask?.cancel()
        capsuleDwellTask = nil
        hoverCapsule = nil
        capsuleFillProgress = 0
    }

    private func startEdgeFlip(direction: Int, onFlip: @escaping (Int) -> Void) {
        guard edgeFlipDirection != direction else { return }
        edgeFlipTask?.cancel()
        edgeFlipDirection = direction
        edgeFlipTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, active, edgeFlipDirection == direction else { return }
            onFlip(direction)
            while !Task.isCancelled, active, edgeFlipDirection == direction {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, active, edgeFlipDirection == direction else { break }
                onFlip(direction)
            }
        }
    }

    private func cancelEdgeFlip() {
        edgeFlipTask?.cancel()
        edgeFlipTask = nil
        edgeFlipDirection = 0
    }

    private func updateAutoScroll(speed: CGFloat, group: BoardGroup?) {
        autoScrollSpeed = speed
        autoScrollGroup = group
        if abs(speed) < 1 || group == nil {
            autoScrollTask?.cancel()
            autoScrollTask = nil
            return
        }
        guard autoScrollTask == nil else { return }
        autoScrollTask = Task { @MainActor in
            var last = CACurrentMediaTime()
            while !Task.isCancelled, active, abs(autoScrollSpeed) >= 1, let col = autoScrollGroup {
                try? await Task.sleep(for: .milliseconds(16))
                let now = CACurrentMediaTime()
                let dt = CGFloat(min(0.05, max(0.004, now - last)))
                last = now
                guard let sv = scrollViews[col]?.value else { continue }
                let maxOffsetY = max(0, sv.contentSize.height - sv.bounds.height + sv.contentInset.bottom)
                let nextY = min(maxOffsetY, max(-sv.contentInset.top, sv.contentOffset.y + autoScrollSpeed * dt))
                if abs(nextY - sv.contentOffset.y) > 0.1 {
                    sv.contentOffset.y = nextY
                }
            }
            autoScrollTask = nil
        }
    }

    private func stopTimers() {
        pressTask?.cancel()
        pressTask = nil
        capsuleDwellTask?.cancel()
        capsuleDwellTask = nil
        edgeFlipTask?.cancel()
        edgeFlipTask = nil
        edgeFlipDirection = 0
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollSpeed = 0
        autoScrollGroup = nil
    }
}

private final class BoardLongPressRecognizer: UILongPressGestureRecognizer {
    var onTouchState: ((Bool) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouchState?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        onTouchState?(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        onTouchState?(false)
    }

    override func reset() {
        super.reset()
        onTouchState?(false)
    }
}

private struct BoardCardLongPressGesture: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let card: JSON
    let group: BoardGroup
    let column: BoardColumn
    let index: Int
    let reduce: Bool
    let session: BoardDragSession
    let onTouchDown: (Bool) -> Void
    let onBegin: (CGPoint) -> Void
    let onMove: (CGPoint, CGFloat?) -> Void
    let onEnd: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIGestureRecognizer(context: Context) -> BoardLongPressRecognizer {
        let press = BoardLongPressRecognizer()
        press.minimumPressDuration = 0.16
        press.allowableMovement = 14
        press.cancelsTouchesInView = true
        press.delegate = context.coordinator
        press.onTouchState = { down in
            context.coordinator.parent.onTouchDown(down)
        }
        return press
    }

    func updateUIGestureRecognizer(_ recognizer: BoardLongPressRecognizer, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isDrivingDrag {
            recognizer.isEnabled = enabled
        }
        recognizer.onTouchState = { down in
            context.coordinator.parent.onTouchDown(down)
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: BoardLongPressRecognizer, context: Context) {
        let point = context.converter.location(in: .named("board"))
        let vx = context.converter.velocity(in: .named("board"))?.x
        switch recognizer.state {
        case .began:
            guard !session.active else { return }
            context.coordinator.isDrivingDrag = true
            onBegin(point)
        case .changed:
            guard context.coordinator.isDrivingDrag else { return }
            onMove(point, vx)
        case .ended:
            guard context.coordinator.isDrivingDrag else { return }
            context.coordinator.isDrivingDrag = false
            onMove(point, vx)
            onEnd(true)
        case .cancelled, .failed:
            guard context.coordinator.isDrivingDrag else { return }
            context.coordinator.isDrivingDrag = false
            onEnd(false)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: BoardCardLongPressGesture
        var isDrivingDrag = false
        init(parent: BoardCardLongPressGesture) { self.parent = parent }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            parent.enabled && !parent.session.active && !parent.session.horizontalSwipeActive
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer.state == .possible
        }
    }
}

private struct BoardCardSwipePanModifier: ViewModifier {
    let enabled: Bool
    let session: BoardDragSession
    let onBegin: (CGPoint) -> Void
    let onMove: (CGPoint, CGFloat?) -> Void
    let onEnd: (Bool) -> Void

    // 始终挂着、只切 isEnabled：if/else 会换视图身份，起拖那一刻把识别器和卡片 @State 一起重建。
    func body(content: Content) -> some View {
        content.gesture(
            BoardCardPanGesture(
                enabled: enabled,
                session: session,
                onBegin: onBegin,
                onMove: onMove,
                onEnd: onEnd
            )
        )
    }
}

private struct BoardCardPanGesture: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let session: BoardDragSession
    let onBegin: (CGPoint) -> Void
    let onMove: (CGPoint, CGFloat?) -> Void
    let onEnd: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(parent: self, converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = true  // 横/斜向直接拖拽认出来后立即锁住列表，浮起卡片跨列流转
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isDrivingDrag {
            recognizer.isEnabled = enabled
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let point = context.converter.location(in: .named("board"))
        let vx = context.converter.velocity(in: .named("board"))?.x
        let t = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began:
            guard !session.active else { return }
            context.coordinator.isDrivingDrag = true
            let startPoint = CGPoint(x: point.x - t.x, y: point.y - t.y)
            onBegin(startPoint)
            onMove(point, vx)
        case .changed:
            if !context.coordinator.isDrivingDrag, !session.active {
                context.coordinator.isDrivingDrag = true
                let startPoint = CGPoint(x: point.x - t.x, y: point.y - t.y)
                onBegin(startPoint)
            }
            guard context.coordinator.isDrivingDrag else { return }
            onMove(point, vx)
        case .ended:
            guard context.coordinator.isDrivingDrag else { return }
            context.coordinator.isDrivingDrag = false
            onMove(point, vx)
            onEnd(true)
        case .cancelled, .failed:
            guard context.coordinator.isDrivingDrag else { return }
            context.coordinator.isDrivingDrag = false
            onEnd(false)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: BoardCardPanGesture
        let converter: CoordinateSpaceConverter
        var isDrivingDrag = false
        init(parent: BoardCardPanGesture, converter: CoordinateSpaceConverter) {
            self.parent = parent
            self.converter = converter
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard parent.enabled, !parent.session.active, !parent.session.horizontalSwipeActive else { return false }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            // 横向或斜向直接拖拽卡片即刻起浮层跨列流转，保留纯纵向给本列 ScrollView 滚动。
            let t = pan.translation(in: pan.view)
            if hypot(t.x, t.y) >= 5 { return abs(t.x) > abs(t.y) * 0.75 }
            let v = pan.velocity(in: pan.view)
            return hypot(v.x, v.y) >= 40 && abs(v.x) > abs(v.y) * 0.85
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer.state == .possible
        }
    }
}

private struct BoardScrollViewBridge: UIViewRepresentable {
    let group: BoardGroup
    let session: BoardDragSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var current: UIView? = uiView
            while let parent = current?.superview {
                if let sv = parent as? UIScrollView {
                    session.scrollViews[group] = WeakScrollView(sv)
                    break
                }
                current = parent
            }
        }
    }
}

private struct BoardGroupFrameKey: PreferenceKey {
    static let defaultValue: [BoardGroup: CGRect] = [:]
    static func reduce(value: inout [BoardGroup: CGRect], nextValue: () -> [BoardGroup: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct BoardCardFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct BoardCapsuleFrameKey: PreferenceKey {
    static let defaultValue: [BoardGroup: CGRect] = [:]
    static func reduce(value: inout [BoardGroup: CGRect], nextValue: () -> [BoardGroup: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct BoardPlaceholderFrameKey: PreferenceKey {
    static let defaultValue: [BoardGroup: CGRect] = [:]
    static func reduce(value: inout [BoardGroup: CGRect], nextValue: () -> [BoardGroup: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct BoardDoneDropFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

private func boardCardID(_ id: String) -> String { "board-card-" + id.replacingOccurrences(of: ":", with: "__") }

struct BoardCardDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let card: JSON
    @State private var busy = false
    @State private var askReason = false
    @State private var handoffNote = ""
    @State private var detent: PresentationDetent = .large

    private var item: JSON {
        if card["kind"].string == "next", !card["next"].isNull { return card["next"] }
        return card
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                NextCardDetailBody(card: card, item: item, handoffNote: $handoffNote, busy: $busy, askReason: $askReason)
                    .padding(Layout.margin)
            }
            .navigationTitle(card["title"].string)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("建议待办") { move(to: .suggest) }
                            .accessibilityIdentifier("board-toolbar-move-suggest")
                        Button("待办") { move(to: .todo) }
                            .accessibilityIdentifier("board-toolbar-move-todo")
                        Button("正在做") { move(to: .doing) }
                            .accessibilityIdentifier("board-toolbar-move-doing")
                        Button("已完成") { move(to: .done) }
                            .accessibilityIdentifier("board-toolbar-move-done")
                    } label: {
                        Image(systemName: "arrow.right.arrow.left")
                    }
                    .accessibilityLabel("移到…")
                    .accessibilityIdentifier("board-toolbar-move-menu")
                }
            }
        }
        .presentationDetents([.large, .medium], selection: $detent)
    }

    private func move(to col: BoardColumn) {
        Task {
            _ = await model.boardMove(card: card, to: col)
            dismiss()
        }
    }
}

/// 原 NextCard 详情区：「移到…」放在顶部可见区，随后是 why、动作草稿、依据袋（参数不动）、主动作。
struct NextCardDetailBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var card: JSON?
    let item: JSON
    @Binding var handoffNote: String
    @Binding var busy: Bool
    @Binding var askReason: Bool
    @State private var activeMicroPayload: MicroSheetPayload? = nil
    private var hasAction: Bool { !item["action"]["type"].string.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if card != nil {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("移到…").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    HStack(spacing: Space.sm) {
                        moveChip("建议", .suggest, id: "board-move-suggest")
                        moveChip("待办", .todo, id: "board-move-todo")
                        moveChip("正在做", .doing, id: "board-move-doing")
                        moveChip("已完成", .done, id: "board-move-done")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("board-detail-move-row")
            }
            if !item["why"].string.isEmpty { Text(item["why"].string).font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary) }
            if hasAction { NextActionDraft(action: item["action"]) }
            let evidence = item["evidence"].array
            if !evidence.isEmpty { EvidencePocket(evidence: evidence, itemID: item.id, itemTitle: item["title"].string) }
            if !handoffNote.isEmpty {
                let failed = handoffNote.contains("没成") || handoffNote.contains("失败") || handoffNote.contains("卡还在")
                if failed {
                    InlineNotice(text: handoffNote, tone: .danger)
                } else {
                    Label(handoffNote, systemImage: "checkmark.circle")
                        .font(TypeScale.footnote.weight(.medium))
                        .foregroundStyle(Palette.accentText)
                }
            }
            HStack(spacing: Space.sm) {
                if hasAction {
                    Button(nextActionTitle(item["action"])) { runAction() }
                        .buttonStyle(.primaryCompact)
                        .disabled(busy)
                        .accessibilityIdentifier("next-action-" + item.id)
                    Button("交给我办") { delegate() }
                        .buttonStyle(.secondaryCompact)
                        .disabled(busy)
                        .accessibilityIdentifier("next-discuss-" + item.id)
                } else {
                    Button("交给我办") { delegate() }
                        .buttonStyle(.primaryCompact)
                        .disabled(busy)
                        .accessibilityIdentifier("next-discuss-" + item.id)
                }
                Button {
                    triggerAttachBoardCard(card ?? item, fallbackItem: item, model: model)
                    dismiss()
                } label: {
                    Label("聊这件", systemImage: "bubble.left")
                }
                .buttonStyle(.secondaryCompact)
                .disabled(busy)
                .accessibilityIdentifier("next-detail-chat-" + item.id)
            }
        }
        .sheet(item: $activeMicroPayload) { payload in
            MicroSheetView(payload: payload) { _ in
                Task {
                    _ = await model.nextAction(item, "done")
                    await model.refreshBoard()
                    dismiss()
                }
            }
        }
    }

    private func moveChip(_ title: String, _ col: BoardColumn, id: String) -> some View {
        Button(title) { move(col) }
            .buttonStyle(.secondaryCompact)
            .accessibilityIdentifier(id)
    }

    private func move(_ col: BoardColumn) {
        guard let card else { return }
        Task {
            _ = await model.boardMove(card: card, to: col)
            dismiss()
        }
    }

    private func runAction() {
        guard !busy else { return }
        let actType = item["action"]["type"].string
        if actType == "bookkeep" || actType == "calendar" || actType == "reply_mail" {
            let mtrId = item["matter_id"].string.isEmpty ? item.id : item["matter_id"].string
            activeMicroPayload = MicroSheetPayload(
                matterId: mtrId,
                action: item["action"],
                title: item["title"].string,
                why: item["why"].string
            )
            return
        }
        busy = true
        Task {
            if await model.runNextAction(item, open: { openURL($0) }) {
                dismiss()
            } else {
                handoffNote = "这一步没成，卡还在——可以再试"
            }
            busy = false
        }
    }

    private func delegate() {
        #if DEBUG
        if model.isUITesting {
            Task {
                _ = await model.nextAction(item, "discuss")
                dismiss()
            }
            return
        }
        #endif
        guard !busy else { return }
        busy = true
        Task {
            if let id = await model.delegateNext(item) {
                if id.isEmpty {
                    handoffNote = "已交由后台处理"
                } else {
                    withAnimation(ComMotion.reduced(reduce, ComMotion.pop)) { model.presentedCase = id }
                    handoffNote = "已接进航程——打开就能看步骤"
                }
                dismiss()
            } else {
                handoffNote = "交给我办没成，卡还在"
            }
            busy = false
        }
    }
}

@MainActor
private func makeBoardAttachedContext(card: JSON, fallbackItem: JSON = .null) -> AttachedContextItem {
    let item = card["item"].isNull ? fallbackItem : card["item"]
    let rawID = !card["matter_id"].string.isEmpty
        ? card["matter_id"].string
        : (!item["matter_id"].string.isEmpty
            ? item["matter_id"].string
            : (!card.id.isEmpty ? card.id : item.id))
    let rawTitle = !card["title"].string.isEmpty ? card["title"].string : item["title"].string
    let rawSummary = !item["why"].string.isEmpty
        ? item["why"].string
        : (!card["progress"].string.isEmpty ? card["progress"].string : item["summary"].string)
    let cleanSummary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = cleanSummary.count > 140 ? String(cleanSummary.prefix(139)) + "…" : cleanSummary
    return AttachedContextItem(id: rawID, title: rawTitle, summary: summary, kind: "next")
}

@MainActor
private func triggerAttachBoardCard(_ card: JSON, fallbackItem: JSON = .null, model: AppModel) {
    let ctx = makeBoardAttachedContext(card: card, fallbackItem: fallbackItem)
    guard !ctx.title.isEmpty || !ctx.id.isEmpty else { return }
    Haptics.selection()
    if model.splitView && model.boardFocus {
        model.boardFocus = false
    }
    model.attachToChat(ctx, switchIfCompact: true)
}
