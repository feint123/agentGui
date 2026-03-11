import XCTest

class UITestBase: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func launchApp(arguments: [String] = []) {
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments = [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.preloadApiKey", "true",
            "-com.agentgui.test.preloadMessages", "true",
            "-com.agentgui.test.sessionId", "ui-test-session"
        ] + arguments
        app.launch()
    }
}