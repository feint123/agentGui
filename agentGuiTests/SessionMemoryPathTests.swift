import XCTest
@testable import agentGui

final class SessionMemoryPathTests: XCTestCase {

    func test_sessionMemoryDir_returnsExpectedPath() {
        let mgr = ConfigDirectoryManager.shared
        let dir = mgr.sessionMemoryDir(sessionId: "abc-123")
        XCTAssertTrue(dir.path.hasSuffix("/.agentgui/sessions/abc-123/session-memory"))
    }

    func test_sessionMemorySummaryURL_returnsExpectedPath() {
        let mgr = ConfigDirectoryManager.shared
        let url = mgr.sessionMemorySummaryURL(sessionId: "abc-123")
        XCTAssertTrue(url.path.hasSuffix("/.agentgui/sessions/abc-123/session-memory/summary.md"))
    }

    func test_sessionMemorySummaryURL_uniquePerSession() {
        let mgr = ConfigDirectoryManager.shared
        let url1 = mgr.sessionMemorySummaryURL(sessionId: "session-1")
        let url2 = mgr.sessionMemorySummaryURL(sessionId: "session-2")
        XCTAssertNotEqual(url1, url2)
    }
}
