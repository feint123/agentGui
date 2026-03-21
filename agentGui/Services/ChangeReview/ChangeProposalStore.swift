import Foundation
import SwiftData

struct ChangeProposalSnapshot: Equatable, Sendable, Identifiable {
    let id: UUID
    let sessionID: String
    let jobID: UUID?
    let messageID: UUID?
    let providerID: ConversationExecutionProviderID
    let state: ChangeProposalState
    let baseWorkspaceRoot: String
    let summary: String?
    let createdAt: Date
    let updatedAt: Date
}

struct ProposedFileChangeSnapshot: Equatable, Sendable, Identifiable {
    let id: UUID
    let proposalID: UUID
    let relativePath: String
    let absolutePath: String
    let changeKind: ProposedFileChangeKind
    let unifiedDiff: String
    let state: ProposedFileChangeState
    let lineAdditions: Int
    let lineDeletions: Int
}

struct ChangeProposalReviewSnapshot: Equatable, Sendable, Identifiable {
    let proposal: ChangeProposalSnapshot
    let fileChanges: [ProposedFileChangeSnapshot]

    var id: UUID { proposal.id }
}

enum ChangeProposalStoreError: LocalizedError {
    case proposalNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .proposalNotFound:
            return "未找到对应的变更提案。"
        }
    }
}

@MainActor
final class ChangeProposalStore {
    private let modelContext: ModelContext
    private let persistenceCoordinator: PersistenceCoordinator

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator? = nil
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator ?? .shared
    }

    func createProposal(
        sessionID: String,
        jobID: UUID?,
        messageID: UUID?,
        providerID: ConversationExecutionProviderID,
        baseWorkspaceRoot: String
    ) async throws -> ChangeProposal {
        let proposal = ChangeProposal(
            sessionID: sessionID,
            jobID: jobID,
            messageID: messageID,
            providerID: providerID,
            baseWorkspaceRoot: baseWorkspaceRoot
        )
        modelContext.insert(proposal)
        try save(userMessage: "变更提案未成功保存")
        return proposal
    }

    func upsertFileChange(
        proposalID: UUID,
        relativePath: String,
        absolutePath: String,
        changeKind: ProposedFileChangeKind,
        unifiedDiff: String,
        baseContentHash: String? = nil,
        stagedContentHash: String? = nil,
        baseContentSnapshot: String? = nil,
        stagedContentSnapshot: String? = nil,
        lineAdditions: Int = 0,
        lineDeletions: Int = 0
    ) async throws {
        let proposal = try requireProposal(id: proposalID)
        if let existing = try fileChange(proposalID: proposalID, relativePath: relativePath) {
            existing.absolutePath = absolutePath
            existing.changeKind = changeKind
            existing.unifiedDiff = unifiedDiff
            existing.baseContentHash = baseContentHash
            existing.stagedContentHash = stagedContentHash
            existing.baseContentSnapshot = baseContentSnapshot
            existing.stagedContentSnapshot = stagedContentSnapshot
            existing.lineAdditions = lineAdditions
            existing.lineDeletions = lineDeletions
            existing.proposal = proposal
        } else {
            let change = ProposedFileChange(
                proposalID: proposalID,
                relativePath: relativePath,
                absolutePath: absolutePath,
                changeKind: changeKind,
                unifiedDiff: unifiedDiff,
                baseContentHash: baseContentHash,
                stagedContentHash: stagedContentHash,
                baseContentSnapshot: baseContentSnapshot,
                stagedContentSnapshot: stagedContentSnapshot,
                lineAdditions: lineAdditions,
                lineDeletions: lineDeletions
            )
            change.proposal = proposal
            modelContext.insert(change)
        }

        proposal.updatedAt = Date()
        try save(userMessage: "文件变更未成功保存到提案")
    }

    func reviewSnapshot(for proposalID: UUID) async throws -> ChangeProposalReviewSnapshot {
        let proposal = try requireProposal(id: proposalID)
        let fileChanges = try fileChanges(for: proposalID)
        return ChangeProposalReviewSnapshot(
            proposal: proposal.snapshot,
            fileChanges: fileChanges.map(\.snapshot)
        )
    }

    func updateProposal(
        proposalID: UUID,
        state: ChangeProposalState,
        summary: String? = nil
    ) async throws {
        let proposal = try requireProposal(id: proposalID)
        proposal.state = state
        if let summary {
            proposal.summary = summary
        }
        proposal.updatedAt = Date()
        try save(userMessage: "变更提案状态未成功更新")
    }

    func proposals(for sessionID: String) throws -> [ChangeProposal] {
        let targetSessionID = sessionID
        var descriptor = FetchDescriptor<ChangeProposal>(
            predicate: #Predicate { proposal in
                proposal.sessionID == targetSessionID
            }
        )
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        return try modelContext.fetch(descriptor)
    }

    func proposal(id: UUID) throws -> ChangeProposal? {
        let targetID = id
        let descriptor = FetchDescriptor<ChangeProposal>(
            predicate: #Predicate { proposal in
                proposal.id == targetID
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func requireProposal(id: UUID) throws -> ChangeProposal {
        if let proposal = try proposal(id: id) {
            return proposal
        }
        throw ChangeProposalStoreError.proposalNotFound(id)
    }

    private func fileChange(proposalID: UUID, relativePath: String) throws -> ProposedFileChange? {
        let targetProposalID = proposalID
        let targetPath = relativePath
        let descriptor = FetchDescriptor<ProposedFileChange>(
            predicate: #Predicate { change in
                change.proposalID == targetProposalID && change.relativePath == targetPath
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fileChanges(for proposalID: UUID) throws -> [ProposedFileChange] {
        let targetProposalID = proposalID
        var descriptor = FetchDescriptor<ProposedFileChange>(
            predicate: #Predicate { change in
                change.proposalID == targetProposalID
            }
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

private extension ChangeProposal {
    var snapshot: ChangeProposalSnapshot {
        ChangeProposalSnapshot(
            id: id,
            sessionID: sessionID,
            jobID: jobID,
            messageID: messageID,
            providerID: providerID,
            state: state,
            baseWorkspaceRoot: baseWorkspaceRoot,
            summary: summary,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private extension ProposedFileChange {
    var snapshot: ProposedFileChangeSnapshot {
        ProposedFileChangeSnapshot(
            id: id,
            proposalID: proposalID,
            relativePath: relativePath,
            absolutePath: absolutePath,
            changeKind: changeKind,
            unifiedDiff: unifiedDiff,
            state: state,
            lineAdditions: lineAdditions,
            lineDeletions: lineDeletions
        )
    }
}