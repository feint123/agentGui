import XCTest

final class ChatFlowUITests: UITestBase {

    private func identifiedElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testPreloadedConversationAppearsInChat() throws {
        launchApp()

        XCTAssertTrue(app.staticTexts["Run the release checks"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Release checklist prepared."].waitForExistence(timeout: 2))
    }

    @MainActor
    func testTodoCardAppearsAboveComposerAndYieldsToSlashPopup() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadMessages", "false",
            "-com.agentgui.test.todoFixtureMode", "basic"
        ])

        XCTAssertTrue(app.buttons["任务列表"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(app.staticTexts["1/3"].waitForExistence(timeout: 2), app.debugDescription)

        launchApp(arguments: [
            "-com.agentgui.test.preloadMessages", "false",
            "-com.agentgui.test.todoFixtureMode", "basic",
            "-com.agentgui.test.initialComposerText", "/"
        ])

        XCTAssertTrue(app.buttons["任务列表"].waitForNonExistence(timeout: 2), app.debugDescription)
    }

    @MainActor
    func testAgentMessageShowsLiveExecutionTheater() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadMessages", "false",
            "-com.agentgui.test.chatProjectionFixture", "liveAgentExecution"
        ])

        XCTAssertTrue(identifiedElement("chat.agentMessage.executionTheater").waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(identifiedElement("chat.agentMessage.phaseRibbon").exists, app.debugDescription)
        XCTAssertTrue(identifiedElement("chat.agentMessage.currentAction").exists, app.debugDescription)
        XCTAssertTrue(identifiedElement("chat.agentMessage.liveTaskCard.ui-live-exec").exists, app.debugDescription)
        XCTAssertFalse(identifiedElement("chat.agentMessage.artifactShelf").exists, app.debugDescription)
    }

    @MainActor
    func testAgentMessageSettlesIntoTranscriptArtifactsAndDigest() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadMessages", "false",
            "-com.agentgui.test.chatProjectionFixture", "settledAgentDelivery"
        ])

        XCTAssertTrue(identifiedElement("chat.agentMessage.answerBlock").waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(identifiedElement("chat.agentMessage.artifactShelf").exists, app.debugDescription)
        XCTAssertTrue(identifiedElement("chat.agentMessage.executionDigest").exists, app.debugDescription)
        XCTAssertTrue(identifiedElement("chat.agentMessage.auditDisclosure").exists, app.debugDescription)
        XCTAssertFalse(identifiedElement("chat.agentMessage.auditTrace").exists, app.debugDescription)
    }
}