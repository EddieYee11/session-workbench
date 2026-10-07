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
        app.buttons.containing(.staticText, identifier: "给今天留一段专注时间").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["事项"].waitForExistence(timeout: 5))
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

    @MainActor func testInlineVoiceAndEditableTranscript() throws {
        let app = app()
        XCTAssertTrue(app.buttons["开始语音"].waitForExistence(timeout: 15))
        app.buttons["开始语音"].tap()
        XCTAssertTrue(app.staticTexts["正在录音"].waitForExistence(timeout: 5))
        capture("08-inline-voice", app: app)
        app.buttons["完成录音"].tap()
        XCTAssertTrue(app.textFields["voice-transcript-input"].waitForExistence(timeout: 5) || app.textViews["voice-transcript-input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["确认发送"].exists)
        capture("09-voice-transcript", app: app)
        app.buttons["放弃录音"].tap()
        XCTAssertTrue(app.buttons["开始语音"].waitForExistence(timeout: 5))
    }

    @MainActor func testQuickVoiceWindow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ui-quick-voice", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts["正在录音"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["完成录音"].exists)
        XCTAssertFalse(app.buttons["确认发送"].exists)
        capture("10-action-button-voice", app: app)
        app.buttons["完成录音"].tap()
        XCTAssertTrue(app.buttons["确认发送"].waitForExistence(timeout: 5))
        app.buttons["保留录音并收起"].tap()
        XCTAssertTrue(app.buttons["tab-聊天"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["确认发送"].exists)
        capture("11-preserved-transcript", app: app)
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
