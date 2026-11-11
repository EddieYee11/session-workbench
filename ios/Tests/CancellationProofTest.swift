import Foundation

func probeWithCancellationHandler(timeoutSec: Double) async throws {
    let lock = NSLock()
    var resumed = false

    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: NSError(domain: "Network", code: -1, userInfo: nil))
                }
            }
        }
    } onCancel: {
        lock.lock()
        defer { lock.unlock() }
        // 关键：当父 TaskGroup 执行 cancelAll() 时，立即触发本回调！
        // 如果这里能够直接 resume，子任务就会在毫秒内立即结束！
    }
}

print("=== 验证 withTaskCancellationHandler 能否让 cancelled task 瞬间退出 ===")
let start = Date()
let winner = await withTaskGroup(of: String.self) { group in
    group.addTask {
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        return "LAN"
    }

    group.addTask {
        let lock = NSLock()
        var continuationRef: CheckedContinuation<String, Never>?
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                lock.lock()
                continuationRef = cont
                lock.unlock()
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                    lock.lock()
                    let c = continuationRef
                    continuationRef = nil
                    lock.unlock()
                    c?.resume(returning: "SLOW")
                }
            }
        } onCancel: {
            lock.lock()
            let c = continuationRef
            continuationRef = nil
            lock.unlock()
            c?.resume(returning: "CANCELLED")
        }
    }

    var first: String?
    for await res in group {
        if res == "LAN" {
            first = res
            group.cancelAll()
            break
        }
    }
    return first
}

let elapsed = Date().timeIntervalSince(start) * 1000.0
print(String(format: "-> 胜出者: %@, withTaskGroup 返回耗时: %.2f ms", winner ?? "nil", elapsed))
