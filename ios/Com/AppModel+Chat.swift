import SwiftUI
import ComCore

// 聊天轨道（chat）：顶栏气泡和流里「工作过程」共用的「当前步骤」。

extension AppModel {
    /// 正在跑的那条用户消息的工作过程（没有就是 nil）。
    var liveProcess: WorkProcess? {
        conversation.messages.last { $0["role"].string == "user" && WorkProcess.activeStatuses.contains($0["status"].string) }
            .flatMap(WorkProcess.from)
    }
    /// 顶栏人物旁手绘气泡里的字；空字符串 = 空闲，气泡收起。
    var workBubble: String {
        if let process = liveProcess { return process.current }
        guard stage.state.isBusy else { return "" }
        return stripCaption
    }
}

#if DEBUG
extension AppModel {
    /// `--ui-work-process`：一条做完的（折叠成一行）+ 一条正在做的（实时一行 + 顶栏气泡），并按脚本往前走。
    func seedWorkProcessPreview() {
        let now = Date().timeIntervalSince1970
        func step(_ n: Int, _ tool: String, _ status: String, at: Double, took: Double = 1.2) -> JSON {
            .object(["id": .string("tool-\(n)"), "kind": .string("tool"), "tool": .string(tool), "title": .string("正在使用 " + tool),
                     "status": .string(status), "started_at": .number(at), "finished_at": .number(status == "running" ? 0 : at + took)])
        }
        let reply = """
        上周（10 月 1 日–7 日）在攀岩上一共花了 **¥1,326**，比前一周多了 **¥410**，主要是多去了两次岩馆。

        ## 明细

        - **岩馆门票** ¥580 · 4 次，其中周六两次
        - **装备** ¥466 · 新换了一双攀岩鞋
        - **交通** ¥280 · 打车往返

        ## 今天这笔

        岩馆月卡 **¥480** 已经记进「运动 · 攀岩」，日期是今天。按这个月剩下的次数算，月卡比单次票便宜大约 ¥220。

        > 如果月卡要跟朋友 AA，告诉我一声，我把这笔拆开记。
        """
        // 10-28 todo 时间轴验收：第三步进行中，它下面挂着从 now-12 起的工具
        func todo(_ id: String, _ text: String, _ status: String, _ start: Double = 0, _ done: Double = 0) -> JSON {
            .object(["id": .string(id), "content": .string(text), "active": .string("正在" + text), "status": .string(status),
                     "started_at": .number(start), "done_at": .number(done)])
        }
        let wpPlan: JSON = .object(["id": .string("plan"), "kind": .string("plan"), "title": .string("查聊天页排版"), "todos": .array([
            todo("1", "找到聊天页代码", "completed", now - 30, now - 18),
            todo("2", "翻排版相关样式", "completed", now - 18, now - 12),
            todo("3", "定位挤的原因", "in_progress", now - 12),
            todo("4", "核对改法会不会误伤", "pending"),
            todo("5", "写结论给你", "pending")])])
        conversation.messages = [
            .object(["id": .string("wp-0"), "role": .string("assistant"), "text": .string("早上好。今天日程不多，下午三点有个会。"), "status": .string("completed"), "created_at": .number(now - 900)]),
            .object(["id": .string("wp-1"), "role": .string("user"), "text": .string("上周在攀岩上花了多少钱？顺便帮我记一笔今天的岩馆月卡 480"), "status": .string("completed"),
                     "created_at": .number(now - 600), "received_at": .number(now - 600),
                     "tasks": .array([step(1, "memory_recall", "done", at: now - 599), step(2, "bookkeeping_search", "done", at: now - 597), step(3, "bookkeeping_search", "done", at: now - 595),
                                      step(4, "bookkeeping_search", "done", at: now - 593), step(5, "bookkeeping", "done", at: now - 590, took: 2)]),
                     "summary": .object(["duration_ms": .number(14_000)])]),
            .object(["id": .string("wp-2"), "role": .string("assistant"), "parent_id": .string("wp-1"), "text": .string(reply), "status": .string("completed"), "created_at": .number(now - 585)]),
            .object(["id": .string("wp-3"), "role": .string("user"), "text": .string("帮我看看 Com 聊天页的代码，排版为什么这么挤"), "status": .string("running"), "phase": .string("executing"),
                     "created_at": .number(now - 20), "received_at": .number(now - 20),
                     "tasks": .array([wpPlan] + (1...6).map { step($0, $0 % 2 == 0 ? "find" : "grep", "done", at: now - 19 + Double($0) * 1.5) } + [step(7, "read", "running", at: now - 6)])])
        ]
        conversation.runs = [.object(["message_id": .string("wp-3"), "status": .string("running"), "phase": .string("executing"), "active_tool": .string("read")])]
        // init 在 seed 之后会用 idle 快照打底，等它跑完再告诉舞台她在翻资料。
        Task { [weak self] in await Task.yield(); self?.stage.receive("task.progress", .object(["kind": .string("searching")])) }
        guard ProcessInfo.processInfo.arguments.contains("--ui-work-process-live") else { return }
        // 往前走：读完 → 跑命令 → 改文件 → 写回复 → 完成。
        let script: [(String, String)] = [("read", "done"), ("read", "running"), ("read", "done"), ("bash", "running"), ("bash", "done"), ("edit", "running"), ("edit", "done"), ("", "responding"), ("", "completed")]
        Task { [weak self] in
            for (tool, status) in script {
                try? await Task.sleep(for: .seconds(2.2))
                guard let self, let index = self.conversation.messages.firstIndex(where: { $0.id == "wp-3" }) else { return }
                var message = self.conversation.messages[index]
                var tasks = message["tasks"].array
                let at = Date().timeIntervalSince1970
                if status == "done", let last = tasks.indices.last { tasks[last]["status"] = .string("done"); tasks[last]["finished_at"] = .number(at) }
                else if status == "running" { tasks.append(step(tasks.count + 1, tool, "running", at: at)) }
                else if status == "responding" { message["phase"] = .string("responding") }
                else {
                    message["status"] = .string("completed")
                    self.conversation.runs = []
                    self.conversation.messages.append(.object(["id": .string("wp-4"), "role": .string("assistant"), "parent_id": .string("wp-3"), "status": .string("completed"), "created_at": .number(at),
                        "text": .string("挤的原因有两个：\n\n1. **行距用的是默认值**，中文长段落贴得很紧\n2. **段落之间只有一行空白**，列表项之间几乎没有间距\n\n我已经把行距和段落间距都放宽了。")]))
                    self.stage.receive("task.progress", .object(["kind": .string("idle")]))
                }
                message["tasks"] = .array(tasks)
                self.conversation.messages[index] = message
                self.conversation.revision += 1
                if status == "running" { self.stage.receive("task.progress", .object(["kind": .string(tool == "bash" ? "working" : tool == "edit" ? "writing" : "searching")])) }
            }
        }
    }
}
#endif

