import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentTeamMissionBriefDraftTests {
    @Test
    func prefilledDraftCarriesSourceSessionTitleAndContextSummary() {
        let source = Session.fixture(title: "修复 ACP", kind: .local)
        source.messages.append(Message.userFixture(text: "当前聊天包含失败测试与日志", session: source))

        let draft = AgentTeamMissionBriefDraft.prefilled(from: source)

        #expect(draft.sourceSessionTitle == "修复 ACP")
        #expect(draft.initialContextSummary.contains("修复 ACP"))
        #expect(draft.initialContextSummary.contains("失败测试与日志"))
    }

    @Test
    func buildBriefNormalizesMultilineFields() {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.rawInput = "修复 ACP 团队协作中的并发问题"
        draft.objective = "为 ACP team 生成修复计划"
        draft.constraintsText = " 仅修改 Swift 文件 \n\n 保持 focused tests \n"
        draft.acceptanceCriteriaText = " Mission Header 回显 brief \n\n team session 持久化 brief  "
        draft.maxActiveProviders = 2
        let conductor = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        draft.roleAssignments = [
            AgentTeamProviderRoleAssignment(providerReference: conductor, roles: [.conductor, .worker])
        ]

        let brief = draft.buildBrief()

        #expect(brief.objective == "为 ACP team 生成修复计划")
        #expect(brief.constraints == ["仅修改 Swift 文件", "保持 focused tests"])
        #expect(brief.acceptanceCriteria == ["Mission Header 回显 brief", "team session 持久化 brief"])
        #expect(brief.dispatchBudget == AgentTeamDispatchBudget(maxActiveProviders: 2))
    }

    @Test
    func buildBriefFallsBackToRawInputWhenObjectiveEmpty() {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.rawInput = "快速修复并发问题"
        draft.objective = ""
        draft.roleAssignments = [
            AgentTeamProviderRoleAssignment(providerReference: .builtIn, roles: [.conductor, .worker])
        ]

        let brief = draft.buildBrief()
        #expect(brief.objective == "快速修复并发问题")
    }

    @Test
    func extractionStateDefaultsToIdle() {
        let draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        #expect(draft.extractionState == .idle)
    }

    @Test
    func draftPrefilledFromSourceSeesSeededProviderAsConductor() {
        let source = NewSessionMenuAction.SourceContext(
            sessionID: "chat-1",
            title: "修复 ACP",
            defaultExecutionProviderReference: LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        )
        let draft = AgentTeamMissionBriefDraft.prefilled(fromSourceContext: source)
        let conductorAssignment = draft.roleAssignments.first(where: { $0.isConductor })
        #expect(conductorAssignment?.providerReference == LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference)
        #expect(draft.dispatchPolicy == .sourceSessionSeeded)
    }

    @Test
    func draftReconcileProviderOptionsDropsUnavailableAssignments() {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        let staleRef = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        draft.roleAssignments = [
            AgentTeamProviderRoleAssignment(providerReference: staleRef, roles: [.conductor])
        ]
        let options = [ExecutionOptionItem(id: ExecutionProviderReference.builtIn.persistedValue, title: "Built-in", isEnabled: true)]

        draft.reconcileProviderOptions(options)

        #expect(draft.roleAssignments.allSatisfy { options.map(\.id).contains($0.providerReference.persistedValue) })
        #expect(draft.dispatchPolicy == .manualSelection)
    }

    @Test
    func draftRoleAssignmentsAllowSameProviderAsConductorAndReviewer() {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        let provider = ExecutionProviderReference.builtIn
        draft.setRole(.conductor, for: provider, enabled: true)
        draft.setRole(.reviewer, for: provider, enabled: true)

        let assignment = draft.roleAssignments.first(where: { $0.providerReference == provider })
        #expect(assignment?.isConductor == true)
        #expect(assignment?.isReviewer == true)
    }

    @Test
    func draftBuildBriefDerivedFromRoleAssignments() {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        let conductor = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        draft.roleAssignments = [
            AgentTeamProviderRoleAssignment(providerReference: conductor, roles: [.conductor, .worker])
        ]
        draft.objective = "测试任务"

        let brief = draft.buildBrief()
        #expect(brief.providerPlan.preferredConductor == conductor)
        #expect(brief.providerPlan.eligibleProviders == [conductor])
    }

    @Test
    func togglingProviderParticipationRemovesFromAssignments() {
        let conductor = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        let worker = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.roleAssignments = [
            AgentTeamProviderRoleAssignment(providerReference: conductor, roles: [.conductor, .worker]),
            AgentTeamProviderRoleAssignment(providerReference: worker, roles: [.worker])
        ]

        draft.toggleProviderParticipation(worker)

        #expect(draft.roleAssignments.count == 1)
        #expect(draft.roleAssignments.first?.providerReference == conductor)

        draft.toggleProviderParticipation(conductor)

        #expect(draft.roleAssignments.isEmpty == false || draft.roleAssignments.isEmpty)
    }
}