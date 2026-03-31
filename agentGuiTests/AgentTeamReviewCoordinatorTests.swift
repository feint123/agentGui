import Foundation
import Testing
@testable import agentGui

struct AgentTeamReviewCoordinatorTests {

    private func makeReviewingCard(id: UUID = UUID()) -> AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: id, title: "T", goal: "G", status: .reviewing, lastUpdatedAt: Date()
        )
    }

    private func makeReport(decision: AgentTeamReviewDecision, cardID: UUID) -> AgentTeamReviewReport {
        AgentTeamReviewReport(
            id: UUID(), reviewer: .builtIn, reviewedArtifactIDs: [],
            kind: .validation, decision: decision,
            rationale: "test rationale", issues: [], conflictingArtifactPairs: [],
            submittedAt: Date()
        )
    }

    @Test
    func approvedReviewTransitionsCardToDone() throws {
        let cardID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [makeReviewingCard(id: cardID)], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .approved, cardID: cardID)

        let (nextArtifactBoard, nextTaskBoard) = try AgentTeamReviewCoordinator().submitReview(
            report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
        )

        let card = nextTaskBoard.card(id: cardID)
        #expect(card?.status == .done)
        #expect(card?.blockerSummary == nil)
        #expect(nextArtifactBoard.reviewReports(for: cardID).count == 1)
    }

    @Test
    func needsWorkReviewTransitionsCardToWorking() throws {
        let cardID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [makeReviewingCard(id: cardID)], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .needsWork, cardID: cardID)

        let (_, nextTaskBoard) = try AgentTeamReviewCoordinator().submitReview(
            report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
        )

        let card = nextTaskBoard.card(id: cardID)
        #expect(card?.status == .working)
        #expect(card?.blockerSummary == "test rationale")
    }

    @Test
    func rejectedReviewTransitionsCardToBlocked() throws {
        let cardID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [makeReviewingCard(id: cardID)], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .rejected, cardID: cardID)

        let (_, nextTaskBoard) = try AgentTeamReviewCoordinator().submitReview(
            report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
        )

        #expect(nextTaskBoard.card(id: cardID)?.status == .blocked)
    }

    @Test
    func conflictDetectedTransitionsCardToBlocked() throws {
        let cardID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [makeReviewingCard(id: cardID)], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .conflictDetected, cardID: cardID)

        let (_, nextTaskBoard) = try AgentTeamReviewCoordinator().submitReview(
            report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
        )

        #expect(nextTaskBoard.card(id: cardID)?.status == .blocked)
    }

    @Test
    func submitToNonReviewingCardThrows() throws {
        let cardID = UUID()
        let card = AgentTeamTaskCard(
            id: cardID, title: "T", goal: "G", status: .working, lastUpdatedAt: Date()
        )
        var taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .approved, cardID: cardID)

        #expect(throws: AgentTeamReviewCoordinator.Error.self) {
            _ = try AgentTeamReviewCoordinator().submitReview(
                report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
            )
        }
    }

    @Test
    func submitToMissingCardThrows() throws {
        let missingID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .approved, cardID: missingID)

        #expect(throws: AgentTeamReviewCoordinator.Error.self) {
            _ = try AgentTeamReviewCoordinator().submitReview(
                report, forTaskCardID: missingID, into: artifactBoard, linking: &taskBoard
            )
        }
    }
}
