import SwiftUI
import WidgetKit
import AppIntents

@main struct ComControls: WidgetBundle {
    var body: some Widget { ComVoiceControl() }
}

struct ComVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "work.eddie.com.voice") {
            ControlWidgetButton(action: OpenComVoice()) {
                Label("语音指令", systemImage: "waveform")
            }
        }
        .displayName("Com 语音小窗")
        .description("打开光效录音面板，转写后确认发送语音指令。")
    }
}
