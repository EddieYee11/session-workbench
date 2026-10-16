import XCTest

/// 第三轮 pages 轨道：下一步页的依据袋动效，今天页的待办两种点击、时间线分道、「下一件」表盘避让。
/// 录屏验收时这些用例会被单独跑（xcodebuild -only-testing），所以每步之间留了停顿，方便抽帧看完整的开合。
final class R3PagesUITests: XCTestCase {
    @MainActor private func launch(_ extra: [String] = [], tab: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-appearance", "light"] + extra
        if let tab { app.launchEnvironment["COM_PREVIEW_TAB"] = tab }
        app.launch()
        return app
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    /// 今天页上面多了简报和身体卡，待办卡在首屏下面：坐标点击不会自动滚，先把它滚进屏幕。
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // 只认真实位置：元素整块落在顶栏以下、Dock 以上；每次轻推一小段，等滚动停稳再看。
        for _ in 0..<12 where !(element.exists && element.frame.minY > 140 && element.frame.maxY < app.frame.maxY - 140) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            pause(0.8)
        }
        pause(0.8)
    }

    /// 依据袋：开 → 合 → 再开 → 点纸片进原始来源 → 在详情里再往下跳到事项 → 一路收回 → 合上。录屏抽帧看有没有闪、跳、穿插。
    /// 每一步点完先停 1.5–2 秒再查询：XCUITest 查界面时会卡住 App 主线程，动画中途查询，录屏里就是掉帧。
    @MainActor func testR3EvidencePocketMotion() throws {
        let app = launch(tab: "下一步")
        let pocket = app.buttons["next-evidence-next-reply"]
        let slip = app.buttons["next-evidence-slip-next-reply-0"]
        XCTAssertTrue(pocket.waitForExistence(timeout: 15))
        pause(1.5)
        pocket.tap()
        pause(1.5)
        XCTAssertTrue(slip.exists)
        XCTAssertTrue(app.buttons["next-evidence-slip-next-reply-1"].exists)
        XCTAssertFalse(app.buttons["next-evidence-row-next-reply-0"].exists, "列表式依据已经删掉")
        capture("r3-pocket-open", app: app)
        pocket.tap()
        pause(1.5)
        pocket.tap()
        pause(1.5)
        slip.tap()
        pause(2)
        XCTAssertTrue(app.navigationBars["依据"].exists)
        XCTAssertTrue(app.staticTexts["Re: Q4 排期确认"].exists)
        capture("r3-evidence-detail", app: app)
        app.buttons["evidence-jump-matter"].tap()
        pause(1.5)
        XCTAssertTrue(app.navigationBars["事项"].exists)
        app.navigationBars["事项"].buttons["完成"].tap()
        pause(1.5)
        XCTAssertTrue(app.navigationBars["依据"].exists)
        app.navigationBars["依据"].buttons["完成"].tap()
        pause(2)
        XCTAssertFalse(app.navigationBars["依据"].exists)
        pocket.tap()
        pause(1.5)
    }

    // MARK: 今天页

    /// 驾驶舱：顶上简报、身体卡（点进 7 天明细）、一句话交代给 Com、建议卡和「全部建议」入口。
    @MainActor func testTodayCockpit() throws {
        let app = launch(tab: "今天")
        XCTAssertTrue(app.staticTexts["today-headline"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["today-headline"].label.contains("电量 47"))
        let body = app.buttons["today-body"]
        XCTAssertTrue(body.exists)
        pause(1.2)
        capture("today-cockpit-top", app: app)
        body.tap()
        XCTAssertTrue(app.descendants(matching: .any)["health-detail"].firstMatch.waitForExistence(timeout: 5))
        pause(1)
        capture("today-health-detail", app: app)
        app.navigationBars.buttons.firstMatch.tap()
        pause(1)
        let field = app.textFields["today-quick-add"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("明天下午三点提醒我交报销")
        XCTAssertTrue(app.buttons["today-quick-send"].waitForExistence(timeout: 2))
        app.buttons["today-quick-send"].tap()
        let sent = app.descendants(matching: .any)["today-quick-sent"].firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 3))
        XCTAssertEqual(sent.label, "已交给 Com：明天下午三点提醒我交报销")
        XCTAssertFalse(app.buttons["today-next-all"].exists, "建议回到「下一步」页")
    }

    /// 半圈表盘：会动（每秒取一次现在）、外圈有整点时间、切眼前 / 半天 / 全天、点圆点进日程详情、沿弧拖读出时间。
    @MainActor func testTodayDialLiveAndInteractive() throws {
        let app = launch(tab: "今天")
        let now = app.descendants(matching: .any)["today-dial-now"].firstMatch
        XCTAssertTrue(now.waitForExistence(timeout: 15))
        pause(1.5)
        capture("today-dial-near", app: app)
        let before = now.frame.midX
        app.buttons["today-dial-span-全天"].tap()
        pause(1.2)
        XCTAssertNotEqual(now.frame.midX, before, accuracy: 2, "换成全天，现在点挪到当天的位置")
        capture("today-dial-day", app: app)
        app.buttons["today-dial-span-眼前"].tap()
        pause(1.2)
        // 点「排期评审」圆点（眼前窗口里，45 分钟后）：进日程详情。
        let review = app.buttons["today-dial-event:ev-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        review.tap()
        XCTAssertTrue(app.navigationBars["日程"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["排期评审"].exists)
        capture("today-dial-detail", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        // 沿弧拖：手指停住时截一张，有时间胶囊。
        let card = app.descendants(matching: .any)["today-next-card"].firstMatch
        let from = card.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
        from.press(forDuration: 0.1, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2)), withVelocity: .slow, thenHoldForDuration: 1.0)
    }

    /// 圆点打勾 / 撤销 / 点字进详情：热区 44pt，点圆点的最右边也不会误进详情；提醒也能勾，4 秒后提示条自己收起。
    @MainActor func testR3TodoCheckUndoAndDetail() throws {
        let app = launch(tab: "今天")
        let dot = app.buttons["today-check-todo:八月打车报销"]
        let row = app.buttons["today-todo:八月打车报销"]
        XCTAssertTrue(dot.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["4 个日程 · 5 个待办"].waitForExistence(timeout: 5))
        reveal(dot, in: app)
        XCTAssertGreaterThanOrEqual(dot.frame.width, 44, "圆点热区宽")
        XCTAssertGreaterThanOrEqual(dot.frame.height, 44, "圆点热区高")
        XCTAssertLessThanOrEqual(dot.frame.maxX, row.frame.minX + 0.5, "圆点和字的热区不重叠")
        pause(2)
        // 点圆点热区靠字的那一边：只打勾，不进详情。
        dot.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3), "打勾后这一行收起离开")
        XCTAssertFalse(app.navigationBars["待办"].exists, "点圆点不会进详情")
        let undo = app.buttons["today-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2), "「已完成 · 撤销」提示条")
        XCTAssertTrue(app.staticTexts["4 个日程 · 4 个待办"].waitForExistence(timeout: 3))
        capture("r3-todo-checked-toast", app: app)
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "撤销后回到原处")
        XCTAssertTrue(app.staticTexts["4 个日程 · 5 个待办"].waitForExistence(timeout: 3))
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
        pause(1)
        // 点字：进详情。
        row.tap()
        XCTAssertTrue(app.navigationBars["待办"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["八月打车报销"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["待办"].waitForNonExistence(timeout: 5))
        // 提醒也能直接勾；不撤销的话 4 秒后提示条自己收起，提醒不再回来。
        let reminderDot = app.buttons["today-check-reminder:rm-late"]
        XCTAssertTrue(reminderDot.waitForExistence(timeout: 5))
        reminderDot.tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["today-reminder:rm-late"].waitForNonExistence(timeout: 2), "过期提醒勾掉后不再出现在今天（待办卡和时间线都没有）")
        XCTAssertTrue(undo.waitForNonExistence(timeout: 6), "约 4 秒后提示条收起")
        XCTAssertFalse(app.buttons["today-reminder:rm-late"].exists)
        XCTAssertTrue(app.staticTexts["4 个日程 · 4 个待办"].exists)
    }

    /// 录屏用：慢一点勾一条、撤销、再勾，抽帧看填充 / 画勾 / 划线 / 收起 / 展开。
    @MainActor func testR3TodoCheckMotion() throws {
        let app = launch(tab: "今天")
        let dot = app.buttons["today-check-todo:预赛前最终策略上传"]
        let undo = app.buttons["today-undo"]
        XCTAssertTrue(dot.waitForExistence(timeout: 15))
        // 先把待办卡往上拖到屏幕中间（不拖到底：页面拉到底时内容变短，上面几行会跟着往下挪），后面点的时候 XCUITest 也不会自己跳着滚。
        reveal(dot, in: app)
        pause(2.5)
        dot.tap()
        pause(1.8)
        XCTAssertTrue(undo.exists)
        undo.tap()
        pause(1.8)
        XCTAssertTrue(dot.exists)
        dot.tap()
        pause(6)
        XCTAssertFalse(undo.exists, "约 4 秒后提示条收起")
    }

    /// 录屏用：表盘上那一摞点开、收起、再点开，抽帧看卡片长高 / 行错峰上浮 / 收起是否对称、有没有闪。
    @MainActor func testR3DialStackMotion() throws {
        let app = launch(["--ui-r3-dense"], tab: "今天")
        let stack = app.buttons["today-dial-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 15))
        pause(3)
        for _ in 0..<2 {
            stack.tap()
            pause(1.5)
            XCTAssertTrue(app.descendants(matching: .any)["today-stack-list"].exists)
            stack.tap()
            pause(1.5)
            XCTAssertFalse(app.descendants(matching: .any)["today-stack-list"].exists)
        }
    }

    /// 密集日程（现在固定 14:00）：表盘上的标记互不压、也不压「现在」点，三件挨着的并成一摞、点开在卡片里展开；
    /// 时间线上卡片分道互不遮挡，全天的单独一行；页头那排圆不叠。
    @MainActor func testR3DenseDialAndTimeline() throws {
        let app = launch(["--ui-r3-dense"], tab: "今天")
        let stack = app.buttons["today-dial-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 15), "15:20 起三件挨着，并成一摞")
        pause(2.5)
        capture("r3-dense-top", app: app)
        // 表盘：标记、一摞、「现在」点两两不压（按圆心距离 ≥ 两个半径之和）。
        let dial = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'today-dial-'")).allElementsBoundByIndex
        let marks = dial.map { e -> (String, CGPoint, CGFloat) in
            // 圆点按画出来的大小算（热区为了好点放大到 44pt，不算重叠）：一摞 20、现在点 6、下一件 14、其余 11。
            let r: CGFloat = e.identifier == "today-dial-stack" ? 20 : e.identifier == "today-dial-now" ? 6 : (e.value as? String) == "下一件" ? 14 : 11
            return (e.identifier, CGPoint(x: e.frame.midX, y: e.frame.midY), r)
        }
        XCTAssertGreaterThanOrEqual(marks.count, 7, "5 个标记 + 一摞 + 现在点：\(marks.map(\.0))")
        for i in 0..<marks.count { for j in (i + 1)..<marks.count {
            let d = hypot(marks[i].1.x - marks[j].1.x, marks[i].1.y - marks[j].1.y)
            XCTAssertGreaterThanOrEqual(d + 0.5, marks[i].2 + marks[j].2, "\(marks[i].0) 和 \(marks[j].0) 叠在一起了")
        } }
        // 页头那排圆不叠。
        let upcoming = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'today-upcoming-'")).allElementsBoundByIndex.map(\.frame)
        XCTAssertGreaterThanOrEqual(upcoming.count, 2)
        for i in 0..<upcoming.count { for j in (i + 1)..<upcoming.count {
            XCTAssertFalse(upcoming[i].insetBy(dx: 0.5, dy: 0.5).intersects(upcoming[j]), "页头的圆叠在一起了")
        } }
        // 点开那一摞：卡片里展开三行，点一行进那件的详情。
        stack.tap()
        let list = app.descendants(matching: .any)["today-stack-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        for id in ["ev-parcel", "ev-video", "ev-house"] { XCTAssertTrue(app.buttons["today-stack-row-event:" + id].exists, id) }
        pause(1)
        capture("r3-dense-stack-open", app: app)
        app.buttons["today-stack-row-event:ev-video"].tap()
        XCTAssertTrue(app.navigationBars["日程"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["视频会 · 设计"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["日程"].waitForNonExistence(timeout: 5))
        stack.tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 3), "再点一下收起")
        // 时间线：分道之后任何两张卡都不相交；全天的两件单独一行。
        let timeline = app.descendants(matching: .any)["today-timeline"]
        for _ in 0..<4 where !app.descendants(matching: .any)["today-allday"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["today-allday-event:ev-holiday"].exists && app.buttons["today-allday-event:ev-bday"].exists)
        pause(1.5)
        capture("r3-dense-timeline", app: app)
        let cards = timeline.descendants(matching: .button).matching(NSPredicate(format: "identifier BEGINSWITH 'today-event:' OR identifier BEGINSWITH 'today-reminder:'")).allElementsBoundByIndex
        XCTAssertEqual(cards.count, 11, "9 件定时日程 + 2 条提醒都在轴上")
        let frames = cards.map { ($0.identifier, $0.frame) }
        for i in 0..<frames.count { for j in (i + 1)..<frames.count {
            XCTAssertFalse(frames[i].1.insetBy(dx: 0.5, dy: 0.5).intersects(frames[j].1), "\(frames[i].0) 和 \(frames[j].0) 叠在一起了")
        } }
        XCTAssertTrue(app.descendants(matching: .any)["today-now"].exists, "「现在」线还在")
    }
}
