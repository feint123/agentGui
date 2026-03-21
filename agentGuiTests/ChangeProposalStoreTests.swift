import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ChangeProposalStoreTests {
    @Test func proposalStartsCollectingAndTracksProviderSessionAndJob() throws {
        let proposal = ChangeProposal(
            sessionID: "session-1",
            jobID: UUID(),
            messageID: UUID(),
            providerID: .githubCopilotCLI,
            baseWorkspaceRoot: "/tmp/workspace"
        )

        #expect(proposal.state == .collecting)
        #expect(proposal.providerID == .githubCopilotCLI)
        #expect(proposal.sessionID == "session-1")
        #expect(proposal.updatedAt >= proposal.createdAt)
    }

    @Test func proposedFileChangeStartsProposedAndCarriesUnifiedDiff() throws {
        let change = ProposedFileChange(
            proposalID: UUID(),
            relativePath: "agentGui/Models/ToolCall.swift",
            absolutePath: "/tmp/workspace/agentGui/Models/ToolCall.swift",
            changeKind: .modify,
            unifiedDiff: "@@ -1 +1 @@\n-old\n+new",
            baseContentSnapshot: "old",
            stagedContentSnapshot: "new"
        )

        #expect(change.state == .proposed)
        #expect(change.unifiedDiff.contains("@@"))
        #expect(change.baseContentSnapshot == "old")
        #expect(change.stagedContentSnapshot == "new")
    }

    @Test func changeReviewDecisionCapturesActionAndTimestamp() throws {
        let decision = ChangeReviewDecision(
            proposalID: UUID(),
            action: .applySelected,
            relativePaths: ["README.md"],
            note: "apply reviewed file"
        )

        #expect(decision.action == .applySelected)
        #expect(decision.relativePaths == ["README.md"])
        #expect(decision.createdAt <= Date())
    }

    @Test func storeCreatesProposalAndUpsertsFileChangesByRelativePath() async throws {
        let harness = try ChangeProposalHarness.make()
        let store = harness.makeProposalStore()

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
            unifiedDiff: "@@ -1 +1 @@\n-old\n+new",
            baseContentSnapshot: "old",
            stagedContentSnapshot: "new"
        )
        try await store.upsertFileChange(
            proposalID: proposal.id,
            relativePath: "README.md",
            absolutePath: "/tmp/workspace/README.md",
            changeKind: .modify,
            unifiedDiff: "@@ -1 +1 @@\n-old\n+newer",
            baseContentSnapshot: "old",
            stagedContentSnapshot: "newer"
        )

        let snapshot = try await store.reviewSnapshot(for: proposal.id)
        #expect(snapshot.proposal.id == proposal.id)
        #expect(snapshot.fileChanges.count == 1)
        #expect(snapshot.fileChanges[0].unifiedDiff.contains("newer"))
    }

    @Test func bootstrapperRestoresPendingProposalIntoProjectionStore() async throws {
        let harness = try ChangeProposalHarness.make()
        let store = harness.makeProposalStore()
        let projectionStore = ChangeReviewProjectionStore()

        let proposal = try await store.createProposal(
            sessionID: "session-restore",
            jobID: nil,
            messageID: nil,
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
        try await store.updateProposal(
            proposalID: proposal.id,
            state: .readyForReview,
            summary: "待审查变更：1 个文件"
        )

        try await ChangeReviewBootstrapper.restorePendingProposals(
            modelContext: harness.context,
            projectionStore: projectionStore,
            persistenceCoordinator: PersistenceCoordinator()
        )

        let snapshot = try #require(projectionStore.snapshot(for: proposal.id))
        #expect(snapshot.proposal.state == .readyForReview)
        #expect(snapshot.fileChanges.map(\.relativePath) == ["README.md"])
    }
}

@MainActor
struct ChangeProposalHarness {
    let container: ModelContainer
    let context: ModelContext

    static func make() throws -> ChangeProposalHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ChangeProposal.self,
            ProposedFileChange.self,
            ChangeReviewDecision.self,
            configurations: configuration
        )
        return ChangeProposalHarness(container: container, context: ModelContext(container))
    }

    func makeProposalStore() -> ChangeProposalStore {
        ChangeProposalStore(modelContext: context, persistenceCoordinator: PersistenceCoordinator())
    }
}