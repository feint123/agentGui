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
        draft.eligibleProviderIDs = [
            ExecutionProviderReference.builtIn.persistedValue,
            LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference.persistedValue
        ]
        draft.preferredConductorID = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference.persistedValue

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
        draft.eligibleProviderIDs = [ExecutionProviderReference.builtIn.persistedValue]
        draft.preferredConductorID = ExecutionProviderReference.builtIn.persistedValue

        let brief = draft.buildBrief()
        #expect(brief.objective == "快速修复并发问题")
    }

    @Test
    func extractionStateDefaultsToIdle() {
        let draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        #expect(draft.extractionState == .idle)
    }

    @Test
    func sourceContextPrefillsSeededProviderParticipationPlan() {
        let source = NewSessionMenuAction.SourceContext(
            sessionID: "chat-1",
            title: "修复 ACP",
            defaultExecutionProviderReference: LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        )

        let draft = AgentTeamMissionBriefDraft.prefilled(fromSourceContext: source)

        #expect(draft.eligibleProviderIDs == [LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference.persistedValue])
        #expect(draft.preferredConductorID == LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference.persistedValue)
        #expect(draft.dispatchPolicy == .sourceSessionSeeded)
    }

    @Test
    func reconcileProviderOptionsDropsUnavailableSelectionsWithoutImplicitStandaloneFallback() {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.eligibleProviderIDs = [UUID().uuidString]
        draft.preferredConductorID = UUID().uuidString

        draft.reconcileProviderOptions([
            ExecutionOptionItem(id: ExecutionProviderReference.builtIn.persistedValue, title: "Built-In Agent")
        ])

        #expect(draft.eligibleProviderIDs.isEmpty)
        #expect(draft.preferredConductorID.isEmpty)
        #expect(draft.dispatchPolicy == .manualSelection)
    }

    @Test
    func togglingProviderRemovesReviewerAndConductorWhenSelectionBecomesInvalid() {
        let conductor = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference.persistedValue
        let reviewer = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference.persistedValue
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.eligibleProviderIDs = [conductor, reviewer]
        draft.preferredConductorID = conductor
        draft.preferredReviewerID = reviewer

        draft.toggleEligibleProvider(reviewer)

        #expect(draft.eligibleProviderIDs == [conductor])
        #expect(draft.preferredReviewerID.isEmpty)

        draft.toggleEligibleProvider(conductor)

        #expect(draft.eligibleProviderIDs.isEmpty)
        #expect(draft.preferredConductorID.isEmpty)
    }
}