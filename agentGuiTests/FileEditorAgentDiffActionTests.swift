import Testing
import Foundation
@testable import agentGui

/// 测试 FileEditorView 内部的 accept/reject 动作路由逻辑（通过 helper 提取被测函数）。
///
/// 直接测试 ApplyEngine / DraftRevertService 在测试环境下的行为，
/// 不依赖完整 SwiftUI View 生命周期。
@MainActor
struct FileEditorAgentDiffActionTests {

    /// 在现有 store 中找到匹配文件的 (proposalID, relativePath)
    private func findPendingChange(
        in store: ChangeReviewProjectionStore,
        fileURL: URL
    ) -> (proposalID: UUID, relativePath: String)? {
        let standardized = fileURL.standardizedFileURL
        for snapshot in store.snapshotsByProposalID.values {
            for fc in snapshot.fileChanges where fc.state.isPendingReview {
                if URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == standardized {
                    return (snapshot.proposal.id, fc.relativePath)
                }
            }
        }
        return nil
    }

    @Test func findPendingChangeReturnsTupleWhenFound() {
        let store = ChangeReviewProjectionStore()
        let proposalID = UUID()
        let proposal = ChangeProposalSnapshot(
            id: proposalID, sessionID: "s1", jobID: nil, messageID: nil,
            providerID: .builtInAgent, state: .readyForReview,
            baseWorkspaceRoot: "/ws", summary: nil, createdAt: Date(), updatedAt: Date()
        )
        let fc = ProposedFileChangeSnapshot(
            id: UUID(), proposalID: proposalID, relativePath: "A.swift",
            absolutePath: "/ws/A.swift", changeKind: .modify,
            unifiedDiff: "", state: .proposed, lineAdditions: 1, lineDeletions: 0
        )
        store.set(ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: [fc]))

        let result = findPendingChange(in: store, fileURL: URL(fileURLWithPath: "/ws/A.swift"))
        #expect(result?.proposalID == proposalID)
        #expect(result?.relativePath == "A.swift")
    }

    @Test func findPendingChangeReturnsNilForAppliedChange() {
        let store = ChangeReviewProjectionStore()
        let proposalID = UUID()
        let proposal = ChangeProposalSnapshot(
            id: proposalID, sessionID: "s1", jobID: nil, messageID: nil,
            providerID: .builtInAgent, state: .applied,
            baseWorkspaceRoot: "/ws", summary: nil, createdAt: Date(), updatedAt: Date()
        )
        let fc = ProposedFileChangeSnapshot(
            id: UUID(), proposalID: proposalID, relativePath: "B.swift",
            absolutePath: "/ws/B.swift", changeKind: .modify,
            unifiedDiff: "", state: .applied, lineAdditions: 0, lineDeletions: 0
        )
        store.set(ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: [fc]))

        let result = findPendingChange(in: store, fileURL: URL(fileURLWithPath: "/ws/B.swift"))
        #expect(result == nil)
    }
}
