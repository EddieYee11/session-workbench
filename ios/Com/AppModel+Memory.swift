import Foundation
import Observation
import ComCore

// MARK: - Muse 式核心真相文件（MEMORY.md / SOUL.md）与一键 /dream 状态仓

struct MemoryTruthFile: Identifiable, Equatable, Sendable {
    var name: String
    var title: String
    var content: String
    var updatedAt: Double
    var lineCount: Int

    var id: String { name }

    var shortLabel: String {
        switch name {
        case "MEMORY.md": "MEMORY.md"
        case "SOUL.md": "SOUL.md"
        default: name
        }
    }

    var roleSubtitle: String {
        switch name {
        case "MEMORY.md": "长期记忆"
        case "SOUL.md": "助理分寸"
        default: title
        }
    }
}

struct MemoryTruthBulletLine: Identifiable, Equatable, Sendable {
    let id: String
    let lineIndex: Int
    let rawLine: String
    let displayText: String
}

struct MemoryTruthSection: Identifiable, Equatable, Sendable {
    let id: String
    let heading: String
    let bullets: [MemoryTruthBulletLine]
}

struct MemoryDreamReport: Equatable, Sendable {
    var updated: Bool
    var summary: String
    var mergedCount: Int
    var archivedCount: Int
    var ranAt: Double
}

@MainActor
@Observable
final class MemoryTruthStore {
    static let shared = MemoryTruthStore()

    var files: [MemoryTruthFile] = [
        MemoryTruthFile(name: "MEMORY.md", title: "长期记忆 (MEMORY.md)", content: "", updatedAt: 0, lineCount: 0),
        MemoryTruthFile(name: "SOUL.md", title: "助理分寸 (SOUL.md)", content: "", updatedAt: 0, lineCount: 0),
    ]
    var selectedName: String = "MEMORY.md"
    var loading: Bool = false
    var saving: Bool = false
    var dreaming: Bool = false
    var forgettingIDs: Set<String> = []
    var hasLoaded: Bool = false
    var errorNote: String = ""
    var statusNote: String = ""
    var lastDream: MemoryDreamReport?

    var selectedFile: MemoryTruthFile {
        files.first(where: { $0.name == selectedName })
            ?? files.first
            ?? MemoryTruthFile(name: selectedName, title: selectedName, content: "", updatedAt: 0, lineCount: 0)
    }

