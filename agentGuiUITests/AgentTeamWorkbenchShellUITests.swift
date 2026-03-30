import XCTest

final class AgentTeamWorkbenchShellUITests: XCTestCase {
    func testAgentTeamWorkbenchShellShowsDedicatedRegions() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.agentTeamFixture", "shell",
            "-com.agentgui.test.sessionId", "ui-agent-team"
        ]

        app.launch()

        XCTAssertTrue(app.otherElements["panel.agentTeam"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["agentTeam.missionHeader"].exists)
        XCTAssertTrue(app.otherElements["agentTeam.roster"].exists)
        XCTAssertTrue(app.otherElements["agentTeam.board"].exists)
        XCTAssertTrue(app.otherElements["agentTeam.inspector"].exists)
        XCTAssertFalse(app.otherElements["chat.inputArea"].exists)
    }
}