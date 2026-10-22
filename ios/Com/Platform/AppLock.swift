import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// 应用锁：离开前台超过宽限期后，回到 App 先要一次系统认证；切后台时先盖一层，避免任务切换器截图里露出对话。
/// 只保护本机界面，不改变服务端权限；认证不可用时回退到设备密码，仍不可用则保持盖住并给出「重试」。
@MainActor @Observable final class AppLock {
    static let shared = AppLock()

    private(set) var locked = false
    private(set) var covered = false
    private(set) var authenticating = false
    private(set) var message = ""

    /// 离开前台多久后重新上锁；太短会在切到相机/通知中心再回来时频繁打扰。
    static let grace: TimeInterval = 30
    private var leftAt: Date?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "appLockEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "appLockEnabled")
            if !newValue { locked = false; covered = false }
        }
    }

    /// 系统能不能做认证；设置页用它决定是否显示开关。
    var available: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    var isCovering: Bool { covered || locked }

    func scene(_ phase: ScenePhase, paired: Bool) {
        switch phase {
        case .inactive:
            // 切到任务切换器/控制中心前先盖住，截图里不出现正文。
            if enabled && paired { covered = true }
        case .background:
            if enabled && paired { leftAt = Date(); covered = true }
        case .active:
            covered = false
            guard enabled, paired else { locked = false; return }
            let away = Date().timeIntervalSince(leftAt ?? .distantPast)
            if locked || away >= Self.grace { locked = true; Task { await unlock() } }
        @unknown default:
            break
        }
    }

    func unlock() async {
        guard locked, !authenticating else { return }
        authenticating = true; message = ""
        defer { authenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = "先不进去"
        context.localizedFallbackTitle = "用设备密码"
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 Com，查看你的对话与 Agent 状态")
            if ok { locked = false }
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel {
            message = "已取消；内容保持隐藏。"
        } catch {
            message = "无法认证：\(error.localizedDescription)"
        }
    }

    func lockNow() {
        guard enabled else { return }
        locked = true
    }
}

/// 盖住整屏的锁：不渲染任何会话内容，只有淡淡的角色与一个解锁按钮。
struct LockScreen: View {
    @Environment(AppLock.self) private var lock
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: Space.lg) {
                Image(systemName: "lock.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                Text("Com 已上锁").font(TypeScale.title)
                Text(lock.message.isEmpty ? "解锁后继续查看对话与 Agent 状态。" : lock.message)
                    .font(TypeScale.callout).foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, Space.xxl)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    HStack(spacing: Space.sm) {
                        if lock.authenticating { ProgressView().controlSize(.small) }
                        Text(lock.authenticating ? "正在认证…" : "解锁").font(TypeScale.callout.weight(.semibold))
                    }.frame(maxWidth: 220)
                }
                .buttonStyle(.primaryFull)
                .disabled(lock.authenticating)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Com 已上锁")
    }
}
