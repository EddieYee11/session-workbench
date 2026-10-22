import Foundation

/// 语音里的控制词：只认整句，避免「停下想一想」被当成停止指令。
/// 停在转写之后、进发送队列之前；录音仍留在本机，可再次打开继续。
enum VoiceCommands {
    static let stopPhrases: Set<String> = [
        "停", "停下", "停止", "停止录音", "不说了", "不用了", "结束", "结束吧", "退出", "取消",
        "好了", "先这样", "就这样", "可以了",
        "stop", "stop listening", "cancel", "never mind", "nevermind", "that's all", "thats all", "we're done",
    ]

    /// 去掉首尾标点、空白和语气词后再比；整句必须正好是控制词。
    static func isStop(_ text: String) -> Bool {
        var value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        for filler in ["好的", "好", "那", "嗯", "okay", "ok", "hey", "com", "please"] {
            if value == filler { return false }
            if value.hasPrefix(filler + " ") || value.hasPrefix(filler + "，") { value = String(value.dropFirst(filler.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return stopPhrases.contains(value)
    }

    /// 设置页里可调的「停顿多久自动发送」，0.5–2.0 秒。
    static var pauseToSend: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "voice.pauseToSend")
        return value > 0 ? min(2, max(0.4, value)) : 0.9
    }
}
