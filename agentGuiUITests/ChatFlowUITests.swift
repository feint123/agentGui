import XCTest

final class ChatFlowUITests: UITestBase {

    @MainActor
    func testPreloadedConversationAppearsInChat() throws {
        launchApp()

        XCTAssertTrue(app.staticTexts["Run the release checks"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Release checklist prepared."].waitForExistence(timeout: 2))
    }

    @MainActor
    func testTodoCardAppearsAboveComposerAndYieldsToSlashPopup() throws {
        launchApp(arguments: [
            "-com.agentgui.test.todoFixtureMode", "basic"
        ])

        XCTAssertTrue(app.staticTexts["任务列表"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(app.staticTexts["1/3"].waitForExistence(timeout: 2), app.debugDescription)

        launchApp(arguments: [
            "-com.agentgui.test.todoFixtureMode", "basic",
            "-com.agentgui.test.initialComposerText", "/"
        ])

        XCTAssertTrue(app.staticTexts["任务列表"].waitForNonExistence(timeout: 2), app.debugDescription)
    }
}