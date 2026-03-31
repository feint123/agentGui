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

// MARK: - AgentTeamTaskBoardDispatchableCardsTests

struct AgentTeamTaskBoardDispatchableCardsTests {

    // 没有 card 时返回空数组
    @Test
    func emptyBoardReturnsNoDispatchableCards() {
        let board = AgentTeamTaskBoardState(cards: [], claims: [])
        #expect(board.dispatchableCards(upTo: 2).isEmpty)
    }

    // 单张无依赖 briefed 卡，完整 budget
    @Test
    func singleBriefedCardWithNoDependenciesIsDispatchable() {
        let card = makeBriefedCard(id: uuid(1))
        let board = AgentTeamTaskBoardState(cards: [card], claims: [])
        #expect(board.dispatchableCards(upTo: 2).count == 1)
    }

    // 有未完成依赖的 briefed 卡不可派发
    @Test
    func briefedCardWithUnresolvedDependencyIsNotDispatchable() {
        let depCardID = uuid(1)
        let depCard = AgentTeamTaskCard(
            id: depCardID, title: "上游", goal: "上游任务",
            status: .working, owner: .builtIn, acceptedClaimID: UUID(),
            dependencyIDs: [], lastUpdatedAt: Date()
        )
        let childCard = makeBriefedCard(id: uuid(2), dependencyIDs: [depCardID])
        let board = AgentTeamTaskBoardState(cards: [depCard, childCard], claims: [])
        #expect(board.dispatchableCards(upTo: 2).isEmpty)
    }

    // 依赖已完成（.done）时可派发
    @Test
    func briefedCardWithResolvedDependencyIsDispatchable() {
        let depCardID = uuid(1)
        let depCard = AgentTeamTaskCard(
            id: depCardID, title: "上游", goal: "上游已完成",
            status: .done, owner: .builtIn, acceptedClaimID: UUID(),
            dependencyIDs: [], lastUpdatedAt: Date()
        )
        let childCard = makeBriefedCard(id: uuid(2), dependencyIDs: [depCardID])
        let board = AgentTeamTaskBoardState(cards: [depCard, childCard], claims: [])
        #expect(board.dispatchableCards(upTo: 2).count == 1)
    }

    // maxActiveProviders 限制 — 已有 1 个 active card，limit=1 → 返回空
    @Test
    func activeCardCountReducesDispatchableLimit() {
        let activeCard = AgentTeamTaskCard(
            id: uuid(1), title: "进行中", goal: "执行中",
            status: .working, owner: .builtIn, acceptedClaimID: UUID(),
            dependencyIDs: [], lastUpdatedAt: Date()
        )
        let waitingCard = makeBriefedCard(id: uuid(2))
        let board = AgentTeamTaskBoardState(cards: [activeCard, waitingCard], claims: [])
        #expect(board.dispatchableCards(upTo: 1).isEmpty)
    }

    // 3 张可派发卡，limit=2 → 只返回前 2 张
    @Test
    func dispatchableCappedByMaxActiveProviders() {
        let cards = [uuid(1), uuid(2), uuid(3)].map { makeBriefedCard(id: $0) }
        let board = AgentTeamTaskBoardState(cards: cards, claims: [])
        #expect(board.dispatchableCards(upTo: 2).count == 2)
    }

    // .claimed 卡也计入 active 数（占用 budget）
    @Test
    func claimedCardCountsAsActiveForBudget() {
        let claimedCard = AgentTeamTaskCard(
            id: uuid(1), title: "已认领", goal: "进入 claimed",
            status: .claimed, owner: .builtIn, acceptedClaimID: UUID(),
            dependencyIDs: [], lastUpdatedAt: Date()
        )
        let briefedCard = makeBriefedCard(id: uuid(2))
        let board = AgentTeamTaskBoardState(cards: [claimedCard, briefedCard], claims: [])
        #expect(board.dispatchableCards(upTo: 1).isEmpty)
    }

    // MARK: - Helpers

    private func uuid(_ n: UInt8) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02x", n))")!
    }

    private func makeBriefedCard(id: UUID, dependencyIDs: [UUID] = []) -> AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: id, title: "任务 \(id.uuidString.prefix(4))", goal: "执行此任务",
            status: .briefed, owner: nil, acceptedClaimID: nil,
            dependencyIDs: dependencyIDs, lastUpdatedAt: Date()
        )
    }
}