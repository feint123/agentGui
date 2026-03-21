import Foundation
import SwiftData

enum ProposedFileChangeKind: String, Codable, CaseIterable, Sendable {
    case add
    case modify
    case delete
    case rename
}

enum ProposedFileChangeState: String, Codable, CaseIterable, Sendable {
    case proposed
    case accepted
    case rejected
    case revertedBeforeApply
    case applied
    case conflict
    case failed
}

extension ProposedFileChangeState {
    var isPendingReview: Bool {
        switch self {
        case .applied, .rejected, .revertedBeforeApply, .failed:
            return false
        case .proposed, .accepted, .conflict:
            return true
        }
    }
}

@Model
final class ProposedFileChange {
    var id: UUID
    var proposalID: UUID
    var relativePath: String
    var absolutePath: String
    var changeKindRaw: String
    var unifiedDiff: String
    var baseContentHash: String?
    var stagedContentHash: String?
    var baseContentSnapshot: String?
    var stagedContentSnapshot: String?
    var stateRaw: String
    var lineAdditions: Int
    var lineDeletions: Int

    var proposal: ChangeProposal?

    init(
        id: UUID = UUID(),
        proposalID: UUID,
        relativePath: String,
        absolutePath: String,
        changeKind: ProposedFileChangeKind,
        unifiedDiff: String,
        baseContentHash: String? = nil,
        stagedContentHash: String? = nil,
        baseContentSnapshot: String? = nil,
        stagedContentSnapshot: String? = nil,
        state: ProposedFileChangeState = .proposed,
        lineAdditions: Int = 0,
        lineDeletions: Int = 0
    ) {
        self.id = id
        self.proposalID = proposalID
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.changeKindRaw = changeKind.rawValue
        self.unifiedDiff = unifiedDiff
        self.baseContentHash = baseContentHash
        self.stagedContentHash = stagedContentHash
        self.baseContentSnapshot = baseContentSnapshot
        self.stagedContentSnapshot = stagedContentSnapshot
        self.stateRaw = state.rawValue
        self.lineAdditions = lineAdditions
        self.lineDeletions = lineDeletions
    }
}

extension ProposedFileChange {
    var changeKind: ProposedFileChangeKind {
        get { ProposedFileChangeKind(rawValue: changeKindRaw) ?? .modify }
        set { changeKindRaw = newValue.rawValue }
    }

    var state: ProposedFileChangeState {
        get { ProposedFileChangeState(rawValue: stateRaw) ?? .proposed }
        set { stateRaw = newValue.rawValue }
    }

    var isPendingReview: Bool {
        state.isPendingReview
    }
}