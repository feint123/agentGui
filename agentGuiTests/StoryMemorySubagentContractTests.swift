import Foundation
import Testing
@testable import agentGui

struct StoryMemorySubagentContractTests {

    @Test func delegationResponseSeparatesFactsInferenceAndRisks() async throws {
        let response = StoryMemoryDelegationResponse(
            status: .ready,
            taskType: .retrieveContext,
            facts: [
                StoryMemoryFactSlice(title: "角色状态", detail: "林澈仍在北塔", source: "character")
            ],
            inferences: ["顾沉可能在隐瞒旧档案来源"],
            risks: [
                StoryMemoryRiskItem(level: .warning, message: "顾沉动机仍未确认", needsUserConfirmation: false)
            ],
            writeDecision: nil,
            fallbackNote: nil
        )

        #expect(response.facts.count == 1)
        #expect(response.inferences == ["顾沉可能在隐瞒旧档案来源"])
        #expect(response.risks.map(\.message) == ["顾沉动机仍未确认"])
    }
}