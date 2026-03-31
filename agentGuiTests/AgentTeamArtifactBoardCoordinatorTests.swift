import Foundation
import Testing
@testable import agentGui

struct AgentTeamArtifactBoardCoordinatorTests {

    // MARK: - submitArtifact

    @Test
    func submitArtifactAppendsToBoard() throws {
        let cardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var taskBoard = makeTaskBoardWithWorkingCard(cardID: cardID)
        let artifactBoard = AgentTeamArtifactBoardState()
        let coordinator = AgentTeamArtifactBoardCoordinator()

        let artifact = makeArtifact(kind: .patchProposal, cardID: cardID)
        let (updatedArtifactBoard, updatedTaskBoard) = try coordinator.submitArtifact(
            artifact,
            into: artifactBoard,
            linking: &taskBoard
        )

        #expect(updatedArtifactBoard.artifacts.count == 1)
        #expect(updatedArtifactBoard.artifacts.first?.id == artifact.id)
        #expect(updatedTaskBoard.card(id: cardID)?.artifactIDs.contains(artifact.id) == true)
    }

    @Test
    func submitArtifactWithUnknownCardIDThrows() {
        let cardID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let unknownCardID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        var taskBoard = makeTaskBoardWithWorkingCard(cardID: cardID)
        let artifactBoard = AgentTeamArtifactBoardState()
        let coordinator = AgentTeamArtifactBoardCoordinator()

        let artifact = makeArtifact(kind: .validationReport, cardID: unknownCardID)

        #expect(throws: AgentTeamArtifactBoardCoordinator.Error.taskCardNotFound(unknownCardID)) {
            _ = try coordinator.submitArtifact(artifact, into: artifactBoard, linking: &taskBoard)
        }
    }

    @Test
    func submitDuplicateArtifactIDThrows() throws {
        let cardID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        var taskBoard = makeTaskBoardWithWorkingCard(cardID: cardID)
        let coordinator = AgentTeamArtifactBoardCoordinator()
        let artifact = makeArtifact(kind: .brief, cardID: cardID)

        var (board, _) = try coordinator.submitArtifact(artifact, into: AgentTeamArtifactBoardState(), linking: &taskBoard)

        #expect(throws: AgentTeamArtifactBoardCoordinator.Error.duplicateArtifactID(artifact.id)) {
            _ = try coordinator.submitArtifact(artifact, into: board, linking: &taskBoard)
        }
    }

    // MARK: - updateArtifactStatus

    @Test
    func updateArtifactStatusTransitionsCorrectly() throws {
        let cardID = UUID()
        var taskBoard = makeTaskBoardWithWorkingCard(cardID: cardID)
        let coordinator = AgentTeamArtifactBoardCoordinator()
        let artifact = makeArtifact(kind: .reviewReport, cardID: cardID, status: .submitted)
        let (board, _) = try coordinator.submitArtifact(artifact, into: AgentTeamArtifactBoardState(), linking: &taskBoard)

        let updatedBoard = try coordinator.updateArtifactStatus(artifact.id, to: .accepted, in: board)

        #expect(updatedBoard.artifact(id: artifact.id)?.status == .accepted)
    }

    @Test
    func updateStatusForUnknownArtifactIDThrows() {
        let unknownID = UUID()
        let board = AgentTeamArtifactBoardState()
        let coordinator = AgentTeamArtifactBoardCoordinator()

        #expect(throws: AgentTeamArtifactBoardCoordinator.Error.artifactNotFound(unknownID)) {
            _ = try coordinator.updateArtifactStatus(unknownID, to: .rejected, in: board)
        }
    }

    // MARK: - Helpers

    private func makeTaskBoardWithWorkingCard(cardID: UUID) -> AgentTeamTaskBoardState {
        let claimID = UUID()
        let claim = AgentTeamClaim(
            id: claimID,
            providerReference: .builtIn,
            taskCardID: cardID,
            confidence: 1.0,
            rationaleSummary: "auto",
            requiredCapabilities: [],
            expectedArtifacts: [],
            estimatedCostSummary: "low",
            status: .accepted,
            submittedAt: Date(timeIntervalSince1970: 1)
        )
        return AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: cardID,
                    title: "测试卡",
                    goal: "用于 artifact 测试",
                    status: .working,
                    owner: .builtIn,
                    acceptedClaimID: claimID,
                    dependencyIDs: [],
                    artifactIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 1)
                )
            ],
            claims: [claim]
        )
    }

    private func makeArtifact(
        kind: AgentTeamArtifactKind,
        cardID: UUID,
        status: AgentTeamArtifactStatus = .draft
    ) -> AgentTeamArtifact {
        AgentTeamArtifact(
            id: UUID(),
            kind: kind,
            title: "\(kind.rawValue) artifact",
            producer: .builtIn,
            taskCardID: cardID,
            version: 1,
            summary: "测试用摘要",
            payload: .text("测试内容"),
            status: status
        )
    }
}
