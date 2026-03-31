import Foundation
import Testing
@testable import agentGui

struct AgentTeamTaskBoardCoordinatorTests {
    @Test
    func applyingAcceptedClaimPromotesBriefedCardToClaimed() throws {
        let cardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let claimID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let board = AgentTeamTaskBoardState(
            cards: [
                .fixture(id: cardID, status: .briefed)
            ],
            claims: [
                .acceptedFixture(id: claimID, taskCardID: cardID, providerReference: .builtIn)
            ]
        )

        let updated = try AgentTeamTaskBoardCoordinator().applyingAcceptedClaim(taskCardID: cardID, in: board)

        #expect(updated.cards.first?.status == .claimed)
        #expect(updated.cards.first?.owner == .builtIn)
        #expect(updated.cards.first?.acceptedClaimID == claimID)
    }

    @Test
    func taskCannotStartWorkingUntilDependenciesAreDone() throws {
        let upstreamID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let downstreamID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let board = AgentTeamTaskBoardState(
            cards: [
                .fixture(id: upstreamID, status: .working),
                .fixture(id: downstreamID, status: .claimed, dependencyIDs: [upstreamID], owner: .builtIn, acceptedClaimID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
            ],
            claims: []
        )

        #expect(throws: AgentTeamTaskBoardCoordinator.Error.unresolvedDependencies([upstreamID])) {
            try AgentTeamTaskBoardCoordinator().transitionCard(downstreamID, to: .working, in: board)
        }
    }

    @Test
    func workingCardCanAdvanceToReviewingAndDone() throws {
        let cardID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let board = AgentTeamTaskBoardState(
            cards: [
                .fixture(id: cardID, status: .working, owner: .builtIn, acceptedClaimID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!)
            ],
            claims: []
        )
        let coordinator = AgentTeamTaskBoardCoordinator()

        let reviewingBoard = try coordinator.transitionCard(cardID, to: .reviewing, in: board)
        let doneBoard = try coordinator.transitionCard(cardID, to: .done, in: reviewingBoard)

        #expect(reviewingBoard.cards.first?.status == .reviewing)
        #expect(doneBoard.cards.first?.status == .done)
    }

    @Test
    func blockedTransitionRequiresBlockerSummary() {
        let cardID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let board = AgentTeamTaskBoardState(
            cards: [
                .fixture(id: cardID, status: .working, owner: .builtIn, acceptedClaimID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!)
            ],
            claims: []
        )

        #expect(throws: AgentTeamTaskBoardCoordinator.Error.blockerSummaryRequired) {
            try AgentTeamTaskBoardCoordinator().transitionCard(cardID, to: .blocked, blockerSummary: nil, in: board)
        }
    }

    @Test
    func boardCanRepresentParallelWorkingCards() throws {
        let firstID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let secondID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let coordinator = AgentTeamTaskBoardCoordinator()
        let board = AgentTeamTaskBoardState(
            cards: [
                .fixture(id: firstID, status: .claimed, owner: .builtIn, acceptedClaimID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!),
                .fixture(id: secondID, status: .claimed, owner: LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference, acceptedClaimID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!)
            ],
            claims: []
        )

        let firstWorking = try coordinator.transitionCard(firstID, to: .working, in: board)
        let secondWorking = try coordinator.transitionCard(secondID, to: .working, in: firstWorking)

        #expect(secondWorking.cards.filter { $0.status == .working }.count == 2)
    }
}

private extension AgentTeamTaskCard {
    static func fixture(
        id: UUID,
        status: AgentTeamTaskStatus,
        dependencyIDs: [UUID] = [],
        owner: ExecutionProviderReference? = nil,
        acceptedClaimID: UUID? = nil,
        blockerSummary: String? = nil
    ) -> Self {
        AgentTeamTaskCard(
            id: id,
            title: "任务 \(id.uuidString.prefix(4))",
            goal: "验证 task board 状态流转",
            status: status,
            owner: owner,
            acceptedClaimID: acceptedClaimID,
            dependencyIDs: dependencyIDs,
            blockerSummary: blockerSummary,
            lastUpdatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private extension AgentTeamClaim {
    static func acceptedFixture(id: UUID, taskCardID: UUID, providerReference: ExecutionProviderReference) -> Self {
        AgentTeamClaim(
            id: id,
            providerReference: providerReference,
            taskCardID: taskCardID,
            confidence: 0.9,
            rationaleSummary: "接受的 claim",
            requiredCapabilities: ["swift"],
            expectedArtifacts: ["patchProposal"],
            estimatedCostSummary: "medium",
            status: .accepted,
            submittedAt: Date(timeIntervalSince1970: 2)
        )
    }
}