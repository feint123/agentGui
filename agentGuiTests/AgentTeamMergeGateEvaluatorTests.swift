import Foundation
import Testing
@testable import agentGui

struct AgentTeamMergeGateEvaluatorTests {

    private func makeCard(
        id: UUID = UUID(),
        status: AgentTeamTaskStatus,
        artifactIDs: [UUID] = []
    ) -> AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: id, title: "T", goal: "G", status: status,
            artifactIDs: artifactIDs, lastUpdatedAt: Date()
        )
    }

    private func makeReviewArtifact(
        taskCardID: UUID,
        decision: AgentTeamReviewDecision
    ) -> AgentTeamArtifact {
        let report = AgentTeamReviewReport(
            id: UUID(), reviewer: .builtIn, reviewedArtifactIDs: [],
            kind: .validation, decision: decision,
            rationale: "test", issues: [], conflictingArtifactPairs: [],
            submittedAt: Date()
        )
        return AgentTeamArtifact(
            id: UUID(), kind: .reviewReport, title: "Review",
            producer: .builtIn, taskCardID: taskCardID, version: 1,
            summary: "review", payload: .reviewReport(report), status: .submitted
        )
    }

    @Test
    func readyWhenAllCardsDoneAndReviewed() {
        let cardID = UUID()
        let card = makeCard(id: cardID, status: .done)
        let reviewArtifact = makeReviewArtifact(taskCardID: cardID, decision: .approved)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [reviewArtifact])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == true)
        #expect(status.blocks.isEmpty)
    }

    @Test
    func blockedWhenIncompleteCardExists() {
        let card = makeCard(status: .working)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == false)
        #expect(status.blocks.contains { block in
            if case .incompleteCardsExist = block { return true }
            return false
        })
    }

    @Test
    func blockedWhenReviewingCardHasNoApprovedReview() {
        let cardID = UUID()
        let card = makeCard(id: cardID, status: .reviewing)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == false)
        #expect(status.blocks.contains { block in
            if case .pendingReviewsExist = block { return true }
            return false
        })
    }

    @Test
    func blockedWhenBlockedCardExists() {
        let card = makeCard(status: .blocked)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == false)
        #expect(status.blocks.contains { block in
            if case .blockedCardsExist = block { return true }
            return false
        })
    }

    @Test
    func blockedWhenConflictDetectedWithNoSubsequentApproval() {
        let cardID = UUID()
        let card = makeCard(id: cardID, status: .blocked)
        let conflictReview = makeReviewArtifact(taskCardID: cardID, decision: .conflictDetected)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [conflictReview])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == false)
        #expect(status.blocks.contains { block in
            if case .unresolvedConflictsExist = block { return true }
            return false
        })
    }

    @Test
    func resolvedConflictNotCountedAsBlock() {
        let cardID = UUID()
        let card = makeCard(id: cardID, status: .done)
        let conflictReview = makeReviewArtifact(taskCardID: cardID, decision: .conflictDetected)
        let approvalReview = makeReviewArtifact(taskCardID: cardID, decision: .approved)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [conflictReview, approvalReview])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        // conflict resolved by subsequent approval → no unresolvedConflictsExist block
        #expect(!status.blocks.contains { block in
            if case .unresolvedConflictsExist = block { return true }
            return false
        })
    }

    @Test
    func emptyBoardIsReady() {
        let taskBoard = AgentTeamTaskBoardState(cards: [], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == true)
    }
}
