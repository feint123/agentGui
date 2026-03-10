import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRetrievalPlannerTests {
    @Test func creativePlanPrefersWorkingThenSemanticThenEpisodic() async throws {
        let planner = MemoryRetrievalPlanner()
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "继续写这一章，先确认顾沉状态和北塔规则",
            taskKind: .creativeWriting,
            projectId: "project-1",
            workspaceRoot: nil,
            contextBudget: 3000
        )

        let plan = planner.makePlan(request: request, profiles: [.creativeWriting(), .userPreferences()])
        #expect(Array(plan.orderedLayers.prefix(3)) == [.working, .semantic, .episodic])
    }

    @Test func generalPlanExcludesArchivedRecordsByDefault() async throws {
        let planner = MemoryRetrievalPlanner()
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Remember my preferred style",
            taskKind: .generalAssistant,
            projectId: nil,
            workspaceRoot: nil,
            contextBudget: 3000
        )

        let plan = planner.makePlan(request: request, profiles: [.userPreferences()])
        #expect(plan.includeArchived == false)
    }
}