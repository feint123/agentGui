import XCTest
import SwiftAnthropic
@testable import agentGui

final class VerificationEvidenceHookTests: XCTestCase {

    private let sessionID = "test-session-hook"

    // MARK: - Helpers

    private func makeHook(store: VerificationEvidenceStore = VerificationEvidenceStore()) -> VerificationEvidenceHook {
        VerificationEvidenceHook(sessionID: sessionID, evidenceStore: store)
    }

    private func makeBashRecord(
        command: String,
        output: String,
        isError: Bool = false
    ) -> ToolRunRecord {
        ToolRunRecord(
            toolCallId: "tc-bash",
            toolName: "bash",
            input: ["command": .string(command)],
            result: ToolExecutionResult(output, status: isError ? .failure : .success),
            sessionID: sessionID,
            executionContext: .mainAgent
        )
    }

    /// Build a ToolRunRecord for update_todo using proper DynamicContent array.
    private func makeTodoRecord(todos: [[String: String]]) -> ToolRunRecord {
        let items: [MessageResponse.Content.DynamicContent] = todos.map { dict in
            let mapped = dict.mapValues { MessageResponse.Content.DynamicContent.string($0) }
            return .dictionary(mapped)
        }
        return ToolRunRecord(
            toolCallId: "tc-todo",
            toolName: "update_todo",
            input: ["items": .array(items)],
            result: ToolExecutionResult("Todo list updated with \(todos.count) items.", status: .success),
            sessionID: sessionID,
            executionContext: .mainAgent
        )
    }

    // MARK: - preExecute always allows

    func test_preExecute_alwaysAllows() async {
        let hook = makeHook()
        let preview = ToolCallPreview(
            toolCallId: "id", toolName: "bash",
            input: [:], sessionID: sessionID, executionContext: .mainAgent
        )
        let decision = await hook.preExecute(toolCall: preview)
        if case .allow = decision { return }
        XCTFail("Expected .allow, got \(decision)")
    }

    // MARK: - bash: non-test command → passthrough

    func test_bash_nonTestCommand_passthrough() async {
        let hook = makeHook()
        let record = makeBashRecord(command: "ls -la", output: "total 0")
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough for non-test command, got \(action)")
    }

    // MARK: - bash: test command → appendAttachment + store recorded

    func test_bash_xcodebuildTest_appendsAttachment() async {
        let store = VerificationEvidenceStore()
        let hook = makeHook(store: store)
        let output = """
        ** TEST SUCCEEDED **
        Executed 4 tests, with 0 failures (0 unexpected) in 0.001 (0.003) seconds
        """
        let record = makeBashRecord(command: "xcodebuild test -scheme agentGui", output: output)
        let action = await hook.postExecute(record: record)
        switch action {
        case .appendAttachment(let text):
            XCTAssertTrue(text.contains("4"), "Expected pass count in label: \(text)")
        default:
            XCTFail("Expected .appendAttachment, got \(action)")
        }
        // Evidence must be recorded
        let hasEvidence = await store.hasEvidence(for: sessionID)
        XCTAssertTrue(hasEvidence)
    }

    func test_bash_testFailed_attachmentMentionsFail() async {
        let hook = makeHook()
        let output = """
        ** TEST FAILED **
        Executed 3 tests, with 2 failures (0 unexpected) in 0.050 (0.060) seconds
        """
        let record = makeBashRecord(command: "xcodebuild test -scheme agentGui", output: output)
        let action = await hook.postExecute(record: record)
        switch action {
        case .appendAttachment(let text):
            XCTAssertTrue(
                text.lowercased().contains("fail") || text.lowercased().contains("失败"),
                "Expected failure indication in: \(text)"
            )
        default:
            XCTFail("Expected .appendAttachment, got \(action)")
        }
    }

    // MARK: - bash: isError → passthrough (even if test command)

    func test_bash_errorResult_passthrough() async {
        let hook = makeHook()
        let record = makeBashRecord(
            command: "xcodebuild test -scheme agentGui",
            output: "Error: build failed",
            isError: true
        )
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough for error result, got \(action)")
    }

    // MARK: - todo nudge: < 3 items → passthrough

    func test_todo_lessThan3Items_passthrough() async {
        let hook = makeHook()
        let todos = [
            ["id": "1", "title": "Fix bug", "status": "done"],
            ["id": "2", "title": "Review PR", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough for < 3 todos, got \(action)")
    }

    // MARK: - todo nudge: not all done → passthrough

    func test_todo_notAllDone_passthrough() async {
        let hook = makeHook()
        let todos = [
            ["id": "1", "title": "Fix A", "status": "done"],
            ["id": "2", "title": "Fix B", "status": "pending"],
            ["id": "3", "title": "Fix C", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough when not all done, got \(action)")
    }

    // MARK: - todo nudge: all done, no evidence → appendAttachment

    func test_todo_allDone3Plus_noEvidence_appendsNudge() async {
        let store = VerificationEvidenceStore()
        let hook = VerificationEvidenceHook(sessionID: sessionID, evidenceStore: store)
        let todos = [
            ["id": "1", "title": "Fix A", "status": "done"],
            ["id": "2", "title": "Fix B", "status": "done"],
            ["id": "3", "title": "Fix C", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        switch action {
        case .appendAttachment(let text):
            XCTAssertTrue(text.contains("测试") || text.lowercased().contains("test"),
                          "Nudge should mention testing: \(text)")
        default:
            XCTFail("Expected .appendAttachment nudge, got \(action)")
        }
    }

    // MARK: - todo nudge: all done, HAS evidence → passthrough (no nudge)

    func test_todo_allDone_withEvidence_passthrough() async {
        let store = VerificationEvidenceStore()
        let summary = VerificationEvidenceSummary(
            command: "swift test", passCount: 5, failCount: 0,
            failureSummary: nil, exitedZero: true, capturedAt: Date()
        )
        await store.record(summary, sessionID: sessionID)

        let hook = VerificationEvidenceHook(sessionID: sessionID, evidenceStore: store)
        let todos = [
            ["id": "1", "title": "Fix A", "status": "done"],
            ["id": "2", "title": "Fix B", "status": "done"],
            ["id": "3", "title": "Fix C", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough when evidence exists, got \(action)")
    }

    // MARK: - todo nudge: all done but has 'test' todo → passthrough

    func test_todo_allDone_verificationTodoPresent_passthrough() async {
        let hook = makeHook()
        let todos = [
            ["id": "1", "title": "Fix A", "status": "done"],
            ["id": "2", "title": "Fix B", "status": "done"],
            ["id": "3", "title": "Run tests to verify", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough when verification todo exists, got \(action)")
    }

    // MARK: - postFailure always propagates

    func test_postFailure_propagates() async {
        let hook = makeHook()
        let preview = ToolCallPreview(
            toolCallId: "id", toolName: "bash",
            input: [:], sessionID: sessionID, executionContext: .mainAgent
        )
        let action = await hook.postFailure(
            toolCall: preview,
            error: ToolExecutionHookError(message: "cmd not found")
        )
        if case .propagate = action { return }
        XCTFail("Expected .propagate, got \(action)")
    }
}
