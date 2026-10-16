import Foundation
import ComCore

// 轨道 agent：记忆页的「最近自动学到」与待确认收件箱。
// 后端 /personal/memory-inbox：learned = 已自动写入、还没被你看过的；pending = 等你批准才写入的。
extension AppModel {
    static let memoryInboxPath = "/personal/memory-inbox"

    func loadMemoryInbox() async {
        #if DEBUG
        if isUITesting && datasets[Self.memoryInboxPath] == nil { seedMemoryInboxPreview() }
        #endif
        _ = await load(Self.memoryInboxPath)
    }

    /// action：confirm（没错 / 记住）、correct（纠正后保存）、delete（删掉=归档，可在历史版本里找回；待确认的则直接丢弃）。
    func actOnLearned(_ id: String, action: String, content: String = "") async {
        #if DEBUG
        if isUITesting {
            var inbox = datasets[Self.memoryInboxPath] ?? .object([:])
            let waiting = inbox["pending"].array.first { $0.id == id }
            let learnedMemory = inbox["learned"].array.first { $0.id == id }?["memory_id"].string ?? ""
            for key in ["learned", "pending"] { inbox[key] = .array(inbox[key].array.filter { $0.id != id }) }
            datasets[Self.memoryInboxPath] = inbox
            // 和后端一样（memory_inbox.act）：待确认的「记住 / 纠正」会写成一条新记忆，出现在所属文件夹里（轨道 r3-memory）。
            if let waiting, action == "confirm" || action == "correct" {
                var memory = datasets["/personal/memory"] ?? .object([:])
                let saved = JSON.object(["id": .string("memory-" + id), "category": waiting["category"], "version": .number(1),
                                         "content": .string(action == "correct" ? content : waiting["content"].string),
                                         "updated_at": .number(Date().timeIntervalSince1970), "source": .object(["type": .string("auto_learned")])])
                memory["items"] = .array([saved] + memory["items"].array)
                datasets["/personal/memory"] = memory
            }
            // 删掉自动学到的：后端把那条记忆归档，列表里就不再有它。
            if action == "delete", !learnedMemory.isEmpty, var memory = datasets["/personal/memory"] {
                memory["items"] = .array(memory["items"].array.filter { $0.id != learnedMemory })
                datasets["/personal/memory"] = memory
            }
            Haptics.selection(); return
        }
        #endif
        do {
            _ = try await mutate(Self.memoryInboxPath + "/" + id.pathEncoded, fields: ["action": .string(action), "content": .string(content)])
            Haptics.selection()
        } catch { banner = error.localizedDescription }
        _ = await load(Self.memoryInboxPath)
        _ = await load("/personal/memory")
    }

    #if DEBUG
    func seedMemoryInboxPreview() {
        let now = Date().timeIntervalSince1970
        func item(_ id: String, _ content: String, _ quote: String, _ category: String, _ ago: Double, memory: String = "") -> JSON {
            .object(["id": .string(id), "content": .string(content), "quote": .string(quote), "category": .string(category),
                     "type": .string("preference"), "created_at": .number(now - ago), "memory_id": .string(memory)])
        }
        datasets[Self.memoryInboxPath] = .object([
            "learned": .array([
                item("learn-short", "Eddie 偏好 1–3 句的简短回复，先给结论", "回复短一点，先说结论", "关于我", 1800, memory: "memory-3"),
                item("learn-climb", "Eddie 每周二、周四晚上去攀岩", "我周二周四晚上都去攀岩", "生活", 7200, memory: "memory-2"),
                item("learn-com", "Eddie 正在把 Com 做成会主动找他的个人助理", "我想让 Com 主动给我发提醒", "项目", 86400),
            ]),
            "pending": .array([
                item("pending-health", "Eddie 晚上 11 点后不想收到消息", "11 点以后别打扰我", "生活", 3600),
            ]),
        ])
    }

    /// 轨道 r3-memory 的验收数据，只在 UI 测试里按启动参数铺一次：
    /// `--ui-r3-folders` 七个文件夹各放几张纸，外加一个没登记的分类（看英文兜底）；`--ui-r3-review` 多放几条待你过目的。
    func seedR3MemoryPreview() {
        guard isUITesting else { return }
        let args = ProcessInfo.processInfo.arguments
        let now = Date().timeIntervalSince1970
        if args.contains("--ui-r3-folders"), datasets["/personal/memory"]?["r3"].bool != true {
            let rows: [(String, String, String)] = [
                ("r3-me-1", "关于我", "沟通直接一点，重要的事用结果说话。"), ("r3-me-2", "关于我", "偏好 1–3 句的短回复，先给结论。"),
                ("r3-work", "工作", "搜狐户外的周报每周五下午交。"), ("r3-create", "创作", "口播先定叙事结构，再定画面和剪辑节奏。"),
                ("r3-skill", "技能", "排障先看实时端口和进程，再动配置。"), ("r3-device", "设备", "Mac mini 常驻在线，NAS 走 Tailscale。"),
                ("r3-project", "项目", "Com 要做成会主动找人的个人助理。"), ("r3-life", "生活", "每周二、周四晚上去攀岩。"),
                ("r3-trip", "旅行", "川西摩旅的素材按天整理在素材盘。"),
            ]
            datasets["/personal/memory"] = .object(["r3": .bool(true), "items": .array(rows.enumerated().map { index, row in
                .object(["id": .string(row.0), "folder": .string(row.1), "content": .string(row.2), "version": .number(1),
                         "updated_at": .number(now - Double(index) * 900), "source": .object(["type": .string("conversation")])])
            })])
        }
        if args.contains("--ui-r3-review"), datasets[Self.memoryInboxPath]?["r3"].bool != true {
            func item(_ id: String, _ content: String, _ quote: String, _ category: String, _ ago: Double) -> JSON {
                .object(["id": .string(id), "content": .string(content), "quote": .string(quote), "category": .string(category),
                         "type": .string("preference"), "created_at": .number(now - ago)])
            }
            datasets[Self.memoryInboxPath] = .object([
                "r3": .bool(true),
                "pending": .array([
                    item("r3-pending-night", "Eddie 晚上 11 点后不想收到消息", "11 点以后别打扰我", "生活", 600),
                    item("r3-pending-money", "Eddie 每月 5 号前对一次账", "每个月 5 号之前帮我对下账", "生活", 1800),
                ]),
                "learned": .array([
                    item("r3-learn-short", "Eddie 偏好 1–3 句的简短回复，先给结论", "回复短一点，先说结论", "关于我", 3600),
                    item("r3-learn-climb", "Eddie 每周二、周四晚上去攀岩", "我周二周四晚上都去攀岩", "生活", 7200),
                    item("r3-learn-com", "Eddie 正在把 Com 做成会主动找他的个人助理", "我想让 Com 主动给我发提醒", "项目", 86400),
                ]),
            ])
        }
    }
    #endif
}
