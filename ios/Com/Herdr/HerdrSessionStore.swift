import Foundation
import HerdrKit
import Observation

/// 工作 Tab「终端」的状态：选机器 → 找到能通的地址 → 读会话树。
/// 会话树和 agent 状态走 HerdrKit（Moshi 逆向那条协议线），真正的终端字节走 `HerdrPTYController`。
@MainActor
@Observable
final class HerdrSessionStore {
    enum Phase: Equatable {
        case idle, connecting, connected
        case needsAuthorization
        case hostKeyChanged
        case failed(String)
    }

    private(set) var machines: [HerdrMachine] = HerdrMachineCache.load()
    private(set) var selectedMachineId = UserDefaults.standard.string(forKey: "herdr.machine") ?? "mbp"
    private(set) var phase: Phase = .idle
    private(set) var snapshot: HerdrSnapshot?
    private(set) var endpoint: SSHEndpoint?
    private(set) var routeLabel = ""
    private(set) var publicKey = ""

    private(set) var client: HerdrClient?
    private var eventsTask: Task<Void, Never>?
    private var refreshDebounceTask: Task<Void, Never>?
    private var generation = 0
    private var snapshotSequence = 0
    private var committedSnapshotSequence = 0

    var selectedMachine: HerdrMachine? { machines.first { $0.id == selectedMachineId } }

    /// 生成设备密钥、向后端登记公钥并取机器清单；后端暂时不通时用上次的缓存。
    func registerDeviceKey(backend: (any HerdrBackend)? = nil) async {
        do {
            publicKey = try HerdrDeviceKey.publicLine()
        } catch {
            phase = .failed("\(error.localizedDescription)")
            return
        }
        guard let backend else { return }
        if let result = try? await backend.mutate("/remote/herdr/device-key", fields: ["public_key": .string(publicKey)]),
           let data = try? JSONEncoder().encode(result["machines"]),
           let fresh = try? JSONDecoder().decode([HerdrMachine].self, from: data), !fresh.isEmpty {
            machines = fresh
            HerdrMachineCache.save(fresh)
        }
    }

    func prepare(backend: (any HerdrBackend)? = nil) async {
        if let backend {
            await registerDeviceKey(backend: backend)
        }
        if case .failed = phase { return }
        await connect()
    }

    // Backward-compatible overloads
    func registerDeviceKey(model: any HerdrBackend) async {
        await registerDeviceKey(backend: model)
    }

    func prepare(model: any HerdrBackend) async {
        await prepare(backend: model)
    }

    func select(_ id: String) async {
        guard id != selectedMachineId else { return }
        selectedMachineId = id
        UserDefaults.standard.set(id, forKey: "herdr.machine")
        await connect()
    }

    func connect() async {
        disconnect()
        generation += 1
        let current = generation
        guard let machine = selectedMachine else {
            phase = .failed("还没拿到机器清单，确认 Com 后端连得上。")
            HerdrSignposts.markConnectFailed(reason: "没有机器清单")
            return
        }
        guard !machine.addresses.isEmpty else {
            phase = .failed("连不上 \(machine.label)。没有可用地址。")
            HerdrSignposts.markConnectFailed(reason: "没有可用地址")
            return
        }
        phase = .connecting
        HerdrSignposts.markConnectStart(machine: machine.label)
        let seed: Data
        do { seed = try HerdrDeviceKey.seed() } catch {
            phase = .failed("\(error.localizedDescription)")
            HerdrSignposts.markConnectFailed(reason: error.localizedDescription)
            return
        }

        // 并发竞速试连：LAN / Tailscale / 公网同时探测，首个成功者即刻胜出解阻塞
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<(winner: ProbeResult?, outcomes: [ProbeOutcome]), Never>) in
            let coordinator = ProbeRaceCoordinator(totalExpected: machine.addresses.count, continuation: continuation)
            var spawnedTasks: [Task<Void, Never>] = []

