import XCTest

/// Her 式私人助理聊天观感验收：时间分隔（≥10 分钟）、顺口提醒同气泡（metadata.kind=nudge）、确认词快捷回复实色胶囊。
final class HerChatUITests: XCTestCase {
    private let outDir = URL(fileURLWithPath: "/Users/eddiegao/AI_Work_System/work/工具与效率/会话工作台/ios/verification/her")

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    @MainActor private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    @MainActor func testHerChatTimeSeparatorAndNudgeBubble() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-her-demo", "-appearance", "light"]
        app.launch()

        let timeSeparator = app.staticTexts["chat-time-separator"].firstMatch
        XCTAssertTrue(timeSeparator.waitForExistence(timeout: 12), "间隔 ≥10 分钟的相邻消息间应出现时间分隔")
        XCTAssertEqual(timeSeparator.label, "9:46")

        XCTAssertTrue(app.staticTexts["好 叫吧"].waitForExistence(timeout: 5))
        let nudgeBubble = app.descendants(matching: .any)["agent-bubble-her-4"].firstMatch
        XCTAssertTrue(nudgeBubble.waitForExistence(timeout: 5), "顺口提醒消息应使用普通助理气泡展示")
        XCTAssertFalse(app.buttons["proactive-action-her-4"].exists, "kind=nudge 不加额外操作标签")
        XCTAssertFalse(app.buttons["proactive-stack"].exists, "kind=nudge 不折进主动消息卡片框")

        Thread.sleep(forTimeInterval: 0.6)
        saveScreenshot(app, name: "her-chat-timeline")
    }

    @MainActor func testHerConfirmSuggestionChipAccentFill() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-her-demo", "--ui-her-confirm", "-appearance", "light"]
        app.launch()

        let chips = app.descendants(matching: .any)["suggestion-chips"].firstMatch
        XCTAssertTrue(chips.waitForExistence(timeout: 12), "待确认消息底部应展示快捷回复胶囊")

        let confirmChip = app.buttons["suggestion-0"]
        let secondaryChip = app.buttons["suggestion-1"]
        XCTAssertTrue(confirmChip.waitForExistence(timeout: 5))
        XCTAssertTrue(secondaryChip.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmChip.label.contains("叫"))
        XCTAssertEqual(confirmChip.value as? String, "confirm", "确认词胶囊应使用实色填充")
        XCTAssertTrue(secondaryChip.label.contains("再想想"))
        XCTAssertEqual(secondaryChip.value as? String, "outline", "其余选项保持描边")

        Thread.sleep(forTimeInterval: 0.6)
        saveScreenshot(app, name: "her-confirm-chips")
    }
}
