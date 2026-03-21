import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ChangeReviewProjectionStoreTests {
    @Test func reviewProjectionSummarizesPendingChangesForSession() async throws {
        let harness = try ChangeProposalHarness.make()
        let store = harness.makeProposalStore()
        let projectionStore = ChangeReviewProjectionStore()

        let proposal = try await store.createProposal(
            sessionID: "session-1",
            jobID: UUID(),
            messageID: UUID(),
            providerID: .builtInAgent,
            baseWorkspaceRoot: "/tmp/workspace"
        )
        try await store.upsertFileChange(
            proposalID: proposal.id,
            relativePath: "README.md",
            absolutePath: "/tmp/workspace/README.md",
            changeKind: .modify,
            unifiedDiff: "@@ -1 +1 @@\n-old\n+new"
        )

        let snapshot = try await store.reviewSnapshot(for: proposal.id)
        projectionStore.set(snapshot)

        let projection = projectionStore.projection(forSessionID: "session-1")
        #expect(projection.pendingProposalCount == 1)
        #expect(projection.pendingFileCount == 1)
    }
}