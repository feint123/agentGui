import XCTest
import SwiftAnthropic
@testable import agentGui

@MainActor
final class ToolExecutionHookCoordinatorIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makePendingTool(name: String = "bash", id: String = "tc-1") -> AgentLoopPendingTool {
        var tool = AgentLoopPendingTool(id: id, name: name)
        tool.partialJson = #"{"command":"echo hi"}"#
        return tool
    }

    private func makeRecord(toolName: String = "bash") -> ToolCall {
        ToolCall(toolCallId: "tc-1", kind: .execute)
    }

    /// Builds a coordinator whose `executeTool` closure returns the provided result.
    private func makeCoordinator(
        executionResult: ToolExecutionResult,
        pipeline: ToolExecutionHookPipeline = .empty
    ) -> AgentLoopToolExecutionCoordinator {
        let capturedResult = executionResult
        return AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                runSubagent: { _, _ in AgentMessage(sender: "test", recipient: "main", content: .text(""), metadata: [:]) },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in capturedResult },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: pipeline
            )
        )
    }

    // MARK: - preExecute block prevents execution

    func test_preExecuteBlock_executorNeverCalled() async {
        var executorCalled = false
        let blockHook = SpyPreHook(returning: .block(reason: "test-block"))
        let pipeline = ToolExecutionHookPipeline(hooks: [blockHook])
        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                runSubagent: { _, _ in AgentMessage(sender: "test", recipient: "main", content: .text(""), metadata: [:]) },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in
                    executorCalled = true
                    return .success("should-not-reach")
                },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: pipeline
            )
        )

        let outcome = await coordinator.execute(
            pendingTool: makePendingTool(),
            record: makeRecord()
        )

        XCTAssertFalse(executorCalled)
        XCTAssertTrue(outcome.result.isError)
        XCTAssertTrue(outcome.result.text.contains("test-block"))
    }

    // MARK: - preExecute allow lets execution proceed

    func test_preExecuteAllow_hookIsCalled() async {
        let allowHook = SpyPreHook(returning: .allow)
        let pipeline = ToolExecutionHookPipeline(hooks: [allowHook])
        let coordinator = makeCoordinator(
            executionResult: .success("ok"),
            pipeline: pipeline
        )
        _ = await coordinator.execute(pendingTool: makePendingTool(), record: makeRecord())
        XCTAssertTrue(allowHook.called)
    }

    // MARK: - postExecute appendAttachment updates ToolCall.toolResultSummary

    func test_postExecuteAppend_updatesSummaryOnRecord() async {
        let appendHook = SpyPostHook(returning: .appendAttachment("change-review: 2 files"))
        let pipeline = ToolExecutionHookPipeline(hooks: [appendHook])
        let coordinator = makeCoordinator(
            executionResult: .success("tool-output"),
            pipeline: pipeline
        )
        let record = makeRecord()
        let outcome = await coordinator.execute(pendingTool: makePendingTool(), record: record)

        XCTAssertEqual(outcome.record.toolResultSummary, "change-review: 2 files")
    }

    // MARK: - postExecute rewriteResult replaces result

    func test_postExecuteRewrite_replacesResult() async {
        let rewrittenResult = ToolExecutionResult.success("rewritten-by-hook")
        let rewriteHook = SpyPostHook(returning: .rewriteResult(rewrittenResult))
        let pipeline = ToolExecutionHookPipeline(hooks: [rewriteHook])
        let coordinator = makeCoordinator(
            executionResult: .success("original"),
            pipeline: pipeline
        )
        let outcome = await coordinator.execute(pendingTool: makePendingTool(), record: makeRecord())
        XCTAssertEqual(outcome.result.text, "rewritten-by-hook")
    }

    // MARK: - postFailure recover replaces failure result

    func test_postFailureRecover_replacesFailureWithSuccess() async {
        let recoveredResult = ToolExecutionResult.success("recovered")
        let recoverHook = SpyFailureHook(returning: .recover(recoveredResult))
        let pipeline = ToolExecutionHookPipeline(hooks: [recoverHook])
        let coordinator = makeCoordinator(
            executionResult: .failure("original-error"),
            pipeline: pipeline
        )
        let outcome = await coordinator.execute(pendingTool: makePendingTool(), record: makeRecord())
        XCTAssertFalse(outcome.result.isError)
        XCTAssertEqual(outcome.result.text, "recovered")
    }

    // MARK: - postFailure appendDiagnostic appends to failure text

    func test_postFailureDiagnostic_appendsToFailureText() async {
        let diagHook = SpyFailureHook(returning: .appendDiagnostic("hint: check file permissions"))
        let pipeline = ToolExecutionHookPipeline(hooks: [diagHook])
        let coordinator = makeCoordinator(
            executionResult: .failure("exec error"),
            pipeline: pipeline
        )
        let outcome = await coordinator.execute(pendingTool: makePendingTool(), record: makeRecord())
        XCTAssertTrue(outcome.result.isError)
        XCTAssertTrue(outcome.result.text.contains("hint: check file permissions"),
                      "Diagnostic must be appended: \(outcome.result.text)")
    }

    // MARK: - no pipeline → normal execution, no crash

    func test_noPipeline_executionProceedsNormally() async {
        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                runSubagent: { _, _ in AgentMessage(sender: "test", recipient: "main", content: .text(""), metadata: [:]) },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in .success("normal-result") },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: nil
            )
        )
        let outcome = await coordinator.execute(
            pendingTool: makePendingTool(),
            record: makeRecord()
        )
        XCTAssertFalse(outcome.result.isError)
        XCTAssertEqual(outcome.result.text, "normal-result")
    }
}
