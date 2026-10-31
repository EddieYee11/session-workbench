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
        /// 灵动岛 compact / 锁屏一眼可读的短标题（≤16 字）。
        var headline: String
        /// 深链后缀：waiting / plan / today / cases / voice（拼成 com-eddie://…）。
        var deepLink: String

        enum CodingKeys: String, CodingKey {
            case mood, caption, waiting, running, urgent, since, headline, deepLink
        }

        init(mood: String, caption: String, waiting: Int, running: Int, urgent: Int, since: Date?,
             headline: String = "", deepLink: String = "plan") {
            self.mood = mood; self.caption = caption; self.waiting = waiting
            self.running = running; self.urgent = urgent; self.since = since
            self.headline = headline; self.deepLink = deepLink
        }

        /// 旧 Live Activity 没有 headline/deepLink 时仍能解码。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mood = try c.decode(String.self, forKey: .mood)
            caption = try c.decode(String.self, forKey: .caption)
            waiting = try c.decode(Int.self, forKey: .waiting)
            running = try c.decode(Int.self, forKey: .running)
            urgent = try c.decode(Int.self, forKey: .urgent)
            since = try c.decodeIfPresent(Date.self, forKey: .since)
            headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
            deepLink = try c.decodeIfPresent(String.self, forKey: .deepLink) ?? "plan"
        }
    }
}
