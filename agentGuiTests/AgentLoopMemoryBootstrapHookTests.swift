import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

struct AgentLoopMemoryBootstrapHookTests {

    @Test func memoryBootstrapComposerBuildsRMSPromptPatch() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadRMSState: {
                    RMSState(
                        taskID: "task-1",
                        sessionID: "session-1",
                        threadID: "thread-1",
                        summary: "Fix build",
                        frontiers: [
                            .init(
                                id: "frontier-1",
                                goal: "Fix build",
                                openClaim: "Need to verify shared scheme",
                                suggestedProbe: "Run xcodebuild -list",
                                stopCondition: "Scheme confirmed"
                            )
                        ],
                        constraints: [
                            .init(
                                id: "constraint-1",
                                summary: "Inspect before editing",
                                scope: .session(id: "s1")
                            )
                        ],
                        verificationDebts: [
                            .init(
                                id: "debt-1",
                                claim: "Scheme issue",
                                reason: "No direct evidence yet"
                            )
                        ]
                    )
                },
                loadInsights: { _ in [] }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 1)
        let text = extractBootstrapText(from: composition.patch?.insertions.first?.message.content)

        #expect(text.contains("Need to verify shared scheme"))
        #expect(text.contains("Inspect before editing"))
        #expect(text.contains("Scheme issue"))
    }

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

        let insertionCount = result.messagePatch.map { $0.insertions.count }
        let source: String?
        if let patch = result.messagePatch {
            source = patch.metadata["source"] as? String
        } else {
            source = nil
        }

        #expect(insertionCount == 1)
        #expect(source == "story")
    }
}

private func extractBootstrapText(from content: MessageParameter.Message.Content?) -> String {
    guard let content else { return "" }
    if case .text(let value) = content {
        return value
    }
    return ""
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