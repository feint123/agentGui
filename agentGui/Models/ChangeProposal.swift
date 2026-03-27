import Foundation
import SwiftData

enum ChangeProposalState: String, Codable, CaseIterable, Sendable {
    case collecting
    case readyForReview
    case partiallyApproved
    case applying
    case applied
    case discarded
    case conflicted
    case failed
}

extension ChangeProposalState {
    var isPendingReview: Bool {
        switch self {
        case .applied, .discarded, .failed:
            return false
        case .collecting, .readyForReview, .partiallyApproved, .applying, .conflicted:
            return true
        }
    }
}

@Model
final class ChangeProposal {
    var id: UUID
    var sessionID: String
    var jobID: UUID?
    var messageID: UUID?
    var providerIDRaw: String
    var stateRaw: String
    var isolationHandleID: UUID?
    var baseWorkspaceRoot: String
    var summary: String?
    var createdAt: Date
    var updatedAt: Date
    var appliedAt: Date?
    var discardedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ProposedFileChange.proposal)
    var fileChanges: [ProposedFileChange] = []

    @Relationship(deleteRule: .cascade, inverse: \ChangeReviewDecision.proposal)
    var reviewDecisions: [ChangeReviewDecision] = []

    init(
        id: UUID = UUID(),
        sessionID: String,
        jobID: UUID? = nil,
        messageID: UUID? = nil,
        providerID: ConversationExecutionProviderID,
        state: ChangeProposalState = .collecting,
        isolationHandleID: UUID? = nil,
        baseWorkspaceRoot: String,
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        appliedAt: Date? = nil,
        discardedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.jobID = jobID
        self.messageID = messageID
        self.providerIDRaw = providerID.rawValue
        self.stateRaw = state.rawValue
        self.isolationHandleID = isolationHandleID
        self.baseWorkspaceRoot = baseWorkspaceRoot
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.appliedAt = appliedAt
        self.discardedAt = discardedAt
    }
}

extension ChangeProposal {
    var providerReference: ExecutionProviderReference {
        get {
            ExecutionProviderReference.decodePersisted(providerIDRaw)
        }
        set {
            providerIDRaw = newValue.persistedValue
        }
    }

    var providerID: ConversationExecutionProviderID {
        get { ConversationExecutionProviderID(rawValue: providerIDRaw) ?? .builtInAgent }
        set { providerIDRaw = newValue.rawValue }
    }

    var state: ChangeProposalState {
        get { ChangeProposalState(rawValue: stateRaw) ?? .collecting }
        set { stateRaw = newValue.rawValue }
    }

    var isPendingReview: Bool {
        state.isPendingReview
    }
}