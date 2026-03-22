import Foundation

struct ProposalDockChangeSummary: Equatable {
    let additions: Int
    let deletions: Int
}

struct ProposalDockItemPresentation: Equatable, Identifiable {
    let id: UUID
    let proposalID: UUID
    let filePath: String
    let title: String
    let subtitle: String
    let statusText: String
    let changeSummary: ProposalDockChangeSummary
}

struct ProposalDockPresentation: Equatable {
    let title: String
    let summaryText: String
    let actionableProposalIDs: [UUID]
    let pendingFileCount: Int
    let totalAdditions: Int
    let totalDeletions: Int
    let items: [ProposalDockItemPresentation]

    var isVisible: Bool {
        !items.isEmpty
    }

    static let hidden = ProposalDockPresentation(
        title: "",
        summaryText: "",
        actionableProposalIDs: [],
        pendingFileCount: 0,
        totalAdditions: 0,
        totalDeletions: 0,
        items: []
    )
}

struct ProposalDockPresenter {
    func build(
        from projection: SessionChangeReviewProjection,
        snapshotsByProposalID: [UUID: ChangeProposalReviewSnapshot] = [:]
    ) -> ProposalDockPresentation {
        guard projection.pendingProposalCount > 0,
              !projection.proposalIDs.isEmpty else {
            return .hidden
        }

        let items = projection.proposalIDs.flatMap { proposalID in
            makeItems(
                proposalID: proposalID,
                snapshot: snapshotsByProposalID[proposalID]
            )
        }

        let actionableProposalIDs = projection.proposalIDs.filter { proposalID in
            guard let snapshot = snapshotsByProposalID[proposalID] else {
                return false
            }

            return snapshot.proposal.state.isPendingReview
                && snapshot.fileChanges.contains(where: { $0.state.isPendingReview })
        }

        let actionableFiles = actionableProposalIDs.flatMap { proposalID in
            snapshotsByProposalID[proposalID]?.fileChanges.filter(\.state.isPendingReview) ?? []
        }

        return ProposalDockPresentation(
            title: "待审查变更",
            summaryText: "\(projection.pendingProposalCount) 个提案，\(projection.pendingFileCount) 个文件待审查",
            actionableProposalIDs: actionableProposalIDs,
            pendingFileCount: actionableFiles.count,
            totalAdditions: actionableFiles.reduce(0) { $0 + $1.lineAdditions },
            totalDeletions: actionableFiles.reduce(0) { $0 + $1.lineDeletions },
            items: items
        )
    }

    private func makeItems(
        proposalID: UUID,
        snapshot: ChangeProposalReviewSnapshot?
    ) -> [ProposalDockItemPresentation] {
        guard let snapshot else {
            return [
                ProposalDockItemPresentation(
                    id: proposalID,
                    proposalID: proposalID,
                    filePath: "",
                    title: "变更提案",
                    subtitle: "等待载入提案详情",
                    statusText: "待处理",
                    changeSummary: ProposalDockChangeSummary(additions: 0, deletions: 0)
                )
            ]
        }

        guard snapshot.proposal.state.isPendingReview else {
            return []
        }

        let pendingFiles = snapshot.fileChanges.filter { $0.state.isPendingReview }
        let rowFiles = pendingFiles.isEmpty ? snapshot.fileChanges : pendingFiles

        return rowFiles.map { file in
            ProposalDockItemPresentation(
                id: file.id,
                proposalID: proposalID,
                filePath: file.relativePath,
                title: URL(fileURLWithPath: file.relativePath).lastPathComponent,
                subtitle: file.relativePath,
                statusText: statusText(for: snapshot.proposal.state),
                changeSummary: ProposalDockChangeSummary(
                    additions: file.lineAdditions,
                    deletions: file.lineDeletions
                )
            )
        }
    }

    private func statusText(for state: ChangeProposalState) -> String {
        switch state {
        case .collecting, .readyForReview:
            return "待处理"
        case .partiallyApproved:
            return "部分处理"
        case .applying:
            return "应用中"
        case .conflicted:
            return "有冲突"
        case .applied:
            return "已应用"
        case .discarded:
            return "已丢弃"
        case .failed:
            return "失败"
        }
    }
}