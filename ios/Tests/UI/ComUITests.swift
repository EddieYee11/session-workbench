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
    /// 点顶栏角色打开菜单，再点一项。
    @MainActor private func openMenu(_ item: String, app: XCUIApplication) {
        let strip = app.descendants(matching: .any)["agent-stage-pull-zone"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 15))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        // 刚收起一张 sheet 时系统可能还没准备好弹 popover；再点一次即可。
        for _ in 0..<3 {
            strip.tap()
            if row.waitForExistence(timeout: 3) { row.tap(); return }
        }
        XCTFail("菜单没有弹出：" + item)
    }

    @MainActor func testAgentStageCanExpandWithoutObscuringComposer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-stage=working", "-appearance", "light"]
        app.launch()
        let pullZone = app.descendants(matching: .any)["agent-stage-pull-zone"].firstMatch
        XCTAssertTrue(pullZone.waitForExistence(timeout: 15))
        let panel = app.descendants(matching: .any)["agent-stage-panel"].firstMatch
        XCTAssertFalse(panel.exists)
        let start = pullZone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = pullZone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2.4))
        start.press(forDuration: 0.08, thenDragTo: end)
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        capture("agent-stage-expanded", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["message-input"].firstMatch.isHittable)
        start.press(forDuration: 0.08, thenDragTo: end)
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        app.buttons["agent-stage-close"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        app.buttons["tab-今天"].tap()
        XCTAssertFalse(panel.exists)
        capture("today-with-strip", app: app)
    }

    @MainActor func testFinanceDrilldownAndProjectEvidence() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        // 聊天页底部不再挂卡片；账本在「全部建议」页最下面（从今天页进）。
        XCTAssertFalse(app.buttons["ledger-note"].exists)
        openAllNext(app)
        let ledger = app.buttons["ledger-note"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 5))
        for _ in 0..<4 where !ledger.isHittable { app.swipeUp() }
        ledger.tap()
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
        // 工作页的历史在侧栏：MacBook 上 Codex 的这段只有进展快照，点开是只读依据。
        app.buttons["work-sidebar"].tap()
        XCTAssertTrue(app.buttons["work-host-macbook"].waitForExistence(timeout: 5))
        app.buttons["work-host-macbook"].tap()
        app.buttons["work-agent-all"].tap()
        let thread = app.buttons["work-thread-preview-board-item"]
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        capture("work-partition-macbook", app: app)
        thread.tap()
        // r3-work：只读快照在工作页原地打开（不再弹「进展依据」页），依据卡在聊天流顶上。
        XCTAssertTrue(app.staticTexts["会话中的依据"].waitForExistence(timeout: 5))
        // 项目看板收在侧栏分区栏右边。
        app.buttons["work-sidebar"].tap()
        XCTAssertTrue(app.buttons["work-board"].waitForExistence(timeout: 5))
        app.buttons["work-board"].tap()
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

    @MainActor func testNextStepsDismissDiscussGoalAndSettings() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        openAllNext(app)
        XCTAssertTrue(app.staticTexts["回复王总的排期邮件"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["会前过一遍周会议题"].exists)
        // 依据袋（轨道 r2-pages）：点开纸片飞出来，卡片里不再有列表式依据。
        app.buttons["next-evidence-next-reply"].tap()
        let slip = app.buttons["next-evidence-slip-next-reply-0"]
        XCTAssertTrue(slip.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["next-evidence-slip-next-reply-1"].exists)
        XCTAssertFalse(app.buttons["next-evidence-row-next-reply-0"].exists, "列表式依据已经删掉")
        sleep(1)
        capture("next-steps", app: app)
        // 点一张纸：推近成原始来源（原文标题、来源、摘要），再往下能跳到事项详情。
        slip.tap()
        XCTAssertTrue(app.navigationBars["依据"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Re: Q4 排期确认"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["王总 <wang@example.com>"].exists)
        sleep(1)
        capture("next-evidence-detail", app: app)
        app.buttons["evidence-jump-matter"].tap()
        XCTAssertTrue(app.navigationBars["事项"].waitForExistence(timeout: 5))
        capture("next-evidence-matter", app: app)
        app.navigationBars["事项"].buttons["完成"].tap()
        // 收起事项后回到那份依据，再关掉依据回到卡片。
        XCTAssertTrue(app.navigationBars["依据"].waitForExistence(timeout: 5))
        app.navigationBars["依据"].buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["依据"].waitForNonExistence(timeout: 5))
        app.buttons["next-dismiss-next-meeting"].tap()
        XCTAssertTrue(app.staticTexts["会前过一遍周会议题"].waitForNonExistence(timeout: 5))
        // 交给 Com：作为一条消息回到对话页。
        app.buttons["next-discuss-next-reply"].tap()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 5))
        let sent = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-bubble-next-")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        openMenu("设置", app: app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["主动性与晨晚报"].tap()
        XCTAssertTrue(app.navigationBars["主动性"].waitForExistence(timeout: 5))
        app.switches["暂停主动消息"].tap()
        XCTAssertTrue(app.staticTexts["先安静一会儿。"].exists)
        capture("agency-settings", app: app)
        app.swipeUp()
        app.buttons["保存安排"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        app.buttons["tab-今天"].tap()
        // 刚才从今天页推进了「全部建议」：先退回今天页根部，再滚到最下面的「任务与目标」。
        if app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 2) { app.navigationBars.buttons.firstMatch.tap() }
        let hub = app.buttons["today-task-hub"]
        XCTAssertTrue(hub.waitForExistence(timeout: 5))
        for _ in 0..<8 where !hub.isHittable { app.swipeUp(velocity: 800) }
        hub.tap()
        XCTAssertTrue(app.buttons["管理"].waitForExistence(timeout: 5))
        app.buttons["管理"].tap()
        XCTAssertTrue(app.buttons["添加目标"].waitForExistence(timeout: 5))
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

    @MainActor private func openAllNext(_ app: XCUIApplication) { app.buttons["tab-下一步"].tap() }

    @MainActor func testRichReplyAndConnectionActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-rich-reply", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts["今日重点"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["下一步"].exists)
        capture("rich-reply", app: app)
        // Gmail 断了：「下一步」页顶部一张卡，顶栏她举牌。
        app.buttons["tab-下一步"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["source-broken-gmail"].firstMatch.waitForExistence(timeout: 5))
        openMenu("连接器", app: app)
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
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        capture("01-flow", app: app)
        for (title, name) in [("下一步", "02-next"), ("今天", "02-today"), ("工作", "03-work")] {
            let tab = app.buttons["tab-" + title]
            XCTAssertTrue(tab.exists)
            tab.tap()
            XCTAssertTrue(tab.isSelected)
            capture(name, app: app)
        }
        openMenu("设置", app: app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["tab-Com"].tap()
        let input = app.descendants(matching: .any)["message-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Hello Com")
        XCTAssertTrue(app.buttons["发送消息"].isHittable)
        capture("04-keyboard", app: app)
    }
    @MainActor func testFiltersAndDetails() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        app.buttons["tab-今天"].tap()
        let hub = app.buttons["today-task-hub"]
        XCTAssertTrue(hub.waitForExistence(timeout: 5))
        for _ in 0..<4 where !hub.isHittable { app.swipeUp() }
        hub.tap()
        XCTAssertTrue(app.staticTexts["查看拍摄素材"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["整理本周内容计划"].exists)
        app.buttons["看详情"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["任务"].waitForExistence(timeout: 5))
        capture("05-task-detail", app: app)
        app.buttons["完成"].tap()
        // 任务与目标是今天页推进来的二级页，顶栏角色在一级页上。
        app.navigationBars["任务与目标"].buttons.element(boundBy: 0).tap()
        openMenu("记忆", app: app)
        // 轨道 r2-memory：搜索收在底部玻璃圆钮里，点开才出现输入框。
        let searchButton = app.buttons["memory-search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5))
        let search = app.textFields["搜索记忆"]
        for _ in 0..<3 where !search.exists { searchButton.tap(); _ = search.waitForExistence(timeout: 3) }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("不存在的记忆")
        XCTAssertTrue(app.staticTexts["这里还留着空白"].waitForExistence(timeout: 3))
        app.buttons["清除搜索"].tap()
        // 集成（r2-integrate）：r2-memory 首页改为文件夹网格，不再平铺记忆正文；清除搜索后回到文件夹网格。
        XCTAssertTrue(app.buttons["memory-folder-工作"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["这里还留着空白"].exists)
    }
    @MainActor func testMemoryFoldersAndWorkChat() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        openMenu("记忆", app: app)
        let folder = app.buttons["memory-folder-工作"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        capture("memory-folders", app: app)
        folder.tap()
        XCTAssertTrue(app.navigationBars["工作"].waitForExistence(timeout: 5))
        let row = app.buttons["memory-memory-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture("memory-folder-detail", app: app)
        row.tap()
        XCTAssertTrue(app.buttons["纠正这条记忆"].waitForExistence(timeout: 5))
        capture("memory-item", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["工作"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        // 工作页：打开是空白新对话；侧栏里 Mac mini → Claude，只剩 Claude 的对话；点开是聊天。
        app.buttons["tab-工作"].tap()
        XCTAssertTrue(app.buttons["work-sidebar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["work-host-mini"].exists, "历史默认收在侧栏里")
        app.buttons["work-sidebar"].tap()
        XCTAssertTrue(app.buttons["work-host-mini"].waitForExistence(timeout: 5))
        app.buttons["work-host-mini"].tap()
        app.buttons["work-agent-claude"].tap()
        let session = app.buttons["work-thread-session:session-3"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["work-thread-session:session-1"].exists, "Codex 的对话不在 Claude 分区")
        XCTAssertTrue(app.textFields["work-input"].exists)
        capture("work-claude", app: app)
        session.tap()
        XCTAssertTrue(app.descendants(matching: .any)["work-chat"].firstMatch.waitForExistence(timeout: 5))  // r3-work：原地聊天，不再推「Claude Code」二级页
        capture("work-chat", app: app)
    }
    /// 轨道 r2-memory：记忆页文件夹网格（筛选、Grid/List、自动学到提示、文件夹里批准待确认）+ 工作页真实 Agent 图标。
    @MainActor func testMemoryFolderGridFiltersAndAgentLogos() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        openMenu("记忆", app: app)
        XCTAssertTrue(app.buttons["memory-folder-关于我"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["memory-learned-all"].exists, "最近自动学到收成一条提示")
        XCTAssertFalse(app.buttons["memory-folder-创作"].exists, "空文件夹不占格子")
        sleep(1)
        capture("memory-grid", app: app)
        app.buttons["待确认"].tap()
        XCTAssertTrue(app.buttons["memory-folder-生活"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["memory-folder-工作"].waitForNonExistence(timeout: 3), "待确认筛选只留有待确认的文件夹")
        capture("memory-grid-pending", app: app)
        app.buttons["自动学到"].tap()
        XCTAssertTrue(app.buttons["memory-folder-关于我"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["memory-folder-工作"].exists)
        app.buttons["全部"].tap()
        app.buttons["memory-layout-list"].tap()
        XCTAssertTrue(app.buttons["memory-folder-工作"].waitForExistence(timeout: 3))
        sleep(1)
        capture("memory-list", app: app)
        app.buttons["memory-layout-grid"].tap()
        // 文件夹里：待确认的纸片可以直接「记住」。
        app.buttons["memory-folder-生活"].tap()
        XCTAssertTrue(app.navigationBars["生活"].waitForExistence(timeout: 5))
        let pending = app.descendants(matching: .any)["memory-learned-pending-health"].firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        sleep(1)
        capture("memory-folder-papers", app: app)
        app.buttons["记住"].firstMatch.tap()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["memory-memory-2"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["memory-learned-all"].waitForExistence(timeout: 5))
        app.buttons["memory-learned-all"].tap()
        XCTAssertTrue(app.navigationBars["自动记忆"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["没错"].firstMatch.exists, "确认 / 纠正 / 删除保留在二级页")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["完成"].firstMatch.tap()
        // 工作页：输入框左侧与空白页居中都是真实 Agent 图标。
        app.buttons["tab-工作"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["work-new-chat"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["work-title-menu"].exists)  // r3-work：派给谁挪到顶栏标题
        sleep(1)
        capture("work-agent-logo", app: app)
        app.buttons["work-sidebar"].tap()
        XCTAssertTrue(app.buttons["work-host-mini"].waitForExistence(timeout: 5))
        app.buttons["work-host-mini"].tap()
        XCTAssertTrue(app.buttons["work-agent-claude"].waitForExistence(timeout: 5))
        app.buttons["work-agent-claude"].tap()
        sleep(1)
        capture("work-sidebar-logos", app: app)
    }

    @MainActor func testSharedKnowledgeDetailAndSource() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        openMenu("记忆", app: app)
        // 轨道 r2-memory：搜索收在底部玻璃圆钮里，点开才出现输入框。
        let searchButton = app.buttons["memory-search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5))
        let search = app.textFields["搜索记忆"]
        for _ in 0..<3 where !search.exists { searchButton.tap(); _ = search.waitForExistence(timeout: 3) }
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
    @MainActor func testTodayTimelineAndWorkSidebar() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        app.buttons["tab-今天"].tap()
        // 大日期下面一行灰字（轨道 r2-pages）：4 个日程；待办 = 2 条提醒 + 2 条行动台待办 + 1 件等你回应的任务。
        XCTAssertTrue(app.staticTexts["4 个日程 · 5 个待办"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["today-now-banner"].firstMatch.exists, "下一件 + 身体横幅")
        XCTAssertFalse(app.descendants(matching: .any)["today-tip"].firstMatch.exists, "深色提示条已并进简报")
        app.buttons["today-deck-timeline"].tap()
        sleep(2)
        capture("today-top", app: app)
        // 横向时间轴：有「现在」线，卡片点进详情。
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["today-now"].firstMatch.waitForExistence(timeout: 3))
        sleep(1)
        capture("today-timeline", app: app)
        let week = app.buttons["today-event:ev-week"]
        let timeline = app.descendants(matching: .any)["today-timeline"].firstMatch
        // 上面多了简报、表盘和身体卡，时间线更靠下：滚到它整块进屏幕。
        for _ in 0..<12 where !(timeline.exists && timeline.frame.minY > 140 && timeline.frame.maxY < app.frame.maxY - 120) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            sleep(1)
        }
        if !week.isHittable { timeline.swipeRight() }
        week.tap()
        XCTAssertTrue(app.navigationBars["日程"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3F 会议室"].exists)
        capture("today-event-detail", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // 待办那一段里的过期提醒：切回待办，点进去完成，回来灰字跟着少一件。
        app.buttons["today-deck-todo"].tap()
        let reminder = app.buttons["today-reminder:rm-late"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 5))
        if !reminder.isHittable { app.swipeDown() }
        reminder.tap()
        app.buttons["reminder-confirm"].tap()
        if !app.staticTexts["4 个日程 · 4 个待办"].exists { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["4 个日程 · 4 个待办"].waitForExistence(timeout: 5))
        // 10-17 黄色拍板卡拿掉了：等你回应的任务从标题旁的小按钮进「任务与目标」。
        app.buttons["today-task-hub"].tap()
        XCTAssertTrue(app.buttons["管理"].waitForExistence(timeout: 5))
        capture("today-task-hub", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // 工作页：空白新对话，侧栏按钮拉出历史。
        app.buttons["tab-工作"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["work-new-chat"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["work-sidebar-panel"].firstMatch.exists)
        capture("work-new-chat", app: app)
        app.buttons["work-sidebar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["work-sidebar-panel"].firstMatch.waitForExistence(timeout: 5))
        capture("work-sidebar", app: app)
        app.buttons["work-sidebar-close"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["work-sidebar-panel"].firstMatch.waitForNonExistence(timeout: 5))
    }
    @MainActor func testDoingListsEveryDecisionAndArchivesTasks() throws {
        let app = app()
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        app.buttons["tab-今天"].tap()
        let hub = app.buttons["today-task-hub"]
        XCTAssertTrue(hub.waitForExistence(timeout: 5))
        for _ in 0..<4 where !hub.isHittable { app.swipeUp() }
        hub.tap()
        // 任务与目标只收真正等你拍板的任务；日历、邮件的事项不再混进来。
        XCTAssertTrue(app.staticTexts["等我决定 · 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["查看拍摄素材"].exists)
        XCTAssertFalse(app.staticTexts["给今天留一段专注时间"].exists)
        capture("doing-decisions", app: app)
        // 任务左划归档：从「等我决定」消失，进「已结束」。
        let task = app.descendants(matching: .any)["pending-task:task-2"].firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.swipeLeft(velocity: .fast)
        XCTAssertTrue(app.staticTexts["等我决定 · 0"].waitForExistence(timeout: 5))
        // 超过一周的旧任务折成一行，一键归档。
        XCTAssertTrue(app.staticTexts["1 件超过一周的旧任务"].exists)
        app.buttons["archive-stale"].tap()
        XCTAssertTrue(app.staticTexts["1 件超过一周的旧任务"].waitForNonExistence(timeout: 5))
        app.buttons["已结束"].tap()
        XCTAssertTrue(app.staticTexts["查看拍摄素材"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["核对上个月的报销单"].exists)
    }

    @MainActor func testInlineVoiceAutomaticallySendsOneTextMessage() throws {
        let app = app()
        XCTAssertTrue(app.buttons["开始语音"].waitForExistence(timeout: 15))
        app.buttons["开始语音"].tap()
        XCTAssertTrue(app.staticTexts["正在录音"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voice-auto-send"].exists)
        // The reveal before auto-send is short now, so check the transcript surface while recording.
        XCTAssertTrue(app.staticTexts["voice-rhythmic-text"].waitForExistence(timeout: 5))
        sleep(1)
        capture("voice-recording-edge-glow", app: app)
        app.buttons["完成录音"].tap()
        let text = "帮我整理今天的安排，再留一点时间去攀岩。"
        XCTAssertFalse(app.buttons["确认发送"].exists)
        XCTAssertTrue(app.buttons["开始语音"].waitForExistence(timeout: 8))
        let bubbles = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat-bubble-", text))
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in bubbles.count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 8), .completed)
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
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 8))
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
        app.launchArguments = ["--ui-testing", "--ui-stress-chat", "--ui-incoming-control", "--ui-stage=working", "-appearance", "light"]
        app.launch()
        let last = app.staticTexts["chat-bubble-stress-300"]
        XCTAssertTrue(last.waitForExistence(timeout: 15))
        for _ in 0..<4 { app.scrollViews["chat-timeline-scroll"].swipeDown(velocity: .fast) }
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
        app.scrollViews["chat-timeline-scroll"].swipeDown(); app.scrollViews["chat-timeline-scroll"].swipeDown()
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
        app.launchArguments = ["--ui-testing", "--ui-stress-chat", "--ui-incoming-control", "--ui-stage=working", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat-bubble-stress-300"].waitForExistence(timeout: 15))
        app.scrollViews["chat-timeline-scroll"].swipeDown(velocity: .slow); app.scrollViews["chat-timeline-scroll"].swipeDown(velocity: .slow)
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


    /// chat 轨道：说完话后助手一侧一行实时步骤 + 顶栏手绘气泡；做完折成「做了 N 步 · 用时 X 秒」，点开看合并后的步骤。
    @MainActor func testWorkProcessLiveLineBubbleAndSummary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-work-process", "--ui-work-process-live", "-appearance", "light"]
        app.launch()
        let live = app.buttons["work-process-live"]
        XCTAssertTrue(live.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["agent-work-bubble"].firstMatch.waitForExistence(timeout: 5))
        live.tap()
        XCTAssertTrue(app.descendants(matching: .any)["work-process-steps"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["翻了 6 处资料"].exists)
        capture("work-process-live-open", app: app)
        // 脚本走完：气泡收起，两条都折成一行。
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "挤的原因")).firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["agent-work-bubble"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["work-process-live"].exists)
        let summary = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "做了 10 步")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        // 做完自动折叠：之前点开的步骤详情收起。
        XCTAssertTrue(app.descendants(matching: .any)["work-process-steps"].firstMatch.waitForNonExistence(timeout: 3))
        capture("work-process-done", app: app)
        let earlier = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "做了 5 步 · 用时 14 秒")).firstMatch
        XCTAssertTrue(earlier.exists)
        earlier.tap()
        XCTAssertTrue(app.staticTexts["查了 3 次账本"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["记了一笔账"].exists)
        capture("work-process-summary-open", app: app)
    }

    /// r2-chat：纯文本回复兜底排版（结论句放大、短段、列表、数字加粗）+ 最新回复下的建议卡，点一下就发出去并收起。
    @MainActor func testReplyLayoutAndSuggestionChips() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-reply-layout", "-appearance", "light"]
        app.launch()
        let chips = app.descendants(matching: .any)["suggestion-chips"].firstMatch
        XCTAssertTrue(chips.waitForExistence(timeout: 15))
        // 原始标记绝不出现在正文里。
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "[[")).firstMatch.exists)
        XCTAssertTrue(app.buttons["suggestion-0"].label.contains("帮我盯着日志"))
        XCTAssertTrue(app.buttons["suggestion-2"].exists)
        // 结论句单独成一行（放大 + 荧光笔）。
        XCTAssertTrue(app.staticTexts["查完了，mini 上的 Com 服务是正常的，刚才连不上是因为 Magpie 网关重启了一次，大概断了40秒。"].exists)
        capture("r2-chat-after-latest", app: app)
        app.buttons["suggestion-0"].tap()
        XCTAssertTrue(chips.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["帮我盯着日志"].waitForExistence(timeout: 5))
        capture("r2-chat-after-chip-sent", app: app)
    }

    /// r2-chat：新回复进场（结论句模糊上浮 + 荧光笔扫入），建议卡只挂在最新一条上。
    @MainActor func testIncomingReplyMovesSuggestionsToLatest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-reply-layout", "--ui-reply-live", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["suggestion-0"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "一起提醒")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "帮我盯着日志")).firstMatch.exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "suggestion-chips").count, 1)
        capture("r2-chat-incoming", app: app)
    }
}
