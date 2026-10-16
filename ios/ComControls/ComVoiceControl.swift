import SwiftUI
import WidgetKit
import AppIntents

@main struct ComControls: WidgetBundle {
    // 轨道 r3-memory：灵动岛常驻挂在现有扩展里，不另建 target（免费团队每 7 天只能新建 10 个 App ID）。
    var body: some Widget { ComVoiceControl(); ComStatusWidget(); ComLiveActivityWidget() }
}

struct ComVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "work.eddie.com.voice") {
            ControlWidgetButton(action: OpenComVoice()) {
                Label("语音指令", systemImage: "waveform")
            }
        }
        .displayName("Com 语音小窗")
        .description("打开光效录音面板，转写为文字后自动发送。")
    }
}
