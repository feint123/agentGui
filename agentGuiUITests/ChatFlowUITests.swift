import XCTest

final class ChatFlowUITests: UITestBase {

    @MainActor
    func testPreloadedConversationAppearsInChat() throws {
        launchApp()

        XCTAssertTrue(app.staticTexts["Run the release checks"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Release checklist prepared."].waitForExistence(timeout: 2))
    }
}