#if DEBUG
// r2-chat：主聊天排版 + 建议卡的验收数据。
extension AppModel {
    /// `--ui-reply-layout`：三条 mini 上常见的整段纯文本回复，最后一条末行带选项标记。
    /// 加 `--ui-reply-legacy` 看改版前的渲染（前后对比截图用）；加 `--ui-reply-live` 1.5 秒后再来一条新回复，看进场动效。
    func seedReplyLayoutPreview() {
        let now = Date().timeIntervalSince1970
        func message(_ id: String, _ role: String, _ text: String, at: Double, extra: [String: JSON] = [:]) -> JSON {
            .object(["id": .string(id), "role": .string(role), "text": .string(text), "status": .string("completed"), "created_at": .number(at)].merging(extra) { $1 })
        }
        conversation.messages = [
            message("rl-1", "user", "上周攀岩花了多少？顺便把今天的岩馆月卡480记一下", at: now - 900),
            message("rl-2", "assistant", "上周你在攀岩上一共花了1326元，比前一周多了410元，主要是多去了两次岩馆。明细是这样的：岩馆门票580元，一共4次；装备466元，换了一双攀岩鞋；交通280元，基本都是打车。今天的岩馆月卡480元我已经记进运动攀岩分类了，日期是今天。按这个月剩下的次数算，月卡比单次票大概便宜220元，挺划算的。如果要跟朋友AA的话告诉我一声，我把这笔拆开记。", at: now - 880),
            message("rl-3", "user", "明天要准备什么", at: now - 600),
            message("rl-4", "assistant", "明天日程不算满，但有三件事要提前准备。首先，上午10:30跟搜狐的同事开选题会，你上次说要带三个备选题，目前行动台里只有两个。其次，下午3点要去岩馆拍探馆素材，记得带上GoPro和备用电池。最后，晚上8点之前要把极限勇士挑战赛的物料清单发给供应商，这个昨天已经催过一次了。我建议今晚先把第三个选题补上，明早就不用赶。", at: now - 580),
            message("rl-5", "user", "Com 刚才怎么连不上", at: now - 120),
            message("rl-6", "assistant", "查完了，mini 上的 Com 服务是正常的，刚才连不上是因为 Magpie 网关重启了一次，大概断了40秒。现在接口都能通，最近一小时没有新的报错。另外我顺手看了下磁盘，还剩86GB，不用管。如果你还遇到连不上，先下拉刷新一下，还不行就告诉我，我去看日志。\n[[选项: 帮我盯着日志 | 先不管 | 看看详情]]", at: now - 100),
        ]
        // `--ui-reply-only=N`：只留第 N 组问答（截图对比用）。
        if let only = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-reply-only=") }).flatMap({ Int($0.split(separator: "=").last ?? "") }), (1...3).contains(only) {
            conversation.messages = Array(conversation.messages[(only - 1) * 2 ..< only * 2])
        }
        guard ProcessInfo.processInfo.arguments.contains("--ui-reply-live") else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.conversation.messages.append(message("rl-7", "user", "明早提醒我带电池", at: Date().timeIntervalSince1970))
            self.conversation.messages.append(message("rl-8", "assistant", "**记好了，明早 8:00 提醒你带 GoPro 备用电池。**\n\n### 顺手看了下\n\n- 下午 **3 点**岩馆拍摄，电池要 **2 块**\n- 充电器在书房抽屉\n\n要不要连充电器也一起提醒？", at: Date().timeIntervalSince1970,
                                                       extra: ["suggestions": .array([.string("一起提醒"), .string("不用了"), .string("改到7点半")])]))
            self.conversation.revision += 1
        }
    }
}
#endif
