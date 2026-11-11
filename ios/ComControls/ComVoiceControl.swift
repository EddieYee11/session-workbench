import SwiftUI
import WidgetKit

@main struct ComControls: WidgetBundle {
    // 轨道 r3-memory：灵动岛常驻挂在现有扩展里，不另建 target（免费团队每 7 天只能新建 10 个 App ID）。
    // 注意：不在 Widget 扩展中重复编译 AppIntents (OpenComVoice)，避免与主 App 的 Metadata.appintents 产生同名 Action 冲突导致 iOS linkd 索引失效。
    var body: some Widget { ComStatusWidget(); ComLiveActivityWidget() }
}