    func sections(for content: String) -> [MemoryTruthSection] {
        let rawLines = content.components(separatedBy: .newlines)
        var out: [MemoryTruthSection] = []
        var currentHeading = ""
        var currentBullets: [MemoryTruthBulletLine] = []
        var inCodeFence = false

        func flushSection(index: Int) {
            guard !currentBullets.isEmpty else { return }
            let secID = "sec-\(index)-\(currentHeading)"
            out.append(MemoryTruthSection(id: secID, heading: currentHeading, bullets: currentBullets))
            currentBullets = []
        }

        for (idx, line) in rawLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                inCodeFence.toggle()
                continue
            }
            if inCodeFence || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                flushSection(index: idx)
                let cleanHeading = String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
                currentHeading = cleanHeading
                continue
            }
            if trimmed == "---" || trimmed == "***" { continue }

            let display = Self.cleanBulletText(trimmed)
            guard !display.isEmpty else { continue }
            let bulletID = "\(selectedName)-L\(idx)-\(trimmed.hashValue)"
            currentBullets.append(
                MemoryTruthBulletLine(
                    id: bulletID,
                    lineIndex: idx,
                    rawLine: trimmed,
                    displayText: display
                )
            )
        }
        flushSection(index: rawLines.count)
        return out
    }

    private static func cleanBulletText(_ line: String) -> String {
        var s = line
        for prefix in ["- [x] ", "- [ ] ", "* [x] ", "* [ ] ", "- ", "* ", "• "] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        if let dotIdx = s.firstIndex(of: "."),
           s[..<dotIdx].allSatisfy(\.isNumber) {
            let after = s.index(after: dotIdx)
            if after < s.endIndex && s[after] == " " {
                s = String(s[s.index(after: after)...])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func applyFilesJSON(_ json: JSON) {
        let arr = json["files"].array
        guard !arr.isEmpty else { return }
        var parsed: [MemoryTruthFile] = []
        for item in arr {
            let name = item["name"].string
            guard !name.isEmpty else { continue }
            let content = item["content"].string
            let lineCount = item["line_count"].int > 0
                ? item["line_count"].int
                : content.split(separator: "\n", omittingEmptySubsequences: true).count
            parsed.append(
                MemoryTruthFile(
                    name: name,
                    title: item["title"].string.isEmpty ? name : item["title"].string,
                    content: content,
                    updatedAt: item["updated_at"].double,
                    lineCount: lineCount
                )
            )
        }
        if !parsed.isEmpty {
            files = parsed
            if !files.contains(where: { $0.name == selectedName }), let first = files.first {
                selectedName = first.name
            }
            hasLoaded = true
        }
    }

    func updateSingleFile(name: String, content: String, updatedAt: Double = Date().timeIntervalSince1970) {
        let count = content.split(separator: "\n", omittingEmptySubsequences: true).count
        if let idx = files.firstIndex(where: { $0.name == name }) {
            files[idx].content = content
            files[idx].updatedAt = updatedAt
            files[idx].lineCount = count
        } else {
            files.append(MemoryTruthFile(name: name, title: name, content: content, updatedAt: updatedAt, lineCount: count))
        }
        hasLoaded = true
    }
}

// 轨道 agent：记忆页的「最近自动学到」与待确认收件箱。
// 后端 /personal/memory-inbox：learned = 已自动写入、还没被你看过的；pending = 等你批准才写入的。
extension AppModel {
    static let memoryInboxPath = "/personal/memory-inbox"
    static let memoryTruthFilesPath = "/personal/memory/files"

    var memoryTruth: MemoryTruthStore { MemoryTruthStore.shared }

    @discardableResult
    func loadMemoryTruthFiles() async -> Bool {
        let store = memoryTruth
        store.loading = true
        defer { store.loading = false }
        #if DEBUG
        if isUITesting {
            if !store.hasLoaded {
                let now = Date().timeIntervalSince1970
                store.files = [
                    MemoryTruthFile(
                        name: "MEMORY.md",
                        title: "长期记忆 (MEMORY.md)",
                        content: "# 关于你\n- 偏好简洁直接的回复，先给结论再附依据\n- 每周二、周四晚上去攀岩\n\n# 正在推进\n- Com 个人助理工作台双栏与记忆升级",
                        updatedAt: now - 600,
                        lineCount: 6
                    ),
                    MemoryTruthFile(
                        name: "SOUL.md",
                        title: "助理分寸 (SOUL.md)",
                        content: "# 分寸与边界\n- 邮件发送、劳务报酬提交、内容发布停在按钮前由你点\n- 数据只转移不删除，不保存或回显任何明文密钥",
                        updatedAt: now - 1200,
                        lineCount: 3
                    ),
                ]
                store.hasLoaded = true
            }
            store.errorNote = ""
            return true
        }
        #endif
        guard let data = await load(Self.memoryTruthFilesPath) else {
            store.errorNote = errors[Self.memoryTruthFilesPath] ?? "核心真相文件还没读上，可稍后重试。"
            return false
        }
        store.applyFilesJSON(data)
        store.errorNote = ""
        return true
    }

    @discardableResult
    func saveMemoryTruthFile(name: String, content: String) async -> Bool {
        let store = memoryTruth
        store.saving = true
        store.errorNote = ""
        defer { store.saving = false }
        #if DEBUG
        if isUITesting {
            store.updateSingleFile(name: name, content: content)
            store.statusNote = "已保存到 \(name)"
            Haptics.success()
            return true
        }
        #endif
        do {
            let resp = try await mutate(
                Self.memoryTruthFilesPath + "/" + name.pathEncoded,
                fields: ["content": .string(content)],
                silentBanner: true
            )
            let savedContent = resp["content"].string.isEmpty ? content : resp["content"].string
            store.updateSingleFile(
                name: name,
                content: savedContent,
                updatedAt: resp["updated_at"].double > 0 ? resp["updated_at"].double : Date().timeIntervalSince1970
            )
            let sanitized = resp["sanitized_lines"].array.count
            if sanitized > 0 {
                store.statusNote = "已保存 \(name)（已自动剥离 \(sanitized) 行敏感口令字样）"
            } else {
                store.statusNote = "已保存 \(name)，下一轮对话立即生效"
            }
            Haptics.success()
            _ = await load(Self.memoryTruthFilesPath)
            _ = await load("/personal/memory")
            return true
        } catch {
            store.errorNote = "保存 \(name) 没成功：" + error.localizedDescription
            Haptics.error()
            return false
        }
    }

    @discardableResult
    func forgetMemoryTruthLine(_ line: MemoryTruthBulletLine, in fileName: String) async -> Bool {
        let store = memoryTruth
        store.forgettingIDs.insert(line.id)
        store.errorNote = ""
        defer { store.forgettingIDs.remove(line.id) }
        #if DEBUG
        if isUITesting {
            let current = store.files.first(where: { $0.name == fileName })?.content ?? ""
            let filtered = current
                .components(separatedBy: .newlines)
                .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != line.rawLine }
                .joined(separator: "\n")
            store.updateSingleFile(name: fileName, content: filtered)
            store.statusNote = "已从 \(fileName) 忘掉这一条"
            Haptics.selection()
            return true
        }
        #endif
        do {
            let resp = try await mutate(
                "/personal/memory/forget",
                fields: [
                    "target": .string(line.rawLine),
                    "name": .string(fileName),
                ],
                silentBanner: true
            )
            if !resp["content"].string.isEmpty {
                store.updateSingleFile(name: fileName, content: resp["content"].string)
            } else {
                _ = await loadMemoryTruthFiles()
            }
            let removed = max(1, resp["removed_count"].int)
            store.statusNote = "已忘掉 \(removed) 条记录"
            Haptics.selection()
            _ = await load("/personal/memory")
            return true
        } catch {
            store.errorNote = "忘掉这条没成功：" + error.localizedDescription
            Haptics.error()
            return false
        }
    }

    @discardableResult
    func runMemoryDream() async -> Bool {
        let store = memoryTruth
        guard !store.dreaming else { return false }
        store.dreaming = true
        store.errorNote = ""
        defer { store.dreaming = false }
        #if DEBUG
        if isUITesting {
            let report = MemoryDreamReport(
                updated: true,
                summary: "合并了 2 条重复偏好，归档 1 条过期临时事项。",
                mergedCount: 2,
                archivedCount: 1,
                ranAt: Date().timeIntervalSince1970
            )
            store.lastDream = report
            store.statusNote = report.summary
            Haptics.success()
            return true
        }
        #endif
        do {
            let resp = try await mutate("/personal/memory/dream", silentBanner: true)
            let merged = resp["merged_count"].int
            let archived = resp["archived_count"].int
            let rawSummary = resp["summary"].string
            let fallbackSummary = resp["updated"].bool
                ? "整理完成：合并 \(merged) 条，归档 \(archived) 条。"
                : "核心真相文件很干净，本轮无需合并或归档。"
            let report = MemoryDreamReport(
                updated: resp["updated"].bool,
                summary: rawSummary.isEmpty ? fallbackSummary : rawSummary,
                mergedCount: merged,
                archivedCount: archived,
                ranAt: resp["ran_at"].double > 0 ? resp["ran_at"].double : Date().timeIntervalSince1970
            )
            store.lastDream = report
            store.statusNote = report.summary
            Haptics.success()
            _ = await loadMemoryTruthFiles()
            _ = await load("/personal/memory")
            return true
        } catch {
            store.errorNote = "整理记忆没成功：" + error.localizedDescription
            Haptics.error()
            return false
        }
    }

    func loadMemoryInbox() async {
        #if DEBUG
        if isUITesting && datasets[Self.memoryInboxPath] == nil { seedMemoryInboxPreview() }
        #endif
        _ = await load(Self.memoryInboxPath)
    }

    /// action：confirm（没错 / 记住）、correct（纠正后保存）、delete（删掉=归档，可在历史版本里找回；待确认的则直接丢弃）。
    @discardableResult
    func actOnLearned(_ id: String, action: String, content: String = "") async -> Bool {
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
            Haptics.selection(); return true
        }
        #endif
        do {
            _ = try await mutate(Self.memoryInboxPath + "/" + id.pathEncoded, fields: ["action": .string(action), "content": .string(content)])
            Haptics.selection()
            _ = await load(Self.memoryInboxPath)
            _ = await load("/personal/memory")
            return true
        } catch {
            // 失败回读；页内由 MemoryReview.actFailNote 开口，banner 仅兜底。
            banner = "记忆操作没成：" + error.localizedDescription
            _ = await load(Self.memoryInboxPath)
            _ = await load("/personal/memory")
            return false
        }
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
