import Foundation
import SwiftData

@MainActor
final class DraftRevertService {
    private let modelContext: ModelContext
    private let persistenceCoordinator: PersistenceCoordinator
    private let projectionStore: ChangeReviewProjectionStore?
    private let conflictResolver: ConflictResolver
    private let workspaceSyncService: DraftWorkspaceSyncService

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator? = nil,
        projectionStore: ChangeReviewProjectionStore? = nil,
        conflictResolver: ConflictResolver? = nil,
        workspaceSyncService: DraftWorkspaceSyncService = DraftWorkspaceSyncService()
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator ?? .shared
        self.projectionStore = projectionStore
        self.conflictResolver = conflictResolver ?? ConflictResolver()
        self.workspaceSyncService = workspaceSyncService
    }

    func revertFiles(proposalID: UUID, relativePaths: [String]) async throws {
        let proposal = try requireProposal(id: proposalID)
        let targets = Set(relativePaths)
        let fileChanges = try fetchFileChanges(for: proposalID)
        let selectedChanges = targets.isEmpty
            ? fileChanges.filter(\.isPendingReview)
            : fileChanges.filter { targets.contains($0.relativePath) }

        do {
            for change in selectedChanges {
                try revertDraft(change: change)
                change.state = .revertedBeforeApply
            }

            proposal.state = fileChanges.allSatisfy { !$0.isPendingReview } ? .discarded : .partiallyApproved
            if proposal.state == .discarded {
                proposal.discardedAt = Date()
            }
            proposal.updatedAt = Date()
            try save(userMessage: "变更提案回退状态未成功保存")
            try await refreshProjection(proposalID: proposalID)
        } catch let conflict as ChangeReviewConflictError {
            proposal.state = .conflicted
            proposal.updatedAt = Date()
            try? save(userMessage: "变更提案冲突状态未成功保存")
            try? await refreshProjection(proposalID: proposalID)
            throw conflict
        }
    }

    private func revertDraft(change: ProposedFileChange) throws {
        let fileURL = URL(fileURLWithPath: change.absolutePath)
        let currentHash = try conflictResolver.currentContentHash(at: fileURL)

        if currentHash == change.baseContentHash {
            return
        }

        if currentHash == change.stagedContentHash {
            try workspaceSyncService.revertDraft(change.draftWorkspaceFileChange)
            return
        }

        throw ChangeReviewConflictError.draftChanged(change.absolutePath)
    }

    private func refreshProjection(proposalID: UUID) async throws {
        guard let projectionStore else { return }
        let store = ChangeProposalStore(modelContext: modelContext, persistenceCoordinator: persistenceCoordinator)
        let snapshot = try await store.reviewSnapshot(for: proposalID)
        projectionStore.set(snapshot)
    }

    private func requireProposal(id: UUID) throws -> ChangeProposal {
        let targetID = id
        let descriptor = FetchDescriptor<ChangeProposal>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let proposal = try modelContext.fetch(descriptor).first else {
            throw ChangeProposalStoreError.proposalNotFound(id)
        }
        return proposal
    }

    private func fetchFileChanges(for proposalID: UUID) throws -> [ProposedFileChange] {
        let targetProposalID = proposalID
        var descriptor = FetchDescriptor<ProposedFileChange>(
            predicate: #Predicate { $0.proposalID == targetProposalID }
        )
        descriptor.sortBy = [SortDescriptor(\.relativePath)]
        return try modelContext.fetch(descriptor)
    }

    private func save(userMessage: String) throws {
        try persistenceCoordinator.save(
            modelContext,
            domain: .execution,
            userMessage: userMessage
        )
    }
}