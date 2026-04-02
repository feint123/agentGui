import Testing
import Foundation
@testable import agentGui

struct MemoryConsolidationHookTests {

    @Test func supportedStageIsWillFinishRun() {
        let hook = MemoryConsolidationHook(callback: { _ in })
        #expect(hook.supports(.willFinishRun))
        #expect(!hook.supports(.willStartRound))
        #expect(!hook.supports(.prepareRun))
    }

    @Test func performReturnsContinueImmediately() async throws {
        let hook = MemoryConsolidationHook(callback: { _ in })
        let context = makeTestContext(executionContext: .mainAgent)
        let result = try await hook.perform(stage: .willFinishRun, context: context)
        #expect(result == .continue)
    }

    @Test func doesNotFireForSubagentContext() async throws {
        var fired = false
        let hook = MemoryConsolidationHook(callback: { _ in fired = true })
        let context = makeTestContext(executionContext: .subagent)
        _ = try await hook.perform(stage: .willFinishRun, context: context)
        // 等一个 runloop 让 fire-and-forget task 有机会运行
        try await Task.sleep(for: .milliseconds(50))
        #expect(!fired)
    }

    @Test func firesForMainAgentContext() async throws {
        let checker = FiredChecker()
        let hook = MemoryConsolidationHook(callback: { _ in await checker.markFired() })
        let context = makeTestContext(executionContext: .mainAgent)
        _ = try await hook.perform(stage: .willFinishRun, context: context)
        // 轮询最多 1s，等待 detached task 回调完成
        let deadline = ContinuousClock.now + .seconds(1)
        while await !checker.fired {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await checker.fired)
    }

    // MARK: - Helpers

    private func makeTestContext(executionContext: ToolContext) -> AgentLoopHookContext {
        var ctx = AgentLoopHookContext(
            runID: "test-run",
            sessionID: "test-session",
            workflowID: nil,
            executionContext: executionContext,
            modelId: "claude-sonnet-4-6",
            roundIndex: 0,
            phase: "finalizing"
        )
        ctx.messagesSnapshot = []
        ctx.metadata = [:]
        return ctx
    }
}

/// 线程安全的 fired 标记，供 fire-and-forget 测试使用。
private actor FiredChecker {
    private(set) var fired = false
    func markFired() { fired = true }
}
