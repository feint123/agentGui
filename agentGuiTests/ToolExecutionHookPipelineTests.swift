import XCTest
import SwiftAnthropic
@testable import agentGui

final class ToolExecutionHookPipelineTests: XCTestCase {

    // MARK: - Helpers

    private func makePreview(toolName: String = "bash", sessionID: String = "s1") -> ToolCallPreview {
        ToolCallPreview(
            toolCallId: "tc-\(toolName)",
            toolName: toolName,
            input: ["command": .string("echo hi")],
            sessionID: sessionID,
            executionContext: .mainAgent
        )
    }

    private func makeRunRecord(
        toolName: String = "bash",
        resultText: String = "output",
        isError: Bool = false
    ) -> ToolRunRecord {
        ToolRunRecord(
            toolCallId: "tc-\(toolName)",
            toolName: toolName,
            input: [:],
            result: ToolExecutionResult(resultText, status: isError ? .failure : .success),
            sessionID: "s1",
            executionContext: .mainAgent
        )
    }

    // MARK: - preExecute: all allow → .allow

    func test_preExecute_allAllow_returnsAllow() async {
        let hook1 = SpyPreHook(returning: .allow)
        let hook2 = SpyPreHook(returning: .allow)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertFalse(outcome.shouldBlock)
        XCTAssertNil(outcome.blockReason)
        XCTAssertTrue(outcome.additionalContexts.isEmpty)
    }

    // MARK: - preExecute: first block wins, later hooks not called

    func test_preExecute_firstBlock_preventsSubsequentHooks() async {
        let hook1 = SpyPreHook(returning: .block(reason: "forbidden"))
        let hook2 = SpyPreHook(returning: .allow)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertTrue(outcome.shouldBlock)
        XCTAssertEqual(outcome.blockReason, "forbidden")
        XCTAssertFalse(hook2.called, "Hook after a blocking hook must not be called")
    }

    // MARK: - preExecute: attachContext accumulates from all hooks

    func test_preExecute_attachContext_accumulatesAll() async {
        let hook1 = SpyPreHook(returning: .attachContext("ctx-A"))
        let hook2 = SpyPreHook(returning: .attachContext("ctx-B"))
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertFalse(outcome.shouldBlock)
        XCTAssertEqual(outcome.additionalContexts, ["ctx-A", "ctx-B"])
    }

    // MARK: - preExecute: hook throws → treated as .allow (non-fatal)

    func test_preExecute_hookThrows_treatedAsAllow() async {
        let hook = ThrowingPreHook()
        let pipeline = ToolExecutionHookPipeline(hooks: [hook])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertFalse(outcome.shouldBlock)
    }

    // MARK: - postExecute: all passthrough → .passthrough

    func test_postExecute_allPassthrough_returnsPassthrough() async {
        let hook1 = SpyPostHook(returning: .passthrough)
        let hook2 = SpyPostHook(returning: .passthrough)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .passthrough = action else {
            return XCTFail("Expected passthrough, got \(action)")
        }
    }

    // MARK: - postExecute: appendAttachment accumulates

    func test_postExecute_multipleAppend_joinedWithNewline() async {
        let hook1 = SpyPostHook(returning: .appendAttachment("line1"))
        let hook2 = SpyPostHook(returning: .appendAttachment("line2"))
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .appendAttachment(let text) = action else {
            return XCTFail("Expected appendAttachment")
        }
        XCTAssertEqual(text, "line1\nline2")
    }

    // MARK: - postExecute: first rewriteResult wins

    func test_postExecute_rewriteResult_firstWins() async {
        let rewrittenResult = ToolExecutionResult.success("rewritten")
        let hook1 = SpyPostHook(returning: .rewriteResult(rewrittenResult))
        let hook2 = SpyPostHook(returning: .appendAttachment("should-be-ignored"))
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .rewriteResult(let r) = action else {
            return XCTFail("Expected rewriteResult")
        }
        XCTAssertEqual(r.text, "rewritten")
        XCTAssertFalse(hook2.called, "Hooks after first rewrite must not be called")
    }

    // MARK: - postExecute: hook throws → treated as passthrough (non-fatal)

