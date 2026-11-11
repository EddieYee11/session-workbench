import Foundation

// 模拟 HerdrMachine 与 Address 数据结构
struct Address: Sendable {
    let host: String
    let port: Int
    let label: String
}

private final class ProbeResultOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?

    init(_ continuation: CheckedContinuation<Result<Void, Error>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: result)
    }
}

private final class ProbeResultHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ProbeResultOnce?
    private var isCancelled = false
    private var connectTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func set(result r: ProbeResultOnce, connectTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            connectTask.cancel()
            timeoutTask.cancel()
            r.resume(.failure(CancellationError()))
            return
        }
        self.result = r
        self.connectTask = connectTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let r = result
        result = nil
        let c = connectTask
        let t = timeoutTask
        connectTask = nil
        timeoutTask = nil
        lock.unlock()
        c?.cancel()
        t?.cancel()
        r?.resume(.failure(CancellationError()))
    }
}

struct MockCandidate: Sendable {
    let address: Address
    var connectTimeoutSeconds: Int = 10
    let behavior: MockBehavior

    enum MockBehavior: Sendable {
        case instantSuccess(latencyMs: Int)
        case instantReject(errorText: String)
        case blackholeTimeout(timeoutSec: Double)
        case hostKeyRejected
        case authFailed
    }

    func probe() async throws {
        switch behavior {
        case .instantSuccess(let latencyMs):
            try await Task.sleep(nanoseconds: UInt64(latencyMs) * 1_000_000)
            return
        case .instantReject(let errorText):
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            throw NSError(domain: "POSIX", code: 61, userInfo: [NSLocalizedDescriptionKey: errorText])
        case .hostKeyRejected:
            try await Task.sleep(nanoseconds: 15_000_000)
            throw NSError(domain: "SSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "SSHHostKeyRejected: pin mismatch"])
        case .authFailed:
            try await Task.sleep(nanoseconds: 15_000_000)
            throw NSError(domain: "SSH", code: 2, userInfo: [NSLocalizedDescriptionKey: "allAuthenticationOptionsFailed"])
        case .blackholeTimeout(let timeoutSec):
            // 真实还原 SSHPTYSession.swift 优化后的 probe() 实现（支持 Task 取消）
            let holder = ProbeResultHolder()
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
                    let once = ProbeResultOnce(continuation)
                    let connectTask = Task {
                        try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                        once.resume(.failure(NSError(domain: "Citadel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection timed out"])))
                    }
                    let timeoutTask = Task {
                        try? await Task.sleep(nanoseconds: UInt64(Double(connectTimeoutSeconds) * 1_000_000_000))
                        once.resume(.failure(NSError(domain: "HerdrKit", code: -2, userInfo: [NSLocalizedDescriptionKey: "连接超时"])))
                    }
                    holder.set(result: once, connectTask: connectTask, timeoutTask: timeoutTask)
                }
            } onCancel: {
                holder.cancel()
            }
            try result.get()
        }
    }
}

struct ProbeResult: Sendable {
    let address: Address
    let candidate: MockCandidate
}

enum ProbeOutcome: Sendable {
    case success(ProbeResult)
    case failure(Address, String, Bool, Bool)
}

final class MockProbeRaceCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(ProbeResult?, [ProbeOutcome]), Never>?
    private var tasks: [Task<Void, Never>] = []
    private var winner: ProbeResult?
    private var outcomes: [ProbeOutcome] = []
    private let totalCount: Int
    private var finishedCount = 0

    init(totalCount: Int, continuation: CheckedContinuation<(ProbeResult?, [ProbeOutcome]), Never>) {
        self.totalCount = totalCount
        self.continuation = continuation
    }

    func register(task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    func recordSuccess(_ result: ProbeResult) {
        lock.lock()
        outcomes.append(.success(result))
        finishedCount += 1
        let cont = continuation
        continuation = nil
        winner = result
        let toCancel = tasks
        lock.unlock()

        for t in toCancel {
            t.cancel()
        }
        cont?.resume(returning: (result, outcomes))
    }

    func recordFailure(address: Address, error: String, isHostKey: Bool, isAuth: Bool) {
        lock.lock()
        outcomes.append(.failure(address, error, isHostKey, isAuth))
        finishedCount += 1
        var cont: CheckedContinuation<(ProbeResult?, [ProbeOutcome]), Never>?
        if finishedCount >= totalCount, winner == nil {
            cont = continuation
            continuation = nil
        }
        lock.unlock()

        cont?.resume(returning: (nil, outcomes))
    }

    func cancelAll() {
        lock.lock()
        let toCancel = tasks
        tasks.removeAll()
        let cont = continuation
        continuation = nil
        lock.unlock()
        for t in toCancel {
            t.cancel()
        }
        cont?.resume(returning: (nil, outcomes))
    }
}

