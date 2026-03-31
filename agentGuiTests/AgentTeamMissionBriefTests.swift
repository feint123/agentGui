import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentTeamMissionBriefTests {
    @Test
    func briefRoundTripsThroughJSON() throws {
        let conductor = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        let reviewer = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        let brief = AgentTeamMissionBrief(
            objective: "为 ACP team 制定修复方案",
            constraints: ["仅修改 Swift 文件", "保持 UI 稳定"],
            acceptanceCriteria: ["存在 focused tests", "Mission Header 可回显 brief"],
            mode: .executionDelivery,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 2),
            initialContextSummary: "来源聊天包含 bug 复现与日志摘要。",
            providerPlan: AgentTeamProviderPlan(
                roleAssignments: [
                    AgentTeamProviderRoleAssignment(providerReference: conductor, roles: [.conductor, .worker]),
                    AgentTeamProviderRoleAssignment(providerReference: reviewer, roles: [.reviewer])
                ],
                dispatchPolicy: .manualSelection
            )
        )

        let data = try JSONEncoder().encode(brief)
        let decoded = try JSONDecoder().decode(AgentTeamMissionBrief.self, from: data)

        #expect(decoded == brief)
    }

    @Test
    func providerPlanPreservesEligibleProvidersAndRoles() {
        let conductor = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        let reviewer = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        let plan = AgentTeamProviderPlan(
            roleAssignments: [
                AgentTeamProviderRoleAssignment(providerReference: conductor, roles: [.conductor, .worker]),
                AgentTeamProviderRoleAssignment(providerReference: reviewer, roles: [.reviewer])
            ],
            dispatchPolicy: .sourceSessionSeeded
        )

        #expect(plan.eligibleProviders == [conductor, reviewer])
        #expect(plan.preferredConductor == conductor)
        #expect(plan.preferredReviewer == reviewer)
        #expect(plan.dispatchPolicy == .sourceSessionSeeded)
    }

    @Test
    func dispatchBudgetOnlyHasMaxActiveProviders() {
        let budget = AgentTeamDispatchBudget(maxActiveProviders: 3)
        #expect(budget.maxActiveProviders == 3)
    }

    @Test
    func briefUsesDispatchBudget() throws {
        let brief = AgentTeamMissionBrief(
            objective: "测试",
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 2),
            initialContextSummary: ""
        )
        let data = try JSONEncoder().encode(brief)
        let decoded = try JSONDecoder().decode(AgentTeamMissionBrief.self, from: data)
        #expect(decoded.dispatchBudget.maxActiveProviders == 2)
    }

    @Test
    func providerRoleAssignmentAllowsSameProviderAsConductorAndReviewer() {
        let provider = ExecutionProviderReference.builtIn
        var assignment = AgentTeamProviderRoleAssignment(providerReference: provider)
        assignment.roles.insert(.conductor)
        assignment.roles.insert(.reviewer)

        #expect(assignment.roles.contains(.conductor))
        #expect(assignment.roles.contains(.reviewer))
        #expect(assignment.isConductor)
        #expect(assignment.isReviewer)
    }

    @Test
    func providerRoleAssignmentRoundTripsThroughJSON() throws {
        let assignment = AgentTeamProviderRoleAssignment(
            providerReference: LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference,
            roles: [.conductor, .worker],
            selectedModelID: "claude-opus-4",
            selectedModeID: "code"
        )
        let data = try JSONEncoder().encode(assignment)
        let decoded = try JSONDecoder().decode(AgentTeamProviderRoleAssignment.self, from: data)
        #expect(decoded == assignment)
    }

    @Test
    func providerPlanUsesRoleAssignmentsAsSourceOfTruth() {
        let conductor = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        let reviewer = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        let plan = AgentTeamProviderPlan(
            roleAssignments: [
                AgentTeamProviderRoleAssignment(
                    providerReference: conductor,
                    roles: [.conductor, .worker]
                ),
                AgentTeamProviderRoleAssignment(
                    providerReference: reviewer,
                    roles: [.reviewer]
                )
            ],
            dispatchPolicy: .manualSelection
        )

        #expect(plan.preferredConductor == conductor)
        #expect(plan.preferredReviewer == reviewer)
        #expect(plan.eligibleProviders == [conductor, reviewer])
    }

    @Test
    func providerPlanAllowsSameProviderAsConductorAndReviewer() {
        let solo = ExecutionProviderReference.builtIn
        let plan = AgentTeamProviderPlan(
            roleAssignments: [
                AgentTeamProviderRoleAssignment(providerReference: solo, roles: [.conductor, .reviewer])
            ],
            dispatchPolicy: .manualSelection
        )
        #expect(plan.preferredConductor == solo)
        #expect(plan.preferredReviewer == solo)
        #expect(plan.eligibleProviders == [solo])
    }

    @Test
    func providerPlanRoleAssignmentsRoundTripsThroughJSON() throws {
        let plan = AgentTeamProviderPlan(
            roleAssignments: [
                AgentTeamProviderRoleAssignment(
                    providerReference: .builtIn,
                    roles: [.conductor, .reviewer]
                )
            ],
            dispatchPolicy: .autoClaim
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(AgentTeamProviderPlan.self, from: data)
        #expect(decoded == plan)
    }
}