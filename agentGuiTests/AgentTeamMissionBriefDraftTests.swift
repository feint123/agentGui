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
        draft.objective = "为 ACP team 生成修复计划"
        draft.constraintsText = " 仅修改 Swift 文件 \n\n 保持 focused tests \n"
        draft.acceptanceCriteriaText = " Mission Header 回显 brief \n\n team session 持久化 brief  "
        draft.maxActiveProviders = 2
        draft.tokenBudgetText = "20k"
        draft.costBudgetText = "medium"
        draft.initialContextSummary = "当前聊天包含失败测试与日志。"

        let brief = draft.buildBrief()

        #expect(brief.objective == "为 ACP team 生成修复计划")
        #expect(brief.constraints == ["仅修改 Swift 文件", "保持 focused tests"])
        #expect(brief.acceptanceCriteria == ["Mission Header 回显 brief", "team session 持久化 brief"])
        #expect(brief.budget == AgentTeamBudget(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"))
    }
}