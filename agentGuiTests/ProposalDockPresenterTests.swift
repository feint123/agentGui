import Foundation
import Testing
@testable import agentGui

@MainActor
struct ProposalDockPresenterTests {

    @Test func buildReturnsHiddenPresentationWhenNoPendingProposalExists() {
        let projection = SessionChangeReviewProjection.empty(sessionID: "session-1")

        let presentation = ProposalDockPresenter().build(from: projection)

        #expect(!presentation.isVisible)
        #expect(presentation.items.isEmpty)
    }

    @Test func buildReturnsVisibleItemsForPendingProposalProjection() {
        let proposalID = UUID()
        let projection = SessionChangeReviewProjection(
            sessionID: "session-1",
            pendingProposalCount: 1,
            pendingFileCount: 3,
            proposalIDs: [proposalID]
        )

        let presentation = ProposalDockPresenter().build(
            from: projection,
            snapshotsByProposalID: [
                proposalID: makeSnapshot(
                    proposalID: proposalID,
                    summary: "重构聊天布局",
                    state: .readyForReview,
                    fileChanges: [
                        makeFileChange(proposalID: proposalID, path: "ChatView.swift", state: .proposed),
                        makeFileChange(proposalID: proposalID, path: "WorkbenchShellView.swift", state: .accepted),
                        makeFileChange(proposalID: proposalID, path: "README.md", state: .rejected)
                    ]
                )
            ]
        )

        #expect(presentation.isVisible)
        #expect(presentation.summaryText == "1 个提案，3 个文件待审查")
        #expect(presentation.actionableProposalIDs == [proposalID])
        #expect(presentation.pendingFileCount == 2)
        #expect(presentation.totalAdditions == 2)
        #expect(presentation.totalDeletions == 2)
        #expect(presentation.items.count == 2)
        #expect(presentation.items[0].title == "ChatView.swift")
        #expect(presentation.items[0].subtitle == "ChatView.swift")
        #expect(presentation.items[0].filePath == "ChatView.swift")
        #expect(presentation.items[0].statusText == "待处理")
        #expect(presentation.items[0].changeSummary.additions == 1)
        #expect(presentation.items[0].changeSummary.deletions == 1)
    }

    @Test func buildKeepsProposalAndFileOrderDeterministic() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let projection = SessionChangeReviewProjection(
            sessionID: "session-1",
            pendingProposalCount: 2,
            pendingFileCount: 3,
            proposalIDs: [first, second]
        )

        let presentation = ProposalDockPresenter().build(
            from: projection,
            snapshotsByProposalID: [
                first: makeSnapshot(
                    proposalID: first,
                    summary: "A",
                    state: .readyForReview,
                    fileChanges: [
                        makeFileChange(proposalID: first, path: "A.swift"),
                        makeFileChange(proposalID: first, path: "B.swift")
                    ]
                ),
                second: makeSnapshot(proposalID: second, summary: "B", state: .partiallyApproved, fileChanges: [makeFileChange(proposalID: second, path: "B.swift")])
            ]
        )

