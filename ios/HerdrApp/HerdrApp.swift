import SwiftUI
import UIKit
import ComCore

final class HerdrAppDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = [.portrait, .landscapeRight, .landscapeLeft]
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return Self.supportedOrientations
    }
}

@main struct HerdrApp: App {
    @UIApplicationDelegateAdaptor(HerdrAppDelegate.self) private var appDelegate
    @State private var store = HerdrSessionStore()
    @State private var backend = HeaderModel()
    @State private var posture = DuoPosture()
    @State private var creaseTick = 0
    @Environment(\.scenePhase) private var scenePhase

    init() {
        HerdrSignposts.markLaunchStart()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if backend.isPaired || ProcessInfo.processInfo.arguments.contains("--ui-herdr-demo") {
                    HerdrTerminalSurface()
                } else {
                    PairView()
                }
            }
            .environment(\.herdrBackend, backend)
            .environment(backend)
            .environment(store)
            .environment(posture)
            .background {
                CreaseProbe(tick: creaseTick) { crease in
                    posture.creaseRect = crease
                }
            }
            .modifier(HingeWatch {
                creaseTick += 1
            })
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                let angle: Double = {
                    if let envAngle = ProcessInfo.processInfo.environment["HERDR_HINGE_ANGLE"].flatMap(Double.init) { return envAngle }
                    if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--hinge-angle=") }),
                       let val = Double(arg.dropFirst("--hinge-angle=".count)) { return val }
                    if let crease = posture.creaseRect, crease.width > 0, crease.height > 0 {
                        return (crease.width > crease.height) ? 90.0 : 135.0
                    }
                    return posture.hingeAngle
                }()
                posture.updateGeometry(width: size.width, height: size.height, crease: posture.creaseRect, angle: angle)
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--ui-herdr-demo") {
                    store.loadDemo()
                } else if backend.isPaired {
                    await store.prepare(backend: backend)
                }
                if ProcessInfo.processInfo.arguments.contains("--landscape") || ProcessInfo.processInfo.environment["HERDR_FORCE_LANDSCAPE"] == "1" {
                    for scene in UIApplication.shared.connectedScenes {
                        guard let windowScene = scene as? UIWindowScene else { continue }
                        let geometry = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscapeRight)
                        windowScene.requestGeometryUpdate(geometry) { _ in }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, store.phase == .connected {
                    Task { await store.refresh() }
                }
                if phase == .active, (ProcessInfo.processInfo.arguments.contains("--landscape") || ProcessInfo.processInfo.environment["HERDR_FORCE_LANDSCAPE"] == "1") {
                    for scene in UIApplication.shared.connectedScenes {
                        guard let windowScene = scene as? UIWindowScene else { continue }
                        let geometry = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscapeRight)
                        windowScene.requestGeometryUpdate(geometry) { _ in }
                    }
                }
            }
            .onOpenURL { url in
                guard url.scheme == "herdr-eddie" else { return }
                if url.host == "pair" {
                    backend.applyPairDeepLink(url)
                }
            }
        }
    }
}

/// 读折痕：iOS 27.1 起 GeometryProxy 能给出 .division 区域；只取活动的那条（半折叠），换成 id 重建来强制重读。
private struct CreaseProbe: View {
    let tick: Int
    let update: (CGRect?) -> Void
    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect?.self) { proxy in
                if #available(iOS 27.1, *) { return proxy.reservedRegions(kind: .division).first(where: \.isActive)?.frame }
                return nil
            } action: { update($0) }
            .id(tick)
    }
}

/// 铰链状态一变（合上 / 半折叠 / 完全展开）就让上面重读一次折痕。
private struct HingeWatch: ViewModifier {
    let changed: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) { content.onHingeChange { _, _ in changed() } } else { content }
    }
}
