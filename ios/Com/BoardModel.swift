import SwiftUI
import ComCore

/// 看板 UI 三大分组（「正在做」合并在待办组内展示）。
enum BoardGroup: String, CaseIterable, Identifiable {
    case suggest, todo, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .suggest: "建议待办"
        case .todo: "待办"
        case .done: "已完成"
        }
    }

    static func fromPersisted(_ raw: String) -> BoardGroup {
        if raw == BoardColumn.doing.rawValue { return .todo }
        return BoardGroup(rawValue: raw) ?? .suggest
    }

    func persistedRawValue() -> String { rawValue }
}

/// PRD §3.1 定义的 11 项全分支有限状态机 (FSM) 状态
enum MatterStatus: String, CaseIterable, Identifiable, Sendable {
    case suggested = "suggested"
    case suggest = "suggest"
    case todo = "todo"
    case doing = "doing"
    case executing = "executing"
    case waitingInput = "waiting_input"
    case errorRetrying = "error_retrying"
    case errorBlocked = "error_blocked"
    case snoozed = "snoozed"
    case dismissed = "dismissed"
    case cancelled = "cancelled"
    case done = "done"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suggested, .suggest: "建议待办"
        case .todo: "待办"
        case .doing: "正在做"
        case .executing: "执行中"
        case .waitingInput: "等待输入"
        case .errorRetrying: "重试中"
        case .errorBlocked: "执行受阻"
        case .snoozed: "已稍后"
        case .dismissed: "已划掉"
        case .cancelled: "已取消"
        case .done: "已完成"
        }
    }

    var boardColumn: BoardColumn {
        switch self {
        case .suggested, .suggest, .dismissed, .snoozed: .suggest
        case .todo: .todo
        case .doing, .executing, .waitingInput, .errorRetrying, .errorBlocked: .doing
        case .done, .cancelled: .done
        }
    }
}

enum BoardColumn: String, CaseIterable, Identifiable {
    case suggest, todo, doing, done
    var id: String { rawValue }
    var boardGroup: BoardGroup {
        switch self {
        case .suggest: .suggest
        case .todo, .doing: .todo
        case .done: .done
        }
    }
    var title: String {
        switch self {
        case .suggest: "建议待办"
        case .todo: "待办"
        case .doing: "正在做"
        case .done: "已完成"
        }
    }
    var moveTarget: String? {
        switch self {
        case .suggest: "suggest"
        case .todo: "todo"
        case .doing: "doing"
        case .done: "done"
        }
    }
}

extension AppModel {
    static let boardPath = "/personal/board"

    var boardData: JSON { datasets[Self.boardPath] ?? .null }
    var boardCards: [BoardColumn: [JSON]] {
        let cols = boardData["columns"]
        return Dictionary(uniqueKeysWithValues: BoardColumn.allCases.map { col in
            (col, cols[col.rawValue].array)
        })
    }

    var boardColumn: BoardGroup {
        get {
            BoardGroup.fromPersisted(boardColumnRaw)
        }
        set {
            boardColumnRaw = newValue.persistedRawValue()
            UserDefaults.standard.set(boardColumnRaw, forKey: "board.column")
        }
    }

    func boardColumn(for card: JSON) -> BoardColumn {
        BoardColumn(rawValue: card["column"].string) ?? .suggest
    }

    func boardAnchor(for column: BoardColumn) -> String? {
        let key = "board.anchor." + column.rawValue
        let value = UserDefaults.standard.string(forKey: key) ?? ""
        return value.isEmpty ? nil : value
    }

