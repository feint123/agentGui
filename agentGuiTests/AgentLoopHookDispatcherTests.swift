import Foundation
import Testing
@testable import agentGui

struct AgentLoopHookDispatcherTests {

    @Test func dispatcherExecutesHooksInStableOrder() async throws {
        let recorder = HookCallRecorder()
        let dispatcher = AgentLoopHookDispatcher(hooks: [
            TestObserverHook(id: "late", order: 20, recorder: recorder),
            TestObserverHook(id: "early", order: 10, recorder: recorder)
        ])

        _ = try await dispatcher.dispatch(
            .didStartRun,
            context: .testRunContext()
        )

        #expect(recorder.ids == ["early", "late"])
    }

    @Test func dispatcherContinuesAfterObserverFailure() async throws {
        let recorder = HookCallRecorder()
        let dispatcher = AgentLoopHookDispatcher(hooks: [
            TestThrowingObserverHook(id: "fails", order: 10),
            TestObserverHook(id: "after", order: 20, recorder: recorder)
        ])

        let result = try await dispatcher.dispatch(
            .didStartRun,
            context: .testRunContext()
        )

        #expect(recorder.ids == ["after"])
        #expect(result.failures.count == 1)
        #expect(result.abortReason == nil)
    }

    @Test func dispatcherAbortsOnRequiredMutatorFailure() async throws {
        let dispatcher = AgentLoopHookDispatcher(hooks: [
            TestRequiredMutatorHook(id: "required-mutator", order: 10)
        ])

        let result = try await dispatcher.dispatch(
            .prepareRun,
            context: .testRunContext()
        )

        #expect(result.abortReason == .requiredHookFailed(hookID: "required-mutator"))
    }

    @Test func dispatcherCollectsDecisionResults() async throws {
        let dispatcher = AgentLoopHookDispatcher(hooks: [
            TestDecisionHook(
                id: "decision",
                order: 10,
                decision: .finalization(.allow)
            )
        ])

        let result = try await dispatcher.dispatch(
            .decideFinalization,
            context: .testRunContext()
        )

        #expect(result.decisions == [.finalization(.allow)])
    }
}

private final class HookCallRecorder {
    private(set) var ids: [String] = []

    func record(_ id: String) {
        ids.append(id)
    }
}

private struct TestObserverHook: AgentLoopHook {
    let id: String
    let order: Int
    let recorder: HookCallRecorder
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .didStartRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        recorder.record(id)
        return .continue
    }
}

private struct TestThrowingObserverHook: AgentLoopHook {
    let id: String
    let order: Int
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .didStartRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        throw TestHookError.expectedFailure
    }
}

private struct TestRequiredMutatorHook: AgentLoopHook {
    let id: String
    let order: Int
    let kind: AgentLoopHookKind = .mutator
    let isRequired = true

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .prepareRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        throw TestHookError.expectedFailure
    }
}

private struct TestDecisionHook: AgentLoopHook {
    let id: String
    let order: Int
    let decision: AgentLoopDecision
    let kind: AgentLoopHookKind = .decisionMaker
    let isRequired = true

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .decideFinalization
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        .decision(decision)
    }
}

private enum TestHookError: Error {
    case expectedFailure
}

private extension AgentLoopHookContext {
    static func testRunContext() -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 0,
            phase: "executing"
        )
    }
}