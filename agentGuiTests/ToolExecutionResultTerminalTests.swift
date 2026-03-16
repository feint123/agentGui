import Foundation
import Testing
@testable import agentGui

struct ToolExecutionResultTerminalTests {

    @Test func terminalOutcomeMapsNonZeroExitToFailure() async throws {
        let outcome = TerminalExecutionOutcome(
            taskId: "task-1",
            exitCode: 2,
            terminationSignal: nil,
            completionReason: .exitedNonZero,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            transcriptPath: "/tmp/task-1.log",
            finalOutputSnippet: "boom"
        )

        let result = ToolExecutionResult.fromTerminalOutcome(outcome)

        #expect(result.toolCallStatus == .failed)
        #expect(result.status == .failure)
        #expect(result.text == "boom")
    }

    @Test func terminalOutcomeMapsTimedOutExitToTimeout() async throws {
        let outcome = TerminalExecutionOutcome(
            taskId: "task-2",
            exitCode: nil,
            terminationSignal: nil,
            completionReason: .timedOut,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            transcriptPath: "/tmp/task-2.log",
            finalOutputSnippet: "partial"
        )

        let result = ToolExecutionResult.fromTerminalOutcome(outcome)

        #expect(result.toolCallStatus == .failed)
        #expect(result.status == .timeout)
        #expect(result.text == "partial")
    }
}