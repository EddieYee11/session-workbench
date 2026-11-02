import XCTest

/// 连真实机器的内嵌终端验收，平时跳过。
/// 跑法：TEST_RUNNER_COM_LIVE_HERDR=mini TEST_RUNNER_COM_LIVE_HERDR_OUT=<目录> xcodebuild test -only-testing:ComUITests/HerdrLiveUITests
/// 前提：模拟器 defaults 里有 herdr.machines.cache，且模拟器的公钥已授权。
final class HerdrLiveUITests: XCTestCase {
    @MainActor func testLiveTerminal() throws {
        let env = ProcessInfo.processInfo.environment
        guard let machine = env["COM_LIVE_HERDR"], let out = env["COM_LIVE_HERDR_OUT"] else {
            throw XCTSkip("需要 COM_LIVE_HERDR 和 COM_LIVE_HERDR_OUT")
        }
        func shot(_ name: String, _ app: XCUIApplication) throws {
            let image = app.screenshot()
            add(XCTAttachment(screenshot: image))
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(machine)-\(name).png"))
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-工作"].waitForExistence(timeout: 15))
        app.buttons["tab-工作"].tap()
        XCTAssertTrue(app.buttons["work-surface-terminal"].waitForExistence(timeout: 5))
        app.buttons["work-surface-terminal"].tap()
        let machineButton = app.buttons["herdr-machine-\(machine)"]
        XCTAssertTrue(machineButton.waitForExistence(timeout: 10))
        machineButton.tap()
        let open = app.buttons["herdr-open-whole"]
        let ready = open.waitForExistence(timeout: 25)
        try shot("1-surface", app)
        XCTAssertTrue(ready, "没连上，看 1-surface 截图")
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["herdr-terminal-view"].waitForExistence(timeout: 10))
        sleep(8)
        try shot("2-whole", app)
        app.descendants(matching: .any)["herdr-terminal-view"].tap()
        sleep(3)
        try shot("3-keyboard", app)
        // 按键会进这台机器当前聚焦的 pane，所以只有明确要求才打字。
        guard env["COM_LIVE_HERDR_TYPE"] == "1" else { return }
        app.typeText("\u{1b}")
        sleep(2)
        app.typeText("echo com-pty-$((6*7))\r")
        sleep(3)
        try shot("4-input", app)
    }
}