            for address in machine.addresses {
                let task = Task {
                    var candidate = SSHEndpoint(
                        host: address.host,
                        port: address.port,
                        username: machine.username,
                        auth: .ed25519Seed(seed),
                        hostKeyCheck: HerdrHostPins.check(machine: machine.id)
                    )
                    candidate.connectTimeoutSeconds = 10
                    if let via = address.via {
                        candidate.via = SSHJump(host: via.host, port: via.port, hostKeyCheck: HerdrHostPins.check(machine: via.machine))
                    }
                    do {
                        try Task.checkCancellation()
                        try await candidate.probe()
                        coordinator.addOutcome(.success(ProbeResult(address: address, candidate: candidate)))
                    } catch {
                        let text = "\(error)"
                        let isHostKey = error is SSHHostKeyRejected || text.contains("SSHHostKeyRejected")
                        let isAuth = text.lowercased().contains("allauthenticationoptionsfailed")
                        coordinator.addOutcome(.failure(address, text, isHostKey, isAuth))
                    }
                }
                spawnedTasks.append(task)
            }
            coordinator.attachTasks(spawnedTasks)
        }

        guard current == generation else {
            HerdrSignposts.cancelConnect()
            return
        }

        if let winner = outcome.winner {
            var candidate = winner.candidate
            candidate.connectTimeoutSeconds = 15
            routeLabel = winner.address.label
            endpoint = candidate
            await loadTree(candidate, generation: current)
            return
        }

        var sawHostKey = false
        var sawAuth = false
        var errors: [String] = []

        for item in outcome.outcomes {
            if case .failure(let addr, let text, let isHostKey, let isAuth) = item {
                if isHostKey { sawHostKey = true }
                if isAuth { sawAuth = true }
                errors.append("\(addr.label)：\(text)")
            }
        }

        if sawHostKey {
            phase = .hostKeyChanged
            HerdrSignposts.markConnectFailed(reason: "hostKeyChanged")
        } else if sawAuth {
            phase = .needsAuthorization
            HerdrSignposts.markConnectFailed(reason: "needsAuthorization")
        } else {
            let detail = errors.joined(separator: "；")
            phase = .failed(detail.isEmpty ? "没有可用地址。" : "连不上 \(machine.label)。\(detail)")
            HerdrSignposts.markConnectFailed(reason: detail)
        }
    }

    /// 验收用：`--ui-herdr-demo` 时不连任何机器，直接喂一份假快照，好在模拟器里看队列和终端布局。
    func loadDemo() {
        HerdrSignposts.markConnectStart(machine: "demo")
        let json = """
        {"version":"0.9.3","protocol":1,"focused_workspace_id":"w1","focused_tab_id":"t1","focused_pane_id":"p1",
         "workspaces":[{"workspace_id":"w1","number":1,"label":"AI_Work_System","focused":true,"pane_count":4,"tab_count":4,"active_tab_id":"t1","agent_status":"blocked"}],
         "tabs":[{"tab_id":"t1","workspace_id":"w1","number":1,"label":"Rex vs Herdr","focused":true,"pane_count":1,"agent_status":"blocked"}],
         "panes":[
          {"pane_id":"p1","terminal_id":"term_1","workspace_id":"w1","tab_id":"t1","focused":true,"cwd":"/Users/eddiegao/AI_Work_System","agent":"claude","agent_status":"blocked","terminal_title_stripped":"Com 终端改版"},
          {"pane_id":"p2","terminal_id":"term_2","workspace_id":"w1","tab_id":"t1","focused":false,"cwd":"/Users/eddiegao/AI_Work_System","agent":"pi","agent_status":"working","terminal_title_stripped":"pi·herdr接口核对"},
          {"pane_id":"p3","terminal_id":"term_3","workspace_id":"w1","tab_id":"t1","focused":false,"cwd":"/Users/eddiegao/AI_Work_System","agent":"agy","agent_status":"done","terminal_title_stripped":"agy·终端代码审查"},
          {"pane_id":"p4","terminal_id":"term_4","workspace_id":"w1","tab_id":"t1","focused":false,"cwd":"/Users/eddiegao","agent":null,"agent_status":"unknown","terminal_title_stripped":"zsh"}],
         "agents":[],"layouts":[]}
        """
        machines = [HerdrMachine(id: "mbp", label: "MBP", username: "eddiegao", addresses: []),
                    HerdrMachine(id: "mini", label: "mini", username: "eddiegao", addresses: [])]
        selectedMachineId = machines.first?.id ?? "mbp"
        snapshot = try? JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
        endpoint = SSHEndpoint(host: "127.0.0.1", port: 1, username: "demo", auth: .ed25519Seed(Data(count: 32)))
        routeLabel = "演示"
        phase = .connected
        HerdrSignposts.markTreeRendered()
    }

    func forgetHostKeyAndRetry() async {
        guard let machine = selectedMachine else { return }
        HerdrHostPins.forget(machine: machine.id)
        await connect()
    }

    func refresh() async {
        guard let activeClient = client, phase == .connected else { return }
        let current = generation
        snapshotSequence += 1
        let seq = snapshotSequence
        if let fresh = try? await activeClient.snapshot() {
            guard !Task.isCancelled,
                  current == generation,
                  client === activeClient,
                  phase == .connected,
                  seq >= committedSnapshotSequence else { return }
            committedSnapshotSequence = seq
            snapshot = fresh
        }
    }

    /// 150ms 会话树事件刷新防抖合并缓冲，避免密集事件触发频繁全树重新渲染
    func scheduleDebouncedRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }

    func disconnect() {
        generation += 1
        snapshotSequence += 1
        committedSnapshotSequence = snapshotSequence
        eventsTask?.cancel()
        eventsTask = nil
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        if let client { Task { await client.stop() } }
        client = nil
        snapshot = nil
        endpoint = nil
        routeLabel = ""
        phase = .idle
        HerdrSignposts.cancelConnect()
    }

    /// 地址已验证能用。树读不到也不挡终端：完整 herdr 不依赖它。
    private func loadTree(_ endpoint: SSHEndpoint, generation current: Int) async {
        guard current == generation else { return }
        let client = HerdrClient(transport: SSHExecTransport(endpoint: endpoint))
        self.client = client
        phase = .connected
        let freshSnapshot = try? await client.snapshot()
        guard current == generation else {
            await client.stop()
            return
        }
        snapshotSequence += 1
        committedSnapshotSequence = snapshotSequence
        self.snapshot = freshSnapshot
        HerdrSignposts.markTreeRendered()
        let events = await client.events()
        guard current == generation else {
            await client.stop()
            return
        }
        try? await client.subscribe(["workspace.updated", "tab.focused", "pane.focused", "pane.updated", "pane.created", "pane.closed"].map {
            .object(["type": .string($0)])
        })
        guard current == generation else {
            await client.stop()
            return
        }
        eventsTask = Task { [weak self] in
            for await _ in events {
                guard let self, !Task.isCancelled else { return }
                self.scheduleDebouncedRefresh()
            }
        }
    }
}

