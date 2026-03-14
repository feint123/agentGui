import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryPromptBudgetingTests {
    @Test func codingPlanPrioritizesTaskAndVerifiedSemanticRecordsUnderBudget() async throws {
        let planner = MemoryRetrievalPlanner()
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix the failing build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 2000
        )

        let plan = planner.makePlan(request: request, profiles: [.codingTask(), .userPreferences()])

        #expect(plan.includeArchived == false)
        #expect(plan.itemBudgetByLayer[.task] ?? 0 >= plan.itemBudgetByLayer[.episodic] ?? 0)
        #expect(plan.itemBudgetByLayer[.semantic] ?? 0 >= plan.itemBudgetByLayer[.episodic] ?? 0)
    }

    @Test func renderedPromptIsTrimmedToContextBudgetAndRecordsTrimMetadata() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(unifiedRecords: longFixtureRecords())
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 200
        )

        let context = try await coordinator.prepareContext(for: request)
        let snapshot = try #require(context.runtimeSnapshot)

        #expect(context.renderedPrompt.count <= 200)
        #expect(snapshot.metrics.totalEstimatedPromptChars >= context.renderedPrompt.count)
        #expect(snapshot.metrics.trimmedCharCount > 0)
        #expect(snapshot.metrics.postEnforcementPromptChars == context.renderedPrompt.count)
        #expect(snapshot.metrics.trimmedSectionIDs.isEmpty == false)
    }

    private func longFixtureRecords() -> [MemoryRecord] {
        [
            MemoryRecord.fixture(
                id: "task-1",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Known failure",
                summary: String(repeating: "shared scheme verification is still pending ", count: 6),
                verificationStatus: .verified
            ),
            MemoryRecord.fixture(
                id: "semantic-1",
                layer: .semantic,
                kind: .semantic,
                scope: .user,
                title: "Stable repo fact",
                summary: String(repeating: "workspace uses xcodebuild and shared schemes ", count: 6),
                verificationStatus: .verified
            ),
            MemoryRecord.fixture(
                id: "episodic-1",
                layer: .episodic,
                kind: .episodic,
                scope: .session(id: "s1"),
                title: "Recent failure",
                summary: String(repeating: "tool output repeated the same failure before verification ", count: 6),
                verificationStatus: .partial
            )
        ]
    }
}