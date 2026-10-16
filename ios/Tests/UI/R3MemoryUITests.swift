import XCTest

/// 第三轮 memory 轨道：记忆文件夹面上的英文 + 中文标题，待你过目的三个按钮（盖章收进文件夹 / 就地纠正 / 滑走可撤销），灵动岛常驻。
/// 录屏验收时这些用例会被单独跑（xcodebuild -only-testing），所以每步之间留了停顿，方便抽帧看完整的动效。
final class R3MemoryUITests: XCTestCase {
    @MainActor private func launch(_ extra: [String] = [], sheet: String? = "memory", appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-appearance", appearance] + extra
        if let sheet { app.launchEnvironment["COM_PREVIEW_SHEET"] = sheet }
        app.launch()
        return app
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor private func captureScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    /// 文件夹面上印英文、下面是中文标题 + 条数；没登记的分类也有得体的英文（NOTES）。
    @MainActor func testR3FolderWordsAndTitles() throws {
        let app = launch(["--ui-r3-folders"])
        let about = app.buttons["memory-folder-关于我"]
        XCTAssertTrue(about.waitForExistence(timeout: 15))
        XCTAssertEqual(about.label, "关于我，2 条", "读屏只念中文标题和条数，英文是装饰")
        pause(2)
        capture("r3-memory-grid-top", app: app)
        app.swipeUp()
        pause(1.5)
        XCTAssertTrue(app.buttons["memory-folder-旅行"].waitForExistence(timeout: 3), "没登记的分类也有文件夹")
        capture("r3-memory-grid-bottom", app: app)
    }

    @MainActor func testR3FolderWordsDark() throws {
        let app = launch(["--ui-r3-folders"], appearance: "dark")
        XCTAssertTrue(app.buttons["memory-folder-关于我"].waitForExistence(timeout: 15))
        pause(2)
        capture("r3-memory-grid-dark", app: app)
    }

    /// 自动记忆页：「记住」盖章后纸片收进文件夹，这一格收起。
    @MainActor func testR3ReviewConfirmFilesIntoFolder() throws {
        let app = launch(["--ui-r3-review"])
        let tip = app.buttons["memory-learned-all"]
        XCTAssertTrue(tip.waitForExistence(timeout: 15))
        tip.tap()
        XCTAssertTrue(app.navigationBars["自动记忆"].waitForExistence(timeout: 5))
        let paper = app.descendants(matching: .any)["memory-learned-r3-pending-night"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        pause(1.5)
        capture("r3-review-buttons", app: app)
        paper.buttons["记住"].tap()
        pause(0.5)
        capture("r3-review-stamped", app: app)
        XCTAssertTrue(paper.waitForNonExistence(timeout: 5), "收进文件夹后这一张不在待确认里了")
        pause(1.2)
        capture("r3-review-after-confirm", app: app)
    }

    /// 纠正：纸片就地展开成编辑框，保存后盖「改好了」收进去。
    @MainActor func testR3ReviewCorrectInPlace() throws {
        let app = launch(["--ui-r3-review"])
        let tip = app.buttons["memory-learned-all"]
        XCTAssertTrue(tip.waitForExistence(timeout: 15))
        tip.tap()
        let paper = app.descendants(matching: .any)["memory-learned-r3-learn-short"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        pause(1.2)
        paper.buttons["纠正"].tap()
        let field = app.textFields["memory-correct-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        pause(1.2)
        capture("r3-review-editing", app: app)
        field.typeText("，长消息再分段")
        pause(0.6)
        app.buttons["保存纠正"].tap()
        pause(0.5)
        capture("r3-review-corrected-stamp", app: app)
        XCTAssertTrue(paper.waitForNonExistence(timeout: 5))
        pause(1)
    }

    /// 删掉：纸片滑走，底部撤销条；撤销后原样回来；再删一次等 4 秒，真的提交。
    @MainActor func testR3ReviewDeleteAndUndo() throws {
        let app = launch(["--ui-r3-review"])
        let tip = app.buttons["memory-learned-all"]
        XCTAssertTrue(tip.waitForExistence(timeout: 15))
        tip.tap()
        let paper = app.descendants(matching: .any)["memory-learned-r3-learn-climb"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        pause(1.2)
        paper.buttons["删掉"].tap()
        let undo = app.buttons["memory-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertTrue(paper.waitForNonExistence(timeout: 3))
        pause(0.6)
        capture("r3-review-undo-toast", app: app)
        undo.tap()
        XCTAssertTrue(paper.waitForExistence(timeout: 3), "撤销后纸片原样回来")
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
        pause(1.5)
        capture("r3-review-undone", app: app)
        paper.buttons["删掉"].tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertTrue(undo.waitForNonExistence(timeout: 6), "4 秒后撤销条收起、真正删掉")
        XCTAssertFalse(paper.exists)
        pause(1)
    }

    /// 灵动岛：进后台 compact 出现 → 按住出 expanded（演示在这期间换到「在想」）→ 收起看走秒 → 锁屏，看等你点头 / 已送达 / 空闲三次更新。
    /// 演示脚本在 App 里（`--ui-r3-live`）：进后台约 1.8s 后开始，+3 在想、+7 两件在跑、+12 两件等你、+16 已送达、+19 空闲。
    @MainActor func testR3LiveActivityIsland() throws {
        let app = launch(["--ui-r3-live"], sheet: nil)
        XCTAssertTrue(app.buttons["tab-Com"].waitForExistence(timeout: 15))
        pause(2)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        pause(1.5)
        captureScreen("r3-live-compact")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).press(forDuration: 0.9)
        pause(0.6)
        captureScreen("r3-live-expanded")
        pause(1.6)
        captureScreen("r3-live-expanded-thinking")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).tap()
        pause(3.2)
        captureScreen("r3-live-compact-working")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        pause(1)
        XCUIDevice.shared.press(.home)
        pause(1)
        // 第一次在锁屏出现时系统会问「允许实时活动？」，真机上 Eddie 点一次「允许」就好。
        let allow = springboard.buttons["允许"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        pause(0.5)
        captureScreen("r3-live-lockscreen")
        pause(2)
        captureScreen("r3-live-lockscreen-waiting")
        pause(3.5)
        captureScreen("r3-live-lockscreen-delivered")
        pause(3)
        captureScreen("r3-live-lockscreen-idle")
        XCUIDevice.shared.press(.home)
        pause(1)
        XCUIDevice.shared.press(.home)
        pause(1)
    }

    /// 文件夹里的待确认纸片：同一套按钮，收进的就是这个文件夹。
    @MainActor func testR3FolderPendingPaper() throws {
        let app = launch(["--ui-r3-review"])
        let folder = app.buttons["memory-folder-生活"]
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        folder.tap()
        XCTAssertTrue(app.navigationBars["生活"].waitForExistence(timeout: 5))
        let paper = app.descendants(matching: .any)["memory-learned-r3-pending-money"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        pause(1.5)
        capture("r3-folder-pending", app: app)
        paper.buttons["记住"].tap()
        XCTAssertTrue(paper.waitForNonExistence(timeout: 5))
        pause(1.2)
    }
}