// 模拟 HerdrSessionStore.swift 优化后的竞速逻辑（ProbeRaceCoordinator）
func raceConnect(addresses: [(Address, MockCandidate.MockBehavior)]) async -> (winner: ProbeResult?, outcomes: [ProbeOutcome], elapsedMs: Double, phase: String) {
    let startTime = Date()
    let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<(ProbeResult?, [ProbeOutcome]), Never>) in
        let coordinator = MockProbeRaceCoordinator(totalCount: addresses.count, continuation: continuation)
        for (addr, behavior) in addresses {
            let candidate = MockCandidate(address: addr, connectTimeoutSeconds: 2, behavior: behavior)
            let task = Task {
                do {
                    try Task.checkCancellation()
                    try await candidate.probe()
                    try Task.checkCancellation()
                    coordinator.recordSuccess(ProbeResult(address: addr, candidate: candidate))
                } catch {
                    let text = "\(error)"
                    let isHostKey = text.contains("SSHHostKeyRejected")
                    let isAuth = text.lowercased().contains("allauthenticationoptionsfailed")
                    coordinator.recordFailure(address: addr, error: text, isHostKey: isHostKey, isAuth: isAuth)
                }
            }
            coordinator.register(task: task)
        }
    }

    let elapsed = Date().timeIntervalSince(startTime) * 1000.0
    var finalPhase = "idle"
    if outcome.0 != nil {
        finalPhase = "connected"
    } else {
        var sawHostKey = false
        var sawAuth = false
        var errors: [String] = []
        for item in outcome.1 {
            if case .failure(let addr, let text, let isHostKey, let isAuth) = item {
                if isHostKey { sawHostKey = true }
                if isAuth { sawAuth = true }
                errors.append("\(addr.label)：\(text)")
            }
        }
        if sawHostKey {
            finalPhase = "hostKeyChanged"
        } else if sawAuth {
            finalPhase = "needsAuthorization"
        } else {
            finalPhase = "failed: \(errors.joined(separator: "；"))"
        }
    }

    return (outcome.0, outcome.1, elapsed, finalPhase)
}

print("=== [CHAOS TEST 1] LAN (20ms 成功) vs 公网黑洞超时 (2000ms 超时) ===")
let lanAddr = Address(host: "192.168.1.100", port: 22, label: "局域网")
let pubAddr = Address(host: "203.0.113.1", port: 22, label: "公网")
let res1 = await raceConnect(addresses: [
    (lanAddr, .instantSuccess(latencyMs: 20)),
    (pubAddr, .blackholeTimeout(timeoutSec: 2.0))
])
print(String(format: "-> 结果: winner=%@, phase=%@, 实际耗时: %.2f ms", res1.winner?.address.label ?? "nil", res1.phase, res1.elapsedMs))

print("=== [CHAOS TEST 2] 全网不可达（局域网拒绝 + 公网黑洞超时） ===")
let res2 = await raceConnect(addresses: [
    (lanAddr, .instantReject(errorText: "Connection refused")),
    (pubAddr, .blackholeTimeout(timeoutSec: 1.0))
])
print(String(format: "-> 结果: winner=%@, phase=%@, 实际耗时: %.2f ms", res2.winner?.address.label ?? "nil", res2.phase, res2.elapsedMs))

print("=== [CHAOS TEST 3] Tailscale 延迟 (50ms) vs 局域网更大延迟 (150ms) ===")
let tsAddr = Address(host: "100.64.0.1", port: 22, label: "Tailscale")
let res3 = await raceConnect(addresses: [
    (tsAddr, .instantSuccess(latencyMs: 50)),
    (lanAddr, .instantSuccess(latencyMs: 150))
])
print(String(format: "-> 结果: winner=%@, phase=%@, 实际耗时: %.2f ms", res3.winner?.address.label ?? "nil", res3.phase, res3.elapsedMs))

print("=== [CHAOS TEST 4] 主机指纹变化与鉴权失败优先级 ===")
let res4 = await raceConnect(addresses: [
    (lanAddr, .hostKeyRejected),
    (pubAddr, .authFailed)
])
print(String(format: "-> 结果: winner=%@, phase=%@, 实际耗时: %.2f ms", res4.winner?.address.label ?? "nil", res4.phase, res4.elapsedMs))
