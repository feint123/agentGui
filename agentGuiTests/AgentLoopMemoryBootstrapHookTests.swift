import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

struct AgentLoopMemoryBootstrapHookTests {

    @Test func memoryBootstrapHookReturnsMessagePatch() async throws {
        let hook = MemoryBootstrapHook { _ in
            AgentLoopMessagePatch(
                insertions: [
                    .init(
                        index: 0,
                        message: .init(role: .user, content: .text("bootstrap"))
                    )
                ],
                metadata: ["source": "unified"]
            )
        }

        let result = try await hook.perform(
            stage: .prepareRun,
            context: .testMemoryBootstrapContext()
        )

        switch result {
        case .messagePatch(let patch):
            #expect(patch.insertions.count == 1)
            #expect(patch.metadata["source"] as? String == "unified")
        default:
            Issue.record("Expected message patch result")
        }
    }

    @Test func dispatcherCollectsBootstrapPatch() async throws {
        let dispatcher = AgentLoopHookDispatcher(hooks: [
            MemoryBootstrapHook { _ in
                AgentLoopMessagePatch(
                    insertions: [
                        .init(
                            index: 1,
                            message: .init(role: .assistant, content: .text("loaded"))
                        )
                    ],
                    metadata: ["source": "story"]
                )
            }
        ])

        let result = try await dispatcher.dispatch(
            .prepareRun,
            context: .testMemoryBootstrapContext()
        )

        #expect(result.messagePatch?.insertions.count == 1)
        #expect(result.messagePatch?.metadata["source"] as? String == "story")
    }
}

private extension AgentLoopHookContext {
    static func testMemoryBootstrapContext() -> AgentLoopHookContext {
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