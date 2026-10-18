import Foundation
import ComCore

// 轨道 pages（下一步 / 今天 / 工作）的界面验收数据。只在 DEBUG + --ui-testing 下用，不碰真实接口。
#if DEBUG
extension AppModel {
    func seedPagesPreview() {
        UserDefaults.standard.removeObject(forKey: "today.dial.span")  // 每次验收表盘都从「眼前」开始
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        func at(_ hour: Double) -> JSON { .number(day + hour * 3600) }
        // 轨道 r2-pages：日程按「现在」前后排，任何时刻跑验收都有过去的、有下一件。
        let nowH = (Date().timeIntervalSince1970 - day) / 3600
        let run = max(0.5, nowH - 6), week = max(1.5, nowH - 2.5), review = min(nowH + 0.75, 23), climb = min(nowH + 1.75, 23.2)
        func time(_ hour: Double) -> String {
            let d = Date(timeIntervalSince1970: day + hour * 3600)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d)
        }
        datasets["/personal/today"] = .object([
            "date": .string(""), "errors": .object([:]),
            "events": .array([
                .object(["id": .string("ev-run"), "title": .string("晨跑 5 公里"), "start": at(run), "end": at(run + 0.75), "all_day": .bool(false), "location": .string("奥森南门"), "source": .string("apple_calendar"), "calendar": .string("个人"), "notes": .string("")]),
                .object(["id": .string("ev-week"), "title": .string("周会"), "start": at(week), "end": at(week + 1), "all_day": .bool(false), "location": .string("3F 会议室"), "source": .string("google_calendar"), "calendar": .string("工作"), "notes": .string("过一遍上周的两个待办，确认 Q4 排期。")]),
                .object(["id": .string("ev-review"), "title": .string("排期评审"), "start": at(review), "end": at(review + 1), "all_day": .bool(false), "location": .string(""), "source": .string("google_calendar"), "calendar": .string("工作"), "notes": .string("")]),
                .object(["id": .string("ev-climb"), "title": .string("攀岩"), "start": at(climb), "end": at(min(climb + 2, 23.9)), "all_day": .bool(false), "location": .string("岩时攀岩馆"), "source": .string("apple_calendar"), "calendar": .string("个人"), "notes": .string("")])
            ]),
            "reminders": .array([
                .object(["id": .string("rm-late"), "title": .string("给妈妈回电话"), "at": at(-4), "due": .string(time(-4)), "status": .string("pending"), "repeat": .string("once"), "overdue": .bool(true)]),
                .object(["id": .string("rm-invoice"), "title": .string("交报销单"), "at": at(max(0.2, nowH - 1)), "due": .string(time(max(0.2, nowH - 1))), "status": .string("pending"), "repeat": .string("once"), "overdue": .bool(false)])
            ]),
            "todos": .array([
                .object(["id": .string("预赛前最终策略上传"), "title": .string("预赛前最终策略上传"), "due": .string(""), "start": .string(""), "overdue": .bool(false), "next_step": .string("跑完回测再传"), "project": .string("AI德州扑克2026"), "note": .string(""), "path": .string("任务/待处理/预赛前最终策略上传.md")]),
                .object(["id": .string("八月打车报销"), "title": .string("八月打车报销"), "due": .string("2026-10-03"), "start": .string(""), "overdue": .bool(true), "next_step": .string("跑 invoice_reconcile 后提交"), "project": .string("合同与劳务结算"), "note": .string("文件在 Downloads/8月份 打车报销"), "path": .string("任务/待处理/八月打车报销.md")])
            ]),
            "health": healthPreview(day: day, nowH: nowH)
        ])
        // 「下一步」依据带上原始来源，验收点开依据的那一级。
        var next = datasets["/personal/next"] ?? .null
        let details: [String: JSON] = [
            "mail:m1": .object(["title": .string("Re: Q4 排期确认"), "source": .string("work_mail"), "source_label": .string("工作邮箱"), "at": .number(Date().timeIntervalSince1970 - 5400),
                                "sender": .string("王总 <wang@example.com>"), "summary": .string("小高，Q4 的三个专场排期麻烦今天下班前给我一个确认版本，特别是 11 月那场的场地。")]),
            "event:m3": .object(["title": .string("周会"), "source": .string("google_calendar"), "source_label": .string("Google 日历"), "at": at(week), "end": at(week + 1), "location": .string("3F 会议室")]),
            "project:p1": .object(["title": .string("Com · 个人 Agent"), "source": .string("project_board"), "source_label": .string("工作看板"), "at": .number(Date().timeIntervalSince1970 - 7200),
                                   "summary": .string("语音小窗光效和入口都做完了。"), "next_step": .string("真机录一次音，检查发送结果"), "host": .string("mini"), "agent": .string("claude")])
        ]
        next["items"] = .array(next["items"].array.map { item in
            var copy = item
            copy["evidence"] = .array(item["evidence"].array.map { e in
                var v = e
                if let d = details[e["ref"].string] { v["detail"] = d }
                if e["ref"].string.hasPrefix("mail:") || e["ref"].string.hasPrefix("event:") { v["matter_id"] = .string(String(e["ref"].string.split(separator: ":").last ?? "")) }
                return v
            })
            return copy
        })
        next["headline"] = .string("睡了 7.2 小时（81 分）、电量 47，下午排期评审前先回王总的排期邮件。")
        next["brief"] = .array([
            .object(["text": .string("睡了 7.2 小时，比周均多半小时；电量 47 偏低，下午别再加会。"), "kind": .string("health")]),
            .object(["text": .string("11:00 周会、15:00 排期评审，中间 12:00–14:30 是今天唯一的整块空档。"), "kind": .string("event")]),
            .object(["text": .string("王总要的 Q4 排期今天下班前给，评审前先回掉。"), "kind": .string("note")]),
            .object(["text": .string("Claude 新版支持直接读手机屏幕，正好能做一期 AI 工具测评。"), "kind": .string("news"), "news_id": .string("n1"), "title": .string("Claude 新版发布"), "url": .string("https://www.anthropic.com/news"), "site": .string("Anthropic")])
        ])
        datasets["/personal/next"] = next
        if ProcessInfo.processInfo.arguments.contains("--ui-r3-dense") { seedDenseToday() }
        seedHealthPage()
    }

    /// 健康页验收数据（10-17）：在今天页那 7 天前面再补 7 天，今天带上新接的字段（呼吸、血氧、负荷、体能年龄、活动）和一份评估。
    private func seedHealthPage() {
        var source = todayData["health"]
        guard !source.isNull else { return }
        let first = source["days"].array
        let earlier: [JSON] = first.enumerated().map { i, d in
            var copy = d
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let date = f.date(from: d["date"].string).map { $0.addingTimeInterval(-7 * 86400) } ?? Date()
            copy["date"] = .string(f.string(from: date))
            var m = copy["measurements"]
            m["hrv_last_night"] = .number(m["hrv_last_night"].double + Double(i % 3) * 2 - 2)
            m["sleep_seconds"] = .number(m["sleep_seconds"].double - Double(i % 4) * 1800)
            copy["measurements"] = m
            copy["activities"] = i == 2 ? .array([.object(["name": .string("先锋攀"), "type": .string("rock_climbing"), "start": .string("19:30"), "minutes": .number(150), "calories": .number(820), "avg_hr": .number(112)])]) : .array([])
            return copy
        }
        var days = earlier + first
        var today = days[days.count - 1]
        var m = today["measurements"]
        for (k, v) in [("hrv_weekly", 42.0), ("sleep_need_minutes", 480), ("sleep_stress", 18), ("respiration_sleep", 15), ("spo2_7d", 96), ("load_acute", 34), ("load_chronic", 219),
                       ("load_ratio", 0.6), ("fitness_age", 26), ("age", 29), ("body_battery_at_wake", 71)] { m[k] = .number(v) }
        m["hrv_baseline"] = .array([.number(40), .number(60)]); m["hrv_status"] = .string("BALANCED"); m["training_status"] = .string("RECOVERY_1")
        today["measurements"] = m
        today["activities"] = .array([.object(["name": .string("抱石"), "type": .string("bouldering"), "start": .string("08:10"), "minutes": .number(75), "calories": .number(410), "avg_hr": .number(108)])])
        days[days.count - 1] = today
        source["days"] = .array(days); source["today"] = today
        datasets["/personal/health?days=30"] = source
        datasets["/personal/health/insight"] = .object([
            "score": .number(81), "level": .string("high"), "source": .string("model"), "running": .bool(false), "updated_at": .number(Date().timeIntervalSince1970 - 900),
            "headline": .string("恢复不错，下午可以上强度"),
            "summary": .string("昨晚睡了 7.2 小时，比两周均值多 20 分钟；HRV 44 在基线 40–60 里，静息心率 58 持平。急性负荷只有 34，身体在恢复期，今天适合安排一次有质量的训练。"),
            "dimensions": .array([
                .object(["key": .string("sleep"), "level": .string("good"), "note": .string("7.2h，深睡 1h57m")]),
                .object(["key": .string("recovery"), "level": .string("good"), "note": .string("HRV 44 在基线内")]),
                .object(["key": .string("load"), "level": .string("low"), "note": .string("负荷比 0.6，可以加量")]),
                .object(["key": .string("stress"), "level": .string("ok"), "note": .string("平均压力 26")])]),
            "actions": .array([
                .object(["title": .string("晚上抱石 90 分钟"), "detail": .string("恢复分 81，可以试两条极限线路，组间休息 3 分钟。"), "when": .string("19:00 后"), "kind": .string("train")]),
                .object(["title": .string("会间起来走 10 分钟"), "detail": .string("今天步数才 2851，补到 6000。"), "when": .string("15:00 评审后"), "kind": .string("move")]),
                .object(["title": .string("训练后补蛋白"), "detail": .string("一掌半的鸡蛋或瘦肉，帮恢复。"), "when": .string("21:00"), "kind": .string("eat")]),
                .object(["title": .string("今晚 23:30 前睡"), "detail": .string("睡够 8 小时，明早电量才能回到 70 以上。"), "when": .string("今晚"), "kind": .string("sleep")])])
        ])
    }

    /// 身体卡验收数据：照 mini 上真实 Garmin 回包的字段，7 天，今天带一条身体电量曲线。
    private func healthPreview(day: Double, nowH: Double) -> JSON {
        let week: [(Double, Double, Double, Double, Double, Double, Double)] = [  // 睡眠秒、睡眠分、HRV、准备度、静息心率、压力、步数
            (23400, 72, 39, 58, 60, 34, 8200), (27000, 85, 45, 77, 57, 25, 10400), (21600, 64, 36, 49, 61, 41, 6300),
            (25800, 80, 43, 70, 58, 28, 9100), (24480, 76, 41, 64, 58, 39, 7528), (22800, 70, 40, 61, 59, 30, 5400), (26040, 81, 44, 81, 58, 26, 2851)]
        let days: [JSON] = week.enumerated().map { i, v in
            let date = Date(timeIntervalSince1970: day - Double(6 - i) * 86400)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            return .object(["date": .string(f.string(from: date)), "missing": .array([]), "body_battery_curve": .array([]),
                            "measurements": .object(["sleep_seconds": .number(v.0), "sleep_score": .number(v.1), "hrv_last_night": .number(v.2), "readiness_score": .number(v.3),
                                                     "resting_heart_rate": .number(v.4), "avg_stress": .number(v.5), "steps": .number(v.6), "body_battery_at_wake": .number(55 + v.3 / 5)])])
        }
        var today = days.last!
        var m = today["measurements"]
        for (k, v) in [("body_battery", 47.0), ("body_battery_charged", 59), ("body_battery_drained", 20), ("deep_seconds", 7020), ("light_seconds", 13620), ("rem_seconds", 5400), ("awake_seconds", 120)] { m[k] = .number(v) }
        m["sleep_start"] = .string("2026-10-15T00:31+08:00"); m["sleep_end"] = .string("2026-10-15T07:47+08:00")
        today["measurements"] = m
        let curve: [JSON] = stride(from: 0.0, through: max(1, nowH), by: 0.25).map { h in
            let level = h < 7.8 ? 8 + h / 7.8 * 59 : max(20, 67 - (h - 7.8) * 2.6)
            return .array([.number(day + h * 3600), .number(level.rounded())])
        }
        today["body_battery_curve"] = .array(curve)
        return .object(["date": today["date"], "today": today, "days": .array(Array(days.dropLast()) + [today]), "phone": .null,
                        "sources": .object(["garmin": .object(["status": .string("connected"), "updated_at": .number(Date().timeIntervalSince1970 - 900), "error": .string("")])])])
    }

    /// r3-pages 密集验收数据（配合 TodayClock：现在固定 14:00）：
    /// 一小时里 4 件两两重叠（其中两件同一时刻开始、一件只有 5 分钟），15:20 起三件挨着（表盘上该并成一摞），
    /// 14:00 整点一条提醒（压在「现在」上），外加两件全天的。
    private func seedDenseToday() {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        func at(_ hour: Double) -> JSON { .number(day + hour * 3600) }
        func event(_ id: String, _ title: String, _ start: Double, _ end: Double, calendar: String = "工作", location: String = "") -> JSON {
            .object(["id": .string(id), "title": .string(title), "start": at(start), "end": at(end), "all_day": .bool(false), "location": .string(location),
                     "source": .string("google_calendar"), "calendar": .string(calendar), "notes": .string("")])
        }
        func allDay(_ id: String, _ title: String, calendar: String, informational: Bool) -> JSON {
            .object(["id": .string(id), "title": .string(title), "start": at(0), "end": at(24), "all_day": .bool(true), "location": .string(""),
                     "source": .string("apple_calendar"), "calendar": .string(calendar), "informational": .bool(informational), "notes": .string("")])
        }
        func reminder(_ id: String, _ title: String, _ hour: Double) -> JSON {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            return .object(["id": .string(id), "title": .string(title), "at": at(hour), "due": .string(f.string(from: Date(timeIntervalSince1970: day + hour * 3600))),
                            "status": .string("pending"), "repeat": .string("once"), "overdue": .bool(false)])
        }
        func todo(_ name: String, due: String, overdue: Bool, next: String) -> JSON {
            .object(["id": .string(name), "title": .string(name), "due": .string(due), "start": .string(""), "overdue": .bool(overdue), "next_step": .string(next),
                     "project": .string("合同与劳务结算"), "note": .string(""), "path": .string("任务/待处理/\(name).md")])
        }
        datasets["/personal/today"] = .object([
            "date": .string(""), "errors": .object([:]),
            "events": .array([
                allDay("ev-holiday", "国庆调休", calendar: "中国大陆节假日", informational: true),
                allDay("ev-bday", "妈妈生日", calendar: "个人", informational: false),
                event("ev-run", "晨跑 5 公里", 7, 7.75, calendar: "个人", location: "奥森南门"),
                event("ev-sync", "周会", 14 + 10 / 60, 14 + 40 / 60, location: "3F 会议室"),
                event("ev-call", "电话 · 王总", 14 + 10 / 60, 14 + 25 / 60),
                event("ev-review", "排期评审", 14.5, 15),
                event("ev-coffee", "咖啡 · 李雷", 14 + 50 / 60, 14 + 55 / 60, calendar: "个人"),
                event("ev-parcel", "取快递", 15 + 20 / 60, 15 + 35 / 60, calendar: "个人"),
                event("ev-video", "视频会 · 设计", 15 + 25 / 60, 15 + 55 / 60),
                event("ev-house", "看房", 15.5, 16, calendar: "个人"),
                event("ev-climb", "攀岩", 16, 18, calendar: "个人", location: "岩时攀岩馆")
            ]),
            "reminders": .array([reminder("rm-invoice", "交报销单", 13 + 40 / 60), reminder("rm-pill", "吃药", 14)]),
            "todos": .array([
                todo("八月打车报销", due: "2026-10-03", overdue: true, next: "跑 invoice_reconcile 后提交"),
                todo("预赛前最终策略上传", due: "", overdue: false, next: "跑完回测再传"),
                todo("白晓萌合同续期", due: "", overdue: false, next: "确认续期金额")
            ])
        ])
    }
}
#endif
