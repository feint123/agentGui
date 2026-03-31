import Foundation

// MARK: - Block Reason

enum AgentTeamMergeGateBlock: Equatable, Sendable {
    case incompleteCardsExist(count: Int)        // 有卡未进入 reviewing/done/blocked
    case pendingReviewsExist(count: Int)         // 有 reviewing 卡尚无 approved review
    case blockedCardsExist(count: Int)           // 有 blocked 卡
    case unresolvedConflictsExist(count: Int)    // 有 conflictDetected review 未被后续 approved 覆盖

    var localizedDescription: String {
        switch self {
        case let .incompleteCardsExist(n):
            return "\(n) 张任务卡尚未完成"
        case let .pendingReviewsExist(n):
            return "\(n) 张卡等待 review 批准"
        case let .blockedCardsExist(n):
            return "\(n) 张卡处于阻塞状态"
        case let .unresolvedConflictsExist(n):
            return "\(n) 处冲突尚未解决"
        }
    }
}

// MARK: - Gate Status

struct AgentTeamMergeGateStatus: Equatable, Sendable {
    let isReady: Bool
    let blocks: [AgentTeamMergeGateBlock]

    static let ready = AgentTeamMergeGateStatus(isReady: true, blocks: [])
}

// MARK: - Evaluator

struct AgentTeamMergeGateEvaluator {

    func evaluate(
        taskBoard: AgentTeamTaskBoardState,
        artifactBoard: AgentTeamArtifactBoardState
    ) -> AgentTeamMergeGateStatus {
        var blocks: [AgentTeamMergeGateBlock] = []

        // 1. incomplete cards（briefed / claimed / working）
        let incompleteStatuses: Set<AgentTeamTaskStatus> = [.briefed, .claimed, .working]
        let incompleteCount = taskBoard.cards.filter { incompleteStatuses.contains($0.status) }.count
        if incompleteCount > 0 {
            blocks.append(.incompleteCardsExist(count: incompleteCount))
        }

        // 2. reviewing cards without approved review
        let reviewingCards = taskBoard.cards.filter { $0.status == .reviewing }
        let pendingCount = reviewingCards.filter { card in
            !artifactBoard.reviewReports(for: card.id).contains { $0.decision == .approved }
        }.count
        if pendingCount > 0 {
            blocks.append(.pendingReviewsExist(count: pendingCount))
        }

        // 3. blocked cards
        let blockedCount = taskBoard.cards.filter { $0.status == .blocked }.count
        if blockedCount > 0 {
            blocks.append(.blockedCardsExist(count: blockedCount))
        }

        // 4. unresolved conflicts: conflictDetected review exists, but no subsequent approved review for same card
        let unresolvedConflictCount = taskBoard.cards.filter { card in
            let reports = artifactBoard.reviewReports(for: card.id)
            let hasConflict = reports.contains { $0.decision == .conflictDetected }
            let hasResolution = reports.contains { $0.decision == .approved }
            return hasConflict && !hasResolution
        }.count
        if unresolvedConflictCount > 0 {
            blocks.append(.unresolvedConflictsExist(count: unresolvedConflictCount))
        }

        return AgentTeamMergeGateStatus(isReady: blocks.isEmpty, blocks: blocks)
    }
}
