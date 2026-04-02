import XCTest
import SwiftAnthropic
@testable import agentGui

final class MemoryRecallHookTests: XCTestCase {

    func test_supports_willStartRound_true() {
        let hook = MemoryRecallHook(recallService: nil)
        XCTAssertTrue(hook.supports(.willStartRound))
    }

    func test_supports_prepareRun_false() {
        let hook = MemoryRecallHook(recallService: nil)
        XCTAssertFalse(hook.supports(.prepareRun))
    }

    func test_perform_nilService_returnsContinue() async throws {
        let hook = MemoryRecallHook(recallService: nil)
        let context = makeContext(executionContext: .mainAgent)
        let result = try await hook.perform(stage: .willStartRound, context: context)
        if case .continue = result { /* ok */ } else {
            XCTFail("nil service should return .continue")
        }
    }

    func test_perform_subagentContext_returnsContinue() async throws {
        // 在 subagent 上下文中不应触发召回（防递归）
        let mockService = MockRecallService(injectText: "recalled memory content")
        let hook = MemoryRecallHook(recallService: mockService)
        let context = makeContext(executionContext: .subagent)
        let result = try await hook.perform(stage: .willStartRound, context: context)
        if case .continue = result { /* ok */ } else {
            XCTFail("subagent context should return .continue")
        }
    }

    func test_perform_withInjectionText_returnsMessagePatch() async throws {
        let injectionText = "<system-reminder>\n## Relevant Memory: foo_abc12345.md\n\nContent here\n</system-reminder>"
        let mockService = MockRecallService(injectText: injectionText)
        let hook = MemoryRecallHook(recallService: mockService)
        let context = makeContext(executionContext: .mainAgent)
        let result = try await hook.perform(stage: .willStartRound, context: context)
        if case .messagePatch(let patch) = result {
            XCTAssertFalse(patch.insertions.isEmpty)
            // 验证注入内容包含 system-reminder
            if case .text(let t) = patch.insertions[0].message.content {
                XCTAssertTrue(t.contains("<system-reminder>"))
            } else {
                XCTFail("注入消息应为 .text 内容")
            }
        } else {
            XCTFail("有召回内容时应返回 .messagePatch，got: \(result)")
        }
    }

    func test_perform_noRecalledContent_returnsContinue() async throws {
        let mockService = MockRecallService(injectText: nil)
        let hook = MemoryRecallHook(recallService: mockService)
        let context = makeContext(executionContext: .mainAgent)
        let result = try await hook.perform(stage: .willStartRound, context: context)
        if case .continue = result { /* ok */ } else {
            XCTFail("无召回内容时应返回 .continue")
        }
    }

    // MARK: - Helpers

    private func makeContext(executionContext: ToolContext) -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: executionContext,
            modelId: "claude-sonnet-4-6",
            roundIndex: 0,
            phase: "executing"
        )
    }
}

// MARK: - Test Double

private struct MockRecallService: MemoryRecallServiceProtocol {
    let injectText: String?
    func recall(
        messagesSnapshot: [MessageParameter.Message],
        now: Date
    ) async -> String? {
        return injectText
    }
}
