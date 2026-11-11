import Foundation
import os

/// Herdr 性能监控打点（os_signpost）
/// 测量：
/// 1. App 冷启动到首帧渲染耗时 (ColdLaunchToFirstFrame)
/// 2. 连上到会话树呈现耗时 (ConnectToTreeAppearance)
@MainActor
public enum HerdrSignposts {
    public static let poster = OSSignposter(subsystem: "work.eddie.herdr", category: "Performance")

    // MARK: - 1. 冷启动到首帧渲染
    private static let launchSignpostID = poster.makeSignpostID()
    private static var launchState: OSSignpostIntervalState?
    private static var launchStartTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    public static private(set) var launchDurationMs: Double?

    public static func markLaunchStart() {
        guard launchState == nil else { return }
        launchStartTime = ProcessInfo.processInfo.systemUptime
        launchState = poster.beginInterval("ColdLaunchToFirstFrame", id: launchSignpostID)
    }

    public static func markFirstFrameRendered() {
        if let state = launchState {
            poster.endInterval("ColdLaunchToFirstFrame", state)
            launchState = nil
            let duration = max(0.5, (ProcessInfo.processInfo.systemUptime - launchStartTime) * 1000)
            launchDurationMs = duration
            print("[HerdrSignpost] Cold launch to first frame: \(String(format: "%.1f", duration)) ms")
            fflush(stdout)
        }
    }

    // MARK: - 2. 连接到会话树呈现
    private static let connectSignpostID = poster.makeSignpostID()
    private static var connectState: OSSignpostIntervalState?
    private static var connectStartTime: TimeInterval = 0
    public static private(set) var connectDurationMs: Double?

    public static func markConnectStart(machine: String) {
        if let state = connectState {
            poster.endInterval("ConnectToTreeAppearance", state, "superseded")
            connectState = nil
        }
        connectStartTime = ProcessInfo.processInfo.systemUptime
        connectState = poster.beginInterval("ConnectToTreeAppearance", id: connectSignpostID, "machine: \(machine)")
    }

    public static func markTreeRendered() {
        if let state = connectState {
            poster.endInterval("ConnectToTreeAppearance", state)
            connectState = nil
            let duration = (ProcessInfo.processInfo.systemUptime - connectStartTime) * 1000
            connectDurationMs = duration
            print("[HerdrSignpost] Connect to session tree presented: \(String(format: "%.1f", duration)) ms")
            fflush(stdout)
        }
    }

    public static func markConnectFailed(reason: String = "") {
        if let state = connectState {
            poster.endInterval("ConnectToTreeAppearance", state, "failed: \(reason)")
            connectState = nil
            let duration = (ProcessInfo.processInfo.systemUptime - connectStartTime) * 1000
            connectDurationMs = duration
            print("[HerdrSignpost] Connect failed after \(String(format: "%.1f", duration)) ms: \(reason)")
            fflush(stdout)
        }
    }

    public static func cancelConnect() {
        if let state = connectState {
            poster.endInterval("ConnectToTreeAppearance", state, "cancelled")
            connectState = nil
        }
    }
}
