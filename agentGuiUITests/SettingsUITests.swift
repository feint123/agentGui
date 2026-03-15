import XCTest

final class SettingsUITests: UITestBase {

    @MainActor
    func testLaunchToSettingsShowsAPIKeyForm() throws {
        launchApp()
        openSettingsWindow()

        let apiKeyField = app.descendants(matching: .any)
            .matching(identifier: "settings.connection.apiKeyField")
            .firstMatch

        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.connection.saveButton"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testSettingsShowsReadinessSummaryAndValidationAction() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadApiKey", "false",
            "-com.agentgui.test.preloadMessages", "false"
        ])
        openSettingsWindow()

        XCTAssertTrue(app.staticTexts["settings.connection.readinessSummary"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.connection.validateButton"].waitForExistence(timeout: 2))
    }
}