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
}