import Foundation
import ComCore

@main
struct StressChatTimeline {
    static func main() async throws {
        print("=== Starting ChatTimeline Stress Tests ===")
        var testCount = 0

        // Test 1: Out-of-order sequence numbers
        do {
            let m1 = JSON.object(["id": .string("m1"), "role": .string("assistant"), "message_seq": .number(1), "created_at": .number(100)])
            let m2 = JSON.object(["id": .string("m2"), "role": .string("assistant"), "message_seq": .number(2), "created_at": .number(200)])
            let m3 = JSON.object(["id": .string("m3"), "role": .string("assistant"), "message_seq": .number(3), "created_at": .number(300)])
            let m4 = JSON.object(["id": .string("m4"), "role": .string("assistant"), "message_seq": .number(4), "created_at": .number(400)])
            let m5 = JSON.object(["id": .string("m5"), "role": .string("assistant"), "message_seq": .number(5), "created_at": .number(500)])

            let shuffled = [m3, m5, m1, m4, m2]
            let rows = ChatTimeline.rows(messages: shuffled, pending: [])
            let resultIDs = rows.map { $0.id }
            assert(resultIDs == ["m1", "m2", "m3", "m4", "m5"], "Test 1 failed: expected [m1, m2, m3, m4, m5], got \(resultIDs)")
            print("✓ Test 1: Out-of-order sequence numbers sorted strictly [1..5]")
            testCount += 1
        }

        // Test 2: Inverted timestamps vs sequence numbers (seq must win)
        do {
            // m1 has seq 1 but newer timestamp (e.g. 500)
            // m2 has seq 2 but older timestamp (e.g. 100)
            let m1 = JSON.object(["id": .string("m1"), "role": .string("assistant"), "message_seq": .number(1), "created_at": .number(500)])
            let m2 = JSON.object(["id": .string("m2"), "role": .string("assistant"), "message_seq": .number(2), "created_at": .number(100)])
            let rows = ChatTimeline.rows(messages: [m2, m1], pending: [])
            let resultIDs = rows.map { $0.id }
            assert(resultIDs == ["m1", "m2"], "Test 2 failed: seq should win over timestamp, got \(resultIDs)")
            print("✓ Test 2: Inverted timestamps vs sequence numbers: seq correctly wins")
            testCount += 1
        }

        // Test 3: Duplicate timestamps with distinct sequence numbers
        do {
            let m1 = JSON.object(["id": .string("m1"), "role": .string("assistant"), "message_seq": .number(1), "created_at": .number(1000)])
            let m2 = JSON.object(["id": .string("m2"), "role": .string("assistant"), "message_seq": .number(2), "created_at": .number(1000)])
            let rows = ChatTimeline.rows(messages: [m2, m1], pending: [])
            let resultIDs = rows.map { $0.id }
            assert(resultIDs == ["m1", "m2"], "Test 3 failed: got \(resultIDs)")
            print("✓ Test 3: Duplicate timestamps with distinct seq sorted by seq")
            testCount += 1
        }

        // Test 4: Duplicate timestamps without sequence numbers (tiebreak by ID)
        do {
            let mA = JSON.object(["id": .string("msg-alpha"), "role": .string("assistant"), "created_at": .number(1000)])
            let mB = JSON.object(["id": .string("msg-beta"), "role": .string("assistant"), "created_at": .number(1000)])
            let rows = ChatTimeline.rows(messages: [mB, mA], pending: [])
            let resultIDs = rows.map { $0.id }
            assert(resultIDs == ["msg-alpha", "msg-beta"], "Test 4 failed: deterministic tiebreak by id failed, got \(resultIDs)")
            print("✓ Test 4: Duplicate timestamps without seq: deterministic tiebreak by id")
            testCount += 1
        }

        // Test 5: Duplicate sequence numbers (fallback to timestamp)
        do {
            let m1 = JSON.object(["id": .string("m1"), "role": .string("assistant"), "message_seq": .number(5), "created_at": .number(100)])
            let m2 = JSON.object(["id": .string("m2"), "role": .string("assistant"), "message_seq": .number(5), "created_at": .number(200)])
            let rows = ChatTimeline.rows(messages: [m2, m1], pending: [])
            let resultIDs = rows.map { $0.id }
            assert(resultIDs == ["m1", "m2"], "Test 5 failed: got \(resultIDs)")
            print("✓ Test 5: Duplicate sequence numbers fall back to timestamp")
            testCount += 1
        }

        // Test 6: Strict Weak Ordering check - Transitivity with mixed seq and non-seq messages
        do {
            // Object A: seq = 1, created_at = 200.0
            // Object B: seq = 2, created_at = 100.0
            // Object C: seq = 0 (e.g. pending), created_at = 150.0
            let mA = JSON.object(["id": .string("mA"), "role": .string("assistant"), "message_seq": .number(1), "created_at": .number(200)])
            let mB = JSON.object(["id": .string("mB"), "role": .string("assistant"), "message_seq": .number(2), "created_at": .number(100)])
            let mC = JSON.object(["id": .string("mC"), "role": .string("assistant"), "created_at": .number(150)])

            // Permutation 1
            let rows1 = ChatTimeline.rows(messages: [mA, mB, mC], pending: []).map { $0.id }
            // Permutation 2
            let rows2 = ChatTimeline.rows(messages: [mC, mB, mA], pending: []).map { $0.id }
            // Permutation 3
            let rows3 = ChatTimeline.rows(messages: [mB, mC, mA], pending: []).map { $0.id }

            print("Transitivity test outputs for permutations:")
            print("  [A, B, C] -> \(rows1)")
            print("  [C, B, A] -> \(rows2)")
            print("  [B, C, A] -> \(rows3)")

            if rows1 != rows2 || rows2 != rows3 {
                print("⚠️ FINDING: Non-deterministic sorting order under mixed seq & non-seq messages due to intransitive comparator!")
            } else {
                print("✓ Strict ordering maintained across permutations: \(rows1)")
            }
            testCount += 1
        }

        // Test 7: Concurrency & Stress - Rapid parallel invocations
        do {
            await withTaskGroup(of: Bool.self) { group in
                for i in 0..<50 {
                    group.addTask {
                        var msgs: [JSON] = []
                        for j in 0..<30 {
                            let seq = (j * 7) % 30 + 1
                            let ts = Double(1000 + (j * 13) % 50)
                            msgs.append(JSON.object([
                                "id": .string("worker-\(i)-msg-\(j)"),
                                "role": .string("assistant"),
                                "message_seq": .number(Double(seq)),
                                "created_at": .number(ts)
                            ]))
                        }
                        let sorted = ChatTimeline.rows(messages: msgs, pending: [])
                        // verify that message_seq is monotonically non-decreasing
                        var prevSeq = 0
                        for row in sorted {
                            let s = row.message["message_seq"].int
                            if s < prevSeq { return false }
                            prevSeq = s
                        }
                        return true
                    }
                }
                var allPassed = true
                for await res in group {
                    if !res { allPassed = false }
                }
                assert(allPassed, "Test 7 failed: concurrent sorting yielded non-monotonic seq order")
            }
            print("✓ Test 7: Concurrency stress: 50 concurrent tasks sorting 30 messages passed monotonically")
            testCount += 1
        }

        // Test 8: Pending message replacement by request_id
        do {
            let pendingMsg = PendingMessage(text: "Hello", requestID: "req-123")
            // Server responds with user message matching request_id
            let serverMsg = JSON.object([
                "id": .string("srv-999"),
                "request_id": .string("req-123"),
                "role": .string("user"),
                "text": .string("Hello"),
                "message_seq": .number(1),
                "created_at": .number(100)
            ])
            let rows = ChatTimeline.rows(messages: [serverMsg], pending: [pendingMsg])
            assert(rows.count == 1, "Test 8 failed: expected 1 row, got \(rows.count)")
            assert(rows[0].id == "request:req-123", "Test 8 failed: expected request:req-123, got \(rows[0].id)")
            assert(rows[0].pending == nil, "Test 8 failed: pending should be replaced by server message")
            print("✓ Test 8: Pending message correctly deduplicated and replaced by server message")
            testCount += 1
        }

        print("=== All \(testCount) ChatTimeline tests completed successfully ===")
    }
}
