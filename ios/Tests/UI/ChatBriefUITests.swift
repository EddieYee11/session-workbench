import XCTest

/// 主聊天「回来简报」卡：出现 → 拖把手收起 → 胶囊停靠 → 点把手重开 → 打字自动收起。
final class ChatBriefUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testChatBriefDragCollapseReopenAndTypeCollapse() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-chat-brief", "-appearance", "light"]
        app.launch()

        let card = app.descendants(matching: .any)["chat-brief-card"]
        let handle = app.buttons["chat-brief-handle"]
        XCTAssertTrue(card.waitForExistence(timeout: 12), "回来简报应在进入主聊天后自动垂下")
        XCTAssertTrue(handle.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["chat-brief-text"].exists)
        add(XCTAttachment(screenshot: app.screenshot()))

        // 慢拖把手往上：跟手收，松手后整卡收回顶栏，胶囊停靠。
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // 拖到顶栏里（-260pt）：手指离开把手，手势会被系统取消，也必须照常收起并停靠。
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitGone(card, timeout: 3), "往上拖过 35% 应收起")
        XCTAssertTrue(handle.waitForExistence(timeout: 2), "收起后把手停在顶栏下")

        // 点把手重新拉开。
        handle.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 3), "点停靠的把手应重新展开")

        // 开始打字：简报让位。
        let input = app.textFields["message-input"].exists ? app.textFields["message-input"] : app.textViews["message-input"]
        input.tap()
        input.typeText("在")
        XCTAssertTrue(waitGone(card, timeout: 3), "开始打字应收起简报")
    }

    @MainActor func testChatBriefDockedHandleAfterAutoCollapse() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-chat-brief", "--ui-chat-brief-collapse", "-appearance", "light"]
        app.launch()
        // 卡片展开 2.5s 后自动收起，启动本身就可能超过这个时长，所以不等卡片出现，只看收起之后。
        let card = app.descendants(matching: .any)["chat-brief-card"]
        XCTAssertTrue(app.textFields["message-input"].waitForExistence(timeout: 10) || app.textViews["message-input"].exists)
        Thread.sleep(forTimeInterval: 5)
        let tree = app.debugDescription.split(separator: "\n").filter { $0.contains("brief") }
        print("BRIEFTREE>>", tree.joined(separator: " | "))
        XCTAssertTrue(waitGone(card, timeout: 2), "自动收起后卡片应消失")
        XCTAssertTrue(app.buttons["chat-brief-handle"].waitForExistence(timeout: 2), "自动收起后把手应停靠")
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
