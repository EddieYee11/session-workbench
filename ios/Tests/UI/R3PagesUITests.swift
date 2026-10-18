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

    /// 10-17 收拢后的今天页：简报标题 + 可收起的要点（资讯左滑不感兴趣）、下一件 + 身体横幅两半各自展开、待办 / 时间线分段切换；
    /// 微信、拍板、一句话交代和整行的任务入口都不在了，任务入口缩成标题旁的小按钮。
    @MainActor func testTodayCockpit() throws {
        let app = launch(tab: "今天")
        XCTAssertTrue(app.staticTexts["today-headline"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["today-headline"].label.contains("电量 47"))
        let news = app.descendants(matching: .any)["today-brief-point-3"].firstMatch
        XCTAssertTrue(news.waitForExistence(timeout: 3), "要点默认展开，4 条")
        XCTAssertFalse(app.textFields["today-quick-add"].exists, "一句话交代已去掉")
        XCTAssertFalse(app.descendants(matching: .any)["today-decision-card"].firstMatch.exists)
        XCTAssertTrue(app.buttons["today-task-hub"].exists, "任务入口缩成小按钮")
        XCTAssertTrue(app.descendants(matching: .any)["today-deck"].firstMatch.exists)
        pause(1.5)
        capture("today-v2-top", app: app)
        // 资讯左滑：不感兴趣，这条收起。
        news.swipeLeft()
        XCTAssertTrue(news.waitForNonExistence(timeout: 3), "左滑掉的资讯收起")
        // 收起要点 → 再展开。
        app.descendants(matching: .any)["today-brief-toggle"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["today-brief-point-0"].firstMatch.waitForNonExistence(timeout: 3))
        pause(1)
        capture("today-v2-brief-collapsed", app: app)
        // 身体那半：展开身体卡，再点进 7 天明细。
        app.buttons["today-body-toggle"].tap()
        let body = app.buttons["today-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 3))
        pause(1.2)
        capture("today-v2-body-open", app: app)
        body.tap()
        XCTAssertTrue(app.descendants(matching: .any)["health-detail"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        pause(1)
        // 下一件那半：换成表盘（身体收起，同一时刻只开一边）。
        app.buttons["today-next-toggle"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["today-dial-now"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["today-body"].exists)
        pause(1.2)
        capture("today-v2-dial-open", app: app)
        app.buttons["today-next-toggle"].tap()
        // 分段：切到时间线。
        app.buttons["today-deck-timeline"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["today-timeline"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["today-todo-card"].firstMatch.exists)
        pause(1.2)
        capture("today-v2-timeline", app: app)
    }

    /// 半圈表盘：会动（每秒取一次现在）、外圈有整点时间、切眼前 / 半天 / 全天、点圆点进日程详情、沿弧拖读出时间。
    @MainActor func testTodayDialLiveAndInteractive() throws {
        let app = launch(["--ui-today-dial"], tab: "今天")
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
        let app = launch(["--ui-r3-dense", "--ui-today-dial", "--ui-today-timeline"], tab: "今天")
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
    /// 时间线上卡片分道互不遮挡，全天的单独一行。（10-17 页头那排圆已去掉。）
    @MainActor func testR3DenseDialAndTimeline() throws {
        let app = launch(["--ui-r3-dense", "--ui-today-dial", "--ui-today-timeline"], tab: "今天")
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

    // MARK: 健康页（10-17）

    /// 健康页二版：一级只有恢复环 + 维度小环（点开冒一句）、「为什么」收着、建议卡堆（点翻面 / 右滑做完）、六格指标（点开 zoom 进趋势页）、活动徽章。
    @MainActor func testHealthPage() throws {
        let app = launch(tab: "健康")
        XCTAssertTrue(app.descendants(matching: .any)["health-hero"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["health-headline"].label, "恢复不错，下午可以上强度")
        XCTAssertFalse(app.descendants(matching: .any)["health-summary"].firstMatch.exists, "解释默认收着")
        pause(1.8)
        capture("health-v2-top", app: app)
        app.buttons["health-dim-load"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["health-dim-note"].firstMatch.waitForExistence(timeout: 2))
        app.buttons["health-why"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["health-summary"].firstMatch.waitForExistence(timeout: 2))
        pause(1)
        capture("health-v2-why", app: app)
        app.buttons["health-why"].tap()
        // 建议卡堆：点一下翻面，再右滑做完。
        let card = app.descendants(matching: .any)["health-action-top"].firstMatch
        for _ in 0..<4 where !(card.exists && card.frame.maxY < app.frame.maxY - 140) { app.swipeUp(velocity: 500); pause(0.6) }
        card.tap()
        pause(1)
        capture("health-v2-card-flipped", app: app)
        card.swipeRight(velocity: .fast)
        pause(1)
        XCTAssertEqual(app.descendants(matching: .any)["health-actions-progress"].firstMatch.label, "完成 1 / 4")
        capture("health-v2-card-done", app: app)
        // 指标方格 → HRV 趋势页。
        let tile = app.buttons["health-tile-hrv"]
        for _ in 0..<4 where !(tile.exists && tile.isHittable && tile.frame.maxY < app.frame.maxY - 120) { app.swipeUp(velocity: 500); pause(0.6) }
        pause(0.8)
        capture("health-v2-grid", app: app)
        tile.tap()
        XCTAssertTrue(app.descendants(matching: .any)["health-hrv"].firstMatch.waitForExistence(timeout: 4))
        app.buttons["health-span-7"].tap()
        pause(1.2)
        capture("health-v2-hrv-page", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        for _ in 0..<4 where !app.buttons["health-activity-0"].exists { app.swipeUp(velocity: 500); pause(0.6) }
        app.buttons["health-activity-0"].tap()
        pause(1)
        capture("health-v2-activity", app: app)
    }

    /// 顶栏的她：每个 tab 一套造型，切 tab 时跳一下换装。录屏抽帧看；这里每页落定后截一张顶栏。
    @MainActor func testCharacterOutfitPerTab() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        for tab in ["Com", "下一步", "今天", "健康", "工作"] {
            app.buttons["tab-" + tab].tap()
            pause(0.18)
            capture("outfit-\(tab)-mid", app: app)
            pause(1.2)
            capture("outfit-\(tab)", app: app)
        }
    }
}
