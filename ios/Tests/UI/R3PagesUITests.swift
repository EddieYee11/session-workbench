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
    /// 时间线卡片在首屏下面时：坐标点击不会自动滚，先把它滚进屏幕。
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

    /// 11-02 重做后的今天页：周条 + 日程时间线（带「现在」）+ 日程建议；简报、身体横幅、待办、表盘都不在了，任务入口还是标题旁的小按钮。
    @MainActor func testTodaySchedule() throws {
        let app = launch(tab: "今天")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["today-week"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(any["today-timeline"].firstMatch.exists)
        XCTAssertTrue(any["today-now"].firstMatch.exists, "「现在」标记")
        XCTAssertTrue(any["today-advice"].firstMatch.exists, "日程建议")
        XCTAssertTrue(app.buttons["today-task-hub"].exists)
        for gone in ["today-brief", "today-now-banner", "today-deck", "today-body"] { XCTAssertFalse(any[gone].firstMatch.exists, gone) }
        pause(1.5)
        capture("today-schedule", app: app)
        let review = app.buttons["today-event:ev-review"]
        reveal(review, in: app)
        review.tap()
        XCTAssertTrue(app.navigationBars["日程"].waitForExistence(timeout: 5))
        capture("today-schedule-detail", app: app)
    }

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
        // 10-28 拼图：最近活动是一张宽卡，点开进负荷与活动页。
        let activity = app.buttons["health-tile-activity"]
        for _ in 0..<4 where !(activity.exists && activity.isHittable && activity.frame.maxY < app.frame.maxY - 120) { app.swipeUp(velocity: 500); pause(0.6) }
        // 在拼图自己身上往上滑（屏幕中间是建议卡堆，会吃掉滑动），把整块拼图带进视野
        app.buttons["health-tile-sleep"].swipeUp(velocity: 400)
        pause(1.4)
        capture("health-v3-bento", app: app)
        app.buttons["health-tile-hrv"].swipeUp(velocity: 400)
        pause(1.4)
        capture("health-v3-bento-bottom", app: app)
        activity.tap()
        XCTAssertTrue(app.descendants(matching: .any)["health-load"].firstMatch.waitForExistence(timeout: 4))
        pause(1)
        capture("health-v2-activity", app: app)
    }

    /// 10-28 动态页（替换航程列表 + 它做过的事）：筛选切换、同类合并、点开详情、全部已读。
    @MainActor func testActivityFeed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-cases", "-appearance", "light"]
        app.launchEnvironment["COM_PREVIEW_SHEET"] = "activity"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["activity-feed"].firstMatch.waitForExistence(timeout: 15))
        pause(1.2)
        capture("feed-all", app: app)
        XCTAssertTrue(app.buttons["feed-row-e:eff-3a"].exists, "同一句话里连着的三条命令合成一条")
        XCTAssertFalse(app.buttons["feed-row-e:eff-3b"].exists)
        XCTAssertFalse(app.buttons["feed-row-c:turn:demo"].exists, "聊天里顺手的多步轮次不进动态")
        app.buttons["feed-filter-ledger"].tap()
        pause(0.8)
        XCTAssertTrue(app.buttons["feed-row-e:eff-1"].exists)
        XCTAssertFalse(app.buttons["feed-row-e:eff-2"].exists)
        app.buttons["feed-row-e:eff-1"].tap()
        XCTAssertTrue(app.buttons["feed-verdict-wrong"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["feed-fix"].exists)
        pause(0.8)
        capture("feed-ledger-detail", app: app)
        app.buttons["feed-filter-all"].tap()
        pause(0.5)
        app.buttons["feed-mark-read"].tap()
        pause(1.6)
        XCTAssertTrue(app.buttons["feed-mark-read"].label.contains("都看过了"))
        capture("feed-read", app: app)
    }

    /// 10-28 航程详情的验收工作台：逐条完成条件 + 评审缺口 + 让它补证据。
    @MainActor func testCaseAcceptance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-cases", "-appearance", "light"]
        app.launchEnvironment["COM_PREVIEW_SHEET"] = "case"
        app.launch()
        let panel = app.descendants(matching: .any)["case-acceptance"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 15))
        let ask = app.buttons["acceptance-ask"]
        for _ in 0..<5 where !(ask.exists && ask.isHittable) { app.swipeUp(velocity: 500); pause(0.6) }
        XCTAssertTrue(ask.isHittable, "有缺证据的条件时能一键让它补")
        pause(0.8)
        capture("case-acceptance", app: app)
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
