import SwiftUI
import AppIntents

@main struct ComApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environment(model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in Task { await model.setActive(phase == .active) } }
                .onOpenURL { url in
                    guard url.scheme == "com-eddie" else { return }
                    if url.host == "voice" { model.openVoice(quick: true) }
                    if url.host == "share", let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value {
                        model.tab = .chat; model.draft = model.draft.isEmpty ? text : model.draft + "\n\n" + text; model.persistNow()
                    }
                }
        }
    }
}

struct OpenComVoice: AppIntent {
    static let title: LocalizedStringResource = "打开 Com 语音"
    static let description = IntentDescription("打开 Com 录音小窗，录完转写，确认后发送。可绑定 iPhone 操作按钮。")
    static var supportedModes: IntentModes { .foreground(.immediate) }
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "openVoiceIntent")
        NotificationCenter.default.post(name: .comVoiceIntent, object: nil)
        return .result()
    }
}
struct ComShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenComVoice(), phrases: ["打开 \(.applicationName) 语音"], shortTitle: "Com 语音", systemImageName: "waveform")
    }
}
extension Notification.Name { static let comVoiceIntent = Notification.Name("com.voice.intent") }