    func test_postExecute_hookThrows_treatedAsPassthrough() async {
        let hook = ThrowingPostHook()
        let pipeline = ToolExecutionHookPipeline(hooks: [hook])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .passthrough = action else {
            return XCTFail("Expected passthrough on hook failure")
        }
    }

    // MARK: - postFailure: propagate by default

    func test_postFailure_allPropagate_returnsPropagation() async {
        let hook = SpyFailureHook(returning: .propagate)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook])
        let action = await pipeline.runPostFailure(
            toolCall: makePreview(),
            error: SampleError()
        )
        guard case .propagate = action else {
            return XCTFail("Expected propagate")
        }
    }

    // MARK: - postFailure: recover wins

    func test_postFailure_recover_returnsRecoveredResult() async {
        let recovered = ToolExecutionResult.success("recovered")
        let hook1 = SpyFailureHook(returning: .recover(recovered))
        let hook2 = SpyFailureHook(returning: .propagate)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostFailure(
            toolCall: makePreview(),
            error: SampleError()
        )
        guard case .recover(let r) = action else {
            return XCTFail("Expected recovery")
        }
        XCTAssertEqual(r.text, "recovered")
        XCTAssertFalse(hook2.called, "Hooks after recovery must not be called")
    }

    // MARK: - postFailure: appendDiagnostic accumulates

    func test_postFailure_multipleDiagnostics_joinedWithNewline() async {
        let hook1 = SpyFailureHook(returning: .appendDiagnostic("diag-A"))
        let hook2 = SpyFailureHook(returning: .appendDiagnostic("diag-B"))
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostFailure(
            toolCall: makePreview(),
            error: SampleError()
        )
        guard case .appendDiagnostic(let text) = action else {
            return XCTFail("Expected appendDiagnostic")
        }
        XCTAssertEqual(text, "diag-A\ndiag-B")
    }

    // MARK: - postFailure: hook throws → treated as propagate (non-fatal)

    func test_postFailure_hookThrows_treatedAsPropagate() async {
        let hook = ThrowingFailureHook()
        let pipeline = ToolExecutionHookPipeline(hooks: [hook])
        let action = await pipeline.runPostFailure(
            toolCall: makePreview(),
            error: SampleError()
        )
        guard case .propagate = action else {
            return XCTFail("Expected propagate on hook failure")
        }
    }

    // MARK: - empty pipeline

    func test_emptyPipeline_preExecute_returnsAllow() async {
        let pipeline = ToolExecutionHookPipeline(hooks: [])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertFalse(outcome.shouldBlock)
    }

    func test_emptyPipeline_postExecute_returnsPassthrough() async {
        let pipeline = ToolExecutionHookPipeline(hooks: [])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .passthrough = action else {
            return XCTFail("Expected passthrough from empty pipeline")
        }
    }
}

// MARK: - Test Doubles

struct SampleError: Error {}

/// Spy for preExecute
final class SpyPreHook: ToolExecutionHook, @unchecked Sendable {
    let hookID: String = "spy-pre"
    private let decision: PreExecuteDecision
    private(set) var called = false

    init(returning decision: PreExecuteDecision) { self.decision = decision }

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        called = true
        return decision
    }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}

/// Spy for postExecute
final class SpyPostHook: ToolExecutionHook, @unchecked Sendable {
    let hookID: String = "spy-post"
    private let action: PostExecuteAction
    private(set) var called = false

    init(returning action: PostExecuteAction) { self.action = action }

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        called = true
        return action
    }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}

/// Spy for postFailure
final class SpyFailureHook: ToolExecutionHook, @unchecked Sendable {
    let hookID: String = "spy-failure"
    private let action: FailureAction
    private(set) var called = false

    init(returning action: FailureAction) { self.action = action }

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        called = true
        return action
    }
}

/// Neutral hook for pre-execute (simulates a hook that returns default)
struct ThrowingPreHook: ToolExecutionHook {
    let hookID = "throwing-pre"
    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}

/// Neutral hook for post-execute (simulates a hook that returns default)
struct ThrowingPostHook: ToolExecutionHook {
    let hookID = "throwing-post"
    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}

/// Neutral hook for post-failure (simulates a hook that returns default)
struct ThrowingFailureHook: ToolExecutionHook {
    let hookID = "throwing-failure"
    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}
