import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRetrievalIntentClassifierTests {
    @Test func classifierRespectsExplicitPhaseHint() async throws {
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix failing SwiftUI snapshot test",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let intent = MemoryRetrievalIntentClassifier().classify(request: request, phaseHint: .verification)

        #expect(intent.phase == .verification)
        #expect(intent.neededObjectTypes.contains(.procedure))
    }
}