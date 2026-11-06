import XCTest

/// 看板验收截图，平时跳过。
/// 跑法：TEST_RUNNER_COM_BOARD_SHOTS_OUT=<目录> [TEST_RUNNER_COM_BOARD_SHOTS_TAG=dark] xcodebuild test -only-testing:ComUITests/BoardShotsUITests
final class BoardShotsUITests: XCTestCase {
    @MainActor func testBoardShots() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["COM_BOARD_SHOTS_OUT"] else { throw XCTSkip("需要 COM_BOARD_SHOTS_OUT") }
        let tag = env["COM_BOARD_SHOTS_TAG"].map { "-" + $0 } ?? ""
        // Duo 双屏下 app.screenshot() 是黑的：这里只落标记，由宿主机 simctl io screenshot --display=3 截内屏。
        func shot(_ name: String, _ app: XCUIApplication) {
            sleep(2)
            try? Data().write(to: URL(fileURLWithPath: out).appendingPathComponent(name + tag + ".ready"))
            sleep(4)
        }
        let device = XCUIDevice.shared
        device.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-tab=下一步"]
        app.launch()
        let toggle = app.buttons["board-focus-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        shot("D-inner-landscape-split", app)
        toggle.tap()
        shot("D-inner-landscape-board-focus", app)
        device.orientation = .portrait
        shot("C-inner-portrait-board-focus", app)
        if toggle.waitForExistence(timeout: 3) { toggle.tap() }
        shot("C-inner-portrait", app)
        // 11-04 三组看板：窄宽单列下切到「待办」看正在做置顶 + 红标签 + 焦点开关。
        device.orientation = .landscapeLeft
        let todoCapsule = app.buttons["board-capsule-todo"]
        if todoCapsule.waitForExistence(timeout: 5) {
            todoCapsule.tap()
            shot("D-inner-landscape-split-todo", app)
        }
        device.orientation = .landscapeLeft
    }
}
