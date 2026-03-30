import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentTeamMissionBriefTests {
    @Test
    func briefRoundTripsThroughJSON() throws {
        let brief = AgentTeamMissionBrief(
            objective: "为 ACP team 制定修复方案",
            constraints: ["仅修改 Swift 文件", "保持 UI 稳定"],
            acceptanceCriteria: ["存在 focused tests", "Mission Header 可回显 brief"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "来源聊天包含 bug 复现与日志摘要。"
        )

        let data = try JSONEncoder().encode(brief)
        let decoded = try JSONDecoder().decode(AgentTeamMissionBrief.self, from: data)

        #expect(decoded == brief)
    }

    @Test
    func budgetPreservesStableFields() {
        let budget = AgentTeamBudget(
            maxActiveProviders: 3,
            tokenBudgetText: "50k",
            costBudgetText: "high"
        )

        #expect(budget.maxActiveProviders == 3)
        #expect(budget.tokenBudgetText == "50k")
        #expect(budget.costBudgetText == "high")
    }
}