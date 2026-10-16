import XCTest

/// r3-work：顶栏人物（全 App 一个实例）与工作页（ChatGPT / Claude App 式）的验收。
/// `testRec*` 是录屏脚本：每一步之间停够久，`simctl io recordVideo` 录下来再按 30fps 抽帧看过渡。
final class R3WorkUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-appearance", "light", "--ui-r3-work"] + extra
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
    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    @MainActor private func openWork(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        app.buttons["tab-工作"].tap()
        XCTAssertTrue(app.buttons["work-sidebar"].waitForExistence(timeout: 5))
    }
    @MainActor private func openSidebar(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["work-sidebar"].tap()
        let panel = element("work-sidebar-panel", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        pause(0.6)
        return panel
    }

    // MARK: - 任务 1：顶栏人物

    /// 全 App 只有一个她；切四个 tab 她都站在同一个位置，只有标题换字。
    @MainActor func testTopBarFigureIsOneInstanceWithStableAnchor() throws {
        let app = launch()
        let figure = element("agent-stage-pull-zone", in: app)
        XCTAssertTrue(figure.waitForExistence(timeout: 15))
        let anchor = figure.frame
        for (tab, head) in [("下一步", "下一步"), ("今天", "今天"), ("工作", "Codex"), ("Com", "Com")] {
            app.buttons["tab-" + tab].tap()
            pause(0.8)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "agent-stage-pull-zone").count, 1, "全 App 只有一个她")
            XCTAssertEqual(figure.frame.minX, anchor.minX, accuracy: 0.5, "切到「\(tab)」她不挪位")
            XCTAssertEqual(figure.frame.minY, anchor.minY, accuracy: 0.5)
            XCTAssertTrue(figure.label.hasPrefix(head + "，"), "标题换成「\(head)」：\(figure.label)")
        }
        // 工作页：左上侧栏、右上新对话（ChatGPT 排布），她在中间。
        app.buttons["tab-工作"].tap()
        let sidebar = app.buttons["work-sidebar"], new = app.buttons["work-new"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3))
        XCTAssertTrue(new.exists)
        let width = app.windows.firstMatch.frame.width
        XCTAssertLessThan(sidebar.frame.maxX, width * 0.25, "侧栏按钮在左上")
        XCTAssertGreaterThan(new.frame.minX, width * 0.75, "新对话在右上")
        XCTAssertGreaterThan(figure.frame.midX, width * 0.4)
        XCTAssertLessThan(figure.frame.midX, width * 0.7, "她在中间")
        capture("r3-topbar-work", app: app)
    }

    /// 点她弹菜单（popover 对准她）；按住往下拉出工作台，右上按钮变成收起。
    @MainActor func testMenuAnchorsToFigureAndStagePullsDown() throws {
        let app = launch()
        let figure = element("agent-stage-pull-zone", in: app)
        XCTAssertTrue(figure.waitForExistence(timeout: 15))
        figure.tap()
        let menu = element("main-menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertEqual(menu.frame.midX, figure.frame.midX, accuracy: 160)
        XCTAssertGreaterThan(menu.frame.minY, figure.frame.minY, "菜单从她下面弹出")
        capture("r3-menu", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 3))
        figure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.08, thenDragTo: figure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 3)))
        XCTAssertTrue(element("agent-stage-panel", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["agent-stage-close"].waitForExistence(timeout: 3))
        capture("r3-stage", app: app)
        app.buttons["agent-stage-close"].tap()
        XCTAssertTrue(element("agent-stage-panel", in: app).waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["top-search"].waitForExistence(timeout: 3), "收起后右上回到搜索")
    }

    // MARK: - 任务 2：工作页

    /// b) 侧栏从左滑入占满整屏高度（连原来 Dock 那一截），主内容连同 Dock 推到右边；右缘点一下、左滑、✕ 都能收。
    @MainActor func testSidebarFillsScreenAndPushesDock() throws {
        let app = launch()
        openWork(app)
        let screen = app.windows.firstMatch.frame
        let dock = app.buttons["tab-Com"]
        let dockBefore = dock.frame
        var panel = openSidebar(app)
        XCTAssertLessThan(panel.frame.minY, 100, "侧栏内容从顶上开始（底色铺到状态栏下面，见录屏抽帧）")
        XCTAssertGreaterThan(panel.frame.maxY, screen.maxY - 40, "侧栏一直到底，不缺 Dock 那一块")
        XCTAssertGreaterThan(dock.frame.minX, dockBefore.minX + 200, "Dock 跟着主内容推到右边")
        XCTAssertFalse(dock.isHittable, "Dock 被推走、压暗，点不到")
        // 上一轮遗留：第 4 个 Agent 胶囊 Claude 不能被侧栏边缘切掉。
        app.buttons["work-host-mini"].tap()
        let claude = app.buttons["work-agent-claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(claude.frame.maxX, panel.frame.maxX - 8, "Claude 胶囊完整露出来")
        XCTAssertTrue(app.buttons["work-agent-codex"].frame.maxX <= panel.frame.maxX - 8)
        capture("r3-sidebar", app: app)
        // 右缘那一条：点一下收起。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(dock.isHittable, "收起后 Dock 回来")
        XCTAssertEqual(dock.frame.minX, dockBefore.minX, accuracy: 1)
        // 左滑收起。
        panel = openSidebar(app)
        panel.swipeLeft()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        // ✕ 收起。
        panel = openSidebar(app)
        app.buttons["work-sidebar-close"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
    }

    /// c) 点侧栏里的会话：侧栏收回，主区域原地变成聊天——没有导航栏、没有 sheet；右边我、左边 Agent（logo + 名字）。
    @MainActor func testSessionOpensInPlaceAsLeftRightChat() throws {
        let app = launch()
        openWork(app)
        _ = openSidebar(app)
        app.buttons["work-host-mini"].tap()
        app.buttons["work-agent-all"].tap()
        let session = app.buttons["work-thread-session:session-1"]
        XCTAssertTrue(session.waitForExistence(timeout: 3))
        session.tap()
        XCTAssertTrue(element("work-sidebar-panel", in: app).waitForNonExistence(timeout: 3), "侧栏收回")
        XCTAssertTrue(element("work-chat", in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(app.navigationBars.count, 0, "原地聊天，不推二级页")
        let width = app.windows.firstMatch.frame.width
        let mine = element("work-bubble-s1-u2", in: app)
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(mine.frame.maxX, width - 40, "我的话在右边")
        XCTAssertGreaterThan(mine.frame.minX, width * 0.25)
        // 审批卡在流里。
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "等待你的决定")).firstMatch.waitForExistence(timeout: 3))
        capture("r3-session-bottom", app: app)
        app.swipeDown(); app.swipeDown()
        let reply = element("work-reply-s1-a1", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 3))
        XCTAssertLessThan(reply.frame.minX, 40, "Agent 的回复在左边")
        XCTAssertTrue(element("work-reply-agent", in: app).exists, "回复上挂 Agent 的 logo 和名字")
        XCTAssertTrue(app.buttons["work-steps"].firstMatch.exists, "工具步骤折成一行")
        app.buttons["work-steps"].firstMatch.tap()
        XCTAssertTrue(element("work-steps-list", in: app).waitForExistence(timeout: 3))
        capture("r3-session-top", app: app)
        // 标题菜单里是这段会话的操作（原 WorkDetailView 右上角）。
        app.buttons["work-title-menu"].tap()
        XCTAssertTrue(app.buttons["置顶"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["结束会话"].exists)
        capture("r3-session-menu", app: app)
        app.buttons["置顶"].tap()
        // 切到正在跑的那段：步骤行在动、输入框右边是停止。
        _ = openSidebar(app)
        app.buttons["work-thread-session:session-2"].tap()
        XCTAssertTrue(app.buttons["work-steps-live"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["work-stop"].exists)
        capture("r3-session-running", app: app)
        app.buttons["work-stop"].tap()
        XCTAssertTrue(app.buttons["work-stop"].waitForNonExistence(timeout: 3))
        // 已结束的会话也照样有输入框：发出去由后端先接上原会话（不再要先点「恢复此会话输入」）。
        _ = openSidebar(app)
        app.buttons["work-agent-claude"].tap()
        app.buttons["work-thread-session:session-3"].tap()
        XCTAssertTrue(app.textFields["work-input"].waitForExistence(timeout: 5))
        // 右上新对话：回到首页。
        app.buttons["work-new"].tap()
        XCTAssertTrue(element("work-new-chat", in: app).waitForExistence(timeout: 3))
    }

    /// d) 首页输入框发出去：同一页原地变成聊天，我的话在右，Agent 的回复在左边流出来。
    @MainActor func testHomeSendTurnsIntoChatInPlace() throws {
        let app = launch()
        openWork(app)
        XCTAssertTrue(element("work-new-chat", in: app).exists)
        let input = app.textFields["work-input"]
        input.tap()
        input.typeText("帮我看看这周的选题")
        app.buttons["work-send"].tap()
        XCTAssertTrue(element("work-new-chat", in: app).waitForNonExistence(timeout: 3), "首页淡出")
        XCTAssertTrue(element("work-chat", in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(app.navigationBars.count, 0)
        let bubble = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "work-bubble-", "帮我看看这周的选题")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(bubble.frame.maxX, app.windows.firstMatch.frame.width - 60, "我的话在右边")
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "要我先把探馆")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "回复流出来")
        XCTAssertLessThan(reply.frame.minX, 60, "回复在左边")
        capture("r3-home-send", app: app)
        // 接着在这段里说。
        input.tap()
        input.typeText("先写探馆那支")
        app.buttons["work-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "work-bubble-", "先写探馆那支")).firstMatch.waitForExistence(timeout: 3))
    }

    /// e) 输入框右边的设置按钮没了；里面的项目目录、模型、推理强度在「+」里，派给谁在顶栏标题里。
    @MainActor func testComposerSettingsMovedToPlusAndTitle() throws {
        let app = launch()
        openWork(app)
        XCTAssertFalse(app.buttons["选目录和模型"].exists, "设置按钮删掉了")
        app.buttons["work-composer-plus"].tap()
        XCTAssertTrue(app.buttons["项目目录：AI_Work_System"].waitForExistence(timeout: 3))
        let modelItem = app.buttons["模型：执行器默认"]
        XCTAssertTrue(modelItem.exists)
        capture("r3-plus-menu", app: app)
        modelItem.tap()
        XCTAssertTrue(app.buttons["GPT-5.5"].waitForExistence(timeout: 3))
        app.buttons["GPT-5.5"].tap()
        app.buttons["work-composer-plus"].tap()
        XCTAssertTrue(app.buttons["模型：GPT-5.5"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["推理强度：默认"].exists, "选了带推理强度的模型才出现")
        app.buttons["推理强度：默认"].tap()
        XCTAssertTrue(app.buttons["high"].waitForExistence(timeout: 3))
        app.buttons["high"].tap()
        app.buttons["work-composer-plus"].tap()
        XCTAssertTrue(app.buttons["推理强度：high"].waitForExistence(timeout: 3))
        app.buttons["项目目录：AI_Work_System"].tap()
        XCTAssertTrue(app.navigationBars["工作目录"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        // 派给谁：顶栏标题。
        app.buttons["work-title-menu"].tap()
        let claude = app.buttons["Claude Code"]
        XCTAssertTrue(claude.waitForExistence(timeout: 3))
        capture("r3-title-menu", app: app)
        claude.tap()
        let figure = element("agent-stage-pull-zone", in: app)
        let changed = NSPredicate(format: "label BEGINSWITH %@", "Claude Code，")
        expectation(for: changed, evaluatedWith: figure)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.textFields["让 Claude Code 做点什么"].exists || app.textFields["work-input"].placeholderValue == "让 Claude Code 做点什么")
    }

    // MARK: - 录屏脚本

    /// 切 tab：Com → 下一步 → 今天 → 工作 → Com，来回两轮。
    @MainActor func testRecTabs() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        pause(1.5)
        for _ in 0..<2 {
            for tab in ["下一步", "今天", "工作", "Com"] {
                app.buttons["tab-" + tab].tap()
                pause(1.6)
            }
        }
    }

    /// 状态轮换（每步 3 秒）：空闲 → 思考 → 翻资料 → 干活 → 等你点头 → 送达 → 空闲；中间气泡出现、换字、收起。
    @MainActor func testRecStates() throws {
        let app = launch(["--ui-r3-cycle"])
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        pause(22)
    }

    /// 气泡出现、换字、收起（`--ui-work-process-live` 按脚本往前走，最后做完）。
    @MainActor func testRecBubble() throws {
        let app = launch(["--ui-work-process", "--ui-work-process-live"])
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        pause(24)
    }

    /// 点她弹菜单、收起；按住往下拉出工作台、收起；工作页再拉一次。
    @MainActor func testRecMenuAndStage() throws {
        let app = launch()
        let strip = element("agent-stage-pull-zone", in: app)
        XCTAssertTrue(strip.waitForExistence(timeout: 15))
        pause(1.5)
        strip.tap()
        pause(1.8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        pause(1.5)
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 3)))
        pause(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        pause(1.5)
        app.buttons["tab-工作"].tap()
        pause(1.2)
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 3)))
        pause(2)
        if app.buttons["agent-stage-close"].exists { app.buttons["agent-stage-close"].tap() }
        pause(1.5)
    }

    /// 工作页：开侧栏（Dock 右移消失）、右缘收起、再开、点会话原地变聊天、切会话、新对话。
    @MainActor func testRecWorkSidebar() throws {
        let app = launch()
        openWork(app)
        pause(1.2)
        app.buttons["work-sidebar"].tap()
        pause(1.6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        pause(1.4)
        app.buttons["work-sidebar"].tap()
        pause(1.4)
        app.buttons["work-host-mini"].tap()
        app.buttons["work-agent-all"].tap()
        pause(0.6)
        app.buttons["work-thread-session:session-1"].tap()
        pause(2.4)
        app.buttons["work-sidebar"].tap()
        pause(1.2)
        app.buttons["work-thread-session:session-2"].tap()
        pause(2.4)
        app.buttons["work-new"].tap()
        pause(2)
    }

    /// 今天页推进详情：顶栏往左淡出让位给系统导航栏；返回时回来。
    @MainActor func testRecTodayPush() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        app.buttons["tab-今天"].tap()
        // 今天页归 pages 轨道，入口标识以它为准：先找「下一件」那一行，没有就点时间线上的日程。
        let row = app.buttons["today-next-row"], event = app.buttons["today-event:ev-week"]
        XCTAssertTrue(row.waitForExistence(timeout: 5) || event.waitForExistence(timeout: 3))
        pause(1.2)
        (row.exists && row.isHittable ? row : event).tap()
        pause(1.8)
        XCTAssertFalse(element("agent-stage-pull-zone", in: app).isHittable, "详情页里顶栏让位")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1.8)
        XCTAssertTrue(element("agent-stage-pull-zone", in: app).isHittable, "回到根页顶栏回来")
    }

    /// 工作页：首页发出去 → 原地变聊天，回复流出来。
    @MainActor func testRecHomeSend() throws {
        let app = launch()
        openWork(app)
        pause(1)
        let input = app.textFields["work-input"]
        input.tap()
        input.typeText("帮我看看这周的选题")
        pause(0.8)
        app.buttons["work-send"].tap()
        pause(6)
    }
}
