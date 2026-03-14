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
        let objectTypeNames = Set(plan.objectBudgetByType.keys.map(\.rawValue))

        #expect(intent.phase == .verification)
        #expect(plan.objectBudgetByType[MemoryRetrievalObjectType.procedure, default: 0] >= 1)
        #expect(plan.objectBudgetByType[MemoryRetrievalObjectType.fact, default: 0] >= 1)
        #expect(objectTypeNames.contains("bridge") == false)
    }

    @Test func retrievalPlannerUsesFrontierAndCounterexamplePriority() async throws {
        let planner = MemoryRetrievalPlanner()
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let plan = planner.makeRMSPlan(
            request: request,
            profiles: [MemoryDomainProfile.codingTask()],
            epistemicState: EpistemicState(
                frontiers: [
                    FrontierMemory(
                        frontierId: "f-1",
                        goal: "Fix build",
                        openClaim: "Need scheme evidence",
                        uncertaintyType: .tooling,
                        impactLevel: .high,
                        suggestedProbe: "Run xcodebuild -list",
                        stopCondition: "Scheme confirmed"
                    )
                ],
                activeConstraints: [
                    ConstraintMemory(id: "c-1", summary: "Inspect before edit", scope: .session(id: "s1"))
                ],
                verificationDebt: [
                    VerificationDebt(id: "d-1", claim: "Build fix works", reason: "Need direct test evidence")
                ],
                counterexamples: [
                    CounterexampleMemory(id: "ce-1", summary: "Do not edit before inspect", replacementAction: "Inspect first")
                ]
            )
        )
        let objectTypeNames = Set(plan.objectBudgetByType.keys.map(\.rawValue))

        #expect(plan.orderedLayers.first == .task)
        #expect(plan.objectBudgetByType[.counterexample, default: 0] >= 2)
        #expect(plan.objectBudgetByType[.constraint, default: 0] >= 1)
        #expect(plan.objectBudgetByType[.verificationDebt, default: 0] >= 1)
        #expect(objectTypeNames.contains("bridge") == false)
        #expect(plan.objectBudgetByType[.fact, default: 0] >= 1)
    }
}