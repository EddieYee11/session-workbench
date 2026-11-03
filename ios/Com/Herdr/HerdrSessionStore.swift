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

    private var client: HerdrClient?
    private var eventsTask: Task<Void, Never>?
    private var generation = 0

    var selectedMachine: HerdrMachine? { machines.first { $0.id == selectedMachineId } }

    /// 生成设备密钥、向后端登记公钥并取机器清单；后端暂时不通时用上次的缓存。
    func registerDeviceKey(model: AppModel) async {
        do {
            publicKey = try HerdrDeviceKey.publicLine()
        } catch {
            phase = .failed("\(error.localizedDescription)")
            return
        }
        if let result = try? await model.mutate("/remote/herdr/device-key", fields: ["public_key": .string(publicKey)]),
           let data = try? JSONEncoder().encode(result["machines"]),
           let fresh = try? JSONDecoder().decode([HerdrMachine].self, from: data), !fresh.isEmpty {
            machines = fresh
            HerdrMachineCache.save(fresh)
        }
    }

    func prepare(model: AppModel) async {
        await registerDeviceKey(model: model)
        if case .failed = phase { return }
        await connect()
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
            return
        }
        phase = .connecting
        let seed: Data
        do { seed = try HerdrDeviceKey.seed() } catch {
            phase = .failed("\(error.localizedDescription)")
            return
        }
        var lastError = ""
        for address in machine.addresses {
            var candidate = SSHEndpoint(
                host: address.host,
                port: address.port,
                username: machine.username,
                auth: .ed25519Seed(seed),
                hostKeyCheck: HerdrHostPins.check(machine: machine.id)
            )
            // 蜂窝网和跨机中转握手慢，外网优先时给足时间。
            candidate.connectTimeoutSeconds = 10
            if let via = address.via {
                candidate.via = SSHJump(host: via.host, port: via.port, hostKeyCheck: HerdrHostPins.check(machine: via.machine))
            }
            do {
                try await candidate.probe()
            } catch {
                guard current == generation else { return }
                let text = "\(error)"
                if error is SSHHostKeyRejected || text.contains("SSHHostKeyRejected") {
                    phase = .hostKeyChanged
                    return
                }
                if text.lowercased().contains("allauthenticationoptionsfailed") {
                    phase = .needsAuthorization
                    return
                }
                lastError = "\(address.label)：\(text)"
                continue
            }
            guard current == generation else { return }
            candidate.connectTimeoutSeconds = 15
            routeLabel = address.label
            endpoint = candidate
            await loadTree(candidate, generation: current)
            return
        }
        phase = .failed(lastError.isEmpty ? "没有可用地址。" : "连不上 \(machine.label)。\(lastError)")
    }

    func forgetHostKeyAndRetry() async {
        guard let machine = selectedMachine else { return }
        HerdrHostPins.forget(machine: machine.id)
        await connect()
    }

    func refresh() async {
        guard let client else { return }
        if let fresh = try? await client.snapshot() { snapshot = fresh }
    }

    func disconnect() {
        eventsTask?.cancel()
        eventsTask = nil
        if let client { Task { await client.stop() } }
        client = nil
        snapshot = nil
        endpoint = nil
        routeLabel = ""
        phase = .idle
    }

    /// 地址已验证能用。树读不到也不挡终端：完整 herdr 不依赖它。
    private func loadTree(_ endpoint: SSHEndpoint, generation current: Int) async {
        let client = HerdrClient(transport: SSHExecTransport(endpoint: endpoint))
        self.client = client
        phase = .connected
        snapshot = try? await client.snapshot()
        guard current == generation else {
            await client.stop()
            return
        }
        let events = await client.events()
        try? await client.subscribe(["workspace.updated", "tab.focused", "pane.focused", "pane.updated", "pane.created", "pane.closed"].map {
            .object(["type": .string($0)])
        })
        eventsTask = Task { [weak self] in
            for await _ in events {
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }
}
