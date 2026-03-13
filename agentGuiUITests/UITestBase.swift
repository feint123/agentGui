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

    @MainActor
    func openSettingsWindow() {
        app.activate()

        app.typeKey(",", modifierFlags: .command)

        let connectionField = app.descendants(matching: .any)
            .matching(identifier: "settings.connection.apiKeyField")
            .firstMatch

        if connectionField.waitForExistence(timeout: 2) {
            return
        }

        let appMenu = app.menuBars.menuBarItems["agentGui"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 2))
        appMenu.click()

        let settingsMenuItem = app.menuBars.menuItems["设置..."]
        XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 2))
        settingsMenuItem.click()
    }
}