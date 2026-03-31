import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentTeamClaimCoordinatorTests {
    @Test
    func coordinatorAcceptsHighestConfidenceClaimForCard() throws {
        let preferredProvider = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        let competingProvider = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        let coordinator = AgentTeamClaimCoordinator()
        let brief = AgentTeamMissionBrief(
            objective: "为 ACP team 汇总修复方案",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。"
        )
        var board = coordinator.bootstrapBoard(from: brief, preferredProvider: preferredProvider)
        let cardID = try #require(board.cards.first?.id)

        board = coordinator.submitClaim(
            AgentTeamClaim(
                id: UUID(),
                providerReference: preferredProvider,
                taskCardID: cardID,
                confidence: 0.91,
                rationaleSummary: "适合负责主执行路径",
                requiredCapabilities: ["swift"],
                expectedArtifacts: ["patchProposal"],
                estimatedCostSummary: "medium",
                status: .pending,
                submittedAt: Date(timeIntervalSince1970: 1)
            ),
            into: board
        )
        board = coordinator.submitClaim(
            AgentTeamClaim(
                id: UUID(),
                providerReference: competingProvider,
                taskCardID: cardID,
                confidence: 0.72,
                rationaleSummary: "可以辅助跟进 UI 投影",
                requiredCapabilities: ["swiftui"],
                expectedArtifacts: ["implementationPlan"],
                estimatedCostSummary: "low",
                status: .pending,
                submittedAt: Date(timeIntervalSince1970: 2)
            ),
            into: board
        )

        let resolved = coordinator.acceptBestClaim(for: cardID, in: board, preferredProvider: preferredProvider)
        let card = try #require(resolved.card(id: cardID))

        #expect(card.owner == preferredProvider)
        #expect(card.phase == .claimed)
        #expect(resolved.acceptedClaim(for: cardID)?.providerReference == preferredProvider)
    }

    @Test
    func submitClaimReplacesExistingClaimFromSameProviderForSameCard() throws {
        let provider = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        let coordinator = AgentTeamClaimCoordinator()
        let brief = AgentTeamMissionBrief(
            objective: "为 ACP team 汇总修复方案",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。"
        )
        var board = coordinator.bootstrapBoard(from: brief, preferredProvider: provider)
        let cardID = try #require(board.cards.first?.id)

        board = coordinator.submitClaim(
            AgentTeamClaim(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                providerReference: provider,
                taskCardID: cardID,
                confidence: 0.61,
                rationaleSummary: "首个 claim",
                requiredCapabilities: ["swift"],
                expectedArtifacts: ["patchProposal"],
                estimatedCostSummary: "low",
                status: .pending,
                submittedAt: Date(timeIntervalSince1970: 1)
            ),
            into: board
        )
        board = coordinator.submitClaim(
            AgentTeamClaim(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                providerReference: provider,
                taskCardID: cardID,
                confidence: 0.94,
                rationaleSummary: "更新后的 claim",
                requiredCapabilities: ["swift", "tests"],
                expectedArtifacts: ["validationReport"],
                estimatedCostSummary: "medium",
                status: .pending,
                submittedAt: Date(timeIntervalSince1970: 2)
            ),
            into: board
        )

        #expect(board.claims.count == 1)
        #expect(board.claims.first?.id == UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
    }

    @Test
    func acceptBestClaimRejectsPreviouslyAcceptedCompetingClaims() throws {
        let preferredProvider = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        let competingProvider = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        let coordinator = AgentTeamClaimCoordinator()
        let cardID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let originalAcceptedID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let replacementAcceptedID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let board = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: cardID,
                    title: "认领主任务",
                    goal: "选择唯一 owner",
                    phase: .claiming,
                    owner: nil,
                    claimIDs: [originalAcceptedID, replacementAcceptedID]
                )
            ],
            claims: [
                AgentTeamClaim(
                    id: originalAcceptedID,
                    providerReference: competingProvider,
                    taskCardID: cardID,
                    confidence: 0.51,
                    rationaleSummary: "旧 accepted claim",
                    requiredCapabilities: ["swiftui"],
                    expectedArtifacts: ["implementationPlan"],
                    estimatedCostSummary: "low",
                    status: .accepted,
                    submittedAt: Date(timeIntervalSince1970: 1)
                ),
                AgentTeamClaim(
                    id: replacementAcceptedID,
                    providerReference: preferredProvider,
                    taskCardID: cardID,
                    confidence: 0.91,
                    rationaleSummary: "新的最佳 claim",
                    requiredCapabilities: ["swift"],
                    expectedArtifacts: ["patchProposal"],
                    estimatedCostSummary: "medium",
                    status: .pending,
                    submittedAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )

        let resolved = coordinator.acceptBestClaim(for: cardID, in: board, preferredProvider: preferredProvider)

        #expect(resolved.acceptedClaim(for: cardID)?.id == replacementAcceptedID)
        #expect(resolved.claim(id: originalAcceptedID)?.status == .rejected)
        #expect(resolved.claim(id: replacementAcceptedID)?.status == .accepted)
    }

    @Test
    func acceptBestClaimCanPromoteTaskBoardCardToClaimed() throws {
        let preferredProvider = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        let coordinator = AgentTeamClaimCoordinator()
        let taskBoardCoordinator = AgentTeamTaskBoardCoordinator()
        let brief = AgentTeamMissionBrief(
            objective: "为 ACP team 汇总修复方案",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。"
        )
        var claimBoard = coordinator.bootstrapBoard(from: brief, preferredProvider: preferredProvider)
        let cardID = try #require(claimBoard.cards.first?.id)
        let claimID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let taskBoard = AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: cardID,
                    title: "主任务",
                    goal: "让 accepted claim 推进 task status",
                    status: .briefed,
                    owner: nil,
                    acceptedClaimID: nil,
                    dependencyIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 1)
                )
            ],
            claims: []
        )

        claimBoard = coordinator.submitClaim(
            AgentTeamClaim(
                id: claimID,
                providerReference: preferredProvider,
                taskCardID: cardID,
                confidence: 0.91,
                rationaleSummary: "接受 claim 后应该推进状态",
                requiredCapabilities: ["swift"],
                expectedArtifacts: ["patchProposal"],
                estimatedCostSummary: "medium",
                status: .pending,
                submittedAt: Date(timeIntervalSince1970: 3)
            ),
            into: claimBoard
        )

        let resolved = try coordinator.acceptBestClaim(
            for: cardID,
            in: claimBoard,
            preferredProvider: preferredProvider,
            updating: taskBoard,
            taskBoardCoordinator: taskBoardCoordinator
        )

        #expect(resolved.claimBoard.acceptedClaim(for: cardID)?.id == claimID)
        #expect(resolved.taskBoard.cards.first?.status == .claimed)
        #expect(resolved.taskBoard.cards.first?.owner == preferredProvider)
        #expect(resolved.taskBoard.cards.first?.acceptedClaimID == claimID)
    }
}