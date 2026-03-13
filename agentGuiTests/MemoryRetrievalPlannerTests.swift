import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRetrievalPlannerTests {
    @Test func creativePlanIncludesTaskBetweenWorkingAndLongerTermLayers() async throws {
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
        #expect(Array(plan.orderedLayers.prefix(4)) == [.working, .task, .semantic, .episodic])
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

    @Test func retrievalPlannerBudgetsByIntentNotOnlyTaskKind() async throws {
        let planner = MemoryRetrievalPlanner()
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
        let classifier = MemoryRetrievalIntentClassifier()
        let intent = classifier.classify(request: request, phaseHint: .verification)
        let plan = planner.makePlan(request: request, profiles: [MemoryDomainProfile.codingTask()], intent: intent)

        #expect(intent.phase == .verification)
        #expect(plan.objectBudgetByType[MemoryRetrievalObjectType.procedure, default: 0] >= 1)
        #expect(plan.objectBudgetByType[MemoryRetrievalObjectType.fact, default: 0] >= 1)
    }
}