import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRuntimeIntegrationTests {
    @Test func codingRequestProducesSingleUnifiedMemorySlice() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            unifiedRecords: [MemoryRecord.fixture(layer: .task, kind: .working, title: "Known task fact")],
            storyRecords: []
        )

        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix the failing build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let context = try await coordinator.prepareContext(for: request)
        #expect(context.renderedPrompt.contains("Known task fact"))
    }
}