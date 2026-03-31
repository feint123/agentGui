import Foundation
import Testing
@testable import agentGui

struct AgentTeamTaskBoardTests {
    @Test
    func taskBoardRoundTripsThroughJSON() throws {
        let cardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let claimID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let board = AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: cardID,
                    title: "修复主路径",
                    goal: "建立 task board contract",
                    status: .reviewing,
                    owner: .builtIn,
                    acceptedClaimID: claimID,
                    dependencyIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 20)
                )
            ],
            claims: [acceptedClaimFixture(id: claimID, taskCardID: cardID)]
        )

        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(AgentTeamTaskBoardState.self, from: data)

        #expect(decoded == board)
    }

    @Test
    func legacyClaimBoardMigratesIntoTaskBoard() {
        let cardID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let claimID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let legacyBoard = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: cardID,
                    title: "修复主路径",
                    goal: "建立 claim gate",
                    phase: .claimed,
                    owner: .builtIn,
                    claimIDs: [claimID]
                )
            ],
            claims: [acceptedClaimFixture(id: claimID, taskCardID: cardID)]
        )

        let migrated = AgentTeamTaskBoardState.migrating(legacyBoard)

        #expect(migrated.cards.count == 1)
        #expect(migrated.cards.first?.status == .claimed)
        #expect(migrated.cards.first?.acceptedClaimID == claimID)
        #expect(migrated.cards.first?.owner == .builtIn)
    }

    @Test
    func legacyClaimingPhaseMigratesIntoBriefedTaskStatus() {
        let cardID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let legacyBoard = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: cardID,
                    title: "拆分任务",
                    goal: "让迁移规则可预测",
                    phase: .claiming,
                    owner: nil,
                    claimIDs: []
                )
            ],
            claims: []
        )

        let migrated = AgentTeamTaskBoardState.migrating(legacyBoard)

        #expect(migrated.cards.first?.status == .briefed)
        #expect(migrated.cards.first?.acceptedClaimID == nil)
    }

    @Test
    func taskCardDecodesLegacyJSONWithoutArtifactIDs() throws {
        // JSON 不含 artifactIDs 字段（旧版序列化数据），应当降级为空数组
        let legacyJSON = """
        {
            "id": "55555555-5555-5555-5555-555555555556",
            "title": "旧版卡片",
            "goal": "测试向后兼容",
            "status": "briefed",
            "dependencyIDs": [],
            "lastUpdatedAt": 0
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let card = try JSONDecoder().decode(AgentTeamTaskCard.self, from: data)

        #expect(card.artifactIDs == [])
    }

    @Test
    func taskCardRoundTripsArtifactIDs() throws {
        let artifactID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let cardID = UUID(uuidString: "55555555-5555-5555-5555-555555555557")!
        let card = AgentTeamTaskCard(
            id: cardID,
            title: "含工件的卡片",
            goal: "测试 artifactIDs 序列化",
            status: .working,
            owner: .builtIn,
            acceptedClaimID: nil,
            dependencyIDs: [],
            artifactIDs: [artifactID],
            blockerSummary: nil,
            lastUpdatedAt: Date(timeIntervalSince1970: 100)
        )

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(AgentTeamTaskCard.self, from: data)

        #expect(decoded.artifactIDs == [artifactID])
    }
}

private func acceptedClaimFixture(id: UUID, taskCardID: UUID) -> AgentTeamClaim {
    AgentTeamClaim(
        id: id,
        providerReference: .builtIn,
        taskCardID: taskCardID,
        confidence: 0.95,
        rationaleSummary: "适合负责主执行路径",
        requiredCapabilities: ["swift"],
        expectedArtifacts: ["patchProposal"],
        estimatedCostSummary: "medium",
        status: .accepted,
        submittedAt: Date(timeIntervalSince1970: 10)
    )
}