import ActivityKit
import SwiftUI
import UIKit
import ComCore

/// 灵动岛常驻（轨道 r3-memory）。
/// - 已配对时保证有且只有一个 Com 的 Live Activity：回到前台、将要进后台都查一遍，复用已有的，多出来的结束掉。
///   ActivityKit 只许在前台发起，所以「进后台时开」落在 inactive 那一刻（还算前台）；系统 8 小时结束后，下次进出前台会重新开。
/// - 前台、以及进后台那一小段还能跑的时间里，跟着 AppModel 的可观察状态更新（说明、等你点头、在跑、该做、计时起点）。
///   进后台后 App 自己断开实时连接，舞台会变成「正在恢复连接」——那不是真的出问题，不推上去，灵动岛停在进后台那一刻。
/// - 取消配对立即结束。
/// 免费开发者账号没有 APNs，做不了推送更新：App 被挂起后内容停在最后一次，靠 Text(timerInterval:) 自己走秒；
/// 在跑的内容 30 分钟后标过时（系统据此让界面改说「点开看最新」）。
@MainActor final class ComLiveActivity {
    static let shared = ComLiveActivity()
    private typealias State = ComActivityAttributes.ContentState
    private weak var model: AppModel?
    private var last: State?
    private var busySince: Date?
    private var runningSince: Date?
    private var started = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// UI 测试里演示一遍状态变化（`--ui-r3-live`），进后台后也照样推。
    private var demo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-r3-live")
        #else
        false
        #endif
    }

    private var activities: [Activity<ComActivityAttributes>] {
        Activity<ComActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    func start(_ model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        // 别的 UI 测试不碰灵动岛。
        guard !model.isUITesting || demo else { return }
        observe()
        ensure()
    }

    /// 接在 ComApp 的 scenePhase 上：active / inactive 都还在前台，能开就开；background 时把这一刻推上去。
    func scene(_ phase: ScenePhase) {
        guard let model, !model.isUITesting || demo else { return }
        switch phase {
        case .active, .inactive: ensure()
        case .background: enterBackground()
        @unknown default: break
        }
    }

    private func observe() {
        withObservationTracking {
            _ = state()
            _ = model?.active
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.changed()
                self.observe()
            }
        }
    }

    private func changed() {
        guard let model else { return }
        guard model.isPaired else { endAll(); return }
        guard model.active || demo, let state = state() else { return }
        push(state)
    }

    /// 已配对就保证有一个；多的结束掉；被系统结束了（8 小时）或被划掉了就重新开。
    private func ensure() {
        guard let state = state() else { endAll(); return }
        // 已经结束的那个会在锁屏上留到 4 小时：直接收掉，免得和新开的并排出现两个。
        for ended in Activity<ComActivityAttributes>.activities where ended.activityState == .ended {
            nonisolated(unsafe) let ended = ended
            Task { await ended.end(nil, dismissalPolicy: .immediate) }
        }
        let alive = activities
        if let keep = alive.first {
            for extra in alive.dropFirst() {
                nonisolated(unsafe) let extra = extra
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
            push(state, to: [keep])
            return
        }
        // 没有活着的 Activity：清掉 last，免得后面假以为岛上已是最新而不重开。
        last = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            model?.liveActivityNote = "系统关闭了实时活动——灵动岛不会更新。到「设置 › 面容 ID 与密码 / 实时活动」打开后再回 Com；不会假装岛上还在跳。"
            return
        }
        do {
            _ = try Activity.request(attributes: ComActivityAttributes(), content: content(state), pushType: nil)
            last = state
            model?.liveActivityNote = ""
        } catch {
            // 不在前台，或请求失败：不清成成功；下次回到前台 / 将要进后台再试。
            model?.liveActivityNote = "灵动岛没开上：\(error.localizedDescription)——回到前台会再试。不会假装已挂上。"
        }
    }

    /// 进后台：这一刻 setActive(false) 还没跑（它在随后的 Task 里），状态还是真的；向系统要一点时间把这次更新推完。
    private func enterBackground() {
        guard let model, model.isPaired, let state = state() else { endAll(); return }
        let alive = activities
        guard !alive.isEmpty else {
            // 没有活岛：不要写 last 假装已推上；ensure 会在下次前台开口。
            last = nil
            return
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "work.eddie.com.live-activity") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        Task {
            for activity in alive {
                nonisolated(unsafe) let activity = activity
                await activity.update(content(state))
            }
            // update 成功后才记住：挂起后若没活岛，下次前台 ensure 会重开而不是跳过。
            last = state
            model.liveActivityNote = ""
            #if DEBUG
            if demo { await runDemo() }
            #endif
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// 只有目标 Activity 真的还活着才推进 `last`。空列表时旧版也会写 last → 之后状态变了不再重试 = 假成功。
    private func push(_ state: State, to targets: [Activity<ComActivityAttributes>]? = nil) {
        let list = targets ?? activities
        guard !list.isEmpty else {
            last = nil
            return
        }
        guard state != last else { return }
        last = state
        model?.liveActivityNote = ""
        for activity in list {
            nonisolated(unsafe) let activity = activity
            Task { await activity.update(content(state)) }
        }
    }

    private func endAll() {
        last = nil; busySince = nil; runningSince = nil
        if model?.isPaired == false { model?.liveActivityNote = "" }
        for activity in Activity<ComActivityAttributes>.activities {
            nonisolated(unsafe) let activity = activity
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func content(_ state: State) -> ActivityContent<State> {
        ActivityContent(state: state, staleDate: state.since == nil ? nil : Date().addingTimeInterval(30 * 60))
    }

    /// 从 AppModel 现有的可观察状态取数：顶栏角色的状态与那句话、等你点头（decisionCount）、在跑（runningTasks / 舞台在忙）、该做（nextUrgentCount）。
    private func state() -> State? {
        guard let model, model.isPaired else { return nil }
        let tasks = model.runningTasks
        let thinking = model.stage.state.isBusy
        let running = max(tasks.count, thinking ? 1 : 0)
        busySince = thinking ? (busySince ?? Date()) : nil
        runningSince = running > 0 ? (runningSince ?? busySince ?? Date()) : nil
        // 电脑上的任务有创建时间就从那一刻算，计时才是真的「跑了多久」。
        let taskStart = tasks.map { $0["created_at"].double }.filter { $0 > 0 }.min().map { Date(timeIntervalSince1970: $0) }
        return State(mood: model.stripState.rawValue, caption: model.stripCaption, waiting: model.waitingInboxCount,
                     running: running, urgent: model.nextUrgentCount, since: running > 0 ? (taskStart ?? runningSince) : nil)
    }

    #if DEBUG
    /// `--ui-r3-live`：进后台后按真实事件把状态走一遍，录屏看灵动岛的更新过渡。
    private func runDemo() async {
        guard let model, model.isUITesting else { return }
        let now = Date().timeIntervalSince1970
        func tasks(_ rows: [(String, String, Double)]) {
            model.datasets["/personal/tasks"] = .object(["items": .array(rows.map { row in
                .object(["id": .string(row.0), "title": .string("演示任务"), "status": .string(row.1), "created_at": .number(now - row.2), "updated_at": .number(now)])
            })])
            model.recomputeFlow()
        }
        model.datasets["/personal/connectors"] = .object(["sources": .array([])])
        try? await Task.sleep(for: .seconds(3))
        tasks([]); model.stage.receive("task.progress", .object(["kind": .string("thinking")]))
        try? await Task.sleep(for: .seconds(4))
        tasks([("demo-a", "running", 95), ("demo-b", "running", 40)]); model.stage.receive("task.progress", .object(["kind": .string("working")]))
        try? await Task.sleep(for: .seconds(5))
        tasks([("demo-a", "waiting", 300), ("demo-b", "approval_required", 200)]); model.stage.receive("task.progress", .object(["kind": .string("idle")]))
        try? await Task.sleep(for: .seconds(4))
        tasks([]); model.stage.receive("agent.push", .object(["message_id": .string("demo-delivery"), "preview": .string("整理好了")]))
        try? await Task.sleep(for: .seconds(3))
        model.stage.receive("task.progress", .object(["kind": .string("idle")])); model.stage.tick()
        try? await Task.sleep(for: .seconds(3))
    }
    #endif
}
