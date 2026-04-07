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

    /// 查找同 sessionID + providerID + baseWorkspaceRoot 下处于活跃待审状态（`.collecting` 或
    /// `.readyForReview`）的已有提案；若不存在则新建一条 `.collecting` 提案。
    /// 用于将同一 session 内多次工具调用的文件变更归并入同一提案，
    /// 避免每次工具调用都生成独立的变更提案记录。
    func findOrCreateCollectingProposal(
        sessionID: String,
        providerID: ConversationExecutionProviderID,
        baseWorkspaceRoot: String
    ) throws -> ChangeProposal {
        let targetSessionID = sessionID
        let targetProviderIDRaw = providerID.rawValue
        let targetRoot = baseWorkspaceRoot
        let collectingRaw = ChangeProposalState.collecting.rawValue
        let readyRaw = ChangeProposalState.readyForReview.rawValue
        var descriptor = FetchDescriptor<ChangeProposal>(
            predicate: #Predicate { proposal in
                proposal.sessionID == targetSessionID &&
                proposal.providerIDRaw == targetProviderIDRaw &&
                proposal.baseWorkspaceRoot == targetRoot &&
                (proposal.stateRaw == collectingRaw || proposal.stateRaw == readyRaw)
            }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }

        let proposal = ChangeProposal(
            sessionID: sessionID,
            jobID: nil,
            messageID: nil,
            providerID: providerID,
            baseWorkspaceRoot: baseWorkspaceRoot
        )
        modelContext.insert(proposal)
        try save(userMessage: "变更提案未成功保存")
        return proposal
    }

    func existingFileChange(proposalID: UUID, relativePath: String) throws -> ProposedFileChange? {
        try fileChange(proposalID: proposalID, relativePath: relativePath)
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
            // 保留最初记录的 baseContentHash / baseContentSnapshot，使 diff 始终从首次
            // 工具调用前的原始内容算起，避免多次编辑同一文件时 base 被覆盖为中间状态。
            if existing.baseContentHash == nil { existing.baseContentHash = baseContentHash }
            if existing.baseContentSnapshot == nil { existing.baseContentSnapshot = baseContentSnapshot }
            existing.stagedContentHash = stagedContentHash
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