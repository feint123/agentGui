import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentLoopMemoryBootstrapComposerTests {

    @Test func composerPrefersUnifiedBootstrapWhenAvailable() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadUnifiedContext: {
                    MemoryRuntimeContext(
                        profiles: ["coding-task"],
                        records: [MemoryRecord.fixture(layer: .task)],
                        warnings: ["warn"],
                        renderedPrompt: "Unified prompt",
                        runtimeSnapshot: .fixture(id: "snapshot-1")
                    )
                },
                loadTaskMemory: { nil },
                loadTaskMemoryPromptText: { nil },
                saveRuntimeSnapshot: { $0.id }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 1)

        #expect(composition.patch?.metadata["source"] as? String == "unified")
        #expect(composition.runtimeProfiles == ["coding-task"])
        #expect(composition.runtimeLayers == [MemoryLayer.task.rawValue])
        #expect(composition.runtimeWarnings == ["warn"])
        #expect(composition.runtimeSnapshotID == "snapshot-1")
    }

    @Test func composerBuildsTaskMemoryFallbackWhenUnifiedContextIsMissing() async throws {
        var taskMemory = TaskMemory(sessionId: "session-1")
        taskMemory.confirmedFacts = ["Repo root is agentGui"]
        taskMemory.failedAttempts = [FailedAttempt(action: "bash:test", reason: "failed")]

        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadUnifiedContext: { nil },
                loadTaskMemory: { taskMemory },
                loadTaskMemoryPromptText: { "## Confirmed Facts\n- Repo root is agentGui" },
                saveRuntimeSnapshot: { _ in nil }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 4)

        #expect(composition.patch?.insertions.count == 2)
        #expect(composition.patch?.metadata["source"] as? String == "task-unified")
        #expect(composition.patch?.metadata["confirmedFactCount"] as? Int == 1)
        #expect(composition.patch?.metadata["failedAttemptCount"] as? Int == 1)
    }

    @Test func composerKeepsTaskBootstrapOrderingStable() async throws {
        var taskMemory = TaskMemory(sessionId: "session-1")
        taskMemory.confirmedFacts = ["fact"]

        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadUnifiedContext: { nil },
                loadTaskMemory: { taskMemory },
                loadTaskMemoryPromptText: { "task prompt" },
                saveRuntimeSnapshot: { _ in nil }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 5)

        #expect(composition.patch?.insertions.map(\.index) == [0, 1])
    }

    @Test func composerReturnsNoPatchWhenAllSourcesAreEmpty() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadUnifiedContext: { nil },
                loadTaskMemory: { nil },
                loadTaskMemoryPromptText: { nil },
                saveRuntimeSnapshot: { _ in nil }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 2)

        #expect(composition.patch == nil)
    }
}