        #expect(presentation.items.map(\.filePath) == ["A.swift", "B.swift", "B.swift"])
        #expect(presentation.items.map(\.statusText) == ["待处理", "待处理", "部分处理"])
        #expect(presentation.actionableProposalIDs == [first, second])
    }

    @Test func buildFallsBackToFirstPendingFileAsSubtitle() {
        let proposalID = UUID()
        let projection = SessionChangeReviewProjection(
            sessionID: "session-1",
            pendingProposalCount: 1,
            pendingFileCount: 1,
            proposalIDs: [proposalID]
        )

        let presentation = ProposalDockPresenter().build(
            from: projection,
            snapshotsByProposalID: [
                proposalID: makeSnapshot(
                    proposalID: proposalID,
                    summary: nil,
                    state: .readyForReview,
                    fileChanges: [
                        makeFileChange(proposalID: proposalID, path: "Sources/Feature/NewPanel.swift", additions: 5, deletions: 1),
                        makeFileChange(proposalID: proposalID, path: "README.md", state: .accepted, additions: 1, deletions: 0)
                    ]
                )
            ]
        )

        #expect(presentation.items[0].title == "NewPanel.swift")
        #expect(presentation.items[0].subtitle == "Sources/Feature/NewPanel.swift")
        #expect(presentation.items[0].filePath == "Sources/Feature/NewPanel.swift")
        #expect(presentation.items[0].changeSummary.additions == 5)
        #expect(presentation.items[0].changeSummary.deletions == 1)
    }

    @Test func buildOnlyIncludesPendingReviewProposalsInBulkActions() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let projection = SessionChangeReviewProjection(
            sessionID: "session-1",
            pendingProposalCount: 2,
            pendingFileCount: 2,
            proposalIDs: [first, second]
        )

        let presentation = ProposalDockPresenter().build(
            from: projection,
            snapshotsByProposalID: [
                first: makeSnapshot(
                    proposalID: first,
                    summary: "First",
                    state: .readyForReview,
                    fileChanges: [makeFileChange(proposalID: first, path: "Sources/One.swift", state: .proposed)]
                ),
                second: makeSnapshot(
                    proposalID: second,
                    summary: "Second",
                    state: .applied,
                    fileChanges: [makeFileChange(proposalID: second, path: "Sources/Two.swift", state: .applied)]
                )
            ]
        )

        #expect(presentation.actionableProposalIDs == [first])
        #expect(presentation.pendingFileCount == 1)
        #expect(presentation.totalAdditions == 1)
        #expect(presentation.totalDeletions == 1)
    }

    @Test func buildSummaryTotalsIncludeAllStillPendingFiles() {
        let proposalID = UUID()
        let projection = SessionChangeReviewProjection(
            sessionID: "session-1",
            pendingProposalCount: 1,
            pendingFileCount: 4,
            proposalIDs: [proposalID]
        )

        let presentation = ProposalDockPresenter().build(
            from: projection,
            snapshotsByProposalID: [
                proposalID: makeSnapshot(
                    proposalID: proposalID,
                    summary: "Totals",
                    state: .readyForReview,
                    fileChanges: [
                        makeFileChange(proposalID: proposalID, path: "Sources/One.swift", state: .proposed, additions: 10, deletions: 2),
                        makeFileChange(proposalID: proposalID, path: "Sources/Two.swift", state: .conflict, additions: 3, deletions: 5),
                        makeFileChange(proposalID: proposalID, path: "Sources/Accepted.swift", state: .accepted, additions: 9, deletions: 9),
                        makeFileChange(proposalID: proposalID, path: "Sources/Rejected.swift", state: .rejected, additions: 7, deletions: 7)
                    ]
                )
            ]
        )

        #expect(presentation.pendingFileCount == 3)
        #expect(presentation.totalAdditions == 22)
        #expect(presentation.totalDeletions == 16)
    }
}

private func makeSnapshot(
    proposalID: UUID,
    summary: String?,
    state: ChangeProposalState,
    fileChanges: [ProposedFileChangeSnapshot]
) -> ChangeProposalReviewSnapshot {
    ChangeProposalReviewSnapshot(
        proposal: ChangeProposalSnapshot(
            id: proposalID,
            sessionID: "session-1",
            jobID: nil,
            messageID: nil,
            providerID: .builtInAgent,
            state: state,
            baseWorkspaceRoot: "/tmp/workspace",
            summary: summary,
            createdAt: .distantPast,
            updatedAt: .now
        ),
        fileChanges: fileChanges
    )
}

private func makeFileChange(
    proposalID: UUID,
    path: String,
    state: ProposedFileChangeState = .proposed,
    additions: Int = 1,
    deletions: Int = 1
) -> ProposedFileChangeSnapshot {
    ProposedFileChangeSnapshot(
        id: UUID(),
        proposalID: proposalID,
        relativePath: path,
        absolutePath: "/tmp/workspace/\(path)",
        changeKind: .modify,
        unifiedDiff: "@@ -1 +1 @@\n-old\n+new",
        state: state,
        lineAdditions: additions,
        lineDeletions: deletions
    )
}