// MARK: - 并发探测结果与竞速协调器

private struct ProbeResult: Sendable {
    let address: HerdrMachine.Address
    let candidate: SSHEndpoint
}

private enum ProbeOutcome: Sendable {
    case success(ProbeResult)
    case failure(HerdrMachine.Address, String, Bool, Bool)
}

private final class ProbeRaceCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var winner: ProbeResult?
    private var allOutcomes: [ProbeOutcome] = []
    private let totalExpected: Int
    private var continuation: CheckedContinuation<(winner: ProbeResult?, outcomes: [ProbeOutcome]), Never>?
    private var tasks: [Task<Void, Never>] = []

    init(totalExpected: Int, continuation: CheckedContinuation<(winner: ProbeResult?, outcomes: [ProbeOutcome]), Never>) {
        self.totalExpected = totalExpected
        self.continuation = continuation
    }

    func attachTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        self.tasks = tasks
        let isDone = (continuation == nil)
        lock.unlock()
        if isDone {
            for t in tasks { t.cancel() }
        }
    }

    func addOutcome(_ outcome: ProbeOutcome) {
        lock.lock()
        allOutcomes.append(outcome)

        if case .success(let res) = outcome, winner == nil {
            winner = res
            let cont = continuation
            continuation = nil
            let toCancel = tasks
            lock.unlock()

            // 立即中断所有其他并发探测
            for t in toCancel { t.cancel() }
            cont?.resume(returning: (res, allOutcomes))
            return
        }

        // 所有候选均已返回且无胜出者
        if allOutcomes.count >= totalExpected, let cont = continuation {
            let finalWinner = winner
            let finalOutcomes = allOutcomes
            continuation = nil
            lock.unlock()
            cont.resume(returning: (finalWinner, finalOutcomes))
            return
        }
        lock.unlock()
    }
}
