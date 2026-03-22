import Foundation
import Testing
@testable import agentGui

struct ChangeProposalReviewSelectionResolverTests {
    @Test func resolvesExplicitlySelectedFileWhenItExists() {
        let snapshot = makeReviewSnapshot(
            fileChanges: [
                makeReviewFileChange(path: "A.swift"),
                makeReviewFileChange(path: "B.swift")
            ]
        )

        let selected = ChangeProposalReviewSelectionResolver.resolve(
            in: snapshot,
            selectedFilePath: "B.swift"
        )

        #expect(selected?.relativePath == "B.swift")
    }

    @Test func fallsBackToFirstPendingFileWhenSelectedFileIsMissing() {
        let snapshot = makeReviewSnapshot(
            fileChanges: [
                makeReviewFileChange(path: "Accepted.swift", state: .accepted),
                makeReviewFileChange(path: "Pending.swift", state: .proposed),
                makeReviewFileChange(path: "Rejected.swift", state: .rejected)
            ]
        )

        let selected = ChangeProposalReviewSelectionResolver.resolve(
            in: snapshot,
            selectedFilePath: "Missing.swift"
        )

        #expect(selected?.relativePath == "Pending.swift")
    }

    @Test func fallsBackToFirstFileWhenNoPendingFileExists() {
        let snapshot = makeReviewSnapshot(
            fileChanges: [
                makeReviewFileChange(path: "Accepted.swift", state: .accepted),
                makeReviewFileChange(path: "Rejected.swift", state: .rejected)
            ]
        )

        let selected = ChangeProposalReviewSelectionResolver.resolve(
            in: snapshot,
            selectedFilePath: nil
        )

        #expect(selected?.relativePath == "Accepted.swift")
    }
}

private func makeReviewSnapshot(
    proposalID: UUID = UUID(),
    fileChanges: [ProposedFileChangeSnapshot]
) -> ChangeProposalReviewSnapshot {
    ChangeProposalReviewSnapshot(
        proposal: ChangeProposalSnapshot(
            id: proposalID,
            sessionID: "session-1",
            jobID: nil,
            messageID: nil,
            providerID: .builtInAgent,
            state: .readyForReview,
            baseWorkspaceRoot: "/tmp/workspace",
            summary: "Test",
            createdAt: .distantPast,
            updatedAt: .now
        ),
        fileChanges: fileChanges
    )
}

private func makeReviewFileChange(
    path: String,
    state: ProposedFileChangeState = .proposed
) -> ProposedFileChangeSnapshot {
    ProposedFileChangeSnapshot(
        id: UUID(),
        proposalID: UUID(),
        relativePath: path,
        absolutePath: "/tmp/workspace/\(path)",
        changeKind: .modify,
        unifiedDiff: "@@ -1 +1 @@\n-old\n+new",
        state: state,
        lineAdditions: 1,
        lineDeletions: 1
    )
}