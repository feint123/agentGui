import XCTest

final class WorkflowRecoveryUITests: UITestBase {

    @MainActor
    func testRecoveryBannerAppearsForInterruptedWorkflow() throws {
        launchApp(arguments: [
            "-com.agentgui.test.workflowState", "running"
        ])

        XCTAssertTrue(app.staticTexts["检测到可恢复的工作流"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["恢复查看"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["标记为中断"].waitForExistence(timeout: 2))
    }
}