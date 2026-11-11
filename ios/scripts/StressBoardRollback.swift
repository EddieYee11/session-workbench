import Foundation
import ComCore

// Model the board data structure and rollback logic from BoardModel.swift
struct BoardSimulator {
    var datasets: [String: JSON] = [:]
    var boardInFlightIDs: Set<String> = []
    var boardPendingIDs: Set<String> = []
    var boardRecentlyDoneIDs: Set<String> = []
    var boardMoveNotes: [String: String] = [:]

    static let boardPath = "/personal/board"

    var boardData: JSON { datasets[Self.boardPath] ?? .null }

    mutating func setInitialBoard(cards: [String: [JSON]]) {
        var cols: [String: JSON] = [:]
        for (col, list) in cards {
            cols[col] = .array(list)
        }
        datasets[Self.boardPath] = .object(["version": .string("v1"), "columns": .object(cols)])
    }

    mutating func applyBoardMoveLocally(cardID: String, from: String, to: String) {
        var data = boardData
        guard case .object(var cols) = data["columns"] else { return }
        var moving: JSON?
        for (colKey, colVal) in cols {
            var rows = colVal.array
            if let idx = rows.firstIndex(where: { $0.id == cardID }) {
                moving = rows.remove(at: idx)
                cols[colKey] = .array(rows)
                break
            }
        }
        if var card = moving {
            card["column"] = .string(to)
            var targetRows = cols[to]?.array ?? []
            targetRows.append(card)
            cols[to] = .array(targetRows)
        }
        var updated = data.object
        updated["columns"] = .object(cols)
        datasets[Self.boardPath] = .object(updated)
    }

    // Simulate incoming SSE delta for another card during in-flight move
    mutating func applyMatterDeltaLocally(matterID: String, newTitle: String) {
        var data = boardData
        guard case .object(var cols) = data["columns"] else { return }
        for (colKey, colVal) in cols {
            var rows = colVal.array
            if let idx = rows.firstIndex(where: { $0.id == matterID }) {
                var c = rows[idx]
                c["title"] = .string(newTitle)
                rows[idx] = c
                cols[colKey] = .array(rows)
                break
            }
        }
        var updated = data.object
        updated["columns"] = .object(cols)
        datasets[Self.boardPath] = .object(updated)
    }

    // Simulate boardMove with simulated network responses:
    // statusAttempt1, statusAttempt2 (e.g. 409, 409)
    mutating func simulateBoardMove(
        cardID: String,
        from: String,
        to: String,
        attempt1Status: Int,
        attempt2Status: Int,
        interleavedSSE: Bool = false
    ) -> Bool {
        let snapshot = boardData
        applyBoardMoveLocally(cardID: cardID, from: from, to: to)
        boardInFlightIDs.insert(cardID)

        if interleavedSSE {
            // Another card is updated concurrently via SSE
            applyMatterDeltaLocally(matterID: "card-2", newTitle: "Updated by SSE concurrently")
        }

        // Attempt 1
        if attempt1Status == 409 {
            // Conflict caught, retry attempt 2
            if attempt2Status == 409 {
                // Persistent conflict -> Outer catch rollback
                boardInFlightIDs.remove(cardID)
                boardPendingIDs.remove(cardID)
                boardRecentlyDoneIDs.remove(cardID)

                // Spring rollback from BoardModel.swift:255
                datasets[Self.boardPath] = snapshot
                boardMoveNotes[cardID] = "没挪成，卡还在原处——可以再拖一次"
                return false
            } else if attempt2Status == 200 {
                // Retry succeeded
                boardInFlightIDs.remove(cardID)
                return true
            }
        } else if attempt1Status == 200 {
            boardInFlightIDs.remove(cardID)
            return true
        }

        return false
    }
}

@main
struct StressBoardRollback {
    static func main() {
        print("=== Starting BoardModel 409 Conflict & Spring Rollback Stress Tests ===")

        let card1 = JSON.object(["id": .string("card-1"), "title": .string("Card One"), "column": .string("todo"), "rev": .number(1)])
        let card2 = JSON.object(["id": .string("card-2"), "title": .string("Card Two"), "column": .string("suggest"), "rev": .number(1)])

        // Test 1: Single 409 conflict followed by successful retry (200)
        do {
            var sim = BoardSimulator()
            sim.setInitialBoard(cards: ["todo": [card1], "suggest": [card2], "doing": [], "done": []])

            let success = sim.simulateBoardMove(cardID: "card-1", from: "todo", to: "doing", attempt1Status: 409, attempt2Status: 200)
            assert(success == true, "Test 1 failed: single conflict retry should succeed")
            let doingCards = sim.boardData["columns"]["doing"].array.map { $0.id }
            assert(doingCards.contains("card-1"), "Test 1 failed: card-1 should be in doing after successful retry")
            print("✓ Test 1: 409 conflict recovered transparently on automatic retry with latest rev")
        }

        // Test 2: Persistent 409 conflict triggers spring rollback to snapshot
        do {
            var sim = BoardSimulator()
            sim.setInitialBoard(cards: ["todo": [card1], "suggest": [card2], "doing": [], "done": []])

            let success = sim.simulateBoardMove(cardID: "card-1", from: "todo", to: "doing", attempt1Status: 409, attempt2Status: 409)
            assert(success == false, "Test 2 failed: persistent conflict should return false")
            let todoCards = sim.boardData["columns"]["todo"].array.map { $0.id }
            let doingCards = sim.boardData["columns"]["doing"].array.map { $0.id }
            assert(todoCards.contains("card-1"), "Test 2 failed: card-1 should roll back to todo")
            assert(doingCards.isEmpty, "Test 2 failed: doing column should be empty after rollback")
            assert(sim.boardInFlightIDs.isEmpty, "Test 2 failed: inFlight IDs must be cleared")
            assert(sim.boardMoveNotes["card-1"] != nil, "Test 2 failed: error note should be set")
            print("✓ Test 2: Persistent 409 conflict triggers spring rollback to pre-move column and cleans up inFlight state")
        }

        // Test 3: Interleaved concurrent SSE update during in-flight move + 409 rollback
        do {
            var sim = BoardSimulator()
            sim.setInitialBoard(cards: ["todo": [card1], "suggest": [card2], "doing": [], "done": []])

            _ = sim.simulateBoardMove(cardID: "card-1", from: "todo", to: "doing", attempt1Status: 409, attempt2Status: 409, interleavedSSE: true)

            // Inspect card-2 title
            let suggestCards = sim.boardData["columns"]["suggest"].array
            let card2AfterRollback = suggestCards.first(where: { $0.id == "card-2" })
            let title = card2AfterRollback?["title"].string ?? ""

            print("Card-2 title after Card-1 rollback: \"\(title)\"")
            if title == "Card Two" {
                print("⚠️ FINDING: Restoring `datasets[Self.boardPath] = snapshot` on 409 rollback causes state regression, clobbering concurrent SSE updates on unrelated cards until full network refresh completes!")
            } else {
                print("✓ Concurrent card updates preserved")
            }
        }

        print("=== All BoardModel rollback stress tests completed ===")
    }
}
