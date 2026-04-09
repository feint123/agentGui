import Testing
import Foundation
@testable import agentGui

/// 测试 unifiedDiff → agentChangeDiffByLine 的转换逻辑（不依赖 SwiftUI）。
@MainActor
struct FileEditorAgentDiffIntegrationTests {

    @Test func parseUnifiedDiffProducesLineDiff() {
        // 模拟 agent 添加第3行、修改第5行的 unified diff
        let unifiedDiff = """
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -2,0 +3,1 @@
        +let x = 1
        @@ -5,1 +6,1 @@
        -let y = 0
        +let y = 42
        """
        let result = UnifiedDiffParser.parse(unifiedDiff)
        // 第3行应为 .added，第5或6行附近应有变更
        #expect(!result.isEmpty)
        #expect(result.values.contains(.added))
    }

    @Test func findFileChangeSnapshotForAbsolutePath() {
        let proposalID = UUID()
        let proposal = ChangeProposalSnapshot(
            id: proposalID,
            sessionID: "s1",
            jobID: nil,
            messageID: nil,
            providerID: .builtInAgent,
            state: .readyForReview,
            baseWorkspaceRoot: "/workspace",
            summary: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let fileChange = ProposedFileChangeSnapshot(
            id: UUID(),
            proposalID: proposalID,
            relativePath: "Foo.swift",
            absolutePath: "/workspace/Foo.swift",
            changeKind: .modify,
            unifiedDiff: "@@ -1,1 +1,1 @@\n-old\n+new",
            state: .proposed,
            lineAdditions: 1,
            lineDeletions: 1
        )
        let reviewSnapshot = ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: [fileChange])
        let store = ChangeReviewProjectionStore()
        store.set(reviewSnapshot)

        // 测试辅助函数：根据文件 URL 在 store 中找匹配的 fileChange
        let targetURL = URL(fileURLWithPath: "/workspace/Foo.swift")
        let match = store.snapshotsByProposalID.values
            .flatMap { $0.fileChanges }
            .filter { $0.state.isPendingReview }
            .first { fc in
                URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == targetURL.standardizedFileURL
            }

        #expect(match != nil)
        #expect(match?.relativePath == "Foo.swift")
    }

    @Test func noMatchWhenFileChangeNotPending() {
        let proposalID = UUID()
        let proposal = ChangeProposalSnapshot(
            id: proposalID,
            sessionID: "s1",
            jobID: nil,
            messageID: nil,
            providerID: .builtInAgent,
            state: .applied,
            baseWorkspaceRoot: "/workspace",
            summary: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let fileChange = ProposedFileChangeSnapshot(
            id: UUID(),
            proposalID: proposalID,
            relativePath: "Bar.swift",
            absolutePath: "/workspace/Bar.swift",
            changeKind: .modify,
            unifiedDiff: "",
            state: .applied,     // 已应用，不应显示装饰
            lineAdditions: 0,
            lineDeletions: 0
        )
        let reviewSnapshot = ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: [fileChange])
        let store = ChangeReviewProjectionStore()
        store.set(reviewSnapshot)

        let targetURL = URL(fileURLWithPath: "/workspace/Bar.swift")
        let match = store.snapshotsByProposalID.values
            .flatMap { $0.fileChanges }
            .filter { $0.state.isPendingReview }
            .first { fc in
                URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == targetURL.standardizedFileURL
            }

        #expect(match == nil)   // 状态为 applied，不应匹配
    }
}
