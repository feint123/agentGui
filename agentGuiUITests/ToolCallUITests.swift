import XCTest

final class ToolCallUITests: UITestBase {

    @MainActor
    func testPreloadedToolCallShowsExpandedDetail() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadToolCall", "true"
        ])

        XCTAssertTrue(app.activityIndicators["ReleaseChecklist.md, 进行中, /tmp/ReleaseChecklist.md"].waitForExistence(timeout: 2))
    }
}