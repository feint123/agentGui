import Foundation

/// 管理 AgentTeamArtifactBoardState 的状态变更：
/// - 提交新 artifact，同时把 artifact ID 连接到对应的 task card
/// - 更新已有 artifact 的状态
struct AgentTeamArtifactBoardCoordinator {

    // MARK: - Error

    enum Error: LocalizedError, Equatable {
        case taskCardNotFound(UUID)
        case duplicateArtifactID(UUID)
        case artifactNotFound(UUID)

        var errorDescription: String? {
            switch self {
            case let .taskCardNotFound(cardID):
                return "未找到 task card：\(cardID.uuidString.lowercased())，无法提交 artifact。"
            case let .duplicateArtifactID(artifactID):
                return "artifact \(artifactID.uuidString.lowercased()) 已存在，请勿重复提交。"
            case let .artifactNotFound(artifactID):
                return "未找到 artifact：\(artifactID.uuidString.lowercased())。"
            }
        }
    }

    // MARK: - Submit

    /// 提交 artifact 到 artifact board，并将 artifact.id 追加到对应 task card 的 artifactIDs 中。
    /// 返回 (更新后的 artifactBoard, 更新后的 taskBoard)。
    func submitArtifact(
        _ artifact: AgentTeamArtifact,
        into artifactBoard: AgentTeamArtifactBoardState,
        linking taskBoard: inout AgentTeamTaskBoardState
    ) throws -> (AgentTeamArtifactBoardState, AgentTeamTaskBoardState) {
        guard taskBoard.card(id: artifact.taskCardID) != nil else {
            throw Error.taskCardNotFound(artifact.taskCardID)
        }
        guard artifactBoard.artifact(id: artifact.id) == nil else {
            throw Error.duplicateArtifactID(artifact.id)
        }

        // Append to artifact board
        var nextArtifactBoard = artifactBoard
        nextArtifactBoard.artifacts.append(artifact)

        // Link artifact ID to task card
        var nextTaskBoard = taskBoard
        if let idx = nextTaskBoard.cards.firstIndex(where: { $0.id == artifact.taskCardID }) {
            nextTaskBoard.cards[idx].artifactIDs.append(artifact.id)
        }
        taskBoard = nextTaskBoard

        return (nextArtifactBoard, nextTaskBoard)
    }

    // MARK: - Update Status

    /// 更新指定 artifact 的 status。
    func updateArtifactStatus(
        _ artifactID: UUID,
        to status: AgentTeamArtifactStatus,
        in board: AgentTeamArtifactBoardState
    ) throws -> AgentTeamArtifactBoardState {
        guard let idx = board.artifacts.firstIndex(where: { $0.id == artifactID }) else {
            throw Error.artifactNotFound(artifactID)
        }

        var next = board
        next.artifacts[idx].status = status
        return next
    }
}
