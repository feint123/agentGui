import XCTest

final class SettingsWindowUITests: UITestBase {

    @MainActor
    func testOpenSettingsWindowShowsConnectionPage() throws {
        launchApp()
        openSettingsWindow()

        let apiKeyField = app.descendants(matching: .any)
            .matching(identifier: "settings.connection.apiKeyField")
            .firstMatch

        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.connection.saveButton"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testSettingsShowsExecutorsNavigationItem() throws {
        launchApp()
        openSettingsWindow()

        let executorsItem = app.descendants(matching: .any)
            .matching(identifier: "settings.nav.executors")
            .firstMatch

        XCTAssertTrue(executorsItem.waitForExistence(timeout: 2))
    }
}