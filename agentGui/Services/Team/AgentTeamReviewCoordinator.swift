import Foundation

struct AgentTeamReviewCoordinator {

    // MARK: - Error

    enum Error: LocalizedError, Equatable {
        case taskCardNotFound(UUID)
        case unexpectedCardStatus(AgentTeamTaskStatus)

        var errorDescription: String? {
            switch self {
            case let .taskCardNotFound(id):
                return "未找到 task card：\(id.uuidString.lowercased())"
            case let .unexpectedCardStatus(status):
                return "task card 当前状态为 \(status.rawValue)，必须处于 reviewing 才能提交 review。"
            }
        }
    }

    private let artifactCoordinator = AgentTeamArtifactBoardCoordinator()

    // MARK: - Submit Review

    /// 提交 review report artifact，并根据 decision 驱动 task card 状态流转。
    /// 返回 (更新后的 artifactBoard, 更新后的 taskBoard)。
    func submitReview(
        _ report: AgentTeamReviewReport,
        forTaskCardID cardID: UUID,
        into artifactBoard: AgentTeamArtifactBoardState,
        linking taskBoard: inout AgentTeamTaskBoardState
    ) throws -> (AgentTeamArtifactBoardState, AgentTeamTaskBoardState) {
        // 1. 验证 card 存在且状态为 .reviewing
        guard let card = taskBoard.card(id: cardID) else {
            throw Error.taskCardNotFound(cardID)
        }
        guard card.status == .reviewing else {
            throw Error.unexpectedCardStatus(card.status)
        }

        // 2. 构造 reviewReport artifact
        let artifact = AgentTeamArtifact(
            id: report.id,
            kind: .reviewReport,
            title: "Review（\(report.kind.rawValue)）",
            producer: report.reviewer,
            taskCardID: cardID,
            version: 1,
            summary: report.rationale,
            payload: .reviewReport(report),
            status: .submitted
        )

        // 3. 提交 artifact
        var (nextArtifactBoard, nextTaskBoard) = try artifactCoordinator.submitArtifact(
            artifact, into: artifactBoard, linking: &taskBoard
        )

        // 4. 根据 decision 流转 task card 状态
        guard let idx = nextTaskBoard.cards.firstIndex(where: { $0.id == cardID }) else {
            throw Error.taskCardNotFound(cardID)
        }
        switch report.decision {
        case .approved:
            nextTaskBoard.cards[idx].status = .done
            nextTaskBoard.cards[idx].blockerSummary = nil
        case .needsWork:
            nextTaskBoard.cards[idx].status = .working
            nextTaskBoard.cards[idx].blockerSummary = report.rationale
        case .rejected:
            nextTaskBoard.cards[idx].status = .blocked
            nextTaskBoard.cards[idx].blockerSummary = report.rationale
        case .conflictDetected:
            let conflictSummary = report.conflictingArtifactPairs.isEmpty
                ? report.rationale
                : "冲突检测：\(report.conflictingArtifactPairs.count) 处冲突。\(report.rationale)"
            nextTaskBoard.cards[idx].status = .blocked
            nextTaskBoard.cards[idx].blockerSummary = conflictSummary
        }
        nextTaskBoard.cards[idx].lastUpdatedAt = report.submittedAt

        taskBoard = nextTaskBoard
        return (nextArtifactBoard, nextTaskBoard)
    }
}
