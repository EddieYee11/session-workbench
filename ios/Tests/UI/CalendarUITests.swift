import XCTest

/// 日历页：今天页周条点某天 → 打开日历页 → 画布左滑换天 → 日期轨上推再换天 → 点月圆章回今天。
final class CalendarUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func key(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    private func days(_ a: String, _ b: String) -> Int {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return Calendar.current.dateComponents([.day], from: f.date(from: a)!, to: f.date(from: b)!).day!
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func leftDay(_ app: XCUIApplication) -> String { app.descendants(matching: .any)["calendar-leftday"].firstMatch.label }

    func testOpenSwipeCanvasDragRailAndReturnToday() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-今天"].waitForExistence(timeout: 15))
        app.buttons["tab-今天"].tap()

        // 周条里点「今天」那一格（无障碍标签以「今天 」开头）。
        let todayCell = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'today-week' AND label BEGINSWITH '今天'")).firstMatch
        XCTAssertTrue(todayCell.waitForExistence(timeout: 10), "周条里应有今天")
        todayCell.tap()

        let view = app.descendants(matching: .any)["calendar-view"].firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 8), "点周条应打开日历页")
        let canvas = app.descendants(matching: .any)["calendar-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let today = key(Date())
        XCTAssertEqual(leftDay(app), today)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-col-" + today].firstMatch.exists, "今天列标题")
        XCTAssertTrue(app.descendants(matching: .any)["calendar-rail"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-pill"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-upnext"].firstMatch.waitForExistence(timeout: 3), "有下一件")
        shot(app, "calendar-rest")

        // 画布往左拖 ≈ 2 列：左列往后翻 1~3 天。
        let frame = canvas.frame
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + frame.width * 0.85, dy: frame.minY + frame.height * 0.45))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -frame.width * 0.55, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleepFor(1.0)
        let afterCanvas = leftDay(app)
        let step1 = days(today, afterCanvas)
        XCTAssertTrue((1...4).contains(step1), "左滑后左列应往后翻 1~4 天，实际 \(step1)：\(afterCanvas)")
        shot(app, "calendar-after-canvas-swipe")

        // 日期轨往上推：继续往后翻。
        let rail = app.descendants(matching: .any)["calendar-rail"].firstMatch
        let r = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        r.press(forDuration: 0.05, thenDragTo: r.withOffset(CGVector(dx: 0, dy: -110)), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleepFor(1.0)
        let afterRail = leftDay(app)
        XCTAssertGreaterThan(days(afterCanvas, afterRail), 0, "轨上推应继续往后翻：\(afterCanvas) -> \(afterRail)")

        // 点月圆章回今天。
        app.buttons["calendar-month"].tap()
        sleepFor(1.0)
        XCTAssertEqual(leftDay(app), today, "点月圆章应回到今天")
        shot(app, "calendar-back-today")
    }

    /// 验收截图：静止 / 融球（--ui-calendar-fuse：tension 固定 1、dayOffset=0.5）/ 深色静止，直接存盘。
    func testScreenshots() {
        for (name, extra, mode) in [("calendar-rest-light", [], "light"), ("calendar-fuse-light", ["--ui-calendar-fuse"], "light"), ("calendar-rest-dark", [], "dark"), ("calendar-fuse-dark", ["--ui-calendar-fuse"], "dark")] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-appearance", mode] + extra
            app.launch()
            XCTAssertTrue(app.buttons["tab-今天"].waitForExistence(timeout: 15))
            app.buttons["tab-今天"].tap()
            let cell = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'today-week' AND label BEGINSWITH '今天'")).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 10))
            cell.tap()
            XCTAssertTrue(app.descendants(matching: .any)["calendar-canvas"].firstMatch.waitForExistence(timeout: 8))
            Thread.sleep(forTimeInterval: 1.5)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/claude-501/-Users-eddiegao-AI-Work-System/8d8d247e-9d2c-43a3-be57-217454f6d5c5/scratchpad/calvid/shots/\(name).png"))
            app.terminate()
        }
    }

    private func sleepFor(_ s: Double) { Thread.sleep(forTimeInterval: s) }
}