    func setBoardAnchor(_ id: String?, column: BoardColumn) {
        let key = "board.anchor." + column.rawValue
        if let id, !id.isEmpty { UserDefaults.standard.set(id, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func refreshBoard() async {
        _ = await load(Self.boardPath)
    }

    func flushDeferredBoardDatasets() {
        guard !deferredBoardDatasets.isEmpty else { return }
        let queued = deferredBoardDatasets
        deferredBoardDatasets.removeAll()
        for (path, data) in queued {
            if path == Self.boardPath && !boardInFlightIDs.isEmpty { continue }
            datasets[path] = data
            if AppModel.flowPaths.contains(path) { recomputeFlow() }
        }
    }

    @discardableResult
    func boardMove(card: JSON, to target: BoardColumn, insertIndex: Int? = nil, reason: String? = nil) async -> Bool {
        let id = card.id
        let fromCol = BoardColumn(rawValue: card["column"].string) ?? .suggest
        if fromCol == target {
            if let insertIndex {
                applyBoardMoveLocally(cardID: id, from: fromCol, to: target, insertIndex: insertIndex, replacement: nil)
            }
            return true
        }
        guard let apiTarget = target.moveTarget else { return false }
        guard !boardInFlightIDs.contains(id) else { return false }

        let snapshot = boardData
        boardMoveNotes.removeValue(forKey: id)
        if target == .done {
            markBoardRecentlyDone(id)
        }
        applyBoardMoveLocally(cardID: id, from: fromCol, to: target, insertIndex: insertIndex, replacement: nil)
        boardInFlightIDs.insert(id)
        let pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled, boardInFlightIDs.contains(id) {
                boardPendingIDs.insert(id)
            }
        }

        #if DEBUG
        if isUITesting {
            pending.cancel()
            boardInFlightIDs.remove(id)
            boardPendingIDs.remove(id)
            if card["kind"].string == "next", target == .todo || target == .doing {
                var replaced = card
                let nextID = card["next"].id.isEmpty ? String(card.id.dropFirst("next:".count)) : card["next"].id
                replaced["id"] = .string("todo:preview-" + nextID)
                replaced["kind"] = .string("todo")
                replaced["column"] = .string(target.rawValue)
                applyBoardMoveLocally(cardID: id, from: fromCol, to: target, insertIndex: insertIndex, replacement: replaced)
            } else if card["kind"].string == "todo", target == .suggest {
                var replaced = card
                let baseID = card.id.hasPrefix("todo:preview-") ? String(card.id.dropFirst("todo:preview-".count)) : (card.id.hasPrefix("todo:") ? String(card.id.dropFirst("todo:".count)) : card.id)
                replaced["id"] = .string("next:" + baseID)
                replaced["kind"] = .string("next")
                replaced["column"] = .string(target.rawValue)
                applyBoardMoveLocally(cardID: id, from: fromCol, to: target, insertIndex: insertIndex, replacement: replaced)
            }
            boardColumn = target.boardGroup
            Haptics.success()
            return true
        }
        #endif

        do {
            func buildFields(using sourceCard: JSON, forceLatest: Bool) -> [String: JSON] {
                let mId = sourceCard["matter_id"].string.isEmpty ? sourceCard.id : sourceCard["matter_id"].string
                let mRev = max(1, sourceCard["matter_rev"].int)
                let revJSON: JSON = sourceCard["rev"].isNull ? .number(Double(mRev)) : sourceCard["rev"]
                var f: [String: JSON] = [
                    "matter_id": .string(mId),
                    "from_status": .string(fromCol.rawValue),
                    "to_status": .string(apiTarget),
                    "rev": revJSON,
                    "matter_rev": .number(Double(mRev)),
                    "card": .string(sourceCard.id.isEmpty ? id : sourceCard.id),
                    "to": .string(apiTarget),
                    "non_destructive": .bool(true),
                ]
                if forceLatest {
                    f["force_latest"] = .bool(true)
                }
                if let reason { f["reason"] = .string(reason) }
                return f
            }

            let result: JSON
            do {
                result = try await mutate("/personal/matter/move", fields: buildFields(using: card, forceLatest: true), silentBanner: true)
            } catch let conflictErr as APIError where conflictErr.status == 409 {
                // 若远端刚刚发生改动，自动拉取最新快照并以最新 rev 重试一次，无需打断用户操作
                _ = await load(Self.boardPath)
                let mId = card["matter_id"].string
                let refreshedCard = boardCards.values.flatMap { $0 }.first(where: {
                    $0.id == id || (!mId.isEmpty && $0["matter_id"].string == mId)
                }) ?? card
                result = try await mutate("/personal/matter/move", fields: buildFields(using: refreshedCard, forceLatest: true), silentBanner: true)
            }
            pending.cancel()
            boardInFlightIDs.remove(id)
            boardPendingIDs.remove(id)
            let hasBoardCard = !result["card"].isNull && !result["card"]["column"].string.isEmpty
            let updated = hasBoardCard ? result["card"] : (result["matter"].isNull ? result["card"] : result["matter"])
            if !updated.isNull {
                if target == .done, updated.id != id, boardRecentlyDoneIDs.contains(id) {
                    markBoardRecentlyDone(updated.id)
                }
                applyBoardMoveLocally(cardID: id, from: fromCol, to: target, insertIndex: insertIndex, replacement: updated)
            }
            let version = result["version"].string.isEmpty ? result["new_version"].string : result["version"].string
            if !version.isEmpty {
                var data = boardData
                data["version"] = .string(version)
                datasets[Self.boardPath] = data
            }
            Haptics.success()
            return true
        } catch let err as APIError where err.status == 409 {
            pending.cancel()
            boardInFlightIDs.remove(id)
            boardPendingIDs.remove(id)
            boardRecentlyDoneIDs.remove(id)
            withAnimation(ComMotion.settle) {
                applyBoardMoveLocally(cardID: id, from: target, to: fromCol, replacement: nil)
            }
            _ = await load(Self.boardPath)
            showBoardMoveError(for: id)
            Haptics.error()
            return false
        } catch {
            pending.cancel()
            boardInFlightIDs.remove(id)
            boardPendingIDs.remove(id)
            boardRecentlyDoneIDs.remove(id)
            withAnimation(ComMotion.settle) {
                applyBoardMoveLocally(cardID: id, from: target, to: fromCol, replacement: nil)
            }
            showBoardMoveError(for: id)
            Haptics.error()
            return false
        }
    }

    func boardMove(card: JSON, toTarget target: String, reason: String? = nil) async -> Bool {
        guard let col = BoardColumn.allCases.first(where: { $0.moveTarget == target }) else { return false }
        return await boardMove(card: card, to: col, reason: reason)
    }

    private func markBoardRecentlyDone(_ id: String) {
        boardRecentlyDoneIDs.insert(id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            boardRecentlyDoneIDs.remove(id)
        }
    }

    private func showBoardMoveError(for id: String) {
        let message = "没挪成，卡还在原处——可以再拖一次"
        boardMoveNotes[id] = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if boardMoveNotes[id] == message {
                boardMoveNotes.removeValue(forKey: id)
            }
        }
    }

    func isBoardMovePending(_ id: String) -> Bool { boardPendingIDs.contains(id) }

    func reorderBoardColumnLocally(_ column: BoardColumn, fromIndex: Int, toIndex: Int) {
        var data = boardData
        guard !data.isNull else { return }
        var cols = data["columns"].object
        var rows = cols[column.rawValue]?.array ?? []
        guard rows.indices.contains(fromIndex) else { return }
        let card = rows.remove(at: fromIndex)
        let dest = min(max(0, toIndex), rows.count)
        rows.insert(card, at: dest)
        cols[column.rawValue] = .array(rows)
        data["columns"] = .object(cols)
        datasets[Self.boardPath] = data
    }

    private func applyBoardMoveLocally(cardID: String, from: BoardColumn, to: BoardColumn, insertIndex: Int? = nil, replacement: JSON?) {
        var data = boardData
        if data.isNull {
            data = .object(["version": .string("local"), "columns": .object([:])])
        }
        var cols = data["columns"].object
        var moving: JSON?
        var existingTargetIndex: Int?
        let repMatterID = replacement?["matter_id"].string ?? ""
        for col in BoardColumn.allCases {
            var rows = cols[col.rawValue]?.array ?? []
            if let index = rows.firstIndex(where: {
                $0.id == cardID || (!repMatterID.isEmpty && $0["matter_id"].string == repMatterID)
            }) {
                moving = rows.remove(at: index)
                if col == to { existingTargetIndex = index }
                cols[col.rawValue] = .array(rows)
                break
            }
        }
        if let replacement { moving = replacement }
        guard var card = moving else { return }
        card["column"] = .string(to.rawValue)
        var dest = (cols[to.rawValue]?.array ?? []).filter {
            $0.id != card.id && $0.id != cardID && (repMatterID.isEmpty || $0["matter_id"].string != repMatterID)
        }
        let targetIndex = min(max(0, insertIndex ?? existingTargetIndex ?? 0), dest.count)
        dest.insert(card, at: targetIndex)
        cols[to.rawValue] = .array(dest)
        data["columns"] = .object(cols)
        datasets[Self.boardPath] = data
    }

    /// 对收到的 matter.update 进行内存增量打补丁，避免全量重新拉取 /personal/board
    func applyMatterDeltaLocally(_ delta: JSON) {
        guard !boardDragFreeze else { return }
        let matter = delta["matter"].isNull ? delta : delta["matter"]
        let mId = matter["matter_id"].string.isEmpty
            ? (matter["id"].string.isEmpty ? delta["matter_id"].string : matter["id"].string)
            : matter["matter_id"].string
        guard !mId.isEmpty else { return }

        let newStatus = matter["status"].string.isEmpty ? delta["status"].string : matter["status"].string
        let targetCol: BoardColumn
        if let fsm = MatterStatus(rawValue: newStatus) {
            targetCol = fsm.boardColumn
        } else {
            switch newStatus {
            case "suggested", "suggest", "dismissed", "snoozed": targetCol = .suggest
            case "todo": targetCol = .todo
            case "doing", "executing", "waiting_input", "error_retrying", "error_blocked": targetCol = .doing
            case "done", "cancelled": targetCol = .done
            default: targetCol = .todo
            }
        }

        var data = boardData
        if data.isNull {
            data = .object(["version": .string("local"), "columns": .object([:])])
        }
        var cols = data["columns"].object
        var existingCard: JSON?
        var existingCol: BoardColumn?
        var existingIndex: Int?

        for col in BoardColumn.allCases {
            let rows = cols[col.rawValue]?.array ?? []
            if let idx = rows.firstIndex(where: {
                $0.id == mId || $0["matter_id"].string == mId || $0.id == "next:" + mId || $0.id == "todo:" + mId
            }) {
                existingCard = rows[idx]
                existingCol = col
                existingIndex = idx
                break
            }
        }

        let hasFullCard = !delta["card"].isNull && !delta["card"]["column"].string.isEmpty
        var updatedCard: JSON
        if let c = existingCard {
            let patchSource = hasFullCard ? delta["card"] : matter
            var dict = c.object
            for (k, v) in patchSource.object where !v.isNull {
                if k == "rev" && !hasFullCard {
                    continue
                }
                if k == "id" && !hasFullCard && v.string.hasPrefix("mtr-") && !c.id.hasPrefix("mtr-") {
                    continue
                }
                dict[k] = v
            }
            dict["status"] = .string(newStatus.isEmpty ? c["status"].string : newStatus)
            dict["column"] = .string(targetCol.rawValue)
            updatedCard = .object(dict)
        } else {
            let patchSource = hasFullCard ? delta["card"] : matter
            guard !patchSource["title"].string.isEmpty else { return }
            var dict = patchSource.object
            if dict["id"] == nil || dict["id"]?.string.isEmpty == true {
                dict["id"] = .string(mId)
            }
            dict["matter_id"] = .string(mId)
            dict["column"] = .string(targetCol.rawValue)
            dict["status"] = .string(newStatus.isEmpty ? "suggest" : newStatus)
            updatedCard = .object(dict)
        }

        if let existingCol, let existingIndex {
            if existingCol == targetCol {
                // 原列未变时保持原有排序位置，避免破坏用户的视觉上下文
                var rows = cols[existingCol.rawValue]?.array ?? []
                if rows.indices.contains(existingIndex) {
                    rows[existingIndex] = updatedCard
                    cols[existingCol.rawValue] = .array(rows)
                } else {
                    rows.insert(updatedCard, at: 0)
                    cols[existingCol.rawValue] = .array(rows)
                }
            } else {
                // 跨列流转时从原列移除，插入目标列头部
                var oldRows = cols[existingCol.rawValue]?.array ?? []
                if oldRows.indices.contains(existingIndex) {
                    oldRows.remove(at: existingIndex)
                    cols[existingCol.rawValue] = .array(oldRows)
                }
                var targetRows = cols[targetCol.rawValue]?.array ?? []
                targetRows.insert(updatedCard, at: 0)
                cols[targetCol.rawValue] = .array(targetRows)
            }
        } else {
            var targetRows = cols[targetCol.rawValue]?.array ?? []
            targetRows.insert(updatedCard, at: 0)
            cols[targetCol.rawValue] = .array(targetRows)
        }
        data["columns"] = .object(cols)

        if targetCol == .done {
            markBoardRecentlyDone(mId)
        }

        guard !boardDragFreeze else { return }
        withAnimation(ComMotion.settle) {
            datasets[Self.boardPath] = data
        }
    }

    #if DEBUG
    func seedBoardPreview() {
        let env = ProcessInfo.processInfo.environment["COM_PREVIEW_BOARD"] ?? ""
        let now = Date().timeIntervalSince1970
        func card(_ id: String, _ kind: String, _ col: BoardColumn, _ title: String, extra: [String: JSON] = [:]) -> JSON {
            var base: [String: JSON] = [
                "id": .string(id), "kind": .string(kind), "column": .string(col.rawValue),
                "title": .string(title), "rev": .string("preview-\(id)"), "urgency": .string("today"),
                "phase": .string("new"), "due": .string(""), "overdue": .bool(false),
                "sources": .array([]), "progress": .string(""), "completed_at": .number(0),
                "case": .null, "next": .null, "todo": .null,
            ]
            for (k, v) in extra { base[k] = v }
            return .object(base)
        }
        var suggest: [JSON] = []
        var todo: [JSON] = []
        var doing: [JSON] = []
        var done: [JSON] = []
        if let next = datasets["/personal/next"] {
            for item in next["items"].array.prefix(5) {
                let nid = "next:" + item.id
                suggest.append(card(nid, "next", .suggest, item["title"].string, extra: [
                    "urgency": item["urgency"], "phase": item["phase"], "next": item,
                    "sources": .array({
                        var kinds: [String] = []
                        for e in item["evidence"].array {
                            let k = e["kind"].string
                            if !k.isEmpty, !kinds.contains(k) { kinds.append(k) }
                            if kinds.count >= 3 { break }
                        }
                        return kinds.map { JSON.string($0) }
                    }()),
                ]))
            }
        }
        while suggest.count < 5 {
            let i = suggest.count
            suggest.append(card("next:pad-\(i)", "next", .suggest, "样例建议 \(i + 1)"))
        }
        for i in 0..<5 {
            todo.append(card("todo:todo-\(i)", "todo", .todo, "待办样例 \(i + 1)", extra: ["due": .string("2026-11-0\(i + 3)"), "progress": .string("")]))
            doing.append(card("todo:doing-\(i)", "todo", .doing, "进行中 \(i + 1)", extra: ["progress": .string("最新进展 · 第 \(i + 1) 步"), "phase": .string("progress")]))
            done.append(card("todo:done-\(i)", "todo", .done, "已完成 \(i + 1)", extra: ["completed_at": .number(now - Double(i) * 3600)]))
        }
        if env == "正在做", let first = suggest.first {
            suggest.removeFirst()
            var moved = first
            moved["column"] = .string(BoardColumn.doing.rawValue)
            doing.insert(moved, at: 0)
        }
        boardColumn = env == "正在做" ? .todo : .suggest
        datasets[Self.boardPath] = .object([
            "version": .string("preview"), "updated_at": .number(now), "snoozed": .number(0),
            "columns": .object([
                "suggest": .array(suggest), "todo": .array(todo), "doing": .array(doing), "done": .array(done),
            ]),
        ])
    }
    #endif
}
