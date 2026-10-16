import ActivityKit
import Foundation

/// 灵动岛 / 锁屏上常驻的 Com（轨道 r3-memory）。主 App 和 ComControls 扩展各编一份。
/// 免费开发者账号没有 APNs：只能 App 自己发起、自己更新，内容就是 App 最后一次看到的样子。
struct ComActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 角色状态：顶栏 StripState 的 rawValue（idle / read / think / exec / send / ask / done / broken）。
        var mood: String
        /// 一行状态说明，和顶栏角色说的那句一样。
        var caption: String
        /// 等你点头的件数。
        var waiting: Int
        /// 在跑的件数：电脑上的任务；Com 自己正在想也算一件。
        var running: Int
        /// 「下一步」里现在就该做的件数。
        var urgent: Int
        /// 在跑时从这一刻起计时；不在跑为 nil。
        var since: Date?
    }
}
