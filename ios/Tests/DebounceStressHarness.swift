import Foundation

@MainActor
final class DebounceTester {
    private var refreshDebounceTask: Task<Void, Never>?
    private(set) var refreshCallCount: Int = 0
    private(set) var lastRefreshTime: Date?

    func scheduleDebouncedRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }

    func disconnect() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
    }

    func refresh() async {
        refreshCallCount += 1
        lastRefreshTime = Date()
    }
}

print("=== [TEST 1] 100~500 并发事件注入防抖测试 ===")
let tester = DebounceTester()
let burstCount = 500
let burstStart = Date()

print("-> 开始并发注入 \(burstCount) 个事件...")
await withTaskGroup(of: Void.self) { group in
    for _ in 0..<10 {
        group.addTask { @MainActor in
            for _ in 0..<(burstCount / 10) {
                tester.scheduleDebouncedRefresh()
                try? await Task.sleep(nanoseconds: UInt64.random(in: 10_000...150_000))
            }
        }
    }
}
let burstEnd = Date()
let burstDurationMs = burstEnd.timeIntervalSince(burstStart) * 1000.0
print(String(format: "-> 注入完成，耗时: %.2f ms", burstDurationMs))

let initialRefreshes = tester.refreshCallCount
print("-> Burst 结束瞬间刷新次数 (预期 0): \(initialRefreshes)")
assert(initialRefreshes == 0, "防抖失败：在密集突发期间触发了刷新！")

try? await Task.sleep(nanoseconds: 250_000_000)
let finalRefreshes = tester.refreshCallCount
print("-> 窗口静默 250ms 后刷新次数 (预期 1): \(finalRefreshes)")
assert(finalRefreshes == 1, "防抖失败：预期单次合并刷新，实际为 \(finalRefreshes)")

print("=== [TEST 2] 连续滑动窗口防抖测试 (无静默期持续注入) ===")
let continuousTester = DebounceTester()
let continuousRounds = 10
print("-> 连续每 40ms 注入一次事件，持续 \(continuousRounds) 次 (总计 400ms，每次均打断 150ms 窗口)...")
for _ in 0..<continuousRounds {
    continuousTester.scheduleDebouncedRefresh()
    try? await Task.sleep(nanoseconds: 40_000_000)
}
let countBeforeQuiet = continuousTester.refreshCallCount
print("-> 连续注入期间刷新次数 (预期 0): \(countBeforeQuiet)")
assert(countBeforeQuiet == 0, "滑动窗口失败：在未静默前触发了刷新")

try? await Task.sleep(nanoseconds: 200_000_000)
let countAfterQuiet = continuousTester.refreshCallCount
print("-> 静默 200ms 后刷新次数 (预期 1): \(countAfterQuiet)")
assert(countAfterQuiet == 1, "最终合并刷新失败：预期 1，实际 \(countAfterQuiet)")

print("=== [TEST 3] Disconnect 立即取消测试 ===")
let disconnectTester = DebounceTester()
disconnectTester.scheduleDebouncedRefresh()
try? await Task.sleep(nanoseconds: 50_000_000)
disconnectTester.disconnect()
try? await Task.sleep(nanoseconds: 200_000_000)
let countAfterDisconnect = disconnectTester.refreshCallCount
print("-> 断开后刷新次数 (预期 0): \(countAfterDisconnect)")
assert(countAfterDisconnect == 0, "断开清理失败：disconnect 后仍然执行了刷新")

print("=== [TEST 4] 极端 5000 次暴风级并发轰炸与死锁检测 ===")
let extremeTester = DebounceTester()
let extremeBurst = 5000
let startExtreme = Date()
await withTaskGroup(of: Void.self) { group in
    for _ in 0..<25 {
        group.addTask { @MainActor in
            for _ in 0..<(extremeBurst / 25) {
                extremeTester.scheduleDebouncedRefresh()
            }
        }
    }
}
let durationExtreme = Date().timeIntervalSince(startExtreme) * 1000.0
print(String(format: "-> 5000 次极端并发轰炸完成，耗时: %.2f ms", durationExtreme))
try? await Task.sleep(nanoseconds: 250_000_000)
let extremeCount = extremeTester.refreshCallCount
print("-> 极端轰炸后静默 250ms 刷新次数 (预期 1): \(extremeCount)")
assert(extremeCount == 1, "极端并发轰炸防抖失败：预期 1，实际 \(extremeCount)")

print("=== 全部防抖并发与极端轰炸测试 100% 通过 ===")
