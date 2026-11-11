import Foundation

enum ProbeOutcome: Sendable {
    case success(String)
    case failure(String, String)
}

func simulateCandidateProbe(label: String, delaySeconds: Double, succeeds: Bool) async throws {
    // 模拟 SSHEndpoint.probe() 的机制：使用 withCheckedContinuation，且内部用 Task.sleep 模拟超时
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            if succeeds {
                continuation.resume()
            } else {
                continuation.resume(throwing: NSError(domain: "Network", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timeout"]))
            }
        }
    }
}

print("=== 模拟 withTaskGroup 竞速探测与取消等待测试 ===")
let startTime = Date()

let outcome = await withTaskGroup(of: ProbeOutcome.self) { group -> (winner: String?, outcomes: [ProbeOutcome]) in
    // Candidate 1: 局域网，20ms 秒连成功
    group.addTask {
        do {
            try Task.checkCancellation()
            try await simulateCandidateProbe(label: "LAN", delaySeconds: 0.02, succeeds: true)
            return .success("LAN")
        } catch {
            return .failure("LAN", "\(error)")
        }
    }

    // Candidate 2: 公网（不可达/黑洞），需要 3 秒才超时
    group.addTask {
        do {
            try Task.checkCancellation()
            try await simulateCandidateProbe(label: "PublicIP", delaySeconds: 3.0, succeeds: false)
            return .success("PublicIP")
        } catch {
            return .failure("PublicIP", "\(error)")
        }
    }

    var allOutcomes: [ProbeOutcome] = []
    var winner: String?

    for await result in group {
        allOutcomes.append(result)
        if case .success(let name) = result, winner == nil {
            winner = name
            print("-> [\(Date().timeIntervalSince(startTime))s] 发现胜出者: \(name)，执行 group.cancelAll() 并 break")
            group.cancelAll()
            break
        }
    }
    print("-> [\(Date().timeIntervalSince(startTime))s] 退出 for await 循环，准备 return (winner, allOutcomes)")
    return (winner, allOutcomes)
}

let totalElapsed = Date().timeIntervalSince(startTime)
print(String(format: "-> [FINAL] withTaskGroup 返回！总耗时: %.3f 秒, 胜出者: %@", totalElapsed, outcome.winner ?? "nil"))
