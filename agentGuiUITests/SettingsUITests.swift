import XCTest

final class SettingsUITests: UITestBase {

    @MainActor
    func testLaunchToSettingsShowsAPIKeyForm() throws {
        launchApp(arguments: [
            "-com.agentgui.test.initialTab", "settings"
        ])

        let apiKeyField = app.descendants(matching: .any)
            .matching(identifier: "settings.apiKeyField")
            .firstMatch

        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.saveButton"].waitForExistence(timeout: 2))
    }
}