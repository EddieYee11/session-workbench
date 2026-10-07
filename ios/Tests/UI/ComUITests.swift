import XCTest

final class ComUITests: XCTestCase {
    @MainActor private func app() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "-appearance", "light"]
        app.launch()
        return app
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testFinanceDrilldownAndProjectEvidence() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-今天"].waitForExistence(timeout: 15))
        app.buttons["tab-今天"].tap()
        XCTAssertTrue(app.buttons["今日花销"].waitForExistence(timeout: 5))
        capture("today-money-and-actions", app: app)
        app.buttons["本月花销"].tap()
        XCTAssertTrue(app.navigationBars["支出明细"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["expense-category-food"].waitForExistence(timeout: 5))
        capture("expense-ranking", app: app)
        app.buttons["expense-category-food"].tap()
        XCTAssertTrue(app.staticTexts["午饭 · 一碗面"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2026-10-07"].exists)
        capture("expense-category-transactions", app: app)
        app.buttons["完成"].firstMatch.tap()
        app.buttons["完成"].firstMatch.tap()
        app.buttons["tab-工作"].tap()
        XCTAssertTrue(app.buttons["project-card-preview-project"].waitForExistence(timeout: 5))
        capture("work-project-board", app: app)
        app.buttons["project-card-preview-project"].tap()
        XCTAssertTrue(app.buttons["project-item-preview-board-item"].waitForExistence(timeout: 5))
        capture("project-progress", app: app)
        app.buttons["project-item-preview-board-item"].tap()
        XCTAssertTrue(app.navigationBars["进展依据"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["会话中的依据"].exists)
        capture("project-source-evidence", app: app)
    }

    @MainActor func testAgencyPreparePostponeGoalAndSettings() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-今天"].waitForExistence(timeout: 15))
        app.buttons["tab-今天"].tap()
        capture("agency-today", app: app)
        if !app.buttons["看下一步"].firstMatch.isHittable { app.swipeUp() }
        app.buttons["看下一步"].firstMatch.tap()
        XCTAssertTrue(app.buttons["agency-prepare"].waitForExistence(timeout: 5))
        app.buttons["agency-prepare"].tap()
        XCTAssertTrue(app.staticTexts["资料已整理"].waitForExistence(timeout: 5))
        capture("agency-prepared", app: app)
        app.buttons["完成"].tap()
        app.buttons["晚点"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["agency-action-result"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["给今天留一段专注时间"].exists)
        capture("agency-postponed", app: app)
        if !app.buttons["主动性设置"].isHittable { app.swipeDown(); app.swipeDown() }
        app.buttons["主动性设置"].tap()
        XCTAssertTrue(app.navigationBars["主动性"].waitForExistence(timeout: 5))
        app.switches["暂停主动消息"].tap()
        XCTAssertTrue(app.staticTexts["先安静一会儿。"].exists)
        capture("agency-settings", app: app)
        app.swipeUp()
        app.buttons["保存安排"].tap()
        XCTAssertTrue(app.staticTexts["主动整理已暂停"].waitForExistence(timeout: 5))
        app.buttons["tab-任务"].tap()
        app.buttons["目标"].tap()
        app.buttons["添加目标"].tap()
        for (id, text) in [("goal-title", "Finish a film"), ("goal-outcome", "A finished video"), ("goal-next", "Choose the footage")] {
            let field = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(text)
        }
        app.swipeUp()
        app.buttons["开始跟进"].tap()
        XCTAssertTrue(app.staticTexts["Finish a film"].waitForExistence(timeout: 5))
        capture("agency-goal-created", app: app)
    }

    @MainActor func testRichReplyAndConnectionActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-rich-reply", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts["今日重点"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["下一步"].exists)
        capture("rich-agent-bubble", app: app)
        app.buttons["设置与连接"].tap()
        app.buttons["管理数据连接"].tap()
        XCTAssertTrue(app.navigationBars["数据连接"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["未连接"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["已连接"].exists)
        capture("connection-list", app: app)
        app.buttons.containing(.staticText, identifier: "GitHub").firstMatch.tap()
        XCTAssertTrue(app.buttons["断开同步"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["连接"].exists)
        capture("connected-source-actions", app: app)
    }
    @MainActor func testNavigationAndScreenshots() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-聊天"].waitForExistence(timeout: 15))
        capture("01-chat", app: app)
        for (title, name) in [("今天", "02-today"), ("任务", "03-tasks"), ("记忆", "04-memory"), ("工作", "05-com")] {
            let tab = app.buttons["tab-" + title]
            XCTAssertTrue(tab.exists)
            tab.tap()
            XCTAssertTrue(tab.isSelected)
            capture(name, app: app)
        }
        app.buttons["设置与连接"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["tab-聊天"].tap()
        let input = app.descendants(matching: .any)["message-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Hello Com")
        XCTAssertTrue(app.buttons["发送消息"].isHittable)
        capture("06-keyboard", app: app)
    }
    @MainActor func testFiltersAndDetails() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-今天"].waitForExistence(timeout: 15))
        app.buttons["tab-今天"].tap()
        if !app.buttons.containing(.staticText, identifier: "给今天留一段专注时间").firstMatch.isHittable { app.swipeUp() }
        app.buttons.containing(.staticText, identifier: "给今天留一段专注时间").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["下一步"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["tab-任务"].tap()
        app.buttons["待决定"].tap()
        XCTAssertTrue(app.staticTexts["查看拍摄素材"].exists)
        XCTAssertFalse(app.staticTexts["整理本周内容计划"].exists)
        app.buttons.containing(.staticText, identifier: "查看拍摄素材").firstMatch.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        capture("07-task-detail", app: app)
        app.buttons["完成"].tap()
        app.buttons["tab-记忆"].tap()
        let search = app.textFields["搜索记忆"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("不存在的记忆")
        XCTAssertTrue(app.staticTexts["这里还留着空白"].exists)
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(app.staticTexts["内容创作时，先梳理叙事结构，再决定画面和剪辑节奏。"].exists)
    }
    @MainActor func testSharedKnowledgeDetailAndSource() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-记忆"].waitForExistence(timeout: 15))
        app.buttons["tab-记忆"].tap()
        let search = app.textFields["搜索记忆"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("共享知识")
        let item = app.buttons.containing(.staticText, identifier: "协作偏好 · 共享知识").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.staticTexts["来自共享知识库，来源文件更新后会自动同步。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["纠正这条记忆"].exists)
        app.buttons["原始来源"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "_global/记忆库/知识/")).firstMatch.waitForExistence(timeout: 5))
        capture("shared-memory-detail", app: app)
    }

    @MainActor func testInlineVoiceAutomaticallySendsOneTextMessage() throws {
        let app = app()
        XCTAssertTrue(app.buttons["开始语音"].waitForExistence(timeout: 15))
        app.buttons["开始语音"].tap()
        XCTAssertTrue(app.staticTexts["正在录音"].waitForExistence(timeout: 5))
        app.buttons["完成录音"].tap()
        let text = "帮我整理今天的安排，再留一点时间去攀岩。"
        XCTAssertTrue(app.staticTexts["voice-rhythmic-text"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["确认发送"].exists)
        XCTAssertTrue(app.buttons["开始语音"].waitForExistence(timeout: 8))
        let bubbles = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat-bubble-", text))
        XCTAssertEqual(bubbles.count, 1)
        sleep(2)
        XCTAssertEqual(bubbles.count, 1, "The accepted reply must replace the same voice outbox entry")
        capture("voice-auto-sent", app: app)
    }

    @MainActor func testVoiceCanFinishWhilePreviousTextIsSending() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-voice-during-send"]
        app.launch()
        XCTAssertTrue(app.buttons["开始语音"].waitForExistence(timeout: 15))
        app.buttons["开始语音"].tap()
        let finish = app.buttons["完成录音"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isEnabled)
        finish.tap()
        let text = "帮我整理今天的安排，再留一点时间去攀岩。"
        let bubbles = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat-bubble-", text))
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in bubbles.count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 8), .completed)
    }

    @MainActor func testQuickVoiceWindow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ui-quick-voice", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts["正在录音"].waitForExistence(timeout: 15))
        app.buttons["完成录音"].tap()
        XCTAssertFalse(app.buttons["确认发送"].exists)
        XCTAssertTrue(app.buttons["tab-聊天"].waitForExistence(timeout: 8))
        let text = "帮我整理今天的安排，再留一点时间去攀岩。"
        let bubbles = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat-bubble-", text))
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in bubbles.count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 8), .completed)
        XCTAssertEqual(bubbles.count, 1)
        capture("quick-voice-auto-sent", app: app)
    }

    @MainActor func testCancelledVoiceNeverSendsLateTranscript() throws {
        let app = app()
        XCTAssertTrue(app.buttons["开始语音"].waitForExistence(timeout: 15))
        app.buttons["开始语音"].tap()
        app.buttons["完成录音"].tap()
        app.buttons["放弃录音"].tap()
        sleep(2)
        let bubbles = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat-bubble-", "帮我整理今天的安排，再留一点时间去攀岩。"))
        XCTAssertEqual(bubbles.count, 0)
    }

    @MainActor func testKeyboardLiftsTimelineAndSendKeepsOneBubble() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-long-chat", "-appearance", "light"]
        app.launch()
        let last = app.staticTexts["chat-bubble-history-34"]
        XCTAssertTrue(last.waitForExistence(timeout: 15))
        let before = last.frame
        let input = app.descendants(matching: .any)["message-input"].firstMatch
        input.tap(); input.typeText("Motion message")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThan(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        XCTAssertLessThan(last.frame.maxY, input.frame.minY)
        XCTAssertLessThan(last.frame.minY, before.minY - 100, "The timeline must rise together with the composer")
        capture("12-keyboard-lifts-history", app: app)
        app.buttons["发送消息"].tap()
        let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", "Motion message"))
        XCTAssertTrue(bubble.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(bubble.count, 1)
        let received = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat-bubble-server-", "Motion message")).firstMatch
        XCTAssertTrue(received.waitForExistence(timeout: 5))
        XCTAssertEqual(bubble.count, 1, "The local row must be replaced, never duplicated")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Sending keeps the keyboard ready for the next message")
        capture("13-landed-message", app: app)
    }

    @MainActor func testIncomingReplyPreservesHistoryPosition() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-long-chat", "--ui-incoming-control", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat-bubble-history-34"].waitForExistence(timeout: 15))
        app.swipeDown(); app.swipeDown()
        app.buttons["模拟新回复"].tap()
        let jump = app.buttons["1 条新回复，回到最新消息"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        capture("14-unread-with-reading-position", app: app)
        jump.tap()
        XCTAssertTrue(app.staticTexts["新的回复已经到达，阅读位置保留。"].waitForExistence(timeout: 5))
        XCTAssertFalse(jump.exists)
    }

    @MainActor func testLongMarkdownScrollReturnsToLatest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-stress-chat", "--ui-incoming-control", "-appearance", "light"]
        app.launch()
        let last = app.staticTexts["chat-bubble-stress-300"]
        XCTAssertTrue(last.waitForExistence(timeout: 15))
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        let jump = app.buttons["chat-jump-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(jump.frame.width, 44)
        XCTAssertGreaterThanOrEqual(jump.frame.height, 44)
        jump.tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            last.exists && last.isHittable && !jump.exists
        }, object: nil)
        let result = XCTWaiter.wait(for: [returned], timeout: 5)
        capture("stress-first-return", app: app)
        XCTAssertEqual(result, .completed)
        app.swipeDown(); app.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        app.buttons["模拟新回复"].tap()
        XCTAssertTrue(jump.exists, "Incoming data must not pull the reader away from history")
        jump.tap()
        let reply = app.staticTexts["新的回复已经到达，阅读位置保留。"]
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in reply.exists && reply.isHittable && !jump.exists }, object: nil)
        let arrivedResult = XCTWaiter.wait(for: [arrived], timeout: 5)
        XCTAssertEqual(arrivedResult, .completed)
        capture("stress-latest-visible", app: app)
    }

    @MainActor func testReadingAnchorDoesNotMoveAfterLayoutOrIncomingReply() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-stress-chat", "--ui-incoming-control", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat-bubble-stress-300"].waitForExistence(timeout: 15))
        app.swipeDown(velocity: .slow); app.swipeDown(velocity: .slow)
        let bubbles = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-bubble-stress-"))
        let anchor = try XCTUnwrap(bubbles.allElementsBoundByIndex.first { $0.isHittable && $0.frame.maxY > 200 && $0.frame.minY < 700 })
        let id = anchor.identifier
        let y = anchor.frame.minY
        // No finger input: neither deferred Markdown layout nor incoming data may move this row.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.staticTexts[id].frame.minY, y, accuracy: 2)
        app.buttons["模拟新回复"].tap()
        XCTAssertTrue(app.buttons["chat-jump-latest"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts[id].frame.minY, y, accuracy: 2)
        capture("stable-reading-anchor", app: app)
    }

    @MainActor func testRejectedSendReturnsToDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-send-rejected", "-appearance", "light"]
        app.launch()
        let input = app.descendants(matching: .any)["message-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap(); input.typeText("Keep my draft")
        app.buttons["发送消息"].tap()
        XCTAssertTrue(app.buttons["回到草稿"].waitForExistence(timeout: 5))
        app.buttons["回到草稿"].tap()
        XCTAssertEqual(input.value as? String, "Keep my draft")
    }

    @MainActor func testReducedMotionSendRemainsVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-reduce-motion", "-appearance", "light"]
        app.launch()
        let input = app.descendants(matching: .any)["message-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap(); input.typeText("Reduced motion message")
        app.buttons["发送消息"].tap()
        let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", "Reduced motion message"))
        XCTAssertTrue(bubble.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(bubble.count, 1)
        capture("15-reduced-motion-message", app: app)
    }

}
