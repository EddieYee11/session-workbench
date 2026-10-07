import AppIntents
import Foundation

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
extension Notification.Name { static let comVoiceIntent = Notification.Name("com.voice.intent") }
