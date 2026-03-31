import Foundation
import Testing
@testable import agentGui

struct AgentTeamClaimTests {
    @Test
    func claimBoardRoundTripsThroughJSON() throws {
        let cardID = UUID()
        let claim = AgentTeamClaim(
            id: UUID(),
            providerReference: .builtIn,
            taskCardID: cardID,
            confidence: 0.92,
            rationaleSummary: "适合负责 SwiftUI workbench 改造",
            requiredCapabilities: ["swiftui", "team-workbench"],
            expectedArtifacts: ["implementationPlan"],
            estimatedCostSummary: "medium",
            status: .accepted,
            submittedAt: Date(timeIntervalSince1970: 1)
        )

        let board = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: cardID,
                    title: "认领主任务",
                    goal: "选择 owner",
                    phase: .claiming,
                    owner: .builtIn,
                    claimIDs: [claim.id]
                )
            ],
            claims: [claim]
        )

        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(AgentTeamClaimBoardState.self, from: data)

        #expect(decoded == board)
    }

    @Test
    func executionContextRequiresExactlyOneAcceptedOwnedCard() {
        let provider = ExecutionProviderReference.builtIn
        let firstCardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondCardID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let firstClaimID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let secondClaimID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let board = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: firstCardID,
                    title: "主任务",
                    goal: "执行主修复",
                    phase: .claimed,
                    owner: provider,
                    claimIDs: [firstClaimID]
                ),
                AgentTeamClaimCard(
                    id: secondCardID,
                    title: "次任务",
                    goal: "补充验证",
                    phase: .claimed,
                    owner: provider,
                    claimIDs: [secondClaimID]
                )
            ],
            claims: [
                AgentTeamClaim(
                    id: firstClaimID,
                    providerReference: provider,
                    taskCardID: firstCardID,
                    confidence: 0.9,
                    rationaleSummary: "主任务认领",
                    requiredCapabilities: ["swift"],
                    expectedArtifacts: ["patchProposal"],
                    estimatedCostSummary: "medium",
                    status: .accepted,
                    submittedAt: Date(timeIntervalSince1970: 1)
                ),
                AgentTeamClaim(
                    id: secondClaimID,
                    providerReference: provider,
                    taskCardID: secondCardID,
                    confidence: 0.8,
                    rationaleSummary: "次任务认领",
                    requiredCapabilities: ["tests"],
                    expectedArtifacts: ["validationReport"],
                    estimatedCostSummary: "low",
                    status: .accepted,
                    submittedAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )

        #expect(board.executionContext(for: provider) == nil)
    }

    @Test
    func acceptedClaimIgnoresUnregisteredClaimIDs() {
        let cardID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let registeredClaimID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let orphanClaimID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let board = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: cardID,
                    title: "主任务",
                    goal: "建立 claim gate",
                    phase: .claimed,
                    owner: .builtIn,
                    claimIDs: [registeredClaimID]
                )
            ],
            claims: [
                AgentTeamClaim(
                    id: registeredClaimID,
                    providerReference: .builtIn,
                    taskCardID: cardID,
                    confidence: 0.9,
                    rationaleSummary: "已注册 claim",
                    requiredCapabilities: ["swift"],
                    expectedArtifacts: ["patchProposal"],
                    estimatedCostSummary: "medium",
                    status: .pending,
                    submittedAt: Date(timeIntervalSince1970: 1)
                ),
                AgentTeamClaim(
                    id: orphanClaimID,
                    providerReference: .builtIn,
                    taskCardID: cardID,
                    confidence: 1.0,
                    rationaleSummary: "孤立 claim",
                    requiredCapabilities: ["swift"],
                    expectedArtifacts: ["patchProposal"],
                    estimatedCostSummary: "medium",
                    status: .accepted,
                    submittedAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )

        #expect(board.acceptedClaim(for: cardID) == nil)
        #expect(board.claims(for: cardID).map(\.id) == [registeredClaimID])
    }
}