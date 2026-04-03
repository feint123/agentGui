// agentGuiTests/SubagentNotificationTextTests.swift
import XCTest
@testable import agentGui

final class SubagentNotificationTextTests: XCTestCase {

    func test_completedStatus_containsCompletedTag() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "verifier",
            description: "Run tests",
            status: .completed,
            result: "VERDICT: PASS",
            error: nil,
            elapsedSeconds: 12.5
        )
        XCTAssertTrue(text.contains("<status>completed</status>"))
        XCTAssertTrue(text.contains("VERDICT: PASS"))
        XCTAssertTrue(text.contains("<agent>verifier</agent>"))
    }

    func test_failedStatus_containsErrorTag() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "worker",
            description: "Refactor code",
            status: .failed,
            result: nil,
            error: "API timeout after 60s",
            elapsedSeconds: 60.0
        )
        XCTAssertTrue(text.contains("<status>failed</status>"))
        XCTAssertTrue(text.contains("<error>API timeout after 60s</error>"))
        XCTAssertFalse(text.contains("<result>"))
    }

    func test_cancelledStatus_noResultTag() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "explore",
            description: "Explore codebase",
            status: .cancelled,
            result: nil,
            error: "Task cancelled",
            elapsedSeconds: 5.0
        )
        XCTAssertTrue(text.contains("<status>cancelled</status>"))
    }

    func test_resultTruncatedAt500Chars() {
        let longResult = String(repeating: "a", count: 600)
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "worker",
            description: "Long task",
            status: .completed,
            result: longResult,
            error: nil,
            elapsedSeconds: 30.0
        )
        // result 内的内容不超过 500 字符
        let resultRange = text.range(of: "<result>")
        let endRange = text.range(of: "</result>")
        XCTAssertNotNil(resultRange)
        XCTAssertNotNil(endRange)
        if let start = resultRange?.upperBound, let end = endRange?.lowerBound {
            let resultContent = String(text[start..<end])
            XCTAssertLessThanOrEqual(resultContent.count, 500)
        }
    }

    func test_emptyResult_noResultTag() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "explore",
            description: "Empty task",
            status: .completed,
            result: "",
            error: nil,
            elapsedSeconds: 1.0
        )
        XCTAssertFalse(text.contains("<result>"))
    }

    func test_elapsedFormat() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "verifier",
            description: "Run verifier",
            status: .completed,
            result: "done",
            error: nil,
            elapsedSeconds: 45.678
        )
        XCTAssertTrue(text.contains("<elapsed>45.7s</elapsed>"))
    }
}
