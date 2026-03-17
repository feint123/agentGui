import XCTest

final class SessionManagementUITests: UITestBase {

    @MainActor
    func testCreateSessionShowsEmptyChatState() throws {
        launchApp()

        XCTAssertTrue(app.popUpButtons["chat.sessionPicker"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["chat.newSessionButton"].waitForExistence(timeout: 2))

        app.buttons["chat.newSessionButton"].click()

        XCTAssertTrue(app.staticTexts["开始对话"].waitForExistence(timeout: 2))
    }
}